import Foundation

/// Only a no-body catalog GET. No realtime worker, inference task or audio/text
/// input is involved. Responses are reduced to finite outcomes and never logged.
public enum CloudModelCatalogVerifier {
    public enum Failure: Error, Sendable, Equatable {
        case noKey, keyUnreadable, rejectedKey, accessDenied, network, timeout
        case redirect, endpointMismatch, bodyTooLarge, invalidSchema, service
        public var setupFailure: HealthFailureReason {
            switch self {
            case .noKey: .noKey
            case .keyUnreadable, .rejectedKey: .invalidKey
            case .network: .network
            case .timeout: .timeout
            default: .unavailable
            }
        }
    }
    public enum Outcome: Sendable, Equatable {
        case authenticated, failed(Failure), cancelled
        public var setupVerification: CloudSetupVerification {
            switch self {
            case .authenticated: .authenticated
            case .failed(let reason): .failed(reason.setupFailure)
            case .cancelled: .notNetworkVerified
            }
        }
    }
    public struct Response: Sendable {
        public let status: Int
        public let url: URL
        public let body: Data
        public init(status: Int, url: URL, body: Data) {
            self.status = status; self.url = url; self.body = body
        }
    }
    public typealias Transport = @Sendable (URLRequest) async throws -> Response
    public static let defaultTimeout: TimeInterval = 12
    public static let maximumBodyBytes = 256 * 1024
    public static let maximumModels = 1024
    public static let successMessage = "密钥认证和模型目录访问已验证；未发送声音，ASR 与免费额度仍未验证。"

    /// Both dependencies are injectable; tests must pass an in-memory key source
    /// and fake transport. The caller checks endpoint/credential/UI generations.
    public static func run(endpoint: CloudModelCatalogEndpoint, timeout: TimeInterval = defaultTimeout,
                           readKey: @escaping @Sendable () async throws -> Data,
                           transport: @escaping Transport = urlSessionTransport,
                           isCurrent: @escaping @Sendable () async -> Bool = { true }) async -> Outcome {
        let race = CatalogVerificationRace()
        let seconds = timeout.isFinite ? min(20, max(0.05, timeout)) : defaultTimeout
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.begin(continuation)
                let work = Task {
                    let outcome: Outcome
                    do {
                        try Task.checkCancellation()
                        guard await isCurrent() else { race.finish(.cancelled); return }
                        let key = try await readKey()
                        try Task.checkCancellation()
                        guard await isCurrent() else { race.finish(.cancelled); return }
                        guard (16...4096).contains(key.count),
                              key.allSatisfy({ $0 >= 33 && $0 <= 126 }),
                              let value = String(data: key, encoding: .utf8), value.hasPrefix("sk-") else {
                            throw Failure.keyUnreadable
                        }
                        var request = URLRequest(url: endpoint.modelsURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                                 timeoutInterval: seconds)
                        request.httpMethod = "GET"
                        request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        let response = try await transport(request)
                        try Task.checkCancellation()
                        guard await isCurrent() else { race.finish(.cancelled); return }
                        outcome = evaluate(response, endpoint: endpoint)
                    } catch is CancellationError { outcome = .cancelled }
                    catch let reason as Failure { outcome = .failed(reason) }
                    catch let credential as CredentialError {
                        outcome = .failed(credential == .missing ? .noKey : .keyUnreadable)
                    } catch let error as URLError {
                        outcome = error.code == .cancelled ? .cancelled : .failed(error.code == .timedOut ? .timeout : .network)
                    } catch { outcome = .failed(.network) }
                    race.finish(outcome)
                }
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    race.finish(.failed(.timeout))
                }
                race.attach(work: work, timer: timer)
            }
        } onCancel: { race.finish(.cancelled) }
    }

    /// Documented workspace ListModels envelope, never an OpenAI data/id list.
    /// Only the first page is requested; a partial or empty catalog authenticates
    /// without asserting ASR access, fetching more pages or inspecting prices.
    public static func evaluate(_ response: Response, endpoint: CloudModelCatalogEndpoint) -> Outcome {
        guard response.url == endpoint.modelsURL else { return .failed(.endpointMismatch) }
        if (300..<400).contains(response.status) { return .failed(.redirect) }
        if response.status == 401 { return .failed(.rejectedKey) }
        if response.status == 403 { return .failed(.accessDenied) }
        guard response.status == 200 else { return .failed(.service) }
        guard response.body.count <= maximumBodyBytes else { return .failed(.bodyTooLarge) }
        guard jsonDepthIsBounded(response.body),
              let result = try? JSONDecoder().decode(CatalogEnvelope.self, from: response.body) else {
            return .failed(.invalidSchema)
        }
        guard result.success else {
            // Finite documented error codes; never surface/log provider text.
            // https://help.aliyun.com/zh/model-studio/error-code
            switch result.code {
            case "InvalidApiKey", "invalid_api_key": return .failed(.rejectedKey)
            case "AccessDenied", "access_denied", "Workspace.AccessDenied": return .failed(.accessDenied)
            default: return .failed(.service)
            }
        }
        guard result.code == nil, result.message == nil, let page = result.output,
              page.total >= 0, page.page_no == 1, page.page_size > 0,
              page.models.count <= maximumModels, page.models.count <= page.page_size,
              page.models.count <= page.total, page.models.isEmpty == (page.total == 0),
              page.models.allSatisfy({ row in
                  (1...256).contains(row.model.utf8.count)
                      && row.model.utf8.allSatisfy { (33...126).contains($0) }
              }) else { return .failed(.invalidSchema) }
        return .authenticated
    }

    private struct CatalogEnvelope: Decodable {
        let success: Bool
        let code: String?, message: String?
        let output: CatalogPage?
        private enum CodingKeys: String, CodingKey { case success, code, message, output, error }
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            guard !fields.contains(.error) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                       debugDescription: "Conflicting catalog error envelope"))
            }
            success = try fields.decode(Bool.self, forKey: .success)
            code = try fields.decodeIfPresent(String.self, forKey: .code)
            message = try fields.decodeIfPresent(String.self, forKey: .message)
            output = success ? try fields.decode(CatalogPage.self, forKey: .output) : nil
        }
    }
    private struct CatalogPage: Decodable {
        struct Model: Decodable { let model: String }
        let total: Int, page_no: Int, page_size: Int
        let models: [Model]
    }
    // Bound nesting before Foundation allocates/parses an untrusted JSON tree.
    private static func jsonDepthIsBounded(_ data: Data) -> Bool {
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 8 { return false } }
            else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0 && !quoted
    }

    public static let urlSessionTransport: Transport = { request in
        // Revalidate even at the transport boundary; never accept a task URL or
        // body from a future caller. The session is created only for this click.
        guard let url = request.url, let endpoint = CloudModelCatalogEndpoint(address: url.absoluteString),
              url == endpoint.modelsURL,
              request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil else {
            throw Failure.endpointMismatch
        }
        let transaction = CatalogURLSessionTransaction(expectedURL: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transaction.start(request, continuation: $0) }
        } onCancel: { transaction.cancel() }
    }
}

