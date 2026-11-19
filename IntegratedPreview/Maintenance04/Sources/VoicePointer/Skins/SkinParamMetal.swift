import Foundation
@preconcurrency import Metal
import VoicePointerCore

// Glue between the skin parameter store (VoicePointerCore, no UI or Metal types) and the HUD skins / Metal.

extension HUDSkinID {
    /// The skin's key in skin_params.json; nil for skins without tunable parameters.
    var paramSkinKey: String? {
        switch self {
        case .astra: return "astra"
        case .blackHole: return "blackhole"
        case .classic, .liquidGlass, .frosted, .liquidMetal, .waterDrop, .liquidChrome, .dither,
             .metaballs, .particles, .inkSprite, .bubble, .flame, .miniDisc, .miniMorph, .glassDisc, .frostDisc,
             .ferrofluid, .voiceLine, .ripple, .plasma:
            return nil
        }
    }

    /// True when the skin's shader declares its constants without defaults (Astra, black hole), so it cannot be
    /// built through plain `makeFunction(name:)` and needs the manifest to specialise it.
    var needsParamManifest: Bool { paramSkinKey != nil }

    static func skin(forParamKey key: String) -> HUDSkinID? {
        allCases.first { $0.paramSkinKey == key }
    }
}

extension SkinParamStore {
    func hasParams(_ skin: HUDSkinID) -> Bool {
        guard let key = skin.paramSkinKey else { return false }
        return hasParams(key)
    }

    /// The overall size for `skin`, 1 when the skin has no parameters. Applied when the HUD appears.
    func hudScale(for skin: HUDSkinID) -> CGFloat {
        guard let key = skin.paramSkinKey else { return 1 }
        return CGFloat(hudScale(key))
    }
}

extension SkinFunctionConstant {
    /// Metal function-constant values for these constants: `.float` for scalars, `.float3` for colours.
    static func metalValues(_ constants: [SkinFunctionConstant]) -> MTLFunctionConstantValues {
        let values = MTLFunctionConstantValues()
        for constant in constants {
            switch constant.value {
            case .float(var x):
                values.setConstantValue(&x, type: .float, index: constant.index)
            case .float3(var v):
                values.setConstantValue(&v, type: .float3, index: constant.index)
            }
        }
        return values
    }
}
