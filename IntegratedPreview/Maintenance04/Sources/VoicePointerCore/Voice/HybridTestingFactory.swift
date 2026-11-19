import Foundation

// Self-test seam for the hybrid backend ("用于增强本地识别"). `HybridSpeechBackend`, `SharedCaptureHub` and the
// capture protocol are internal to this module, so the self-test binary drives them through this SPI: the real
// hybrid backend, assembled with scripted branches, a scripted capture source and the caller's clock. Nothing
// here opens a microphone, a network connection or a worker; buffers are silent PCM made in memory.

/// What a scripted branch throws when told to fail its start.
@_spi(Testing) public enum HybridTestingError: Error, Equatable, Sendable {
    case scripted(String)
}

/// One ordered record of what the scripted parts did, so a check can assert the order of side effects.
@_spi(Testing) @MainActor public final class HybridTestingLog {
    public private(set) var entries: [String] = []

    public init() {}

    public func note(_ entry: String) {
        entries.append(entry)
    }
}

/// A scripted capture: silence the check appends by hand, a failure or the duration limit on demand.
@_spi(Testing) @MainActor public final class HybridTestingSource: LocalSpeechCapture {
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var didReachDurationLimit = false
    /// When set, `start` throws with this code (after counting the attempt).
    public var startFailureCode: String?

    var onCaptureFailure: (@Sendable (String) -> Void)?
    var onDurationLimitReached: (@Sendable () -> Void)?
    private(set) var captureFailure: TrialCoreError?

    private let log: HybridTestingLog?
    private var buffers: [OwnedPCMBuffer] = []
    private var sealed = false

    public init(log: HybridTestingLog? = nil) {
        self.log = log
    }

    public var bufferCount: Int { buffers.count }

    /// Appends one silent buffer; ignored (false) once the capture is sealed, like the real store.
    @discardableResult
    public func appendBuffer(frames: Int, sampleRate: Double = 48_000) -> Bool {
        guard !sealed, let buffer = HybridTestingPCM.silence(frames: frames, sampleRate: sampleRate) else {
            return false
        }
        buffers.append(buffer)
        return true
    }

    /// Appends `milliseconds` of silence as one buffer.
    @discardableResult
    public func appendAudio(milliseconds: Int, sampleRate: Double = 48_000) -> Bool {
        appendBuffer(frames: Int((Double(milliseconds) * sampleRate / 1_000).rounded()), sampleRate: sampleRate)
    }

    /// The real pipeline seals, records the failure and reports it through its callback (on the main actor).
    public func failCapture(_ code: String) {
        sealed = true
        captureFailure = .invalid(code)
        onCaptureFailure?(code)
    }

    /// The real pipeline stops itself at the limit, then reports it.
    public func reachDurationLimit() {
        sealed = true
        didReachDurationLimit = true
        onDurationLimitReached?()
    }

    func snapshotBuffers() -> [OwnedPCMBuffer] { buffers }

    func start(streamingToApple: Bool) throws {
        startCount += 1
        log?.note("source.start")
        if streamingToApple { throw TrialCoreError.invalid("TEST_SOURCE_APPLE") }
        if let startFailureCode { throw TrialCoreError.invalid(startFailureCode) }
    }

    func stop() {
        stopCount += 1
        if !sealed { log?.note("source.stop") }
        sealed = true
    }
}

/// A scripted branch that behaves like the real backend of its role at every boundary the hybrid backend
/// relies on: the local one asks for permission, opens its capture view and emits `.ready` inside `start`, and
/// its `cancel` is silent; the cloud one emits `.ready` only when the check says so and its `cancel` reports
/// `.stopped` (or the cleanup failure), as `AliSpeechBackend` does.
@_spi(Testing) @MainActor public final class HybridTestingBranch: SpeechInputBackend, CloudUplinkReporting {
    public enum Role: String, Sendable {
        case local, cloud
    }

    public enum StartFailure: Equatable, Sendable {
        case none
        /// Throws before asking for permission or touching the capture (the local catalog lookup).
        case beforePermission(String)
        /// Opens the capture, then fails: emits `.failed` like the local backend's own start clean-up.
        case afterCapture(String)
        /// Opens the capture, then throws without a word (the local backend's start giving up when stopped).
        case afterCaptureSilently(String)
    }

