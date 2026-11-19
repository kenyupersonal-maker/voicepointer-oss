import AppKit
import SwiftUI
import VoicePointerCore

struct MagicMouseReviewFixture {
    var present: Bool
    var expanded: Bool = false
    var samples: [TouchSample] = []
    var snapshot: TouchSurfaceSnapshot? = nil
    var decision: TouchSampleLatestDecision? = nil
}

struct MagicMouseLiveValues: Sendable {
    var present: Bool
    var snapshot: TouchSurfaceSnapshot?
    var decision: TouchSampleLatestDecision?
    var label: TouchSampleLabel = .none
    var storageFailed = false
}

/// Injected checks need neither the private touch driver nor the real sample recorder.
struct MagicMouseSettingsSource: Sendable {
    var live: @MainActor @Sendable () -> MagicMouseLiveValues
    var samples: @Sendable () -> [TouchSample]
    var load: @Sendable () async -> Void = {}
    var mark: @Sendable (TouchSampleLabel) -> Void = { _ in }
    var clear: @Sendable () async -> TouchSampleStorageState = { .idle }
}

struct MagicMouseComparisonRow: Equatable, Sendable {
    var label: TouchSampleLabel
    var count: Int
    var triggered: Int
    var ratio: Double
}

struct MagicMouseScatterPoint: Identifiable, Equatable, Sendable {
    var id: Int
    var density: Float
    var label: TouchSampleLabel
}

struct MagicMouseSamplePresentation: Equatable, Sendable {
    var samples: [TouchSample] = []
    var rows: [MagicMouseComparisonRow] = [.init(label: .single, count: 0, triggered: 0, ratio: 0),
                                            .init(label: .real, count: 0, triggered: 0, ratio: 0)]
    var scatter: [MagicMouseScatterPoint] = []
}

/// Only these controls affect the prediction; haptic/recording changes do not invalidate it.
struct MagicMouseComparisonConfiguration: Equatable, Sendable {
    let fingers: Int
    let density: Float
    let skew: Int
    let fresh: Int
    let movement: Float
    let fastLanding: Int
    let slowDensity: Float
    init(_ value: GestureConfiguration) {
        fingers = value.magicMouseFingerCount; density = value.magicMouseMinDensity
        skew = value.magicMouseMaxLandingSkewMilliseconds; fresh = value.magicMouseFreshChordWindowMilliseconds
        movement = value.maximumTouchMovement
        fastLanding = value.magicMouseFastLandingMilliseconds; slowDensity = value.magicMouseSlowMinDensity
    }
}

/// Array equality, density extraction, filtering and all ratio work stay off the main actor.
actor MagicMouseSampleProcessor {
    struct Result: Sendable { let version: UInt64; let presentation: MagicMouseSamplePresentation }
    private var cached = MagicMouseSamplePresentation()
    private var configuration = MagicMouseComparisonConfiguration(.init())
    private var comparisonRequest: UInt64 = 0
    private var version: UInt64 = 0
    private(set) var sampleComputations = 0
    private(set) var comparisonComputations = 0
    private let beforeRead: @Sendable () async -> Void
    init(beforeRead: @escaping @Sendable () async -> Void = {}) { self.beforeRead = beforeRead }

    func prepare(read: @Sendable () -> [TouchSample], configuration next: GestureConfiguration,
                 comparisonRequest nextRequest: UInt64 = 0) async -> Result? {
        guard !Task.isCancelled else { return nil }
        await beforeRead()
        guard !Task.isCancelled else { return nil }
        let samples = read()
        let key = MagicMouseComparisonConfiguration(next)
        let samplesChanged = samples != cached.samples
        let compareChanged = samplesChanged || key != configuration || nextRequest != comparisonRequest
        var presentation = cached
        if samplesChanged {
            presentation.samples = samples
            presentation.scatter = Array(samples.filter { $0.label != .none && $0.minDensity.isFinite }.suffix(500))
                .enumerated().map { .init(id: $0.offset, density: $0.element.minDensity, label: $0.element.label) }
        }
        if compareChanged {
            presentation.rows = TouchSampleRecorder.compare(samples, configuration: next).map {
                .init(label: $0.label, count: $0.count, triggered: $0.triggered, ratio: $0.ratio)
            }
        }
        guard !Task.isCancelled else { return nil }
        if samplesChanged { sampleComputations += 1 }
        if compareChanged { comparisonComputations += 1 }
        // A control can change without changing any prediction. Do not publish that either.
        if presentation != cached { version &+= 1; cached = presentation }
        configuration = key
        comparisonRequest = nextRequest
        return .init(version: version, presentation: cached)
    }
}

