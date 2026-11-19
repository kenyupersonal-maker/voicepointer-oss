import Foundation

/// Which sound plays at a spoken push-up release. `system` is the real macOS "sent" swoosh
/// (pitched up, v6); every other choice is rendered from a spectral table by `ShapedNoiseSound`.
/// The table sounds are original designs made with the offline sound-sketch tool from hand-made
/// breath recordings; no sample of any other app or product is used.
public enum SendSoundChoice: String, CaseIterable, Sendable {
    case system
    case whisper
    case clean
    case breathArc
    case breathArcLong
    case swishUp
    case flyBy
    case short

    public static let defaultsKey = "hud.sendSound.v1"

    /// The card's name. Short and neutral: it says how the sound behaves, not whose recording it came from.
    public var title: String {
        switch self {
        case .system: "系统咻"
        case .whisper: "气声咻"
        case .clean: "清透咻"
        case .breathArc: "轻息咻"
        case .breathArcLong: "轻息咻·长"
        case .swishUp: "上扬嗖"
        case .flyBy: "掠过嗖"
        case .short: "短促嗖"
        }
    }

    /// One line under the name, taken from the measured shape of each sound (length and pitch movement).
    public var blurb: String {
        switch self {
        case .system: "默认，系统发送音"
        case .whisper: "轻柔气声，稍长"
        case .clean: "气声更干净，渐暗"
        case .breathArc: "气息一弧，0.32 秒"
        case .breathArcLong: "拉长四成，渐弱收尾"
        case .swishUp: "音调一路上扬"
        case .flyBy: "先升后落，像掠过"
        case .short: "最短，干脆利落"
        }
    }

    /// Nil for the system sound; otherwise the table `ShapedNoiseSound` renders.
    public var table: [[Int8]]? {
        switch self {
        case .system: nil
        case .whisper: SendSoundTables.whisper
        case .clean: SendSoundTables.clean
        case .breathArc: SendSoundTables.breathArc
        case .breathArcLong: SendSoundTables.breathArcLong
        case .swishUp: SendSoundTables.swishUp
        case .flyBy: SendSoundTables.flyBy
        case .short: SendSoundTables.short
        }
    }

    /// An unknown or missing stored value reads as the default.
    public static func load(from defaults: UserDefaults = .standard) -> SendSoundChoice {
        defaults.string(forKey: defaultsKey).flatMap(SendSoundChoice.init(rawValue:)) ?? .system
    }

    public static func save(_ choice: SendSoundChoice, to defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: defaultsKey)
    }
}
