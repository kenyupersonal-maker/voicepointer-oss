import AppKit
import QuartzCore

/// 磨砂（v1）：跟随系统浅色/深色的磨砂圆盘，指向的半圈高亮。数值见 16 号 v1 §4。
@MainActor
final class FrostedSkin: HUDSkin {
    let view: NSView
    private let shadowView = HUDLayerView(frame: NSRect(origin: .zero, size: HUDLayout.panelSize))
    private let effect = NSVisualEffectView(frame: .zero)
    private let overlay = HUDLayerView(frame: NSRect(origin: .zero, size: HUDLayout.panelSize))
    private var env = HUDEnvironment()
    private var coreOnly = false
    private var aim: HUDAim = .none
    private var released = false
    private var presentationGeneration = 0
    private var scale: CGFloat { view.window?.backingScaleFactor ?? 2 }

    private let ambient = CAShapeLayer()
    private let contact = CAShapeLayer()
    private let shadowMask = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let sheenMask = CAShapeLayer()
    private let rimInner = CAShapeLayer()
    private let rimOuter = CAShapeLayer()
    private let sepL = CAGradientLayer()
    private let sepR = CAGradientLayer()
    private let sendFill = CAShapeLayer()
    private let cancelFill = CAShapeLayer()
    private let sendArc = CAShapeLayer()
    private let cancelArc = CAShapeLayer()
    private let sendLabel = ArcTextLayer()
    private let cancelLabel = ArcTextLayer()
    private let coreShadow = CALayer()
    private let core = CAGradientLayer()
    private let coreHighlight = CAShapeLayer()
    private let wave = WaveformLayer()
    private var pill: PillLayer?

    init() {
        let root = NSView(frame: NSRect(origin: .zero, size: HUDLayout.panelSize))
        root.wantsLayer = true
        view = root
        root.addSubview(shadowView)
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.material = .popover
        root.addSubview(effect)
        root.addSubview(overlay)
        build()
    }

    // MARK: Tokens (16 号 v1 §4)

    private struct Tokens {
        let discFill, sheen, rimInner, rimOuter, label, labelSelected, separator: NSColor
        let sendFill, sendArc, cancelFill, cancelArc: NSColor
        let coreTop, coreBottom, coreRim, coreHighlight, waveform: NSColor
        let ambient, contact, coreShadow: Float
    }

    private var t: Tokens {
        if env.isDark {
            return Tokens(
                discFill: .srgb(34, 34, 37, 0.78), sheen: NSColor.white.withAlphaComponent(0.08),
                rimInner: NSColor.white.withAlphaComponent(0.10), rimOuter: NSColor.black.withAlphaComponent(0.45),
                label: NSColor.white.withAlphaComponent(env.increaseContrast ? 0.88 : 0.76),
                labelSelected: NSColor.white.withAlphaComponent(0.96),
                separator: NSColor.white.withAlphaComponent(0.14),
                sendFill: .srgb(48, 209, 88, env.increaseContrast ? 0.36 : 0.24), sendArc: .srgb(48, 209, 88),
                cancelFill: NSColor.white.withAlphaComponent(env.increaseContrast ? 0.135 : 0.09),
                cancelArc: NSColor.white.withAlphaComponent(0.50),
                coreTop: NSColor.white.withAlphaComponent(0.12), coreBottom: NSColor.white.withAlphaComponent(0.05),
                coreRim: NSColor.white.withAlphaComponent(0.12), coreHighlight: NSColor.white.withAlphaComponent(0.10),
                waveform: .srgb(48, 209, 88), ambient: 0.42, contact: 0.30, coreShadow: 0.35
            )
        }
        return Tokens(
            discFill: .srgb(244, 244, 246, 0.78), sheen: NSColor.white.withAlphaComponent(0.45),
            rimInner: NSColor.white.withAlphaComponent(0.70), rimOuter: NSColor.black.withAlphaComponent(env.increaseContrast ? 0.30 : 0.08),
            label: NSColor.black.withAlphaComponent(env.increaseContrast ? 0.80 : 0.62),
            labelSelected: NSColor.black.withAlphaComponent(0.90),
            separator: NSColor.black.withAlphaComponent(0.10),
            sendFill: .srgb(52, 199, 89, env.increaseContrast ? 0.24 : 0.16), sendArc: .srgb(31, 163, 74),
            cancelFill: NSColor.black.withAlphaComponent(env.increaseContrast ? 0.09 : 0.06),
            cancelArc: NSColor.black.withAlphaComponent(0.45),
            coreTop: NSColor.white.withAlphaComponent(0.85), coreBottom: NSColor.white.withAlphaComponent(0.55),
            coreRim: NSColor.black.withAlphaComponent(0.08), coreHighlight: NSColor.white.withAlphaComponent(0.90),
            waveform: .srgb(31, 163, 74), ambient: 0.16, contact: 0.10, coreShadow: 0.08
        )
    }

