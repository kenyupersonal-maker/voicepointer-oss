import Foundation
import VoicePointerCore

public enum FocusCancellationChecks {
    public static func run() -> [String] {
        let token = OperationCancellationToken()
        let scope = FocusOperationScope(cancellationToken: token, deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        token.cancel()
        var failures: [String] = []
        if scope.isValid { failures.append("cancel gate failed") }
        let expired = FocusOperationScope(deadline: DispatchTime.now().uptimeNanoseconds - 1)
        if expired.isValid { failures.append("deadline gate failed") }

        let preCancelled = FocusCancellationFake(token: token)
        _ = SmartFocusEngine(provider: preCancelled).focus(at: .zero, mode: .smart, cancellationToken: token)
        if preCancelled.reads != 0 || preCancelled.writes != 0 { failures.append("pre-cancelled focus touched provider") }

        let snapshotToken = OperationCancellationToken()
        let snapshotFake = FocusCancellationFake(token: snapshotToken, cancelAt: .snapshot)
        let snapshotResult = SmartFocusEngine(provider: snapshotFake).focus(at: .zero, mode: .smart, cancellationToken: snapshotToken)
        if snapshotResult.outcome != .cancelled || snapshotFake.writes != 0 {
            failures.append("snapshot cancellation allowed late focus write")
        }

        let writeToken = OperationCancellationToken()
        let writeFake = FocusCancellationFake(token: writeToken, cancelAt: .write)
        _ = SmartFocusEngine(provider: writeFake).focus(at: .zero, mode: .smart,
            configuration: .init(synthesizeClickFallback: true), cancellationToken: writeToken)
        if writeFake.clicks != 0 || writeFake.verifications != 0 {
            failures.append("cancelled focus write continued to verification or click")
        }

        let verifyToken = OperationCancellationToken()
        let verifyFake = FocusCancellationFake(token: verifyToken, cancelAt: .verification)
        let verifyResult = SmartFocusEngine(provider: verifyFake).focus(at: .zero, mode: .smart, cancellationToken: verifyToken)
        if verifyResult.outcome != .cancelled { failures.append("cancelled verification reported focus success") }

        let nilFake = FocusCancellationFake(token: OperationCancellationToken(), nilSnapshot: true)
        let nilResult = SmartFocusEngine(provider: nilFake).focus(at: .zero, mode: .smart)
        if nilResult.outcome != .unavailable || nilFake.legacyCalls != 0 {
            failures.append("nil scoped snapshot bypassed guarded provider")
        }
        return failures
    }
}

/// Synchronous test-owned fake; never shared concurrently. Both provider
/// paths are instrumented to detect falling back from a scoped failure.
private final class FocusCancellationFake: ScopedFocusProviding, @unchecked Sendable {
    enum Stage { case none, snapshot, write, verification }
    let token: OperationCancellationToken
    let cancelAt: Stage
    let nilSnapshot: Bool
    var reads = 0
    var writes = 0
    var clicks = 0
    var verifications = 0
    var legacyCalls = 0
    init(token: OperationCancellationToken, cancelAt: Stage = .none, nilSnapshot: Bool = false) {
        self.token = token; self.cancelAt = cancelAt; self.nilSnapshot = nilSnapshot
    }
    private var sample: FocusSnapshot {
        .init(contextIdentifier: "offline", bundleIdentifier: nil, candidates: [
            .init(identifier: "editor", role: "AXTextArea", frame: .init(x: 0, y: 0, width: 500, height: 120), isPointerInside: true)
        ])
    }
    func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration, scope: FocusOperationScope) -> FocusSnapshot? {
        guard scope.isValid else { return nil }
        reads += 1
        if cancelAt == .snapshot { token.cancel() }
        return nilSnapshot ? nil : sample
    }
    func setFocused(candidateIdentifier: String, scope: FocusOperationScope) -> Bool {
        guard scope.isValid else { return false }
        writes += 1
        if cancelAt == .write { token.cancel() }
        return true
    }
    func isFocused(candidateIdentifier: String, scope: FocusOperationScope) -> Bool {
        guard scope.isValid else { return false }
        verifications += 1
        if cancelAt == .verification { token.cancel() }
        return true
    }
    func synthesizeClick(candidateIdentifier: String, scope: FocusOperationScope) -> Bool {
        guard scope.isValid else { return false }
        clicks += 1
        return true
    }
    func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? { legacyCalls += 1; return sample }
    func setFocused(candidateIdentifier: String) -> Bool { legacyCalls += 1; return true }
    func isFocused(candidateIdentifier: String) -> Bool { legacyCalls += 1; return true }
    func synthesizeClick(candidateIdentifier: String) -> Bool { legacyCalls += 1; return true }
}
