import Foundation

// 小球（2026-11-10）：没有大圆盘、只在起点有一颗小东西的皮肤。第一个是小圆盘：大圆盘的「柔和」缩成一颗，用系统
// 液态玻璃（MiniDiscSkin.swift）。后面是更新的 3D 玻璃小圆盘（清透 / 磨砂，Resources/HUDShaders/skin_glassdisc.hsl，
// 和趣味皮肤一样走显卡着色器）。2026-11-10 先试过的四款用图层拼的（玻璃水滴、符号变形、光球、水球）Ken 看了说太丑，已经拿掉。

extension HUDSkinID {
    /// The 小球 skins, in the order the chooser lists them.
    /// 2026-11-10 (Ken): the former 趣味 skins have the same layout (a small thing in the middle), so they joined 小球;
    /// Astra and the black hole fill a whole disc and sit with 大圆盘.
    static let small: [HUDSkinID] = [
        .miniDisc, .miniMorph, .liquidMetal, .inkSprite, .bubble, .particles, .dither, .ferrofluid, .voiceLine, .plasma,
    ]
    /// 大圆盘 besides 默认.
    static let bigDiscExtras: [HUDSkinID] = [.astra, .blackHole]

    /// Whether this Mac can draw the skin: 液态玻璃 and 小圆盘 need macOS 26 (NSGlassEffectView).
    var isAvailableHere: Bool {
        guard self == .liquidGlass || self == .miniDisc || self == .miniMorph else { return true }
        if #available(macOS 26.0, *) { return true }
        return false
    }
}