    // MARK: Build

    private var c: CGPoint { HUDLayout.anchor }
    private var discRect: CGRect { CGRect(x: c.x - 100, y: c.y - 100, width: 200, height: 200) }
    private var coreRect: CGRect { CGRect(x: c.x - 40, y: c.y - 40, width: 80, height: 80) }

    private func circleImage(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    private func halfAnnulus(top: Bool) -> CGPath {
        let p = CGMutablePath()
        let a0: CGFloat = top ? 0 : .pi
        let a1: CGFloat = top ? .pi : 2 * .pi
        p.addArc(center: c, radius: 100, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: 42, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }

    private func edgeArc(top: Bool) -> CGPath {
        let p = CGMutablePath()
        let mid: CGFloat = top ? .pi / 2 : 3 * .pi / 2
        let half: CGFloat = 50 * .pi / 180
        p.addArc(center: c, radius: 94, startAngle: mid - half, endAngle: mid + half, clockwise: false)
        return p
    }

    private func build() {
        let sroot = shadowView.host
        for (l, r, off) in [(ambient, CGFloat(16), CGFloat(-12)), (contact, CGFloat(3), CGFloat(-2))] {
            l.frame = sroot.bounds
            l.fillColor = NSColor.black.cgColor
            l.shadowColor = NSColor.black.cgColor
            l.shadowRadius = r
            l.shadowOffset = CGSize(width: 0, height: off)
            sroot.addSublayer(l)
        }
        shadowMask.frame = sroot.bounds
        shadowMask.fillRule = .evenOdd
        shadowMask.fillColor = NSColor.black.cgColor
        sroot.mask = shadowMask

        let o = overlay.host
        for l in [fill, rimInner, rimOuter] { l.frame = o.bounds; o.addSublayer(l) }
        sheen.type = .radial
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint = CGPoint(x: 1.7, y: 0.1)
        sheen.locations = [0, 0.6]
        o.insertSublayer(sheen, above: fill)
        sheen.mask = sheenMask

        for (s, leftSide) in [(sepL, true), (sepR, false)] {
            s.type = .axial
            s.startPoint = CGPoint(x: 0, y: 0.5)
            s.endPoint = CGPoint(x: 1, y: 0.5)
            s.locations = leftSide ? [0, 0.45, 1] : [0, 0.55, 1]
            o.addSublayer(s)
        }
        for l in [sendFill, cancelFill] { l.frame = o.bounds; l.opacity = 0; o.addSublayer(l) }
        for l in [sendArc, cancelArc] {
            l.frame = o.bounds
            l.fillColor = nil
            l.lineWidth = 3
            l.lineCap = .round
            l.opacity = 0
            o.addSublayer(l)
        }
        for l in [sendLabel, cancelLabel] { l.frame = o.bounds; o.addSublayer(l) }
        coreShadow.cornerRadius = 40
        o.addSublayer(coreShadow)
        core.type = .axial
        core.startPoint = CGPoint(x: 0.5, y: 1)
        core.endPoint = CGPoint(x: 0.5, y: 0)
        core.cornerRadius = 40
        core.borderWidth = 0.5
        o.addSublayer(core)
        coreHighlight.fillColor = nil
        coreHighlight.lineWidth = 1
        coreHighlight.lineCap = .round
        o.addSublayer(coreHighlight)
        wave.bounds = CGRect(x: 0, y: 0, width: 40, height: 28)
        wave.position = c
        o.addSublayer(wave)
        wave.build(color: t.waveform.cgColor)
        layout()
    }

    private func layout() {
        let tk = t
        let disc = coreOnly ? coreRect : discRect
        effect.frame = disc
        effect.maskImage = circleImage(size: disc.size)
        let circle = CGPath(ellipseIn: disc, transform: nil)
        Anim.quiet {
            ambient.path = circle
            ambient.shadowPath = circle
            contact.path = circle
            contact.shadowPath = circle
            ambient.shadowRadius = coreOnly ? 9 : 16
            ambient.shadowOffset = CGSize(width: 0, height: coreOnly ? -6 : -12)
            contact.shadowRadius = coreOnly ? 1.5 : 3
            contact.shadowOffset = CGSize(width: 0, height: coreOnly ? -1 : -2)
            ambient.shadowOpacity = tk.ambient
            contact.shadowOpacity = tk.contact
            let outside = CGMutablePath()
            outside.addRect(shadowView.host.bounds)
            outside.addEllipse(in: disc.insetBy(dx: -0.5, dy: -0.5))
            shadowMask.path = outside

            fill.path = circle
            let reduce = env.reduceTransparency
            fill.fillColor = (reduce ? (env.isDark ? NSColor.srgb(44, 44, 46) : NSColor.srgb(242, 242, 244)) : tk.discFill).cgColor
            effect.isHidden = reduce
            sheen.frame = disc
            sheen.colors = [tk.sheen, tk.sheen.withAlphaComponent(0)].map(\.cgColor)
            sheenMask.path = CGPath(ellipseIn: CGRect(origin: .zero, size: disc.size), transform: nil)
            rimInner.path = CGPath(ellipseIn: disc.insetBy(dx: 0.25, dy: 0.25), transform: nil)
            rimInner.fillColor = nil
            rimInner.strokeColor = tk.rimInner.cgColor
            rimInner.lineWidth = 0.5
            rimOuter.path = CGPath(ellipseIn: disc.insetBy(dx: -0.25, dy: -0.25), transform: nil)
            rimOuter.fillColor = nil
            rimOuter.strokeColor = tk.rimOuter.cgColor
            rimOuter.lineWidth = env.increaseContrast ? 1 : 0.5

            sepL.frame = CGRect(x: c.x - 100, y: c.y - 0.5, width: 58, height: 1)
            sepR.frame = CGRect(x: c.x + 42, y: c.y - 0.5, width: 58, height: 1)
            for s in [sepL, sepR] {
                s.colors = [tk.separator.withAlphaComponent(0), tk.separator, tk.separator.withAlphaComponent(0)].map(\.cgColor)
            }
            sendFill.path = halfAnnulus(top: true)
            cancelFill.path = halfAnnulus(top: false)
            sendFill.fillColor = tk.sendFill.cgColor
            cancelFill.fillColor = tk.cancelFill.cgColor
            sendArc.path = edgeArc(top: true)
            cancelArc.path = edgeArc(top: false)
            sendArc.strokeColor = tk.sendArc.cgColor
            cancelArc.strokeColor = tk.cancelArc.cgColor

            coreShadow.frame = coreRect
            coreShadow.backgroundColor = NSColor.black.cgColor
            coreShadow.shadowColor = NSColor.black.cgColor
            coreShadow.shadowOpacity = tk.coreShadow
            coreShadow.shadowRadius = 1
            coreShadow.shadowOffset = CGSize(width: 0, height: -1)
            coreShadow.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: coreRect.size), transform: nil)
            coreShadow.opacity = coreOnly ? 0 : 1
            core.frame = coreRect
            core.colors = [tk.coreTop, tk.coreBottom].map(\.cgColor)
            core.borderColor = tk.coreRim.cgColor
            let hp = CGMutablePath()
            hp.addArc(center: c, radius: 39, startAngle: .pi * 0.2, endAngle: .pi * 0.8, clockwise: false)
            coreHighlight.path = hp
            coreHighlight.strokeColor = tk.coreHighlight.cgColor
            wave.setColor(tk.waveform.cgColor)

            for l in [sheen, rimInner, sepL, sepR, sendFill, cancelFill, sendArc, cancelArc] as [CALayer] { l.isHidden = coreOnly }
            sendLabel.isHidden = coreOnly
            cancelLabel.isHidden = coreOnly
            core.isHidden = false
        }
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        sendLabel.configure(text: "Send", font: font, color: tk.label.cgColor, kern: 0.2, radius: HUDLayout.labelRadius, placement: .top, center: c, scale: scale)
        cancelLabel.configure(text: "Cancel", font: font, color: tk.label.cgColor, kern: 0.2, radius: HUDLayout.labelRadius, placement: .bottom, center: c, scale: scale)
        applyAim(animated: false)
    }

