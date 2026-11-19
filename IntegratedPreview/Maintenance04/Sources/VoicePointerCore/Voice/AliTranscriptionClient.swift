import Foundation

internal enum AliClientError: Error { case state, failed, cleanup, taskStartFailed }

internal actor AliTranscriptionClient {
    private enum Phase { case idle, preparing, ready, finishing, closing, done }
    private let sessionID: UUID; private let endpoint: AliEndpoint
    private let language: String; private let worker: StreamingLineWorker
    private let modelID: String
    private let checkOnly: Bool
    private var phase: Phase = .idle, cancelled = false
    private var expectedSequence: UInt64 = 0, lastClock: Double = 0
    private var sending = false, reading = false, totalPCM = 0
    private var readyTimings: AliHostReadyTiming?
    func readinessTiming() -> AliHostReadyTiming? { readyTimings }

    init(sessionID: UUID, endpoint: AliEndpoint, language: String, worker: StreamingLineWorker, modelID: String = AliIPC.legacyModelID, checkOnly: Bool = false) throws {
        guard ["zh", "en", "auto"].contains(language), AliIPC.supportedModelIDs.contains(modelID) else { throw AliClientError.state }
        self.sessionID = sessionID; self.endpoint = endpoint
        self.language = language; self.worker = worker
        self.modelID = modelID
        self.checkOnly = checkOnly
    }

    private func checkAlive(_ allowed: Phase...) throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        guard allowed.contains(phase) else { throw AliClientError.state }
    }

    private func cleanup() async {
        await worker.shutdown()
        phase = await worker.isQuiescent() ? .done : .closing
    }

    private func fail(_ error: Error, fallback: AliClientError = .failed) async throws -> Never {
        await cleanup()
        if cancelled || error is CancellationError { throw CancellationError() }
        if let failure = error as? AliServiceFailure { throw failure }
        if error is AliIPCError { throw error }
        if error is StreamingWorkerError { throw error }
        if let client = error as? AliClientError {
            switch client {
            case .state, .cleanup, .taskStartFailed: throw client
            case .failed: break
            }
        }
        throw fallback
    }

    private func failure(from output: AliIPCOutput) -> AliServiceFailure {
        AliServiceFailure(AliServiceFailure.Code(rawValue: output.errorCode ?? "") ?? .streamFailed,
                          evidence: output.failureEvidence)
    }

    private func validated(_ line: Data) throws -> AliIPCOutput {
        let out = try AliIPC.decodeOutput(line)
        guard out.sessionID == sessionID, out.sequence == expectedSequence,
              out.observedMilliseconds >= lastClock else { throw AliClientError.failed }
        expectedSequence += 1; lastClock = out.observedMilliseconds
        return out
    }

    func prepare(credential: Data) async throws {
        guard phase == .idle else { throw AliClientError.state }
        phase = .preparing
        do {
            var frame = try AliIPC.encodeCommand(
                .configure(sessionID: sessionID, endpoint: endpoint, language: language, credential: credential, modelID: modelID, checkOnly: checkOnly))
            defer { frame.resetBytes(in: 0..<frame.count); frame.removeAll(keepingCapacity: false) }
            let launchAt = ProcessInfo.processInfo.systemUptime
            let ready = try await worker.launch(initialLine: frame)
            let elapsed = (ProcessInfo.processInfo.systemUptime - launchAt) * 1000
            try checkAlive(.preparing)
            let out = try validated(ready)
            if out.kind == "failed" { throw failure(from: out) }
            guard out.kind == "ready" else { throw AliClientError.failed }
            readyTimings = AliHostReadyTiming(workerMs: max(0, elapsed - out.observedMilliseconds),
                connectMs: out.readyTiming?.connectMs, taskStartMs: out.readyTiming?.taskStartMs,
                path: out.readyTiming?.path ?? "system")
            phase = .ready
        } catch {
            // The app waits 15 s for `ready` and the worker gives up on the connection after its own 15 s, which
            // starts later, so a stalled connection ends here first. That is a timeout, not a broken worker.
            if case DuplexLineError.timeout = error { try await fail(AliServiceFailure(.timeout)) }
            try await fail(error, fallback: .taskStartFailed)
        }
    }

    func sendPCM(_ data: Data) async throws {
        guard phase == .ready, !sending, !checkOnly else { throw AliClientError.state }
        guard data.count % 2 == 0, (2...32000).contains(data.count),
              totalPCM + data.count <= 9_600_000 else { throw AliClientError.failed }
        sending = true
        defer { sending = false }
        do {
            try await worker.sendLine(AliIPC.encodeCommand(.pcm(data)))
            try checkAlive(.ready)
            totalPCM += data.count
        } catch { try await fail(error) }
    }

    func finishInput() async throws {
        guard phase == .ready, !sending, !checkOnly else { throw AliClientError.state }
        phase = .finishing
        do {
            try await worker.sendLine(try AliIPC.encodeCommand(.finish))
            // A valid final can arrive before this send continuation resumes.
            try checkAlive(.finishing, .done)
        } catch { try await fail(error) }
    }

    func nextEvent() async throws -> AliIPCOutput {
        guard (phase == .ready || phase == .finishing), !reading, !checkOnly else { throw AliClientError.state }
        reading = true
        defer { reading = false }
        let out: AliIPCOutput
        do {
            let line = try await worker.readLine(timeout: 360)
            try checkAlive(.ready, .finishing)
            out = try validated(line)
        } catch { try await fail(error) }
        switch out.kind {
        case "partial":
            return out
        case "final":
            await worker.shutdown()
            do { try checkAlive(.ready, .finishing) } catch { try await fail(error) }
            guard await worker.isQuiescent() else { phase = .closing; throw AliClientError.cleanup }
            phase = .done
            return out
        default:
            await cleanup()
            if cancelled { throw CancellationError() }
            if out.kind == "failed" { throw failure(from: out) }
            throw AliClientError.failed
        }
    }

    func cancel() async {
        cancelled = true; phase = .closing
        await worker.shutdown()
        if await worker.isQuiescent() { phase = .done }
    }

    func isQuiescent() async -> Bool { await worker.isQuiescent() }

    /// Worker ack proves finish-task was sent and its socket cancelled, without audio.
    func finishConnectionCheck() async throws {
        guard checkOnly, phase == .ready, !reading else { throw AliClientError.state }
        reading = true; phase = .finishing
        defer { reading = false }
        do {
            let output = try validated(await worker.readLine(timeout: 8))
            if output.kind == "failed" { throw failure(from: output) }
            guard output.kind == "checked" else { throw AliClientError.failed }
            await cleanup()
            guard await worker.isQuiescent() else { throw AliClientError.cleanup }
            if cancelled { throw CancellationError() }
        } catch { try await fail(error) }
    }
}