@MainActor final class MagicMouseSettingsState: ObservableObject {
    static let refreshInterval = 1.0 / 15.0
    @Published private(set) var present = false
    @Published private(set) var snapshot: TouchSurfaceSnapshot?
    @Published private(set) var decision: TouchSampleLatestDecision?
    @Published private(set) var samplePresentation = MagicMouseSamplePresentation()
    var samples: [TouchSample] { samplePresentation.samples }
    var samplePresentationRevision: UInt64 { presentationVersion }
    @Published private(set) var label: TouchSampleLabel = .none
    @Published private(set) var clearing = false
    @Published private(set) var clearFailed = false
    @Published private(set) var storageFailed = false
    private var fixture: MagicMouseReviewFixture?
    private let source: MagicMouseSettingsSource?
    private let processor: MagicMouseSampleProcessor
    private let activity: SettingsLiveActivity
    private let injectedVisibility: (@MainActor () -> Bool)?
    private let automaticPolling: Bool
    private weak var window: NSWindow?
    private var pageVisible = true
    private var windowVisible = false
    private var visible = false
    private var activityObserver: UUID?
    private var refreshTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var pendingPresentation: MagicMouseSampleProcessor.Result?
    private var presentationVersion: UInt64 = 0
    private var epoch: UInt64 = 0
    private var lastRefreshTime: Double?
    private var configuration = GestureConfiguration()
    private var comparisonRequest: UInt64 = 0
    private(set) var refreshCount = 0

    init(fixture: MagicMouseReviewFixture?, source injected: MagicMouseSettingsSource? = nil,
         activity: SettingsLiveActivity = .shared, processor: MagicMouseSampleProcessor = .init(),
         visibility: (@MainActor () -> Bool)? = nil, automaticPolling: Bool = true) {
        self.fixture = fixture; self.activity = activity; self.processor = processor
        injectedVisibility = visibility; self.automaticPolling = automaticPolling
        if let injected { source = injected }
        else if fixture != nil { source = nil }
        else {
            let recorder = TouchSampleRecorder.shared
            let driver = MultitouchDriver() // Existing shim only; never starts the private framework.
            source = .init(live: {
                let present = driver.magicMousePresent
                return .init(present: present, snapshot: present ? driver.magicMouseSnapshot : nil,
                             decision: recorder.latestDecision, label: recorder.label,
                             storageFailed: recorder.storageState == .failed)
            }, samples: { recorder.recentSamples }, load: { await recorder.refreshRecentSamples() },
               mark: { recorder.label = $0 }, clear: { await recorder.clear() })
        }
        if let fixture {
            present = fixture.present; snapshot = fixture.snapshot; decision = fixture.decision
        }
    }

    func appear(configuration: GestureConfiguration) {
        pageVisible = true
        updateConfiguration(configuration)
        setVisible(windowVisible)
    }
    func disappear() { pageVisible = false; setVisible(false) }
    func attach(_ window: NSWindow?, visible: Bool) {
        self.window = window; windowVisible = visible
        setVisible(pageVisible && visible)
    }
    func setVisible(_ next: Bool) {
        visible = next
        if next {
            if activityObserver == nil {
                activityObserver = activity.observe { [weak self] _ in self?.reconcilePolling() }
            }
            reconcilePolling()
        } else {
            if let activityObserver { activity.removeObserver(activityObserver) }
            activityObserver = nil
            cancelWork()
        }
    }
    private var mayRefresh: Bool {
        guard visible, !activity.snapshot.pausesMouseRefresh else { return false }
        if let injectedVisibility { return injectedVisibility() }
        return window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
    }
    private func cancelWork() {
        epoch &+= 1
        refreshTask?.cancel(); refreshTask = nil
        sampleTask?.cancel(); sampleTask = nil
        pendingPresentation = nil
    }
    private func reconcilePolling() {
        guard mayRefresh else { cancelWork(); return }
        guard automaticPolling, refreshTask == nil else { return }
        let generation = epoch
        let load = source?.load
        refreshTask = Task { @MainActor [weak self] in
            // Loading is also admission-gated and cancellation checked before any publication.
            guard !Task.isCancelled, self?.epoch == generation, self?.mayRefresh == true else { return }
            if let load { await load() }
            while !Task.isCancelled {
                guard self?.refreshIfAdmitted(epoch: generation) == true else { return }
                do { try await Task.sleep(for: .nanoseconds(66_666_667)) } catch { return }
            }
        }
    }
    private func refreshIfAdmitted(epoch generation: UInt64) -> Bool {
        guard epoch == generation else { return false }
        guard mayRefresh else { cancelWork(); return false }
        refresh()
        return true
    }
    func updateConfiguration(_ next: GestureConfiguration) {
        let changed = MagicMouseComparisonConfiguration(next) != MagicMouseComparisonConfiguration(configuration)
        configuration = next
        guard changed else { return }
        cancelWork()
        reconcilePolling()
    }

