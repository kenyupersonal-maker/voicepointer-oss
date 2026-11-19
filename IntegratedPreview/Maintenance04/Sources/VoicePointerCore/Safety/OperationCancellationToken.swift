import Foundation

/// Token supporting parent-to-child cancellation commit.
/// Lock ordering: parent lock is acquired first and held across the child body;
/// No reentrancy or blocking calls allowed inside body.
public final class OperationCancellationToken: @unchecked Sendable {

    private let parent: OperationCancellationToken?
    private let lock = NSLock()
    private var cancelled = false

    public init(parent: OperationCancellationToken? = nil) {
        self.parent = parent
    }

    public var isCancelled: Bool {
        // Parent state first, then own state.
        if let parent {
            if parent.isCancelled { return true }
        }
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Cancel this token only (not the parent).
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    /// Commit atomically: with a parent, the child commit runs inside the
    /// parent's commitIfValid closure so the parent lock stays held across
    /// the child body (parent-to-child ordering). Body must not reenter
    /// these tokens or block.
    public func commitIfValid<T>(_ body: () -> T) -> T? {
        if let parent {
            // Outer result only is unwrapped; child commit is nested inside.
            if let result = parent.commitIfValid({ self.commitOwn(body) }) {
                return result
            }
            return nil
        }
        return commitOwn(body)
    }

    /// Hold own lock across the cancelled guard and body execution.
    private func commitOwn<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return nil }
        return body()
    }
}
