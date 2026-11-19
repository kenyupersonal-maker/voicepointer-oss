import AppKit
import QuartzCore
import VoicePointerCore

enum RadialHUDMetrics {
    static let logicalSize = CGSize(width: 256, height: 256)
    static let shadowPadding: CGFloat = 20
    static let panelSize = CGSize(
        width: logicalSize.width + shadowPadding * 2,
        height: logicalSize.height + shadowPadding * 2
    )
    static let logicalOrigin = CGPoint(x: shadowPadding, y: shadowPadding)
}

@MainActor
private final class HUDPillTextView: NSView {
    var text = "" {
        didSet { needsDisplay = true }
    }
    var textFont = NSFont.systemFont(ofSize: 11, weight: .semibold) {
        didSet { needsDisplay = true }
    }
    var maximumNumberOfLines = 1 {
        didSet { needsDisplay = true }
    }
    /// White on the legacy dark pill; the system label colour on Liquid Glass (resolved per draw).
    var textColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = maximumNumberOfLines > 1 ? .byTruncatingTail : .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let available = bounds.insetBy(dx: 12, dy: 0)
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: available.width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lineHeight = ceil(textFont.ascender - textFont.descender + textFont.leading)
        let maximumHeight = lineHeight * CGFloat(maximumNumberOfLines)
        let textHeight = min(maximumHeight, ceil(measured.height))
        let textRect = CGRect(
            x: available.minX,
            y: floor(bounds.midY - textHeight / 2) + 0.5,
            width: available.width,
            height: textHeight
        )
        (text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes
        )
    }
}

@MainActor
private final class HUDGlassPillView: NSView {
    private let effectView = NSVisualEffectView(frame: .zero)
    private let tintView = NSView(frame: .zero)
    private let textView = HUDPillTextView(frame: .zero)

    var text: String {
        get { textView.text }
        set { textView.text = newValue }
    }
    var textFont: NSFont {
        get { textView.textFont }
        set { textView.textFont = newValue }
    }
    var maximumNumberOfLines: Int {
        get { textView.maximumNumberOfLines }
        set { textView.maximumNumberOfLines = newValue }
    }

    /// macOS 26+: the system Liquid Glass capsule. Older systems keep the dark tinted blur.
    private var glassView: NSView?
    var usesSystemGlass: Bool { glassView != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        textView.wantsLayer = true
        textView.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.tintColor = nil
            glass.contentView = textView
            addSubview(glass)
            glassView = glass
            layer?.masksToBounds = false
            textView.textColor = .labelColor
            return
        }
        layer?.masksToBounds = true

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        addSubview(effectView)

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        tintView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        tintView.layer?.borderWidth = 0.5
        addSubview(tintView)

        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Darkness behind the legacy blur only. Liquid Glass draws its own surface and must stay untinted.
    func setFallbackBackdrop(_ color: NSColor) {
        layer?.backgroundColor = glassView == nil ? color.cgColor : nil
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        if let glassView {
            glassView.frame = bounds
            if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
                glass.cornerRadius = min(radius, CGFloat(LiquidGlassTuningStore.shared.value.toastCornerRadius))
            }
            textView.frame = glassView.bounds
            return
        }
        layer?.cornerRadius = radius
        for view in [effectView, tintView, textView] { view.frame = bounds }
        tintView.layer?.cornerRadius = radius
    }
}

/// 0.5.104 (Ken: every Toast was changed to the white glass one, so why is 「再下滑清空」 still a dark pill?): the skins
/// that draw their own disc used PillLayer, the old dark pill. They now show this, the big disc's own Toast.
@MainActor
enum HUDGlassToast {
    static func make(message: String, center: CGPoint, layoutScale: CGFloat = 1) -> NSView {
        let k = HUDLayout.clampedScale(layoutScale)
        let pill = HUDGlassPillView(frame: .zero)
        pill.maximumNumberOfLines = 2
        pill.textFont = NSFont.systemFont(
            ofSize: 12 * k, weight: pill.usesSystemGlass ? LiquidGlassTuningStore.shared.value.toastFontWeight : .semibold)
        pill.text = message
        let measured = (message as NSString).boundingRect(
            with: CGSize(width: 216 * k, height: 48 * k),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: pill.textFont]
        )
        let width = min(240 * k, max(96 * k, ceil(measured.width) + 24 * k))
        let height = min(48 * k, max(32 * k, ceil(measured.height) + 16 * k))
        pill.frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        pill.setFallbackBackdrop(NSColor.black.withAlphaComponent(0.62))
        pill.setAccessibilityElement(true)
        pill.setAccessibilityRole(.staticText)
        pill.setAccessibilityValue(message)
        return pill
    }

    static func fadeIn(_ toast: NSView) {
        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toast.animator().alphaValue = 1
        }
    }
}

/// Figma-backed radial HUD. Functional state and release semantics stay in
/// StatusHUD; this view owns only geometry, hit testing, and presentation.
@MainActor
final class RadialHUDView: NSView {
    private enum Geometry {
        static let anchor = CGPoint(x: 128, y: 132)
        static let dialFrame = CGRect(x: 28, y: 32, width: 200, height: 200)
        static let defaultAssetFrame = CGRect(x: 4, y: 0, width: 248, height: 248)
        static let sendGlowFrame = CGRect(x: 4, y: 32, width: 248, height: 224)
        static let undoGlowFrame = CGRect(x: 4, y: 8, width: 248, height: 224)
        static let ringFrame = CGRect(x: 87, y: 91, width: 82, height: 82)
        static let coreFrame = CGRect(x: 88, y: 92, width: 80, height: 80)
        static let waveformOrigin = CGPoint(x: 114, y: 118)
        static let sendIconFrame = CGRect(x: 98, y: 170, width: 57, height: 58)
        static let undoIconFrame = CGRect(x: 98, y: 34, width: 60, height: 55)
        static let arcLabelRadius: CGFloat = 68
        static let arcLabelCurvatureRadius: CGFloat = 66
    }

