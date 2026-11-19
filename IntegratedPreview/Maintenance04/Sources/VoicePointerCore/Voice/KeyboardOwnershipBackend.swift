import Foundation

public enum KeyboardEventPostResult: Sendable, Equatable {
    case submitted
    case rejected(reason: String)
    case failed(reason: String)
}

/// Synchronous by design: `submitted` is the point at which the event was
/// handed to CoreGraphics. CoreGraphics provides no delivery acknowledgement.
public protocol KeyboardEventPosting: Sendable {
    func post(modifier: VoiceModifier, isDown: Bool, marker: UInt64) -> KeyboardEventPostResult
    func isPhysicalHeld(_ modifier: VoiceModifier) -> Bool
}

public extension KeyboardEventPosting {
    // Offline fakes never consult the real keyboard.
    func isPhysicalHeld(_ modifier: VoiceModifier) -> Bool { false }
}

#if canImport(CoreGraphics)
import CoreGraphics

public struct CGEventKeyboardPostBackend: KeyboardEventPosting {
    public init() {}

    public func post(modifier: VoiceModifier, isDown: Bool, marker: UInt64) -> KeyboardEventPostResult {
        guard EventAccessPermission.canPost else {
            RuntimeTrace.record("keyboard ownership post rejected permission=missing modifier=\(modifier.rawValue) down=\(isDown)")
            return .rejected(reason: "eventPostingPermissionMissing")
        }
        if isDown, isPhysicalHeld(modifier) { return .rejected(reason: "physicalKeyHeld") }
        guard let event = Self.makeOwnedEvent(
            modifier: modifier, isDown: isDown, marker: marker,
            physicalFlags: CGEventSource.flagsState(.hidSystemState)
        ) else {
            RuntimeTrace.record("keyboard ownership post failed eventCreation modifier=\(modifier.rawValue) down=\(isDown)")
            return .failed(reason: "eventCreationFailed")
        }
        event.setIntegerValueField(.eventSourceUserData, value: Int64(bitPattern: marker))
        event.post(tap: .cghidEventTap)
        RuntimeTrace.record("keyboard ownership post submitted modifier=\(modifier.rawValue) down=\(isDown) marker=\(marker)")
        return .submitted
    }
}

extension VoiceModifier {
    var keyCode: CGKeyCode {
        switch self {
        case .fn: return 63
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftShift: return 56
        case .rightShift: return 60
        }
    }
}
extension CGEventKeyboardPostBackend {
    public func isPhysicalHeld(_ modifier: VoiceModifier) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: modifier.keyCode)
    }

    @_spi(Testing)
    public static func makeOwnedEvent(
        modifier: VoiceModifier, isDown: Bool, marker: UInt64,
        physicalFlags: CGEventFlags
    ) -> CGEvent? {
        guard let event = CGEventKeyboardSender.makeEvent(
            modifier, isDown: isDown, baseFlags: physicalFlags
        ) else { return nil }
        // makeEvent removes the owned class bit for up. Put back every bit
        // the hardware still owns, including another key in the same class.
        event.flags.formUnion(physicalFlags)
        event.setIntegerValueField(.eventSourceUserData, value: Int64(bitPattern: marker))
        return event
    }
}
#endif
