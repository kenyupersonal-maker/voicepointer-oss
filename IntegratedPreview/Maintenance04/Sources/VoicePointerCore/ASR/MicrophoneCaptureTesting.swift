@preconcurrency import AVFoundation
import Foundation
import CAudioMeterSupport

// T1 self-test seam: the real tap callback, CaptureSink, shared capture view,
// LocalSpeechBackend, PCM converter and session are exercised with fake
// permission/catalog/worker boundaries. No engine, microphone, files or network.
@_spi(Testing) public struct MicrophoneCaptureProbeResult: Sendable {
    public let inferenceCalls: Int
    public let inferredNonzeroBytes: Int
    public let acceptedBuffers: Int
    public let finals: Int
    public let failureCode: String?
    public let level: Float
    public let diagnostics: String
    public let confidence: LocalModelConfidence?
}

@_spi(Testing) public struct MicrophoneCloudProbeResult: Sendable {
    public let preparesBeforeAudio: Int
    public let credentialReads: Int
    public let prepares: Int
    public let pcmSends: Int
    public let finishCommands: Int
    public let transcriptionCalls: Int
    public let finals: Int
    public let failureCode: String?
}

private actor SyntheticCredentialReader {
    private(set) var calls = 0
    func read() -> Data { calls += 1; return Data() }
}

private actor SyntheticCloudTransport: AliSpeechTransport, GroqSpeechTransport {
    let sessionID: UUID
    private(set) var prepares = 0
    private(set) var pcmSends = 0
    private(set) var finishCommands = 0
    private(set) var transcriptionCalls = 0
    private var cancelled = false
    init(sessionID: UUID) { self.sessionID = sessionID }
    func prepare(credential: Data) async throws { prepares += 1 }
    func sendPCM(_ data: Data) async throws { pcmSends += 1 }
    func finishInput() async throws { finishCommands += 1 }
    func nextEvent() async throws -> AliIPCOutput {
        while finishCommands == 0 && !cancelled {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !cancelled else { throw CancellationError() }
        return AliIPCOutput(sessionID: sessionID, sequence: 0, observedMilliseconds: 0,
                            kind: "final", text: "", errorCode: nil)
    }
    func transcribe(wav: Data) async throws -> GroqWireResult {
        transcriptionCalls += 1
        return GroqWireResult(sessionID: sessionID, text: "", hostMilliseconds: 0, requestMilliseconds: 0)
    }
    func cancel() async { cancelled = true }
    func isQuiescent() async -> Bool { prepares == 0 || cancelled }
}

@MainActor
private final class SyntheticGatedCapture: LocalSpeechCapture {
    let store = CapturedPCMStore()
    let sink: CaptureSink
    var onCaptureFailure: (@Sendable (String) -> Void)?
    var onDurationLimitReached: (@Sendable () -> Void)?
    var captureFailure: TrialCoreError? { store.failure }
    private(set) var stopped = false
    let epoch: UInt64 = 1_000_000_000

    init() { sink = CaptureSink(store: store, input: nil) }
    func snapshotBuffers() -> [OwnedPCMBuffer] { store.snapshot() }
    func start(streamingToApple: Bool) throws {
        guard !streamingToApple else { throw TrialCoreError.invalid("SYNTHETIC_APPLE_DISABLED") }
        sink.beginCapture(now: epoch)
        sink.setFailureHandler { [weak self] code in
            Task { @MainActor [weak self] in self?.onCaptureFailure?(code) }
        }
    }
    func stop() { stopped = true; sink.finish() }
    func feed(_ buffer: AVAudioPCMBuffer, milliseconds: UInt64) {
        let timestamp = epoch + milliseconds * 1_000_000
        AudioTapCallbackFactory.make(sink: sink, now: { timestamp })(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate))
    }
}

