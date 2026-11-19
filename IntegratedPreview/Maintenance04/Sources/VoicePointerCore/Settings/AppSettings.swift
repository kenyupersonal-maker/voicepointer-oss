import Foundation

public enum FocusMode: String, CaseIterable, Codable, Sendable {
    case smart = "Smart Focus"
    case currentOnly = "Current Focus Only"
    case voiceOnly = "Voice Only"
}

public enum VoiceShortcutMode: String, CaseIterable, Codable, Sendable {
    case hold = "Hold"
    case toggle = "Toggle"
}

public struct GestureConfiguration: Codable, Equatable, Sendable {
    public var magicMouseFingerCount: Int
    public var trackpadFingerCount: Int
    public var freshChordWindowMilliseconds: Int
    public var magicMouseFreshChordWindowMilliseconds: Int
    public var maximumTouchMovement: Float
    public var trackpadEnabled: Bool
    public var magicMouseMinDensity: Float
    public var magicMouseMaxLandingSkewMilliseconds: Int
    public var magicMouseFastLandingMilliseconds: Int
    public var magicMouseSlowMinDensity: Float
    public var magicMouseEdgeMargin: Float
    public var magicMouseEdgeMaxMinor: Float
    public var touchSampleRecordingEnabled: Bool
    public var hapticStrength: HapticStrength

    public init(
        magicMouseFingerCount: Int = 2,
        trackpadFingerCount: Int = 3,
        freshChordWindowMilliseconds: Int = 350,
        magicMouseFreshChordWindowMilliseconds: Int = 1200,
        maximumTouchMovement: Float = 0.08,
        trackpadEnabled: Bool = true,
        magicMouseMinDensity: Float = 0.9,
        magicMouseMaxLandingSkewMilliseconds: Int = 600,
        magicMouseFastLandingMilliseconds: Int = 100,
        magicMouseSlowMinDensity: Float = 1.1,
        magicMouseEdgeMargin: Float = 0.05,
        magicMouseEdgeMaxMinor: Float = 4.6,
        touchSampleRecordingEnabled: Bool = true,
        hapticStrength: HapticStrength = .strong
    ) {
        self.magicMouseFingerCount = magicMouseFingerCount
        self.trackpadFingerCount = trackpadFingerCount
        self.freshChordWindowMilliseconds = freshChordWindowMilliseconds
        self.magicMouseFreshChordWindowMilliseconds = magicMouseFreshChordWindowMilliseconds
        self.maximumTouchMovement = maximumTouchMovement
        self.trackpadEnabled = trackpadEnabled
        self.magicMouseMinDensity = magicMouseMinDensity
        self.magicMouseMaxLandingSkewMilliseconds = magicMouseMaxLandingSkewMilliseconds
        self.magicMouseFastLandingMilliseconds = magicMouseFastLandingMilliseconds
        self.magicMouseSlowMinDensity = magicMouseSlowMinDensity
        self.magicMouseEdgeMargin = magicMouseEdgeMargin
        self.magicMouseEdgeMaxMinor = magicMouseEdgeMaxMinor
        self.touchSampleRecordingEnabled = touchSampleRecordingEnabled
        self.hapticStrength = hapticStrength
    }

    private enum CodingKeys: String, CodingKey {
        case magicMouseFingerCount, trackpadFingerCount, freshChordWindowMilliseconds, magicMouseFreshChordWindowMilliseconds,
             maximumTouchMovement, trackpadEnabled, magicMouseMinDensity,
             magicMouseMaxLandingSkewMilliseconds, magicMouseFastLandingMilliseconds, magicMouseSlowMinDensity, magicMouseEdgeMargin, magicMouseEdgeMaxMinor, touchSampleRecordingEnabled, hapticStrength
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let trackpadFresh = try c.decodeIfPresent(Int.self, forKey: .freshChordWindowMilliseconds) ?? 350
        let mouseFresh = try c.decodeIfPresent(Int.self, forKey: .magicMouseFreshChordWindowMilliseconds)
        let mouseSkew = try c.decodeIfPresent(Int.self, forKey: .magicMouseMaxLandingSkewMilliseconds) ?? 150
        let oldDensity = try c.decodeIfPresent(Float.self, forKey: .magicMouseMinDensity) ?? 1.0
        let oldDefault = !c.contains(.magicMouseFastLandingMilliseconds) && !c.contains(.magicMouseSlowMinDensity)
            && oldDensity == 1.0 && (mouseSkew == 80 || mouseSkew == 150)
        // The absent mouse field identifies old shared timing. Migrate only
        // its exact defaults; keep custom shared timing for both devices.
        self.init(magicMouseFingerCount: try c.decodeIfPresent(Int.self, forKey: .magicMouseFingerCount) ?? 2,
                  trackpadFingerCount: try c.decodeIfPresent(Int.self, forKey: .trackpadFingerCount) ?? 3,
                  freshChordWindowMilliseconds: trackpadFresh,
                  magicMouseFreshChordWindowMilliseconds: mouseFresh ?? (trackpadFresh == 350 ? 1200 : trackpadFresh),
                  maximumTouchMovement: try c.decodeIfPresent(Float.self, forKey: .maximumTouchMovement) ?? 0.08,
                  trackpadEnabled: try c.decodeIfPresent(Bool.self, forKey: .trackpadEnabled) ?? true,
                  magicMouseMinDensity: oldDefault ? 0.9 : oldDensity,
                  magicMouseMaxLandingSkewMilliseconds: oldDefault ? 600 : mouseSkew,
                  magicMouseFastLandingMilliseconds: try c.decodeIfPresent(Int.self, forKey: .magicMouseFastLandingMilliseconds) ?? 100,
                  magicMouseSlowMinDensity: try c.decodeIfPresent(Float.self, forKey: .magicMouseSlowMinDensity) ?? max(1.1, oldDefault ? 0.9 : oldDensity),
                  magicMouseEdgeMargin: try c.decodeIfPresent(Float.self, forKey: .magicMouseEdgeMargin) ?? 0.05,
                  magicMouseEdgeMaxMinor: try c.decodeIfPresent(Float.self, forKey: .magicMouseEdgeMaxMinor) ?? 4.6,
                  touchSampleRecordingEnabled: try c.decodeIfPresent(Bool.self, forKey: .touchSampleRecordingEnabled) ?? true,
                  hapticStrength: try c.decodeIfPresent(HapticStrength.self, forKey: .hapticStrength) ?? .strong)
    }
}