    public enum FinishStyle: Equatable, Sendable {
        /// `finish` suspends until `completeFinish(final:)` / `completeFinish(failure:)` or a cancel.
        case manual
        case final(String)
        case failure(String)
        /// `finish` returns without a result (a local backend breaking its contract).
        case silent
    }

    public enum CancelReport: Equatable, Sendable {
        case silent
        case stopped
        case cleanupFailure
    }

    private enum State {
        case idle, starting, listening, finishing, done
    }

    public let role: Role
    public var startFailure: StartFailure = .none
    public var finishStyle: FinishStyle = .manual
    public var cancelReport: CancelReport
    /// The cloud's start suspends (after it opened its capture) until `releaseStart()`.
    public var holdsStart = false
    /// `cancel` suspends until `releaseCancel()`.
    public var holdsCancel = false
    public var uplinkSentMilliseconds: Int64 = 0
    /// Synthetic numeric confidence for learning checks. Production evidence comes from the worker observer.
    public var modelConfidence: Double?

    public private(set) var startCount = 0
    public private(set) var finishCount = 0
    public private(set) var cancelCount = 0
    public private(set) var receivedSnapshot: VoiceInputSnapshot?
    public private(set) var permissionAnswers: [Bool] = []
    public private(set) var captureFailures: [String] = []
    public private(set) var durationLimitCalls = 0
    /// The buffers the branch read when it was told to finish.
    public private(set) var finishSnapshotIdentities: [ObjectIdentifier] = []

    private let log: HybridTestingLog?
    private var state: State = .idle
    private var makeCapture: (@MainActor () -> any LocalSpeechCapture)?
    private var permission: (@MainActor () async -> Bool)?
    private var capture: (any LocalSpeechCapture)?
    private var callback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
    private var sessionID: UUID?
    private var sequence: UInt64 = 0
    private var terminalEmitted = false
    private var stopRequested = false
    private var startGate: CheckedContinuation<Void, Never>?
    private var cancelGate: CheckedContinuation<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    public init(role: Role, log: HybridTestingLog? = nil) {
        self.role = role
        self.log = log
        cancelReport = role == .cloud ? .stopped : .silent
    }

    internal func attach(
        capture: @escaping @MainActor () -> any LocalSpeechCapture,
        permission: @escaping @MainActor () async -> Bool
    ) {
        makeCapture = capture
        self.permission = permission
    }

    // MARK: SpeechInputBackend

    public var isQuiescent: Bool {
        (state == .idle || state == .done) && cancelGate == nil
    }

    public var capabilities: SpeechInputCapabilities {
        SpeechInputCapabilities(
            deliveryKind: .transcriptStream, supportsPartialText: true, supportsHints: role == .local
        )
    }

