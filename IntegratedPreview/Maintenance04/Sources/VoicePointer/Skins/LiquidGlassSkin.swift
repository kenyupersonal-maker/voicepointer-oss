import AppKit
import QuartzCore
import VoicePointerCore

/// 液态玻璃（0.5.80 重写）：交互、荧光和图标与「经典」完全一样，底盘就是一块系统 NSGlassEffectView（macOS 26+）；
/// 低版本上等同经典皮肤。设置里它和经典合成一张「默认」：清透、柔和是这块玻璃的两种系统样式，磨砂就是经典（0.5.83）。
///
/// Bottom to top, nothing else:
/// 1. The system glass, 「透明」 style for 清透 and 「常规」 for 柔和, never tinted by the system. Its thin bright
///    edge is the system's.
/// 2. 明暗: a plain white or black circle over the glass at exactly the chosen strength, and 边缘加深, a ring that
///    darkens toward the glass edge (2026-11-10: on a bright page clear glass is just bright; the dim layer and the
///    darker edge are what make it read as a piece of glass). The system tint ignores the
///    strength (white 15 % drew an opaque white disc on screen, glass lab 2026-11-07), and so did the circle 0.5.79
///    painted inside the glass: that was the dial turning pure white whatever the slider said.
/// 3. The radial: labels, glows, icons, waveform, the two grooves and the ring round the core (「分割线」) and a faint
///    core fill, and its soft outer shadow round the dial (「投影」). The radial hides its own dial, core highlight
///    and rim (hidesBuiltIn…Surface).
/// The same stack at 80 pt stands in for the core while aiming (the dial fades out then).
/// The glass has no blur setting besides its two styles, and a material view under it blurs only at full opacity
/// (below that it is a faint fog over sharp text, glass lab 2026-11-07). 0.5.80-0.5.82 offered that full frost as a
/// third step; it looked like the classic skin, so 磨砂 is now the classic skin itself (Ken, 2026-11-08).
///
/// Replaced on 2026-11-07 after Ken's「拆掉重写」: the earlier skin painted its own tint circle inside the glass, laid a
/// dark ring over the glass edge (「白边」, which at 0 % turned into a black ring) and the classic contact shadow hugging
/// the edge, which made the system edge look like a thick white stroke. 0.5.80 dropped the whole outer shadow; 0.5.81
/// brings back the soft part (Ken: 「为什么又没有投影了」).
@MainActor
final class LiquidGlassSkin: HUDSkin, LiquidGlassTunable {
    let view: NSView
    private let radial: RadialHUDView
    private var dial: GlassStack?
    private var core: GlassStack?
    /// How much of each stack shows right now (the radial decides: dial while idle, core while aiming).
    private var dialShown: CGFloat = 1
    private var coreShown: CGFloat = 0
    private var env = HUDEnvironment()
    private var aim: HUDAim = .none
    private var released = false
    /// Review host only: draw this tuning instead of the saved one (several settings side by side).
    var tuningOverride: LiquidGlassTuning? {
        didSet { applyTuning() }
    }

