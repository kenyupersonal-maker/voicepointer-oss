import Foundation

/// The settings' "测试连接" for the Aliyun key.
///
/// One handshake with the realtime service: the saved key goes to the sandboxed worker over its pipe, the worker
/// opens the connection, sends the task start and waits for the service to accept it. No audio is sent and no
/// text comes back, so nothing is transcribed. What returns is a finite outcome the page can explain; it never
/// carries the key, a response body or an account detail.
///
/// Pure orchestration: the key source and the handshake are closures, so the self-tests drive every outcome with
/// fakes and never touch the network, the worker or a real key.
public enum CloudConnectionCheck {
    public enum Failure: Sendable, Equatable, CaseIterable {
        /// Nothing is saved.
        case noKey
        /// A key file exists but the local store cannot read it.
        case keyUnreadable
        /// The service does not accept this key.
        case rejectedKey
        /// The key is fine but the account may not use this model.
        case noAccess
        case freeQuotaExhausted
        case balanceDue
        case rateLimited
        case modelUnavailable
        case serviceUnavailable
        case network
        case timeout
        /// The bundled worker is missing, would not start or stopped on its own.
        case worker
        /// The task did not become ready; the available evidence does not establish why.
        case taskStartFailed
        /// The worker could not be confirmed stopped after the check.
        case notClosed
        case unknown
    }

    public enum Outcome: Sendable, Equatable {
        case connected
        case failed(Failure)

        /// Fixed vocabulary for the local log. Never a message from the service.
        public var logLabel: String {
            switch self {
            case .connected: return "connected"
            case .failed(let failure): return "failed.\(failure)"
            }
        }
    }

    /// What a real handshake throws when the worker side, not the service, is the problem.
    public enum HandshakeError: Error, Sendable, Equatable {
        case workerUnavailable
        case notClosed
    }

    /// Optional diagnostic evidence; no credentials, provider strings or response bodies.
    /// Quiescence is measured by the owned worker, never inferred from an outcome.
    public enum HandshakeObservation: Sendable, Equatable {
        case taskStarted
        case serviceFailure(AliFailureEvidence.Source)
        case cancellationRequested
        case workerQuiescent(Bool)
    }

    /// The longest the page waits. The worker itself gives up on the connection after 15 s.
    public static let defaultTimeout: TimeInterval = 25

    public static let successMessage = "连接正常：阿里云接受了这个 Key，识别模型可用。测试没有发送声音。"

    /// Reads the key, runs the handshake, and turns whatever happens into an `Outcome` within `timeout`.
    /// When the time runs out the handshake is cancelled (which shuts its worker down) and the outcome is
    /// `.timeout` without waiting for it to unwind, so the page never hangs on a stuck worker.
    public static func run(
        timeout: TimeInterval = defaultTimeout,
        readKey: @escaping @Sendable () async throws -> Data,
        handshake: @escaping @Sendable (Data) async throws -> Void
    ) async -> Outcome {
        let race = Race()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard race.begin(continuation) else { return }
                let work = Task {
                    let outcome: Outcome
                    do {
                        try Task.checkCancellation()
                        guard race.isActive else { throw CancellationError() }
                        var key = try await readKey()
                        defer { key.resetBytes(in: 0..<key.count); key.removeAll(keepingCapacity: false) }
                        try Task.checkCancellation()
                        guard race.isActive else { throw CancellationError() }
                        try await handshake(key)
                        outcome = .connected
                    } catch {
                        outcome = .failed(classify(error))
                    }
                    race.finish(outcome, cancelWork: false)
                }
                let timer = Task {
                    let nanoseconds = UInt64(max(0.05, timeout) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    race.finish(.failed(.timeout), cancelWork: true)
                }
                race.attach(work: work, timer: timer)
            }
        }, onCancel: {
            // The owner fences this result before publication. Cancel the
            // worker promptly even when its callback ignores cancellation.
            race.finish(.failed(.unknown), cancelWork: true)
        })
    }

    /// The real handshake for the Aliyun route, using the endpoint the dictation uses. Throws when the endpoint
    /// is not a valid Aliyun realtime address.
    public static func aliyunHandshake(
        endpoint: String,
        modelID: String = AliWireCodec.legacyModelID,
        observe: (@Sendable (HandshakeObservation) -> Void)? = nil
    ) throws -> @Sendable (Data) async throws -> Void {
        try AliBackendFactory.makeConnectionHandshake(endpoint: endpoint, modelID: modelID, observe: observe)
    }

    /// Maps any error a key read or a handshake can throw onto the finite vocabulary.
    public static func classify(_ error: any Error) -> Failure {
        if let credential = error as? CredentialError {
            switch credential {
            case .missing: return .noKey
            case .corrupt, .storage, .invalidKey: return .keyUnreadable
            }
        }
        if let handshake = error as? HandshakeError {
            switch handshake {
            case .workerUnavailable: return .worker
            case .notClosed: return .notClosed
            }
        }
        if let failure = error as? AliServiceFailure {
            switch failure.code {
            case .authFailed: return .rejectedKey
            case .accessDenied: return .noAccess
            case .freeQuotaExhausted: return .freeQuotaExhausted
            case .balanceDue: return .balanceDue
            case .rateLimited: return .rateLimited
            case .modelUnavailable: return .modelUnavailable
            case .serviceUnavailable: return .serviceUnavailable
            case .networkFailed: return .network
            case .timeout: return .timeout
            case .invalidRequest, .streamFailed: return .unknown
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .network
        }
        if let worker = error as? StreamingWorkerError {
            switch worker {
            case .cleanup: return .notClosed
            case .launch, .invalid, .state: return .worker
            }
        }
        if let client = error as? AliClientError {
            switch client {
            case .cleanup: return .notClosed
            case .taskStartFailed: return .taskStartFailed
            case .state, .failed: return .unknown
            }
        }
        return .unknown
    }
}

extension CloudConnectionCheck.Failure {
    /// One plain sentence for the settings page, with what to do next. It never quotes the service.
    public var message: String {
        SpeechFailureDiagnostics.aliDiagnostic(for: self).message
    }
}

/// Lets exactly one of the handshake and the timer decide the outcome.
private final class Race: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CloudConnectionCheck.Outcome, Never>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var settled = false

    private var cancelledBeforeBegin = false

    var isActive: Bool { lock.withLock { !settled && !cancelledBeforeBegin } }

    func begin(_ continuation: CheckedContinuation<CloudConnectionCheck.Outcome, Never>) -> Bool {
        let cancelled = lock.withLock { () -> Bool in
            self.continuation = continuation
            return cancelledBeforeBegin
        }
        if cancelled { finish(.failed(.unknown), cancelWork: true) }
        return !cancelled
    }

    /// The tasks may already have finished by the time they are handed over.
    func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let alreadySettled = lock.withLock { () -> Bool in
            if settled { return true }
            self.work = work
            self.timer = timer
            return false
        }
        if alreadySettled {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(_ outcome: CloudConnectionCheck.Outcome, cancelWork: Bool) {
        let taken = lock.withLock { () -> (CheckedContinuation<CloudConnectionCheck.Outcome, Never>, Task<Void, Never>?, Task<Void, Never>?)? in
            guard !settled else { return nil }
            guard let continuation else {
                if cancelWork { cancelledBeforeBegin = true }
                return nil
            }
            settled = true
            let handles = (continuation, work, timer)
            self.continuation = nil
            work = nil
            timer = nil
            return handles
        }
        guard let (continuation, work, timer) = taken else { return }
        timer?.cancel()
        if cancelWork { work?.cancel() }
        continuation.resume(returning: outcome)
    }
}
