import AppKit
import QuartzCore
import VoicePointerCore

/// A panel whose contents are drawn with the active-window look although it never becomes key or main.
/// Liquid Glass (NSGlassEffectView) in a window that is not active draws its inactive look: frosted, and without
/// its tint. The HUD panel is never active (it must not take the focus from the text field being dictated into),
/// so the real disc was frosted while the settings preview, in the active settings window, was clear glass (Ken,
/// 2026-11-07). AppKit asks the window these undocumented questions to choose the look; answering yes gives the
/// panel the same glass as the preview. Measured in the review host's glass lab: overriding isKeyWindow,
/// isMainWindow or wrapping the glass in an always-active effect view did not help, these did. They only change
/// how things are drawn; the panel still never becomes key or main and never takes input.
@MainActor
class GlassActiveLookPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
}

@MainActor
private final class PassiveHUDPanel: GlassActiveLookPanel {}

/// The settings window draws its glass the same way, so the 圆盘样式 previews keep the look of the real disc when
/// the window is not in front (after switching to another app they went frosted white; Ken, 2026-11-07). It still
/// becomes key and main normally; only the drawing keeps the active look.
@MainActor
final class GlassActiveLookWindow: NSWindow {
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
}

@MainActor
final class StatusHUD {
    private static let hapticDebounceDuration = Duration.milliseconds(40)
    private static let panelSize = RadialHUDMetrics.panelSize
    private static let panelAnchor = CGPoint(
        x: 128 + RadialHUDMetrics.shadowPadding,
        y: 132 + RadialHUDMetrics.shadowPadding
    )

