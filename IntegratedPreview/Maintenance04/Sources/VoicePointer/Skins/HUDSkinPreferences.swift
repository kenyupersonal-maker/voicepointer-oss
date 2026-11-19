import Foundation
import VoicePointerCore

@MainActor
final class HUDSkinPreferences {
    static let shared = HUDSkinPreferences()
    static let key = "hud.skin.v1"
    /// Set once Astra has been made the selected skin, so the migration never runs again.
    static let astraDefaultFlagKey = "hud.skin.astraDefault.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateToAstraOnce()
    }

    /// Astra becomes the selected skin exactly once, the first time this version runs; any skin the user
    /// picks afterwards stays picked.
    private func migrateToAstraOnce() {
        SkinSelectionMigration.selectOnce(
            HUDSkinID.astra.rawValue, selectionKey: Self.key, flagKey: Self.astraDefaultFlagKey, defaults: defaults)
    }

    var selection: HUDSkinID {
        guard let raw = defaults.string(forKey: Self.key),
              let skin = HUDSkinID(rawValue: raw) else { return .classic }
        switch skin {
        case .classic, .astra, .liquidMetal, .dither, .blackHole, .particles, .inkSprite, .bubble,
             .ferrofluid, .voiceLine, .plasma:
            return skin
        // No longer offered (HUDSkinID.retired); a saved one shows as 经典 (the saved value itself is left alone).
        case .frosted, .waterDrop, .flame, .glassDisc, .frostDisc, .metaballs, .liquidChrome, .ripple: return .classic
        case .liquidGlass: return LiquidGlassSkin.isSupported ? .liquidGlass : .classic
        case .miniDisc, .miniMorph: return skin.isAvailableHere ? skin : .classic
        }
    }

    /// 「默认」's 质感 (Ken, 2026-11-08): 清透 and 柔和 are the Liquid Glass skin in the system's clear and regular
    /// styles, 磨砂 is the classic skin. Settings shows one tile with three steps; underneath they stay two skins,
    /// and the saved skin is still `classic` or `liquidGlass`.
    enum DefaultTexture: Int, CaseIterable, Sendable {
        case clear = 0, soft = 1, frost = 2
    }
    static let textureKey = "hud.skin.defaultTexture.v1"

    /// What the 默认 tile stands for: the current selection when it is 默认, else the last 质感 picked there.
    var defaultTexture: DefaultTexture {
        switch selection {
        case .classic: return .frost
        case .liquidGlass: return LiquidGlassTuningStore.shared.value.blur == 0 ? .clear : .soft
        default:
            guard let raw = defaults.object(forKey: Self.textureKey) as? Int,
                  let saved = DefaultTexture(rawValue: raw),
                  saved == .frost || LiquidGlassSkin.isSupported else { return .frost }
            return saved
        }
    }

    func selectDefault(_ texture: DefaultTexture) {
        switch texture {
        case .frost:
            select(.classic)
        case .clear, .soft:
            guard LiquidGlassSkin.isSupported else { return }
            LiquidGlassTuningStore.shared.setBlur(texture == .clear ? 0 : 1)
            select(.liquidGlass)
        }
        defaults.set(texture.rawValue, forKey: Self.textureKey)
    }

    func select(_ skin: HUDSkinID) {
        guard skin.isAvailableHere, !HUDSkinID.retired.contains(skin) else { return }
        defaults.set(skin.rawValue, forKey: Self.key)
        if skin.isShaderSkin { HUDShaderLibrary.shared.prepare(skin) }
    }
}