private actor SyntheticMicrophoneClient: BetaInferenceClient {
    private let confidence: LocalModelConfidence?
    init(confidence: LocalModelConfidence? = nil) { self.confidence = confidence }
    private(set) var calls = 0
    private(set) var nonzeroBytes = 0
    func start() async throws {}
    func shutdown() async {}
    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool) async throws -> BetaWorkerResult {
        try await infer(sessionID: sessionID, revision: revision, pcm: pcm, final: final, context: nil)
    }
    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool, context: BetaRecognitionContext?) async throws -> BetaWorkerResult {
        calls += 1
        nonzeroBytes += pcm.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
        return BetaWorkerResult(type: "result", session_id: sessionID, revision: revision,
                                text: "SYNTHETIC_PCM_OK", final: final, compute_ms: 1,
                                model_confidence: confidence?.probability,
                                model_confidence_source: confidence?.source.rawValue,
                                model_confidence_token_count: confidence?.tokenCount)
    }
}

@_spi(Testing) @MainActor public enum MicrophoneCaptureTesting {
    /// Exercises the production sink across a tap-generation change, using only synthetic PCM.
    public static func routeResume(first: AVAudioPCMBuffer, second: AVAudioPCMBuffer, sameRoute: Bool) throws -> (buffers: Int, failure: Bool, frames: Int) {
        let store = CapturedPCMStore()
        // Keep one sink/store pair throughout the simulated engine replacement.
        let active = CaptureSink(store: store, input: nil)
        active.beginCapture()
        let oldCallback = AudioTapCallbackFactory.make(sink: active)
        let time = AVAudioTime(sampleTime: 0, atRate: first.format.sampleRate)
        oldCallback(first, time)
        active.resumeCapture()
        oldCallback(first, time) // a late callback from the detached engine must be ignored.
        if sameRoute {
            AudioTapCallbackFactory.make(sink: active)(second, time)
        } else {
            active.finish() // changed device/format preserves only the old segment.
        }
        active.finish()
        let snapshot = store.snapshot()
        return (snapshot.count, store.failure != nil, snapshot.reduce(0) { $0 + Int($1.buffer.frameLength) })
    }
    public static func runCloud(buffers: [AVAudioPCMBuffer], noCallbacks: Bool = false,
                                shared: Bool = false, groq: Bool = false,
                                finishImmediately: Bool = false) async throws -> MicrophoneCloudProbeResult {
        let source = SyntheticGatedCapture()
        let hub = SharedCaptureHub(makeSource: { source })
        let sessionID = UUID()
        let transport = SyntheticCloudTransport(sessionID: sessionID)
        let credential = SyntheticCredentialReader()
        let makeCapture: @MainActor () -> any LocalSpeechCapture = {
            if shared { return hub.makeView(.cloud) }
            return source
        }
        let backend: any SpeechInputBackend
        if groq {
            backend = GroqSpeechBackend(consentGranted: true, makeTransport: { _ in transport },
                                        readCredential: { await credential.read() }, requestPermission: { true },
                                        makeCapture: makeCapture)
        } else {
            // Only a disposable test store receives these fictional grants.
            // The production gate/settings and all credential stores are untouched.
            let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
                .appendingPathComponent("MicrophoneCloudProbe-\(UUID().uuidString)").appendingPathComponent("state.json")
            let gate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: file))
            let identity = try CloudAdmissionIdentity(provider: "test", accountReference: "synthetic",
                                                      credentialRevision: "synthetic", region: "test",
                                                      workspace: "test", modelID: "test")
            _ = await gate.setPolicy(.freeOnly, for: identity)
            _ = await gate.confirmFreeOnlyGuard(for: identity, verificationRevision: "synthetic")
            let requirements = CloudAdmissionRequirements(cloudRouteEnabled: true, credentialAvailable: true,
                                                           sampleUploadAllowed: true, sessionUploadAllowed: true)
            guard case .admitted(let permit) = await gate.admission(for: identity, requirements: requirements) else {
                throw TrialCoreError.invalid("SYNTHETIC_ADMISSION_FAILED")
            }
            let admission = CloudStreamAdmission(inputs: .init(gate: gate, identity: identity, requirements: requirements), permit: permit)
            backend = AliSpeechBackend(consentGranted: true, makeTransport: { _ in transport },
                                       readCredential: { await credential.read() }, requestPermission: { true },
                                       makeCapture: makeCapture, admission: admission)
        }
        let selection = try VoiceInputSelection(mode: .voiceNative, routeID: groq ? "groq-v3" : "aliyun", language: "zh")
        let snapshot = try VoiceInputSnapshot(sessionID: sessionID, selection: selection, lexiconRevision: 0)
        var finals = 0
        var failureCode: String?
        try await backend.start(snapshot: snapshot) { event in
            if event.kind == .final { finals += 1 }
            if event.kind == .failed { failureCode = event.errorCode }
        }
        try await Task.sleep(for: .milliseconds(50))
        let preparesBeforeAudio = await transport.prepares
        for (index, buffer) in buffers.enumerated() { source.feed(buffer, milliseconds: UInt64(index) * 650) }
        if noCallbacks { source.sink.checkSilence(now: source.epoch + 1_500_000_000) }
        if !finishImmediately { try await Task.sleep(for: .milliseconds(150)) }
        if shared { await hub.stop() }
        await backend.finish()
        return MicrophoneCloudProbeResult(preparesBeforeAudio: preparesBeforeAudio, credentialReads: await credential.calls,
                                           prepares: await transport.prepares, pcmSends: await transport.pcmSends,
                                           finishCommands: await transport.finishCommands,
                                           transcriptionCalls: await transport.transcriptionCalls,
                                           finals: finals, failureCode: failureCode)
    }

    public static func diagnosticLogLines(format: AVAudioFormat) -> [String] {
        let deviceFields = VPCAudioInputDiagnosticFields()
        return [CaptureDiagnosticLog.start(deviceFields: deviceFields, format: format),
                CaptureDiagnosticLog.end(deviceFields: deviceFields, diagnostics: CaptureAudioDiagnostics()),
                CaptureDiagnosticLog.reopen(attempt: 1), VPCAudioMeterDiagnosticLogProbe()]
    }

    public static func run(buffers: [AVAudioPCMBuffer], noCallbacks: Bool = false,
                           shared: Bool = false, confidence: LocalModelConfidence? = nil) async throws -> MicrophoneCaptureProbeResult {
        let source = SyntheticGatedCapture()
        let hub = SharedCaptureHub(makeSource: { source })
        let client = SyntheticMicrophoneClient(confidence: confidence)
        let pool = LocalWorkerPool(factory: { _, _ in client })
        let profile = BetaProfile(id: "qwen17-rolling", label: "Synthetic", summary: "Synthetic",
                                  backend: "qwen", host: nil, correction: "none", streaming_kind: "rolling",
                                  max_seconds: 30, initial_seconds: 0.1, interval_seconds: 0.2,
                                  experimental: false, required_files: [], languages: ["zh"])
        let makeCapture: @MainActor () -> any LocalSpeechCapture = {
            if shared { return hub.makeView(.local) }
            return source
        }
        let backend = LocalSpeechBackend(pool: pool, loadProfiles: { [profile] }, requestPermission: { true }, makeCapture: makeCapture)
        let selection = try VoiceInputSelection(mode: .voiceNative, routeID: "qwen17-rolling", language: "zh")
        let snapshot = try VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 0)
        var events: [SpeechInputEvent.Kind] = []
        var failureCode: String?
        var finalConfidence: LocalModelConfidence?
        try await backend.start(snapshot: snapshot) { event in
            events.append(event.kind)
            if event.kind == .failed { failureCode = event.errorCode }
            if event.kind == .final { finalConfidence = event.confidenceEvidence }
        }
        for (index, buffer) in buffers.enumerated() {
            source.feed(buffer, milliseconds: UInt64(index) * 650)
        }
        if noCallbacks { source.sink.checkSilence(now: source.epoch + 1_500_000_000) }
        // Let the actual local polling task see the empty gated snapshot.
        try await Task.sleep(for: .milliseconds(150))
        if shared { await hub.stop() }
        await backend.finish()
        await pool.shutdownAll()
        let level = CaptureLevelBus.shared.recent(now: source.epoch + UInt64(max(0, buffers.count - 1)) * 650_000_000) ?? 0
        return MicrophoneCaptureProbeResult(inferenceCalls: await client.calls, inferredNonzeroBytes: await client.nonzeroBytes,
                                            acceptedBuffers: source.snapshotBuffers().count,
                                            finals: events.filter { $0 == .final }.count,
                                            failureCode: failureCode, level: level, diagnostics: source.sink.diagnostics.fields(),
                                            confidence: finalConfidence)
    }
}