    private let panel: NSPanel
    private let settingsActivity = SettingsLiveActivityLease()
    private let host: NSView
    private let content: RadialHUDView
    private let microphoneMonitor: (any MicrophoneLevelMonitoring)?
    private let skinProvider: () -> HUDSkinID
    private var skinID: HUDSkinID = .classic
    /// Overall size of the skin being shown (1 = normal). Set by `applyHUDScale()` when a gesture begins and
    /// the HUD is hidden; the panel, hit testing and travel thresholds all follow this one value.
    private var hudScale: CGFloat = 1
    private var activeSkin: any HUDSkin
    private var levelTask: Task<Void, Never>?
    private var levelUpdateGeneration: UUID?
    private var coreOnly = false
    private var currentAction: VoiceReleaseAction = .stop
    private var acceptsReleaseAction = false
    private var releasePending = false
    private var earlySendSound = false
    private var dismissTask: Task<Void, Never>?
    private var inputNoticeTask: Task<Void, Never>?
    private var isListening = false
    private var inlinePolicyNoticeTask: Task<Void, Never>?
    func showInlinePolicyNotice() {
        inlinePolicyNoticeTask?.cancel()
        // Let the action's own outcome finish first; this notice must not
        // change the Coordinator state, retry delivery, or end new dictation.
        inlinePolicyNoticeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            let message = SettingsStrings.inlineRecoveryNotice
            if self.isListening { self.showMicrophoneNotice(message) }
            else { self.complete(feedback: .init(message: message, kind: .info), action: .stop) }
            self.inlinePolicyNoticeTask = nil
        }
    }
    func showMicrophoneNotice(_ message: String) {
        guard isListening else { return }
        inputNoticeTask?.cancel()
        content.showMicrophoneNotice(message)
        inputNoticeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.isListening else { return }
            self.content.setStatus(.listening)
        }
    }
    private var hapticDebounceTask: Task<Void, Never>?
    private var lastHapticAction: VoiceReleaseAction = .stop
    private var gestureAnchor: CGPoint?
    /// The previous tracked pointer position in hit-zone coordinates, so a quick flick that jumps
    /// over the Send / Cancel circle between two samples still arms it.
    private var lastZonePoint: CGPoint?
    private var gestureDeviceKind: TouchDeviceKind?
    private let hapticFeedback: ZoneHapticFeedback
    private let hapticStrengthProvider: () -> HapticStrength
    private let reduceMotionProvider: () -> Bool
    private let settingsButton = NSButton(title: OnlineAPIStrings.hudOpenSettings, target: nil, action: nil)
    private var settingsAction: (() -> Void)?

    static func feedbackDuration(for kind: ComposerActionFeedback.Kind) -> TimeInterval {
        switch kind {
        case .success: return 0.9
        case .info: return 1.2
        case .warning: return 2.0
        }
    }

    init(
        capturesMicrophoneLevels: Bool = true,
        microphoneLevelMonitor injectedMicrophoneMonitor: (any MicrophoneLevelMonitoring)? = nil,
        reduceMotionProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        hapticPerformer: @escaping (NSHapticFeedbackManager.FeedbackPattern) -> Void = { pattern in
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        },
        hapticFeedback injectedHapticFeedback: ZoneHapticFeedback? = nil,
        hapticStrengthProvider: @escaping () -> HapticStrength = { SettingsStore.shared.value.gesture.hapticStrength },
        skinProvider: @escaping () -> HUDSkinID = { HUDSkinPreferences.shared.selection }
    ) {
        self.hapticFeedback = injectedHapticFeedback
            ?? ZoneHapticFeedback(systemPerform: { hapticPerformer(.levelChange) })
        self.hapticStrengthProvider = hapticStrengthProvider
        self.reduceMotionProvider = reduceMotionProvider
        self.skinProvider = skinProvider
        panel = PassiveHUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false

        let monitor: (any MicrophoneLevelMonitoring)?
        if let injectedMicrophoneMonitor {
            monitor = injectedMicrophoneMonitor
        } else {
            monitor = capturesMicrophoneLevels ? MicrophoneLevelMonitor() : nil
        }
        microphoneMonitor = monitor
        content = RadialHUDView(
            frame: NSRect(
                origin: RadialHUDMetrics.logicalOrigin,
                size: RadialHUDMetrics.logicalSize
            ),
            microphoneLevelMonitor: monitor
        )
        content.setAccessibilityElement(false)

        let transparentHost = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        transparentHost.wantsLayer = true
        transparentHost.layer = CALayer()
        transparentHost.layer?.masksToBounds = false
        host = transparentHost
        activeSkin = ClassicSkin(radial: content)
        transparentHost.addSubview(activeSkin.view)
        settingsButton.target = self; settingsButton.action = #selector(openOnlineSettings)
        settingsButton.bezelStyle = .inline; settingsButton.isHidden = true
        settingsButton.font = .systemFont(ofSize: 12, weight: .semibold)
        transparentHost.addSubview(settingsButton)
        panel.contentView = transparentHost
        HUDShaderLibrary.shared.prepareAtStartup(selected: skinProvider())
    }

    private func prepareSkin() {
        let requested = skinProvider()
        let shaderLibrary = HUDShaderLibrary.shared
        if requested.isShaderSkin { shaderLibrary.prepare(requested) }
        let unavailable = !requested.isAvailableHere
            || (requested.isShaderSkin && !shaderLibrary.isPrepared(requested))
        let chosen: HUDSkinID = unavailable ? .classic : requested
        if chosen != skinID {
            stopLevelUpdates()
            content.removeFromSuperview()
            activeSkin.view.removeFromSuperview()
            // The glass adapter changes the shared radial (dial, core, hooks, tuning).
            // Restore all of it before another skin reuses the same radial view.
            content.resetSkinCustomizations()
            skinID = chosen
            switch chosen {
            case .classic: activeSkin = ClassicSkin(radial: content)
            case .liquidGlass: activeSkin = LiquidGlassSkin(radial: content)
            case .frosted:
                content.isHidden = true
                host.addSubview(content)
                activeSkin = FrostedSkin()
            case .miniDisc, .miniMorph:
                content.isHidden = true
                host.addSubview(content)
                activeSkin = MiniDiscSkin(morphs: chosen == .miniMorph)
            case .astra, .liquidMetal, .waterDrop, .liquidChrome, .dither, .metaballs, .blackHole,
                 .particles, .inkSprite, .bubble, .flame, .glassDisc, .frostDisc, .ferrofluid, .voiceLine, .ripple, .plasma:
                content.isHidden = true
                host.addSubview(content)
                if let shader = ShaderSkin(id: chosen) {
                    activeSkin = shader
                } else {
                    skinID = .classic
                    content.isHidden = false
                    content.removeFromSuperview()
                    activeSkin = ClassicSkin(radial: content)
                }
            }
            host.addSubview(activeSkin.view)
        }
        content.isHidden = skinID.usesStandaloneRenderer
        if skinID.usesStandaloneRenderer, content.superview == nil { host.addSubview(content) }
        // Liquid Glass: re-read the tuning at every gesture, so the real disc always shows what the settings preview
        // shows, even if a live update was missed (2026-11-07). Trace: enum names and numbers only.
        if let glassSkin = activeSkin as? LiquidGlassSkin {
            glassSkin.applyTuning()
            RuntimeTrace.record("liquid glass hud tuning \(glassSkin.tuningTraceSummary)")
        } else if let classicSkin = activeSkin as? ClassicSkin {
            classicSkin.applyTuning()
        }
        RuntimeTrace.record("hud skin prepared requested=\(requested.rawValue) skin=\(skinID.rawValue)")
        applyHUDScale()
        let appearance = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        activeSkin.apply(HUDEnvironment(
            isDark: appearance == .darkAqua,
            reduceMotion: reduceMotionProvider(),
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        ))
    }

    /// Sizes the panel and the skin for the overall size saved for it (Astra, black hole). Runs from
    /// `prepareSkin()`, when a gesture begins, never while one is in progress.
    private func applyHUDScale() {
        let requested: CGFloat = skinID.isShaderSkin ? SkinParamStore.shared.hudScale(for: skinID) : 1
        let scale = HUDLayout.clampedScale(requested)
        hudScale = scale
        (activeSkin as? ShaderSkin)?.setLayoutScale(scale)
        let size = scaledPanelSize
        if panel.contentView?.frame.size != size { panel.setContentSize(size) }
    }

    private var scaledPanelSize: CGSize {
        CGSize(width: Self.panelSize.width * hudScale, height: Self.panelSize.height * hudScale)
    }

    private var scaledPanelAnchor: CGPoint {
        CGPoint(x: Self.panelAnchor.x * hudScale, y: Self.panelAnchor.y * hudScale)
    }

    private func startLevelUpdatesIfNeeded() {
        guard levelTask == nil, skinID.usesStandaloneRenderer, let microphoneMonitor else { return }
        let generation = UUID()
        levelUpdateGeneration = generation
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.levelUpdateGeneration == generation else { return }
                guard self.panel.isVisible, self.skinID.usesStandaloneRenderer else {
                    self.stopLevelUpdates()
                    return
                }
                self.activeSkin.update(level: CGFloat(microphoneMonitor.displayLevel))
                do {
                    try await Task.sleep(for: .milliseconds(34))
                } catch {
                    break
                }
            }
            guard let self, self.levelUpdateGeneration == generation else { return }
            self.levelTask = nil
            self.levelUpdateGeneration = nil
        }
    }

    private func stopLevelUpdates() {
        levelTask?.cancel()
        levelTask = nil
        levelUpdateGeneration = nil
        microphoneMonitor?.stop()
        if skinID.usesStandaloneRenderer { activeSkin.update(level: 0) }
    }

    func beginGesture(deviceKind: TouchDeviceKind, deviceID: UInt64? = nil) {
        inputNoticeTask?.cancel(); inputNoticeTask = nil
        settingsActivity.gesture(true)
        earlySendSound = false
        VoicePointerHUDSound.shared.prepareForDictation()
        cancelPendingHaptic(resetTo: .stop)
        // The coordinator publishes its initial status before this callback.
        // Do not cancel the failure Toast it may just have presented.
        gestureDeviceKind = deviceKind
        hapticFeedback.begin(deviceKind: deviceKind, deviceID: deviceID)
    }

    /// Preserves the original status API. The first non-idle update anchors the
    /// dial to the gesture's Quartz point; tracking then uses the visible zones.
    func update(
        status: VoicePointerRuntimeStatus,
        quartzPoint: CGPoint?,
        allowsDirectedRelease: Bool = true,
        onlineSettingsAction: (() -> Void)? = nil
    ) {
        let reduceMotion = reduceMotionProvider()
        content.setReduceMotion(reduceMotion)

        switch status {
        case .idle:
            isListening = false
            acceptsReleaseAction = false
            if !releasePending { hideImmediately() }
            return

        case .resolvingTarget:
            isListening = false
            prepareSkin()
            coreOnly = !allowsDirectedRelease
            gestureAnchor = quartzPoint
            lastZonePoint = nil
            hideImmediately()
            prepareForPresentation(at: quartzPoint)
            // Show the original dial on admission, without waiting for AX or
            // the backend. A stationary waveform is not a recording signal;
            // recording and release actions still require .listening.
            acceptsReleaseAction = false
            content.setStatus(.resolvingTarget)
            content.setRadialChromeHidden(false)
            content.setDirectionalActionsHidden(!allowsDirectedRelease)
            content.setCenterHint("")

        case .listening:
            isListening = true
            if gestureAnchor == nil { prepareSkin() }
            if gestureAnchor == nil { gestureAnchor = quartzPoint }
            prepareForPresentation(at: quartzPoint)
            acceptsReleaseAction = allowsDirectedRelease
            content.setStatus(.listening)
            content.setRadialChromeHidden(false)
            content.setDirectionalActionsHidden(!allowsDirectedRelease)
            content.setCenterHint(allowsDirectedRelease ? "松手保留" : "再按停止")
            coreOnly = !allowsDirectedRelease

        case .failed(let message):
            isListening = false
            stopLevelUpdates()
            cancelPendingHaptic(resetTo: .stop)
            hapticFeedback.end()
            if !panel.isVisible && gestureAnchor == nil { prepareSkin() }
            // Keep the panel at the gesture's established anchor when a
            // result arrives after mouse-up. Only a failure with no visible
            // panel needs the supplied point to establish its first position.
            if !panel.isVisible { prepareForPresentation(at: quartzPoint) }
            acceptsReleaseAction = false
            currentAction = .stop
            content.setAction(.stop, animated: false)
            content.setStatus(.failed(message))
            content.showFeedback(message: message, kind: .warning)
            releasePending = true
            settingsAction = onlineSettingsAction
            settingsButton.isHidden = onlineSettingsAction == nil
            panel.ignoresMouseEvents = onlineSettingsAction == nil
            settingsButton.frame = NSRect(x: scaledPanelAnchor.x - 42, y: scaledPanelAnchor.y - 67 * hudScale, width: 84, height: 24)
            host.addSubview(settingsButton, positioned: .above, relativeTo: nil)
            scheduleDismiss(after: onlineSettingsAction == nil ? 2.0 : 4.0)
        }

        showIfNeeded()
        if case .failed(let message) = status, skinID.usesStandaloneRenderer {
            activeSkin.showFeedback(message) {}
        }
        if case .listening = status {
            // The radial view is hidden for standalone skins, and its reduced-
            // motion path intentionally has no waveform timer. Keep capture
            // owned by StatusHUD so neither condition can suppress the meter.
            if microphoneMonitor?.hasStartIntent != true {
                microphoneMonitor?.start()
            }
            startLevelUpdatesIfNeeded()
        }
    }

    /// Returns exactly the action represented by the visible circle currently
    /// under the pointer. Everywhere else is the neutral stop action.
    @discardableResult
    func track(quartzPoint: CGPoint) -> VoiceReleaseAction {
        updateTrackedAction(quartzPoint: quartzPoint, allowsHaptic: true)
    }

    @discardableResult
    private func updateTrackedAction(
        quartzPoint: CGPoint,
        allowsHaptic: Bool
    ) -> VoiceReleaseAction {
        guard acceptsReleaseAction, panel.isVisible,
              let appKitPoint = Self.appKitLocation(fromQuartzPoint: quartzPoint)?.point
        else { return .stop }

        let panelPoint = panel.convertPoint(fromScreen: appKitPoint)
        // The radial hit zones are laid out at normal size; a skin drawn larger or smaller maps the pointer back into them.
        let zonePoint = CGPoint(x: panelPoint.x / hudScale, y: panelPoint.y / hudScale)
        let contentPoint = content.convert(zonePoint, from: panel.contentView)
        var hitAction = content.action(at: contentPoint)
        if hitAction == .stop, currentAction == .stop, let previous = lastZonePoint,
           let crossed = crossedAction(from: previous, to: zonePoint) {
            hitAction = crossed
            RuntimeTrace.record("radial aim crossed=\(crossed.rawValue)")
        }
        lastZonePoint = zonePoint
        let action = RadialReleaseClassifier.classify(
            hitAction: hitAction,
            anchor: gestureAnchor,
            current: quartzPoint,
            previousAction: currentAction,
            minimumDirectionalTravel: RadialReleaseClassifier.defaultMinimumDirectionalTravel * hudScale,
            neutralTravel: RadialReleaseClassifier.defaultNeutralTravel * hudScale
        )
        if skinID.usesStandaloneRenderer {
            let dy = gestureAnchor.map { $0.y - quartzPoint.y } ?? 0
            activeSkin.update(pointer: HUDPointer(
                dy: dy,
                aim: action == .send ? .send : (action == .cancel ? .cancel : .none),
                progress: HUDLayout.progress(forDy: dy, scale: hudScale)
            ))
        }
        if action != currentAction {
            currentAction = action
            scheduleHaptic(for: action, ifAllowed: allowsHaptic)
            content.setAction(
                action,
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        }
        return action
    }

    /// The first Send / Cancel circle on the straight path between two hit-zone points, sampled every
    /// 3 pt. Pointer events can arrive far apart during a fast flick; the path between them was travelled.
    private func crossedAction(from start: CGPoint, to end: CGPoint) -> VoiceReleaseAction? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 3 else { return nil }
        let steps = min(Int(length / 3), 200)
        guard steps > 1 else { return nil }
        for step in 1..<steps {
            let t = CGFloat(step) / CGFloat(steps)
            let sample = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            let action = content.action(at: content.convert(sample, from: panel.contentView))
            if action != .stop { return action }
        }
        return nil
    }

    /// Freezes the final hit before mouse-up side effects run, then leaves a
    /// short visual confirmation even if the coordinator publishes idle.
    @discardableResult
    func releaseAction(
        at quartzPoint: CGPoint,
        heardSpeech: @MainActor () -> SpeechHeard = { GestureSpeechActivity.shared.heard() },
        playSendSound: @MainActor () -> Void = { VoicePointerHUDSound.shared.playSend() }
    ) -> VoiceReleaseAction {
        settingsActivity.gesture(false)
        hapticFeedback.cancelPending()
        hapticDebounceTask?.cancel()
        hapticDebounceTask = nil
        guard acceptsReleaseAction else { return .stop }
        isListening = false
        // Commit the last state the HUD actually showed. Mouse-up must never
        // switch a visible center state into an unseen Send or Cancel action.
        let action = currentAction
        // stop() commits this monitor's final speech summary before it is read.
        stopLevelUpdates()
        earlySendSound = action == .send && heardSpeech() != .silence
        if earlySendSound { playSendSound() }

        let delta = gestureAnchor.map {
            CGPoint(x: quartzPoint.x - $0.x, y: quartzPoint.y - $0.y)
        } ?? .zero
        RuntimeTrace.record(
            "radial release final=\(action.rawValue) " +
            "dx=\(Int(delta.x)) dy=\(Int(delta.y))"
        )

        acceptsReleaseAction = false
        releasePending = true
        content.commit(action)
        if skinID.usesStandaloneRenderer {
            activeSkin.release(action == .send ? .send : (action == .cancel ? .cancel : .keep)) {}
        }
        let fallbackDelay: TimeInterval = action == .stop ? 0.26 : 4.5
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        scheduleDismiss(after: action == .stop && reduceMotion ? 0.10 : fallbackDelay)
        return action
    }

    func complete(
        outcome: ComposerActionOutcome,
        action: VoiceReleaseAction,
        feedback suppliedFeedback: ComposerActionFeedback? = nil
    ) {
        // A completion from an older operation must not interrupt a new
        // listening session. Current-session results arrive after release,
        // when acceptsReleaseAction is already false.
        guard !acceptsReleaseAction else { return }
        if earlySendSound && action == .send {
            RuntimeTrace.record("hud sound send early=1 outcome=\(outcome.rawValue)")
            earlySendSound = false
        }
        switch outcome {
        case .nothingToSend, .clearArmed, .nothingToCancel: content.rebound()
        default: break
        }
        complete(
            feedback: suppliedFeedback ?? ComposerActionFeedback(outcome: outcome, action: action),
            action: action
        )
    }

    /// Release feedback is independent of a Chromium editor's delayed AX readback.
    /// An older release must never sound over a newly started gesture.
    func playEarlyCancelSound() {
        guard releasePending, !acceptsReleaseAction, currentAction == .cancel else { return }
        VoicePointerHUDSound.shared.playCancel(early: true)
    }

    func complete(feedback: ComposerActionFeedback, action: VoiceReleaseAction) {
        guard !acceptsReleaseAction else { return }
        stopLevelUpdates()
        guard feedback.shouldPresent else {
            // The action result is already perceptible through the editor,
            // state transition, or action sound. Do not repeat it as Toast or
            // VoiceOver. hideImmediately also cancels old deadlines/timers,
            // stops animation, and releases the pending gesture state.
            hideImmediately()
            return
        }
        content.stopAnimations()
        content.setReduceMotion(reduceMotionProvider())
        content.showFeedback(message: feedback.message, kind: feedback.kind)
        if skinID.usesStandaloneRenderer { activeSkin.showFeedback(feedback.message) {} }
        releasePending = true
        showIfNeeded()
        let duration = Self.feedbackDuration(for: feedback.kind)
        // Reduced motion changes animation only; result reading time stays
        // the same for every feedback category.
        scheduleDismiss(after: duration)
    }

    func previewDiagnostics() -> String {
        "skin=\(skinID.rawValue) visible=\(panel.isVisible) frame=\(NSStringFromRect(panel.frame)) " +
            "level=\(panel.level.rawValue) alpha=\(panel.alphaValue) " +
            content.previewDiagnostics()
    }

    var previewPanelFrame: CGRect { panel.frame }
    var previewBuiltInDialSurfaceHidden: Bool { content.hidesBuiltInDialSurface }
    var previewBuiltInCoreSurfaceHidden: Bool { content.hidesBuiltInCoreSurface }
    var previewBuiltInDialViewHidden: Bool { content.isHidden }
    var previewLevelUpdatesActive: Bool { levelTask != nil }
    var previewMicrophoneRunning: Bool { microphoneMonitor?.isRunning ?? false }
    var previewFeedbackFrame: CGRect { content.feedbackFrame }
    var previewAnnouncementCount: Int { content.feedbackAnnouncementCount }

    func previewCenterHint(_ value: String) {
        content.setCenterHint(value)
    }

    /// Escape, disconnect, and disable paths must not show send/cancel success.
    func cancelGesture() {
        isListening = false
        settingsActivity.gesture(false)
        earlySendSound = false
        stopLevelUpdates()
        (activeSkin as? ShaderSkin)?.stopRendering()
        cancelPendingHaptic(resetTo: .stop)
        dismissTask?.cancel()
        dismissTask = nil
        acceptsReleaseAction = false
        releasePending = false
        currentAction = .stop
        gestureAnchor = nil
        lastZonePoint = nil
        gestureDeviceKind = nil
        hapticFeedback.end()
        content.setAction(.stop, animated: false)
        content.stopAnimations()
        content.clearFeedback()

        guard panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hideImmediately()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }
        scheduleDismiss(after: 0.09)
    }

    private func prepareForPresentation(at quartzPoint: CGPoint?) {
        dismissTask?.cancel()
        dismissTask = nil
        releasePending = false

        if !panel.isVisible {
            currentAction = .stop
            content.setAction(.stop, animated: false)
        }

        guard let quartzPoint,
              let location = Self.appKitLocation(fromQuartzPoint: quartzPoint)
        else {
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(
                    x: screen.visibleFrame.midX - scaledPanelSize.width / 2,
                    y: screen.visibleFrame.maxY - scaledPanelSize.height - 20
                ))
            }
            return
        }

        let proposed = CGPoint(
            x: location.point.x - scaledPanelAnchor.x,
            y: location.point.y - scaledPanelAnchor.y
        )
        panel.setFrameOrigin(Self.clampedOrigin(
            proposed,
            panelSize: scaledPanelSize,
            visibleFrame: location.screen.visibleFrame,
            content: Self.visibleContent(scale: hudScale)
        ))
    }

    /// The part of the panel that shows anything: the 200 pt disc from top to bottom, and the widest Toast (240 pt)
    /// from side to side. The rest is transparent canvas and shadow room and may run past the screen edge.
    /// 2026-11-07: clamping used the whole 296 pt panel, so near the bottom of the screen the disc stopped about
    /// 160 pt above the edge and well away from the pointer; now its centre can come down to 108 pt.
    static func visibleContent(scale: CGFloat) -> CGRect {
        let anchor = HUDLayout.anchor
        let radius = HUDLayout.discRadius
        return CGRect(x: (anchor.x - 120) * scale, y: (anchor.y - radius) * scale,
                      width: 240 * scale, height: radius * 2 * scale)
    }

    private func showIfNeeded() {
        // Stop live previews synchronously before ordering/drawing the real HUD.
        settingsActivity.hud(true)
        guard !panel.isVisible else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        // A non-activating panel can silently remain transparent when its
        // NSWindow animator is created before the app event loop starts.
        // The component itself owns the presentation spring, so make the
        // window visible synchronously and animate only its contents.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        RuntimeTrace.record("hud visible on admission=\(panel.isVisible)")
        if skinID.usesStandaloneRenderer { activeSkin.present(coreOnly: coreOnly) }
        else { content.animatePresentation() }
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.hideImmediately()
        }
    }

    private func hideImmediately() {
        inputNoticeTask?.cancel(); inputNoticeTask = nil
        settingsButton.isHidden = true; settingsAction = nil; panel.ignoresMouseEvents = true
        stopLevelUpdates()
        cancelPendingHaptic(resetTo: .stop)
        hapticFeedback.end()
        dismissTask?.cancel()
        dismissTask = nil
        content.stopAnimations()
        content.clearFeedback()
        (activeSkin as? ShaderSkin)?.stopRendering()
        panel.alphaValue = 1
        panel.orderOut(nil)
        settingsActivity.hud(false)
        releasePending = false
        acceptsReleaseAction = false
        currentAction = .stop
        gestureAnchor = nil
        lastZonePoint = nil
        gestureDeviceKind = nil
    }
    @objc private func openOnlineSettings() { let action = settingsAction; hideImmediately(); action?() }

    private func scheduleHaptic(for action: VoiceReleaseAction, ifAllowed: Bool) {
        hapticFeedback.cancelPending()
        hapticDebounceTask?.cancel()
        hapticDebounceTask = nil
        guard ifAllowed, action != lastHapticAction,
              gestureDeviceKind == .builtInTrackpad || gestureDeviceKind == .externalTrackpad
        else { return }

        hapticDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.hapticDebounceDuration)
            } catch {
                return
            }
            guard let self, self.acceptsReleaseAction,
                  self.currentAction == action,
                  self.lastHapticAction != action
            else { return }
            self.lastHapticAction = action
            let zone: HapticZone = action == .send ? .send : (action == .cancel ? .cancel : .center)
            self.hapticFeedback.trigger(zone: zone, strength: self.hapticStrengthProvider())
            self.hapticDebounceTask = nil
        }
    }

    private func cancelPendingHaptic(resetTo action: VoiceReleaseAction) {
        hapticFeedback.cancelPending()
        hapticDebounceTask?.cancel()
        hapticDebounceTask = nil
        lastHapticAction = action
    }

    private static func appKitLocation(fromQuartzPoint point: CGPoint) -> (point: CGPoint, screen: NSScreen)? {
        let mappings: [(screen: NSScreen, quartzBounds: CGRect)] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return (screen, CGDisplayBounds(CGDirectDisplayID(number.uint32Value)))
        }
        guard !mappings.isEmpty else { return nil }

        let mapping = mappings.first(where: { $0.quartzBounds.contains(point) })
            ?? mappings.min(by: {
                squaredDistance(from: point, to: $0.quartzBounds)
                    < squaredDistance(from: point, to: $1.quartzBounds)
            })!
        let bounds = mapping.quartzBounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // CGEvent uses Quartz's top-left global space; AppKit uses bottom-left.
        // Ratios also cover different Quartz and logical AppKit display sizes.
        let normalizedX = (point.x - bounds.minX) / bounds.width
        let normalizedY = (point.y - bounds.minY) / bounds.height
        return (
            CGPoint(
                x: mapping.screen.frame.minX + normalizedX * mapping.screen.frame.width,
                y: mapping.screen.frame.maxY - normalizedY * mapping.screen.frame.height
            ),
            mapping.screen
        )
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// Keeps `content` (a rect inside the panel; the whole panel when nil) 8 pt inside the visible frame.
    static func clampedOrigin(
        _ origin: CGPoint, panelSize: CGSize, visibleFrame: CGRect, content: CGRect? = nil
    ) -> CGPoint {
        let frame = visibleFrame.insetBy(dx: 8, dy: 8)
        let shown = content ?? CGRect(origin: .zero, size: panelSize)
        let minX = frame.minX - shown.minX
        let minY = frame.minY - shown.minY
        let maxX = max(minX, frame.maxX - shown.maxX)
        let maxY = max(minY, frame.maxY - shown.maxY)
        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }
}

