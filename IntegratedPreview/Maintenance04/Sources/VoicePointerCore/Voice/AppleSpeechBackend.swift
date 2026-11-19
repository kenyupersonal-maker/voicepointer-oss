import Foundation

/// Capture surface required by the Apple speech backend.
@MainActor
internal protocol AppleSpeechCapture: LocalSpeechCapture {
    var input: BoundedPCMStream? { get }
}

extension LiveAudioPipeline: AppleSpeechCapture {}

/// Apple on-device speech input backend. Streams captured PCM into the
/// existing Recognizer and translates LiveEvents into SpeechInputEvents.
/// No Speech SDK, AX, Keychain, or network access.
@MainActor
@available(macOS 26.0, *)
internal final class AppleSpeechBackend: SpeechInputBackend, SpeechCaptureCancellationInvalidating {
    internal var isQuiescent: Bool { phase == .idle || phase == .done }

    internal var capabilities: SpeechInputCapabilities {
        SpeechInputCapabilities(
            deliveryKind: .transcriptStream,
            supportsPartialText: true,
            supportsHints: false
        )
    }

    private enum Phase: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case done
    }

    internal struct RunnerArguments: Sendable {
        let input: AsyncThrowingStream<OwnedPCMBuffer, Error>
        let sessionID: String
        let locale: Locale
        let startedAt: Double
    }

    internal typealias PermissionRequest = @MainActor () async -> Bool
    internal typealias CaptureFactory = @MainActor () -> AppleSpeechCapture
    internal typealias Runner = @MainActor (
        _ arguments: RunnerArguments,
        _ onEvent: @escaping @Sendable (LiveEvent) async -> Void
    ) async throws -> Void

    internal let requestPermission: PermissionRequest
    internal let makeCapture: CaptureFactory
    internal let runner: Runner

    private var phase: Phase = .idle
    private var startUsed = false
    private var startInFlight = false
    private var startCancelled = false
    private var startExitWaiters: [CheckedContinuation<Void, Never>] = []

    private var capture: AppleSpeechCapture?
    private var captureStopTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    private var activeSessionID: UUID?
    private var activeCallback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
    private var captureStartUptime: Double = 0
    private var nextSequence: UInt64 = 0
    private var pendingFinalText: String?
    private var captureFailed = false
    private var emittedTerminal = false

    internal init(
        requestPermission: @escaping PermissionRequest = {
            await LocalSpeechBackend.requestMicrophonePermission()
        },
        makeCapture: @escaping CaptureFactory = {
            LiveAudioPipeline(
                capacity: 4096,
                appleEnabled: true,
                captureByteLimit: 256 * 1024 * 1024,
                captureDurationSeconds: 300,
                gracefulDurationLimit: true
            )
        },
        runner: @escaping Runner = { arguments, onEvent in
            let recognizer = Recognizer()
            try await recognizer.run(
                input: arguments.input,
                sessionID: arguments.sessionID,
                locale: arguments.locale,
                mode: "live",
                sessionStartUptime: arguments.startedAt,
                onEvent: onEvent,
                timeout: .seconds(330)
            )
        }
    ) {
        self.requestPermission = requestPermission
        self.makeCapture = makeCapture
        self.runner = runner
    }

    private static func locale(for language: String) -> Locale? {
        guard VoiceNativeModelPreparation.isAppleLanguageSupported(language) else { return nil }
        return switch language {
        case "zh": Locale(identifier: "zh-CN")
        case "en": Locale(identifier: "en-US")
        case "yue": Locale(identifier: "yue-CN")
        default: nil
        }
    }

    // MARK: - Lifecycle

    internal func start(
        snapshot: VoiceInputSnapshot,
        onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void
    ) async throws {
        guard !startUsed else {
            throw TrialCoreError.invalid("APPLE_SPEECH_BACKEND_BUSY")
        }
        startUsed = true
        startInFlight = true
        startCancelled = false
        phase = .starting
        defer {
            startInFlight = false
            resumeStartExitWaiters()
        }
        do {
            try await performStart(snapshot: snapshot, onEvent: onEvent)
        } catch {
            await startCleanup()
            throw error
        }
    }

    private func performStart(
        snapshot: VoiceInputSnapshot,
        onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void
    ) async throws {
        let selection = snapshot.selection
        guard selection.mode == .voiceNative else {
            throw TrialCoreError.invalid("APPLE_SPEECH_MODE_MISMATCH")
        }
        guard selection.routeID == "apple-speech" else {
            throw TrialCoreError.invalid("APPLE_SPEECH_ROUTE_MISMATCH")
        }
        guard let locale = Self.locale(for: selection.language) else {
            throw TrialCoreError.invalid("APPLE_SPEECH_LANGUAGE_UNSUPPORTED")
        }

        // Capture, session id, and callback are installed before permission.
        let pipeline = makeCapture()
        guard let input = pipeline.input else {
            throw TrialCoreError.invalid("APPLE_SPEECH_NO_INPUT_STREAM")
        }
        capture = pipeline
        pipeline.onDurationLimitReached = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.startCancelled, self.phase == .listening else { return }
                await self.finish()
            }
        }
        activeSessionID = snapshot.sessionID
        activeCallback = onEvent
        pipeline.onCaptureFailure = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.startCancelled,
                      self.phase == .listening || self.phase == .finishing else { return }
                self.captureFailed = true
                self.requestCaptureStop()
                self.timerTask?.cancel()
                self.runTask?.cancel()
                await self.stopCapture()
                self.emitTerminal(.failed, errorCode: "APPLE_SPEECH_CAPTURE_FAILED")
            }
        }

        try Task.checkCancellation()
        let granted = await requestPermission()
        try Task.checkCancellation()
        if startCancelled { throw CancellationError() }
        guard granted else {
            throw TrialCoreError.invalid("APPLE_SPEECH_PERMISSION_DENIED")
        }

        do {
            try await pipeline.start(streamingToApple: true)
            try Task.checkCancellation()
            if startCancelled { throw CancellationError() }
        } catch {
            throw error
        }
        if pipeline.captureFailure != nil {
            captureFailed = true
            throw TrialCoreError.invalid("APPLE_SPEECH_CAPTURE_FAILED")
        }

        captureStartUptime = ProcessInfo.processInfo.systemUptime
        nextSequence = 0
        pendingFinalText = nil
        emittedTerminal = false
        phase = .listening

        let arguments = RunnerArguments(
            input: input.stream,
            sessionID: snapshot.sessionID.uuidString,
            locale: locale,
            startedAt: captureStartUptime
        )
        runTask = Task { [weak self] in
            await self?.runRecognized(arguments: arguments)
        }
        timerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.finish()
        }
        emit(kind: .ready)
    }

    internal func finish() async {
        switch phase {
        case .listening:
            phase = .finishing
            timerTask?.cancel()
            timerTask = nil
            await stopCapture()
            if let task = runTask { _ = await task.value }
        case .finishing:
            await stopCapture()
            if let task = runTask { _ = await task.value }
        case .starting:
            startCancelled = true
            activeCallback = nil
            requestCaptureStop()
            await awaitStartExit()
        case .idle, .done:
            return
        }
    }

    internal func invalidateCaptureForCancellation() {
        timerTask?.cancel()
        timerTask = nil
        startCancelled = true
        activeCallback = nil
        requestCaptureStop()
        runTask?.cancel()
    }

    internal func cancel() async {
        invalidateCaptureForCancellation()
        switch phase {
        case .listening, .finishing:
            await stopCapture()
            let task = runTask
            task?.cancel()
            if let task { _ = await task.value }
        case .starting:
            await awaitStartExit()
        case .idle, .done:
            break
        }
    }

    // MARK: - Run loop

    private func runRecognized(arguments: RunnerArguments) async {
        do {
            try Task.checkCancellation()
            try await runner(arguments) { [weak self] liveEvent in
                await self?.handleLiveEvent(liveEvent)
            }
            try Task.checkCancellation()
            if capture?.didReachDurationLimit == true, phase == .listening {
                phase = .finishing
            }
            await stopCapture()
            if capture?.captureFailure != nil { captureFailed = true }
            deliverTerminal()
        } catch {
            await stopCapture()
            pendingFinalText = nil
            if !startCancelled {
                emitTerminal(.failed, errorCode: "APPLE_SPEECH_RUN_FAILED")
            }
        }
        await terminalCleanup()
    }

    private func deliverTerminal() {
        if captureFailed {
            emitTerminal(.failed, errorCode: "APPLE_SPEECH_CAPTURE_FAILED")
            return
        }
        guard !startCancelled else { return }
        guard phase == .finishing else {
            // Run ended while still listening: unexpected end of stream.
            emitTerminal(.failed, errorCode: "APPLE_SPEECH_UNEXPECTED_END")
            return
        }
        // Final text may legitimately be the empty string.
        guard let text = pendingFinalText else {
            emitTerminal(.failed, errorCode: "APPLE_SPEECH_FINAL_MISSING")
            return
        }
        emitTerminal(.final, text: text)
    }

    private func handleLiveEvent(_ liveEvent: LiveEvent) {
        guard !startCancelled, !emittedTerminal else { return }
        guard let id = activeSessionID, liveEvent.session_id == id.uuidString else { return }
        if liveEvent.partial, !liveEvent.segment_final, !liveEvent.session_finished {
            guard phase == .listening else { return }
            emit(kind: .partial, text: liveEvent.text)
        } else if liveEvent.segment_final, !liveEvent.session_finished {
            // Stored in .listening or .finishing; delivered after a clean run.
            if let text = liveEvent.text { pendingFinalText = text }
        }
    }

    // MARK: - Cleanup

    private func requestCaptureStop() {
        guard captureStopTask == nil, let capture else { return }
        captureStopTask = Task { @MainActor in await capture.stop() }
    }

    private func stopCapture() async {
        requestCaptureStop()
        await captureStopTask?.value
    }

    private func terminalCleanup() async {
        await stopCapture()
        if let input = capture?.input { input.finish() }
        timerTask?.cancel()
        timerTask = nil
        runTask = nil
        capture?.onDurationLimitReached = nil
        capture = nil
        activeCallback = nil
        activeSessionID = nil
        phase = .done
        captureStopTask = nil
    }

    private func startCleanup() async {
        await stopCapture()
        if let input = capture?.input { input.finish() }
        timerTask?.cancel()
        timerTask = nil
        if let task = runTask {
            task.cancel()
            _ = await task.value
        }
        runTask = nil
        capture?.onDurationLimitReached = nil
        capture = nil
        activeCallback = nil
        activeSessionID = nil
        phase = .done
        captureStopTask = nil
    }

    // MARK: - Events

    private func emit(kind: SpeechInputEvent.Kind, text: String? = nil) {
        guard !startCancelled, !emittedTerminal else { return }
        guard phase == .listening || phase == .finishing else { return }
        guard let sessionID = activeSessionID, let callback = activeCallback else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - captureStartUptime) * 1000
        let milliseconds = elapsed.isFinite && elapsed >= 0 ? elapsed : 0
        let event = SpeechInputEvent(
            sessionID: sessionID,
            sequence: nextSequence,
            observedMilliseconds: milliseconds,
            kind: kind,
            text: text,
            errorCode: nil
        )
        nextSequence += 1
        callback(event)
    }

    private func emitTerminal(
        _ kind: SpeechInputEvent.Kind,
        text: String? = nil,
        errorCode: String? = nil
    ) {
        guard !emittedTerminal, !startCancelled else { return }
        guard let sessionID = activeSessionID, let callback = activeCallback else { return }
        emittedTerminal = true
        let elapsed = (ProcessInfo.processInfo.systemUptime - captureStartUptime) * 1000
        let milliseconds = elapsed.isFinite && elapsed >= 0 ? elapsed : 0
        let event = SpeechInputEvent(
            sessionID: sessionID,
            sequence: nextSequence,
            observedMilliseconds: milliseconds,
            kind: kind,
            text: text,
            errorCode: errorCode
        )
        nextSequence += 1
        callback(event)
    }

    // MARK: - Waiters

    private func awaitStartExit() async {
        guard startInFlight else { return }
        await withCheckedContinuation { startExitWaiters.append($0) }
    }

    private func resumeStartExitWaiters() {
        let waiters = startExitWaiters
        startExitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
