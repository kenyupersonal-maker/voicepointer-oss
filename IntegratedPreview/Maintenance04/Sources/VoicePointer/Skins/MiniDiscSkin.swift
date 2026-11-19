import AppKit
import QuartzCore

/// 小圆盘（2026-11-10，Ken：「小球就用咱们现在这个柔和的那个皮肤」）：一颗系统液态玻璃小圆盘。说话时五根语音条跳；
/// 推过 Send / Cancel 的那一刻（和标签变色、松手的判断是同一个），语音条转着缩没、一笔画出 ↑ 或 ↩，自己播完，
/// 不跟着手指停在半截；推回来时倒着播回去（Ken，2026-11-10 下午）。
/// 小圆盘（形变）（morphs = true）：像液态金属那样，玻璃片本身变形——上推时整片玻璃变成一个圆角三角，下推时压成一条
/// 横的圆角长条（里面画 ↩），形状和液态金属那款一致。系统玻璃只能是圆角矩形，所以这一款用一块更大的系统玻璃，用形状遮罩切出圆 / 三角 / 长条，
/// 边缘自己画一圈细亮线。
/// 0.5.94：常规玻璃原样放在白底上是一片死白，看不出是玻璃（Ken）。实验页比过（常规 / 透明 × 几档压暗 × 三种投影，
/// 文字底和白底，浅深）：透明玻璃在白底上更白，压在文字上边缘折射得更厚；常规玻璃压暗 5 % 在白底上是一颗浅灰的玻璃，
/// 压在文字上折射带被模糊收住、显得薄。所以用常规玻璃压暗 5 %，投影换成更大更淡的那种。
@MainActor
final class MiniDiscSkin: HUDSkin, LiquidGlassTunable {
    let view: NSView
    private let overlay = HUDLayerView(frame: NSRect(origin: .zero, size: HUDLayout.panelSize))
    private let shadowView = HUDLayerView(frame: NSRect(origin: .zero, size: HUDLayout.panelSize))
    private var glass: NSView?
    private let ambient = CAShapeLayer()
    private let key = CAShapeLayer()
    private let outsideMask = CAShapeLayer()
    private let tint = CAShapeLayer()
    private let barGroup = CALayer()
    private let bars = (0..<5).map { _ in CAShapeLayer() }
    private let symbol = CAShapeLayer()
    private let sendLabel = ArcTextLayer()
    private let cancelLabel = ArcTextLayer()
    private var toast: NSView?
    private var env = HUDEnvironment()
    private var coreOnly = false
    private var released = false
    private var aim: HUDAim = .none
    private var level: CGFloat = 0
    private var history = Array(repeating: CGFloat.zero, count: 5)
    private var shownSymbol: HUDAim = .none
    /// When the symbol being drawn is complete (its stroke starts a little after the bars turn away).
    private var symbolDoneAt: CFTimeInterval = 0
    private var generation = 0
    private let c = HUDLayout.anchor
    private let diameter: CGFloat = 84
    /// 小圆盘（形变）: the glass changes shape with the symbol.
    let morphs: Bool
    /// The glass outline right now: 小圆盘 is always the circle; 形变 springs between outlines sampled at the same
    /// number of points (circle, arrow, ellipse), so any two of them blend point by point.
    private var shapePoints: [CGPoint] = []
    private var shapeFrom: [CGPoint] = []
    private var shapeTo: [CGPoint] = []
    private var shapeT: CGFloat = 1
    private var shapeV: CGFloat = 0
    private var shapeTimer: Timer?
    private let glassMask = CAShapeLayer()
    private let rim = CAShapeLayer()

    /// One look of the small disc. Review host only sets `lookOverride`; the app uses `.standard`.
    struct Look: Equatable, Sendable {
        var clearGlass = false
        /// 明暗 over the glass: negative darker, positive lighter (the layer's opacity).
        var tone: CGFloat = -0.05
        /// 0: 0.5.93 (a close shadow and a wider one, both below). 1: larger and lighter. 2: largest and lightest.
        var shadow = 1
        static let standard = Look()
    }
    var lookOverride: Look? { didSet { applyTuning() } }