    private func applyAim(animated: Bool) {
        let tk = t
        let dIn: CFTimeInterval = (animated && !env.reduceMotion) ? 0.12 : 0
        let dOut: CFTimeInterval = (animated && !env.reduceMotion) ? 0.09 : 0
        let send = aim == .send
        let cancel = aim == .cancel
        Anim.opacity(sendFill, send ? 1 : 0, send ? dIn : dOut)
        Anim.opacity(sendArc, send ? 1 : 0, send ? dIn : dOut)
        Anim.opacity(cancelFill, cancel ? 1 : 0, cancel ? dIn : dOut)
        Anim.opacity(cancelArc, cancel ? 1 : 0, cancel ? dIn : dOut)
        sendLabel.setColor((send ? tk.labelSelected : tk.label).cgColor, duration: send ? dIn : dOut)
        cancelLabel.setColor((cancel ? tk.labelSelected : tk.label).cgColor, duration: cancel ? dIn : dOut)
    }

    // MARK: HUDSkin

    func apply(_ environment: HUDEnvironment) {
        env = environment
        view.appearance = NSAppearance(named: env.isDark ? .darkAqua : .aqua)
        layout()
    }

    func present(coreOnly: Bool) {
        presentationGeneration += 1
        self.coreOnly = coreOnly
        released = false
        aim = .none
        pill?.removeFromSuperlayer()
        pill = nil
        for layer in overlay.host.sublayers ?? [] { layer.isHidden = false }
        view.alphaValue = 1
        overlay.host.opacity = 1
        shadowView.host.opacity = 1
        effect.alphaValue = 1
        layout()
        // v1: first frame is complete — no scale, no fade, no position change.
    }

