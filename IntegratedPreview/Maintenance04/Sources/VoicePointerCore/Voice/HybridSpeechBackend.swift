import Foundation

extension HybridSpeechBackend: SpeechCapturedDurationProviding {
    public var capturedDurationSeconds: Double {
        if let finalAudioDurationSeconds { return finalAudioDurationSeconds }
        return hub.map { Double($0.capturedMilliseconds()) / 1000 } ?? .nan
    }
}

// "用于增强本地识别": one dictation, two recognizers. The local Qwen branch drafts live exactly as on the local
// route alone; the Aliyun streaming branch hears the same audio (through `SharedCaptureHub`) and competes for
// the final text. `HybridFinalSelector` is the only decider; this file translates the branches' events into its
// inputs, performs its actions, and speaks to the coordinator as one ordinary `SpeechInputBackend`:
// one `.ready`, locally started drafts followed by live cloud drafts, and exactly one terminal event.
//
// What the coordinator must never see from the cloud branch: its `.failed` / `.stopped` (the coordinator cancels
// the whole dictation on a `.failed`), its sequence numbers or its session id. The cloud branch runs
// on a derived snapshot (its own session id, no hot words) and its callback is switched off before it is
// cancelled, so what a cancelled cloud says on its way out is dropped here.
//
// Written against protocols and the pure selector only; `HybridBackendFactory` wires the real backends.

/// How far a cloud branch's uplink has got: milliseconds of audio handed to its transport. The hybrid backend
/// compares it with the captured audio to drop a cloud branch that falls behind (K05's bounded fan-out).
@MainActor
protocol CloudUplinkReporting: AnyObject {
    var uplinkSentMilliseconds: Int64 { get }
}

/// Cloud branches cut loose from a hybrid dictation that are still shutting down in the background. The
/// coordinator runs the next dictation locally only while this is non-zero, so two cloud streams never overlap.
@MainActor
enum HybridCloudDrain {
    private static var running = 0

    /// Number of cloud branches that were cut loose and are still shutting down in the background.
    static var outstanding: Int { running }

    fileprivate static func begin() {
        running += 1
    }

    fileprivate static func end() {
        running = max(0, running - 1)
    }
}

@MainActor
final class HybridSpeechBackend: SpeechInputBackend, HybridSessionControlling, SpeechCaptureCancellationInvalidating, SpeechCaptureActivityProviding, SpeechPartialActivityProviding {
    private var finalAudioDurationSeconds: Double?
    var partialCount: Int { selector.counters.localPartials + selector.counters.cloudPartials }
    var hasAcceptedCaptureAudio: Bool { !(hub?.snapshot().isEmpty ?? true) }
    typealias CaptureMaker = @MainActor () -> any LocalSpeechCapture
    typealias PermissionAnswer = @MainActor () async -> Bool
    typealias CloudBranch = any SpeechInputBackend & CloudUplinkReporting

    /// How the two branches are built. Each gets its view of the shared capture and the one memoized
    /// permission answer, so the person is asked at most once and only when the local branch asks.
    struct Branches {
        let makeLocal: @MainActor (
            _ capture: @escaping CaptureMaker, _ permission: @escaping PermissionAnswer
        ) -> any SpeechInputBackend
        let makeCloud: @MainActor (
            _ capture: @escaping CaptureMaker, _ permission: @escaping PermissionAnswer
        ) throws -> CloudBranch
    }

    private typealias Input = HybridFinalSelector.Input
    private typealias Action = HybridFinalSelector.Action

    /// A local failure without a code, or a local branch that stopped without a result. The coordinator reads
    /// both exactly as it reads a failure with no code.
    private static let unknownLocalCode = "unknown"

    private let route: HybridSpeechRoute
    private let clock: HybridClock
    private let makeSource: CaptureMaker
    private let requestPermission: PermissionAnswer
    private let branches: Branches
    private let backlogIntervalMs: Int64
    private let learningReceiver: (@MainActor @Sendable (EnhancementComparison) -> Void)?
    private let teacherFinalReceiver: (@MainActor @Sendable (UUID, String) -> Void)?
    private var learningLocal: (text: String, at: Date, confidence: Double?)?
    private var learningReference: (text: String, at: Date)?
    private var selector: HybridFinalSelector
    private let preferCloudDrafts: Bool
    private let configuration: OnlineAPIConfiguration?
    private var uploadMode: Bool { configuration?.provider.isAliyun == false }
    private var uploadRequested = false
    private var uploadStartedMs: Int64?
    private var uploadExpiry: Task<Void, Never>?
    private var uploadLearningOnly = false
    private var uploadLogged = false
    private var captureOriginNanoseconds: UInt64 = 0
    private var cloudDraftActive = false
    private var latestLocalDraft: String?
    private var localFinalText: String?
    private var pendingUploadFinal: String?
    private var lastDisplayedDraft: String?
    private var displayedFinal: String?
    private var backToLocalCount = 0

    // Lifecycle.
    private var startUsed = false
    private var localStartInFlight = false
    private var localReadySeen = false
    /// The local branch has reported its result (final, failure or stop) for this dictation.
    private var localResultSeen = false
    /// A finish or cancel arrived while the local branch was still starting: the start is abandoned.
    private var stopRequested = false
    private var cancelRequested = false
    private var releaseDiscard = false
    private var snapshot: VoiceInputSnapshot?
    private var cloudSnapshot: VoiceInputSnapshot?
    private var callback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?

