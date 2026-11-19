import AppKit
import ApplicationServices
import Foundation

public enum VoicePointerRuntimeStatus: Sendable, Equatable {
    case idle
    case resolvingTarget
    case listening
    case failed(String)

    public var title: String {
        switch self {
        case .idle: return "就绪"
        case .resolvingTarget: return "正在定位输入框"
        case .listening: return "正在听写"
        case .failed(let message): return message
        }
    }
}

@MainActor
public final class VoicePointerCoordinator {
    public typealias StatusHandler = @MainActor (VoicePointerRuntimeStatus, CGPoint?) -> Void
    public typealias OutcomeHandler = @MainActor (ComposerActionOutcome, VoiceReleaseAction, ComposerActionFeedback) -> Void
    public typealias TranscriptHandler = @MainActor @Sendable (SpeechInputEvent) -> Void
    public typealias DictationHandler = @MainActor (DictationRecord) -> Void

    public private(set) var status: VoicePointerRuntimeStatus = .idle
    public private(set) var lastIssuePresentation: VoiceIssuePresentation?
    public var currentSessionID: UUID? { sessionSnapshot?.sessionID }
    public func hasCancelContent(expectedSessionID: UUID?) async -> Bool {
        guard let expectedSessionID, currentSessionID == expectedSessionID, let session = composerSession else { return false }
        let hasContent = await composerActionExecutor.hasCancelContent(session: session)
        return !Task.isCancelled && currentSessionID == expectedSessionID && composerSession == session && hasContent
    }
    private let focusEngine: SmartFocusEngine
    private let focusQueue = DispatchQueue(label: "com.kenyu.VoicePointer.focus", qos: .userInitiated)
    private let focusWorker = AXSerialWorker()
    private let keyboardSender: (any KeyboardEventSending)?
    private let keyboardOwnership: KeyboardOwnershipManager
    public nonisolated let operationSafety = VoiceOperationSafety()
    private let composerActionExecutor: any ComposerActionExecuting
    private let outcomeHandler: OutcomeHandler
    private let statusHandler: StatusHandler
    private var stateMachine = VoiceStateMachine()
    private var focusTask: Task<Void, Never>?
    private var focusCancellationToken: FocusCancellationToken?
    private var watchdogTask: Task<Void, Never>?
    private var controller: (any VoiceShortcutControlling)?
    private var activeBackend: (any SpeechInputBackend)?
    private var backendReleased = false
    private var backendReady = false
    private var backendFailure: String?
    private var backendPartialCount = 0

    private var canSendWithoutFinal: Bool {
        !sessionHasNoTarget && sessionSnapshot?.selection.mode == .voiceNative && SilentSendPolicy.qualifies(
            partials: max(backendPartialCount, (activeBackend as? any SpeechPartialActivityProviding)?.partialCount ?? 0),
            peak: GestureSpeechActivity.shared.loudestPeak())
    }

    /// Never create a second session or issue a second Return. The original
    /// target-bound worker validates focus before consuming this one-shot hint.
    public func expeditePendingDoubaoSend() -> Bool {
        guard releaseGeneration != nil,
              sessionSnapshot?.selection.mode == .doubao,
              let current = composerSession, !current.isCancelled else { return false }
        return current.requestExpeditedSend()
    }

    public func preemptPendingSend() {
        retireCancelledSession(performDownSwipe: false)
        RuntimeTrace.record("composer action outcome=sendPreempted")
        let feedback = feedbackForOutcome(.sendPreempted, action: .send)
        outcomeHandler(.sendPreempted, .send, feedback)
        publishOutcome(feedback)
        // The warning is already handed to the HUD; release admission for the queued gesture.
        status = .idle
    }
    private var sessionCloudConsent: Set<String> = []
    /// "用于增强本地识别" for this dictation, frozen in `gestureBegan`...
    private var sessionEnhanceLocal = false
    /// ...and withdrawn since: no cloud branch is built, or kept, for the rest of this dictation.
    private var sessionEnhanceWithdrawn = false
    private var sessionAliyunEndpoint = AliEndpoint.defaultURLString
    private var sessionOnlineAPIConfiguration: OnlineAPIConfiguration?
    private var backendGate: SpeechSessionEventGate?
    private var sessionSnapshot: VoiceInputSnapshot?
    private var operationToken: OperationCancellationToken?
    private var composerSession: ComposerActionSession?
    private var sessionHasNoTarget = false {
        didSet { if !sessionHasNoTarget { sessionNoTargetContext = nil } }
    }
    private var sessionNoTargetContext: ComposerNoInputFieldContext?
    private var sessionPracticeSink: (@MainActor @Sendable (UUID, String) -> Void)?
    private var lastLocation: CGPoint?
    private var operationGeneration: UInt64 = 0
    private var feedbackSessionID = UUID()
    private var feedbackPresentationGate = VoiceIssuePresentationGate()
    private let localWorkerPool = LocalWorkerPool()
    private var finalTranscript: String?
    private var sessionOmitTerminalPeriod = true
    private var terminalPrefix = ""
    private var terminalRemoved: String?
    private var terminalReceipt: (baseline: KeptDictationBaseline, mark: String, at: UInt64)?
    private var releaseGeneration: UInt64?
    private var gestureStartedAt: UInt64 = 0
    // T13: UI cancellation retires a session immediately; its resources keep their original owner until drained.
    private var cancelledResourceTasks: [UUID: Task<Void, Never>] = [:]
    private var terminating = false
    /// Generation whose Doubao dictation was cancelled because the target app moved focus by itself
    /// (it was still frontmost). Its release shows "请点一下输入框" instead of ending silently.
    private var targetDriftGeneration: UInt64?
    private let transcriptHandler: TranscriptHandler
    // K06: where the gate handle, identity and current-call permissions come from. Nil (the app passes
    // none yet) is a denial, never an admission.
    private let cloudAdmissionInputs: CloudAdmissionInputsProvider?
    private var inlinePump: InlineDraftPump?
    // Personal lexicon: frozen with the dictation, applied to what P2/P3 recognizers write. The Doubao
    // keyboard route never sees it: the app does not get that text before it is inserted.
    private var sessionCorrector = DictationCorrector.none
    private var rawFinalTranscript: String?
    private var finalTranscriptSource: SpeechTranscriptSource?
    private var finalHotwordEcho = false
    private var teacherResumeTask: Task<Void, Never>?
    private var finalLexiconHits: [LexiconSnapshot.Hit] = []
    private let dictationHandler: DictationHandler?
    private let memoryHandler: (@MainActor (DictationRecord, String, Bool) -> Void)?
    /// Learning from the person's own corrections: told when a dictation was kept and when the next gesture
    /// began (nil: not wired, nothing is observed).
    private let learningObserver: (any DictationEditObserving)?
    private let doubaoLearningAudio: (any DoubaoLearningAudioProviding)?
    private var doubaoLearningSelection: VoiceInputSelection?
    private var storedDoubaoLearning: DoubaoLearningRuntime?
    // Build on the MainActor in a method instead of a stored lazy default expression. The local
    // actor and the main-actor learning runtime have distinct isolation and explicit dependencies.
    private var doubaoLearning: DoubaoLearningRuntime? {
        if let storedDoubaoLearning { return storedDoubaoLearning }
        guard let audio = doubaoLearningAudio else { return nil }
        let recognizer = DoubaoOfflineRecognizer(pool: localWorkerPool, loadProfiles: { try BetaCatalog.load() })
        let runtime = DoubaoLearningRuntime(audio: audio,
            recognize: { audio, selection in try await recognizer.recognize(audio, selection: selection) },
            cancelRecognition: { await recognizer.cancel() },
            trace: { RuntimeTrace.record($0) },
            receive: { [weak self] comparison, baseline in
                self?.learningObserver?.doubaoEnhancementCompared(comparison, baseline: baseline)
            })
        storedDoubaoLearning = runtime
        return runtime
    }
    public func doubaoLearningAuthorizationChanged(selection: VoiceInputSelection, learningEnabled: Bool) {
        if doubaoLearningSelection != selection { doubaoLearning?.cancel(); doubaoLearningSelection = selection }
        doubaoLearning?.authorize(isDoubao: selection.mode == .doubao, learningEnabled: learningEnabled)
    }
    private var speechBackendFactoryForTesting: (@MainActor (VoiceInputSnapshot) -> (any SpeechInputBackend)?)?
#if VOICEPOINTER_TEST_ENTRY
    private var watchdogDelaySecondsForTesting: TimeInterval?
    private var releaseWaitTimeoutNanosecondsForTesting: UInt64?
    @_spi(Testing) public private(set) var isReleaseWaitInProgressForTesting = false

#endif
    @_spi(Testing)
    public func setSpeechBackendFactoryForTesting(
        _ factory: @escaping @MainActor (VoiceInputSnapshot) -> (any SpeechInputBackend)?
    ) {
        guard case .idle = status else { return }
        speechBackendFactoryForTesting = factory
    }
#if VOICEPOINTER_TEST_ENTRY
    @_spi(Testing)
    public func setWatchdogDelayForTesting(_ seconds: TimeInterval) {
        guard case .idle = status, seconds.isFinite, seconds > 0 else { return }
        watchdogDelaySecondsForTesting = seconds
    }

    @_spi(Testing)
    public func setReleaseWaitTimeoutForTesting(_ seconds: TimeInterval) {
        guard case .idle = status,
              seconds.isFinite, seconds > 0, seconds <= 1 else { return }
        releaseWaitTimeoutNanosecondsForTesting = UInt64(seconds * 1_000_000_000)
    }

    @_spi(Testing)
    public func replaceActiveBackendForTesting(_ backend: (any SpeechInputBackend)?) {
        activeBackend = backend
    }
#endif

    public init(
        focusEngine: SmartFocusEngine,
        keyboardSender: (any KeyboardEventSending)? = nil,
        keyboardOwnership: KeyboardOwnershipManager = KeyboardOwnershipManager(),
        composerActionExecutor: any ComposerActionExecuting = MacOSComposerActionExecutor(),
        outcomeHandler: @escaping OutcomeHandler = { _, _, _ in },
        statusHandler: @escaping StatusHandler = { _, _ in },
        transcriptHandler: @escaping TranscriptHandler = { _ in },
        cloudAdmissionInputs: CloudAdmissionInputsProvider? = nil,
        dictationHandler: DictationHandler? = nil,
        memoryHandler: (@MainActor (DictationRecord, String, Bool) -> Void)? = nil,
        learningObserver: (any DictationEditObserving)? = nil,
        doubaoLearningAudio: (any DoubaoLearningAudioProviding)? = nil
    ) {
        self.focusEngine = focusEngine
        self.keyboardSender = keyboardSender
        self.keyboardOwnership = keyboardOwnership
        self.composerActionExecutor = composerActionExecutor
        self.outcomeHandler = outcomeHandler
        self.statusHandler = statusHandler
        self.transcriptHandler = transcriptHandler
        self.cloudAdmissionInputs = cloudAdmissionInputs
        self.dictationHandler = dictationHandler
        self.memoryHandler = memoryHandler
        self.learningObserver = learningObserver
        self.doubaoLearningAudio = doubaoLearningAudio
        // Removed: hotword-seeded second decoding of candidate words was self-confirming.
        // The strict learner consumes only the original local final and teacher final.
    }

