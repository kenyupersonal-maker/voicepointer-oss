import Foundation
import AVFoundation

protocol GroqSpeechTransport: Sendable {
    func prepare(credential: Data) async throws
    func transcribe(wav: Data) async throws -> GroqWireResult
    func cancel() async
    func isQuiescent() async -> Bool
}

extension GroqTranscriptionClient: GroqSpeechTransport {}

enum GroqBackendError: Error {
    case invalid
    case permission
    case startFailed
}

@MainActor
final class GroqSpeechBackend: SpeechInputBackend, SpeechCaptureCancellationInvalidating, SpeechCaptureActivityProviding {
    var hasAcceptedCaptureAudio: Bool { !(capture?.snapshotBuffers().isEmpty ?? true) }

    enum Phase {
        case idle
        case starting
        case listening
        case finishing
        case cleaning
        case done
    }

    let consentGranted: Bool
    let provider: OnlineAPIProvider
    let makeTransport: @MainActor (VoiceInputSnapshot) throws -> any GroqSpeechTransport
    let readCredential: @Sendable () async throws -> Data
    let requestPermission: @MainActor () async -> Bool
    let makeCapture: @MainActor () -> any LocalSpeechCapture

    var phase: Phase = .idle
    var used = false
    var cancelled = false
    var captureError = false
    var captureFailureCode: String?
    var terminal = false
    var snapshot: VoiceInputSnapshot?
    var callback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
    var startedAt: TimeInterval = 0
    var requestMilliseconds: Int64 = 0
    var sequence: UInt64 = 0
    var transport: (any GroqSpeechTransport)?
    var capture: (any LocalSpeechCapture)?
    var captureStopTask: Task<[OwnedPCMBuffer], Never>?
    var startTask: Task<Void, Error>?
    var prepareTask: Task<Void, Error>?
    var observerTask: Task<Void, Never>?
    var finishTask: Task<Void, Never>?

    init(
        consentGranted: Bool,
        provider: OnlineAPIProvider = .groq,
        makeTransport: @escaping @MainActor (VoiceInputSnapshot) throws -> any GroqSpeechTransport,
        readCredential: @escaping @Sendable () async throws -> Data,
        requestPermission: @escaping @MainActor () async -> Bool = { await LocalSpeechBackend.requestMicrophonePermission() },
        makeCapture: @escaping @MainActor () -> any LocalSpeechCapture = {
            LiveAudioPipeline(
                capacity: 32,
                appleEnabled: false,
                captureByteLimit: 256 * 1024 * 1024,
                captureDurationSeconds: 300,
                gracefulDurationLimit: true
            )
        }
    ) {
        self.consentGranted = consentGranted
        self.provider = provider
        self.makeTransport = makeTransport
        self.readCredential = readCredential
        self.requestPermission = requestPermission
        self.makeCapture = makeCapture
    }

    var isQuiescent: Bool {
        phase == .idle || phase == .done
    }

    var capabilities: SpeechInputCapabilities {
        SpeechInputCapabilities(
            deliveryKind: .transcriptStream,
            supportsPartialText: false,
            supportsHints: false
        )
    }

    func start(
        snapshot: VoiceInputSnapshot,
        onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void
    ) async throws {
        guard !used else {
            used = true
            throw GroqBackendError.invalid
        }
        used = true
        guard consentGranted else { throw GroqBackendError.invalid }
        guard snapshot.selection.mode == .voiceNative else { throw GroqBackendError.invalid }
        let allowed = provider == .groq ? ["groq-v3", "groq-turbo"] : provider == .openai ? ["openai-transcribe", "openai-mini-transcribe"] : provider == .siliconflow ? ["siliconflow-sensevoice"] : []
        guard allowed.contains(snapshot.selection.routeID) else { throw GroqBackendError.invalid }
        guard VoiceInputSelection.isBoundedLanguageTag(snapshot.selection.language) else {
            throw GroqBackendError.invalid
        }
        self.snapshot = snapshot
        self.callback = onEvent
        self.startedAt = ProcessInfo.processInfo.systemUptime
        self.transport = try makeTransport(snapshot)
        self.phase = .starting

        let task = Task<Void, Error> { @MainActor [self] in
            try Task.checkCancellation()
            guard await requestPermission() else { throw GroqBackendError.permission }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            let mic = makeCapture()
            capture = mic
            mic.onCaptureFailure = { [weak self] code in
                Task { @MainActor in
                    guard let self else { return }
                    if self.phase == .listening && !self.cancelled {
                        self.captureError = true
                        if MicrophoneSilenceGate.isSilenceCode(code) { self.captureFailureCode = code }
                    }
                    await self.finish()
                }
            }
            mic.onDurationLimitReached = { [weak self] in
                Task { @MainActor in
                    await self?.finish()
                }
            }
            try await mic.start(streamingToApple: false)
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            guard let transport else { throw GroqBackendError.invalid }
            let preparation = Task<Void, Error> { [transport, readCredential] in
                let key = try await readCredential()
                try Task.checkCancellation()
                try await transport.prepare(credential: key)
            }
            prepareTask = preparation
            phase = .listening
            observerTask = Task { @MainActor [weak self] in
                do {
                    try await preparation.value
                    guard let self, !self.cancelled, self.phase == .listening else { return }
                    self.emit(.ready)
                } catch {
                    guard let self, !self.cancelled, self.phase == .listening else { return }
                    self.captureError = true
                    await self.finish()
                }
            }
        }
        startTask = task
        do {
            try await task.value
        } catch {
            if cancelled { throw CancellationError() }
            await cancel()
            throw GroqBackendError.startFailed
        }
    }

    func requestCaptureStop() {
        guard captureStopTask == nil, let capture else { return }
        capture.onCaptureFailure = nil
        capture.onDurationLimitReached = nil
        captureStopTask = Task { @MainActor [weak self] in
            await capture.stop()
            let buffers = capture.snapshotBuffers()
            guard let self else { return buffers }
            if capture.captureFailure != nil {
                self.captureError = true
                if let code = capture.captureFailure?.description, MicrophoneSilenceGate.isSilenceCode(code) {
                    self.captureFailureCode = code
                }
            }
            self.capture = nil
            return buffers
        }
    }

    func stopCapture() async -> [OwnedPCMBuffer] {
        requestCaptureStop()
        return await captureStopTask?.value ?? []
    }

    func emit(
        _ kind: SpeechInputEvent.Kind,
        text: String? = nil,
        errorCode: String? = nil
    ) {
        guard !terminal, let snapshot else { return }
        let elapsed = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        let event = SpeechInputEvent(
            sessionID: snapshot.sessionID,
            sequence: sequence,
            observedMilliseconds: elapsed,
            kind: kind,
            text: text,
            errorCode: errorCode.map { provider == .openai ? SpeechFailureDiagnostics.openAICode($0) : $0 }
        )
        sequence += 1
        switch kind {
        case .final, .failed, .stopped:
            terminal = true
        default:
            break
        }
        callback?(event)
        if terminal { callback = nil }
    }
}
