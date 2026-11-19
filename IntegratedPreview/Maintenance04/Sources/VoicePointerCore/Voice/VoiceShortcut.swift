import Foundation

public enum VoiceModifier: String, Sendable, Codable {
    case fn, leftOption, rightOption, leftCommand, rightCommand, leftControl, rightControl, leftShift, rightShift
}

public enum VoiceActivationMode: String, Sendable, Codable { case hold, toggle }

public struct VoiceShortcut: Sendable, Codable, Equatable {
    public var modifier: VoiceModifier
    public var mode: VoiceActivationMode
    public init(modifier: VoiceModifier = .leftOption, mode: VoiceActivationMode = .hold) {
        self.modifier = modifier; self.mode = mode
    }
}

public protocol KeyboardEventSending: Sendable {
    func keyDown(_ modifier: VoiceModifier) async
    func keyUp(_ modifier: VoiceModifier) async
    func tap(_ modifier: VoiceModifier) async
}

public struct NoopKeyboardEventSender: KeyboardEventSending {
    public init() {}
    public func keyDown(_ modifier: VoiceModifier) async {}
    public func keyUp(_ modifier: VoiceModifier) async {}
    public func tap(_ modifier: VoiceModifier) async {}
}

#if canImport(CoreGraphics)
import CoreGraphics
public struct CGEventKeyboardSender: KeyboardEventSending {
    public init() {}
    public static func emergencyKeyUp(_ modifier: VoiceModifier) {
        CGEventKeyboardSender().post(modifier, isDown: false)
    }
    public static func emergencyTap(_ modifier: VoiceModifier) {
        let sender = CGEventKeyboardSender()
        sender.post(modifier, isDown: true)
        sender.post(modifier, isDown: false)
    }
    private func code(_ modifier: VoiceModifier) -> CGKeyCode {
        switch modifier { case .fn: return 63; case .leftOption: return 58; case .rightOption: return 61; case .leftCommand: return 55; case .rightCommand: return 54; case .leftControl: return 59; case .rightControl: return 62; case .leftShift: return 56; case .rightShift: return 60 }
    }
    private func flag(_ modifier: VoiceModifier) -> CGEventFlags {
        switch modifier {
        case .fn: return .maskSecondaryFn
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftControl, .rightControl: return .maskControl
        case .leftShift, .rightShift: return .maskShift
        }
    }
    @_spi(Testing)
    public static func makeEvent(
        _ modifier: VoiceModifier,
        isDown: Bool,
        baseFlags: CGEventFlags? = nil
    ) -> CGEvent? {
        let sender = CGEventKeyboardSender()
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: sender.code(modifier),
            keyDown: isDown
        ) else { return nil }
        var flags = baseFlags ?? CGEventSource.flagsState(.combinedSessionState)
        if isDown { flags.insert(sender.flag(modifier)) }
        else { flags.remove(sender.flag(modifier)) }
        event.type = .flagsChanged
        event.flags = flags
        return event
    }
    private func post(_ modifier: VoiceModifier, isDown: Bool) {
        guard EventAccessPermission.canPost else {
            RuntimeTrace.record(
                "keyboard post blocked permission=missing modifier=\(modifier.rawValue) down=\(isDown)"
            )
            return
        }
        guard let event = Self.makeEvent(modifier, isDown: isDown) else { return }
        RuntimeTrace.record("keyboard post modifier=\(modifier.rawValue) down=\(isDown)")
        event.post(tap: .cghidEventTap)
    }
    public func keyDown(_ modifier: VoiceModifier) async { post(modifier, isDown: true) }
    public func keyUp(_ modifier: VoiceModifier) async { post(modifier, isDown: false) }
    public func tap(_ modifier: VoiceModifier) async { await keyDown(modifier); await keyUp(modifier) }
}
#endif

public protocol VoiceShortcutControlling: Sendable {
    func modifierDown() async
    func modifierUp() async
    func toggle() async
}

public actor HoldVoiceShortcutController: VoiceShortcutControlling {
    private let sender: any KeyboardEventSending; private let modifier: VoiceModifier
    private var isDown = false
    public init(modifier: VoiceModifier = .leftOption, sender: any KeyboardEventSending = NoopKeyboardEventSender()) { self.modifier = modifier; self.sender = sender }
    public func modifierDown() async {
        guard !isDown else { return }
        isDown = true
        await sender.keyDown(modifier)
    }
    public func modifierUp() async {
        guard isDown else { return }
        isDown = false
        await sender.keyUp(modifier)
    }
    public func toggle() async {}
}
public actor ToggleVoiceShortcutController: VoiceShortcutControlling {
    private let sender: any KeyboardEventSending; private let modifier: VoiceModifier
    private var isOn = false
    public init(modifier: VoiceModifier = .leftOption, sender: any KeyboardEventSending = NoopKeyboardEventSender()) { self.modifier = modifier; self.sender = sender }
    public func modifierDown() async {
        guard !isOn else { return }
        isOn = true
        await sender.tap(modifier)
    }
    public func modifierUp() async {}
    public func toggle() async {
        guard isOn else { return }
        isOn = false
        await sender.tap(modifier)
    }
}