    /// Revocation is bound to one admitted practice session, never a later external dictation.
    public func cancelPracticeSession(cancellationToken: OperationCancellationToken) async {
        guard sessionPracticeSink != nil, operationToken === cancellationToken else { return }
        await cancel()
    }

    @discardableResult
    public func gestureBegan(
        _ activation: GestureActivation,
        settings: VoicePointerSettings,
        cancellationToken: OperationCancellationToken = .init(),
        selection: VoiceInputSelection? = nil,
        lexiconRevision: Int = 0,
        cloudConsent: Set<String> = [],
        aliyunEndpoint: String = AliEndpoint.defaultURLString,
        onlineAPIConfiguration: OnlineAPIConfiguration? = nil,
        lexicon: LexiconSnapshot? = nil,
        localHotwords: [String] = [], localContext: RecognitionContextPlan? = nil, contextAppKey: String = "",
        practiceSink: (@MainActor @Sendable (UUID, String) -> Void)? = nil
    ) -> Bool {
        guard !terminating else { return ignoreGesture(reason: "terminating", at: activation.location) }
        RuntimeTrace.record(
            "coordinator gestureBegan mode=\(settings.voiceShortcut.mode.rawValue) " +
            "shortcutKeyCode=\(settings.voiceShortcut.keyCode)"
        )
        let requestedMode: VoiceActivationMode = settings.voiceShortcut.mode == .hold ? .hold : .toggle
        if requestedMode == .toggle, stateMachine.state == .listening {
            let generation = operationGeneration
            let actions = stateMachine.handle(.gestureBegan)
            guard actions.contains(.stopVoice) else { return ignoreGesture(reason: "toggleState", at: activation.location) }
            Task { [weak self] in
                await self?.completeRelease(action: .stop, generation: generation)
            }
            return true
        }
        beginFeedbackSession(UUID())
        if case .failed = status { publish(.idle, at: nil) }
        if releaseGeneration == nil,
           stateMachine.state == .idle,
           let previousBackend = activeBackend {
            guard previousBackend.isQuiescent else {
                RuntimeTrace.record("coordinator gesture ignored reason=previousBackendBusy")
                publishFailure(.dictationResourceBusy, stage: .resourceRelease, safeAction: .retryManually, at: activation.location)
                return false
            }
            activeBackend = nil
            backendGate?.invalidate()
            backendGate = nil
            backendReleased = false
            backendReady = false
            backendFailure = nil
            backendPartialCount = 0
            operationToken?.cancel()
            operationToken = nil
            if case .failed = status { publish(.idle, at: nil) }
        }
        guard case .idle = status else { return ignoreGesture(reason: "activeStatus", at: activation.location) }
        // Ignored duplicate presses must not reset an active targetless dictation.
        sessionHasNoTarget = false
        guard activeBackend?.isQuiescent != false else {
            RuntimeTrace.record("coordinator gesture ignored reason=backendBusy")
            publishFailure(.dictationResourceBusy, stage: .resourceRelease, safeAction: .retryManually, at: activation.location)
            return false
        }
        guard releaseGeneration == nil else { return ignoreGesture(reason: "releasePending", at: activation.location) }
        guard !cancellationToken.isCancelled else { return ignoreGesture(reason: "cancelled", at: activation.location) }
        guard let effectiveSelection = try? (selection ?? VoiceInputSelection()) else {
            RuntimeTrace.record("coordinator gesture ignored reason=invalidSelection")
            publishFailure(.configurationInvalid, stage: .selection, safeAction: .openSettings, at: activation.location)
            scheduleIdleReset()
            return true
        }
        func isBlank(_ value: String) -> Bool {
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !isBlank(effectiveSelection.routeID),
              !isBlank(effectiveSelection.language),
              lexiconRevision >= 0 else {
            RuntimeTrace.record("coordinator gesture ignored reason=invalidConfiguration")
            publishFailure(.configurationInvalid, stage: .selection, safeAction: .openSettings, at: activation.location)
            scheduleIdleReset()
            return true
        }
        // HTTP routes require a matching frozen provider/model and explicit upload consent.
        // Aliyun is decided per dictation by the admission gate (finishResolution):
        // legacy consent is never that decision, and a denial runs the local route.
        if effectiveSelection.mode == .voiceNative,
           OnlineAPIConfiguration.cloudRouteIDs.subtracting(["aliyun"]).contains(effectiveSelection.routeID),
           (onlineAPIConfiguration?.routeID != effectiveSelection.routeID || onlineAPIConfiguration?.provider.isAliyun != false
            || !cloudConsent.contains(onlineAPIConfiguration?.consentID ?? "")) {
            RuntimeTrace.record("cloud route blocked reason=admissionNotConnected")
            RuntimeTrace.record("coordinator gesture ignored reason=cloudAdmission")
            publishFailure(.cloudRouteUnavailable, stage: .selection, safeAction: .switchProvider, at: activation.location)
            scheduleIdleReset()
            return true
        }
        sessionPracticeSink = effectiveSelection.mode == .voiceNative ? practiceSink : nil
        finalTranscript = nil
        sessionOmitTerminalPeriod = settings.omitTerminalPeriod
        terminalPrefix = ""
        terminalRemoved = nil
        GestureSpeechActivity.shared.beginGesture()
        backendPartialCount = 0
        rawFinalTranscript = nil
        finalTranscriptSource = nil
        finalHotwordEcho = false
        finalLexiconHits = []
        sessionCorrector = DictationCorrector(lexicon: lexicon)
        inlinePump?.cancel()
        inlinePump = nil
        sessionCloudConsent = cloudConsent
        HybridUploadWork.cancelOutstanding()
        sessionEnhanceLocal = HybridSessionPolicy.freezesEnhancement(consent: cloudConsent, selection: effectiveSelection,
            cloudProvider: onlineAPIConfiguration?.provider ?? .aliyunBailian)
        sessionEnhanceWithdrawn = false
        sessionOnlineAPIConfiguration = onlineAPIConfiguration
        sessionAliyunEndpoint = onlineAPIConfiguration?.provider.isAliyun == true
            ? ((try? onlineAPIConfiguration?.validatedEndpoint().absoluteString) ?? aliyunEndpoint) : aliyunEndpoint
        // Hot words are for a recognizer on this Mac; the keyboard route (Doubao) has none to give them to.
        sessionSnapshot = try? VoiceInputSnapshot(
            sessionID: UUID(),
            selection: effectiveSelection,
            lexiconRevision: lexicon?.revision ?? lexiconRevision,
            localHotwords: effectiveSelection.mode == .voiceNative ? localHotwords : [], onlineAPIConfiguration: onlineAPIConfiguration,
            localContext: localContext, contextAppKey: contextAppKey
        )
        doubaoLearning?.cancel()
        if let sessionID = sessionSnapshot?.sessionID { beginFeedbackSession(sessionID) }
        teacherResumeTask?.cancel(); teacherResumeTask = nil
        learningObserver?.pauseTeacherRecheck()

        operationGeneration &+= 1
        let generation = operationGeneration
        operationSafety.install(cancellationToken)
        operationToken = cancellationToken
        stateMachine = VoiceStateMachine(mode: requestedMode)
        composerActionExecutor.cancel(session: composerSession)
        composerSession = nil
        let actions = stateMachine.handle(.gestureBegan)
        guard case .resolveTarget(let id) = actions.first else { return ignoreGesture(reason: "resolutionState", at: activation.location) }
        gestureStartedAt = DispatchTime.now().uptimeNanoseconds
        _ = stateMachine.handle(.resolutionStarted)
        lastLocation = activation.location
        publish(.resolvingTarget, at: activation.location)

        let focusEngine = self.focusEngine
        let point = activation.location
        let focusMode = settings.focusMode
        var focusConfiguration = SmartFocusConfiguration()
        focusConfiguration.synthesizeClickFallback = settings.allowSyntheticClickFallback
        let resolvedFocusConfiguration = focusConfiguration
        let excluded = settings.excludedBundleIdentifiers
        focusTask?.cancel()
        focusCancellationToken?.cancel()
        let focusToken = FocusCancellationToken()
        focusCancellationToken = focusToken
        focusTask = Task { [weak self] in
            guard let self else { return }
            if self.sessionPracticeSink != nil {
                await self.finishResolution(SmartFocusResult(outcome: .voiceOnly), activationID: id,
                    operationGeneration: generation, settings: settings)
                return
            }
            let queue = self.focusQueue
            // 0.6 s normally; a cold Chromium or Electron page can use the
            // bounded warm-up window inside this 1.7-second worker ceiling.
            let boundedResult = await self.focusWorker.runBounded(nanoseconds: 1_700_000_000) {
                await withCheckedContinuation { continuation in
                    queue.async {
                        continuation.resume(returning: focusEngine.focus(
                            at: point,
                            mode: focusMode,
                            configuration: resolvedFocusConfiguration,
                            excludedBundleIdentifiers: excluded,
                            cancellationToken: cancellationToken,
                            shouldContinue: { !focusToken.isCancelled && !cancellationToken.isCancelled }
                        ))
                    }
                }
            }
            if boundedResult == nil { cancellationToken.cancel() }
            let result = boundedResult ?? SmartFocusResult(outcome: .cancelled)
            await self.finishResolution(
                result,
                activationID: id,
                operationGeneration: generation,
                settings: settings
            )
        }
        return true
    }

    public func cloudAuthorizationChanged(_ allowed: Set<String>) {
        let uploadProviderWithdrawn = sessionOnlineAPIConfiguration.map {
            !$0.provider.isAliyun && !allowed.contains($0.consentID)
        } ?? false
        if !allowed.contains(CloudEntry.enhanceConsentID) || uploadProviderWithdrawn {
            HybridUploadWork.cancelOutstanding()
        }
        guard let snapshot = sessionSnapshot,
              snapshot.selection.mode == .voiceNative else { return }
        // Withdrawing "用于增强本地识别" stops only the cloud branch: the local dictation, this operation and its
        // pending send stay. It is remembered, so a backend still being admitted or started gets no cloud branch.
        if uploadProviderWithdrawn && sessionEnhanceLocal || HybridSessionPolicy.withdrawsEnhancement(
            frozen: sessionEnhanceLocal, alreadyWithdrawn: sessionEnhanceWithdrawn, allowed: allowed
        ) {
            sessionEnhanceWithdrawn = true
            if operationToken?.isCancelled == false {
                (activeBackend as? any HybridSessionControlling)?.revokeCloud(reason: .consentWithdrawn)
            }
            return
        }
        let provider: String
        switch snapshot.selection.routeID {
        case "groq-v3", "groq-turbo":
            provider = "groq"
        case "openai-transcribe", "openai-mini-transcribe": provider = "openai"
        case "siliconflow-sensevoice": provider = "siliconflow"
        case "aliyun":
            provider = "aliyun-beijing"
        default:
            return
        }
        guard sessionCloudConsent.contains(provider),
              !allowed.contains(provider),
              operationToken?.isCancelled == false else { return }
        let id = snapshot.sessionID
        invalidatePendingActions()
        Task { [weak self] in
            guard let self, self.sessionSnapshot?.sessionID == id else { return }
            await self.cancel()
        }
    }

    public func gestureEnded(action: VoiceReleaseAction = .stop, expectedSessionID: UUID? = nil) async {
        guard expectedSessionID == nil || expectedSessionID == sessionSnapshot?.sessionID else { return }
        if action == .send, stateMachine.state == .arming || stateMachine.state == .resolvingTarget {
            let identity = operationGeneration
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
            while identity == operationGeneration, !Task.isCancelled,
                  (stateMachine.state == .arming || stateMachine.state == .resolvingTarget),
                  DispatchTime.now().uptimeNanoseconds < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            guard identity == operationGeneration, !Task.isCancelled else { return }
            guard stateMachine.state == .listening else {
                retireCancelledSession(performDownSwipe: false)
                publishFailure(.recognitionIncomplete, stage: .preparation, safeAction: .retryManually, at: lastLocation)
                scheduleIdleReset()
                return
            }
        }
        let holdMs = gestureStartedAt == 0 ? UInt64.max : (DispatchTime.now().uptimeNanoseconds - gestureStartedAt) / 1_000_000
        if action == .stop, holdMs < MicrophoneSilenceGate.shortTapMilliseconds,
           (activeBackend as? any SpeechCaptureActivityProviding)?.hasAcceptedCaptureAudio == false {
            RuntimeTrace.record("voice release silent reason=shortTap holdMs=\(holdMs)")
            retireCancelledSession(performDownSwipe: false)
            return
        }
        composerSession?.noteRelease()
        if action == .send, sessionSnapshot?.selection.mode == .doubao {
            composerSession?.beginExternalSend()
        }
        if action == .cancel, stateMachine.mode == .hold, !sessionHasNoTarget {
            retireCancelledSession(performDownSwipe: true)
            return
        }
        RuntimeTrace.record(
            "coordinator gestureEnded state=\(String(describing: stateMachine.state)) " +
            "releaseAction=\(action.rawValue)"
        )
        let generation = operationGeneration
        let actions = stateMachine.handle(.gestureEnded)
        if actions.contains(.cancelResolution) {
            operationSafety.invalidate()
            cancelFocusWork()
            composerActionExecutor.cancel(session: composerSession)
            composerSession = nil
            sessionHasNoTarget = false
            publish(.idle, at: nil)
        }
        if actions.contains(.stopVoice) {
            await completeRelease(action: action, generation: generation)
        }
    }

    /// Synchronously closes the window in which a queued mouse-up could
    /// perform send/cancel. Call immediately when the UI observes Escape,
    /// disable, disconnect, or another cancellation source. Resource cleanup has its own owner.
    public func invalidatePendingActions() {
        retireCancelledSession(performDownSwipe: false)
    }

    public func cancel() async {
        retireCancelledSession(performDownSwipe: false)
    }

    private func retireCancelledSession(performDownSwipe: Bool) {
        terminalReceipt = nil
        terminalPrefix = ""
        terminalRemoved = nil
        let backend = activeBackend, shortcut = controller, session = composerSession, pump = inlinePump
        let snapshot = sessionSnapshot, mode = stateMachine.mode, token = operationToken
        let text = finalTranscript ?? ""
        let noTarget = sessionHasNoTarget
        if noTarget {
            RuntimeTrace.record("composer release skipped noTarget action=cancel utf16=\(text.utf16.count)")
        }
        doubaoLearning?.cancel() // Cancel revokes T8 reference work; normal Stop never enters this path.
        pump?.cancel()
        (backend as? any SpeechCaptureCancellationInvalidating)?.invalidateCaptureForCancellation()
        watchdogTask?.cancel(); watchdogTask = nil
        cancelFocusWork()
        operationGeneration &+= 1
        let generation = operationGeneration
        releaseGeneration = nil
        backendGate?.invalidate(); backendGate = nil
        activeBackend = nil; controller = nil; composerSession = nil; inlinePump = nil
        sessionHasNoTarget = false
        sessionSnapshot = nil; operationToken = nil
        sessionPracticeSink = nil
        finalTranscript = nil; rawFinalTranscript = nil; finalLexiconHits = []
        backendReady = false; backendReleased = false; backendFailure = nil
        _ = stateMachine.handle(.cancel); _ = stateMachine.handle(.stopCompleted)
        if !performDownSwipe {
            if let token { operationSafety.invalidate(token: token) }
            composerActionExecutor.cancel(session: session)
        }
        publish(.idle, at: nil)
        guard backend != nil || shortcut != nil || pump != nil || session != nil else { return }
        let owner = UUID()
        let executor = composerActionExecutor
        cancelledResourceTasks[owner] = Task { @MainActor [weak self] in
            if let backend {
                (backend as? any HybridSessionControlling)?.noteReleaseAction(.cancel)
                // The keyboard route only releases its shortcut; finish cannot wait for an ASR final.
                // Its parent token stays valid for the existing native Undo transaction.
                if performDownSwipe, snapshot?.selection.mode == .doubao { await backend.finish() }
                else { await backend.cancel() }
                while !backend.isQuiescent { try? await Task.sleep(for: .milliseconds(25)) }
            }
            if let shortcut {
                if mode == .hold { await shortcut.modifierUp() } else { await shortcut.toggle() }
            }
            await pump?.finish() // Any already-owned inline writer drains before a new session or data cleanup.
            if performDownSwipe, let session, !session.isCancelled {
                let outcome: ComposerActionOutcome
                if snapshot?.selection.mode == .voiceNative, let deliverer = executor as? any TranscriptDelivering {
                    outcome = await deliverer.deliver(text: text, action: .cancel, session: session)
                } else { outcome = await executor.perform(.cancel, session: session) }
                if let self, generation == self.operationGeneration, !self.terminating {
                    let feedback = self.feedbackForOutcome(outcome, action: .cancel)
                    self.outcomeHandler(outcome, .cancel, feedback)
                    self.publishOutcome(feedback)
                }
            }
            if let session { executor.cancel(session: session) }
            token?.cancel()
            await executor.waitForPendingOperations()
            // Only this retired owner's task is removed; never clear a later session's backend or state.
            self?.cancelledResourceTasks.removeValue(forKey: owner)
        }
    }

    public func waitForCancelledResources() async {
        while !cancelledResourceTasks.isEmpty {
            let owned = Array(cancelledResourceTasks.values)
            for task in owned { await task.value }
        }
    }

    public func applicationWillTerminate() async {
        terminating = true
        teacherResumeTask?.cancel(); teacherResumeTask = nil
        learningObserver?.cancelTeacherRecheck()
        await learningObserver?.waitForTeacherCancellation()
        await cancel()
        await waitForCancelledResources()
        await doubaoLearning?.waitForCancellation()
        await composerActionExecutor.waitForPendingOperations()
        await focusWorker.drain()
        await localWorkerPool.shutdownAll()
    }

    private func finishResolution(
        _ result: SmartFocusResult,
        activationID id: UInt64,
        operationGeneration generation: UInt64,
        settings: VoicePointerSettings
    ) async {
        await waitForCancelledResources()
        guard generation == operationGeneration,
              id == stateMachine.activationID else { return }
        RuntimeTrace.record("focus resolved outcome=\(String(describing: result.outcome))")
        let focusSucceeded: Bool
        switch result.outcome {
        case .focused, .alreadyFocused, .fallbackClicked, .voiceOnly:
            focusSucceeded = true
        case .unavailable:
            publishFailure(.targetUnavailable, stage: .target, safeAction: .refocusInput, at: lastLocation)
            focusSucceeded = false
        case .cancelled:
            publish(.idle, at: nil)
            focusSucceeded = false
        case .excluded:
            publishFailure(.applicationExcluded, stage: .target, safeAction: .openSettings, at: lastLocation)
            focusSucceeded = false
        case .ambiguous:
            publishFailure(.targetUnavailable, stage: .target, safeAction: .refocusInput, at: lastLocation)
            focusSucceeded = false
        case .rejected:
            publishFailure(.targetUnavailable, stage: .target, safeAction: .refocusInput, at: lastLocation)
            focusSucceeded = false
        }
        guard focusSucceeded else {
            _ = stateMachine.handle(.targetResolutionFailed)
            scheduleIdleReset()
            return
        }
        guard let token = operationToken, !token.isCancelled else { return }
        let safety = operationSafety
        let isNative = sessionSnapshot?.selection.mode == .voiceNative
        let deliveryToken = isNative ? OperationCancellationToken(parent: token) : token
        let targetPID: pid_t? = result.target.flatMap { target in
            var pid: pid_t = 0
            return AXUIElementGetPid(target.element, &pid) == .success ? pid : nil
        }
        let startResult: ComposerSessionStartResult
        if sessionPracticeSink != nil {
            startResult = .forFailure(.wrongProcess)
        } else {
        startResult = await composerActionExecutor.beginSession(
            cancellationToken: deliveryToken, target: result.target,
            onTargetInvalidated: { [weak self] in
                guard !isNative else { return }
                safety.invalidate(token: token)
                // Still in the same app: the app moved focus itself, not the user switching away.
                if let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                    Task { @MainActor [weak self] in self?.noteTargetDrift(generation: generation) }
                }
            })
        }
        // The look at the field this start took (when the field is the one a kept dictation went to) is emptied
        // right here, whatever becomes of the start.
        var revisit: FieldRevisitSample?
        if case .ready(let startedSession) = startResult, !startedSession.isSecureField,
           let reporter = composerActionExecutor as? any KeptDeliveryReporting {
            revisit = reporter.takeRevisit(for: startedSession)
        }
        guard generation == operationGeneration,
              id == stateMachine.activationID, !token.isCancelled else {
            if case .ready(let staleSession) = startResult { composerActionExecutor.cancel(session: staleSession) }
            return
        }
        switch startResult {
        case .ready(let session) where !session.isCancelled:
            composerSession = session
            sessionSnapshot = sessionSnapshot?.confirmedContextTarget(session.applicationBundleID)
            if session.isSecureField {
                // A password field is usable, but never a learning/record source.
                // Preserve the chosen recognizer and its existing upload consent.
                sessionSnapshot = sessionSnapshot?.withoutLocalHotwords()
                sessionCorrector = .none
                sessionOmitTerminalPeriod = false
                terminalPrefix = ""
            }
            if sessionOmitTerminalPeriod, sessionSnapshot?.selection.mode == .voiceNative,
               let receipt = terminalReceipt, let revisit,
               DispatchTime.now().uptimeNanoseconds &- receipt.at <= 600_000_000_000,
               revisit.baselineID == receipt.baseline.id, revisit.caretAtEnd,
               revisit.document == receipt.baseline.document,
               revisit.editingGeneration == receipt.baseline.editingGeneration,
               receipt.baseline.spanLocation + receipt.baseline.spanLength == receipt.baseline.document.utf16.count {
                terminalPrefix = receipt.mark == "." ? ". " : receipt.mark
            }
            terminalReceipt = nil
            if !session.isSecureField { learningObserver?.sessionBegan(revisit: revisit) }
            if !session.isSecureField, let snapshot = sessionSnapshot,
               snapshot.selection.mode == .voiceNative,
               let deliverer = composerActionExecutor as? any InlineTranscriptDelivering {
                inlinePump = InlineDraftPump(
                    deliverer: deliverer, session: session, speechSessionID: snapshot.sessionID)
            }
        case .noInputField(let context):
            sessionSnapshot = sessionSnapshot?.confirmedContextTarget(nil)
            sessionNoTargetContext = context
            sessionHasNoTarget = true
            composerSession = nil
            RuntimeTrace.record("composer session skipped reason=\(context.reason.rawValue) mode=noTarget")
        case .secureFieldUnavailable:
            token.cancel()
            sessionHasNoTarget = false
            _ = stateMachine.handle(.targetResolutionFailed)
            publishFailure(.safeInputBlocked, stage: .target, safeAction: .none, at: lastLocation)
            scheduleIdleReset()
            return
        case .ready, .unavailable, .cancelled, .timedOut:
            token.cancel()
            sessionHasNoTarget = false
            _ = stateMachine.handle(.targetResolutionFailed)
            publishFailure(.targetUnavailable, stage: .target, safeAction: .refocusInput, at: lastLocation)
            scheduleIdleReset()
            return
        }
        let actions = stateMachine.handle(.targetResolved)
        guard actions.contains(.startVoice) else {
            sessionHasNoTarget = false
            publish(.idle, at: nil)
            return
        }

        let modifier = voiceModifier(for: settings.voiceShortcut.keyCode)
        if let keyboardSender {
            guard sessionSnapshot?.selection.mode != .voiceNative else {
                token.cancel()
                _ = stateMachine.handle(.cancel)
                _ = stateMachine.handle(.stopCompleted)
                publishFailure(.configurationInvalid, stage: .preparation, safeAction: .openSettings, at: lastLocation)
                scheduleIdleReset()
                return
            }
            // Explicit injection seam for legacy offline tests; never selected
            // by the app's production initializer.
            let newController: any VoiceShortcutControlling = stateMachine.mode == .hold
                ? HoldVoiceShortcutController(modifier: modifier, sender: keyboardSender)
                : ToggleVoiceShortcutController(modifier: modifier, sender: keyboardSender)
            controller = newController
            await newController.modifierDown()
        } else {
            guard var frozenSnapshot = sessionSnapshot else {
                token.cancel()
                _ = stateMachine.handle(.cancel)
                _ = stateMachine.handle(.stopCompleted)
                publishFailure(.configurationInvalid, stage: .preparation, safeAction: .openSettings, at: lastLocation)
                scheduleIdleReset()
                return
            }
            // K06: cloud audio needs a permit the gate issued for this dictation. A denial, or an
            // admission that cannot be established, runs the same dictation on the local route.
            if sessionHasNoTarget && sessionPracticeSink == nil {
                sessionEnhanceLocal = false
                guard let local = CloudDictationStart.targetlessSnapshot(for: frozenSnapshot) else {
                    token.cancel()
                    _ = stateMachine.handle(.cancel)
                    _ = stateMachine.handle(.stopCompleted)
                    publish(.idle, at: nil)
                    return
                }
                frozenSnapshot = local
                sessionSnapshot = local
                RuntimeTrace.record("cloud skipped reason=noTarget")
            }
            var cloudAdmission: CloudStreamAdmission?
            var hybridStart: (route: HybridSpeechRoute, admission: CloudStreamAdmission?)?
            if frozenSnapshot.selection.mode == .voiceNative,
               frozenSnapshot.selection.routeID == "aliyun" {
                switch await CloudDictationStart.resolve(snapshot: frozenSnapshot, provider: cloudAdmissionInputs) {
                case .admitted(let admission):
                    RuntimeTrace.record("cloud admission admitted epoch=\(admission.permit.pauseEpoch)")
                    cloudAdmission = admission
                case .denied(let reason):
                    RuntimeTrace.record("cloud admission denied reason=\(reason) fallback=local")
                    guard let fallback = CloudDictationStart.localFallbackSnapshot(for: frozenSnapshot) else {
                        token.cancel()
                        composerActionExecutor.cancel(session: composerSession)
                        composerSession = nil
                        _ = stateMachine.handle(.cancel)
                        _ = stateMachine.handle(.stopCompleted)
                        publishFailure(.cloudRouteUnavailable, stage: .selection, safeAction: .switchProvider, at: lastLocation)
                        scheduleIdleReset()
                        return
                    }
                    frozenSnapshot = fallback
                    sessionSnapshot = fallback
                }
                guard generation == operationGeneration, id == stateMachine.activationID,
                      !token.isCancelled, stateMachine.state == .listening else { return }
            } else if sessionEnhanceLocal, !sessionEnhanceWithdrawn {
                // "用于增强本地识别": the same gate, asked for this dictation with the local snapshot (the app's
                // provider maps a local route to the enhancement's own switch). A denial or a skip runs the plain
                // local backend below; `frozenSnapshot` and `sessionSnapshot` stay the local route's.
                switch HybridSessionPolicy.admissionPlan(
                    for: frozenSnapshot.selection, cloudDrainOutstanding: HybridCloudDrain.outstanding,
                    cloudProvider: sessionOnlineAPIConfiguration?.provider ?? .aliyunBailian
                ) {
                case .skip(let reason):
                    RuntimeTrace.record(HybridSessionPolicy.skippedTrace(reason))
                case .ask(let route):
                    if let config = sessionOnlineAPIConfiguration, !config.provider.isAliyun {
                        if sessionCloudConsent.contains(config.consentID), (try? config.validatedEndpoint()) != nil {
                            RuntimeTrace.record("hybrid admission admitted epoch=0")
                            hybridStart = (route, nil)
                        } else {
                            RuntimeTrace.record(HybridSessionPolicy.deniedTrace(reason: "uploadNotAllowed"))
                        }
                        break
                    }
                    switch await CloudDictationStart.resolve(snapshot: frozenSnapshot, provider: cloudAdmissionInputs) {
                    case .admitted(let admission):
                        RuntimeTrace.record(HybridSessionPolicy.admittedTrace(epoch: admission.permit.pauseEpoch))
                        hybridStart = (route, admission)
                    case .denied(let reason):
                        RuntimeTrace.record(HybridSessionPolicy.deniedTrace(reason: reason))
                    }
                    guard generation == operationGeneration, id == stateMachine.activationID,
                          !token.isCancelled, stateMachine.state == .listening else { return }
                }
            }
            await doubaoLearning?.waitForCancellation()
            await learningObserver?.waitForTeacherCancellation()
            guard generation == operationGeneration, !token.isCancelled else { return }
            let gate: SpeechSessionEventGate
            do {
                gate = try SpeechSessionEventGate(snapshot: frozenSnapshot)
            } catch {
                token.cancel()
                _ = stateMachine.handle(.cancel)
                _ = stateMachine.handle(.stopCompleted)
                publishFailure(.configurationInvalid, stage: .preparation, safeAction: .openSettings, at: lastLocation)
                scheduleIdleReset()
                return
            }
            let backend: any SpeechInputBackend
            let testBackend = speechBackendFactoryForTesting?(frozenSnapshot)
            if let testBackend {
                backend = testBackend
            } else if frozenSnapshot.selection.mode == .doubao {
                backend = DoubaoSpeechBackend(
                    manager: keyboardOwnership,
                    modifier: modifier,
                    mode: stateMachine.mode,
                    externalToken: token,
                    safety: operationSafety
                )
            } else if frozenSnapshot.selection.routeID == "apple-speech" {
            guard #available(macOS 26.0, *) else {
                    token.cancel()
                    composerActionExecutor.cancel(session: composerSession)
                    composerSession = nil
                    _ = stateMachine.handle(.cancel)
                    _ = stateMachine.handle(.stopCompleted)
                    publishFailure(.platformUnsupported, stage: .preparation, safeAction: .switchProvider, at: lastLocation)
                    scheduleIdleReset()
                    return
                }
                backend = AppleSpeechBackend()
            } else if frozenSnapshot.selection.routeID == "groq-v3" || frozenSnapshot.selection.routeID == "groq-turbo" {
                backend = makeCloudFallback(snapshot: frozenSnapshot) { capture in
                    GroqBackendFactory.make(consentGranted: self.sessionCloudConsent.contains("groq"),
                        credentialRevision: frozenSnapshot.onlineAPIConfiguration?.credentialRevision, makeCapture: capture)
                }
            } else if ["openai-transcribe", "openai-mini-transcribe", "siliconflow-sensevoice"].contains(frozenSnapshot.selection.routeID) {
                backend = makeCloudFallback(snapshot: frozenSnapshot) { capture in
                    GroqBackendFactory.make(consentGranted: self.sessionCloudConsent.contains(frozenSnapshot.onlineAPIConfiguration?.consentID ?? ""),
                        provider: frozenSnapshot.onlineAPIConfiguration?.provider ?? .openai,
                        credentialRevision: frozenSnapshot.onlineAPIConfiguration?.credentialRevision, makeCapture: capture)
                }
            } else if frozenSnapshot.selection.routeID == "aliyun" {
                guard let admission = cloudAdmission,
                      let candidate = try? makeCloudFallback(snapshot: frozenSnapshot, makePrimary: { capture in
                          try AliBackendFactory.make(consentGranted: self.sessionCloudConsent.contains("aliyun-beijing"), endpoint: self.sessionAliyunEndpoint, admission: admission,
                        modelID: frozenSnapshot.onlineAPIConfiguration?.modelID ?? AliWireCodec.legacyModelID,
                        credentialRevision: frozenSnapshot.onlineAPIConfiguration?.credentialRevision, makeCapture: capture)
                      }) else {
                    token.cancel()
                    composerActionExecutor.cancel(session: composerSession)
                    composerSession = nil
                    _ = stateMachine.handle(.cancel)
                    _ = stateMachine.handle(.stopCompleted)
                    publishFailure(.endpointInvalid, stage: .preparation, safeAction: .openSettings, at: lastLocation)
                    scheduleIdleReset()
                    return
                }
                backend = candidate
            } else if let hybrid = makeHybridBackend(hybridStart) {
                backend = hybrid
            } else {
                backend = LocalSpeechBackend(pool: localWorkerPool)
            }
            // Hot words are for the recognizer on this Mac: no other backend is handed them. The hybrid backend
            // gives them to its local branch only and leaves them off the cloud branch's snapshot.
            if !(backend is LocalSpeechBackend || backend is any HybridSessionControlling),
               !frozenSnapshot.localHotwords.isEmpty || frozenSnapshot.localContext != nil {
                frozenSnapshot = frozenSnapshot.withoutLocalHotwords()
                sessionSnapshot = frozenSnapshot
            }
            activeBackend = backend
            backendGate = gate
            backendReleased = false
            backendReady = false
            backendFailure = nil
            if !sessionHasNoTarget, composerSession?.isSecureField != true { doubaoLearning?.begin(frozenSnapshot) }
            do {
                RuntimeTrace.record(
                    "speech backend start mode=\(frozenSnapshot.selection.mode.rawValue) " +
                    "route=\(Self.safeRouteLabel(frozenSnapshot.selection.routeID)) " +
                    "localHotwords=\(frozenSnapshot.localHotwords.count)" +
                    HybridSessionPolicy.backendStartSuffix(
                        enhancementFrozen: sessionEnhanceLocal, hybridBackend: backend is any HybridSessionControlling,
                        cloudProvider: sessionOnlineAPIConfiguration?.provider ?? .aliyunBailian
                    )
                )
                try await backend.start(snapshot: frozenSnapshot) { [weak self, weak backend] event in
                    guard let self, let backend else { return }
                    guard generation == self.operationGeneration,
                          let snapshot = self.sessionSnapshot,
                          event.sessionID == snapshot.sessionID,
                          self.operationToken?.isCancelled != true else { return }
                    guard var currentGate = self.backendGate else { return }
                    let accepted = currentGate.accept(event)
                    self.backendGate = currentGate
                    guard accepted else { return }
                    switch event.kind {
                    case .ready:
                        self.backendReady = true
                        if snapshot.selection.mode == .voiceNative { self.transcriptHandler(event) }
                    case .stopped:
                        self.backendReleased = true
                    case .partial:
                        if self.composerSession?.isSecureField == true {
                            if !(event.text ?? "").isEmpty { self.backendPartialCount += 1 }
                            break
                        }
                        if event.transcriptSource != .cloudEnhancement,
                           RecognitionHotwords.echoedWordCount(in: event.text ?? "", words: snapshot.localHotwords) > 0 {
                            RuntimeTrace.record("local hotwords echo dropped=true kind=partial")
                            break
                        }
                        if event.transcriptSource != .cloudEnhancement,
                           RecognitionContextEchoPolicy.shouldDrop(text: event.text ?? "", plan: snapshot.localContext,
                            peak: GestureSpeechActivity.shared.loudestPeak()) {
                            RuntimeTrace.record("local context echo dropped=true kind=partial")
                            break
                        }
                        let correctedDraft = HybridSessionPolicy.guardedFinal(
                            event, corrected: self.sessionCorrector.correct(event, mode: snapshot.selection.mode))
                        let draft = TerminalPeriodPolicy.sentence(correctedDraft.event.text ?? "", prefix: self.terminalPrefix, enabled: self.sessionOmitTerminalPeriod).text
                        let shown = TerminalPeriodPolicy.event(correctedDraft.event, text: draft)
                        (backend as? HybridSpeechBackend)?.noteDisplayedDraft(shown.text ?? "")
                        self.transcriptHandler(shown)
                        if InlineWritePolicy.acceptsPartial(draft) {
                            self.backendPartialCount += 1
                            if self.releaseGeneration == nil { self.inlinePump?.enqueue(shown) }
                        }
                    case .final:
                        self.finalHotwordEcho = event.transcriptSource != .cloudEnhancement
                            && (backend as? any SpeechCapturedDurationProviding).map {
                                RecognitionHotwords.isEcho(text: event.text ?? "", words: snapshot.localHotwords,
                                    durationSeconds: $0.capturedDurationSeconds)
                            } == true
                        if !(backend is HybridSpeechBackend), !(backend is CloudOnlyFallbackBackend),
                           !(event.text ?? "").isEmpty { DictationHealthObservation.success(snapshot.selection) }
                        // Recognizer .final is not proof of finger release. Keep automatic
                        // corrections out of the displayed stream; apply them only at delivery.
                        let corrected = HybridSessionPolicy.guardedFinal(
                            event, corrected: self.sessionCorrector.correct(
                                event, mode: snapshot.selection.mode, afterRelease: false
                            )
                        )
                        if let line = corrected.trace { RuntimeTrace.record(line) }
                        (backend as? HybridSpeechBackend)?.noteDisplayedFinal(corrected.event.text ?? "")
                        self.rawFinalTranscript = event.text ?? ""
                        self.finalTranscriptSource = event.transcriptSource
                        let formatted = TerminalPeriodPolicy.sentence(corrected.event.text ?? "", prefix: self.terminalPrefix, enabled: self.sessionOmitTerminalPeriod)
                        self.terminalRemoved = formatted.removed
                        self.finalTranscript = self.finalHotwordEcho ? "" : formatted.text
                        self.finalLexiconHits = corrected.hits
                        self.backendReleased = true
                        if self.composerSession?.isSecureField != true {
                            self.transcriptHandler(TerminalPeriodPolicy.event(corrected.event, text: self.finalTranscript ?? ""))
                        }
                        if self.stateMachine.state == .listening, self.releaseGeneration == nil {
                            _ = self.stateMachine.handle(.watchdog)
                            let currentGeneration = self.operationGeneration
                            Task { [weak self] in
                                await self?.completeRelease(action: .stop, generation: currentGeneration)
                            }
                        }
                    case .failed:
                        let rawCode = SpeechFailureDiagnostics.safeCode(event.errorCode ?? "unknown")
                        let failureCode = self.sessionOnlineAPIConfiguration.map { SpeechFailureDiagnostics.code(rawCode, provider: $0.provider) } ?? rawCode
                        self.backendFailure = failureCode
                        if !(backend is HybridSpeechBackend), !(backend is CloudOnlyFallbackBackend) {
                            DictationHealthObservation.failure(snapshot.selection, code: failureCode)
                        }
                        RuntimeTrace.record("speech backend failed mode=\(snapshot.selection.mode.rawValue) code=\(failureCode)")
                        if self.canSendWithoutFinal {
                            // A failed empty capture must still accept the eventual pure-send gesture.
                            // Stop presents the saved failure; Send cancels it and posts no new text.
                            return
                        }
                        if snapshot.selection.mode == .voiceNative { self.transcriptHandler(event) }
                        if self.releaseGeneration != generation {
                            Task { [weak self] in
                                guard let self else { return }
                                guard generation == self.operationGeneration,
                                      self.activeBackend === backend else { return }
                                defer {
                                    if generation == self.operationGeneration { self.sessionHasNoTarget = false }
                                }
                                self.doubaoLearning?.cancel()
                                self.operationToken?.cancel()
                                await backend.cancel()
                                guard generation == self.operationGeneration,
                                      self.activeBackend === backend else { return }
                                guard backend.isQuiescent else {
                                    self.publishFailure(.dictationResourceBusy, stage: .resourceRelease, safeAction: .retryManually, at: self.lastLocation)
                                    return
                                }
                                self.activeBackend = nil
                                self.backendGate?.invalidate()
                                self.backendGate = nil
                                self.composerActionExecutor.cancel(session: self.composerSession)
                                self.composerSession = nil
                                _ = self.stateMachine.handle(.cancel)
                                _ = self.stateMachine.handle(.stopCompleted)
                                self.publishPresentation(
                                    VoiceIssuePresentationPolicy.forBackendCode(failureCode),
                                    at: self.lastLocation
                                )
                                self.scheduleIdleReset()
                            }
                        }
                    }
                }
            } catch {
                doubaoLearning?.cancel()
                let aliDiagnostic = frozenSnapshot.selection.routeID == "aliyun"
                    ? SpeechFailureDiagnostics.aliDiagnostic(for: error) : nil
                if let diagnostic = aliDiagnostic { DictationHealthObservation.failure(frozenSnapshot.selection, code: diagnostic.code.rawValue) }
                if let failure = error as? BetaWorkerTransportError, failure.description == "LOCAL_MODEL_FILES_MISSING" {
                    DictationHealthObservation.failure(frozenSnapshot.selection, code: failure.description)
                }
                RuntimeTrace.record(
                    "speech backend start rejected route=\(Self.safeRouteLabel(frozenSnapshot.selection.routeID)) " +
                    "reason=\(Self.safeStartupFailure(error))" +
                    (aliDiagnostic.map { " code=\($0.code.rawValue)" } ?? "")
                )
                token.cancel()
                await backend.cancel()
                guard generation == operationGeneration, activeBackend === backend else { return }
                if !backend.isQuiescent {
                    publishFailure(.recognitionStartFailed, stage: .backend, safeAction: .retryManually, at: lastLocation)
                    return
                }
                activeBackend = nil
                backendGate = nil
                _ = stateMachine.handle(.cancel)
                _ = stateMachine.handle(.stopCompleted)
                if let aliDiagnostic {
                    publishPresentation(
                        VoiceIssuePresentationPolicy.forBackendCode(frozenSnapshot.onlineAPIConfiguration.map {
                            SpeechFailureDiagnostics.code(aliDiagnostic.code.rawValue, provider: $0.provider)
                        } ?? aliDiagnostic.code.rawValue), at: lastLocation
                    )
                } else {
                    publishFailure(.recognitionStartFailed, stage: .backend, safeAction: .retryManually, at: lastLocation)
                }
                scheduleIdleReset()
                return
            }
            if generation != operationGeneration
                || token.isCancelled || stateMachine.state != .listening {
                await backend.cancel()
                return
            }
            if SpeechStartupPolicy.shouldReject(deliveryKind: frozenSnapshot.selection.deliveryKind,
                                                ready: backendReady, failed: backendFailure != nil) {
                token.cancel()
                await backend.cancel()
                guard generation == operationGeneration, activeBackend === backend else { return }
                if backend.isQuiescent {
                    activeBackend = nil
                    backendGate = nil
                    _ = stateMachine.handle(.cancel)
                    _ = stateMachine.handle(.stopCompleted)
                    publishFailure(.recognitionStartFailed, stage: .backend, safeAction: .retryManually, at: lastLocation)
                    scheduleIdleReset()
                } else {
                    publishFailure(.recognitionStartFailed, stage: .backend, safeAction: .retryManually, at: lastLocation)
                }
                return
            }
            // Withdrawn while the backend was starting: its cloud branch may have come up after the withdrawal
            // reached it. Asking again is a no-op once the branch has stopped.
            if sessionEnhanceWithdrawn {
                (backend as? any HybridSessionControlling)?.revokeCloud(reason: .consentWithdrawn)
            }
        }
        guard generation == operationGeneration else {
            await releaseActiveVoice(generation: generation)
            return
        }
        guard id == stateMachine.activationID,
              stateMachine.state == .listening else {
            await releaseActiveVoice(generation: generation)
            composerActionExecutor.cancel(session: composerSession)
            composerSession = nil
            sessionHasNoTarget = false
            publish(.idle, at: nil)
            return
        }
        publish(.listening, at: lastLocation)
        startWatchdog(for: id)
    }

    private static func safeRouteLabel(_ routeID: String) -> String {
        switch routeID {
        case "qwen17-rolling", "qwen06-rolling", "qwen06-incremental", "apple-speech",
             "groq-v3", "groq-turbo", "openai-transcribe", "openai-mini-transcribe", "siliconflow-sensevoice", "aliyun", "sensevoice", "zipformer",
             "zipformer-small", "paraformer", "nemotron", "moss-transcribe-diarize",
             "zipformer-sensevoice", "zipformer-qwen17":
            return routeID
        default:
            return "unknown"
        }
    }

    private static func safeStartupFailure(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let transport = error as? BetaWorkerTransportError {
            switch transport.description {
            case "LOCAL_CATALOG_UNAVAILABLE", "LOCAL_UNKNOWN_ROUTE", "LOCAL_MODEL_FILES_MISSING",
                 "LOCAL_LANGUAGE_UNSUPPORTED", "LOCAL_MIC_PERMISSION_DENIED", "LOCAL_START_FAILED",
                 "LOCAL_ALREADY_STARTED", "LOCAL_UNSUPPORTED_MODE", "LOCAL_APPLE_ROUTE_REFUSED":
                return transport.description
            default:
                return "localUnknown"
            }
        }
        if let ali = error as? AliBackendError {
            switch ali {
            case .invalid: return "aliInvalid"
            case .permission: return "aliPermission"
            case .startFailed: return "aliStartFailed"
            }
        }
        if let groq = error as? GroqBackendError {
            switch groq {
            case .invalid: return "groqInvalid"
            case .permission: return "groqPermission"
            case .startFailed: return "groqStartFailed"
            }
        }
        return "unknown"
    }

    /// The local+cloud backend for an admitted enhancement, or nil for the plain local backend: nothing was
    /// admitted, the enhancement was withdrawn meanwhile, or the backend could not be built.
    private func makeCloudFallback(snapshot: VoiceInputSnapshot,
        makePrimary: (@escaping @MainActor () -> any LocalSpeechCapture) throws -> any SpeechInputBackend
    ) rethrows -> any SpeechInputBackend {
        guard let fallback = CloudDictationStart.localFallbackSnapshot(for: snapshot) else {
            return try makePrimary({ SharedCaptureHub.liveSource() })
        }
        let hub = SharedCaptureHub(makeSource: { SharedCaptureHub.liveSource() })
        let primary = try makePrimary({ hub.makeView(.cloud) })
        let local = LocalSpeechBackend(pool: localWorkerPool,
            makeCapture: { hub.makeView(.local, allowSealedSnapshot: true) })
        return CloudOnlyFallbackBackend(hub: hub, primary: primary, local: local, localSnapshot: fallback)
    }

    private func makeHybridBackend(
        _ start: (route: HybridSpeechRoute, admission: CloudStreamAdmission?)?
    ) -> (any SpeechInputBackend)? {
        guard let start else { return nil }
        guard !sessionEnhanceWithdrawn else {
            RuntimeTrace.record(HybridSessionPolicy.skippedTrace(.consentWithdrawn))
            return nil
        }
        do {
            return try HybridBackendFactory.make(
                pool: localWorkerPool,
                route: start.route,
                consentGranted: sessionCloudConsent.contains(CloudEntry.enhanceConsentID),
                endpoint: sessionAliyunEndpoint,
                admission: start.admission,
                modelID: sessionOnlineAPIConfiguration?.modelID ?? AliWireCodec.legacyModelID,
                credentialRevision: sessionOnlineAPIConfiguration?.credentialRevision,
                learningReceiver: sessionHasNoTarget || composerSession?.isSecureField == true ? nil : learningObserver?.enhancementReceiver(),
                teacherFinalReceiver: sessionHasNoTarget || composerSession?.isSecureField == true ? nil : learningObserver?.teacherFinalReceiver(),
                configuration: sessionOnlineAPIConfiguration
            )
        } catch {
            RuntimeTrace.record(HybridSessionPolicy.skippedTrace(.constructFailed))
            return nil
        }
    }

    private func stopActiveVoice(
        reason finalStatus: VoicePointerRuntimeStatus,
        issue: VoiceIssuePresentation? = nil,
        generation: UInt64
    ) async {
        let noTarget = sessionHasNoTarget
        let sensitive = composerSession?.isSecureField == true
        defer {
            if generation == operationGeneration {
                sessionHasNoTarget = false
                sessionPracticeSink = nil
                if sensitive {
                    finalTranscript = nil; rawFinalTranscript = nil; finalLexiconHits = []
                    terminalReceipt = nil
                }
            }
        }
        inlinePump?.cancel()
        let session = composerSession
        composerActionExecutor.cancel(session: session)
        if composerSession == session { composerSession = nil }
        // The text of a stopped dictation is dropped: an enhanced one must not wait for its cloud branch either.
        (activeBackend as? any HybridSessionControlling)?.noteReleaseAction(.cancel)
        let released = await releaseActiveVoice(generation: generation)
        guard generation == operationGeneration, !Task.isCancelled else { return }
        if noTarget {
            doubaoLearning?.cancel()
            RuntimeTrace.record("composer release skipped noTarget action=stop utf16=\(finalTranscript?.utf16.count ?? 0)")
            finalTranscript = nil; rawFinalTranscript = nil; finalLexiconHits = []
            publish(.idle, at: nil)
            return
        }
        if released {
            if let issue {
                publishPresentation(issue, at: nil)
            } else {
                publish(finalStatus, at: nil)
            }
        } else {
            publishFailure(.dictationResourceBusy, stage: .resourceRelease, safeAction: .retryManually, at: lastLocation)
        }
    }

    private func completeRelease(action: VoiceReleaseAction, generation: UInt64) async {
        guard generation == operationGeneration, releaseGeneration == nil else { return }
        releaseGeneration = generation
        let noTarget = sessionHasNoTarget
        let noTargetContext = sessionNoTargetContext
        let isPracticeSession = sessionPracticeSink != nil
        defer {
            if releaseGeneration == generation { releaseGeneration = nil }
            if generation == operationGeneration {
                sessionHasNoTarget = false
                sessionPracticeSink = nil
            }
        }
        let session = composerSession
        let snapshot = sessionSnapshot
        let finishingBackend = activeBackend
        defer {
            if session?.isSecureField == true, generation == operationGeneration {
                finalTranscript = nil
                rawFinalTranscript = nil
                finalLexiconHits = []
                terminalReceipt = nil
            }
        }
        // Before finish(): a swipe-down must not wait for the cloud branch of an enhanced dictation.
        (activeBackend as? any HybridSessionControlling)?.noteReleaseAction(action)
        let silentSend = action == .send && canSendWithoutFinal
        let decisionAt = DispatchTime.now().uptimeNanoseconds
        let released = await releaseActiveVoice(generation: generation, silentSend: silentSend)
        if silentSend {
            RuntimeTrace.record("hybrid final source=none reason=silentSend releaseToDecisionMs=\((DispatchTime.now().uptimeNanoseconds - decisionAt) / 1_000_000) localPartials=0 cloudPartials=0")
        }
        guard generation == operationGeneration,
              releaseGeneration == generation,
              !Task.isCancelled else { return }
        if noTarget {
            // The explicit practice destination is frozen for this session; ordinary no-target
            // dictation still discards its result. Neither path calls AX, sending or learning.
            if released, action != .cancel, operationToken?.isCancelled == false,
               let snapshot, let text = finalTranscript, !text.isEmpty,
               let sink = sessionPracticeSink {
                sink(snapshot.sessionID, text)
                RuntimeTrace.record("onboarding practice delivered final=1")
            }
            doubaoLearning?.cancel()
            RuntimeTrace.record("composer release skipped noTarget action=\(action.rawValue) utf16=\(finalTranscript?.utf16.count ?? 0)")
            operationToken?.cancel()
            composerSession = nil
            inlinePump?.cancel(); inlinePump = nil
            finalTranscript = nil; rawFinalTranscript = nil; finalLexiconHits = []
            sessionSnapshot = nil
            _ = stateMachine.handle(.stopCompleted)
            if action == .send, !isPracticeSession, let context = noTargetContext {
                // The generation guard above owns this entire synchronous completion.
                // Use the acquisition snapshot even if the frontmost app has changed.
                let shown = publishPresentation(
                    VoiceIssuePresentationPolicy.resolve(code: .sendNoTarget, stage: .send, safeAction: .refocusInput),
                    at: lastLocation, applicationBundleID: context.applicationBundleID
                )
                RuntimeTrace.record("composer send noTarget reason=\(context.reason.rawValue) app=\(context.applicationBundleID) focusedRole=\(context.focusedRole) focusedSubrole=\(context.focusedSubrole) hint=\(shown ? "shown" : "throttled")")
            } else {
                publish(.idle, at: nil)
            }
            return
        }
        guard released, operationToken?.isCancelled == false else {
            doubaoLearning?.cancel()
            composerActionExecutor.cancel(session: session)
            if composerSession == session { composerSession = nil }
            _ = stateMachine.handle(.stopCompleted)
            if operationToken?.isCancelled == true {
                if targetDriftGeneration == generation {
                    RuntimeTrace.record("composer target drift reported")
                    publishFailure(.targetUnavailable, stage: .target, safeAction: .refocusInput, at: lastLocation)
                } else {
                    publish(.idle, at: nil)
                }
            } else if !released, activeBackend?.isQuiescent == false {
                publishFailure(.dictationResourceBusy, stage: .resourceRelease, safeAction: .retryManually, at: lastLocation)
            } else if let failureCode = backendFailure {
                publishPresentation(VoiceIssuePresentationPolicy.forBackendCode(failureCode), at: lastLocation)
            } else {
                publishFailure(.recognitionFailed, stage: .backend, safeAction: .retryManually, at: lastLocation)
            }
            if activeBackend?.isQuiescent != false { scheduleIdleReset() }
            return
        }
        // Read the exact Doubao span before Return clears the field. The existing
        // target/edit-generation reader is the only AX source, even when learning is off.
        var doubaoReference: DoubaoLearningReference?
        if session?.isSecureField != true, snapshot?.selection.mode == .doubao, action != .cancel,
           let reporter = composerActionExecutor as? any DoubaoLearningReferenceProviding {
            doubaoReference = await reporter.observeDoubaoReference(for: session)
        }
        guard generation == operationGeneration, !Task.isCancelled else { return }
        let outcome: ComposerActionOutcome
        var dictated: (raw: String, text: String, hits: [LexiconSnapshot.Hit], noise: Bool)?
        if snapshot?.selection.mode == .voiceNative {
            guard let text = finalTranscript,
                  let deliverer = composerActionExecutor as? any TranscriptDelivering else {
                composerActionExecutor.cancel(session: session)
                if composerSession == session { composerSession = nil }
                let failedOutcome = ComposerActionOutcome.deliveryFailed
                _ = stateMachine.handle(.stopCompleted)
                let feedback = feedbackForOutcome(failedOutcome, action: action)
                outcomeHandler(failedOutcome, action, feedback)
                publishOutcome(feedback)
                return
            }
            let pump = inlinePump
            await pump?.finish()
            guard generation == operationGeneration,
                  releaseGeneration == generation,
                  operationToken?.isCancelled == false else { return }
            // Room noise (a near-silent tap that produced a character or two) is judged now, on this gesture's
            // own microphone reading: the next press resets the reading while the delivery is still going on.
            let noise = SilentTranscriptPolicy.shouldDrop(
                transcriptUTF16: text.utf16.count, peakLevel: GestureSpeechActivity.shared.loudestPeak())
                || finalHotwordEcho
                || (finalTranscriptSource != .cloudEnhancement && RecognitionContextEchoPolicy.shouldDrop(text: rawFinalTranscript ?? text,
                    plan: snapshot?.localContext, peak: GestureSpeechActivity.shared.loudestPeak())
                )
            if noise { RuntimeTrace.record("local context echo dropped=true") }
            // This is the existing post-release delivery path, not a new output mechanism.
            // Recompute from the untouched final in one human-first scan. Never cascade an
            // automatic rule onto text already produced by a human rule or count that as a hit.
            let automatic = (!noise && action != .cancel)
                ? sessionCorrector.finalApplication(raw: rawFinalTranscript ?? text,
                    mode: snapshot?.selection.mode ?? .voiceNative, source: finalTranscriptSource)
                : nil
            let deliveredText = noise ? "" : automatic.map {
                TerminalPeriodPolicy.sentence($0.text, prefix: terminalPrefix,
                    enabled: sessionOmitTerminalPeriod).text
            } ?? text
            let deliveredHits = noise ? [] : (automatic?.hits ?? finalLexiconHits)
            RuntimeTrace.record("composer terminal period stripped=\(terminalRemoved == nil || noise || deliveredText.isEmpty ? 0 : 1) restored=\(terminalPrefix.isEmpty || noise || deliveredText.isEmpty ? 0 : 1)")
            dictated = (rawFinalTranscript ?? text, deliveredText, deliveredHits, noise)
            outcome = await deliverer.deliver(text: deliveredText, action: action, session: session)
        } else if stateMachine.mode == .hold {
            outcome = await composerActionExecutor.perform(action, session: session)
        } else {
            composerActionExecutor.cancel(session: session)
            outcome = .kept
        }
        // The executor's receipt of where the dictation landed is emptied here whatever happens next, so that
        // no text of the field stays behind in it.
        let keptBaseline = session?.isSecureField == true ? nil
            : (composerActionExecutor as? any KeptDeliveryReporting)?.takeKeptBaseline(for: session)
        guard generation == operationGeneration else { return }
        terminalReceipt = nil
        if outcome == .kept, action != .cancel, let keptBaseline, let mark = terminalRemoved,
           !keptBaseline.delivered.isEmpty, keptBaseline.delivered == dictated?.text {
            terminalReceipt = (keptBaseline, mark, DispatchTime.now().uptimeNanoseconds)
        }
        RuntimeTrace.record("composer action outcome=\(outcome.rawValue)")
        // sendUnconfirmed already has a confirmed text write; only Return's result is unknown.
        let learningDelivered = session?.isSecureField != true && (outcome == .kept || outcome == .sent || outcome == .sendUnconfirmed)
        if snapshot?.selection.mode == .doubao, learningDelivered,
           let reference = doubaoReference {
            if let selection = snapshot?.selection { DictationHealthObservation.success(selection) }
            let record = DictationRecord(id: reference.baseline.id, date: reference.observedAt,
                rawText: reference.baseline.delivered, text: reference.baseline.delivered, hits: [], routeID: "doubao")
            memoryHandler?(record, session?.applicationBundleID ?? "", false)
            if let roundID = snapshot?.sessionID {
                learningObserver?.teacherFinalObserved(
                    text: reference.baseline.delivered, roundID: roundID, source: .doubao
                )
            }
            doubaoLearning?.finish(reference: { reference })
        } else if snapshot?.selection.mode == .doubao {
            doubaoLearning?.cancel()
        }
        if session?.isSecureField != true, let dictated, let snapshot, action != .cancel, !dictated.text.isEmpty {
            if sessionCorrector.isActive {
                RuntimeTrace.record("lexicon final rules=\(sessionCorrector.lexicon.ruleCount) hits=\(dictated.hits.count)")
            }
            // Room noise is not a dictation to list or to correct.
            if !dictated.noise {
                let record = DictationRecord(
                    rawText: dictated.raw, text: dictated.text,
                    hits: learningDelivered ? dictated.hits : [], routeID: snapshot.selection.routeID
                )
                dictationHandler?(record)
                if learningDelivered {
                    learningObserver?.teacherDictationDelivered(roundID: snapshot.sessionID)
                    let cloudSeen = ((finishingBackend as? HybridSpeechBackend)?.cloudAudioUploaded ?? false)
                        || ((finishingBackend as? AliSpeechBackend)?.uplinkSentMilliseconds ?? 0) > 0
                        || ((finishingBackend as? CloudOnlyFallbackBackend)?.cloudAudioUploaded ?? false)
                    memoryHandler?(record, session?.applicationBundleID ?? "", cloudSeen)
                }
                if outcome == .kept, let observer = learningObserver, let baseline = keptBaseline {
                    observer.dictationKept(record, baseline: baseline)
                }
            }
        }
        let feedback = feedbackForOutcome(outcome, action: action)
        outcomeHandler(outcome, action, feedback)
        if composerSession == session { composerSession = nil }
        inlinePump = nil
        _ = stateMachine.handle(.stopCompleted)
        publishOutcome(feedback)
    }

    @discardableResult
    private func releaseActiveVoice(generation: UInt64, silentSend: Bool = false) async -> Bool {
        guard generation == operationGeneration else { return false }
        watchdogTask?.cancel()
        watchdogTask = nil
        var released = true
        if silentSend {
            finalTranscript = ""; rawFinalTranscript = ""; finalLexiconHits = []
            backendReleased = true; backendFailure = nil
            backendGate?.invalidate(); backendGate = nil
            if let backend = activeBackend {
                activeBackend = nil
                (backend as? any SpeechCaptureCancellationInvalidating)?.invalidateCaptureForCancellation()
                let owner = UUID()
                cancelledResourceTasks[owner] = Task { @MainActor [weak self] in
                    await backend.cancel()
                    while !backend.isQuiescent { try? await Task.sleep(for: .milliseconds(25)) }
                    self?.cancelledResourceTasks.removeValue(forKey: owner)
                }
            }
        }
        if let backend = activeBackend {
            let finishingToken = operationToken
            if finishingToken?.isCancelled == true {
                await backend.cancel()
            } else if (backend as? any SpeechCaptureActivityProviding)?.hasAcceptedCaptureAudio == false {
                // Empty/zero PCM is never offered to an inference finalizer.
                await backend.cancel()
                backendReleased = true
                backendFailure = MicrophoneSilenceGate.noSoundCode
            } else {
                await backend.finish()
            }
            guard generation == operationGeneration,
                  activeBackend === backend,
                  !Task.isCancelled else {
                RuntimeTrace.record("voice release phase identityChanged=true")
                return false
            }
            if !backend.isQuiescent {
#if VOICEPOINTER_TEST_ENTRY
                let timeoutNanoseconds = releaseWaitTimeoutNanosecondsForTesting ?? 1_000_000_000
                isReleaseWaitInProgressForTesting = true
                defer { isReleaseWaitInProgressForTesting = false }
#else
                let timeoutNanoseconds: UInt64 = 1_000_000_000
#endif
                let waitStarted = DispatchTime.now().uptimeNanoseconds
                let deadline = waitStarted &+ timeoutNanoseconds
                while !backend.isQuiescent {
                    guard generation == operationGeneration,
                          activeBackend === backend,
                          !Task.isCancelled else {
                        RuntimeTrace.record("voice release wait outcome=superseded")
                        return false
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { break }
                    let remaining = deadline - now
                    do {
                        try await Task.sleep(nanoseconds: min(25_000_000, remaining))
                    } catch {
                        RuntimeTrace.record("voice release wait outcome=cancelled")
                        return false
                    }
                }
                guard generation == operationGeneration,
                      activeBackend === backend,
                      !Task.isCancelled else {
                    RuntimeTrace.record("voice release wait outcome=superseded")
                    return false
                }
                RuntimeTrace.record(
                    backend.isQuiescent
                        ? "voice release wait outcome=released"
                        : "voice release wait outcome=timedOut"
                )
            }
            let finishingCancelled = finishingToken?.isCancelled == true
            released = backend.isQuiescent
                && (finishingCancelled || backendReleased)
                && (finishingCancelled || backendFailure == nil)
            RuntimeTrace.record("voice release phase identityChanged=false quiescent=\(backend.isQuiescent) backendReleased=\(backendReleased) cancelled=\(finishingCancelled) failure=\(backendFailure ?? "none")")
            if backend.isQuiescent {
                activeBackend = nil
                backendGate?.invalidate()
                backendGate = nil
            }
        }
        let releasingController = controller
        controller = nil
        if let releasingController {
            RuntimeTrace.record("voice shortcut release mode=\(String(describing: stateMachine.mode))")
            if stateMachine.mode == .hold { await releasingController.modifierUp() }
            else { await releasingController.toggle() }
        }
        return released
    }

    private func feedbackForOutcome(
        _ outcome: ComposerActionOutcome,
        action: VoiceReleaseAction
    ) -> ComposerActionFeedback {
        let feedback = ComposerActionFeedback(outcome: outcome, action: action)
        guard let presentation = feedback.presentation else { return feedback }
        let allowed = feedbackPresentationGate.shouldPresent(
            presentation,
            sessionID: feedbackSessionID
        )
        return feedback.withPresentationAllowed(allowed)
    }

    private func publishOutcome(_ feedback: ComposerActionFeedback) {
        guard feedback.shouldPresent else {
            publish(.idle, at: nil)
            return
        }
        if let presentation = feedback.presentation {
            let status = VoiceIssuePresentationPolicy.runtimeStatus(
                for: presentation,
                isPresentationAllowed: feedback.shouldPresent
            )
            publish(status, at: status == .idle ? nil : lastLocation)
            if case .failed = status { scheduleIdleReset() }
            return
        }
        switch feedback.kind {
        case .success, .info:
            publish(.idle, at: nil)
        case .warning:
            // A warning can represent an unknown result after submission.
            // Never turn it into an assertion that the action did not run.
            publish(.failed(feedback.message), at: lastLocation)
            scheduleIdleReset()
        }
    }

    private func startWatchdog(for id: UInt64) {
        watchdogTask?.cancel()
        let generation = operationGeneration
#if VOICEPOINTER_TEST_ENTRY
        let delaySeconds = watchdogDelaySecondsForTesting
            ?? (sessionSnapshot?.selection.mode == .voiceNative ? 330 : 120)
#else
        let delaySeconds: TimeInterval = sessionSnapshot?.selection.mode == .voiceNative ? 330 : 120
#endif
        watchdogTask = Task { [weak self] in
            // The watchdog exists for a release that never arrived. 2026-09-30 the user dictated for
            // more than two minutes and was cut off at exactly 120 s four times in ten minutes, while
            // still pressing. A hold gesture whose button is still physically down is a long dictation:
            // keep going in 60 s steps, up to 10 minutes. A lifted press (missed release) still stops.
            var waitedSeconds: TimeInterval = 0
            var nextDelay = delaySeconds
            while true {
                try? await Task.sleep(for: .seconds(nextDelay))
                guard !Task.isCancelled,
                      let self,
                      generation == self.operationGeneration,
                      id == self.stateMachine.activationID else { return }
                waitedSeconds += nextDelay
                guard self.stateMachine.mode == .hold, waitedSeconds < 600,
                      NSEvent.pressedMouseButtons != 0 else { break }
                RuntimeTrace.record("watchdog extended heldSeconds=\(Int(waitedSeconds))")
                nextDelay = 60
            }
            guard let self else { return }
            let actions = self.stateMachine.handle(.watchdog)
            guard actions.contains(.stopVoice) else { return }
            self.watchdogTask = nil
            await self.stopActiveVoice(
                reason: .idle,
                issue: VoiceIssuePresentationPolicy.resolve(
                    code: .dictationNotSettled,
                    stage: .backend,
                    safeAction: .retryManually
                ),
                generation: generation
            )
            guard generation == self.operationGeneration else { return }
            _ = self.stateMachine.handle(.stopCompleted)
            self.scheduleIdleReset()
        }
    }

    private func noteTargetDrift(generation: UInt64) {
        guard generation == operationGeneration else { return }
        targetDriftGeneration = generation
        RuntimeTrace.record("composer target drift during=listening")
        // Stop now rather than at release: the dictation is already dead (keyboard ownership was
        // released by the watch), and a HUD that keeps "listening" makes the user talk into nothing.
        guard stateMachine.state == .listening, releaseGeneration == nil else { return }
        let actions = stateMachine.handle(.cancel)
        guard actions.contains(.stopVoice) else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        Task { [weak self] in
            guard let self else { return }
            await self.stopActiveVoice(
                reason: .idle,
                issue: VoiceIssuePresentationPolicy.resolve(
                    code: .targetUnavailable, stage: .target, safeAction: .refocusInput),
                generation: generation)
            guard generation == self.operationGeneration else { return }
            _ = self.stateMachine.handle(.stopCompleted)
            RuntimeTrace.record("composer target drift reported early=true")
            self.scheduleIdleReset()
        }
    }

    private func scheduleIdleReset() {
        let generation = operationGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, let self, generation == self.operationGeneration else { return }
            if case .failed = self.status { self.publish(.idle, at: nil) }
        }
    }

    private func beginFeedbackSession(_ id: UUID) {
        feedbackSessionID = id
        feedbackPresentationGate.beginSession(id)
    }
    private func ignoreGesture(reason: String, at location: CGPoint) -> Bool {
        RuntimeTrace.record("coordinator gesture ignored reason=\(reason)")
        // Keep an existing listening/processing HUD alive when a duplicate arrives.
        if case .idle = status {
            publishFailure(.dictationResourceBusy, stage: .resourceRelease, safeAction: .retryManually, at: location)
        } else {
            NotificationCenter.default.post(name: InputDeviceRuntime.notice, object: nil,
                userInfo: ["message": "上一轮听写还在处理，请稍后再按"])
        }
        return false
    }

    private func publishFailure(
        _ code: VoiceIssueCode,
        stage: VoiceIssueStage,
        safeAction: VoiceIssueSafeAction,
        at location: CGPoint?
    ) {
        publishPresentation(
            VoiceIssuePresentationPolicy.resolve(code: code, stage: stage, safeAction: safeAction),
            at: location
        )
    }

    @discardableResult
    private func publishPresentation(_ presentation: VoiceIssuePresentation, at location: CGPoint?,
                                     applicationBundleID: String? = nil) -> Bool {
        if sessionHasNoTarget,
           [.recognitionFailed, .recognitionIncomplete, .microphoneNoSound].contains(presentation.code) {
            RuntimeTrace.record("composer feedback skipped mode=noTarget code=\(presentation.code.rawValue)")
            publish(.idle, at: nil)
            return false
        }
        lastIssuePresentation = presentation
        let allowed = feedbackPresentationGate.shouldPresent(
            presentation,
            sessionID: feedbackSessionID,
            applicationBundleID: applicationBundleID
        )
        let status = VoiceIssuePresentationPolicy.runtimeStatus(
            for: presentation,
            isPresentationAllowed: allowed
        )
        publish(status, at: status == .idle ? nil : location)
        if case .failed = status {
            sessionHasNoTarget = false
            scheduleIdleReset()
        }
        return allowed
    }

    private func publish(_ newStatus: VoicePointerRuntimeStatus, at location: CGPoint?) {
        status = newStatus
        if case .idle = newStatus, !terminating {
            teacherResumeTask?.cancel()
            let generation = operationGeneration
            teacherResumeTask = Task { [weak self] in
                guard let self else { return }
                await self.waitForCancelledResources()
                guard !Task.isCancelled, !self.terminating, self.operationGeneration == generation,
                      self.status == .idle else { return }
                self.learningObserver?.resumeTeacherRecheck()
            }
        }
        statusHandler(newStatus, location)
    }

    private func cancelFocusWork() {
        focusTask?.cancel()
        focusCancellationToken?.cancel()
        focusCancellationToken = nil
        focusTask = nil
    }

    private func voiceModifier(for keyCode: UInt16) -> VoiceModifier {
        switch keyCode {
        case 58: return .leftOption
        case 61: return .rightOption
        case 55: return .leftCommand
        case 54: return .rightCommand
        case 59: return .leftControl
        case 62: return .rightControl
        case 56: return .leftShift
        case 60: return .rightShift
        default: return .fn
        }
    }
}