    // What the coordinator sees: our own numbering and one monotonic time line.
    private var startedAtMs: Int64 = 0
    private var nextSequence: UInt64 = 0
    private var lastObservedMs: Double = 0
    private var terminalEmitted = false

    // Branches and the shared capture.
    private var hub: SharedCaptureHub?
    private var local: (any SpeechInputBackend)?
    private var cloud: CloudBranch?
    private var cloudAttempted = false
    /// The cloud branch's callback is honoured. Cleared before the branch is cancelled.
    private var cloudLive = false
    /// The cloud branch was cut loose (at most once per dictation).
    private var cloudDetached = false
    private var cloudStartInFlight = false
    private var cloudStartedAtMs: Int64?
    private var cloudReadyNoted = false
    /// The one answer to the microphone question, asked inline (no extra hop) by the first branch that asks.
    private var permissionAnswer: Bool?
    private var permissionAsking = false
    private var permissionWaiters: [CheckedContinuation<Bool, Never>] = []
    /// The cloud branch's start runs on its own task, so `start()` returns at the local `.ready` (see `start`).
    private var cloudStartTask: Task<Void, Never>?
    /// That task exists but has not begun: `finish()` and `cancel()` let it run first (it then sees that the
    /// dictation moved on and starts nothing), so no cloud branch can come up after they return.
    private var cloudStartPending = false

    // The selector is fed one input at a time; inputs that arrive while a batch is performed wait here.
    private var pending: [(input: Input, cloudCode: String?)] = []
    private var performing = false

    // Work in flight.
    private var timerTask: Task<Void, Never>?
    private var timerGeneration: UInt64 = 0
    private var backlogTask: Task<Void, Never>?
    private var localFinishTask: Task<Void, Never>?
    private var localCancelTask: Task<Void, Never>?
    private var cloudFinishTask: Task<Void, Never>?
    private var pendingLocalOperations = 0
    private var finishTask: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?
    private var decisionWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// Which branch's text became the final; nil until then, and for a failure or a cancel.
    private(set) var finalSource: HybridFinalSelector.Source?

    // Counts for the self-tests; never text.
    private(set) var permissionRequests = 0
    private(set) var droppedLocalEvents = 0
    private(set) var droppedCloudEvents = 0
    private(set) var timerArms = 0

    init(
        route: HybridSpeechRoute,
        budget: HybridBudget = .init(),
        clock: HybridClock = .live,
        makeSource: @escaping CaptureMaker,
        requestPermission: @escaping PermissionAnswer,
        branches: Branches,
        backlogIntervalMs: Int64 = 250,
        learningReceiver: (@MainActor @Sendable (EnhancementComparison) -> Void)? = nil,
        teacherFinalReceiver: (@MainActor @Sendable (UUID, String) -> Void)? = nil,
        preferCloudDrafts: Bool? = nil,
        configuration: OnlineAPIConfiguration? = nil
    ) {
        self.route = route
        self.clock = clock
        self.makeSource = makeSource
        self.requestPermission = requestPermission
        self.branches = branches
        self.backlogIntervalMs = backlogIntervalMs
        self.learningReceiver = learningReceiver
        self.teacherFinalReceiver = teacherFinalReceiver
        self.configuration = configuration
        self.preferCloudDrafts = preferCloudDrafts ?? (UserDefaults.standard.string(forKey: "hybridDraftSource") != "local")
        var selectedBudget = budget
        if configuration?.provider.isAliyun == false {
            selectedBudget.totalMs = 60_000
            selectedBudget.localMs = 60_000
            selectedBudget.cloudTailMs = 300
        }
        self.selector = HybridFinalSelector(budget: selectedBudget)
    }

    // MARK: - Read-only state

    var counters: HybridCounters { selector.counters }

    var phase: HybridFinalSelector.Phase { selector.phase }

    var hasArmedTimer: Bool { timerTask != nil }

    var isMonitoringBacklog: Bool { backlogTask != nil }

    var captureHub: SharedCaptureHub? { hub }
    var cloudAudioUploaded: Bool { (cloud?.uplinkSentMilliseconds ?? 0) > 0 }

    var localSnapshotForTesting: VoiceInputSnapshot? { snapshot }

    var cloudSnapshotForTesting: VoiceInputSnapshot? { cloudSnapshot }

    // MARK: - SpeechInputBackend

    /// Quiet once the microphone is stopped, the local branch has settled, and the cloud branch has either
    /// ended or been cut loose (a cut-loose cloud holds neither the microphone nor the local worker).
    var isQuiescent: Bool {
        guard startUsed else { return true }
        if localStartInFlight || cloudStartPending { return false }
        if let hub, !hub.isStopped { return false }
        if pendingLocalOperations > 0 { return false }
        if let local, !local.isQuiescent { return false }
        if let cloud, !cloudDetached, !cloud.isQuiescent { return false }
        return true
    }

    /// The local branch's, unchanged (before the start: what the local backend reports before its start).
    var capabilities: SpeechInputCapabilities {
        local?.capabilities ?? SpeechInputCapabilities(
            deliveryKind: .transcriptStream, supportsPartialText: true, supportsHints: false
        )
    }

