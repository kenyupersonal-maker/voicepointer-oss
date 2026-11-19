import Foundation

/// One-shot invalidation gate shared by all focus-notification callbacks
/// (AX and workspace) of a single composer target watch. Ensures the token
/// is cancelled and the caller notified exactly once across the first real
/// identity mismatch, while repeated matching notifications stay silent.
/// Redundant notifications for the SAME frozen element/window are a normal
/// macOS behavior and must not invalidate; switching away and back does not
/// revive a cancelled token.
@_spi(Testing)
public final class ComposerFocusEventGate: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var returnPosted = false
    private var invalidationKind: String?

    public init() {}

    /// Returns true (exactly once per gate) when the notification does not
    /// match the frozen identity and the gate has never invalidated before;
    /// atomically marks the gate invalidated in that case. Returns false for
    /// matching notifications and for any call after the first invalidation.
    public func shouldInvalidate(matchesFrozenIdentity: Bool, kind: String = "other") -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return false }
        guard !matchesFrozenIdentity else { return false }
        invalidated = true
        invalidationKind = ["focusElement", "focusWindow", "workspace"].contains(kind) ? kind : "other"
        return true
    }

    /// Called inside the same token commit as the accepted Return key pair.
    public func noteReturnPosted() { lock.lock(); returnPosted = true; lock.unlock() }

    public var hasPostedReturn: Bool {
        lock.lock(); defer { lock.unlock() }; return returnPosted
    }

    /// A finite observation, never permission to write into a replacement editor.
    public var postReturnInvalidation: String? {
        lock.lock(); defer { lock.unlock() }
        return returnPosted ? invalidationKind : nil
    }

    /// Read-only, lock-protected state.
    public var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }
}
