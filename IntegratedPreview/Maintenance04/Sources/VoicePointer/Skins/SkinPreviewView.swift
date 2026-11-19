import AppKit
import QuartzCore
import VoicePointerCore

@MainActor
struct SkinPreviewAssembly {
    let skin: any HUDSkin
    let radial: RadialHUDView?
    let syntheticMonitor: PreviewMicrophoneLevelMonitor?
    let shutdown: @MainActor () -> Void
}

@MainActor
final class PreviewMicrophoneLevelMonitor: MicrophoneLevelMonitoring {
    var level: Float = 0
    private(set) var isRunning = false
    var hasStartIntent: Bool { isRunning }

    func start() { isRunning = true }
    func stop() {
        isRunning = false
        level = 0
    }
}

@MainActor
enum SkinPreviewFactory {
    /// A skin drawn inside the settings window (stage, cards): its frosted parts blur the preview page.
    static func make(_ id: HUDSkinID) -> SkinPreviewAssembly { make(id, onScreen: false) }

    /// A skin in its own floating panel (「在屏幕上试一下」, the Toast trial): blurs what is behind it on screen.
    static func makeOnScreen(_ id: HUDSkinID) -> SkinPreviewAssembly { make(id, onScreen: true) }

    private static func make(_ id: HUDSkinID, onScreen: Bool) -> SkinPreviewAssembly {
        switch id {
        case .frosted:
            return assembly(FrostedSkin())
        case .miniDisc:
            return assembly(MiniDiscSkin())
        case .miniMorph:
            return assembly(MiniDiscSkin(morphs: true))
        case .classic:
            let (radial, monitor) = makeRadial(onScreen: onScreen)
            return assembly(ClassicSkin(radial: radial), radial: radial, monitor: monitor)
        case .liquidGlass:
            let (radial, monitor) = makeRadial(onScreen: onScreen)
            return assembly(LiquidGlassSkin(radial: radial), radial: radial, monitor: monitor)
        default:
            if let shader = ShaderSkin(id: id) { return assembly(shader) }
            let (radial, monitor) = makeRadial(onScreen: onScreen)
            return assembly(ClassicSkin(radial: radial), radial: radial, monitor: monitor)
        }
    }

    static func environment(isDark: Bool) -> HUDEnvironment {
        HUDEnvironment(
            isDark: isDark,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }

    private static func makeRadial(onScreen: Bool) -> (RadialHUDView, PreviewMicrophoneLevelMonitor) {
        let monitor = PreviewMicrophoneLevelMonitor()
        let radial = RadialHUDView(
            frame: NSRect(origin: RadialHUDMetrics.logicalOrigin, size: RadialHUDMetrics.logicalSize),
            microphoneLevelMonitor: monitor
        )
        if !onScreen { radial.useWithinWindowBlending() }
        return (radial, monitor)
    }

    private static func assembly(
        _ skin: any HUDSkin,
        radial: RadialHUDView? = nil,
        monitor: PreviewMicrophoneLevelMonitor? = nil
    ) -> SkinPreviewAssembly {
        SkinPreviewAssembly(skin: skin, radial: radial, syntheticMonitor: monitor) {
            monitor?.stop()
            radial?.stopAnimations()
            removeAnimations(in: skin.view)
            (skin as? ShaderSkin)?.stopRendering()
        }
    }

    private static func removeAnimations(in view: NSView) {
        view.layer?.removeAllAnimations()
        for subview in view.subviews { removeAnimations(in: subview) }
    }
}

/// Hosts the product HUDSkin classes over a quiet document, using only synthetic audio and pointer input.
@MainActor
final class SkinPreviewView: NSView {
    enum Motion { case idle, demo }