    func start(
        snapshot: VoiceInputSnapshot,
        onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void
    ) async throws {
        guard !startUsed else { throw BetaWorkerTransportError(description: "LOCAL_ALREADY_STARTED") }
        startUsed = true
        guard !cancelRequested else { throw CancellationError() }
        guard snapshot.selection.mode == .voiceNative else {
            throw BetaWorkerTransportError(description: "LOCAL_UNSUPPORTED_MODE")
        }
        guard HybridSpeechRoute.resolve(
            isVoiceNative: true, localRouteID: snapshot.selection.routeID, language: snapshot.selection.language,
            cloudProvider: configuration?.provider ?? .aliyunBailian
        ) != nil else {
            throw BetaWorkerTransportError(description: "HYBRID_ROUTE_INELIGIBLE")
        }

        self.snapshot = snapshot
        callback = onEvent
        startedAtMs = clock.nowMs()
        captureOriginNanoseconds = DispatchTime.now().uptimeNanoseconds
        cloudSnapshot = Self.cloudSnapshot(for: snapshot, configuration: configuration)
        RuntimeTrace.record("hybrid cloud mode=\(uploadMode ? "upload" : "stream")")
        let hub = SharedCaptureHub(makeSource: makeSource)
        hub.onDurationLimit = { [weak self] in self?.captureReachedDurationLimit() }
        self.hub = hub
        let permission: PermissionAnswer = { [weak self] in
            guard let self else { return false }
            return await self.sharedPermission()
        }

        // The local branch goes first and does everything the local route alone does, in the same order
        // (catalog, permission, microphone, `.ready`). Nothing of the cloud exists until it has started.
        let local = branches.makeLocal({ hub.makeView(.local) }, permission)
        self.local = local
        localStartInFlight = true
        var failure: (any Error)?
        do {
            try await local.start(snapshot: snapshot) { [weak self] event in
                self?.receiveLocal(event)
            }
        } catch {
            failure = error
        }
        if failure == nil, stopRequested || cancelRequested { failure = CancellationError() }
        if let failure {
            await abandonAfterLocalStartFailure()
            localStartInFlight = false
            resumeStartWaiters()
            throw failure
        }
        localStartInFlight = false
        resumeStartWaiters()
        // The coordinator reads `start()` returning as "listening" and cancels a dictation that was released
        // before that, so the cloud branch must not hold the start: it comes up on its own task, which first
        // checks that the dictation is still listening, not cancelled and not withdrawn.
        cloudStartPending = true
        cloudStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.cloudStartPending = false
            await self.startCloudBranch(permission: permission)
        }
    }

    func finish() async {
        if let finishTask {
            await finishTask.value
            return
        }
        if let cancelTask {
            await cancelTask.value
            return
        }
        guard startUsed, snapshot != nil, !cancelRequested else { return }
        if localStartInFlight, !localReadySeen {
            // As on the local route alone: a finish while the local branch is still starting abandons the start
            // (it throws), and nothing more is reported.
            stopRequested = true
            callback = nil
            let local = self.local
            let task = Task { @MainActor [weak self] in
                await local?.finish()
                await self?.waitForStartToSettle()
            }
            finishTask = task
            await task.value
            return
        }
        // The release is taken now, with this moment's clock reading; the waiting is shared by every caller.
        if !selector.isTerminal { feed(.release(discard: releaseDiscard)) }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.completeFinish()
        }
        finishTask = task
        await task.value
    }

    func invalidateCaptureForCancellation() {
        callback = nil
        cancelRequested = true
        learningLocal = nil; learningReference = nil
        uploadExpiry?.cancel(); uploadExpiry = nil
        if let snapshot { HybridUploadWork.finished(id: snapshot.sessionID) }
        stopBacklogMonitor()
        cancelTimer()
        hub?.requestStop()
        (local as? any SpeechCaptureCancellationInvalidating)?.invalidateCaptureForCancellation()
        (cloud as? any SpeechCaptureCancellationInvalidating)?.invalidateCaptureForCancellation()
    }

    func cancel() async {
        invalidateCaptureForCancellation()
        if let cancelTask {
            await cancelTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCancel()
        }
        cancelTask = task
        await task.value
    }

    // MARK: - HybridSessionControlling

    func noteReleaseAction(_ action: VoiceReleaseAction) {
        releaseDiscard = action == .cancel
    }

    func revokeCloud(reason: HybridFinalSelector.CloudEnd) {
        guard startUsed, snapshot != nil, !cancelRequested, !selector.isTerminal else { return }
        feed(.cloudEnded(reason))
    }

    // MARK: - Start

    private static func cloudSnapshot(for snapshot: VoiceInputSnapshot, configuration: OnlineAPIConfiguration?) -> VoiceInputSnapshot? {
        var sessionID = UUID()
        while sessionID == snapshot.sessionID { sessionID = UUID() }
        guard let selection = try? VoiceInputSelection(
            mode: .voiceNative, routeID: configuration?.routeID ?? HybridSpeechRoute.cloudRouteID, language: snapshot.selection.language
        ) else { return nil }
        // K09 L4: hot words stay on this Mac.
        return try? VoiceInputSnapshot(
            sessionID: sessionID, selection: selection, lexiconRevision: snapshot.lexiconRevision, localHotwords: [],
            onlineAPIConfiguration: configuration
        )
    }

    private func sharedPermission() async -> Bool {
        if let permissionAnswer { return permissionAnswer }
        if permissionAsking {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                permissionWaiters.append(continuation)
            }
        }
        // Asked inline, exactly as the local route alone asks. Capture startup can still suspend afterwards;
        // a release before the local `.ready` follows the starting-state cancellation path.
        permissionAsking = true
        permissionRequests += 1
        let answer = await requestPermission()
        permissionAnswer = answer
        permissionAsking = false
        let waiters = permissionWaiters
        permissionWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: answer) }
        return answer
    }

    private func startCloudBranch(permission: @escaping PermissionAnswer) async {
        guard !cancelRequested, !cloudDetached, selector.phase == .listening,
              let hub, let cloudSnapshot else {
            noteCloudNeverStarted()
            return
        }
        cloudAttempted = true
        let cloud: CloudBranch
        do {
            cloud = try branches.makeCloud({ hub.makeView(.cloud) }, permission)
        } catch {
            feed(.cloudEnded(.startFailed))
            return
        }
        self.cloud = cloud
        cloudLive = true
        cloudStartInFlight = true
        cloudStartedAtMs = clock.nowMs()
        var started = true
        do {
            try await cloud.start(snapshot: cloudSnapshot) { [weak self] event in
                self?.receiveCloud(event)
            }
        } catch {
            started = false
        }
        cloudStartInFlight = false
        guard started else {
            if cloudLive { feed(.cloudEnded(.startFailed)) }
            return
        }
        if cloudLive, !cancelRequested, selector.phase == .listening, !uploadMode {
            startBacklogMonitor(cloud)
        }
    }

    /// The cloud never got going (the dictation moved on first, or its snapshot could not be made): the selector
    /// still counts it as running until told.
    private func noteCloudNeverStarted() {
        guard !selector.isTerminal, selector.counters.cloudEnd == nil else { return }
        feed(.cloudEnded(.startFailed))
    }

    /// The local branch did not start: nothing else may keep running, and the local error is the one thrown.
    private func abandonAfterLocalStartFailure() async {
        if !selector.isTerminal { feed(.cancel) }
        stopBacklogMonitor()
        cancelTimer()
        await hub?.stop()
        await settleLocal(cancelling: true)
        detachCloudIfStillRunning()
        callback = nil
    }

    private func waitForStartToSettle() async {
        while localStartInFlight {
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

    // MARK: - Finish / cancel

    private func completeFinish() async {
        await hub?.stop()
        await joinPendingCloudStart()
        await waitForDecision()
        await settleLocal(cancelling: false)
        detachCloudIfStillRunning()
    }

    private func runCancel() async {
        guard startUsed, snapshot != nil else { return }
        if localStartInFlight, !localReadySeen {
            // The start owns the cleanup while the local branch is starting; it throws once the branch gives up.
            stopRequested = true
            await local?.cancel()
            await waitForStartToSettle()
            return
        }
        // After the decision a cancel is no input for the selector; it only makes sure everything is quiet.
        if !selector.isTerminal { feed(.cancel) }
        stopBacklogMonitor()
        cancelTimer()
        await hub?.stop()
        resumeDecisionWaiters()
        await joinPendingCloudStart()
        await settleLocal(cancelling: true)
        detachCloudIfStillRunning()
    }

    /// A cloud start task that has not begun runs now: it finds the dictation released or cancelled and starts
    /// nothing. One that has begun is not waited for: its branch is cut loose like any other.
    private func joinPendingCloudStart() async {
        guard cloudStartPending, let task = cloudStartTask else { return }
        await task.value
    }

    private func waitForDecision() async {
        while !selector.isTerminal {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                decisionWaiters.append(continuation)
            }
        }
    }

    private func resumeDecisionWaiters() {
        let waiters = decisionWaiters
        decisionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Waits until the local branch is quiet. Everything the selector asked of it is awaited; a local branch
    /// that ended by itself (its own 300 s finish, or a failure) is joined through its own finish (or cancel).
    private func settleLocal(cancelling: Bool) async {
        if let task = localCancelTask { await task.value }
        if let task = localFinishTask { await task.value }
        guard let local, !local.isQuiescent else { return }
        pendingLocalOperations += 1
        if cancelling {
            await local.cancel()
        } else {
            await local.finish()
        }
        pendingLocalOperations -= 1
    }

    /// A cloud branch that is still running when the dictation is over is cut loose, never waited for.
    private func detachCloudIfStillRunning() {
        if uploadMode, uploadLearningOnly { return }
        guard let cloud, !cloudDetached, !cloud.isQuiescent else { return }
        detachCloud(reason: .cancelled, phase: "finishing", code: nil, traced: false)
    }

    private func captureReachedDurationLimit() {
        guard startUsed, !cancelRequested, !selector.isTerminal else { return }
        feed(.release(discard: releaseDiscard))
    }

    // MARK: - Branch events

    private func receiveLocal(_ event: SpeechInputEvent) {
        guard let snapshot, event.sessionID == snapshot.sessionID, !cancelRequested else {
            droppedLocalEvents += 1
            return
        }
        switch event.kind {
        case .ready:
            localReadySeen = true
            feed(.localReady)
        case .partial:
            latestLocalDraft = event.text ?? ""
            feed(.localPartial(text: event.text ?? ""))
        case .final:
            localResultSeen = true
            localFinalText = event.text ?? ""
            if uploadMode, !HybridUploadPolicy.shouldUpload(localText: localFinalText), uploadStartedMs == nil {
                feed(.cloudEnded(.blankFinal))
            }
            if !(event.text ?? "").isEmpty { DictationHealthObservation.success(snapshot.selection) }
            if learningReceiver != nil {
                learningLocal = (event.text ?? "", Date(timeIntervalSince1970: Double(clock.nowMs()) / 1000), event.modelConfidence)
            }
            feed(.localFinal(text: event.text ?? ""))
            if uploadMode, let text = pendingUploadFinal {
                pendingUploadFinal = nil
                let normalized = HybridUploadPolicy.text(text, matching: localFinalText ?? "")
                learningReference = learningReference.map { (normalized, $0.at) }
                feed(.cloudFinal(text: normalized))
            }
            if uploadMode, uploadRequested { startCloudFinish() }
        case .failed:
            localResultSeen = true
            DictationHealthObservation.failure(snapshot.selection, code: event.errorCode)
            feed(.localFailed(code: event.errorCode ?? Self.unknownLocalCode))
        case .stopped:
            localResultSeen = true
            feed(.localFailed(code: Self.unknownLocalCode))
        }
    }

    private func receiveCloud(_ event: SpeechInputEvent) {
        guard cloudLive, !cancelRequested, let cloudSnapshot, event.sessionID == cloudSnapshot.sessionID else {
            droppedCloudEvents += 1
            return
        }
        switch event.kind {
        case .ready:
            if !cloudReadyNoted {
                cloudReadyNoted = true
                let handshake = Self.elapsed(from: cloudStartedAtMs ?? startedAtMs, to: clock.nowMs())
                if let ali = cloud as? AliSpeechBackend {
                    let timing = ali.readyTiming
                    let worker = timing.map { Int($0.workerMs) } ?? -1
                    let connect = timing?.connectMs.map { Int($0) } ?? -1
                    let taskStart = timing?.taskStartMs.map { Int($0) } ?? -1
                    RuntimeTrace.record("hybrid cloud ready handshakeMs=\(handshake) audibleWaitMs=\(ali.audibleWaitMs) keyReadMs=\(ali.credentialReadMs) workerMs=\(worker) connectMs=\(connect) taskStartMs=\(taskStart) path=\(timing?.path ?? "system")")
                } else {
                    RuntimeTrace.record("hybrid cloud ready handshakeMs=\(handshake) path=system")
                }
            }
            feed(.cloudReady)
        case .partial:
            feed(.cloudPartial)
            if preferCloudDrafts, cloudLive, cloudReadyNoted, selector.phase == .listening,
               counters.cloudEnd == nil, let text = event.text, !text.isEmpty {
                if !cloudDraftActive {
                    cloudDraftActive = true
                    RuntimeTrace.record("hybrid draft source=cloud switchAtMs=\(Self.elapsed(from: startedAtMs, to: clock.nowMs())) backToLocal=\(backToLocalCount)")
                }
                showDraft(Self.normalizedLineBreaks(text), source: .cloudEnhancement)
            }
        case .final:
            if !(event.text ?? "").isEmpty { DictationHealthObservation.success(cloudSnapshot.selection) }
            let referenceText = HybridUploadPolicy.text(Self.normalizedLineBreaks(event.text ?? ""),
                matching: localFinalText ?? latestLocalDraft ?? "")
            // Index every qualified FINAL teacher utterance, even when local recognition failed.
            // It is sent to the strict observer only as transient in-memory text.
            if let snapshot { teacherFinalReceiver?(snapshot.sessionID, referenceText) }
            if learningReceiver != nil {
                learningReference = (referenceText, Date(timeIntervalSince1970: Double(clock.nowMs()) / 1000))
            }
            if uploadMode, !localResultSeen {
                pendingUploadFinal = referenceText
                return
            }
            if uploadMode, uploadLearningOnly {
                if HybridUploadPolicy.shouldUpload(localText: referenceText) { deliverLearning(); logUpload(.learnOnly) }
                else { logUpload(.failed) }
                finishUploadLease()
                return
            }
            feed(.cloudFinal(text: referenceText))
            // A late callback can run before the deadline timer. The selector then closes correction
            // while handling this very input; preserve its result for learning as well.
            if uploadMode, uploadLearningOnly {
                if HybridUploadPolicy.shouldUpload(localText: referenceText) { deliverLearning(); logUpload(.learnOnly) }
                else { logUpload(.failed) }
                finishUploadLease()
            }
        case .failed:
            DictationHealthObservation.failure(cloudSnapshot.selection, code: event.errorCode)
            if uploadMode { logUpload(.failed) }
            if uploadLearningOnly { finishUploadLease(); return }
            let reason: HybridFinalSelector.CloudEnd = cloudStartInFlight
                ? .startFailed : .forCloudErrorCode(event.errorCode)
            feed(.cloudEnded(reason), cloudCode: Self.traceSafeCode(event.errorCode))
        case .stopped:
            if uploadMode { logUpload(.failed) }
            if uploadLearningOnly { finishUploadLease(); return }
            feed(.cloudEnded(cloudStartInFlight ? .startFailed : .cancelled))
        }
    }

    /// `InlineDraftTransaction` refuses a carriage return, so a cloud final carrying one would be dropped at
    /// delivery (nothing written, no Return pressed). Line breaks become `\n`, the local recognizer's own form.
    nonisolated static func normalizedLineBreaks(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        var scalars = String.UnicodeScalarView()
        var afterCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                scalars.append("\n")
                afterCarriageReturn = true
                continue
            }
            if scalar == "\n", afterCarriageReturn {
                afterCarriageReturn = false
                continue
            }
            afterCarriageReturn = false
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Only the finite upper-case code vocabulary (`ALI_*`, `CREDENTIAL_*`) reaches the trace.
    nonisolated static func traceSafeCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let allowed = code.unicodeScalars.allSatisfy {
            (0x41...0x5A).contains($0.value) || (0x30...0x39).contains($0.value) || $0.value == 0x5F
        }
        return allowed && (1...64).contains(code.unicodeScalars.count) ? code : "other"
    }

    // MARK: - Selector

    private func feed(_ input: Input, cloudCode: String? = nil) {
        pending.append((input, cloudCode))
        guard !performing else { return }
        performing = true
        while !pending.isEmpty {
            let next = pending.removeFirst()
            let wasListening = selector.phase == .listening
            let wasTerminal = selector.isTerminal
            let actions = selector.handle(next.input, nowMs: clock.nowMs())
            perform(actions, wasListening: wasListening, cloudCode: next.cloudCode)
            if !wasTerminal, selector.isTerminal { becameTerminal() }
        }
        performing = false
    }

    private func perform(_ actions: [Action], wasListening: Bool, cloudCode: String?) {
        for action in actions {
            switch action {
            case .emitReady:
                emit(.ready)
            case .emitPartial(let text):
                if !cloudDraftActive { showDraft(text, source: .local) }
            case .emitFinal(let text, let source):
                finalAudioDurationSeconds = capturedDurationSeconds
                if source == .cloud, counters.cloudFinalAtMs != nil { deliverLearning(); if uploadMode { logUpload(.correct) } }
                if !uploadLearningOnly { learningLocal = nil; learningReference = nil }
                finalSource = source
                cancelTimer()
                stopBacklogMonitor()
                displayedFinal = text
                emit(.final, text: text, source: source == .cloud ? .cloudEnhancement : .local)
                recordDecision(source: source.rawValue)
            case .emitFailure(let code):
                cancelTimer()
                stopBacklogMonitor()
                recordDecision(source: "none")
                emit(.failed, errorCode: code)
            case .stopCapture:
                stopBacklogMonitor()
                hub?.requestStop()
            case .finishLocal:
                startLocalFinish()
            case .finishCloud:
                startCloudFinish()
            case .cancelLocal:
                startLocalCancel()
            case .cancelCloud(let reason):
                if uploadMode, uploadStartedMs != nil, !cancelRequested, !releaseDiscard,
                   HybridUploadPolicy.shouldUpload(localText: localFinalText),
                   (reason == .tailTimeout || reason == .deadline), learningReceiver != nil {
                    uploadLearningOnly = true
                    cloudDetached = true // No microphone/local worker is held; only the bounded HTTP job remains.
                    if let snapshot {
                        HybridUploadWork.retain(id: snapshot.sessionID) { [weak self] in
                            guard let self else { return }
                            self.uploadLearningOnly = false
                            self.invalidateCaptureForCancellation()
                            Task { await self.cloud?.cancel(); self.hub?.discardSnapshot() }
                        }
                    }
                    continue
                }
                let phase: String
                switch selector.phase {
                case .listening: phase = "listening"
                case .finishing: phase = "finishing"
                case .decided, .cancelled: phase = wasListening ? "listening" : "finishing"
                }
                detachCloud(reason: reason, phase: phase, code: cloudCode, traced: true)
            case .wake(let atMs):
                armTimer(at: atMs)
            }
        }
    }

    private func becameTerminal() {
        if !uploadLearningOnly { learningLocal = nil; learningReference = nil }
        cancelTimer()
        stopBacklogMonitor()
        resumeDecisionWaiters()
    }

    private func startLocalFinish() {
        guard let local, localFinishTask == nil else { return }
        pendingLocalOperations += 1
        let hub = self.hub
        localFinishTask = Task { @MainActor [weak self] in
            await hub?.stop()
            await local.finish()
            guard let self else { return }
            self.pendingLocalOperations -= 1
            // Nothing bounds the local branch once the cloud is out, so a finish that came back without a result
            // must not leave the dictation waiting: it counts as a local failure.
            if !self.localResultSeen, !self.cancelRequested, !self.selector.isTerminal {
                self.feed(.localFailed(code: Self.unknownLocalCode))
            }
        }
    }

    private func startLocalCancel() {
        guard let local, localCancelTask == nil else { return }
        pendingLocalOperations += 1
        localCancelTask = Task { @MainActor [weak self] in
            await local.cancel()
            self?.pendingLocalOperations -= 1
        }
    }

    private func startCloudFinish() {
        guard let cloud, cloudLive, cloudFinishTask == nil else { return }
        if uploadMode {
            guard capturedDurationSeconds <= 60 else {
                feed(.cloudEnded(.deadline))
                return
            }
            // No draft yet: wait for the local final before allowing a file request.
            if !HybridUploadPolicy.shouldUpload(localText: localFinalText ?? latestLocalDraft) {
                uploadRequested = true
                return
            }
            uploadRequested = true
            uploadStartedMs = clock.nowMs()
            uploadExpiry = Task { @MainActor [weak self] in
                guard let origin = self?.captureOriginNanoseconds else { return }
                let age = Double(DispatchTime.now().uptimeNanoseconds - origin) / 1_000_000_000
                try? await Task.sleep(for: .seconds(min(45, max(0, 60 - age))))
                guard !Task.isCancelled, let self else { return }
                self.logUpload(.failed)
                self.uploadLearningOnly = false
                self.learningLocal = nil; self.learningReference = nil
                self.cloudLive = false
                if !self.selector.isTerminal { self.feed(.cloudEnded(.deadline)) }
                await self.cloud?.cancel()
                if self.pendingLocalOperations == 0 { self.hub?.discardSnapshot() }
                if let snapshot = self.snapshot { HybridUploadWork.finished(id: snapshot.sessionID) }
            }
        }
        let hub = self.hub
        cloudFinishTask = Task { @MainActor [self] in
            await hub?.stop()
            await cloud.finish()
            if uploadMode {
                uploadExpiry?.cancel(); uploadExpiry = nil
                if uploadLearningOnly { logUpload(.failed); finishUploadLease() }
            }
        }
    }

    private func deliverLearning() {
        guard let snapshot, let local = learningLocal, let reference = learningReference else { return }
        learningReceiver?(EnhancementComparison(roundID: snapshot.sessionID,
            localText: local.text, referenceText: reference.text, localAt: local.at, referenceAt: reference.at,
            localConfidence: local.confidence, source: .onlineAPI,
            audio: nil, snapshot: snapshot))
        learningLocal = nil; learningReference = nil
    }

    private func logUpload(_ use: HybridUploadPolicy.Use) {
        guard uploadMode, !uploadLogged, let began = uploadStartedMs else { return }
        uploadLogged = true
        let measured = (cloud as? GroqSpeechBackend)?.requestMilliseconds ?? 0
        let requestMs = measured > 0 ? measured : Self.elapsed(from: began, to: clock.nowMs())
        RuntimeTrace.record("hybrid cloud upload uploadMs=\(requestMs) resultMs=\(Self.elapsed(from: counters.releasedAtMs ?? began, to: clock.nowMs())) used=\(use.rawValue)")
    }

    private func finishUploadLease() {
        uploadLearningOnly = false; cloudLive = false
        learningLocal = nil; learningReference = nil
        uploadExpiry?.cancel(); uploadExpiry = nil
        if selector.isTerminal, pendingLocalOperations == 0 { hub?.discardSnapshot() }
        if let snapshot { HybridUploadWork.finished(id: snapshot.sessionID) }
    }

    /// The cloud branch leaves the dictation: its callback is switched off first, then it is cancelled in the
    /// background (also when it already stopped itself), counted in `HybridCloudDrain` until it is quiet.
    private func detachCloud(reason: HybridFinalSelector.CloudEnd, phase: String, code: String?, traced: Bool) {
        guard !cloudDetached else { return }
        cloudDetached = true
        cloudLive = false
        if cloudDraftActive {
            cloudDraftActive = false
            backToLocalCount += 1
            if selector.phase == .listening, !cancelRequested, let text = latestLocalDraft {
                RuntimeTrace.record("hybrid draft source=local switchAtMs=\(Self.elapsed(from: startedAtMs, to: clock.nowMs())) backToLocal=\(backToLocalCount)")
                showDraft(text, source: .local)
            }
        }
        stopBacklogMonitor()
        let uplink = cloud?.uplinkSentMilliseconds ?? 0
        if traced, cloudAttempted || reason != .cancelled {
            RuntimeTrace.record(
                "hybrid cloud ended phase=\(phase) reason=\(reason.rawValue) code=\(code ?? "none") " +
                "atMs=\(Self.elapsed(from: startedAtMs, to: clock.nowMs())) uplinkMs=\(uplink)"
            )
        }
        guard let cloud else { return }
        HybridCloudDrain.begin()
        let clock = self.clock
        let began = clock.nowMs()
        Task { @MainActor in
            await cloud.cancel()
            HybridCloudDrain.end()
            RuntimeTrace.record(
                "hybrid drain done ms=\(Self.elapsed(from: began, to: clock.nowMs())) " +
                "outstanding=\(HybridCloudDrain.outstanding)"
            )
        }
    }

    // MARK: - Timer and backlog monitor

    /// The single deadline timer: a new moment replaces the armed one; it feeds `.tick` with the clock's
    /// reading when it fires.
    private func armTimer(at target: Int64) {
        timerTask?.cancel()
        timerGeneration &+= 1
        timerArms += 1
        let generation = timerGeneration
        let clock = self.clock
        timerTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleepUntilMs(target)
            } catch {
                return
            }
            guard let self, self.timerGeneration == generation, !self.selector.isTerminal else { return }
            self.timerTask = nil
            self.feed(.tick)
        }
    }

    private func cancelTimer() {
        timerGeneration &+= 1
        timerTask?.cancel()
        timerTask = nil
    }

    /// While listening, every `backlogIntervalMs` on the clock, the captured audio and the cloud uplink go to
    /// the selector, which drops a cloud branch that trails by more than the budget.
    private func startBacklogMonitor(_ cloud: CloudBranch) {
        guard backlogTask == nil, backlogIntervalMs > 0 else { return }
        let clock = self.clock
        let interval = backlogIntervalMs
        let origin = clock.nowMs()
        backlogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let target = Self.nextBacklogCheck(after: clock.nowMs(), origin: origin, interval: interval)
                do {
                    try await clock.sleepUntilMs(target)
                } catch {
                    return
                }
                guard let self, self.backlogTask != nil, self.cloudLive, !self.cancelRequested,
                      self.selector.phase == .listening, let hub = self.hub else { return }
                self.feed(.backlog(capturedMs: hub.capturedMilliseconds(), consumedMs: cloud.uplinkSentMilliseconds))
            }
        }
    }

    private func stopBacklogMonitor() {
        backlogTask?.cancel()
        backlogTask = nil
    }

    /// The next point of the monitor's grid strictly after `now` (grid: origin + k * interval, k >= 1).
    nonisolated static func nextBacklogCheck(after now: Int64, origin: Int64, interval: Int64) -> Int64 {
        guard interval > 0 else { return Int64.max }
        guard now >= origin else { return saturatingAdd(origin, interval) }
        let steps = (now - origin) / interval + 1
        let (offset, overflow) = steps.multipliedReportingOverflow(by: interval)
        return overflow ? Int64.max : saturatingAdd(origin, offset)
    }

    // MARK: - Emission and diagnostics

    private func showDraft(_ text: String, source: SpeechTranscriptSource) {
        lastDisplayedDraft = text
        emit(.partial, text: text, source: source)
    }

    /// The coordinator reports what survived lexicon correction and projection.
    /// No text leaves RAM; diagnostics compare exactly what the HUD displayed.
    func noteDisplayedDraft(_ text: String) { lastDisplayedDraft = text }
    func noteDisplayedFinal(_ text: String) { displayedFinal = text }

    private func emit(
        _ kind: SpeechInputEvent.Kind,
        text: String? = nil,
        errorCode: String? = nil,
        source: SpeechTranscriptSource? = nil
    ) {
        guard let callback, let snapshot, !terminalEmitted else { return }
        switch kind {
        case .final, .failed, .stopped:
            terminalEmitted = true
        case .ready, .partial:
            break
        }
        let observed = max(lastObservedMs, Double(Self.elapsed(from: startedAtMs, to: clock.nowMs())))
        lastObservedMs = observed
        let event = SpeechInputEvent(
            sessionID: snapshot.sessionID,
            sequence: nextSequence,
            observedMilliseconds: observed,
            kind: kind,
            text: text,
            errorCode: errorCode,
            transcriptSource: source
        )
        nextSequence += 1
        callback(event)
    }

    /// The one diagnostics line per decided dictation: counts, lengths, milliseconds and finite reasons only.
    private func recordDecision(source: String) {
        let c = selector.counters
        let released = c.releasedAtMs
        func since(_ moment: Int64?, _ base: Int64?) -> String {
            guard let moment, let base else { return "none" }
            return String(Self.elapsed(from: base, to: moment))
        }
        let decided = c.decidedAtMs ?? clock.nowMs()
        let releaseToDecision = released.map { Self.elapsed(from: $0, to: decided) } ?? 0
        let draftToFinal = lastDisplayedDraft.flatMap { draft in displayedFinal.map { HybridTextDifference.bucket(draft, $0).rawValue } } ?? "na"
        RuntimeTrace.record(
            "hybrid final source=\(source) reason=\(c.reason?.rawValue ?? "none") " +
            "releaseToLocalFinalMs=\(since(c.localFinalAtMs, released)) " +
            "releaseToCloudFinalMs=\(since(c.cloudFinalAtMs, released)) " +
            "releaseToDecisionMs=\(releaseToDecision) localPartials=\(c.localPartials) cloudPartials=\(c.cloudPartials) " +
            "firstLocalPartialMs=\(since(c.firstLocalPartialAtMs, startedAtMs)) " +
            "firstCloudPartialMs=\(since(c.firstCloudPartialAtMs, startedAtMs)) " +
            "localUTF16=\(c.localUTF16 ?? 0) cloudUTF16=\(c.cloudUTF16 ?? 0) diffBucket=\(c.diffBucket.rawValue) " +
            "maxBacklogMs=\(c.maxBacklogMs) lateDropped=\(c.lateDropped) uplinkMs=\(cloud?.uplinkSentMilliseconds ?? 0) draftToFinal=\(draftToFinal)"
        )
    }

    private nonisolated static func elapsed(from start: Int64, to end: Int64) -> Int64 {
        let (difference, overflow) = end.subtractingReportingOverflow(start)
        if overflow { return end > start ? Int64.max : 0 }
        return max(difference, 0)
    }

    private nonisolated static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        if overflow { return b > 0 ? Int64.max : Int64.min }
        return sum
    }
}
