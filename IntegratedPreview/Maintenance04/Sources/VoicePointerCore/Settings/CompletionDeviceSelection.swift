public enum CompletionDeviceSelection: String, Sendable {
    case trackpad, mouse, both
    public static func resolve(kinds: [TouchDeviceKind]) -> Self {
        let mouse = kinds.contains(.magicMouse)
        let trackpad = kinds.contains(.builtInTrackpad) || kinds.contains(.externalTrackpad)
        return mouse ? (trackpad ? .both : .mouse) : .trackpad
    }
}