    func update(level: CGFloat) {
        guard !released else { return }
        wave.update(level: level)
    }

    func update(pointer: HUDPointer) {
        guard !released, !coreOnly, pointer.aim != aim else { return }
        aim = pointer.aim
        applyAim(animated: true)
    }

    func release(_ action: HUDRelease, completion: @escaping @MainActor () -> Void) {
        guard !released else { return }
        released = true
        let generation = presentationGeneration
        let d = env.reduceMotion ? 0.1 : 0.14
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = d
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            view.animator().alphaValue = 0
        }
        Anim.after(d + 0.01) { [weak self] in
            guard self?.presentationGeneration == generation else { return }
            completion()
        }
    }

    func showFeedback(_ message: String, completion: @escaping @MainActor () -> Void) {
        presentationGeneration += 1
        let generation = presentationGeneration
        released = true
        view.alphaValue = 1
        effect.alphaValue = 0
        Anim.opacity(overlay.host, 1, 0)
        for l in overlay.host.sublayers ?? [] { l.isHidden = true }
        shadowView.host.opacity = 0
        let p = PillLayer()
        p.configure(message: message, center: c, scale: scale)
        overlay.host.addSublayer(p)
        pill = p
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 0
        f.toValue = 1
        f.duration = env.reduceMotion ? 0.1 : 0.15
        p.add(f, forKey: "in")
        Anim.after(2.0) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            Anim.opacity(p, 0, 0.2)
            Anim.after(0.21) {
                guard self.presentationGeneration == generation else { return }
                for l in self.overlay.host.sublayers ?? [] { l.isHidden = false }
                p.removeFromSuperlayer()
                self.pill = nil
                completion()
            }
        }
    }
}