public struct VoiceShortcutConfiguration: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifierMaskRawValue: UInt64
    public var mode: VoiceShortcutMode

    public init(
        keyCode: UInt16 = 58,
        modifierMaskRawValue: UInt64 = 1 << 19,
        mode: VoiceShortcutMode = .hold
    ) {
        self.keyCode = keyCode
        self.modifierMaskRawValue = modifierMaskRawValue
        self.mode = mode
    }
}

public struct VoicePointerSettings: Codable, Equatable, Sendable {
    private var omitTerminalPeriodPreference: Bool?
    public var omitTerminalPeriod: Bool {
        get { omitTerminalPeriodPreference ?? true }
        set { omitTerminalPeriodPreference = newValue }
    }
    public var focusMode: FocusMode
    public var gesture: GestureConfiguration
    public var voiceShortcut: VoiceShortcutConfiguration
    public var excludedBundleIdentifiers: Set<String>
    public var allowSyntheticClickFallback: Bool

    public init(
        focusMode: FocusMode = .voiceOnly,
        gesture: GestureConfiguration = .init(),
        voiceShortcut: VoiceShortcutConfiguration = .init(),
        excludedBundleIdentifiers: Set<String> = [],
        allowSyntheticClickFallback: Bool = false,
        omitTerminalPeriod: Bool = true
    ) {
        self.focusMode = focusMode
        self.gesture = gesture
        self.voiceShortcut = voiceShortcut
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.allowSyntheticClickFallback = allowSyntheticClickFallback
        self.omitTerminalPeriodPreference = omitTerminalPeriod
    }
}

@MainActor
public final class SettingsStore {
    public static let shared = SettingsStore()

    private let defaults: UserDefaults
    private let storageKey = "voicePointer.settings.v1"
    private let clickFallbackMigrationKey = "voicePointer.settings.clickFallback.v2"
    private let gestureFilterMigrationKey = "voicePointer.settings.gestureFilter.v2"
    public private(set) var value: VoicePointerSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           var decoded = try? JSONDecoder().decode(VoicePointerSettings.self, from: data) {
            // 智能聚焦暂不做，需要时恢复；keep Codable fields for older settings.
            decoded.focusMode = .voiceOnly
            // v0.1 briefly shipped with Fn as the generated default even
            // though the accepted Doubao mapping is Left Option hold. There
            // is no shortcut editor yet, so every persisted Fn value is that
            // invalid default and can be migrated safely.
            if decoded.voiceShortcut.keyCode == 63 {
                decoded.voiceShortcut.keyCode = 58
                decoded.voiceShortcut.modifierMaskRawValue = UInt64(1 << 19)
            }
            if defaults.object(forKey: clickFallbackMigrationKey) == nil {
                // Preserve the user's persisted choice when upgrading.
                defaults.set(true, forKey: clickFallbackMigrationKey)
            }
            if defaults.object(forKey: gestureFilterMigrationKey) == nil {
                // Decoding supplies the timing defaults. Preserve an explicit
                // trackpad window even when this older migration flag is absent.
                decoded.gesture.maximumTouchMovement = min(
                    decoded.gesture.maximumTouchMovement,
                    0.08
                )
                defaults.set(true, forKey: gestureFilterMigrationKey)
            }
            value = decoded
            if let migrated = try? JSONEncoder().encode(decoded) {
                defaults.set(migrated, forKey: storageKey)
            }
        } else {
            value = .init()
            defaults.set(true, forKey: clickFallbackMigrationKey)
            defaults.set(true, forKey: gestureFilterMigrationKey)
        }
    }

    public func update(_ transform: (inout VoicePointerSettings) -> Void) {
        transform(&value)
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