    /// One glass disc and the tint over it.
    private struct GlassStack {
        let glass: NSView
        let tint: NSView
        let tintCircle: CAShapeLayer
        let edge: CAGradientLayer
        var views: [NSView] { [glass, tint] }
    }

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    init(radial: RadialHUDView) {
        let root = NSView(frame: NSRect(origin: .zero, size: HUDLayout.panelSize))
        root.wantsLayer = true
        view = root
        self.radial = radial
        if #available(macOS 26.0, *) {
            let a = HUDLayout.anchor
            let r = HUDLayout.discRadius
            let c = HUDLayout.coreRadius
            dial = Self.makeStack(frame: CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2), in: root)
            core = Self.makeStack(frame: CGRect(x: a.x - c, y: a.y - c, width: c * 2, height: c * 2), in: root)
        }
        root.addSubview(radial)
        guard let core else {
            root.appearance = NSAppearance(named: .aqua)
            return
        }
        radial.hidesBuiltInDialSurface = true
        radial.hidesBuiltInCoreSurface = true
        radial.externalSurfaceAlphaHandler = { [weak self] alpha, animated in
            self?.setDialShown(alpha, animated: animated)
        }
        radial.externalCoreAlphaHandler = { [weak self] alpha, animated in
            self?.setCoreShown(alpha, animated: animated)
        }
        radial.externalCoreViews = core.views
        LiquidGlassTuningStore.shared.register(self)
        applyTuning()
    }

    @available(macOS 26.0, *)
    private static func makeStack(frame: CGRect, in root: NSView) -> GlassStack {
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = frame.width / 2
        glass.contentView = NSView(frame: glass.bounds)
        glass.alphaValue = 0
        root.addSubview(glass)
        let tint = NSView(frame: frame)
        tint.wantsLayer = true
        let circle = CAShapeLayer()
        circle.frame = tint.bounds
        circle.path = CGPath(ellipseIn: tint.bounds, transform: nil)
        circle.fillColor = nil
        circle.actions = ["fillColor": NSNull()]
        tint.layer?.addSublayer(circle)
        // 边缘加深: only the outermost tenth of the radius (it started at 62 % until 0.5.92 and made the disc look
        // like a thick, puffy cake).
        let edge = CAGradientLayer()
        edge.frame = tint.bounds
        edge.type = .radial
        edge.startPoint = CGPoint(x: 0.5, y: 0.5)
        edge.endPoint = CGPoint(x: 1, y: 1)
        edge.locations = [0, 0.90, 0.97, 1]
        edge.actions = ["colors": NSNull()]
        let edgeMask = CAShapeLayer()
        edgeMask.frame = edge.bounds
        edgeMask.path = CGPath(ellipseIn: edge.bounds, transform: nil)
        edge.mask = edgeMask
        tint.layer?.addSublayer(edge)
        tint.alphaValue = 0
        root.addSubview(tint)
        return GlassStack(glass: glass, tint: tint, tintCircle: circle, edge: edge)
    }

    private var tuning: LiquidGlassTuning { tuningOverride ?? LiquidGlassTuningStore.shared.value }

    /// Numbers only, for the runtime trace at the start of a real gesture.
    var tuningTraceSummary: String {
        let t = tuning
        let look = t.look
        return "blur=\(t.blur) tone=\(Int((look.tone * 100).rounded())) edge=\(Int((look.rimShade * 100).rounded())) "
            + "core=\(Int((look.coreBrightness * 100).rounded())) shadow=\(Int((look.shadowStrength * 100).rounded())) "
            + "lines=\(Int((look.lines * 100).rounded())) "
            + "glass=\(dial == nil ? 0 : 1) inWindow=\(view.window == nil ? 0 : 1) "
            + "listeners=\(LiquidGlassTuningStore.shared.listenerCount)"
    }

    /// Re-reads 设置 → 外观 → 液态玻璃调节 and applies it at once (the settings stage updates live).
    func applyTuning() {
        let t = tuning
        if #available(macOS 26.0, *) {
            for case let glass as NSGlassEffectView in [dial?.glass, core?.glass].compactMap({ $0 }) {
                glass.style = t.blur == 0 ? .clear : .regular
                glass.tintColor = nil
            }
        }
        let look = t.look
        let shade = CGFloat(min(max(look.rimShade, 0), 1))
        let edgeColors = [0, 0, shade * 0.45, shade].map { NSColor.black.withAlphaComponent($0).cgColor }
        for stack in [dial, core].compactMap({ $0 }) {
            stack.tintCircle.fillColor = look.toneColor?.cgColor
            stack.edge.colors = edgeColors
        }
        show(dial, dialShown, animated: false)
        show(core, coreShown, animated: false)
        radial.applyGlassMarks(coreBrightness: CGFloat(look.coreBrightness), lines: CGFloat(look.lines))
        radial.applyOuterShadow(
            strength: CGFloat(look.shadowStrength), spread: CGFloat(look.shadowSpread), drop: CGFloat(look.shadowDrop))
        radial.snapAmplitude = CGFloat(t.snapAmplitude)
        radial.snapDuration = t.snapDuration
    }

    private func setDialShown(_ alpha: CGFloat, animated: Bool) {
        dialShown = alpha
        show(dial, alpha, animated: animated)
    }

    private func setCoreShown(_ alpha: CGFloat, animated: Bool) {
        coreShown = alpha
        show(core, alpha, animated: animated)
    }

    private func show(_ stack: GlassStack?, _ alpha: CGFloat, animated: Bool) {
        guard let stack else { return }
        if animated && !env.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                stack.glass.animator().alphaValue = alpha
                stack.tint.animator().alphaValue = alpha
            }
        } else {
            stack.glass.alphaValue = alpha
            stack.tint.alphaValue = alpha
        }
    }

    func apply(_ environment: HUDEnvironment) {
        env = environment
        if dial != nil {
            view.appearance = NSAppearance(named: environment.isDark ? .darkAqua : .aqua)
        }
        radial.setReduceMotion(environment.reduceMotion)
    }

    func present(coreOnly: Bool) {
        released = false
        aim = .none
        view.alphaValue = 1
        setDialShown(coreOnly ? 0 : 1, animated: false)
        setCoreShown(coreOnly ? 1 : 0, animated: false)
        radial.clearFeedback()
        radial.setAction(.stop, animated: false)
        radial.setStatus(.listening)
        radial.setRadialChromeHidden(false)
        radial.setDirectionalActionsHidden(coreOnly)
        radial.animatePresentation()
    }

    func update(level: CGFloat) {
        // The product RadialHUDView reads its injected microphone monitor.
    }

    func update(pointer: HUDPointer) {
        guard !released, pointer.aim != aim else { return }
        aim = pointer.aim
        let action: VoiceReleaseAction = aim == .send ? .send : (aim == .cancel ? .cancel : .stop)
        radial.setAction(action, animated: !env.reduceMotion)
    }

    func release(_ action: HUDRelease, completion: @escaping @MainActor () -> Void) {
        guard !released else { return }
        released = true
        let a: VoiceReleaseAction = action == .send ? .send : (action == .cancel ? .cancel : .stop)
        radial.commit(a)
        Anim.after(env.reduceMotion ? 0 : 0.2) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self.view.animator().alphaValue = 0
            }
            Anim.after(0.13) { [weak self] in
                self?.radial.stopAnimations()
                completion()
            }
        }
    }

    func showFeedback(_ message: String, completion: @escaping @MainActor () -> Void) {
        released = true
        setDialShown(0, animated: false)
        setCoreShown(0, animated: false)
        radial.showFeedback(message: message, kind: .warning)
        Anim.after(2.2) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.view.animator().alphaValue = 0
            }
            Anim.after(0.21) { [weak self] in
                self?.radial.stopAnimations()
                completion()
            }
        }
    }
}