    public func start(
        snapshot: VoiceInputSnapshot,
        onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void
    ) async throws {
        startCount += 1
        log?.note("\(role.rawValue).start")
        receivedSnapshot = snapshot
        sessionID = snapshot.sessionID
        callback = onEvent
        state = .starting
        defer { resumeStartWaiters() }
        if case .beforePermission(let code) = startFailure {
            state = .done
            throw HybridTestingError.scripted(code)
        }
        let granted = await permission?() ?? false
        permissionAnswers.append(granted)
        if stopRequested {
            state = .done
            throw CancellationError()
        }
        guard granted else {
            if role == .local { emit(.failed, errorCode: "LOCAL_START_FAILED") } else { emit(.stopped) }
            state = .done
            throw HybridTestingError.scripted(role == .local ? "LOCAL_MIC_PERMISSION_DENIED" : "ALI_PERMISSION")
        }
        guard let makeCapture else {
            state = .done
            throw HybridTestingError.scripted("NO_CAPTURE")
        }
        let capture = makeCapture()
        self.capture = capture
        capture.onCaptureFailure = { [weak self] code in
            Task { @MainActor [weak self] in self?.captureFailed(code) }
        }
        capture.onDurationLimitReached = { [weak self] in
            Task { @MainActor [weak self] in self?.durationLimitCalls += 1 }
        }
        do {
            try await capture.start(streamingToApple: false)
            if stopRequested { throw CancellationError() }
        } catch {
            await capture.stop()
            if !stopRequested {
                if role == .local { emit(.failed, errorCode: "LOCAL_START_FAILED") } else { emit(.stopped) }
            }
            state = .done
            throw error
        }
        if case .afterCapture(let code) = startFailure {
            await capture.stop()
            if role == .local { emit(.failed, errorCode: "LOCAL_START_FAILED") } else { emit(.stopped) }
            state = .done
            throw HybridTestingError.scripted(code)
        }
        if case .afterCaptureSilently(let code) = startFailure {
            await capture.stop()
            state = .done
            throw HybridTestingError.scripted(code)
        }
        if holdsStart {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                startGate = continuation
            }
            if stopRequested {
                await capture.stop()
                state = .done
                throw CancellationError()
            }
        }
        state = .listening
        if role == .local { emit(.ready) }
    }

    public func finish() async {
        finishCount += 1
        log?.note("\(role.rawValue).finish")
        switch state {
        case .idle, .done:
            return
        case .starting:
            if role == .local {
                // Like the local backend: a finish during the start abandons it.
                stopRequested = true
                callback = nil
                startGate?.resume()
                startGate = nil
                await waitForStart()
                return
            }
            // Like the Ali backend: the finish waits for the start, then finishes.
            await waitForStart()
            guard state == .listening else { return }
        case .finishing:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                finishWaiters.append(continuation)
            }
            return
        case .listening:
            break
        }
        state = .finishing
        await capture?.stop()
        finishSnapshotIdentities = (capture?.snapshotBuffers() ?? []).map { ObjectIdentifier($0) }
        switch finishStyle {
        case .final(let text):
            end(kind: .final, text: text, errorCode: nil)
        case .failure(let code):
            end(kind: .failed, text: nil, errorCode: code)
        case .manual:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                finishWaiters.append(continuation)
            }
        case .silent:
            state = .done
            await capture?.stop()
            resumeFinishWaiters()
        }
    }

    public func cancel() async {
        cancelCount += 1
        log?.note("\(role.rawValue).cancel")
        if role == .local { callback = nil }
        stopRequested = true
        await capture?.stop()
        if state == .starting {
            startGate?.resume()
            startGate = nil
            await waitForStart()
        }
        if holdsCancel {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cancelGate = continuation
            }
        }
        let wasRunning = state != .idle && state != .done
        state = .done
        resumeFinishWaiters()
        if wasRunning || role == .cloud {
            switch cancelReport {
            case .silent: break
            case .stopped: emit(.stopped)
            case .cleanupFailure: emit(.failed, errorCode: "ALI_CLEANUP")
            }
        }
    }

    // MARK: Script

    public func releaseStart() {
        startGate?.resume()
        startGate = nil
    }

    public func releaseCancel() {
        cancelGate?.resume()
        cancelGate = nil
    }

    public var isHoldingCancel: Bool { cancelGate != nil }

    public var isHoldingStart: Bool { startGate != nil }

    public func emitReady() { emit(.ready) }

    public func emitPartial(_ text: String) { emit(.partial, text: text) }

    /// A final nobody asked for (the local branch's own 300 s finish, or a cloud final out of turn).
    public func emitFinal(_ text: String?) {
        end(kind: .final, text: text, errorCode: nil)
    }

    public func emitFailure(_ code: String?) {
        end(kind: .failed, text: nil, errorCode: code)
    }

    public func emitStopped() {
        end(kind: .stopped, text: nil, errorCode: nil)
    }

    /// Any event under any session id, for the checks that other sessions' events are ignored.
    public func emitRaw(kind: SpeechInputEvent.Kind, text: String?, errorCode: String? = nil, sessionID: UUID) {
        guard let callback else { return }
        let event = SpeechInputEvent(
            sessionID: sessionID, sequence: sequence, observedMilliseconds: 0,
            kind: kind, text: text, errorCode: errorCode, modelConfidence: modelConfidence
        )
        sequence += 1
        callback(event)
    }

    /// Completes a manual finish.
    public func completeFinish(final text: String) {
        guard state == .finishing else { return }
        end(kind: .final, text: text, errorCode: nil)
    }

    public func completeFinish(failure code: String) {
        guard state == .finishing else { return }
        end(kind: .failed, text: nil, errorCode: code)
    }

    /// Takes this branch off the shared capture the way a backend does when it stops its own capture.
    public func stopCapture() async {
        await capture?.stop()
    }

    public func snapshotIdentities() -> [ObjectIdentifier] {
        (capture?.snapshotBuffers() ?? []).map { ObjectIdentifier($0) }
    }

    // MARK: Internals

    private func captureFailed(_ code: String) {
        captureFailures.append(code)
        guard state == .listening else { return }
        if role == .local {
            end(kind: .failed, text: nil, errorCode: "LOCAL_CAPTURE_FAILED")
        } else {
            end(kind: .failed, text: nil, errorCode: "ALI_STREAM_FAILED")
        }
    }

    private func end(kind: SpeechInputEvent.Kind, text: String?, errorCode: String?) {
        emit(kind, text: text, errorCode: errorCode)
        state = .done
        if let capture { Task { @MainActor in await capture.stop() } }
        resumeFinishWaiters()
    }

    private func emit(_ kind: SpeechInputEvent.Kind, text: String? = nil, errorCode: String? = nil) {
        guard let callback, let sessionID, !terminalEmitted else { return }
        switch kind {
        case .final, .failed, .stopped: terminalEmitted = true
        case .ready, .partial: break
        }
        let event = SpeechInputEvent(
            sessionID: sessionID, sequence: sequence, observedMilliseconds: Double(sequence),
            kind: kind, text: text, errorCode: errorCode, modelConfidence: modelConfidence
        )
        sequence += 1
        callback(event)
    }

    private func waitForStart() async {
        while state == .starting {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                startWaiters.append(continuation)
            }
        }
    }

    private func resumeStartWaiters() {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func resumeFinishWaiters() {
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// The hybrid backend under test, with what a check needs to see of it.
@_spi(Testing) @MainActor public final class HybridTestingSession {
    private let hybrid: HybridSpeechBackend
    public let source: HybridTestingSource
    public let local: HybridTestingBranch
    /// Nil: building the cloud branch throws (an invalid endpoint, say).
    public let cloud: HybridTestingBranch?
    public private(set) var sourceMakes = 0
    public private(set) var localMakes = 0
    public private(set) var cloudMakes = 0

    fileprivate init(
        clock: HybridClock,
        budget: HybridBudget,
        backlogIntervalMs: Int64,
        source: HybridTestingSource,
        local: HybridTestingBranch,
        cloud: HybridTestingBranch?,
        log: HybridTestingLog?,
        permission: @escaping @MainActor () async -> Bool,
        learningReceiver: (@MainActor @Sendable (EnhancementComparison) -> Void)?,
        preferCloudDrafts: Bool
    ) {
        self.source = source
        self.local = local
        self.cloud = cloud
        // The closures below are only called once `init` has finished, so the unowned counters are safe.
        var counter: HybridTestingSession?
        let route = HybridSpeechRoute.resolve(isVoiceNative: true, localRouteID: "qwen17-rolling", language: "zh")
        hybrid = HybridSpeechBackend(
            route: route!,
            budget: budget,
            clock: clock,
            makeSource: {
                counter?.sourceMakes += 1
                log?.note("source.make")
                return source
            },
            requestPermission: permission,
            branches: HybridSpeechBackend.Branches(
                makeLocal: { capture, permission in
                    counter?.localMakes += 1
                    log?.note("local.make")
                    local.attach(capture: capture, permission: permission)
                    return local
                },
                makeCloud: { capture, permission in
                    counter?.cloudMakes += 1
                    log?.note("cloud.make")
                    guard let cloud else { throw HybridTestingError.scripted("CLOUD_CONSTRUCTION") }
                    cloud.attach(capture: capture, permission: permission)
                    return cloud
                }
            ),
            backlogIntervalMs: backlogIntervalMs,
            learningReceiver: learningReceiver,
            preferCloudDrafts: preferCloudDrafts
        )
        counter = self
    }

    public var backend: any SpeechInputBackend { hybrid }

    public func noteReleaseAction(_ action: VoiceReleaseAction) { hybrid.noteReleaseAction(action) }

    public func revokeCloud(reason: HybridFinalSelector.CloudEnd) { hybrid.revokeCloud(reason: reason) }

    public var finalSource: HybridFinalSelector.Source? { hybrid.finalSource }

    public var counters: HybridCounters { hybrid.counters }

    public var phase: HybridFinalSelector.Phase { hybrid.phase }

    public var isQuiescent: Bool { hybrid.isQuiescent }

    public var permissionRequests: Int { hybrid.permissionRequests }

    public var droppedLocalEvents: Int { hybrid.droppedLocalEvents }

    public var droppedCloudEvents: Int { hybrid.droppedCloudEvents }

    public var timerArms: Int { hybrid.timerArms }

    public var hasArmedTimer: Bool { hybrid.hasArmedTimer }

    public var isMonitoringBacklog: Bool { hybrid.isMonitoringBacklog }

    public var localSnapshot: VoiceInputSnapshot? { hybrid.localSnapshotForTesting }

    public var cloudSnapshot: VoiceInputSnapshot? { hybrid.cloudSnapshotForTesting }

    public var hubExists: Bool { hybrid.captureHub != nil }

    public var hubIsRunning: Bool { hybrid.captureHub?.isRunning ?? false }

    public var hubIsStopped: Bool { hybrid.captureHub?.isStopped ?? false }

    public var hubPhysicalStarts: Int { hybrid.captureHub?.physicalStarts ?? 0 }

    public var hubCapturedMilliseconds: Int64 { hybrid.captureHub?.capturedMilliseconds() ?? 0 }

    public func hubSampleIndex(ofBufferAt index: Int) -> Int64? {
        hybrid.captureHub?.sampleIndex(ofBufferAt: index)
    }

    public func hubSnapshotIdentities() -> [ObjectIdentifier] {
        (hybrid.captureHub?.snapshot() ?? []).map { ObjectIdentifier($0) }
    }
}

@_spi(Testing) public enum HybridTestingFactory {
    /// The real hybrid backend with scripted branches. `cloud == nil` makes building the cloud branch throw.
    @MainActor public static func make(
        clock: HybridClock,
        budget: HybridBudget = .init(),
        backlogIntervalMs: Int64 = 250,
        source: HybridTestingSource,
        local: HybridTestingBranch,
        cloud: HybridTestingBranch?,
        log: HybridTestingLog? = nil,
        permission: @escaping @MainActor () async -> Bool,
        learningReceiver: (@MainActor @Sendable (EnhancementComparison) -> Void)? = nil,
        preferCloudDrafts: Bool = false
    ) -> HybridTestingSession {
        HybridTestingSession(
            clock: clock, budget: budget, backlogIntervalMs: backlogIntervalMs, source: source,
            local: local, cloud: cloud, log: log, permission: permission, learningReceiver: learningReceiver,
            preferCloudDrafts: preferCloudDrafts
        )
    }

    /// Cloud branches of any hybrid dictation still shutting down in the background.
    @MainActor public static var cloudDrainOutstanding: Int { HybridCloudDrain.outstanding }

    /// The line-break rule the hybrid backend applies to a cloud final.
    public static func normalizedLineBreaks(_ text: String) -> String {
        HybridSpeechBackend.normalizedLineBreaks(text)
    }

    /// The code filter of the hybrid backend's trace lines.
    public static func traceSafeCode(_ code: String?) -> String? {
        HybridSpeechBackend.traceSafeCode(code)
    }

    /// The backlog monitor's grid.
    public static func nextBacklogCheck(after now: Int64, origin: Int64, interval: Int64) -> Int64 {
        HybridSpeechBackend.nextBacklogCheck(after: now, origin: origin, interval: interval)
    }
}
