import AppKit
import QuartzCore

// MARK: - Shared model (all skins render the same states; geometry and hit-testing are shared)

enum HUDAim: Equatable, Sendable { case none, send, cancel }
enum HUDRelease: Sendable { case send, cancel, keep }

struct HUDEnvironment: Equatable, Sendable {
    var isDark = false
    var reduceMotion = false
    var reduceTransparency = false
    var increaseContrast = false
}

/// Pointer state relative to the gesture start. `dy` is positive upward (AppKit).
struct HUDPointer: Equatable, Sendable {
    var dy: CGFloat = 0
    /// Committed classifier result (with hysteresis). Visuals may use `progress`.
    var aim: HUDAim = .none
    /// 0...1, continuous, toward the side given by the sign of `dy`.
    var progress: CGFloat = 0
}

enum HUDLayout {
    /// Same as the product: 256pt logical canvas + 20pt shadow padding.
    static let panelSize = CGSize(width: 296, height: 296)
    /// Product anchor (128, 132) + padding 20.
    static let anchor = CGPoint(x: 148, y: 152)
    static let discRadius: CGFloat = 100
    static let coreRadius: CGFloat = 40
    static let labelRadius: CGFloat = 68

    /// Range of a skin's overall size ("整体大小", set in the skin editor). skin_params.json declares the same bounds.
    static let minimumScale: CGFloat = 0.7
    static let maximumScale: CGFloat = 1.5

    /// A usable overall size: finite and inside the allowed range, 1 otherwise.
    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(max(scale, minimumScale), maximumScale)
    }

    /// The panel for a skin drawn at `scale` times its normal size (shadow padding included).
    static func panelSize(scale: CGFloat) -> CGSize {
        let s = clampedScale(scale)
        return CGSize(width: panelSize.width * s, height: panelSize.height * s)
    }

    /// Where the gesture start sits in that panel.
    static func anchor(scale: CGFloat) -> CGPoint {
        let s = clampedScale(scale)
        return CGPoint(x: anchor.x * s, y: anchor.y * s)
    }

    /// 0...1 lean toward Send/Cancel for a vertical travel of `dy` screen points. The 8 pt dead zone and the
    /// 56 pt run scale with the disc, so a larger disc asks for proportionally more travel.
    static func progress(forDy dy: CGFloat, scale: CGFloat = 1) -> CGFloat {
        let s = clampedScale(scale)
        return min(max((abs(dy) - 8 * s) / (56 * s), 0), 1)
    }
}

enum HUDSkinID: String, CaseIterable, Sendable {
    case classic, liquidGlass, frosted
    case astra, liquidMetal, waterDrop, liquidChrome, dither, metaballs, blackHole, particles, inkSprite, bubble, flame
    /// 小球 (2026-11-10): no dial, a small disc at the gesture start (MiniDiscSkin, skin_glassdisc.hsl).
    case miniDisc, glassDisc, frostDisc
    /// 2026-11-10: skins made theme first (Ken: 先想主题，再从主题反推样式和材质).
    case ferrofluid, voiceLine, ripple, plasma
    /// 小圆盘（形变）: the small disc whose glass itself changes shape with the symbol.
    case miniMorph

    /// 2026-11-07: 磨砂 is no longer offered (Ken: 不要那个皮肤). The case stays so an old selection still decodes.
    static let basic: [HUDSkinID] = [.classic, .liquidGlass]
    /// No longer offered; the cases stay so an old selection still decodes (it shows as 默认). 磨砂 since 2026-11-07,
    /// 玻璃珠 and 火苗 since 2026-11-10 (Ken: 玻璃珠非常差，火苗也删掉).
    /// 3D 玻璃（清透 / 磨砂）, 液滴融合 and 镜面铬 since 2026-11-10 too (Ken: 丑，该删的删).
    static let retired: [HUDSkinID] = [.frosted, .waterDrop, .flame, .glassDisc, .frostDisc, .metaballs, .liquidChrome, .ripple]
    /// The skins the shader library draws.
    static let shaderSkins: [HUDSkinID] = [
        .astra, .liquidMetal, .dither, .blackHole, .particles, .inkSprite, .bubble,
        .ferrofluid, .voiceLine, .plasma,
    ]

    var isShaderSkin: Bool { Self.shaderSkins.contains(self) }

    var usesStandaloneRenderer: Bool { self == .frosted || self == .miniDisc || self == .miniMorph || isShaderSkin }

    var title: String {
        switch self {
        case .classic: return "经典"
        case .liquidGlass: return "液态玻璃"
        case .frosted: return "磨砂"
        case .astra: return "Astra"
        case .liquidMetal: return "液态金属"
        case .waterDrop: return "玻璃珠"
        case .liquidChrome: return "镜面铬"
        case .dither: return "点阵"
        case .metaballs: return "液滴融合"
        case .blackHole: return "黑洞"
        case .particles: return "沙"
        case .inkSprite: return "墨"
        case .bubble: return "泡泡"
        case .flame: return "火苗"
        case .miniDisc: return "小圆盘"
        case .miniMorph: return "小圆盘（形变）"
        case .glassDisc: return "3D 玻璃（清透）"
        case .frostDisc: return "3D 玻璃（磨砂）"
        case .ferrofluid: return "磁流体"
        case .voiceLine: return "声纹"
        case .ripple: return "水面"
        case .plasma: return "等离子球"
        }
    }
}