/// Independent from MainActor: an input-worker timeout closes the operation
/// and requests the owned key release even while the UI is stalled.
public final class VoiceOperationSafety: @unchecked Sendable {
    private let lock = NSLock()
    private var token: OperationCancellationToken?
    private var lease: OwnedShortcutLease?
    private var inputGeneration: UInt64?
    private var gestureID: UInt64?

    public init() {}

    public func install(_ newToken: OperationCancellationToken, generation: UInt64? = nil, gestureID: UInt64? = nil) {
        lock.lock()
        if token === newToken { lock.unlock(); return }
        let oldToken = token
        let oldLease = lease
        token = newToken
        inputGeneration = generation
        self.gestureID = gestureID
        lease = nil
        oldToken?.cancel()
        lock.unlock()
        oldLease?.cancel()
    }

    public func install(_ newLease: OwnedShortcutLease, for expected: OperationCancellationToken) {
        lock.lock()
        let valid = token === expected && !expected.isCancelled
        if valid { lease = newLease }
        lock.unlock()
        if !valid { newLease.cancel() }
    }

    public func invalidate() {
        invalidate(matching: { true })
    }

    /// A delayed old heartbeat callback must not kill a newer operation
    /// installed after recovery. Compare inside the same ownership lock.
    public func invalidate(olderThanGeneration generation: UInt64) {
        invalidate(matching: { self.inputGeneration.map { $0 < generation } ?? true })
    }

    public func invalidate(gestureID expected: UInt64) {
        invalidate(matching: { self.gestureID == expected })
    }

    public func invalidate(token expected: OperationCancellationToken) {
        invalidate(matching: { self.token === expected })
    }

    private func invalidate(matching predicate: () -> Bool) {
        lock.lock()
        guard predicate() else { lock.unlock(); return }
        token?.cancel()
        let owned = lease
        lease = nil
        lock.unlock()
        owned?.cancel()
    }
}

private final class FocusCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