    private let paper: PreviewPaperView
    private let scaler = NSView()
    private var assembly: SkinPreviewAssembly?
    private var skin: (any HUDSkin)? { assembly?.skin }
    private var skinID: HUDSkinID?
    private var requestedSkin: HUDSkinID?
    private var environment = HUDEnvironment()
    private var timer: Timer?
    /// Running right now: the page wants the preview and a person can see it.
    private var previewActive = false
    /// What the page asks for (`setPreviewActive`).
    private var previewWanted = false
    /// The window is on screen, uncovered and the app is in front (`PreviewRenderingPolicy`).
    private var windowShowsPreview = false
    private var visibilityObservers: [any NSObjectProtocol] = []
    private let activity: SettingsLiveActivity
    private var activityObserver: UUID?
    private let makeAssembly: @MainActor (HUDSkinID) -> SkinPreviewAssembly
    private let makeEnvironment: @MainActor (Bool) -> HUDEnvironment
    private let log: @MainActor (String) -> Void
    private static var runningPreviews = 0
    private var generation = 0
    private var clock: Double = 0
    private var level: CGFloat = 0
    private var syllableOn = false
    private var syllableLeft: Double = 0.3
    private var syllablePeak: CGFloat = 0
    private var syllableTime: Double = 0
    private var aim: HUDAim = .none
    private var releasing = false
    private var pendingRelease: HUDRelease?
    private var releaseStart: Double = 0
    private var releaseFrom: CGFloat = 0
    private var lastDy: CGFloat = 0

    var motion: Motion = .idle {
        didSet { if motion != oldValue { clock = 0 } }
    }
    var voiceAmount: CGFloat = 1
    var previewScale: CGFloat = 1 {
        didSet { if previewScale != oldValue { needsLayout = true } }
    }
    /// Overall size (1 = normal) for skins that have a size setting. The preview is a demo rather than a
    /// live gesture, so a change applies at once. Skins without a size setting ignore it.
    var layoutScale: CGFloat = 1 {
        didSet {
            guard layoutScale != oldValue else { return }
            (skin as? ShaderSkin)?.setLayoutScale(layoutScale)
            placeSkin()
        }
    }
    /// The size the current skin is actually drawn at.
    private var effectiveLayoutScale: CGFloat { (skin as? ShaderSkin)?.layoutScale ?? 1 }
    var previewFrameRate: Float = 60 {
        didSet {
            guard previewFrameRate != oldValue else { return }
            (skin as? ShaderSkin)?.setFrameRate(previewFrameRate)
        }
    }

    init(paper style: PreviewPaperView.Style, activity: SettingsLiveActivity = .shared,
         makeAssembly: @escaping @MainActor (HUDSkinID) -> SkinPreviewAssembly = SkinPreviewFactory.make,
         makeEnvironment: @escaping @MainActor (Bool) -> HUDEnvironment = { SkinPreviewFactory.environment(isDark: $0) },
         log: @escaping @MainActor (String) -> Void = { RuntimeTrace.record($0) }) {
        self.activity = activity
        self.makeAssembly = makeAssembly; self.makeEnvironment = makeEnvironment; self.log = log
        paper = PreviewPaperView(style: style)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(paper)
        scaler.wantsLayer = true
        addSubview(scaler)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        paper.frame = bounds
        scaler.frame = bounds
        placeSkin()
    }

    func configure(skin id: HUDSkinID, dark: Bool) {
        requestedSkin = id
        let appearanceChanged = dark != environment.isDark
        environment = makeEnvironment(dark)
        paper.isDark = dark
        guard previewActive else { return }
        if id != skinID || skin == nil {
            rebuild(id)
        } else if appearanceChanged, let skin {
            skin.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            skin.apply(environment)
        }
        assembly?.radial?.setCompactPreviewLabels(previewScale < 0.7,
                                                  dark: dark && (id == .liquidGlass || id == .classic),
                                                  scaleFactor: previewScale)
    }

    /// The page's wish. The preview runs only while its window is also viewable (`observeVisibility`).
    func setPreviewActive(_ active: Bool) {
        guard active != previewWanted else { return }
        previewWanted = active
        reconcilePreview()
    }

    private func reconcilePreview() {
        let shouldRun = previewWanted && windowShowsPreview && !activity.snapshot.pausesSkinPreviews
        guard shouldRun != previewActive else { return }
        previewActive = shouldRun
        generation += 1
        countRunning(shouldRun)
        guard shouldRun else {
            disposeSkin()
            return
        }
        guard let requestedSkin else { return }
        if skin == nil || skinID != requestedSkin {
            rebuild(requestedSkin)
        } else {
            startPreview()
        }
    }

