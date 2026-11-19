import CoreGraphics

/// CoreGraphics separates passive event listening from event synthesis.
/// Accessibility alone is not a sufficient readiness signal for raw touch
/// input on current macOS releases.
public enum EventAccessPermission {
    public static var canListen: Bool {
        CGPreflightListenEventAccess()
    }

    public static var canPost: Bool {
        CGPreflightPostEventAccess()
    }

    @discardableResult
    public static func requestListenIfNeeded() -> Bool {
        canListen || CGRequestListenEventAccess()
    }

    @discardableResult
    public static func requestPostIfNeeded() -> Bool {
        canPost || CGRequestPostEventAccess()
    }
}