@MainActor
protocol HUDSkin: AnyObject {
    /// Root view, sized `HUDLayout.panelSize`; the gesture start sits on `HUDLayout.anchor`.
    var view: NSView { get }
    func apply(_ environment: HUDEnvironment)
    func present(coreOnly: Bool)
    func update(level: CGFloat)
    func update(pointer: HUDPointer)
    func release(_ action: HUDRelease, completion: @escaping @MainActor () -> Void)
    func showFeedback(_ message: String, completion: @escaping @MainActor () -> Void)
}

// MARK: - Helpers

extension NSColor {
    static func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    /// Linear blend in sRGB (good enough for UI tints).
    func blended(to other: NSColor, _ t: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        let k = min(max(t, 0), 1)
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * k,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * k,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * k,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * k
        )
    }
}

@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// A view whose layer is a plain CALayer we own (layer-hosting), y-up like AppKit.
@MainActor
final class HUDLayerView: NSView {
    let host = CALayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = host
        wantsLayer = true
        host.masksToBounds = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum Anim {
    static func quiet(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    static func opacity(_ l: CALayer, _ v: Float, _ d: CFTimeInterval, _ t: CAMediaTimingFunctionName = .easeOut) {
        let from = l.presentation()?.opacity ?? l.opacity
        quiet { l.opacity = v }
        guard d > 0, abs(from - v) > 0.001 else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = v
        a.duration = d
        a.timingFunction = CAMediaTimingFunction(name: t)
        l.add(a, forKey: "opacity")
    }

    static func position(_ l: CALayer, _ p: CGPoint, _ d: CFTimeInterval, _ t: CAMediaTimingFunctionName = .easeOut) {
        let from = l.presentation()?.position ?? l.position
        quiet { l.position = p }
        guard d > 0 else { return }
        let a = CABasicAnimation(keyPath: "position")
        a.fromValue = NSValue(point: from)
        a.toValue = NSValue(point: p)
        a.duration = d
        a.timingFunction = CAMediaTimingFunction(name: t)
        l.add(a, forKey: "position")
    }

    static func transform(_ l: CALayer, _ tr: CATransform3D, _ d: CFTimeInterval, _ t: CAMediaTimingFunctionName = .easeOut) {
        let from = l.presentation()?.transform ?? l.transform
        quiet { l.transform = tr }
        guard d > 0 else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: from)
        a.toValue = NSValue(caTransform3D: tr)
        a.duration = d
        a.timingFunction = CAMediaTimingFunction(name: t)
        l.add(a, forKey: "transform")
    }

    static func textColor(_ l: CATextLayer, _ c: CGColor, _ d: CFTimeInterval) {
        let from = l.presentation()?.foregroundColor ?? l.foregroundColor
        quiet { l.foregroundColor = c }
        guard d > 0, let from else { return }
        let a = CABasicAnimation(keyPath: "foregroundColor")
        a.fromValue = from
        a.toValue = c
        a.duration = d
        l.add(a, forKey: "foregroundColor")
    }

    static func strokeColor(_ l: CAShapeLayer, _ c: CGColor, _ d: CFTimeInterval) {
        let from = l.presentation()?.strokeColor ?? l.strokeColor
        quiet { l.strokeColor = c }
        guard d > 0, let from else { return }
        let a = CABasicAnimation(keyPath: "strokeColor")
        a.fromValue = from
        a.toValue = c
        a.duration = d
        l.add(a, forKey: "strokeColor")
    }

    /// Critically damped scale-in (no overshoot) — used for "appear".
    static func springScale(_ l: CALayer, from: CGFloat, stiffness: CGFloat = 320, zeta: CGFloat = 1) {
        let s = CASpringAnimation(keyPath: "transform.scale")
        s.fromValue = from
        s.toValue = 1
        s.mass = 1
        s.stiffness = stiffness
        s.damping = 2 * sqrt(stiffness) * zeta
        s.initialVelocity = 0
        s.duration = s.settlingDuration
        l.add(s, forKey: "appear.scale")
    }

    static func after(_ seconds: Double, _ block: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            block()
        }
    }
}

// MARK: - Arc text (one CATextLayer per glyph, rotated about its own centre)

@MainActor
final class ArcTextLayer: CALayer {
    enum Placement { case top, bottom }
    private(set) var glyphs: [CATextLayer] = []