    /// One line when the first preview starts and when the last one stops, so the log shows whether previews
    /// are drawing while the settings window is closed.
    private func countRunning(_ running: Bool) {
        let before = Self.runningPreviews
        Self.runningPreviews = max(0, before + (running ? 1 : -1))
        if before == 0 || Self.runningPreviews == 0 {
            log("skin previews running=\(Self.runningPreviews)")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility()
        refreshWindowVisibility()
    }

    /// A settings window that was closed, minimized, covered or left in the background keeps its views alive,
    /// and SwiftUI does not say so (`onDisappear` never fires). Previews that kept drawing there held Metal
    /// drawables the compositor no longer returned, and the main thread waited for them: the hang samples of
    /// 2026-09-30 (idle app) had 25-75% of the main thread inside `nextDrawable`. So previews follow the window.
    private func observeVisibility() {
        let center = NotificationCenter.default
        for token in visibilityObservers { center.removeObserver(token) }
        visibilityObservers.removeAll()
        if let activityObserver { activity.removeObserver(activityObserver) }
        activityObserver = nil
        guard let window else { return }
        activityObserver = activity.observe { [weak self] _ in self?.reconcilePreview() }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshWindowVisibility() }
        }
        let windowNames: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        for name in windowNames {
            visibilityObservers.append(center.addObserver(forName: name, object: window, queue: nil, using: refresh))
        }
        let appNames: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        for name in appNames {
            visibilityObservers.append(center.addObserver(forName: name, object: nil, queue: nil, using: refresh))
        }
    }

    private func refreshWindowVisibility() {
        var shows = false
        if let window {
            #if SETTINGS_REVIEW_HOST
            let applicationIsActive = true
            #else
            let applicationIsActive = NSApp.isActive
            #endif
            shows = PreviewRenderingPolicy.isViewable(
                windowIsOnScreen: window.isVisible,
                windowIsOccluded: !window.occlusionState.contains(.visible),
                windowIsMiniaturized: window.isMiniaturized,
                applicationIsActive: applicationIsActive,
                applicationIsHidden: NSApp.isHidden
            )
        }
        #if SETTINGS_REVIEW_HOST
        // Review host only: a capture session runs the host hidden in the background; keep previews drawing there.
        if let window, UserDefaults.standard.bool(forKey: "settingsReviewCaptureHidden") { shows = !window.isMiniaturized }
        #endif
        guard shows != windowShowsPreview else { return }
        windowShowsPreview = shows
        reconcilePreview()
    }

    func playRelease(_ action: HUDRelease) {
        guard previewActive, skin != nil, !releasing, pendingRelease == nil else { return }
        pendingRelease = action
        releaseStart = clock
        releaseFrom = lastDy
    }

    func shutdown() {
        setPreviewActive(false)
        generation += 1
        disposeSkin()
        requestedSkin = nil
        let center = NotificationCenter.default
        for token in visibilityObservers { center.removeObserver(token) }
        visibilityObservers.removeAll()
        if let activityObserver { activity.removeObserver(activityObserver) }
        activityObserver = nil
        windowShowsPreview = false
    }

    private func rebuild(_ id: HUDSkinID) {
        disposeSkin()
        let newAssembly = makeAssembly(id)
        assembly = newAssembly
        skinID = id
        newAssembly.radial?.setCompactPreviewLabels(previewScale < 0.7,
                                                     dark: environment.isDark && (id == .liquidGlass || id == .classic),
                                                     scaleFactor: previewScale)
        newAssembly.skin.view.appearance = NSAppearance(named: environment.isDark ? .darkAqua : .aqua)
        (newAssembly.skin as? ShaderSkin)?.setLayoutScale(layoutScale)
        scaler.addSubview(newAssembly.skin.view)
        placeSkin()
        startPreview()
    }

    private func startPreview() {
        guard previewActive, let skin else { return }
        stopTimer()
        skin.view.appearance = NSAppearance(named: environment.isDark ? .darkAqua : .aqua)
        skin.apply(environment)
        assembly?.syntheticMonitor?.start()
        skin.present(coreOnly: false)
        (skin as? ShaderSkin)?.setFrameRate(previewFrameRate)
        clock = 0
        level = 0
        syllableOn = false
        syllableLeft = 0.3
        syllablePeak = 0
        syllableTime = 0
        aim = .none
        releasing = false
        pendingRelease = nil
        lastDy = 0
        startTimer()
    }