@MainActor
private final class LegacyRadialHUDView: NSView {
    private enum Geometry {
        static let dialRect = CGRect(x: 34, y: 34, width: 132, height: 132)
        static let centerRect = CGRect(x: 70, y: 70, width: 60, height: 60)
        static let sendRect = CGRect(x: 74, y: 132, width: 52, height: 52)
        static let undoRect = CGRect(x: 74, y: 16, width: 52, height: 52)
    }

    private let effectView = NSVisualEffectView(frame: Geometry.dialRect)
    private let overlay = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))

    private let dialTintLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let pulseLayerA = CAShapeLayer()
    private let pulseLayerB = CAShapeLayer()
    private let resolvingRingLayer = CAShapeLayer()
    private let centerLayer = CAShapeLayer()
    private let sendLayer = CAShapeLayer()
    private let undoLayer = CAShapeLayer()
    private let waveformLayers = (0..<5).map { _ in CAShapeLayer() }
    private var waveformTimer: Timer?
    private var waveformPhase: CGFloat = 0

    private let sendIcon = NSImageView(frame: CGRect(x: 90, y: 148, width: 20, height: 20))
    private let undoIcon = NSImageView(frame: CGRect(x: 90, y: 32, width: 20, height: 20))
    private let centerIcon = NSImageView(frame: CGRect(x: 84, y: 91, width: 32, height: 18))
    private let sendLabel = NSTextField(labelWithString: "发送")
    private let undoLabel = NSTextField(labelWithString: "撤销")
    private let centerTitle = NSTextField(labelWithString: "听写中")
    private let centerHint = NSTextField(labelWithString: "松手停止")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    private var reduceMotion = false
    private var displayedStatus: VoicePointerRuntimeStatus = .idle
    private var selectedAction: VoiceReleaseAction = .stop

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Geometry.dialRect.width / 2
        effectView.layer?.masksToBounds = true
        addSubview(effectView)

        overlay.wantsLayer = true
        overlay.layer = CALayer()
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        configureShapeLayers()
        configureTextAndIcons()
        applyPalette()
        resolvingRingLayer.isHidden = true
        setAction(.stop, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        shapeLayers.forEach { $0.contentsScale = scale }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    func setReduceMotion(_ enabled: Bool) {
        guard reduceMotion != enabled else { return }
        reduceMotion = enabled
        if enabled { stopAnimations() } else { restartStatusAnimations() }
    }

    func setStatus(_ status: VoicePointerRuntimeStatus) {
        displayedStatus = status
        errorLabel.isHidden = true
        setActionViewsHidden(false)

        switch status {
        case .idle:
            stopAnimations()

        case .resolvingTarget:
            centerIcon.image = symbol(named: "scope", pointSize: 18, weight: .semibold)
            centerIcon.contentTintColor = .systemYellow
            centerIcon.isHidden = false
            waveformLayers.forEach { $0.isHidden = true }
            pulseLayerA.isHidden = true
            pulseLayerB.isHidden = true
            centerTitle.stringValue = "定位中"
            centerHint.stringValue = "松手保留"
            restartStatusAnimations()

        case .listening:
            centerIcon.isHidden = true
            waveformLayers.forEach { $0.isHidden = false }
            pulseLayerA.isHidden = false
            pulseLayerB.isHidden = false
            centerTitle.stringValue = "听写中"
            centerHint.stringValue = "松手保留"
            restartStatusAnimations()

        case .failed(let message):
            stopAnimations()
            setActionViewsHidden(true)
            waveformLayers.forEach { $0.isHidden = true }
            pulseLayerA.isHidden = true
            pulseLayerB.isHidden = true
            errorLabel.stringValue = message
            errorLabel.isHidden = false
        }
        applyPalette()
        if case .failed = status {
            centerLayer.fillColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
            centerLayer.strokeColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
        }
    }

    func action(at point: CGPoint) -> VoiceReleaseAction {
        if Self.circle(Geometry.sendRect, contains: point) { return .send }
        if Self.circle(Geometry.undoRect, contains: point) { return .cancel }
        return .stop
    }

    func setAction(_ action: VoiceReleaseAction, animated: Bool) {
        let changed = action != selectedAction
        selectedAction = action
        applyPalette()
        guard changed, animated, !reduceMotion else { return }

        let target: CALayer = switch action {
        case .stop: centerLayer
        case .send: sendLayer
        case .cancel: undoLayer
        }
        let snap = CAKeyframeAnimation(keyPath: "transform.scale")
        snap.values = [1.0, 1.13, 1.04]
        snap.keyTimes = [0, 0.55, 1]
        snap.duration = 0.18
        snap.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        target.add(snap, forKey: "voicePointer.snap")
    }

    func animatePresentation() {
        guard !reduceMotion, let layer = overlay.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.90
        spring.toValue = 1.0
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 25
        spring.initialVelocity = 0
        spring.duration = min(spring.settlingDuration, 0.24)
        layer.add(spring, forKey: "voicePointer.present")
    }

    func commit(_ action: VoiceReleaseAction) {
        setAction(action, animated: !reduceMotion)
        guard !reduceMotion else { return }

        let targetView: NSImageView = switch action {
        case .stop: centerIcon
        case .send: sendIcon
        case .cancel: undoIcon
        }
        targetView.wantsLayer = true
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [1.0, 0.42, 1.0]
        flash.keyTimes = [0, 0.45, 1]
        flash.duration = 0.20
        targetView.layer?.add(flash, forKey: "voicePointer.commit")

        if action == .send {
            let lift = CABasicAnimation(keyPath: "transform.translation.y")
            lift.fromValue = 0
            lift.toValue = 9
            lift.duration = 0.18
            lift.timingFunction = CAMediaTimingFunction(name: .easeOut)
            targetView.layer?.add(lift, forKey: "voicePointer.send")
        }
    }

    func rebound() {
        guard !reduceMotion, let layer = overlay.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, 4, -2, 0]
        bounce.keyTimes = [0, 0.35, 0.70, 1]
        bounce.duration = 0.22
        bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bounce, forKey: "voicePointer.boundary")
    }

    func stopAnimations() {
        pulseLayerA.removeAllAnimations()
        pulseLayerB.removeAllAnimations()
        resolvingRingLayer.removeAllAnimations()
        centerIcon.layer?.removeAllAnimations()
        waveformTimer?.invalidate()
        waveformTimer = nil
    }

    private var shapeLayers: [CAShapeLayer] {
        [dialTintLayer, borderLayer, guideLayer, pulseLayerA, pulseLayerB,
         resolvingRingLayer, centerLayer, sendLayer, undoLayer] + waveformLayers
    }

    private func configureShapeLayers() {
        guard let rootLayer = overlay.layer else { return }

        dialTintLayer.frame = bounds
        dialTintLayer.path = CGPath(ellipseIn: Geometry.dialRect, transform: nil)
        dialTintLayer.shadowColor = NSColor.black.cgColor
        dialTintLayer.shadowOpacity = 0.22
        dialTintLayer.shadowRadius = 16
        dialTintLayer.shadowOffset = CGSize(width: 0, height: -3)
        rootLayer.addSublayer(dialTintLayer)

        borderLayer.frame = bounds
        borderLayer.path = CGPath(ellipseIn: Geometry.dialRect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 1
        rootLayer.addSublayer(borderLayer)

        guideLayer.frame = bounds
        let guidePath = CGMutablePath()
        guidePath.move(to: CGPoint(x: Geometry.centerRect.midX, y: Geometry.undoRect.midY))
        guidePath.addLine(to: CGPoint(x: Geometry.centerRect.midX, y: Geometry.sendRect.midY))
        guideLayer.path = guidePath
        guideLayer.lineWidth = 2
        guideLayer.lineCap = .round
        guideLayer.lineDashPattern = [2, 6]
        rootLayer.addSublayer(guideLayer)

        for pulse in [pulseLayerA, pulseLayerB] {
            pulse.frame = Geometry.centerRect
            pulse.path = CGPath(ellipseIn: pulse.bounds.insetBy(dx: 2, dy: 2), transform: nil)
            pulse.fillColor = NSColor.clear.cgColor
            pulse.lineWidth = 1.5
            rootLayer.addSublayer(pulse)
        }

        resolvingRingLayer.frame = Geometry.centerRect.insetBy(dx: -5, dy: -5)
        resolvingRingLayer.path = CGPath(
            ellipseIn: resolvingRingLayer.bounds.insetBy(dx: 2, dy: 2),
            transform: nil
        )
        resolvingRingLayer.fillColor = NSColor.clear.cgColor
        resolvingRingLayer.lineWidth = 2
        resolvingRingLayer.lineDashPattern = [4, 7]
        rootLayer.addSublayer(resolvingRingLayer)

        configureCircleLayer(centerLayer, rect: Geometry.centerRect, in: rootLayer)
        configureCircleLayer(sendLayer, rect: Geometry.sendRect, in: rootLayer)
        configureCircleLayer(undoLayer, rect: Geometry.undoRect, in: rootLayer)
        waveformLayers.forEach { layer in
            layer.frame = Geometry.centerRect
            layer.fillColor = NSColor.clear.cgColor
            layer.lineWidth = 1.5
            layer.lineCap = .round
            rootLayer.addSublayer(layer)
        }
        updateWaveforms()
    }

    private func configureCircleLayer(_ shapeLayer: CAShapeLayer, rect: CGRect, in rootLayer: CALayer) {
        shapeLayer.frame = rect
        shapeLayer.path = CGPath(ellipseIn: shapeLayer.bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        shapeLayer.lineWidth = 1.5
        shapeLayer.shadowRadius = 12
        shapeLayer.shadowOffset = .zero
        rootLayer.addSublayer(shapeLayer)
    }

    private func configureTextAndIcons() {
        sendIcon.image = symbol(named: "paperplane.fill", pointSize: 16, weight: .semibold)
        undoIcon.image = symbol(named: "arrow.uturn.backward", pointSize: 16, weight: .semibold)
        centerIcon.image = symbol(named: "waveform", pointSize: 20, weight: .semibold)
        [sendIcon, undoIcon, centerIcon].forEach {
            $0.imageScaling = .scaleProportionallyDown
            $0.wantsLayer = true
            overlay.addSubview($0)
        }

        configureLabel(sendLabel, frame: CGRect(x: 90, y: 151, width: 44, height: 14), size: 10, weight: .semibold)
        configureLabel(undoLabel, frame: CGRect(x: 78, y: 18, width: 44, height: 14), size: 10, weight: .semibold)
        sendLabel.isHidden = true; undoLabel.isHidden = true; centerTitle.isHidden = true
        configureLabel(centerTitle, frame: CGRect(x: 78, y: 96, width: 68, height: 14), size: 11, weight: .semibold)
        configureLabel(centerHint, frame: CGRect(x: 56, y: 0, width: 88, height: 18), size: 10, weight: .medium)
        centerHint.wantsLayer = true
        centerHint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.52).cgColor
        centerHint.layer?.cornerRadius = 9
        centerHint.layer?.masksToBounds = true

        errorLabel.frame = CGRect(x: 36, y: 82, width: 152, height: 60)
        errorLabel.alignment = .center
        errorLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        errorLabel.textColor = .labelColor
        errorLabel.maximumNumberOfLines = 3
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true
        errorLabel.wantsLayer = true
        errorLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        errorLabel.layer?.cornerRadius = 10
        errorLabel.layer?.masksToBounds = true
        overlay.addSubview(errorLabel)
    }

    private func configureLabel(
        _ label: NSTextField,
        frame: CGRect,
        size: CGFloat,
        weight: NSFont.Weight
    ) {
        label.frame = frame
        label.alignment = .center
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .secondaryLabelColor
        overlay.addSubview(label)
    }

    private func setActionViewsHidden(_ hidden: Bool) {
        setDirectionalActionsHidden(hidden)
        centerIcon.isHidden = hidden
        centerTitle.isHidden = true
        centerHint.isHidden = hidden
    }

    /// Hides the large radial surface while retaining the same passive panel
    /// for a compact, pointer-adjacent failure message.
    func setRadialChromeHidden(_ hidden: Bool) {
        effectView.isHidden = hidden
        [dialTintLayer, borderLayer, guideLayer, pulseLayerA, pulseLayerB,
         resolvingRingLayer, centerLayer, sendLayer, undoLayer]
            .forEach { $0.isHidden = hidden }
        waveformLayers.forEach { $0.isHidden = hidden }
        if hidden {
            errorLabel.frame = CGRect(x: 20, y: 76, width: 160, height: 48)
            errorLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            errorLabel.maximumNumberOfLines = 2
            errorLabel.alignment = .center
        } else {
            errorLabel.frame = CGRect(x: 36, y: 82, width: 152, height: 60)
        }
    }

    func setDirectionalActionsHidden(_ hidden: Bool) {
        sendLayer.isHidden = hidden
        undoLayer.isHidden = hidden
        guideLayer.isHidden = hidden
        sendIcon.isHidden = hidden
        undoIcon.isHidden = hidden
        sendLabel.isHidden = true
        undoLabel.isHidden = true
    }

    func setCenterHint(_ value: String) {
        centerHint.stringValue = value
    }

    private func applyPalette() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.material = reduceTransparency ? .menu : .hudWindow
        dialTintLayer.fillColor = (reduceTransparency
            ? NSColor.windowBackgroundColor.withAlphaComponent(0.96)
            : NSColor.black.withAlphaComponent(0.13)).cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.20).cgColor
        guideLayer.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor

        let centerColor: NSColor = .systemBlue
        pulseLayerA.strokeColor = centerColor.withAlphaComponent(0.50).cgColor
        pulseLayerB.strokeColor = centerColor.withAlphaComponent(0.32).cgColor
        resolvingRingLayer.strokeColor = centerColor.withAlphaComponent(0.82).cgColor

        let neutralFill = NSColor.white.withAlphaComponent(0.075)
        let neutralStroke = NSColor.white.withAlphaComponent(0.20)
        applyCenterCore(fill: neutralFill, stroke: neutralStroke, accent: centerColor)
        applyDirection(sendLayer, selected: selectedAction == .send, color: .systemGreen)
        applyDirection(undoLayer, selected: selectedAction.isUndo, color: .systemOrange)

        sendIcon.contentTintColor = selectedAction == .send ? .white : .systemGreen
        undoIcon.contentTintColor = selectedAction.isUndo ? .white : .systemOrange
        centerIcon.contentTintColor = centerColor
        sendLabel.textColor = selectedAction == .send ? .white : .secondaryLabelColor
        undoLabel.textColor = selectedAction.isUndo ? .white : .secondaryLabelColor
        centerTitle.textColor = selectedAction == .stop ? .white : .secondaryLabelColor
        centerHint.textColor = NSColor.white.withAlphaComponent(0.90)
        centerHint.stringValue = switch selectedAction {
        case .stop: "松手保留"
        case .send: "松开发送"
        case .cancel: "松手撤销一步"
        }
        waveformLayers.forEach { $0.strokeColor = centerColor.withAlphaComponent(0.86).cgColor }
        let shift: CGFloat = selectedAction == .send ? 8 : (selectedAction.isUndo ? -8 : 0)
        let transform = CGAffineTransform(translationX: 0, y: shift)
        centerLayer.setAffineTransform(transform)
        pulseLayerA.setAffineTransform(transform)
        pulseLayerB.setAffineTransform(transform)
        resolvingRingLayer.setAffineTransform(transform)
        waveformLayers.forEach { $0.setAffineTransform(transform) }
        centerIcon.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: shift))
        dialTintLayer.opacity = selectedAction == .stop ? 1 : 0.88
        borderLayer.opacity = selectedAction == .stop ? 1 : 0.72
    }

    private func applyCenterCore(fill: NSColor, stroke: NSColor, accent: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        centerLayer.fillColor = fill.cgColor
        centerLayer.strokeColor = (selectedAction == .stop
            ? accent.withAlphaComponent(0.78)
            : stroke).cgColor
        centerLayer.lineWidth = selectedAction == .stop ? 2 : 1.5
        centerLayer.shadowColor = accent.cgColor
        centerLayer.shadowOpacity = selectedAction == .stop ? 0.24 : 0.08
        centerLayer.shadowRadius = 12
        CATransaction.commit()
    }

    private func applyDirection(
        _ layer: CAShapeLayer,
        selected: Bool,
        color: NSColor
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.fillColor = color.withAlphaComponent(selected ? 0.18 : 0.025).cgColor
        layer.strokeColor = color.withAlphaComponent(selected ? 0.95 : 0.38).cgColor
        layer.lineWidth = selected ? 2.25 : 1.25
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = selected ? 0.75 : 0.10
        layer.shadowRadius = selected ? 18 : 8
        CATransaction.commit()
    }

    private func restartStatusAnimations() {
        stopAnimations()
        resolvingRingLayer.isHidden = true

        switch displayedStatus {
        case .resolvingTarget:
            resolvingRingLayer.isHidden = false
            guard !reduceMotion else { return }
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = CGFloat.pi * 2
            rotation.duration = 0.9
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            resolvingRingLayer.add(rotation, forKey: "voicePointer.resolving")

        case .listening:
            guard !reduceMotion else { return }
            waveformTimer?.invalidate()
            waveformTimer = scheduleMainActorTimer(every: 1.0 / 24.0) { [weak self] in
                self?.waveformTick()
            }
            addPulse(to: pulseLayerA, delay: 0)
            addPulse(to: pulseLayerB, delay: 0.575)

            let breathing = CABasicAnimation(keyPath: "transform.scale")
            breathing.fromValue = 0.96
            breathing.toValue = 1.06
            breathing.duration = 0.62
            breathing.autoreverses = true
            breathing.repeatCount = .infinity
            breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            centerIcon.layer?.add(breathing, forKey: "voicePointer.waveform")

        case .idle, .failed:
            break
        }
    }

    private func addPulse(to layer: CAShapeLayer, delay: CFTimeInterval) {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.86
        scale.toValue = 1.44

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.50
        opacity.toValue = 0

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 1.15
        group.repeatCount = .infinity
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "voicePointer.pulse")
    }

    /// Five low-cost procedural bars. The timer is capped at 24 fps and uses
    /// quick attack / slower decay to suggest live audio without microphone access.
    private func waveformTick() {
        waveformPhase += 0.22
        updateWaveforms()
    }

    private func updateWaveforms() {
        let amplitudes: [CGFloat] = [0.42, 0.72, 1.0, 0.68, 0.38]
        for (index, layer) in waveformLayers.enumerated() {
            let w = layer.bounds.width
            let h = layer.bounds.height
            let x = CGFloat(index + 1) * w / 6
            let rawPhase = (waveformPhase + CGFloat(index) * 0.9)
                .truncatingRemainder(dividingBy: CGFloat.pi * 2)
            let normalized = rawPhase >= 0 ? rawPhase : rawPhase + CGFloat.pi * 2
            let progress = normalized / (CGFloat.pi * 2)
            let wave = progress < 0.25
                ? progress / 0.25
                : max(0, 1 - (progress - 0.25) / 0.75)
            let height = 8 + 20 * amplitudes[index] * wave
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: h / 2 - height / 2))
            path.addLine(to: CGPoint(x: x, y: h / 2 + height / 2))
            layer.path = path
        }
    }

    private func symbol(named name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private static func circle(_ rect: CGRect, contains point: CGPoint) -> Bool {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        let radius = rect.width / 2
        return dx * dx + dy * dy <= radius * radius
    }
}

private extension VoiceReleaseAction {
    var isUndo: Bool {
        switch self {
        case .cancel: true
        case .stop, .send: false
        }
    }
}
