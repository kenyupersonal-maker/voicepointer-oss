import Foundation
import AVFoundation

internal protocol AliSpeechTransport: Sendable {
    func readinessTiming() async -> AliHostReadyTiming?
    func prepare(credential: Data) async throws
    func sendPCM(_ data: Data) async throws
    func finishInput() async throws
    func nextEvent() async throws -> AliIPCOutput
    func cancel() async
    func isQuiescent() async -> Bool
}

extension AliSpeechTransport {
    func readinessTiming() async -> AliHostReadyTiming? { nil }
}

extension AliTranscriptionClient: AliSpeechTransport {}

internal enum AliBackendError: Error {
    case invalid
    case permission
    case startFailed
}

@MainActor
final class AliSpeechBackend: SpeechInputBackend, SpeechCaptureCancellationInvalidating, SpeechCaptureActivityProviding {
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
    let makeTransport: @MainActor (VoiceInputSnapshot) throws -> any AliSpeechTransport
    let readCredential: @Sendable () async throws -> Data
    let requestPermission: @MainActor () async -> Bool
    let makeCapture: @MainActor () -> any LocalSpeechCapture

    var phase: Phase = .idle
    var used = false
    var cancelled = false
    var captureError = false
    var terminal = false
    var finishSent = false
    var snapshot: VoiceInputSnapshot?
    var callback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
    var startedAt: TimeInterval = 0
    private(set) var audibleWaitMs = 0
    private(set) var credentialReadMs = 0
    private(set) var readyTiming: AliHostReadyTiming?
    var sequence: UInt64 = 0
    var transport: (any AliSpeechTransport)?
    var capture: (any LocalSpeechCapture)?
    var captureStopTask: Task<[OwnedPCMBuffer], Never>?
    var converter: BetaPCMAccumulator?
    var sentBytes = 0
    var captureHasAudio = false
    var startTask: Task<Void, Error>?
    var prepareTask: Task<Void, Error>?
    var senderTask: Task<Void, Never>?
    var supervisorTask: Task<Void, Never>?
    var finishTask: Task<Void, Never>?
    var failureCode: String?
    // Retain finite evidence through transport cleanup, never in transcript events or logs.
    var failureEvidence: AliFailureEvidence?
    // K06. Without an admitted permit the backend can never start: cloud audio is closed by default.
    let admission: CloudStreamAdmission?
    let arbiter: CloudStreamArbiter?
    var revocationTask: Task<Int, Never>?
    var pauseEvidenceHandled = false

    init(
        consentGranted: Bool,
        makeTransport: @escaping @MainActor (VoiceInputSnapshot) throws -> any AliSpeechTransport,
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
        },
        admission: CloudStreamAdmission? = nil
    ) {
        self.consentGranted = consentGranted
        self.makeTransport = makeTransport
        self.readCredential = readCredential
        self.requestPermission = requestPermission
        self.makeCapture = makeCapture
        self.admission = admission
        self.arbiter = admission.map { CloudStreamArbiter(admission: $0) }
    }

    var isQuiescent: Bool {
        phase == .idle || phase == .done
    }

    /// Keep only finite service and credential categories; never retain provider text.
    func recordFailure(_ error: any Error) {
        guard !cancelled, !terminal, !(error is CancellationError) else { return }
        let code: String
        if let diagnostic = SpeechFailureDiagnostics.aliDiagnostic(for: error) {
            code = diagnostic.code.rawValue
        } else {
            code = "ALI_STREAM_FAILED"
        }
        if let existing = failureCode,
           existing != "ALI_STREAM_FAILED", existing != "ALI_TRANSCRIBE_FAILED" {
            return
        }
        failureCode = code
        failureEvidence = (error as? AliServiceFailure)?.evidence
    }

    var capabilities: SpeechInputCapabilities {
        SpeechInputCapabilities(
            deliveryKind: .transcriptStream,
            supportsPartialText: true,
            supportsHints: false
        )
    }

    func start(
        snapshot: VoiceInputSnapshot,
        onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void
    ) async throws {
        guard !used else {
            used = true
            throw AliBackendError.invalid
        }
        used = true
        guard consentGranted else { throw AliBackendError.invalid }
        // K06: no admitted permit, no cloud session (and no microphone capture on its behalf).
        guard arbiter != nil else { throw AliBackendError.invalid }
        guard snapshot.selection.mode == .voiceNative else { throw AliBackendError.invalid }
        guard snapshot.selection.routeID == "aliyun" else { throw AliBackendError.invalid }
        guard CloudEntry.supportedLanguages.contains(snapshot.selection.language) else {
            throw AliBackendError.invalid
        }
        self.snapshot = snapshot
        self.callback = onEvent
        self.startedAt = ProcessInfo.processInfo.systemUptime
        self.transport = try makeTransport(snapshot)
        self.converter = try BetaPCMAccumulator(maxSeconds: 300)
        self.phase = .starting

        let task = Task<Void, Error> { @MainActor [self] in
            try Task.checkCancellation()
            guard await requestPermission() else { throw AliBackendError.permission }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            let mic = makeCapture()
            capture = mic
            mic.onCaptureFailure = { [weak self] code in
                Task { @MainActor in
                    guard let self else { return }
                    if self.phase == .listening && !self.cancelled {
                        self.captureError = true
                        if MicrophoneSilenceGate.isSilenceCode(code) { self.failureCode = code }
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
            guard let transport else { throw AliBackendError.invalid }
            let preparation = Task<Void, Error> { [transport, readCredential] in
                // T1: prepare opens an ASR task, not merely an idle connection.
                // Do not read a key or launch it until gated PCM has real audio.
                let audioAt = ProcessInfo.processInfo.systemUptime
                try await self.waitForAudibleCapture()
                self.audibleWaitMs = Int((ProcessInfo.processInfo.systemUptime - audioAt) * 1000)
                // K06: a permit the gate no longer recognises must not read the key or open a request.
                guard await self.streamMayPrepare() else { throw AliBackendError.invalid }
                let keyAt = ProcessInfo.processInfo.systemUptime
                var key = try await readCredential()
                defer { key.resetBytes(in: 0..<key.count); key.removeAll(keepingCapacity: false) }
                self.credentialReadMs = Int((ProcessInfo.processInfo.systemUptime - keyAt) * 1000)
                try Task.checkCancellation()
                try await transport.prepare(credential: key)
                self.readyTiming = await transport.readinessTiming()
            }
            prepareTask = preparation
            phase = .listening
            senderTask = Task { @MainActor [weak self] in
                await self?.runSender()
            }
            supervisorTask = Task { @MainActor [weak self] in
                await self?.runSupervisor()
            }
        }
        startTask = task
        do {
            try await task.value
        } catch {
            if cancelled { throw CancellationError() }
            await cancel()
            if let permission = error as? AliBackendError, case .permission = permission {
                throw permission
            }
            throw AliBackendError.startFailed
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
            if !buffers.isEmpty { self.captureHasAudio = true }
            if capture.captureFailure != nil {
                self.captureError = true
                if let code = capture.captureFailure?.description, MicrophoneSilenceGate.isSilenceCode(code) {
                    self.failureCode = code
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
            errorCode: errorCode
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
