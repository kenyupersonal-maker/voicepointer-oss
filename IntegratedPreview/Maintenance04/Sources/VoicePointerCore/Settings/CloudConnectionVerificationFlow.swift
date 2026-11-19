import Foundation

/// Shared by setup, saved-key renewal and the explicit settings connection click.
/// Only closures can supply a credential or transport; constructing this flow
/// performs no I/O. Visibility/epoch fencing discards every obsolete result.
@MainActor
public enum CloudConnectionVerificationFlow {
    public typealias Handshake = @Sendable (Data) async throws -> Void

    /// F1 owns the finite code and the actionable Chinese sentence. The UI
    /// never quotes an error's description or a service response.
    public nonisolated static func failureMessage(_ failure: CloudConnectionCheck.Failure) -> String {
        SpeechFailureDiagnostics.aliDiagnostic(for: failure).message
    }

    /// The existing Aliyun zero-audio path. It sends a task-start handshake and
    /// closes the worker without audio. Billing is not inferred from this API.
    public nonisolated static func aliyunHandshake(_ credential: Data) async throws {
        let handshake = try CloudConnectionCheck.aliyunHandshake(endpoint: AliEndpoint.defaultURLString)
        try await handshake(credential)
    }

    public static func run(
        timeout: TimeInterval = CloudConnectionCheck.defaultTimeout,
        readKey: @escaping @Sendable () async throws -> Data,
        handshake: @escaping Handshake,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> CloudSetupVerification {
        guard isCurrent(), !Task.isCancelled else { return .notNetworkVerified }
        let outcome = await CloudConnectionCheck.run(timeout: timeout,
            readKey: {
                try Task.checkCancellation()
                guard await isCurrent() else { throw CancellationError() }
                return try await readKey()
            }, handshake: { key in
                try Task.checkCancellation()
                guard await isCurrent() else { throw CancellationError() }
                try await handshake(key)
            })
        guard isCurrent(), !Task.isCancelled else { return .notNetworkVerified }
        switch outcome {
        case .connected: return .authenticated
        case .failed(let failure): return .connectionFailed(failure)
        }
    }
}
