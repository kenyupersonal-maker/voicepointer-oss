import Foundation

internal enum AliSocketError: Error {
    case invalid
    case state
    case failed
}

internal actor AliWebSocketConnection {

    private final class RedirectRejector: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var openedAt: TimeInterval?
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didOpenWithProtocol protocol: String?) {
            lock.lock(); openedAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
        }
        func openedTime() -> TimeInterval? {
            lock.lock(); defer { lock.unlock() }; return openedAt
        }
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let endpoint: AliEndpoint
    private var keyData: Data
    private let wireCodec: AliWireCodec
    private let taskID: UUID

    private var started = false
    private var ready = false
    private var closed = false
    private var finishing = false
    private var writing = false
    private var receiving = false

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var timeoutTask: Task<Void, Never>?
    private var timedOut = false
    private var timing: AliIPCOutput.ReadyTiming?
    func readinessTiming() -> AliIPCOutput.ReadyTiming? { timing }

    internal init(endpoint: AliEndpoint, credential: Data, taskID: UUID, language: String, hints: AliRecognitionHints? = nil, modelID: String = AliWireCodec.legacyModelID) throws {
        guard credential.count >= 16, credential.count <= 4096 else { throw AliSocketError.invalid }
        guard let keyString = String(data: credential, encoding: .utf8) else { throw AliSocketError.invalid }
        guard keyString.allSatisfy({ $0.isASCII && $0.asciiValue! >= 33 && $0.asciiValue! <= 126 }) else {
            throw AliSocketError.invalid
        }
        self.endpoint = endpoint
        self.keyData = credential
        self.taskID = taskID
        self.wireCodec = try AliWireCodec(taskID: taskID, language: language, hints: hints, modelID: modelID)
    }

    internal func start() async throws {
        guard !started, !closed else { throw AliSocketError.state }
        started = true
        do { try await connect(direct: endpoint.prefersDirectConnection) }
        catch {
            // Retry only a transport failure before WebSocket opens: no task/audio could have been accepted.
            let retryable = (error as? AliServiceFailure)?.code
            guard endpoint.prefersDirectConnection, !closed, !Task.isCancelled,
                  retryable == .networkFailed || retryable == .timeout else { await cancel(); throw error }
            do { try await connect(direct: false) } catch { await cancel(); throw error }
        }
    }

    private func connect(direct: Bool) async throws {

        let keyString = String(data: keyData, encoding: .utf8) ?? ""
        var request = URLRequest(url: endpoint.url, timeoutInterval: 15)
        request.setValue("Bearer \(keyString)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.ephemeral
        if direct { config.connectionProxyDictionary = [:] }
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false

        let delegate = RedirectRejector()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1048576

        let timeoutTask = Task<Void, Never> { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { await self?.handleTimeout() }
        }
        self.session = session
        self.socket = socket
        self.timeoutTask = timeoutTask
        timedOut = false

        do {
            let resumedAt = ProcessInfo.processInfo.systemUptime
            socket.resume()
            try await socket.send(.string(String(data: wireCodec.startCommand(), encoding: .utf8)!))
            if closed || Task.isCancelled { throw AliSocketError.failed }

            let message = try await socket.receive()
            if closed || Task.isCancelled { throw AliSocketError.failed }
            let data = try Self.decoderPayload(message)

            guard case .started = try wireCodec.parse(data) else { throw AliSocketError.failed }
            if let openedAt = delegate.openedTime() {
                let finishedAt = ProcessInfo.processInfo.systemUptime
                timing = .init(connectMs: max(0, (openedAt - resumedAt) * 1000),
                    taskStartMs: max(0, (finishedAt - openedAt) * 1000), path: direct ? "direct" : "system")
            }
            timeoutTask.cancel()
            self.timeoutTask = nil
            if closed || Task.isCancelled { throw AliSocketError.failed }
            ready = true
        } catch {
            timeoutTask.cancel()
            let failure = classifyFailure(error, socket: socket)
            // An opened socket may already have accepted start; never repeat that task.
            if delegate.openedTime() != nil || closed || Task.isCancelled { await cancel() }
            else {
                socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
                self.socket = nil; self.session = nil; self.timeoutTask = nil
            }
            throw failure
        }
    }

    internal func sendPCM(_ data: Data) async throws {
        guard ready, !closed, !finishing else { throw AliSocketError.state }
        guard data.count >= 2, data.count <= 32000, data.count % 2 == 0 else { throw AliSocketError.invalid }
        guard !writing, let socket else { throw AliSocketError.state }
        writing = true
        defer { writing = false }
        do {
            try await socket.send(.data(data))
            if closed { throw AliSocketError.failed }
            if Task.isCancelled { throw CancellationError() }
        } catch {
            let failure = classifyFailure(error, socket: socket)
            await cancel()
            throw failure
        }
    }

    internal func finish() async throws {
        guard ready, !closed, !finishing, !writing else { throw AliSocketError.state }
        finishing = true
        guard let socket else { throw AliSocketError.state }
        do {
            try await socket.send(.string(String(data: wireCodec.finishCommand(), encoding: .utf8)!))
            if closed { throw AliSocketError.failed }
            if Task.isCancelled { throw CancellationError() }
        } catch {
            let failure = classifyFailure(error, socket: socket)
            await cancel()
            throw failure
        }
    }

    internal func receive() async throws -> AliWireEvent {
        guard ready, !closed, !receiving, let socket else { throw AliSocketError.state }
        receiving = true
        defer { receiving = false }
        do {
            let message = try await socket.receive()
            if closed { throw AliSocketError.failed }
            if Task.isCancelled { throw CancellationError() }
            let data = try Self.decoderPayload(message)
            return try wireCodec.parse(data)
        } catch {
            let failure = classifyFailure(error, socket: socket)
            await cancel()
            throw failure
        }
    }

    internal func cancel() async {
        closed = true
        ready = false
        timeoutTask?.cancel()
        timeoutTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        keyData.resetBytes(in: 0..<keyData.count)
        keyData.removeAll(keepingCapacity: false)
    }

    private static func decoderPayload(_ message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8), data.count <= 1048576 else { throw AliSocketError.invalid }
            return data
        case .data:
            throw AliSocketError.invalid
        @unknown default:
            throw AliSocketError.invalid
        }
    }

    private func handleTimeout() {
        guard !closed, !ready else { return }
        timedOut = true
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Classify a caught error into the finite vocabulary. Never reclassify real
    /// cancellation; read the HTTP status from the live socket before cancel clears it.
    private func classifyFailure(_ error: any Error, socket currentSocket: URLSessionWebSocketTask?) -> any Error {
        if Task.isCancelled || error is CancellationError || (closed && !timedOut) { return CancellationError() }
        if let socketError = error as? AliSocketError {
            switch socketError {
            case .invalid, .state: return socketError
            case .failed: break
            }
        }
        // A task-failed frame is distinct from the HTTP handshake. Never attach
        // the socket's HTTP status to its code-only evidence.
        if let ali = error as? AliServiceFailure { return ali }
        if timedOut { return AliServiceFailure(.timeout) }
        let status = (currentSocket?.response as? HTTPURLResponse)?.statusCode
        // No response body is available here. Keep status-only evidence; never
        // invent a provider code or issue an extra probe request.
        return AliServiceFailure.transport(error, httpStatus: status)
    }
}