    /// Glyph centres sit on `radius`; spacing uses the same radius (the product used 66 vs 68,
    /// and rotated each glyph about its corner — the cause of the uneven tilt).
    func configure(
        text: String, font: NSFont, color: CGColor, kern: CGFloat,
        radius: CGFloat, placement: Placement, center: CGPoint, scale: CGFloat
    ) {
        glyphs.forEach { $0.removeFromSuperlayer() }
        glyphs.removeAll()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: kern]
        let chars = text.map { String($0) }
        let advances = chars.map { ($0 as NSString).size(withAttributes: attrs).width }
        let total = advances.reduce(0, +) - kern
        let height = ceil(font.ascender - font.descender) + 2
        var cursor = -total / 2
        for (i, ch) in chars.enumerated() {
            let adv = advances[i]
            let mid = cursor + (adv - kern) / 2
            let theta: CGFloat
            let rotation: CGFloat
            switch placement {
            case .top:
                theta = .pi / 2 - mid / radius
                rotation = theta - .pi / 2
            case .bottom:
                theta = -.pi / 2 + mid / radius
                rotation = theta + .pi / 2
            }
            let g = CATextLayer()
            g.contentsScale = scale
            g.string = ch
            g.font = font
            g.fontSize = font.pointSize
            g.foregroundColor = color
            g.alignmentMode = .center
            g.bounds = CGRect(x: 0, y: 0, width: ceil(adv) + 6, height: height)
            g.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            g.position = CGPoint(x: center.x + cos(theta) * radius, y: center.y + sin(theta) * radius)
            g.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)
            addSublayer(g)
            glyphs.append(g)
            cursor += adv
        }
    }

    func setColor(_ c: CGColor, duration: CFTimeInterval) {
        glyphs.forEach { Anim.textColor($0, c, duration) }
    }

    func setHalo(color: CGColor, opacity: Float, radius: CGFloat) {
        for g in glyphs {
            g.shadowColor = color
            g.shadowOpacity = opacity
            g.shadowRadius = radius
            g.shadowOffset = .zero
        }
    }
}

// MARK: - Waveform (5 bars, level driven only)

@MainActor
final class WaveformLayer: CALayer {
    private var bars: [CALayer] = []
    private let weights: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]
    var minHeight: CGFloat = 4
    var maxHeight: CGFloat = 20

    func build(color: CGColor) {
        bars.forEach { $0.removeFromSuperlayer() }
        bars = (0..<5).map { i in
            let b = CALayer()
            b.backgroundColor = color
            b.cornerRadius = 1.5
            b.bounds = CGRect(x: 0, y: 0, width: 3, height: minHeight)
            b.position = CGPoint(x: bounds.midX + CGFloat(i - 2) * 6, y: bounds.midY)
            addSublayer(b)
            return b
        }
    }

    func setColor(_ c: CGColor) { bars.forEach { $0.backgroundColor = c } }

    func update(level: CGFloat) {
        let l = sqrt(min(max(level, 0), 1))
        Anim.quiet {
            for (i, b) in bars.enumerated() {
                let jitter = level < 0.02 ? 1 : CGFloat.random(in: 0.9...1.1)
                let h = minHeight + (maxHeight - minHeight) * l * weights[i] * jitter
                b.bounds.size.height = max(minHeight, h)
            }
        }
    }
}

// MARK: - Feedback pill (shared by all skins; v1 `Pill` tokens)

@MainActor
final class PillLayer: CALayer {
    private let text = CATextLayer()
    private let dot = CALayer()

    /// `layoutScale` is the skin's overall size (1 = normal); every measure of the pill scales with it.
    func configure(message: String, center: CGPoint, scale: CGFloat, layoutScale: CGFloat = 1) {
        let k = HUDLayout.clampedScale(layoutScale)
        let font = NSFont.systemFont(ofSize: 13 * k, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = min(ceil((message as NSString).size(withAttributes: attrs).width), (280 - 28 - 14) * k)
        let w = textWidth + (28 + 14) * k
        let h: CGFloat = 36 * k
        bounds = CGRect(x: 0, y: 0, width: w, height: h)
        position = center
        cornerRadius = h / 2
        backgroundColor = NSColor.srgb(28, 28, 30, 0.86).cgColor
        borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        borderWidth = 0.5
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.20
        shadowRadius = 9 * k
        shadowOffset = CGSize(width: 0, height: -6 * k)

        dot.bounds = CGRect(x: 0, y: 0, width: 8 * k, height: 8 * k)
        dot.cornerRadius = 4 * k
        dot.backgroundColor = NSColor.srgb(255, 159, 10).cgColor
        dot.position = CGPoint(x: (14 + 4) * k, y: h / 2)
        if dot.superlayer == nil { addSublayer(dot) }

        text.contentsScale = scale
        text.string = message
        text.font = font
        text.fontSize = 13 * k
        text.foregroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        text.alignmentMode = .left
        text.truncationMode = .end
        text.bounds = CGRect(x: 0, y: 0, width: textWidth, height: 18 * k)
        text.position = CGPoint(x: (14 + 8 + 6) * k + textWidth / 2, y: h / 2 - k)
        if text.superlayer == nil { addSublayer(text) }
    }
}