    /// The measured synchronous main-thread tick; prepared arrays/ratios are only assigned here.
    /// Preserve the timestamp across pauses/restarts, so a quick hide/show cannot exceed 15 Hz.
    @discardableResult
    func refresh(at now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard mayRefresh else { return false }
        if let lastRefreshTime, now - lastRefreshTime < Self.refreshInterval { return false }
        lastRefreshTime = now; refreshCount += 1
        let live = source?.live() ?? MagicMouseLiveValues(present: fixture?.present ?? false,
                                                         snapshot: fixture?.snapshot, decision: fixture?.decision,
                                                         label: label)
        if present != live.present { present = live.present }
        // Only the contour is displayed. Frame ages change while an unchanged contour is idle.
        let nextSnapshot = live.present ? live.snapshot : nil
        if snapshot?.deviceToken != nextSnapshot?.deviceToken || snapshot?.points != nextSnapshot?.points {
            snapshot = nextSnapshot
        }
        if decision != live.decision { decision = live.decision }
        if label != live.label {
            label = live.label
            comparisonRequest &+= 1
            cancelWork(); reconcilePolling()
        }
        if storageFailed != live.storageFailed { storageFailed = live.storageFailed }
        if let pendingPresentation {
            if pendingPresentation.version != presentationVersion {
                presentationVersion = pendingPresentation.version
                samplePresentation = pendingPresentation.presentation
            }
            self.pendingPresentation = nil
        }
        scheduleSamples()
        return true
    }
    private func scheduleSamples() {
        guard sampleTask == nil else { return }
        let generation = epoch, configuration = configuration, processor = processor, comparisonRequest = comparisonRequest
        let read: @Sendable () -> [TouchSample]
        if let source { read = source.samples }
        else { let samples = fixture?.samples ?? []; read = { samples } }
        sampleTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, self?.epoch == generation, self?.mayRefresh == true else { return }
            let result = await processor.prepare(read: read, configuration: configuration,
                                                 comparisonRequest: comparisonRequest)
            guard !Task.isCancelled, let state = self, state.epoch == generation, state.mayRefresh else { return }
            // Keep expensive output atomic; the next admitted tick publishes it on main.
            state.pendingPresentation = result
            state.sampleTask = nil
        }
    }
    func mark(_ value: TouchSampleLabel) {
        guard label != value else { return }
        label = value
        comparisonRequest &+= 1
        source?.mark(value)
        cancelWork(); reconcilePolling()
        if mayRefresh { scheduleSamples() }
    }
    func clear() async {
        guard !clearing else { return }
        clearing = true
        if clearFailed { clearFailed = false }
        cancelWork()
        let result = await source?.clear() ?? .idle
        if source == nil { fixture?.samples = [] }
        let failed = result == .failed
        if clearFailed != failed { clearFailed = failed }
        clearing = false
        reconcilePolling()
    }

    #if F5_SETTINGS_CHECK
    var sampleTaskForCheck: Task<Void, Never>? { sampleTask }
    var refreshTaskForCheck: Task<Void, Never>? { refreshTask }
    func waitForSamplesForCheck() async { await sampleTask?.value }
    #endif

    deinit {
        refreshTask?.cancel(); sampleTask?.cancel()
        let activity = activity, token = activityObserver
        Task { @MainActor in if let token { activity.removeObserver(token) } }
    }
}