    private func disposeSkin() {
        stopTimer()
        assembly?.shutdown()
        assembly?.skin.view.removeFromSuperview()
        assembly = nil
        skinID = nil
    }

    private func placeSkin() {
        guard let view = skin?.view else { return }
        let anchor = HUDLayout.anchor(scale: effectiveLayoutScale)
        let size = HUDLayout.panelSize(scale: effectiveLayoutScale)
        view.frame = NSRect(
            x: (bounds.midX - anchor.x).rounded(),
            y: (bounds.midY - anchor.y).rounded(),
            width: size.width,
            height: size.height
        )
        guard let layer = scaler.layer else { return }
        let scale = previewScale
        let anchorX = layer.anchorPoint.x * layer.bounds.width + layer.bounds.minX
        let anchorY = layer.anchorPoint.y * layer.bounds.height + layer.bounds.minY
        let dx = layer.bounds.midX - anchorX
        let dy = layer.bounds.midY - anchorY
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -dx, -dy, 0)
        Anim.quiet { layer.sublayerTransform = transform }
    }

    private func startTimer() {
        stopTimer()
        let next = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    #if F5_SETTINGS_CHECK
    func setViewableForCheck(_ viewable: Bool) {
        if activityObserver == nil {
            activityObserver = activity.observe { [weak self] _ in self?.reconcilePreview() }
        }
        windowShowsPreview = viewable
        reconcilePreview()
    }
    var runningForCheck: Bool { previewActive && timer != nil }
    func releaseForCheck() {
        if previewActive, let skin { releasePreview(.send, skin: skin) }
    }
    #endif

    deinit {
        let activity = activity, token = activityObserver
        Task { @MainActor in if let token { activity.removeObserver(token) } }
    }

    private static let path: [(Double, CGFloat)] = [
        (0.0, 0), (1.1, 0), (1.9, 72), (3.1, 72), (3.7, 0),
        (4.7, 0), (5.5, -72), (6.5, -72), (7.1, 0), (8.4, 0),
    ]

    private static func pathDy(_ time: Double) -> CGFloat {
        let duration = path[path.count - 1].0
        let position = time.truncatingRemainder(dividingBy: duration)
        for index in 1..<path.count {
            let (endTime, endValue) = path[index]
            let (startTime, startValue) = path[index - 1]
            if position <= endTime {
                let progress = CGFloat(max(0, min(1, (position - startTime) / max(endTime - startTime, 0.0001))))
                let eased = progress * progress * (3 - 2 * progress)
                return startValue + (endValue - startValue) * eased
            }
        }
        return 0
    }

    @objc private func tick(_ timer: Timer) {
        guard previewActive, !releasing, let skin else { return }
        let delta = 1.0 / 30
        clock += delta
        updateSyntheticVoice(delta: delta, skin: skin)

        // The demo pointer travels farther for a larger disc, as a real one would.
        let travel = effectiveLayoutScale
        var dy: CGFloat = motion == .demo ? Self.pathDy(clock) * travel : 0
        if let action = pendingRelease {
            let progress = CGFloat(max(0, min(1, (clock - releaseStart) / 0.35)))
            let target: CGFloat = (action == .send ? 72 : -72) * travel
            dy = releaseFrom + (target - releaseFrom) * (progress * progress * (3 - 2 * progress))
            if clock - releaseStart >= 0.5 {
                pendingRelease = nil
                releasePreview(action, skin: skin)
                return
            }
        }
        lastDy = dy
        switch aim {
        case .none:
            if dy > 24 * travel { aim = .send } else if dy < -24 * travel { aim = .cancel }
        case .send:
            if dy < -24 * travel { aim = .cancel } else if abs(dy) < 16 * travel { aim = .none }
        case .cancel:
            if dy > 24 * travel { aim = .send } else if abs(dy) < 16 * travel { aim = .none }
        }
        skin.update(pointer: HUDPointer(dy: dy, aim: aim, progress: HUDLayout.progress(forDy: dy, scale: travel)))
    }

    private func releasePreview(_ action: HUDRelease, skin: any HUDSkin) {
        releasing = true
        let currentGeneration = generation
        skin.release(action) { [weak self] in
            guard let self, self.previewActive, self.generation == currentGeneration else { return }
            Anim.after(0.2) { [weak self] in
                guard let self, self.previewActive, self.generation == currentGeneration,
                      let id = self.requestedSkin else { return }
                self.rebuild(id)
            }
        }
    }

    private func updateSyntheticVoice(delta: Double, skin: any HUDSkin) {
        syllableLeft -= delta
        syllableTime += delta
        if syllableLeft <= 0 {
            if syllableOn {
                let pause = Double.random(in: 0...1) < 0.18
                syllableOn = false
                syllableLeft = pause ? Double.random(in: 0.35...0.8) : Double.random(in: 0.06...0.18)
            } else {
                syllableOn = true
                syllableLeft = Double.random(in: 0.11...0.22)
                syllablePeak = CGFloat.random(in: 0.45...1.0)
            }
            syllableTime = 0
        }
        var raw: CGFloat = 0
        if syllableOn {
            raw = syllableTime < 0.03
                ? syllablePeak * CGFloat(syllableTime / 0.03)
                : syllablePeak * CGFloat(exp(-(syllableTime - 0.03) / 0.12))
        }
        let timeConstant = raw > level ? 0.04 : 0.16
        level += (raw - level) * CGFloat(1 - exp(-delta / timeConstant))
        assembly?.syntheticMonitor?.level = Float(level * voiceAmount)
        skin.update(level: level * voiceAmount)
    }
}