    static var isSupported: Bool { LiquidGlassSkin.isSupported }

    private var backingScale: CGFloat { view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var discFrame: CGRect {
        CGRect(x: c.x - diameter / 2, y: c.y - diameter / 2, width: diameter, height: diameter)
    }

    init(morphs: Bool = false) {
        self.morphs = morphs
        let root = NSView(frame: NSRect(origin: .zero, size: HUDLayout.panelSize))
        root.wantsLayer = true
        view = root
        root.addSubview(shadowView)
        buildShadow()
        if #available(macOS 26.0, *) {
            // 形变: a larger piece of glass, cut to the outline by a mask (the system glass is only a rounded rect).
            let frame = morphs ? Self.morphBox(around: c) : discFrame
            let disc = NSGlassEffectView(frame: frame)
            disc.style = .regular
            disc.cornerRadius = morphs ? 30 : diameter / 2
            if morphs {
                disc.wantsLayer = true
                glassMask.frame = CGRect(origin: .zero, size: frame.size)
                glassMask.actions = ["path": NSNull()]
                disc.layer?.mask = glassMask
            }
            disc.tintColor = nil
            disc.contentView = NSView(frame: CGRect(origin: .zero, size: discFrame.size))
            root.addSubview(disc)
            glass = disc
        }
        root.addSubview(overlay)
        buildOverlay()
        LiquidGlassTuningStore.shared.register(self)
        applyTuning()
    }

    /// The big disc's soft shadow, drawn only outside the glass (inside it would grey the glass).
    private func buildShadow() {
        let host = shadowView.host
        for layer in [ambient, key] {
            layer.frame = host.bounds
            // No fill (0.5.102): the layer only casts. Filled black, the cut-out's antialiased edge let a hairline of
            // it through, the thin black line round the disc Ken saw.
            layer.fillColor = nil
            layer.shadowColor = NSColor.black.cgColor
            layer.actions = ["path": NSNull(), "shadowPath": NSNull()]
            host.addSublayer(layer)
        }
        outsideMask.frame = host.bounds
        outsideMask.fillRule = .evenOdd
        outsideMask.actions = ["path": NSNull()]
        host.mask = outsideMask
    }

    // MARK: Outline

    private static let samples = 120
    static func morphBox(around c: CGPoint) -> CGRect { CGRect(x: c.x - 64, y: c.y - 64, width: 128, height: 128) }