private final class CatalogVerificationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: CloudModelCatalogVerifier.Outcome?
    private var continuation: CheckedContinuation<CloudModelCatalogVerifier.Outcome, Never>?
    private var work: Task<Void, Never>?, timer: Task<Void, Never>?
    func begin(_ continuation: CheckedContinuation<CloudModelCatalogVerifier.Outcome, Never>) {
        let prior = lock.withLock { () -> CloudModelCatalogVerifier.Outcome? in
            if let outcome { return outcome }
            self.continuation = continuation; return nil
        }
        if let prior { continuation.resume(returning: prior) }
    }
    func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let settled = lock.withLock { () -> Bool in
            guard outcome == nil else { return true }
            self.work = work; self.timer = timer; return false
        }
        if settled { work.cancel(); timer.cancel() }
    }
    func finish(_ value: CloudModelCatalogVerifier.Outcome) {
        let handles = lock.withLock { () -> (CheckedContinuation<CloudModelCatalogVerifier.Outcome, Never>?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard outcome == nil else { return nil }
            outcome = value
            let taken = (continuation, work, timer)
            continuation = nil; work = nil; timer = nil
            return taken
        }
        guard let (continuation, work, timer) = handles else { return }
        work?.cancel(); timer?.cancel(); continuation?.resume(returning: value)
    }
}

/// Streaming size limit and unconditional redirect denial apply before any
/// response body is exposed. Ephemeral session has no cookies/cache/credentials.
private final class CatalogURLSessionTransaction: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let expectedURL: URL
    private var result: Result<CloudModelCatalogVerifier.Response, any Error>?
    private var continuation: CheckedContinuation<CloudModelCatalogVerifier.Response, any Error>?
    private var session: URLSession?, task: URLSessionDataTask?
    private var status: Int?, body = Data()
    init(expectedURL: URL) { self.expectedURL = expectedURL }
    func start(_ request: URLRequest, continuation: CheckedContinuation<CloudModelCatalogVerifier.Response, any Error>) {
        let prior = lock.withLock { () -> Result<CloudModelCatalogVerifier.Response, any Error>? in
            if let result { return result }
            self.continuation = continuation; return nil
        }
        if let prior { continuation.resume(with: prior); return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let cancelled = lock.withLock { () -> Bool in
            guard result == nil else { return true }
            self.session = session; self.task = task; return false
        }
        if cancelled { session.invalidateAndCancel() } else { task.resume() }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ value: Result<CloudModelCatalogVerifier.Response, any Error>) {
        let taken = lock.withLock { () -> (CheckedContinuation<CloudModelCatalogVerifier.Response, any Error>?, URLSession?, URLSessionDataTask?)? in
            guard result == nil else { return nil }
            result = value
            let handles = (continuation, session, task)
            continuation = nil; session = nil; task = nil; body.removeAll(keepingCapacity: false)
            return handles
        }
        guard let (continuation, session, task) = taken else { return }
        task?.cancel(); session?.invalidateAndCancel(); continuation?.resume(with: value)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)  // Deny same-host and cross-host redirects alike.
        finish(.failure(CloudModelCatalogVerifier.Failure.redirect))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == expectedURL else {
            completionHandler(.cancel); finish(.failure(CloudModelCatalogVerifier.Failure.endpointMismatch)); return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.success(.init(status: http.statusCode, url: expectedURL, body: Data()))); return
        }
        guard response.expectedContentLength <= CloudModelCatalogVerifier.maximumBodyBytes else {
            completionHandler(.cancel); finish(.failure(CloudModelCatalogVerifier.Failure.bodyTooLarge)); return
        }
        let active = lock.withLock { () -> Bool in
            guard result == nil else { return false }
            status = http.statusCode; return true
        }
        completionHandler(active ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Bool in
            guard result == nil else { return false }
            guard data.count <= CloudModelCatalogVerifier.maximumBodyBytes - body.count else { return true }
            body.append(data); return false
        }
        if overflow { finish(.failure(CloudModelCatalogVerifier.Failure.bodyTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        let response = lock.withLock { () -> CloudModelCatalogVerifier.Response? in
            guard result == nil, let status else { return nil }
            return .init(status: status, url: expectedURL, body: body)
        }
        if let response { finish(.success(response)) }
        else { finish(.failure(CloudModelCatalogVerifier.Failure.invalidSchema)) }
    }
}