    private enum Palette {
        static let surface = NSColor(
            srgbRed: 0xED / 255.0,
            green: 0xED / 255.0,
            blue: 0xED / 255.0,
            alpha: 0.05
        )
        /// Light: black .36 on the light dial. Dark (classic in dark mode, or Liquid Glass): white .66.
        static let label = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.66)
                : NSColor.black.withAlphaComponent(0.36)
        }
        /// The recessed lettering: a dark inner edge above the face, a one-pixel highlight below it.
        /// On the dark dial the highlight would read as a second copy, so both go almost away.
        static let labelEdge = NSColor(name: nil) { appearance in
            NSColor.black.withAlphaComponent(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.22 : 0.05)
        }
        static let labelHighlight = NSColor(name: nil) { appearance in
            NSColor.white.withAlphaComponent(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.04 : 0.30)
        }
        static let waveform = NSColor(
            srgbRed: 0x12 / 255.0,
            green: 0xBE / 255.0,
            blue: 0x1D / 255.0,
            alpha: 1
        )
    }

    /// Three soft shadows under the glass (2026-09-29, Claude): a wide, almost centred
    /// ambient halo so the whole rim reads against the page (including the top edge),
    /// a gentle key shadow that gives depth below, and a faint contact line at the edge.
    private enum OuterShadowStyle {
        static let ambientOpacity: Float = 0.20
        static let ambientRadius: CGFloat = 30
        static let ambientSpread: CGFloat = -8
        static let ambientOffsetY: CGFloat = -3
        static let keyOpacity: Float = 0.10
        static let keyRadius: CGFloat = 12
        static let keySpread: CGFloat = -4
        static let keyOffsetY: CGFloat = -8
        static let contactOpacity: Float = 0.05
        static let contactRadius: CGFloat = 1.5
        static let contactOffsetY: CGFloat = -1
    }

    private let shadowHostView = NSView(
        frame: CGRect(
            origin: CGPoint(
                x: -RadialHUDMetrics.shadowPadding,
                y: -RadialHUDMetrics.shadowPadding
            ),
            size: RadialHUDMetrics.panelSize
        )
    )
    private let dialEffectView = NSVisualEffectView(frame: Geometry.dialFrame)
    private let coreEffectView = NSVisualEffectView(frame: Geometry.coreFrame)
    private let overlay = NSView(frame: CGRect(origin: .zero, size: RadialHUDMetrics.logicalSize))

    private let shadowAmbientLayer = CAShapeLayer()
    private let shadowContactLayer = CAShapeLayer()
    private let shadowKeyLayer = CAShapeLayer()
    private let shadowOutsideMaskLayer = CAShapeLayer()
    private let dialGroup = CALayer()

    /// Skins that bring their own dial surface (e.g. Liquid Glass) hide the built-in one and
    /// follow its visibility through this handler: (alpha, animated). Labels, core, grooves,
    /// glows and icons stay exactly as in the classic skin.
    var externalSurfaceAlphaHandler: (@MainActor (CGFloat, Bool) -> Void)?
    /// Liquid Glass: the core is the same glass as the dial, only a little lighter. Drop the separate
    /// frosted material view, its shadow, highlight and the ring's fill; only the core fill and the ring's
    /// hairlines stay on the glass (0.5.80).
    var hidesBuiltInCoreSurface = false {
        didSet {
            coreEffectView.isHidden = hidesBuiltInCoreSurface
            coreShadowLayer.isHidden = hidesBuiltInCoreSurface
            // The classic core's tall radial highlight reads as a vertical streak on glass (Ken, 2026-11-07).
            coreHighlightLayer.isHidden = hidesBuiltInCoreSurface
            ringFillLayer.isHidden = hidesBuiltInCoreSurface
            applyCoreFills()
        }
    }
    /// Liquid Glass: whether the skin's own core glass shows, (alpha, animated). The dial glass is hidden
    /// while aiming and in core-only mode; the core must stay glass then (0.5.70 fix).
    var externalCoreAlphaHandler: (@MainActor (CGFloat, Bool) -> Void)?
    /// Views owned by a skin that are part of the core and must take part in the centre snap.
    var externalCoreViews: [NSView] = []
    /// Return-to-centre snap: overshoot (0 = no snap) and duration. Liquid Glass tuning sets these.
    var snapAmplitude: CGFloat = 0.10
    var snapDuration: CFTimeInterval = 0.22
    /// Liquid Glass 「分割线」: opacity of the two grooves and the ring round the core (classic: 1).
    private var markScale: Float = 1
    var hidesBuiltInDialSurface = false {
        didSet {
            dialEffectView.isHidden = hidesBuiltInDialSurface
            fallbackDialLayer.isHidden = hidesBuiltInDialSurface
            dialSurfaceLightLayer.isHidden = hidesBuiltInDialSurface
            outerRimLayer.isHidden = hidesBuiltInDialSurface
            applyAppearanceTones()
        }
    }
    private let fallbackDialLayer = CAShapeLayer()
    private let defaultFrameLayer = CALayer()
    private let dialSurfaceLightLayer = CAGradientLayer()
    private let outerRimLayer = CAGradientLayer()
    private let grooveLayers = (0..<4).map { _ in CALayer() }

    private let sendGlowLayer = CALayer()
    private let undoGlowLayer = CALayer()
    private let sendIconLayer = CALayer()
    private let undoIconLayer = CALayer()

    private let coreGroup = CALayer()
    private let coreShadowLayer = CAShapeLayer()
    private let ringFillLayer = CAShapeLayer()
    private let ringBlackLayer = CAGradientLayer()
    private let ringWhiteLayer = CAGradientLayer()
    private let coreFillLayer = CAShapeLayer()
    private let coreBlackLayer = CAGradientLayer()
    private let coreWhiteLayer = CAGradientLayer()
    private let coreHighlightLayer = CAGradientLayer()
    private let waveformLayers = (0..<5).map { _ in CAShapeLayer() }
    private let resolvingRingLayer = CAShapeLayer()

    private let sendLabel = NSView(frame: .zero)
    private let undoLabel = NSView(frame: .zero)
    private let compactSendLabel = ArcTextLayer()
    private let compactUndoLabel = ArcTextLayer()
    private var compactPreviewLabels = false
    private var compactPreviewDark = false
    private var compactPreviewScale: CGFloat = 1
    private let centerHint = HUDGlassPillView(frame: .zero)
    private let errorLabel = HUDGlassPillView(frame: .zero)
    private let microphoneLevelMonitor: (any MicrophoneLevelMonitoring)?

    private var loadedAssetCount = 0
    private var reduceMotion = false
    private var displayedStatus: VoicePointerRuntimeStatus = .idle
    private var selectedAction: VoiceReleaseAction = .stop
    private var directionalActionsHidden = false
    private var radialChromeHidden = false
    private var feedbackMessage = ""
    private var lastAnnouncedFeedback: String?
    private(set) var feedbackAnnouncementCount = 0
    var feedbackFrame: CGRect { errorLabel.frame }
    private var waveformTimer: Timer?
    private var smoothedAudioLevel: CGFloat = 0
    private var audioLevelHistory = Array(repeating: CGFloat.zero, count: 5)

    init(
        frame frameRect: NSRect,
        microphoneLevelMonitor: (any MicrophoneLevelMonitoring)? = MicrophoneLevelMonitor()
    ) {
        self.microphoneLevelMonitor = microphoneLevelMonitor
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        configureGlass()
        configureDial()
        configureDirectionalAssets()
        configureCore()
        configureLabels()
        configureFunctionalFeedback()
        applyVisualState(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        allLayers.forEach { $0.contentsScale = scale }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configureMaterials()
        applyAppearanceTones()
    }

    /// Classic in dark mode (2026-11-07, Ken): the same glass stack on the dark material, without the white
    /// wash that used to keep it light grey everywhere. Only the built-in surface follows the appearance;
    /// a skin that brings its own dial surface (Liquid Glass) keeps the tones it was tuned with.
    private func applyAppearanceTones() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let dark = !hidesBuiltInDialSurface && isDark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackDialLayer.fillColor = (dark ? NSColor.black.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.26)).cgColor
        // The core's material view has its own uniform 0.5 pt white border (38 %). On the dark dial that was the
        // white circle around the centre (Ken, 2026-11-07); the groove hairlines already draw the edge there.
        coreEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.04 : 0.38).cgColor
        outerRimLayer.colors = [
            NSColor.white.withAlphaComponent(dark ? 0.12 : 0.60).cgColor,
            NSColor.white.withAlphaComponent(dark ? 0.02 : 0.05).cgColor,
            NSColor.white.withAlphaComponent(dark ? 0.05 : 0.14).cgColor,
        ]
        // The groove across the dial is cut into the glass: a shaded upper wall (dark hairline) over a lit
        // lower lip (light hairline), light from above. On a dark dial the light lip was a bright line
        // (Ken, 2026-11-07), so in dark the shade carries the groove and the lip is only a glint. Both skins.
        let glassGroove = glassGrooveColors(isDark: isDark)
        for (index, layer) in grooveLayers.enumerated() {
            if let glassGroove {
                layer.backgroundColor = index < 2 ? glassGroove.shade : glassGroove.lip
            } else {
                layer.backgroundColor = index < 2
                    ? NSColor.black.withAlphaComponent(isDark ? 0.26 : 0.10).cgColor
                    : NSColor.white.withAlphaComponent(isDark ? 0.05 : 0.22).cgColor
            }
        }
        coreHighlightLayer.colors = [
            NSColor.white.withAlphaComponent(dark ? 0.08 : 0.40).cgColor,
            NSColor.white.withAlphaComponent(dark ? 0.03 : 0.13).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        applyCoreFills()
        CATransaction.commit()
    }
    /// Liquid Glass: the grooves and the ring round the core, cut into the glass (shaded wall over a lit lip). On a
    /// plain page clear glass looks like the page itself, so these are all that show the core and the two halves;
    /// at the classic strengths they vanished there and the disc read as plain white (Ken, 2026-11-08), so glass
    /// draws them about three times stronger. nil: the classic dial's own tones.
    private func glassGrooveColors(isDark: Bool) -> (shade: CGColor, lip: CGColor)? {
        guard hidesBuiltInDialSurface else { return nil }
        // 2026-11-10 (Ken, after the grooves became 1 pt): light, the dark wall at 30 % was too black on 柔和 and 清透,
        // so it is half that now; dark, the cut was hard to see on 清透, so the lit lip is twice as bright.
        return (NSColor.black.withAlphaComponent(isDark ? 0.55 : 0.15).cgColor,
                NSColor.white.withAlphaComponent(isDark ? 0.32 : 0.75).cgColor)
    }

    /// Liquid Glass's tuned core brightness (nil: the classic fills).
    private var coreLookBrightness: CGFloat?

    /// How much lighter the core is than the dial. Light mode keeps the fills as they were. Dark mode
    /// (Ken, 2026-11-07): only 1-2 % lighter in both skins. White on a dark surface reads far stronger
    /// than on a light one, so the glass core's tuned brightness is scaled down; the classic core has its
    /// own material view, which already sits just above the darkened dial, so it gets almost no fill.
    private func applyCoreFills() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let core: NSColor
        if !hidesBuiltInDialSurface {
            // Measured on the dark preview: the bare core material is already ~1.3 % above the washed dial.
            core = isDark ? NSColor.white.withAlphaComponent(0.006)
                : NSColor.white.withAlphaComponent(hidesBuiltInCoreSurface ? 0.14 : 0.08)
        } else {
            let brightness = coreLookBrightness ?? (hidesBuiltInCoreSurface ? 0.14 : 0.08)
            core = NSColor.white.withAlphaComponent(isDark ? brightness * 0.15 : brightness)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coreFillLayer.fillColor = core.cgColor
        ringFillLayer.fillColor = (isDark ? NSColor.clear : NSColor.white.withAlphaComponent(0.08)).cgColor
        // The ring around the core is the same groove, bent into a circle: at the top the outer wall is in
        // shade and the inner lip catches the light, at the bottom the other way round. In dark the shade
        // carries it and the lit lip is only a glint, so it reads as a cut in the glass, not a drawn outline.
        let glassGroove = glassGrooveColors(isDark: isDark)
        let lip = glassGroove?.lip ?? NSColor.white.withAlphaComponent(isDark ? 0.05 : 0.32).cgColor
        let shade = glassGroove?.shade ?? NSColor.black.withAlphaComponent(isDark ? 0.26 : 0.10).cgColor
        let clearWhite = NSColor.white.withAlphaComponent(0).cgColor
        let clearBlack = NSColor.black.withAlphaComponent(0).cgColor
        ringBlackLayer.colors = [shade, clearBlack]
        ringWhiteLayer.colors = [clearWhite, lip]
        coreBlackLayer.colors = [clearBlack, shade]
        coreWhiteLayer.colors = [lip, clearWhite]
        CATransaction.commit()
    }

    func previewDiagnostics() -> String {
        "assets=\(loadedAssetCount)/5 action=\(selectedAction) " +
            "feedbackVisible=\(!errorLabel.isHidden) feedback=\(feedbackMessage) " +
            "preparingSpinner=\(!resolvingRingLayer.isHidden) " +
            "presentationAnimation=\(layer?.animation(forKey: "voicePointer.present") != nil)"
    }

    func setReduceMotion(_ enabled: Bool) {
        guard reduceMotion != enabled else { return }
        reduceMotion = enabled
        if enabled {
            stopAnimations()
            updateWaveforms()
        } else {
            restartStatusAnimations()
        }
    }

    func setStatus(_ status: VoicePointerRuntimeStatus) {
        displayedStatus = status
        if case .failed(let message) = status {
            if feedbackMessage != message {
                errorLabel.isHidden = true
                feedbackMessage = ""
                lastAnnouncedFeedback = nil
            }
        } else {
            clearFeedback()
        }
        if case .listening = status { centerHint.isHidden = true }

        switch status {
        case .idle:
            stopAnimations()
        case .resolvingTarget, .listening:
            restartStatusAnimations()
        case .failed(let message):
            stopAnimations()
            errorLabel.text = message
            errorLabel.isHidden = false
        }
        applyVisualState(animated: false)
    }

    func showMicrophoneNotice(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
    }

    /// Presents every completed operation in the same glass pill. The radial
    /// controls are hidden so the result cannot be mistaken for a new action.
    func showFeedback(message: String, kind: ComposerActionFeedback.Kind) {
        centerHint.isHidden = true
        radialChromeHidden = true
        errorLabel.text = message
        feedbackMessage = message
        errorLabel.maximumNumberOfLines = 2
        errorLabel.textFont = NSFont.systemFont(
            ofSize: 12, weight: errorLabel.usesSystemGlass ? LiquidGlassTuningStore.shared.value.toastFontWeight : .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: errorLabel.textFont]
        let measured = (message as NSString).boundingRect(
            with: CGSize(width: 216, height: 48),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let width = min(240, max(96, ceil(measured.width) + 24))
        let height = min(48, max(32, ceil(measured.height) + 16))
        errorLabel.frame = CGRect(
            x: 128 - width / 2,
            y: 88 - height / 2,
            width: width,
            height: height
        )
        errorLabel.setFallbackBackdrop(NSColor.black.withAlphaComponent(kind == .warning ? 0.68 : 0.58))
        errorLabel.isHidden = false
        errorLabel.setAccessibilityElement(true)
        errorLabel.setAccessibilityRole(.staticText)
        errorLabel.setAccessibilityValue(message)
        applyVisualState(animated: false)
        if lastAnnouncedFeedback != message {
            lastAnnouncedFeedback = message
            feedbackAnnouncementCount += 1
            NSAccessibility.post(
                element: errorLabel,
                notification: .announcementRequested,
                userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: message]
            )
        }
    }

    func clearFeedback() {
        feedbackMessage = ""
        lastAnnouncedFeedback = nil
        errorLabel.isHidden = true
    }

    func action(at point: CGPoint) -> VoiceReleaseAction {
        let dy = point.y - Geometry.anchor.y
        if dy > 0 { return .send }
        if dy < 0 { return .cancel }
        return .stop
    }

    func setAction(_ action: VoiceReleaseAction, animated: Bool) {
        let changed = action != selectedAction
        selectedAction = action
        applyVisualState(animated: animated && !reduceMotion)
        guard changed, animated, !reduceMotion else { return }

        guard action != .stop else {
            snapCore()
            return
        }
        let target = action == .send ? sendIconLayer : undoIconLayer
        let snap = CAKeyframeAnimation(keyPath: "transform.scale")
        snap.values = [0.88, 1.10, 1.0]
        snap.keyTimes = [0, 0.62, 1]
        snap.duration = 0.22
        snap.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        target.add(snap, forKey: "voicePointer.directionSnap")

        let travel = CABasicAnimation(keyPath: "transform.translation.y")
        travel.fromValue = action == .send ? -12 : 12
        travel.toValue = 0
        travel.duration = 0.22
        travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
        target.add(travel, forKey: "voicePointer.directionTravel")
    }

    /// The return-to-centre snap. The core is two pieces: the frosted material view and the layer
    /// group (ring, fill, highlight, rims, waveform). Both get the same keyframes about the same centre
    /// so the whole area scales together and no edge lags behind another (2026-11-07).
    private func snapCore() {
        let amplitude = min(max(snapAmplitude, 0), 0.3)
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
            snap.duration = min(max(snapDuration, 0.05), 1)
            snap.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            layer.add(snap, forKey: "voicePointer.directionSnap")
        }
        CATransaction.begin()
        add(to: coreGroup, centre: CGPoint(x: Geometry.coreFrame.midX, y: Geometry.coreFrame.midY))
        for view in [coreEffectView] + externalCoreViews where !view.isHidden {
            add(to: view.layer, centre: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        }
        CATransaction.commit()
    }

    /// Settings previews only: blur the preview's own page instead of whatever sits behind the settings window.
    /// On screen the disc floats over the app being typed in, so `.behindWindow` is right there; inside the settings
    /// window it showed the window behind it (Ken saw the classic core turn WeChat green while aiming, 2026-11-07).
    func useWithinWindowBlending() {
        dialEffectView.blendingMode = .withinWindow
        coreEffectView.blendingMode = .withinWindow
    }

    /// Puts back everything a skin may have changed on this radial (Liquid Glass hides the built-in dial and
    /// core, hooks its own glass in and applies its tuning). StatusHUD shares one radial between skins, so it
    /// calls this before the next skin takes over. 2026-11-07: without it the hidden core leaked into 经典 after
    /// switching from 液态玻璃, and only the waveform was left while aiming.
    func resetSkinCustomizations() {
        externalSurfaceAlphaHandler = nil
        externalCoreAlphaHandler = nil
        externalCoreViews = []
        hidesBuiltInDialSurface = false
        hidesBuiltInCoreSurface = false
        snapAmplitude = 0.10
        snapDuration = 0.22
        markScale = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grooveLayers.forEach { $0.opacity = 1 }
        shadowAmbientLayer.shadowOpacity = OuterShadowStyle.ambientOpacity
        shadowAmbientLayer.shadowRadius = OuterShadowStyle.ambientRadius
        shadowKeyLayer.shadowOpacity = OuterShadowStyle.keyOpacity
        shadowKeyLayer.shadowRadius = OuterShadowStyle.keyRadius
        shadowKeyLayer.shadowOffset = CGSize(width: 0, height: OuterShadowStyle.keyOffsetY)
        shadowAmbientLayer.shadowOffset = CGSize(width: 0, height: OuterShadowStyle.ambientOffsetY)
        shadowContactLayer.shadowOpacity = OuterShadowStyle.contactOpacity
        setShadowSilhouette(shadowAmbientLayer, inset: -OuterShadowStyle.ambientSpread)
        setShadowSilhouette(shadowKeyLayer, inset: -OuterShadowStyle.keySpread)
        CATransaction.commit()
        coreLookBrightness = nil
        applyCoreFills()
        applyVisualState(animated: false)
    }

    /// The disc a shadow layer casts from: the dial, pulled in by `inset` (the host masks everything inside the dial).
    private func setShadowSilhouette(_ layer: CAShapeLayer, inset: CGFloat) {
        let frame = Geometry.dialFrame
            .offsetBy(dx: RadialHUDMetrics.shadowPadding, dy: RadialHUDMetrics.shadowPadding)
            .insetBy(dx: inset, dy: inset)
        let path = CGPath(ellipseIn: frame, transform: nil)
        layer.path = path
        layer.shadowPath = path
    }

    /// Liquid Glass 「投影」 (2026-11-10, Ken: the soft glass's shadow was not clean). The classic shadow is mostly an
    /// almost centred halo, as heavy above the dial as beside it, which read as a grey smudge round the glass. Glass
    /// is lifted instead: both layers sit below the dial, a closer one that gives the edge its depth and a wide faint
    /// one under it, and next to nothing shows above the top edge. Strength multiplies the opacities, spread is the
    /// wide layer's blur (the close one follows at 42 %), drop is how far down the close one sits. No contact line:
    /// it hugs the glass's own bright edge and made it read as a thick white stroke (Ken, 2026-11-07).
    func applyOuterShadow(strength: CGFloat, spread: CGFloat, drop: CGFloat) {
        let opacity = Float(min(max(strength, 0), 2))
        let radius = min(max(spread, 0), 60)
        let down = min(max(drop, 0), 30)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowKeyLayer.shadowOpacity = 0.18 * opacity
        shadowKeyLayer.shadowRadius = radius * 0.42
        shadowKeyLayer.shadowOffset = CGSize(width: 0, height: -down)
        setShadowSilhouette(shadowKeyLayer, inset: 6)
        shadowAmbientLayer.shadowOpacity = 0.09 * opacity
        shadowAmbientLayer.shadowRadius = radius
        shadowAmbientLayer.shadowOffset = CGSize(width: 0, height: -down * 1.8)
        setShadowSilhouette(shadowAmbientLayer, inset: radius * 0.58)
        shadowContactLayer.shadowOpacity = 0
        CATransaction.commit()
    }

    /// 磨砂 (the classic dial) with its own 纹路 and 投影 numbers. At 100 % / 30 pt / 8 pt this is exactly the classic
    /// shadow: the halo, the key shadow at 40 % of the spread and the contact line.
    func applyClassicLook(lines: CGFloat, shadowStrength: CGFloat, spread: CGFloat, drop: CGFloat) {
        let opacity = Float(min(max(shadowStrength, 0), 2))
        let radius = min(max(spread, 0), 60)
        markScale = Float(min(max(lines, 0), 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grooveLayers.forEach { $0.opacity = markScale }
        shadowAmbientLayer.shadowOpacity = OuterShadowStyle.ambientOpacity * opacity
        shadowAmbientLayer.shadowRadius = radius
        shadowAmbientLayer.shadowOffset = CGSize(width: 0, height: OuterShadowStyle.ambientOffsetY)
        setShadowSilhouette(shadowAmbientLayer, inset: -OuterShadowStyle.ambientSpread)
        shadowKeyLayer.shadowOpacity = OuterShadowStyle.keyOpacity * opacity
        shadowKeyLayer.shadowRadius = radius * 0.4
        shadowKeyLayer.shadowOffset = CGSize(width: 0, height: -min(max(drop, 0), 30))
        setShadowSilhouette(shadowKeyLayer, inset: -OuterShadowStyle.keySpread)
        shadowContactLayer.shadowOpacity = OuterShadowStyle.contactOpacity * opacity
        CATransaction.commit()
        applyVisualState(animated: false)
    }

    /// Liquid Glass tuning: how much lighter the core is than the glass round it, and how strong the two grooves
    /// and the ring round the core are (「分割线」, 0 hides them).
    func applyGlassMarks(coreBrightness: CGFloat, lines: CGFloat) {
        coreLookBrightness = min(max(coreBrightness, 0), 1)
        markScale = Float(min(max(lines, 0), 1))
        applyCoreFills()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grooveLayers.forEach { $0.opacity = markScale }
        CATransaction.commit()
        applyVisualState(animated: false)
    }

    func animatePresentation() {
        // The original artwork appears at full opacity/size on the first
        // frame. No additional 150 ms scale/fade after focus acquisition.
        layer?.removeAnimation(forKey: "voicePointer.present")
    }

    func commit(_ action: VoiceReleaseAction) {
        setAction(action, animated: !reduceMotion)
        guard !reduceMotion else { return }
        let target = switch action {
        case .stop: coreGroup
        case .send: sendIconLayer
        case .cancel: undoIconLayer
        }
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [1.0, 0.50, 1.0]
        flash.keyTimes = [0, 0.44, 1]
        flash.duration = 0.20
        target.add(flash, forKey: "voicePointer.commit")

        if action != .stop {
            let lift = CABasicAnimation(keyPath: "transform.translation.y")
            lift.fromValue = 0
            lift.toValue = action == .send ? 10 : -8
            lift.duration = 0.18
            lift.timingFunction = CAMediaTimingFunction(name: .easeOut)
            target.add(lift, forKey: "voicePointer.commitTravel")
        }
    }

    func rebound() {
        guard !reduceMotion, let root = overlay.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, 5, -3, 0]
        bounce.keyTimes = [0, 0.34, 0.72, 1]
        bounce.duration = 0.24
        bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.add(bounce, forKey: "voicePointer.boundary")
    }

    func stopAnimations() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        smoothedAudioLevel = 0
        audioLevelHistory = Array(repeating: 0, count: 5)
        resolvingRingLayer.removeAllAnimations()
        allLayers.forEach { $0.removeAllAnimations() }
        layer?.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Hides the radial control while keeping a small failure pill above the
    /// pointer. The previous full-size error dial was too obstructive.
    func setRadialChromeHidden(_ hidden: Bool) {
        radialChromeHidden = hidden
        applyVisualState(animated: false)
    }

    func setDirectionalActionsHidden(_ hidden: Bool) {
        directionalActionsHidden = hidden
        applyVisualState(animated: false)
    }

    func setCenterHint(_ value: String) {
        if value.hasPrefix("松手") || value == "再按停止" {
            centerHint.isHidden = true
            return
        }
        centerHint.text = value
        centerHint.isHidden = value.isEmpty
    }

    private var allLayers: [CALayer] {
        [
            shadowAmbientLayer, shadowKeyLayer, shadowContactLayer, shadowOutsideMaskLayer,
            dialGroup, fallbackDialLayer, defaultFrameLayer, dialSurfaceLightLayer, outerRimLayer,
            sendGlowLayer, undoGlowLayer, sendIconLayer,
            undoIconLayer, coreGroup, coreShadowLayer, ringFillLayer,
            ringBlackLayer, ringWhiteLayer, coreFillLayer, coreBlackLayer,
            coreWhiteLayer, coreHighlightLayer, resolvingRingLayer,
        ] + grooveLayers + waveformLayers
    }

    private func configureGlass() {
        configureMaterials()
        configureOuterShadow()
        for (effect, frame, radius) in [
            (dialEffectView, Geometry.dialFrame, CGFloat(100)),
            (coreEffectView, Geometry.coreFrame, CGFloat(40)),
        ] {
            effect.frame = frame
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
            effect.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
            effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.38).cgColor
            effect.layer?.borderWidth = 0.5
            addSubview(effect)
        }
        // The dial uses a controlled directional rim instead of the visual
        // effect view's uniform native border.
        dialEffectView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        dialEffectView.layer?.borderWidth = 0

        overlay.wantsLayer = true
        overlay.layer = CALayer()
        overlay.layer?.masksToBounds = false
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    /// The glass remains translucent, so a conventional filled-layer shadow
    /// placed behind it would bleed through and gray the entire dial. This
    /// host masks out the complete dial interior after rendering two physical
    /// shadow components, leaving only pixels outside the glass silhouette.
    private func configureOuterShadow() {
        shadowHostView.wantsLayer = true
        shadowHostView.layer = CALayer()
        shadowHostView.layer?.masksToBounds = false

        guard let host = shadowHostView.layer else { return }
        let dialFrameInHost = Geometry.dialFrame.offsetBy(
            dx: RadialHUDMetrics.shadowPadding,
            dy: RadialHUDMetrics.shadowPadding
        )
        let silhouette = CGPath(ellipseIn: dialFrameInHost, transform: nil)
        let ambientFrame = dialFrameInHost.insetBy(
            dx: -OuterShadowStyle.ambientSpread,
            dy: -OuterShadowStyle.ambientSpread
        )
        let ambientSilhouette = CGPath(ellipseIn: ambientFrame, transform: nil)

        shadowAmbientLayer.frame = host.bounds
        shadowAmbientLayer.path = ambientSilhouette
        shadowAmbientLayer.fillColor = NSColor.black.cgColor
        shadowAmbientLayer.shadowPath = ambientSilhouette
        shadowAmbientLayer.shadowColor = NSColor.black.cgColor
        host.addSublayer(shadowAmbientLayer)

        let keyFrame = dialFrameInHost.insetBy(
            dx: -OuterShadowStyle.keySpread,
            dy: -OuterShadowStyle.keySpread
        )
        let keySilhouette = CGPath(ellipseIn: keyFrame, transform: nil)
        shadowKeyLayer.frame = host.bounds
        shadowKeyLayer.path = keySilhouette
        shadowKeyLayer.fillColor = NSColor.black.cgColor
        shadowKeyLayer.shadowPath = keySilhouette
        shadowKeyLayer.shadowColor = NSColor.black.cgColor
        shadowKeyLayer.shadowOpacity = OuterShadowStyle.keyOpacity
        shadowKeyLayer.shadowRadius = OuterShadowStyle.keyRadius
        shadowKeyLayer.shadowOffset = CGSize(width: 0, height: OuterShadowStyle.keyOffsetY)
        host.addSublayer(shadowKeyLayer)

        shadowContactLayer.frame = host.bounds
        shadowContactLayer.path = silhouette
        shadowContactLayer.fillColor = NSColor.black.cgColor
        shadowContactLayer.shadowPath = silhouette
        shadowContactLayer.shadowColor = NSColor.black.cgColor
        host.addSublayer(shadowContactLayer)

        shadowAmbientLayer.shadowOpacity = OuterShadowStyle.ambientOpacity
        shadowAmbientLayer.shadowRadius = OuterShadowStyle.ambientRadius
        shadowAmbientLayer.shadowOffset = CGSize(width: 0, height: OuterShadowStyle.ambientOffsetY)

        shadowContactLayer.shadowOpacity = OuterShadowStyle.contactOpacity
        shadowContactLayer.shadowRadius = OuterShadowStyle.contactRadius
        shadowContactLayer.shadowOffset = CGSize(width: 0, height: OuterShadowStyle.contactOffsetY)

        let outsidePath = CGMutablePath()
        outsidePath.addRect(host.bounds)
        outsidePath.addEllipse(in: dialFrameInHost.insetBy(dx: -0.5, dy: -0.5))
        shadowOutsideMaskLayer.frame = host.bounds
        shadowOutsideMaskLayer.path = outsidePath
        shadowOutsideMaskLayer.fillRule = .evenOdd
        shadowOutsideMaskLayer.fillColor = NSColor.black.cgColor
        shadowOutsideMaskLayer.allowsEdgeAntialiasing = true
        host.mask = shadowOutsideMaskLayer

        addSubview(shadowHostView)
    }

    private func configureMaterials() {
        let material: NSVisualEffectView.Material = NSWorkspace.shared
            .accessibilityDisplayShouldReduceTransparency ? .menu : .popover
        dialEffectView.material = material
        coreEffectView.material = material
    }

    private func configureDial() {
        guard let root = overlay.layer else { return }
        dialGroup.frame = root.bounds
        root.addSublayer(dialGroup)

        fallbackDialLayer.frame = dialGroup.bounds
        fallbackDialLayer.path = CGPath(ellipseIn: Geometry.dialFrame, transform: nil)
        // A little white above the material keeps the glass a clean light grey over dark
        // pages instead of a muddy mid grey (the classic dial is the white version everywhere).
        fallbackDialLayer.fillColor = NSColor.white.withAlphaComponent(0.26).cgColor
        fallbackDialLayer.shadowOpacity = 0
        dialGroup.addSublayer(fallbackDialLayer)

        let hasDefaultAsset = configureAsset(
            defaultFrameLayer,
            fileName: "dial-default@2x.png",
            frame: Geometry.defaultAssetFrame
        )
        if hasDefaultAsset { loadedAssetCount += 1 }
        fallbackDialLayer.isHidden = false
        // The raster asset is retained for packaging compatibility and state
        // diagnostics, but no longer participates in the neutral glass stack.
        defaultFrameLayer.opacity = 0
        dialGroup.addSublayer(defaultFrameLayer)

        configureSurfaceLight(dialSurfaceLightLayer, frame: Geometry.dialFrame)
        dialGroup.addSublayer(dialSurfaceLightLayer)

        configureOuterRim()
        dialGroup.addSublayer(outerRimLayer)

        // 2026-11-10 (Ken: the ring round the core looked about twice as heavy as the two lines): the grooves and
        // the ring are one cut now, a 1 pt shaded wall over a 0.5 pt lit lip, 1.5 pt in all. The grooves used to be
        // 0.5 + 0.5 pt, the ring two 0.65 pt strokes 1 pt apart.
        let grooveFrames = [
            CGRect(x: 28, y: 131.5, width: 59, height: 1),
            CGRect(x: 169, y: 131.5, width: 59, height: 1),
            CGRect(x: 28, y: 131, width: 59, height: 0.5),
            CGRect(x: 169, y: 131, width: 59, height: 0.5),
        ]
        for (index, layer) in grooveLayers.enumerated() {
            layer.frame = grooveFrames[index]
            layer.backgroundColor = index < 2
                ? NSColor.black.withAlphaComponent(0.10).cgColor
                : NSColor.white.withAlphaComponent(0.22).cgColor
            dialGroup.addSublayer(layer)
        }
    }

    /// One fixed top-left light model replaces the previous independent white
    /// and black radial overlays, which accumulated into a muddy gray surface.
    private func configureSurfaceLight(_ layer: CAGradientLayer, frame: CGRect) {
        layer.frame = frame
        layer.type = .axial
        layer.startPoint = CGPoint(x: 0.32, y: 1)
        layer.endPoint = CGPoint(x: 0.68, y: 0)
        layer.colors = [
            NSColor(
                srgbRed: 0.98,
                green: 0.95,
                blue: 0.91,
                alpha: 0.16
            ).cgColor,
            NSColor.white.withAlphaComponent(0.045).cgColor,
            NSColor(
                srgbRed: 0.72,
                green: 0.82,
                blue: 0.86,
                alpha: 0.055
            ).cgColor,
        ]
        layer.locations = [0, 0.58, 1]
        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        mask.path = CGPath(ellipseIn: layer.bounds, transform: nil)
        layer.mask = mask
    }

    private func configureOuterRim() {
        outerRimLayer.frame = Geometry.dialFrame
        outerRimLayer.type = .axial
        outerRimLayer.startPoint = CGPoint(x: 0.5, y: 1)
        outerRimLayer.endPoint = CGPoint(x: 0.5, y: 0)
        // Top edge catches the light (the thin white line along the top of the glass),
        // the bottom inner edge keeps a faint refracted glow.
        outerRimLayer.colors = [
            NSColor.white.withAlphaComponent(0.60).cgColor,
            NSColor.white.withAlphaComponent(0.05).cgColor,
            NSColor.white.withAlphaComponent(0.14).cgColor,
        ]
        outerRimLayer.locations = [0, 0.50, 1]

        let mask = CAShapeLayer()
        mask.frame = outerRimLayer.bounds
        mask.path = CGPath(
            ellipseIn: outerRimLayer.bounds.insetBy(dx: 0.75, dy: 0.75),
            transform: nil
        )
        mask.fillColor = NSColor.clear.cgColor
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = 0.75
        mask.allowsEdgeAntialiasing = true
        outerRimLayer.mask = mask
    }

    private func configureDirectionalAssets() {
        guard let root = overlay.layer else { return }
        if configureAsset(sendGlowLayer, fileName: "glow-send@2x.png", frame: Geometry.sendGlowFrame) {
            loadedAssetCount += 1
        }
        if configureAsset(undoGlowLayer, fileName: "glow-undo@2x.png", frame: Geometry.undoGlowFrame) {
            loadedAssetCount += 1
        }
        root.addSublayer(sendGlowLayer)
        root.addSublayer(undoGlowLayer)

        if configureAsset(sendIconLayer, fileName: "icon-send@2x.png", frame: Geometry.sendIconFrame) {
            loadedAssetCount += 1
        }
        if configureAsset(undoIconLayer, fileName: "icon-undo@2x.png", frame: Geometry.undoIconFrame) {
            loadedAssetCount += 1
        }
        root.addSublayer(sendIconLayer)
        root.addSublayer(undoIconLayer)
    }

    private func configureCore() {
        guard let root = overlay.layer else { return }
        coreGroup.frame = root.bounds
        root.addSublayer(coreGroup)

        coreShadowLayer.frame = coreGroup.bounds
        coreShadowLayer.path = CGPath(ellipseIn: Geometry.coreFrame, transform: nil)
        coreShadowLayer.fillColor = Palette.surface.cgColor
        coreShadowLayer.shadowColor = NSColor.black.cgColor
        coreShadowLayer.shadowOpacity = 0.16
        coreShadowLayer.shadowRadius = 12
        coreShadowLayer.shadowOffset = CGSize(width: 0, height: -8)
        coreShadowLayer.isHidden = true
        coreGroup.addSublayer(coreShadowLayer)

        ringFillLayer.frame = coreGroup.bounds
        ringFillLayer.path = CGPath(ellipseIn: Geometry.ringFrame, transform: nil)
        ringFillLayer.fillColor = NSColor.white.withAlphaComponent(0.08).cgColor
        coreGroup.addSublayer(ringFillLayer)

        // The ring is the groove bent into a circle, on the band between radius 39.5 and 41. Upper half: the
        // shaded wall outside (40...41) over the lit lip inside (39.5...40). Lower half the other way round:
        // the wall inside (39.5...40.5), the lip outside (40.5...41). Each fades out toward the other half.
        configureBorderGradient(
            ringBlackLayer,
            frame: Geometry.ringFrame,
            top: NSColor.black.withAlphaComponent(0.10),
            bottom: NSColor.black.withAlphaComponent(0),
            lineWidth: 1,
            inset: 0.5
        )
        configureBorderGradient(
            ringWhiteLayer,
            frame: Geometry.ringFrame,
            top: NSColor.white.withAlphaComponent(0),
            bottom: NSColor.white.withAlphaComponent(0.32),
            lineWidth: 0.5,
            inset: 0.25
        )
        coreGroup.addSublayer(ringBlackLayer)
        coreGroup.addSublayer(ringWhiteLayer)

        coreFillLayer.frame = coreGroup.bounds
        coreFillLayer.path = CGPath(ellipseIn: Geometry.coreFrame, transform: nil)
        coreFillLayer.fillColor = NSColor.white.withAlphaComponent(0.08).cgColor
        coreFillLayer.shadowPath = CGPath(ellipseIn: Geometry.coreFrame, transform: nil)
        coreFillLayer.shadowColor = NSColor.black.cgColor
        coreFillLayer.shadowRadius = 12
        coreFillLayer.shadowOffset = CGSize(width: 0, height: -8)
        coreFillLayer.shadowOpacity = 0
        coreGroup.addSublayer(coreFillLayer)

        configureBorderGradient(
            coreBlackLayer,
            frame: Geometry.ringFrame,
            top: NSColor.black.withAlphaComponent(0),
            bottom: NSColor.black.withAlphaComponent(0.10),
            lineWidth: 1,
            inset: 1
        )
        configureBorderGradient(
            coreWhiteLayer,
            frame: Geometry.ringFrame,
            top: NSColor.white.withAlphaComponent(0.32),
            bottom: NSColor.white.withAlphaComponent(0),
            lineWidth: 0.5,
            inset: 1.25
        )
        coreGroup.addSublayer(coreBlackLayer)
        coreGroup.addSublayer(coreWhiteLayer)

        coreHighlightLayer.frame = Geometry.coreFrame
        coreHighlightLayer.type = .radial
        coreHighlightLayer.colors = [
            NSColor.white.withAlphaComponent(0.40).cgColor,
            NSColor.white.withAlphaComponent(0.13).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        coreHighlightLayer.locations = [0, 0.56, 1]
        coreHighlightLayer.startPoint = CGPoint(x: 0.42, y: 0.62)
        coreHighlightLayer.endPoint = CGPoint(x: 0.5, y: 1)
        let highlightMask = CAShapeLayer()
        highlightMask.frame = coreHighlightLayer.bounds
        highlightMask.path = CGPath(ellipseIn: highlightMask.bounds, transform: nil)
        coreHighlightLayer.mask = highlightMask
        coreGroup.addSublayer(coreHighlightLayer)

        for layer in waveformLayers {
            layer.frame = coreGroup.bounds
            layer.fillColor = Palette.waveform.cgColor
            layer.shadowColor = Palette.waveform.cgColor
            layer.shadowOpacity = 0.16
            layer.shadowRadius = 2
            coreGroup.addSublayer(layer)
        }
        updateWaveforms()

        resolvingRingLayer.frame = coreGroup.bounds
        resolvingRingLayer.path = CGPath(
            ellipseIn: Geometry.ringFrame.insetBy(dx: -5, dy: -5),
            transform: nil
        )
        resolvingRingLayer.fillColor = NSColor.clear.cgColor
        resolvingRingLayer.strokeColor = Palette.waveform.withAlphaComponent(0.70).cgColor
        resolvingRingLayer.lineWidth = 2
        resolvingRingLayer.lineDashPattern = [4, 7]
        resolvingRingLayer.isHidden = true
        coreGroup.addSublayer(resolvingRingLayer)
    }

    private func configureBorderGradient(
        _ layer: CAGradientLayer,
        frame: CGRect,
        top: NSColor,
        bottom: NSColor,
        lineWidth: CGFloat = 1,
        inset: CGFloat = 0.5
    ) {
        layer.frame = frame
        layer.type = .axial
        layer.startPoint = CGPoint(x: 0.5, y: 1)
        layer.endPoint = CGPoint(x: 0.5, y: 0)
        layer.colors = [top.cgColor, bottom.cgColor]
        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        mask.path = CGPath(ellipseIn: layer.bounds.insetBy(dx: inset, dy: inset), transform: nil)
        mask.fillColor = NSColor.clear.cgColor
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = lineWidth
        layer.mask = mask
    }

    private func configureLabels() {
        configureArcLabel(sendLabel, text: "Send", placement: .top)
        configureArcLabel(undoLabel, text: "Cancel", placement: .bottom)
        compactSendLabel.frame = overlay.bounds
        compactUndoLabel.frame = overlay.bounds
        compactSendLabel.isHidden = true
        compactUndoLabel.isHidden = true
        overlay.layer?.addSublayer(compactSendLabel)
        overlay.layer?.addSublayer(compactUndoLabel)

        centerHint.frame = CGRect(x: 78, y: 76, width: 100, height: 24)
        centerHint.isHidden = true
        overlay.addSubview(centerHint)
    }

    /// Small settings thumbnails use layer text so AppKit glyph views do not
    /// lose strokes when the complete HUD is scaled down. The live HUD keeps
    /// its original labels unchanged.
    func setCompactPreviewLabels(_ enabled: Bool, dark: Bool, scaleFactor: CGFloat) {
        guard compactPreviewLabels != enabled || compactPreviewDark != dark
                || compactPreviewScale != scaleFactor else { return }
        compactPreviewLabels = enabled
        compactPreviewDark = dark
        compactPreviewScale = scaleFactor
        sendLabel.isHidden = enabled
        undoLabel.isHidden = enabled
        if enabled {
            let color = dark
                ? NSColor.white.withAlphaComponent(0.66).cgColor
                : NSColor.black.withAlphaComponent(0.36).cgColor
            let font = NSFont.systemFont(ofSize: 13)
            let scale = (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
                / max(scaleFactor, 0.25)
            compactSendLabel.configure(text: "Send", font: font, color: color, kern: 0.3,
                                       radius: 68, placement: .top, center: CGPoint(x: 128, y: 132), scale: scale)
            compactUndoLabel.configure(text: "Cancel", font: font, color: color, kern: 0.3,
                                       radius: 68, placement: .bottom, center: CGPoint(x: 128, y: 132), scale: scale)
        }
        compactSendLabel.isHidden = !enabled
        compactUndoLabel.isHidden = !enabled
        applyVisualState(animated: false)
    }

    private enum ArcPlacement { case top, bottom }

    private func configureArcLabel(_ container: NSView, text: String, placement: ArcPlacement) {
        container.frame = overlay.bounds
        container.wantsLayer = true
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let tracking: CGFloat = 0.3
        let glyphs = text.map { character -> (NSView, CGFloat) in
            let value = String(character)
            let width = ceil((String(character) as NSString).size(
                withAttributes: [.font: font]
            ).width)
            let size = CGSize(
                width: max(width + tracking + 8, 12),
                height: ceil(font.ascender - font.descender + font.leading) + 4
            )
            let glyph = NSView(frame: CGRect(origin: .zero, size: size))
            glyph.wantsLayer = true

            @MainActor
            func makeLabel(color: NSColor, verticalOffset: CGFloat) -> NSTextField {
                let label = NSTextField(labelWithString: value)
                label.font = font
                label.textColor = color
                label.alignment = .center
                label.frame = glyph.bounds.offsetBy(dx: 0, dy: verticalOffset)
                return label
            }

            // A recessed mark under fixed top lighting has a dark inner edge
            // above the face and a one-pixel highlight below it.
            // Finer than before: a lighter face needs a softer edge and highlight,
            // otherwise the highlight reads as a second white copy on grey glass.
            glyph.addSubview(makeLabel(color: Palette.labelEdge, verticalOffset: 0.5))
            glyph.addSubview(makeLabel(color: Palette.labelHighlight, verticalOffset: -0.8))
            glyph.addSubview(makeLabel(color: Palette.label, verticalOffset: 0))
            return (glyph, width + tracking)
        }
        let totalAdvance = max(0, glyphs.reduce(0) { $0 + $1.1 } - tracking)
        var cursor = -totalAdvance / 2
        for (glyph, advance) in glyphs {
            let glyphCenter = cursor + (advance - tracking) / 2
            let angle: CGFloat
            let rotation: CGFloat
            switch placement {
            case .top:
                angle = .pi / 2 - glyphCenter / Geometry.arcLabelRadius
                rotation = angle - .pi / 2
            case .bottom:
                angle = -.pi / 2 + glyphCenter / Geometry.arcLabelRadius
                rotation = angle + .pi / 2
            }
            let center = CGPoint(
                x: Geometry.anchor.x + cos(angle) * Geometry.arcLabelRadius,
                y: Geometry.anchor.y + sin(angle) * Geometry.arcLabelRadius
            )
            glyph.frame = CGRect(
                x: center.x - glyph.bounds.width / 2,
                y: center.y - glyph.bounds.height / 2,
                width: glyph.bounds.width,
                height: glyph.bounds.height
            )
            glyph.frameCenterRotation = rotation * 180 / .pi
            container.addSubview(glyph)
            cursor += advance
        }
        overlay.addSubview(container)
    }

    private func configureFunctionalFeedback() {
        errorLabel.frame = CGRect(x: 38, y: 172, width: 180, height: 38)
        errorLabel.maximumNumberOfLines = 2
        errorLabel.setFallbackBackdrop(NSColor.black.withAlphaComponent(0.62))
        errorLabel.isHidden = true
        errorLabel.setAccessibilityElement(true)
        errorLabel.setAccessibilityRole(.staticText)
        overlay.addSubview(errorLabel)
    }

    private func configureAsset(_ layer: CALayer, fileName: String, frame: CGRect) -> Bool {
        layer.frame = frame
        layer.contentsGravity = .resizeAspect
        layer.minificationFilter = .linear
        layer.magnificationFilter = .linear
        guard let image = Self.assetImage(named: fileName) else { return false }
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return false
        }
        layer.contents = cgImage
        layer.contentsScale = 2
        return true
    }

    private static func assetImage(named fileName: String) -> NSImage? {
        let fileManager = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?
                .appendingPathComponent("HUD", isDirectory: true)
                .appendingPathComponent(fileName),
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources/HUD", isDirectory: true)
                .appendingPathComponent(fileName),
        ]
        for candidate in candidates.compactMap({ $0 }) where fileManager.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) { return image }
        }
        return nil
    }

    private func applyVisualState(animated: Bool) {
        let chromeVisible = !radialChromeHidden
        let dialVisible = chromeVisible && selectedAction == .stop && !directionalActionsHidden
        let sendVisible = chromeVisible && selectedAction == .send && !directionalActionsHidden
        let undoVisible = chromeVisible && selectedAction == .cancel && !directionalActionsHidden

        setOpacity(dialGroup, to: dialVisible ? 1 : 0, animated: animated, key: "dial")
        setOpacity(sendGlowLayer, to: sendVisible ? 1 : 0, animated: animated, key: "sendGlow")
        setOpacity(undoGlowLayer, to: undoVisible ? 1 : 0, animated: animated, key: "undoGlow")
        setOpacity(sendIconLayer, to: sendVisible ? 1 : 0, animated: animated, key: "sendIcon")
        setOpacity(undoIconLayer, to: undoVisible ? 1 : 0, animated: animated, key: "undoIcon")
        setOpacity(coreGroup, to: chromeVisible ? 1 : 0, animated: animated, key: "core")

        let active = selectedAction != .stop
        coreShadowLayer.opacity = 0
        coreFillLayer.shadowOpacity = 0
        coreFillLayer.opacity = active ? 0.25 : 1
        coreHighlightLayer.opacity = active ? 0.35 : 1
        ringFillLayer.opacity = active ? 0 : 1
        ringBlackLayer.opacity = active ? 0 : markScale
        ringWhiteLayer.opacity = active ? 0 : markScale
        coreBlackLayer.opacity = active ? 0 : markScale
        coreWhiteLayer.opacity = active ? 0 : markScale

        let dialAlpha: CGFloat = dialVisible ? 1 : 0
        externalSurfaceAlphaHandler?(dialAlpha, animated)
        externalCoreAlphaHandler?(chromeVisible && !dialVisible ? 1 : 0, animated)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shadowHostView.animator().alphaValue = dialAlpha
                dialEffectView.animator().alphaValue = dialAlpha
            }
        } else {
            shadowHostView.alphaValue = dialAlpha
            dialEffectView.alphaValue = dialAlpha
        }
        coreEffectView.alphaValue = chromeVisible ? 1.0 : 0
        coreEffectView.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(active ? 0.12 : 0.11)
            .cgColor
        sendLabel.alphaValue = dialVisible ? 1 : 0
        undoLabel.alphaValue = dialVisible ? 1 : 0
        compactSendLabel.isHidden = !compactPreviewLabels || !dialVisible
        compactUndoLabel.isHidden = !compactPreviewLabels || !dialVisible
        waveformLayers.forEach { $0.isHidden = !chromeVisible }
        if radialChromeHidden { centerHint.isHidden = true }
    }

    private func setOpacity(
        _ layer: CALayer,
        to value: Float,
        animated: Bool,
        key: String
    ) {
        let previous = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = value
        CATransaction.commit()
        guard animated, previous != value else { return }
        let transition = CABasicAnimation(keyPath: "opacity")
        transition.fromValue = previous
        transition.toValue = value
        transition.duration = 0.22
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transition, forKey: "voicePointer.\(key)")
    }

    private func restartStatusAnimations() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        resolvingRingLayer.removeAllAnimations()
        resolvingRingLayer.isHidden = true

        switch displayedStatus {
        case .resolvingTarget:
            smoothedAudioLevel = 0
            audioLevelHistory = Array(repeating: 0, count: 5)
            updateWaveforms()
        case .listening:
            guard !reduceMotion else { return }
            smoothedAudioLevel = 0
            audioLevelHistory = Array(repeating: 0, count: 5)
            waveformTimer = scheduleMainActorTimer(
                every: 1.0 / 45.0,
                mode: .common
            ) { [weak self] in
                self?.waveformTick()
            }
        case .idle, .failed:
            break
        }
    }

    private func waveformTick() {
        // displayLevel is already perceptual (0...1) and follows this speaker's own range.
        let responsiveLevel = CGFloat(microphoneLevelMonitor?.displayLevel ?? 0)
        let coefficient: CGFloat = responsiveLevel > smoothedAudioLevel ? 0.62 : 0.20
        smoothedAudioLevel += (responsiveLevel - smoothedAudioLevel) * coefficient
        audioLevelHistory.removeLast()
        audioLevelHistory.insert(smoothedAudioLevel, at: 0)
        updateWaveforms()
    }

    /// Maps real microphone amplitude into a perceptual display range. Raw
    /// speech levels spend most of their time near zero, so a dB curve keeps
    /// quiet rooms still while making normal speech visibly responsive.
    static func normalizedAudioLevel(_ measured: CGFloat) -> CGFloat {
        guard measured > 0 else { return 0 }
        let decibels = 20 * log10(max(measured, 0.000_1))
        let normalized = min(max((decibels + 36) / 30, 0), 1)
        return pow(normalized, 0.90)
    }

    private func updateWaveforms() {
        // Paired bars share the same visual envelope. Different history
        // offsets preserve a small temporal stagger without making one side
        // permanently shorter than the other.
        let minimumHeights: [CGFloat] = [4, 6.5, 10, 6.5, 4]
        let response: [CGFloat] = [0.30, 0.65, 1.0, 0.65, 0.30]
        let responsePowers: [CGFloat] = [1.25, 0.97, 0.68, 0.97, 1.25]
        let historyOffsets = [4, 2, 0, 1, 3]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in waveformLayers.enumerated() {
            let height: CGFloat
            if waveformTimer == nil || reduceMotion {
                height = minimumHeights[index]
            } else {
                let level = pow(
                    audioLevelHistory[historyOffsets[index]],
                    responsePowers[index]
                )
                height = min(35, minimumHeights[index] + level * 25 * response[index])
            }
            let rect = CGRect(
                x: Geometry.waveformOrigin.x + CGFloat(index) * 6,
                y: Geometry.anchor.y - height / 2,
                width: 3,
                height: height
            )
            let path = CGMutablePath()
            path.addRoundedRect(in: rect, cornerWidth: 1.5, cornerHeight: 1.5)
            layer.path = path
        }
        CATransaction.commit()
    }
}