    private static func circlePoints(_ c: CGPoint, _ r: CGFloat) -> [CGPoint] {
        (0..<samples).map { i in
            let a = CGFloat(i) / CGFloat(samples) * 2 * .pi + .pi / 2
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
    }

    /// Where rays from `o` meet the polygon, one per sample, rounded by averaging neighbours `rounds` times.
    private static func sampled(_ poly: [CGPoint], from o: CGPoint, around c: CGPoint, rounds: Int) -> [CGPoint] {
        var radii: [CGFloat] = (0..<samples).map { i in
            let a = CGFloat(i) / CGFloat(samples) * 2 * .pi + .pi / 2
            let d = CGPoint(x: cos(a), y: sin(a))
            var best = CGFloat.greatestFiniteMagnitude
            for j in 0..<poly.count {
                let p = poly[j], q = poly[(j + 1) % poly.count]
                let e = CGPoint(x: q.x - p.x, y: q.y - p.y)
                let den = d.x * e.y - d.y * e.x
                guard abs(den) > 1e-6 else { continue }
                let w = CGPoint(x: p.x - o.x, y: p.y - o.y)
                let t = (w.x * e.y - w.y * e.x) / den
                let u = (w.x * d.y - w.y * d.x) / den
                if t > 0, u >= 0, u <= 1 { best = min(best, t) }
            }
            return best
        }
        for _ in 0..<rounds {
            radii = radii.indices.map { i in
                (radii[(i + samples - 1) % samples] + 2 * radii[i] + radii[(i + 1) % samples]) / 4
            }
        }
        return (0..<samples).map { i in
            let a = CGFloat(i) / CGFloat(samples) * 2 * .pi + .pi / 2
            return CGPoint(x: c.x + o.x + radii[i] * cos(a), y: c.y + o.y + radii[i] * sin(a))
        }
    }

    /// 2026-11-10 (Ken, pointing at 液态金属): the same shapes as that skin. Send: a rounded triangle pointing up.
    private static func arrowPoints(_ c: CGPoint) -> [CGPoint] {
        sampled([CGPoint(x: 0, y: 46), CGPoint(x: 42, y: -24), CGPoint(x: -42, y: -24)],
                from: CGPoint(x: 0, y: 0), around: c, rounds: 10)
    }

    /// Cancel: a wide rounded bar (a capsule), a little below the start.
    private static func ellipsePoints(_ c: CGPoint) -> [CGPoint] {
        let halfW: CGFloat = 50, r: CGFloat = 23
        var poly: [CGPoint] = []
        for i in 0...24 {      // right cap, bottom to top
            let a = -CGFloat.pi / 2 + CGFloat(i) / 24 * .pi
            poly.append(CGPoint(x: halfW - r + r * cos(a), y: r * sin(a)))
        }
        for i in 0...24 {      // left cap, top to bottom
            let a = CGFloat.pi / 2 + CGFloat(i) / 24 * .pi
            poly.append(CGPoint(x: -(halfW - r) + r * cos(a), y: r * sin(a)))
        }
        return sampled(poly, from: .zero, around: CGPoint(x: c.x, y: c.y - 6), rounds: 1)
    }

    private static func path(_ pts: [CGPoint], offset: CGPoint = .zero) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.x - offset.x, y: first.y - offset.y))
        for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x - offset.x, y: p.y - offset.y)) }
        path.closeSubpath()
        return path
    }

    private func outline(_ target: HUDAim) -> [CGPoint] {
        guard morphs else { return Self.circlePoints(c, diameter / 2) }
        switch target {
        case .send: return Self.arrowPoints(c)
        case .cancel: return Self.ellipsePoints(c)
        case .none: return Self.circlePoints(c, diameter / 2)
        }
    }

    /// Puts the tone, the shadow, the 形变 mask and rim, and the marks on the outline (no implicit animation).
    private func layoutShape(_ pts: [CGPoint]) {
        shapePoints = pts
        let shape = Self.path(pts)
        let bounds = shape.boundingBoxOfPath
        let centre = CGPoint(x: bounds.midX, y: morphs && shownSymbol == .send ? c.y : bounds.midY)
        Anim.quiet {
            tint.path = shape
            key.path = shape
            key.shadowPath = shape
            ambient.path = shape
            ambient.shadowPath = shape
            let outside = CGMutablePath()
            outside.addRect(shadowView.host.bounds)
            outside.addPath(shape)
            outsideMask.path = outside
            if morphs, let glass {
                glassMask.path = Self.path(pts, offset: glass.frame.origin)
                rim.path = shape
            }
            symbol.position = centre
            barGroup.position = centre
        }
    }

    /// 形变: springs the glass toward `target`'s outline (a slight overshoot, about 0.4 s), frame by frame.
    private func morph(to target: HUDAim) {
        guard morphs else { return }
        let goal = outline(target)
        if env.reduceMotion {
            stopMorph()
            layoutShape(goal)
            return
        }
        shapeFrom = shapePoints.count == goal.count ? shapePoints : outline(.none)
        shapeTo = goal
        shapeT = 0
        shapeV = 0
        if shapeTimer == nil {
            var last = CACurrentMediaTime()
            shapeTimer = scheduleMainActorTimer(every: 1.0 / 120.0, mode: .common) { [weak self] in
                guard let self else { return }
                let now = CACurrentMediaTime()
                let dt = CGFloat(min(now - last, 1.0 / 30.0))
                last = now
                self.stepMorph(dt)
            }
        }
    }

    private func stepMorph(_ dt: CGFloat) {
        // damped spring on t: 0 → 1, ω 15, ζ 0.58
        let omega: CGFloat = 15, zeta: CGFloat = 0.58
        let accel = -2 * zeta * omega * shapeV - omega * omega * (shapeT - 1)
        shapeV += accel * dt
        shapeT += shapeV * dt
        let t = shapeT
        layoutShape(zip(shapeFrom, shapeTo).map { a, b in CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) })
        if abs(shapeT - 1) < 0.002 && abs(shapeV) < 0.01 {
            layoutShape(shapeTo)
            stopMorph()
        }
    }

    private func stopMorph() {
        shapeTimer?.invalidate()
        shapeTimer = nil
        shapeT = 1
        shapeV = 0
    }

    private func buildOverlay() {
        let host = overlay.host
        tint.path = Self.path(Self.circlePoints(c, diameter / 2))
        tint.actions = ["fillColor": NSNull(), "opacity": NSNull(), "path": NSNull()]
        host.addSublayer(tint)
        if morphs {
            // The cut glass has no edge of its own: a thin bright line, a little stronger at the top.
            rim.fillColor = nil
            rim.lineWidth = 0.8
            rim.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
            rim.shadowColor = NSColor.black.cgColor
            rim.shadowOpacity = 0.10
            rim.shadowRadius = 0.6
            rim.shadowOffset = .zero
            rim.actions = ["path": NSNull(), "strokeColor": NSNull()]
            host.addSublayer(rim)
        }
        barGroup.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        barGroup.position = c
        barGroup.actions = ["transform": NSNull(), "opacity": NSNull()]
        for bar in bars {
            bar.actions = ["path": NSNull(), "fillColor": NSNull()]
            barGroup.addSublayer(bar)
        }
        host.addSublayer(barGroup)
        symbol.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        symbol.position = c
        symbol.fillColor = nil
        symbol.lineWidth = 3
        symbol.lineCap = .round
        symbol.lineJoin = .round
        symbol.strokeEnd = 0
        symbol.actions = ["path": NSNull(), "strokeColor": NSNull(), "opacity": NSNull(), "transform": NSNull()]
        host.addSublayer(symbol)
        host.addSublayer(sendLabel)
        host.addSublayer(cancelLabel)
    }

    // MARK: Tuning

    /// The small disc keeps its own look (it no longer follows 柔和, see the type comment); only the shadow's strength,
    /// spread and drop still come from 质感调节 → 柔和, so the shadow there tunes both.
    func applyTuning() {
        let look = self.look
        let t = LiquidGlassTuningStore.shared.value.soft
        let strength = Float(min(max(t.shadowStrength, 0), 2))
        let spread = CGFloat(min(max(t.shadowSpread, 0), 60))
        let drop = min(max(CGFloat(t.shadowDrop), 0), 30)
        if #available(macOS 26.0, *), let disc = glass as? NSGlassEffectView {
            disc.style = look.clearGlass ? .clear : .regular
            disc.tintColor = nil
        }
        // 2026-11-10 (Ken: the small disc's shadow did not look natural; larger and lighter?): look.shadow picks how.
        let k: (opacity: Float, radius: CGFloat, drop: CGFloat, wideOpacity: Float, wideRadius: CGFloat, wideDrop: CGFloat)
        switch look.shadow {
        case 0: k = (0.16, spread * 0.26, drop * 0.55, 0.07, spread * 0.55, drop * 1.1)
        // 1 (the one in use): Ken 18:13 — still dirty; half the opacity and a little lower.
        case 1: k = (0.0425, spread * 0.48, drop * 0.95, 0.025, spread * 0.95, drop * 1.6)
        default: k = (0.05, spread * 0.70, drop * 0.85, 0.035, spread * 1.30, drop * 1.6)
        }
        Anim.quiet {
            let tone = look.tone
            tint.fillColor = (tone < -0.001 ? NSColor.black.withAlphaComponent(-tone)
                : (tone > 0.001 ? NSColor.white.withAlphaComponent(tone) : NSColor.clear)).cgColor
            key.shadowOpacity = k.opacity * strength
            key.shadowRadius = k.radius
            key.shadowOffset = CGSize(width: 0, height: -k.drop)
            ambient.shadowOpacity = k.wideOpacity * strength
            ambient.shadowRadius = k.wideRadius
            ambient.shadowOffset = CGSize(width: 0, height: -k.wideDrop)
        }
        layoutShape(shapePoints.isEmpty ? outline(.none) : shapePoints)
        if morphs {
            rim.strokeColor = NSColor.white.withAlphaComponent(env.isDark ? 0.28 : 0.60).cgColor
        }
    }

    // MARK: HUDSkin

    func apply(_ environment: HUDEnvironment) {
        env = environment
        view.appearance = NSAppearance(named: environment.isDark ? .darkAqua : .aqua)
        configureLabels()
        drawBars()
        applyTuning()
    }

    /// 小圆盘 keeps the big disc's 柔和 glass as it is (0.5.102); 形变 keeps the 5 % dim it was tuned with.
    private var look: Look { lookOverride ?? (morphs ? .standard : Look(tone: 0)) }

    /// The big disc's snap (RadialHUDView.snapCore) on the whole small disc: a slight squeeze and swell each time the
    /// pointer crosses out to a side or back (Ken, 0.5.102). 形变 already springs.
    private func snap() {
        guard !morphs, !env.reduceMotion else { return }
        let tuning = LiquidGlassTuningStore.shared.value
        let amplitude = CGFloat(min(max(tuning.snapAmplitude, 0), 0.3)) * 0.7
        guard amplitude > 0.001 else { return }
        let values: [CGFloat] = [1 - amplitude * 1.2, 1 + amplitude, 1.0]
        func add(to layer: CALayer?, centre: CGPoint) {
            guard let layer else { return }
            let anchor = CGPoint(x: layer.bounds.minX + layer.anchorPoint.x * layer.bounds.width,
                                 y: layer.bounds.minY + layer.anchorPoint.y * layer.bounds.height)
            let snap = CAKeyframeAnimation(keyPath: "transform")
            snap.values = values.map { scale -> NSValue in
                var transform = CATransform3DMakeScale(scale, scale, 1)
                transform.m41 = (1 - scale) * (centre.x - anchor.x)
                transform.m42 = (1 - scale) * (centre.y - anchor.y)
                return NSValue(caTransform3D: transform)
            }
            snap.keyTimes = [0, 0.62, 1]
            snap.duration = min(max(tuning.snapDuration, 0.05), 1)
            snap.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            layer.add(snap, forKey: "snap")
        }
        add(to: overlay.host, centre: c)
        add(to: shadowView.host, centre: c)
        if let glass { add(to: glass.layer, centre: CGPoint(x: glass.bounds.midX, y: glass.bounds.midY)) }
    }

    func present(coreOnly: Bool) {
        generation += 1
        self.coreOnly = coreOnly
        released = false
        aim = .none
        level = 0
        history = Array(repeating: 0, count: 5)
        shownSymbol = .none
        stopMorph()
        toast?.removeFromSuperview()
        toast = nil
        view.alphaValue = 1
        glass?.alphaValue = 1
        if let glass { glass.frame = morphs ? Self.morphBox(around: c) : discFrame }
        layoutShape(outline(.none))
        symbol.removeAllAnimations()
        barGroup.removeAllAnimations()
        overlay.host.removeAllAnimations()
        shadowView.host.removeAllAnimations()
        Anim.quiet {
            overlay.host.opacity = 1
            overlay.host.transform = CATransform3DIdentity
            shadowView.host.opacity = 1
            shadowView.host.transform = CATransform3DIdentity
            symbol.strokeEnd = 0
            symbol.strokeStart = 0
            symbol.opacity = 1
            symbol.transform = CATransform3DIdentity
            tint.opacity = 1
            barGroup.transform = CATransform3DIdentity
            barGroup.opacity = 1
        }
        applyTuning()
        configureLabels()
        drawBars()
    }

    func update(level raw: CGFloat) {
        guard !released else { return }
        let target = min(max(raw, 0), 1)       // already perceptual (MicrophoneLevelMonitoring.displayLevel)
        level += (target - level) * (target > level ? 0.62 : 0.20)
        history.removeLast()
        history.insert(level, at: 0)
        drawBars()
    }

    func update(pointer: HUDPointer) {
        guard !released else { return }
        let next: HUDAim = coreOnly ? .none : pointer.aim
        if next != aim {
            aim = next
            colorLabels(animated: true)
            showSymbol(aim)
            morph(to: aim)
            snap()
        }
    }

    func release(_ action: HUDRelease, completion: @escaping @MainActor () -> Void) {
        guard !released else { return }
        released = true
        generation += 1
        let current = generation
        let quick = env.reduceMotion
        let d: Double = quick ? 0.1 : 0.34
        var fadeDelay: Double = 0
        var fadeDuration: Double = d
        if action == .send { showSymbol(.send); morph(to: .send) }
        if action == .cancel { showSymbol(.cancel); morph(to: .cancel) }
        if action == .keep { showSymbol(.none); morph(to: .none) }
        Anim.opacity(sendLabel, 0, 0.15)
        Anim.opacity(cancelLabel, 0, 0.15)
        switch action {
        case .send where !quick:
            // The glass and its arrow lift away upward.
            let lift = CATransform3DMakeTranslation(0, 60, 0)
            Anim.transform(overlay.host, lift, d, .easeIn)
            Anim.transform(shadowView.host, lift, d, .easeIn)
            stopMorph()
            layoutShape(outline(.send))
            if let glass {
                let origin = glass.frame.origin
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = d
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    glass.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 60))
                }
            }
        case .cancel where !quick:
            // 0.5.103 (Ken): no spin. ↩ goes the way it came: the stroke is wiped off from the tail along the path,
            // the head last, fading as it goes. It waits for the drawing to finish if that is still under way.
            let now = CACurrentMediaTime()
            let wait = max(0, symbolDoneAt - now)
            let erase: CFTimeInterval = 0.30
            Anim.quiet {
                symbol.strokeStart = 1
                symbol.opacity = 0
            }
            for (keyPath, timing) in [("strokeStart", CAMediaTimingFunctionName.easeInEaseOut), ("opacity", .easeIn)] {
                let a = CABasicAnimation(keyPath: keyPath)
                a.fromValue = keyPath == "strokeStart" ? 0 : 1
                a.toValue = keyPath == "strokeStart" ? 1 : 0
                a.duration = erase
                a.timingFunction = CAMediaTimingFunction(name: timing)
                a.beginTime = now + wait
                a.fillMode = .backwards
                symbol.add(a, forKey: "erase." + keyPath)
            }
            // the disc fades once most of the stroke is gone
            fadeDelay = wait + erase * 0.45
            fadeDuration = 0.24
        default:
            break
        }
        let fade = fadeDuration
        Anim.after(fadeDelay) { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fade
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.view.animator().alphaValue = 0
            }
        }
        Anim.after(fadeDelay + fadeDuration + 0.02) { [weak self] in
            guard let self, self.generation == current else { return }
            self.stopMorph()
            completion()
        }
    }

    func showFeedback(_ message: String, completion: @escaping @MainActor () -> Void) {
        generation += 1
        let current = generation
        released = true
        view.alphaValue = 1
        glass?.alphaValue = 0
        Anim.quiet {
            shadowView.host.opacity = 0
            tint.opacity = 0
            barGroup.opacity = 0
            symbol.opacity = 0
            sendLabel.opacity = 0
            cancelLabel.opacity = 0
        }
        toast?.removeFromSuperview()
        let t = HUDGlassToast.make(message: message, center: c)
        view.addSubview(t)
        toast = t
        HUDGlassToast.fadeIn(t)
        Anim.after(2.2) { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.view.animator().alphaValue = 0
            }
            Anim.after(0.21) { [weak self] in
                guard let self, self.generation == current else { return }
                completion()
            }
        }
    }

    // MARK: Drawing

    /// The five bars' heights. Their turn and fade belong to showSymbol (threshold-triggered), not to the pointer.
    private func drawBars() {
        let minimum: [CGFloat] = [4, 6.5, 10, 6.5, 4]
        let response: [CGFloat] = [0.30, 0.65, 1.0, 0.65, 0.30]
        let powers: [CGFloat] = [1.25, 0.97, 0.68, 0.97, 1.25]
        let offsets = [4, 2, 0, 1, 3]
        Anim.quiet {
            for (i, bar) in bars.enumerated() {
                let h = minimum[i] + pow(history[offsets[i]], powers[i]) * 20 * response[i]
                let rect = CGRect(x: 30 + CGFloat(i - 2) * 6 - 1.5, y: 30 - h / 2, width: 3, height: h)
                let corner = min(1.5, h / 2)
                bar.path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
                bar.fillColor = Self.green.cgColor
            }
        }
    }

    /// Draws the symbol for `target` in one stroke, or takes it back.
    private func showSymbol(_ target: HUDAim) {
        guard target != shownSymbol else { return }
        let previous = shownSymbol
        shownSymbol = target
        // The bars turn toward the side and shrink away (or come back), in a fixed time.
        let dir: CGFloat = target == .cancel || (target == .none && previous == .cancel) ? -1 : 1
        var gone = CATransform3DMakeRotation(-dir * .pi / 2, 0, 0, 1)
        gone = CATransform3DScale(gone, 0.35, 0.35, 1)
        let barsTo = target == .none ? CATransform3DIdentity : gone
        let barsFromT = barGroup.presentation()?.transform ?? barGroup.transform
        let barsFromO = barGroup.presentation()?.opacity ?? barGroup.opacity
        Anim.quiet {
            barGroup.transform = barsTo
            barGroup.opacity = target == .none ? 1 : 0
        }
        let quick = env.reduceMotion
        for (keyPath, from, to) in [("transform", NSValue(caTransform3D: barsFromT) as Any, NSValue(caTransform3D: barsTo) as Any),
                                    ("opacity", barsFromO as Any, (target == .none ? 1 : 0) as Any)] {
            let a = CABasicAnimation(keyPath: keyPath)
            a.fromValue = from
            a.toValue = to
            a.duration = quick ? 0.01 : 0.22
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            barGroup.add(a, forKey: "snap." + keyPath)
        }
        let from = symbol.presentation()?.strokeEnd ?? symbol.strokeEnd
        let grow = CABasicAnimation(keyPath: "strokeEnd")
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if morphs {
            let look = self.look
            let rest = look.tone < 0 ? NSColor.black.withAlphaComponent(-look.tone) : NSColor.white.withAlphaComponent(look.tone)
            let fill = target == .send ? Self.green.withAlphaComponent(0.14) : rest
            let a = CABasicAnimation(keyPath: "fillColor")
            a.fromValue = tint.presentation()?.fillColor ?? tint.fillColor
            a.toValue = fill.cgColor
            a.duration = env.reduceMotion ? 0.01 : 0.22
            Anim.quiet { tint.fillColor = fill.cgColor }
            tint.add(a, forKey: "fill")
        }
        switch target {
        case .send where morphs:
            // the glass itself becomes the arrow
            Anim.quiet { symbol.strokeEnd = 0 }
            grow.fromValue = from
            grow.toValue = 0
            grow.duration = env.reduceMotion ? 0.01 : 0.12
        case .send, .cancel:
            Anim.quiet {
                symbol.path = target == .send ? SmallDiscMath.upArrow() : SmallDiscMath.undoArrow()
                symbol.strokeColor = (target == .send ? Self.green : Self.red).cgColor
                symbol.strokeEnd = 1
            }
            grow.fromValue = 0
            grow.toValue = 1
            grow.duration = env.reduceMotion ? 0.01 : 0.28
            // starts as the bars are half gone
            if !env.reduceMotion {
                grow.beginTime = CACurrentMediaTime() + 0.10
                grow.fillMode = .backwards
            }
            symbolDoneAt = CACurrentMediaTime() + (env.reduceMotion ? 0 : 0.38)
        case .none:
            Anim.quiet { symbol.strokeEnd = 0 }
            grow.fromValue = from
            grow.toValue = 0
            grow.duration = env.reduceMotion ? 0.01 : 0.16
        }
        symbol.add(grow, forKey: "grow")
    }

    private func configureLabels() {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let color = Self.labelColor(env.isDark).cgColor
        sendLabel.configure(text: "Send", font: font, color: color, kern: 0.3, radius: 62, placement: .top,
                            center: c, scale: backingScale)
        cancelLabel.configure(text: "Cancel", font: font, color: color, kern: 0.3, radius: 62, placement: .bottom,
                              center: c, scale: backingScale)
        Anim.quiet {
            sendLabel.opacity = coreOnly ? 0 : 1
            cancelLabel.opacity = coreOnly ? 0 : 1
        }
        colorLabels(animated: false)
    }

    private func colorLabels(animated: Bool) {
        let d: CFTimeInterval = animated && !env.reduceMotion ? 0.12 : 0
        let rest = Self.labelColor(env.isDark)
        sendLabel.setColor((aim == .send ? Self.green : rest).cgColor, duration: d)
        cancelLabel.setColor((aim == .cancel ? Self.red : rest).cgColor, duration: d)
    }

    private static let green = NSColor(srgbRed: 0x12 / 255, green: 0xBE / 255, blue: 0x1D / 255, alpha: 1)
    private static let red = NSColor(srgbRed: 1, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
    private static func labelColor(_ dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.58) : NSColor.black.withAlphaComponent(0.42)
    }
}

/// Shapes for the 小圆盘's symbols (symbol layer space, 40 × 40, y up).
enum SmallDiscMath {
    static func ease(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// ↑ drawn from the tail up to the tip, then the head from left to right.
    static func upArrow() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 20, y: 7))
        path.addLine(to: CGPoint(x: 20, y: 33))
        path.move(to: CGPoint(x: 10, y: 23))
        path.addLine(to: CGPoint(x: 20, y: 33))
        path.addLine(to: CGPoint(x: 30, y: 23))
        return path
    }

    /// ↩ (undo), drawn from the top down (Ken, 2026-11-10: it used to start at the bottom, which read the wrong way):
    /// from the top tail round the right-hand turn to the tip at the lower left, then the head.
    static func undoArrow() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 13, y: 31))
        path.addLine(to: CGPoint(x: 22, y: 31))
        path.addArc(center: CGPoint(x: 22, y: 22.5), radius: 8.5, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: 9, y: 14))
        path.move(to: CGPoint(x: 15, y: 8))
        path.addLine(to: CGPoint(x: 9, y: 14))
        path.addLine(to: CGPoint(x: 15, y: 20))
        return path
    }
}
