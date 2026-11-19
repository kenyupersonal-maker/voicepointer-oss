import AppKit
import QuartzCore
import VoicePointerCore

// MARK: - 经典：the product's RadialHUDView (with the two §3.3 tweaks) behind the HUDSkin protocol.

@MainActor
final class ClassicSkin: HUDSkin, LiquidGlassTunable {
    let view: NSView
    private let radial: RadialHUDView
    private var env = HUDEnvironment()
    private var aim: HUDAim = .none
    private var released = false

    init(radial: RadialHUDView) {
        let root = NSView(frame: NSRect(origin: .zero, size: HUDLayout.panelSize))
        root.wantsLayer = true
        // Light until the first apply(); from 0.5.76 the classic skin follows the system appearance.
        root.appearance = NSAppearance(named: .aqua)
        view = root
        self.radial = radial
        root.addSubview(radial)
        LiquidGlassTuningStore.shared.register(self)
        applyTuning()
    }

    /// 质感调节 → 磨砂: 纹路 and 投影, plus the shared return-to-centre snap. The defaults are the classic dial as it was.
    func applyTuning() {
        let t = LiquidGlassTuningStore.shared.value
        radial.applyClassicLook(
            lines: CGFloat(t.frost.lines), shadowStrength: CGFloat(t.frost.shadowStrength),
            spread: CGFloat(t.frost.shadowSpread), drop: CGFloat(t.frost.shadowDrop))
        radial.snapAmplitude = CGFloat(t.snapAmplitude)
        radial.snapDuration = t.snapDuration
    }

    func apply(_ environment: HUDEnvironment) {
        env = environment
        view.appearance = NSAppearance(named: environment.isDark ? .darkAqua : .aqua)
        radial.setReduceMotion(environment.reduceMotion)
    }

    func present(coreOnly: Bool) {
        released = false
        aim = .none
        view.alphaValue = 1
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
