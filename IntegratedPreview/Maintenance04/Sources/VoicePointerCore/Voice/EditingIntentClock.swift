import CoreGraphics
import Foundation

/// Counts physical editing intent without storing keys, pointer positions or text.
public final class EditingIntentClock: @unchecked Sendable {
    public static let shared = EditingIntentClock()
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init() {}

    public func snapshot() -> UInt64 {
        lock.withLock { generation }
    }

    public func advance() {
        lock.withLock { generation &+= 1 }
    }

    public func performIfUnchanged<T>(_ expected: UInt64, _ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { return nil }
        return body()
    }

    @_spi(Testing)
    public static func shouldAdvance(type: CGEventType, passedThrough: Bool, syntheticMarker: Int64) -> Bool {
        guard passedThrough, syntheticMarker != voicePointerSyntheticEventUserData else { return false }
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown: return true
        default: return false
        }
    }
}

/// A separate counter for caret movement. Key codes and pointer positions are inspected,
/// never retained; ordinary typing is deliberately not a caret-navigation observation.
public final class CaretMovementIntentClock: @unchecked Sendable {
    public static let shared = CaretMovementIntentClock()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    public func snapshot() -> UInt64 { lock.withLock { generation } }
    public func observe(type: CGEventType, passedThrough: Bool, syntheticMarker: Int64,
                        keyCode: Int64, flags: CGEventFlags) {
        guard passedThrough, syntheticMarker != voicePointerSyntheticEventUserData else { return }
        let moves: Bool
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: moves = true
        case .keyDown:
            moves = [123, 124, 125, 126, 115, 119, 116, 121].contains(keyCode)
                || ([0, 6].contains(keyCode) && flags.contains(.maskCommand))
        default: moves = false
        }
        if moves { lock.withLock { generation &+= 1 } }
    }
}
