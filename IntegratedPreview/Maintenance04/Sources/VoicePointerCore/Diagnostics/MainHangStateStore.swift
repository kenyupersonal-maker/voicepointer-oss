import Foundation

/// Small, content-free state copied by the background hang observer. Never
/// store transcript, editor value, window title, or AX attribute values here.
public struct MainHangState: Sendable {
    public var phase = "idle"
    public var routeID = "none"
    public var targetBundleID = "none"
    public var operation = "none"
}

public enum MainHangOperation: String, Sendable {
    case hudUpdate
    case permissionPoll
    case statusPermissionRead
    case axObserverRemove
}

public final class MainHangStateStore: @unchecked Sendable {
    public static let shared = MainHangStateStore()

    private let lock = NSLock()
    private var state = MainHangState()

    private init() {}

    public func setPhase(_ phase: String) {
        lock.withLock { state.phase = Self.safeLabel(phase) }
    }

    public func setRouteID(_ routeID: String?) {
        lock.withLock { state.routeID = Self.safeLabel(routeID ?? "none") }
    }

    public func setTargetBundleID(_ bundleID: String?) {
        lock.withLock { state.targetBundleID = Self.safeLabel(bundleID ?? "none") }
    }

    /// Main-thread work may nest. Restore the outer breadcrumb on return.
    @discardableResult
    public func withOperation<T>(_ operation: MainHangOperation, _ body: () throws -> T) rethrows -> T {
        let previous = lock.withLock { () -> String in
            let previous = state.operation
            state.operation = operation.rawValue
            return previous
        }
        defer { lock.withLock { state.operation = previous } }
        return try body()
    }

    public func snapshot() -> MainHangState { lock.withLock { state } }

    private static func safeLabel(_ raw: String) -> String {
        let allowed = raw.unicodeScalars.filter {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
        let label = String(String.UnicodeScalarView(allowed.prefix(96)))
        return label.isEmpty ? "unknown" : label
    }
}
