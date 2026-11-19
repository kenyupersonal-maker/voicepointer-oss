import Foundation

internal enum GroqClientError: Error, Sendable {
    case state
    case cleanup
    case failed

    var code: String {
        switch self {
        case .state: return "GROQ_CLIENT_STATE"
        case .cleanup: return "GROQ_CLIENT_CLEANUP"
        case .failed: return "GROQ_CLIENT_FAILED"
        }
    }
}

internal actor GroqTranscriptionClient {
    private enum Phase {
        case idle
        case preparing
        case ready
        case transcribing
        case closed
    }

    private let worker: OneShotLineWorker
    private let wire: GroqWireProtocol
    private var phase: Phase = .idle
    private var cancelled = false
    private var readyHost: Double?

    internal init(command: [String], sessionID: UUID, routeID: String, language: String, timeout: TimeInterval = 45, provider: OnlineAPIProvider = .groq, modelID: String? = nil) throws {
        self.worker = OneShotLineWorker(command: command, timeout: timeout)
        self.wire = try GroqWireProtocol(sessionID: sessionID, routeID: routeID, language: language, provider: provider, modelID: modelID)
    }

    internal func prepare(credential: Data) async throws {
        guard phase == .idle else { throw GroqClientError.state }
        phase = .preparing
        do {
            try checkCancellation()
            let line = try wire.configurationLine(credential: credential)
            let response = try await worker.launch(initialLine: line)
            try checkCancellation()
            guard phase == .preparing, !cancelled else { throw CancellationError() }
            readyHost = try wire.parseReady(response)
            phase = .ready
        } catch {
            phase = .closed
            await worker.shutdown()
            if cancelled || error is CancellationError { throw CancellationError() }
            switch error {
            case is GroqWireError, is LineWorkerError:
                throw error
            default:
                throw GroqClientError.failed
            }
        }
    }

    internal func transcribe(wav: Data) async throws -> GroqWireResult {
        guard phase == .ready, let host = readyHost else { throw GroqClientError.state }
        phase = .transcribing
        do {
            try checkCancellation()
            let request = try wire.transcriptionLine(wav: wav)
            let response = try await worker.finish(finalLine: request)
            try checkCancellation()
            guard phase == .transcribing, !cancelled else { throw CancellationError() }
            let result = try wire.parseFinal(response, readyHostMilliseconds: host)
            let quiet = await worker.isQuiescent()
            try checkCancellation()
            guard phase == .transcribing, !cancelled else { throw CancellationError() }
            guard quiet else { throw GroqClientError.cleanup }
            phase = .closed
            return result
        } catch {
            phase = .closed
            await worker.shutdown()
            if cancelled || error is CancellationError { throw CancellationError() }
            switch error {
            case is GroqWireError, is LineWorkerError, GroqClientError.cleanup:
                throw error
            default:
                throw GroqClientError.failed
            }
        }
    }

    internal func cancel() async {
        cancelled = true
        phase = .closed
        await worker.shutdown()
    }

    internal func isQuiescent() async -> Bool {
        if phase == .idle { return true }
        if phase != .closed { return false }
        return await worker.isQuiescent()
    }

    private func checkCancellation() throws {
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
}