@MainActor
final class PreviewPaperView: NSView {
    enum Style { case lines, text }

    let style: Style
    var isDark = false {
        didSet {
            guard isDark != oldValue else { return }
            appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            needsDisplay = true
        }
    }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        switch style {
        case .lines: drawBars()
        case .text: drawText()
        }
    }

    private func drawBars() {
        let ink = NSColor.labelColor.withAlphaComponent(0.07)
        let selected = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.24)
        let widths: [CGFloat] = [0.82, 0.64, 0.90, 0.55, 0.78, 0.70, 0.86, 0.50, 0.74, 0.66]
        var y: CGFloat = 12
        var index = 0
        while y < bounds.height - 6 {
            let width = (bounds.width - 24) * widths[index % widths.count]
            (index == 4 ? selected : ink).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: y, width: width, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            y += 12
            index += 1
        }
    }

    #if SETTINGS_REVIEW_HOST
    private static let lines = [
        "示例文字用于查看圆盘与输入区域的层次。",
        "第二行展示中文、标点与适中的行距。",
        "第三行包含 English words 和数字 123。",
        "第四行保持普通长度，便于观察遮挡范围。",
        "第五行是选中状态的视觉示例。",
        "第六行继续填充预览区域。",
        "第七行用于检查浅色模式的对比度。",
        "第八行用于检查深色模式的对比度。",
        "第九行没有个人内容或真实识别结果。",
        "第十行结束排版预览。",
    ]
    #else
    private static let lines = [
        "明天下午三点开会，记得把设计稿带上，顺便确认一下预算有没有变化。",
        "如果来不及的话我们改到周四，我先把 PR 合并，等 GitHub Actions 跑完再说。",
        "把 Qwen3-ASR 的 1.7B 模型换成 4-bit 量化版，然后跑一遍对比测试。",
        "这个 bug 在 macOS 26 上能复现，Sonoma 上没问题，先别急着发版。",
        "豆包输入法的离线语音比阿里云的 API 慢一点，但是不用联网。",
        "他说的是 Claude，不是 cloud，也不是 color。",
        "百分之八十五的用例都通过了，剩下的要人工看。",
        "麦克风、辅助功能和输入监控这三个权限都要单独申请。",
        "帮我把这句话翻译成英文：今天的会议推迟到下周一。",
        "我现在在深圳，下周三飞上海，周五回来。",
    ]
    #endif

    private func drawText() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55),
        ]
        var y: CGFloat = 16
        for (index, line) in Self.lines.enumerated() {
            if index == 4 {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.22).setFill()
                NSRect(x: 0, y: y - 3, width: bounds.width, height: 23).fill()
            }
            (line as NSString).draw(at: NSPoint(x: 22, y: y), withAttributes: attributes)
            y += 26
            if y > bounds.height { break }
        }
    }
}
