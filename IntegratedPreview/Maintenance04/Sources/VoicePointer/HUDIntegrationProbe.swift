import AppKit
import SwiftUI
import VoicePointerCore

@MainActor
private enum HUDInlinePolicyProbe {
    static func run(at center: CGPoint) async -> String {
        var failures: [String] = []
        for directed in [true, false] {
            let monitor = HUDProbeMicrophoneMonitor()
            let hud = StatusHUD(capturesMicrophoneLevels: false, microphoneLevelMonitor: monitor,
                reduceMotionProvider: { true }, skinProvider: { .classic })
            hud.update(status: .listening, quartzPoint: center, allowsDirectedRelease: directed)
            let stops = monitor.stopCount
            hud.showInlinePolicyNotice()
            try? await Task.sleep(for: .milliseconds(2100))
            if !monitor.isRunning || monitor.stopCount != stops || !hud.previewDiagnostics().contains("visible=true") {
                failures.append("notice interrupted listening")
            }
            hud.cancelGesture()
        }
        let hud = StatusHUD(capturesMicrophoneLevels: false, reduceMotionProvider: { true })
        hud.update(status: .failed("fixture"), quartzPoint: center)
        let announcements = hud.previewAnnouncementCount
        hud.showInlinePolicyNotice()
        try? await Task.sleep(for: .milliseconds(2150))
        if hud.previewAnnouncementCount != announcements + 1 || !hud.previewDiagnostics().contains("visible=true") {
            failures.append("one released demotion notice")
        }
        hud.cancelGesture()
        let suite = "VoicePointerInlineSectionProbe." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return "HUDInlinePolicyProbe: FAIL fixture" }
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = InlineWriteRuntime(defaults: defaults)
        for bundle in InlineWritePolicy.chromiumAllowlist.sorted() {
            runtime.noteWrite(bundle: bundle)
            runtime.noteFailure(bundle: bundle, reason: .sendStillPresent)
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cache/r59-1-release", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let host = NSHostingView(rootView: Form { InlineDemotedApplicationsSection(runtime: runtime) }
                    .formStyle(.grouped).tint(OnboardingStyle.accent))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 260),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(150))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    failures.append("settings bitmap"); continue
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    failures.append("settings png"); continue
                }
                try png.write(to: directory.appendingPathComponent("inline-recovery-\(name).png"))
                window.orderOut(nil)
            }
        } catch { failures.append("settings render") }
        return failures.isEmpty ? "HUDInlinePolicyProbe: PASS cases=3 realMicrophone=0 fixtureScreenshots=2" :
            "HUDInlinePolicyProbe: FAIL " + failures.joined(separator: ", ")
    }
}

@MainActor
private final class HUDProbeMicrophoneMonitor: MicrophoneLevelMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var readCount = 0
    private(set) var isRunning = false
    var hasStartIntent: Bool { isRunning }
    var sampleLevel: Float = 0.05
    var onStop: () -> Void = {}

    var level: Float {
        readCount += 1
        return sampleLevel
    }

    func start() {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
        onStop()
    }
}

@MainActor
private enum HUDSendSoundReleaseProbe {
    static func run(at center: CGPoint, sendPoint: CGPoint) -> String {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }

        let activity = GestureSpeechActivity.shared
        defer { activity.beginGesture() }
        let previousBusMode = MicrophoneLevelMonitor.usesRecognizerBus
        MicrophoneLevelMonitor.usesRecognizerBus = true
        let busMonitor = MicrophoneLevelMonitor()
        CaptureLevelBus.shared.invalidate()
        CaptureLevelBus.shared.captureBegan()
        busMonitor.start()
        let count = busMonitor.sampleCount
        CaptureLevelBus.shared.publish(0.05)
        check(busMonitor.isRunning && busMonitor.hasStartIntent && busMonitor.level == 0.05 && busMonitor.sampleCount == count + 1,
              "F1 production monitor reads only recognition bus")
        check(activity.heard() == .speech, "F1 gesture silence decision uses capture bus")
        busMonitor.stop()
        check(!busMonitor.hasStartIntent, "F1 production bus monitor stops")
        CaptureLevelBus.shared.captureEnded()
        CaptureLevelBus.shared.invalidate()
        MicrophoneLevelMonitor.usesRecognizerBus = previousBusMode
        let cases: [(name: String, peak: Float?, heard: SpeechHeard, events: [String])] = [
            ("silence", 0.01, .silence, ["stop", "heard:silence"]),
            ("speech", 0.05, .speech, ["stop", "heard:speech", "sound"]),
            ("unknown", nil, .unknown, ["stop", "heard:unknown", "sound"]),
        ]
        for test in cases {
            activity.beginGesture()
            let monitor = HUDProbeMicrophoneMonitor()
            let hud = StatusHUD(
                capturesMicrophoneLevels: false,
                microphoneLevelMonitor: monitor,
                reduceMotionProvider: { true },
                hapticPerformer: { _ in },
                hapticStrengthProvider: { .standard },
                skinProvider: { .classic }
            )
            // No beginGesture(): the probe never prepares or plays a real sound.
            hud.update(status: .resolvingTarget, quartzPoint: center)
            hud.update(status: .listening, quartzPoint: center)
            check(hud.track(quartzPoint: sendPoint) == .send, "\(test.name) arms visible send")
            check(activity.heard() == .unknown, "\(test.name) summary pending before stop")
            var events: [String] = []
            let stopCount = monitor.stopCount
            monitor.onStop = {
                events.append("stop")
                if let peak = test.peak { activity.recordCapture(peakLevel: peak) }
            }
            let action = hud.releaseAction(
                at: center,
                heardSpeech: {
                    let heard = activity.heard()
                    events.append("heard:\(heard)")
                    return heard
                },
                playSendSound: { events.append("sound") }
            )
            check(events == test.events, "\(test.name) exact stop/heard/sound order: \(events)")
            check(activity.heard() == test.heard, "\(test.name) finalized same heard source")
            check(action == .send, "\(test.name) preserves visible release decision")
            check(!monitor.isRunning && monitor.stopCount == stopCount + 1 && !hud.previewLevelUpdatesActive,
                  "\(test.name) stops same monitor exactly once")
            monitor.onStop = {}
            hud.cancelGesture()
        }
        return failures.isEmpty ? "HUDSendSoundReleaseProbe: PASS cases=3 realMicrophone=0" :
            "HUDSendSoundReleaseProbe: FAIL " + failures.joined(separator: ", ")
    }
}

@MainActor
private enum HUDMicrophoneLifecycleProbe {
    static func run(at center: CGPoint) async -> String {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }

        let summary = MicrophoneLevelSummary(samples: [0.1, 0.2, 0.3, 0.4, 1.0])
        check(summary?.count == 5 && summary?.p50 == 0.3 && summary?.p95 == 1.0 && summary?.maximum == 1.0,
              "numeric session summary percentiles")
        check(MicrophoneLevelSummary(samples: []) == nil, "empty level summary is omitted")

        // Standalone skins keep live level updates even when reduced motion
        // disables the classic radial waveform timer. A fake monitor keeps
        // this regression independent of microphone permission and hardware.
        var monitoredSkin: HUDSkinID = .frosted
        let probeMonitor = HUDProbeMicrophoneMonitor()
        let levelHUD = StatusHUD(
            capturesMicrophoneLevels: false,
            microphoneLevelMonitor: probeMonitor,
            reduceMotionProvider: { true },
            skinProvider: { monitoredSkin }
        )
        levelHUD.beginGesture(deviceKind: .builtInTrackpad)
        levelHUD.update(status: .resolvingTarget, quartzPoint: center)
        levelHUD.update(status: .listening, quartzPoint: center)
        levelHUD.update(status: .listening, quartzPoint: center)
        try? await Task.sleep(for: .milliseconds(90))
        check(probeMonitor.isRunning && probeMonitor.startCount == 1,
              "StatusHUD starts hidden radial monitor with reduce motion")
        check(levelHUD.previewDiagnostics().contains("skin=frosted") &&
              levelHUD.previewDiagnostics().contains("visible=true"),
              "standalone skin remains visible with reduce motion")
        check(probeMonitor.readCount > 0, "standalone level polling reads monitor")
        check(levelHUD.previewLevelUpdatesActive,
              "standalone level task stays active with reduce motion")

        _ = levelHUD.releaseAction(at: center)
        check(!probeMonitor.isRunning && !levelHUD.previewLevelUpdatesActive,
              "release stops microphone and level task")
        levelHUD.update(status: .idle, quartzPoint: nil)

        levelHUD.beginGesture(deviceKind: .builtInTrackpad)
        levelHUD.update(status: .resolvingTarget, quartzPoint: center)
        levelHUD.update(status: .listening, quartzPoint: center)
        check(probeMonitor.isRunning, "second listening session starts monitor")
        levelHUD.update(status: .idle, quartzPoint: nil)
        check(!probeMonitor.isRunning && !levelHUD.previewLevelUpdatesActive,
              "idle hides HUD and stops monitor")

        levelHUD.beginGesture(deviceKind: .builtInTrackpad)
        levelHUD.update(status: .resolvingTarget, quartzPoint: center)
        levelHUD.update(status: .listening, quartzPoint: center)
        levelHUD.update(status: .failed("探针失败"), quartzPoint: center)
        check(!probeMonitor.isRunning && !levelHUD.previewLevelUpdatesActive,
              "failure stops monitor and level task")
        levelHUD.cancelGesture()

        levelHUD.beginGesture(deviceKind: .builtInTrackpad)
        levelHUD.update(status: .resolvingTarget, quartzPoint: center)
        levelHUD.update(status: .listening, quartzPoint: center, allowsDirectedRelease: false)
        levelHUD.complete(feedback: ComposerActionFeedback(
            message: "探针完成", kind: .info
        ), action: .stop)
        check(!probeMonitor.isRunning && !levelHUD.previewLevelUpdatesActive,
              "completion stops monitor and level task")

        levelHUD.beginGesture(deviceKind: .builtInTrackpad)
        levelHUD.update(status: .resolvingTarget, quartzPoint: center)
        levelHUD.update(status: .listening, quartzPoint: center)
        levelHUD.cancelGesture()
        check(!probeMonitor.isRunning && !levelHUD.previewLevelUpdatesActive,
              "cancel stops monitor and level task")

        levelHUD.beginGesture(deviceKind: .builtInTrackpad)
        levelHUD.update(status: .resolvingTarget, quartzPoint: center)
        levelHUD.update(status: .listening, quartzPoint: center)
        monitoredSkin = .classic
        levelHUD.update(status: .resolvingTarget, quartzPoint: center)
        check(!probeMonitor.isRunning && !levelHUD.previewLevelUpdatesActive,
              "skin switch stops prior monitor and task")
        levelHUD.update(status: .listening, quartzPoint: center)
        check(probeMonitor.isRunning, "classic listening still owns the same monitor")
        levelHUD.update(status: .listening, quartzPoint: center, allowsDirectedRelease: false)
        levelHUD.complete(feedback: ComposerActionFeedback(outcome: .kept), action: .stop)
        check(!probeMonitor.isRunning && !levelHUD.previewLevelUpdatesActive,
              "silent completion hides HUD and stops monitor")

        return failures.isEmpty ? "HUDMicrophoneLifecycleProbe: PASS" :
            "HUDMicrophoneLifecycleProbe: FAIL " + failures.joined(separator: ", ")
    }
}

/// Exercises the normal hide entry points with an injected actuator. Open,
/// Close/release and delayed pulses are synthetic; no driver or clock is used.
@MainActor
enum HUDHapticLifecycleProbe {
    private final class Actuator: HapticActuatorPerforming {
        var defersOpen = false
        var pendingOpen: (@MainActor @Sendable (Bool) -> Void)?
        private var hasHandle = false
        private(set) var closeRequests = 0
        private(set) var closeCount = 0
        private(set) var releaseCount = 0
        private(set) var pulses: [Int32] = []

        func open(deviceID: UInt64, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
            hasHandle = true
            if defersOpen { pendingOpen = completion }
            else { completion(true) }
        }

        func actuate(id: Int32, lease: HapticPulseLease, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
            guard hasHandle, !lease.isCancelled else { completion(false); return }
            pulses.append(id)
            completion(true)
        }

        func close() {
            closeRequests += 1
            guard hasHandle else { return }
            hasHandle = false
            closeCount += 1
            releaseCount += 1
        }
    }

    static func run() -> String {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }

        for completion in 0..<3 {
            let name = completion == 2 ? "failure" : completion == 1 ? "silent completion" : "idle"
            let actuator = Actuator()
            var pending: [@MainActor @Sendable () -> Void] = []
            var systemPulses = 0
            let feedback = ZoneHapticFeedback(actuator: actuator,
                schedule: { _, action in pending.append(action) },
                systemPerform: { systemPulses += 1 }, log: { _ in })
            let hud = StatusHUD(capturesMicrophoneLevels: false,
                reduceMotionProvider: { true }, hapticFeedback: feedback,
                hapticStrengthProvider: { .max }, skinProvider: { .classic })
            // Begin the injected lifecycle directly: beginGesture also prepares
            // sound output, which this resource-only regression never needs.
            feedback.begin(deviceKind: .builtInTrackpad, deviceID: 17)
            feedback.trigger(zone: .cancel, strength: .max)
            check(actuator.pulses == [6] && pending.count == 2, "\(name) opened with pending pulses")
            let requestsBeforeHide = actuator.closeRequests
            let hide = {
                if completion == 2 {
                    hud.update(status: .failed("syntheticFailure"), quartzPoint: nil)
                } else if completion == 1 {
                    hud.complete(feedback: ComposerActionFeedback(outcome: .kept), action: .stop)
                } else {
                    hud.update(status: .idle, quartzPoint: nil)
                }
            }
            hide()
            check(actuator.closeRequests == requestsBeforeHide + 1 &&
                  actuator.closeCount == 1 && actuator.releaseCount == 1,
                  "\(name) hide closes and releases opened actuator")
            hide()
            check(actuator.closeCount == 1 && actuator.releaseCount == 1,
                  "\(name) double hide closes and releases once")
            pending.forEach { $0() }
            feedback.trigger(zone: .send, strength: .max)
            check(actuator.pulses == [6] && systemPulses == 0,
                  "\(name) hide cancels queued pulses and ends gesture")
        }

        let actuator = Actuator()
        actuator.defersOpen = true
        var pending: [@MainActor @Sendable () -> Void] = []
        var systemPulses = 0
        let feedback = ZoneHapticFeedback(actuator: actuator,
            schedule: { _, action in pending.append(action) },
            systemPerform: { systemPulses += 1 }, log: { _ in })
        let hud = StatusHUD(capturesMicrophoneLevels: false,
            reduceMotionProvider: { true }, hapticFeedback: feedback,
            hapticStrengthProvider: { .strong }, skinProvider: { .classic })
        feedback.begin(deviceKind: .externalTrackpad, deviceID: 39)
        feedback.trigger(zone: .send, strength: .strong)
        check(systemPulses == 1 && pending.count == 1, "pending open uses fallback")
        let requestsBeforeHide = actuator.closeRequests
        hud.update(status: .idle, quartzPoint: nil)
        actuator.pendingOpen?(true)
        actuator.pendingOpen = nil
        pending.forEach { $0() }
        feedback.trigger(zone: .send, strength: .strong)
        check(actuator.closeRequests == requestsBeforeHide + 1 &&
              actuator.closeCount == 1 && actuator.releaseCount == 1,
              "hide closes and releases pending open")
        check(systemPulses == 1 && actuator.pulses.isEmpty,
              "late open cannot revive hidden gesture or queued fallback")

        return failures.isEmpty ? "HUDHapticLifecycleProbe: PASS" :
            "HUDHapticLifecycleProbe: FAIL " + failures.joined(separator: ", ")
    }
}

/// Small deterministic smoke probe for the HUD contract. It intentionally uses
/// only public StatusHUD APIs and never requests input or accessibility access.
@MainActor
enum HUDIntegrationProbe {
    static func run() async -> String {
        if CommandLine.arguments.contains("--self-test-hud-inline-policy-only") {
            let result = await HUDInlinePolicyProbe.run(at: quartzPoint(offsetY: 0))
            return result.hasPrefix("HUDInlinePolicyProbe: PASS") ? "HUDIntegrationProbe: PASS \(result)" : "HUDIntegrationProbe: FAIL \(result)"
        }
        if CommandLine.arguments.contains("--self-test-hud-send-release-only") {
            // This narrow probe must not open the user's runtime diagnostic file.
            RuntimeTrace.suspendForDataRemoval()
            let result = HUDSendSoundReleaseProbe.run(
                at: quartzPoint(offsetY: 0), sendPoint: quartzPoint(offsetY: 58)
            )
            return result.hasPrefix("HUDSendSoundReleaseProbe: PASS")
                ? "HUDIntegrationProbe: PASS \(result)"
                : "HUDIntegrationProbe: FAIL \(result)"
        }
        if CommandLine.arguments.contains("--self-test-hud-microphone-only") {
            let result = await HUDMicrophoneLifecycleProbe.run(at: quartzPoint(offsetY: 0))
            return result.hasPrefix("HUDMicrophoneLifecycleProbe: PASS")
                ? "HUDIntegrationProbe: PASS \(result)"
                : "HUDIntegrationProbe: FAIL \(result)"
        }
        let hapticLifecycleResult = HUDHapticLifecycleProbe.run()
        if CommandLine.arguments.contains("--self-test-hud-haptic-only") {
            return hapticLifecycleResult.hasPrefix("HUDHapticLifecycleProbe: PASS")
                ? "HUDIntegrationProbe: PASS \(hapticLifecycleResult)"
                : "HUDIntegrationProbe: FAIL \(hapticLifecycleResult)"
        }
        var hapticPatterns: [NSHapticFeedbackManager.FeedbackPattern] = []
        let hud = StatusHUD(
            capturesMicrophoneLevels: false,
            hapticPerformer: { hapticPatterns.append($0) },
            hapticStrengthProvider: { .standard }
        )
        var failures: [String] = []
        if !hapticLifecycleResult.hasPrefix("HUDHapticLifecycleProbe: PASS") {
            failures.append(hapticLifecycleResult)
        }
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }

        let center = quartzPoint(offsetY: 0)
        let upper = quartzPoint(offsetY: 58)
        let lower = quartzPoint(offsetY: -58)
        let upperHysteresisEdge = quartzPoint(offsetY: 31)
        let upperNeutral = quartzPoint(offsetY: 29)
        let lowerPreBoundary = quartzPoint(offsetY: -39)

        let releaseSoundResult = HUDSendSoundReleaseProbe.run(at: center, sendPoint: upper)
        check(releaseSoundResult.hasPrefix("HUDSendSoundReleaseProbe: PASS"), releaseSoundResult)

        hud.update(status: .resolvingTarget, quartzPoint: center)
        check(hud.previewDiagnostics().contains("visible=true"), "admission immediately visible")
        check(hud.previewDiagnostics().contains("preparingSpinner=false"), "no preparing spinner")
        check(hud.previewDiagnostics().contains("presentationAnimation=false"), "no presentation delay")
        check(hud.track(quartzPoint: upper) == .stop, "preparing cannot select send")

        hud.beginGesture(deviceKind: .builtInTrackpad)
        hud.update(status: .listening, quartzPoint: center)
        check(hud.previewDiagnostics().contains("visible=true"), "listening visible")
        check(hud.previewDiagnostics().contains("{296, 296}"), "transparent host 296x296")
        check(hud.previewDiagnostics().contains("assets=5/5"), "Figma assets loaded")
        let quietLevel = RadialHUDView.normalizedAudioLevel(0.005)
        let speechLevel = RadialHUDView.normalizedAudioLevel(0.05)
        let loudLevel = RadialHUDView.normalizedAudioLevel(0.20)
        check(quietLevel == 0, "waveform quiet gate")
        check(speechLevel > 0.30, "waveform speech sensitivity")
        check(loudLevel > speechLevel && loudLevel <= 1, "waveform level range")
        // Ken's built-in microphone (2026-11-10): room ~0.0005, speech 0.004-0.02. The shaper must move for that speech
        // and stay still for the room.
        var shaper = VoiceLevelShaper()
        var shaped: [Float] = []
        for i in 0..<120 { shaped.append(shaper.next(i % 6 < 2 ? 0.0005 : (i % 6 == 3 ? 0.015 : 0.004), now: Double(i) * 0.034)) }
        let tail = shaped.suffix(60)
        check((tail.max() ?? 0) > 0.8, "shaped level reaches the top for quiet speech")
        check(tail.contains { $0 > 0.35 && $0 < 0.8 }, "shaped level has a middle for ordinary syllables")
        check(shaper.next(0.0005, now: 120 * 0.034) == 0, "shaped level is still in a quiet room")
        check(shaper.next(0, now: 121 * 0.034) == 0, "shaped level is zero without audio")
        check(hud.track(quartzPoint: center) == .stop, "center stop")
        try? await Task.sleep(for: .milliseconds(60))
        check(hapticPatterns.isEmpty, "initial center has no haptic")
        check(hud.track(quartzPoint: upper) == .send, "upper send")
        check(hapticPatterns.isEmpty, "send haptic is debounced")
        try? await Task.sleep(for: .milliseconds(60))
        check(hapticPatterns == [.levelChange], "level-change haptic on send zone entry")
        check(hud.track(quartzPoint: upper) == .send, "upper send retained")
        check(hapticPatterns.count == 1, "no repeated haptic in send zone")
        check(hud.track(quartzPoint: upperHysteresisEdge) == .send,
              "send retained at hysteresis edge")
        check(hud.track(quartzPoint: upperNeutral) == .stop,
              "wide center zone disarms send")
        try? await Task.sleep(for: .milliseconds(60))
        check(hapticPatterns == [.levelChange, .levelChange],
              "level-change haptic on center zone entry")
        check(hud.track(quartzPoint: lowerPreBoundary) == .stop,
              "center zone remains stop before cancel boundary")
        check(hud.track(quartzPoint: center) == .stop, "return center stop")
        check(hapticPatterns.count == 2, "no repeated haptic in center")
        check(hud.track(quartzPoint: lower) == .cancel, "lower cancel")
        try? await Task.sleep(for: .milliseconds(60))
        check(hapticPatterns == [.levelChange, .levelChange, .levelChange],
              "level-change haptic on cancel zone entry")
        let hapticsBeforeFastCrossing = hapticPatterns.count
        check(hud.track(quartzPoint: center) == .stop, "fast crossing enters center")
        check(
            hud.track(quartzPoint: CGPoint(x: upper.x + 800, y: upper.y)) == .send,
            "upper half-plane send"
        )
        try? await Task.sleep(for: .milliseconds(60))
        check(hapticPatterns.count == hapticsBeforeFastCrossing + 1 &&
              hapticPatterns.last == .levelChange,
              "fast center crossing suppresses center haptic")
        check(
            hud.track(quartzPoint: CGPoint(x: lower.x - 800, y: lower.y)) == .cancel,
            "lower half-plane cancel"
        )
        try? await Task.sleep(for: .milliseconds(60))
        check(hapticPatterns.count == 5 && hapticPatterns.last == .levelChange,
              "haptic when switching into cancel zone")

        check(hud.track(quartzPoint: center) == .stop, "center before release")
        let hapticsBeforeRelease = hapticPatterns.count
        check(hud.releaseAction(at: upper) == .stop, "release preserves visible center state")
        try? await Task.sleep(for: .milliseconds(60))
        check(hapticPatterns.count == hapticsBeforeRelease, "no haptic on release")
        hud.update(status: .idle, quartzPoint: nil)
        check(hud.previewDiagnostics().contains("visible=true"), "release confirmation retained")
        let announcementsBeforeSilentKept = hud.previewAnnouncementCount
        hud.complete(outcome: .kept, action: .stop)
        check(hud.previewDiagnostics().contains("visible=false"), "kept silently dismisses")
        check(hud.previewAnnouncementCount == announcementsBeforeSilentKept,
              "kept does not announce")

        let microphoneResult = await HUDMicrophoneLifecycleProbe.run(at: center)
        if !microphoneResult.hasPrefix("HUDMicrophoneLifecycleProbe: PASS") {
            failures.append(microphoneResult)
        }

        check(StatusHUD.feedbackDuration(for: .success) == 0.9, "success reading duration")
        check(StatusHUD.feedbackDuration(for: .info) == 1.2, "info reading duration")
        check(StatusHUD.feedbackDuration(for: .warning) == 2.0, "warning reading duration")
        let feedbackOutcomes: [ComposerActionOutcome] = [
            .kept, .sent, .nothingToSend, .removedCurrentDictation,
            .clearedCurrentInput, .clearArmed, .nothingToCancel, .deliveryFailed,
            .targetChanged, .unsafeToCancel, .eventPostFailed,
            .sendUnconfirmed, .sendStillPresent, .cancelUnconfirmed, .dictationNotSettled,
        ]
        for outcome in feedbackOutcomes {
            let feedback = ComposerActionFeedback(outcome: outcome)
            let announcementsBefore = hud.previewAnnouncementCount
            hud.complete(feedback: feedback, action: .stop)
            let diagnostics = hud.previewDiagnostics()
            if feedback.shouldPresent {
                check(diagnostics.contains("visible=true"), "panel visible \(outcome.rawValue)")
                check(diagnostics.contains("feedbackVisible=true"), "feedback visible \(outcome.rawValue)")
                check(diagnostics.contains("feedback=\(feedback.message)"), "feedback text \(outcome.rawValue)")
                check(hud.previewFeedbackFrame.width <= 240 && hud.previewFeedbackFrame.height <= 48,
                      "feedback bounded \(outcome.rawValue)")
                check(CGRect(x: 0, y: 0, width: 256, height: 256).contains(hud.previewFeedbackFrame),
                      "feedback inside logical bounds \(outcome.rawValue)")
            } else {
                check(diagnostics.contains("visible=false"), "silent \(outcome.rawValue) dismisses")
                check(diagnostics.contains("feedbackVisible=false"), "silent \(outcome.rawValue) has no feedback")
                check(hud.previewAnnouncementCount == announcementsBefore,
                      "silent \(outcome.rawValue) does not announce")
            }
        }
        hud.cancelGesture()

        hud.complete(feedback: ComposerActionFeedback(
            message: "警告保留",
            kind: .warning
        ), action: .stop)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        hud.update(status: .idle, quartzPoint: nil)
        check(hud.previewDiagnostics().contains("visible=true"), "warning survives coordinator idle")
        hud.beginGesture(deviceKind: .builtInTrackpad)
        hud.update(status: .listening, quartzPoint: center)
        check(hud.previewDiagnostics().contains("visible=true"), "new gesture replaces warning")
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        check(hud.previewDiagnostics().contains("visible=true"), "new gesture cancels old dismiss")
        hud.cancelGesture()

        // Regression: cancelGesture starts an NSWindow animator fade. A new
        // listening session must synchronously restore the panel and must not
        // be faded out by the previous window animation.
        hud.beginGesture(deviceKind: .builtInTrackpad)
        hud.update(status: .listening, quartzPoint: center)
        hud.cancelGesture()
        hud.update(status: .listening, quartzPoint: center)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let restoredAfterCancelFade = hud.previewDiagnostics()
        check(restoredAfterCancelFade.contains("visible=true"),
              "new listening survives prior cancel fade visibility")
        check(restoredAfterCancelFade.contains("alpha=1.0"),
              "new listening survives prior cancel fade alpha")

        // Regression: a previous feedback deadline must not dismiss a newer
        // listening session. Keep the session alive beyond the warning delay.
        hud.beginGesture(deviceKind: .builtInTrackpad)
        hud.update(status: .listening, quartzPoint: center)
        let announcementsBeforeLateCompletion = hud.previewAnnouncementCount
        hud.complete(feedback: ComposerActionFeedback(
            message: "旧反馈不应关闭新会话",
            kind: .warning
        ), action: .stop)
        check(hud.previewDiagnostics().contains("visible=true"),
              "late completion does not hide new session")
        check(hud.previewAnnouncementCount == announcementsBeforeLateCompletion,
              "late completion does not announce in new session")
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        let sustainedListening = hud.previewDiagnostics()
        check(sustainedListening.contains("visible=true"),
              "listening remains visible for eight seconds")
        check(sustainedListening.contains("alpha=1.0"),
              "listening remains opaque for eight seconds")
        hud.cancelGesture()

        let reducedHUD = StatusHUD(
            capturesMicrophoneLevels: false,
            reduceMotionProvider: { true }
        )
        reducedHUD.complete(feedback: ComposerActionFeedback(
            message: "减弱动态仍可读",
            kind: .warning
        ), action: .stop)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        check(reducedHUD.previewDiagnostics().contains("visible=true"), "reduce motion keeps duration")
        reducedHUD.cancelGesture()

        let announcementsBeforeSilentSent = hud.previewAnnouncementCount
        hud.complete(outcome: .sent, action: .send)
        check(hud.previewDiagnostics().contains("visible=false"), "sent silently dismisses")
        check(hud.previewAnnouncementCount == announcementsBeforeSilentSent,
              "sent does not announce")

        // Match application ordering: a rejected begin publishes failure
        // before beginGesture metadata. That callback must not cancel timing.
        hud.update(status: .failed("入口失败"), quartzPoint: center)
        hud.beginGesture(deviceKind: .builtInTrackpad)
        try? await Task.sleep(for: .milliseconds(1500))
        hud.update(status: .idle, quartzPoint: nil)
        check(hud.previewDiagnostics().contains("visible=true"), "begin metadata preserves warning")
        try? await Task.sleep(for: .milliseconds(1000))
        check(hud.previewDiagnostics().contains("visible=false"), "begin warning still dismisses")

        hud.beginGesture(deviceKind: .builtInTrackpad)
        hud.update(status: .listening, quartzPoint: center)
        _ = hud.releaseAction(at: upper)
        let stableFrame = hud.previewPanelFrame
        let feedback = ComposerActionFeedback(outcome: .sendUnconfirmed)
        let announcementsBefore = hud.previewAnnouncementCount
        hud.complete(outcome: .sendUnconfirmed, action: .send)
        hud.update(status: feedback.shouldPresent ? .failed(feedback.message) : .idle,
                   quartzPoint: CGPoint(x: upper.x + 300, y: upper.y))
        check(hud.previewPanelFrame == stableFrame, "silent uncertainty keeps release anchor")
        check(hud.previewAnnouncementCount == announcementsBefore,
              "unconfirmed send does not announce a Toast")
        hud.cancelGesture()

        // Synthetic screen arrangements exercise production clamping without
        // changing the user's display configuration.
        let screens = [
            CGRect(x: 0, y: 0, width: 1512, height: 950),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 1080, width: 1280, height: 720),
        ]
        for screen in screens {
            for x in [screen.minX - 400, screen.midX, screen.maxX + 400] {
                for y in [screen.minY - 400, screen.midY, screen.maxY + 400] {
                    let origin = StatusHUD.clampedOrigin(
                        CGPoint(x: x, y: y), panelSize: RadialHUDMetrics.panelSize, visibleFrame: screen
                    )
                    check(screen.insetBy(dx: 8, dy: 8).contains(CGRect(origin: origin, size: RadialHUDMetrics.panelSize)),
                          "panel clamped to synthetic screen")
                    // Production clamps only the visible disc / widest Toast, so the disc can sit near the edge.
                    let content = StatusHUD.visibleContent(scale: 1)
                    let shown = StatusHUD.clampedOrigin(
                        CGPoint(x: x, y: y), panelSize: RadialHUDMetrics.panelSize, visibleFrame: screen, content: content
                    )
                    check(screen.insetBy(dx: 8, dy: 8).contains(content.offsetBy(dx: shown.x, dy: shown.y)),
                          "visible disc clamped to synthetic screen")
                    if y == screen.minY - 400 {
                        check(abs(shown.y + content.minY - (screen.minY + 8)) < 0.5,
                              "disc reaches 8 pt from the bottom edge")
                    }
                }
            }
        }

        hud.update(status: .failed("probe"), quartzPoint: center)
        check(hud.previewDiagnostics().contains("visible=true"), "failed visible")
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        check(hud.previewDiagnostics().contains("visible=true"), "failed remains readable")
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        check(hud.previewDiagnostics().contains("visible=false"), "failed dismiss")
        hud.cancelGesture()

        // Switching skins must keep the same hit classifier and must restore
        // the built-in dial when leaving Liquid Glass.
        var selectedSkin: HUDSkinID = .classic
        let skinHUD = StatusHUD(capturesMicrophoneLevels: false,
                                skinProvider: { selectedSkin })
        let skins: [HUDSkinID] = LiquidGlassSkin.isSupported
            ? [.classic, .liquidGlass, .frosted, .classic]
            : [.classic, .frosted, .classic]
        for skin in skins {
            selectedSkin = skin
            skinHUD.update(status: .resolvingTarget, quartzPoint: center)
            skinHUD.update(status: .listening, quartzPoint: center)
            check(skinHUD.previewDiagnostics().contains("skin=\(skin.rawValue)"),
                  "skin selection \(skin.rawValue)")
            check(skinHUD.previewBuiltInDialSurfaceHidden == (skin == .liquidGlass),
                  "skin dial restoration \(skin.rawValue)")
            check(skinHUD.previewBuiltInCoreSurfaceHidden == (skin == .liquidGlass),
                  "skin core restoration \(skin.rawValue)")
            check(skinHUD.track(quartzPoint: upper) == .send,
                  "skin send geometry \(skin.rawValue)")
            check(skinHUD.track(quartzPoint: lower) == .cancel,
                  "skin cancel geometry \(skin.rawValue)")
            check(skinHUD.releaseAction(at: lower) == .cancel,
                  "skin release \(skin.rawValue)")
            skinHUD.cancelGesture()
        }

        // The source-only check executable has no app resources. Run this
        // branch from the assembled candidate to verify its actual bundled
        // Metal sources compile and every new style keeps the same hit areas.
        if let folder = Bundle.main.resourceURL?.appendingPathComponent("HUDShaders"),
           FileManager.default.fileExists(atPath: folder.path) {
            let library = HUDShaderLibrary.shared
            library.preparePreviews()
            let deadline = Date().addingTimeInterval(30)
            let shaderSkins = HUDSkinID.shaderSkins
            while !shaderSkins.allSatisfy({ library.isPrepared($0) }), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            check(shaderSkins.allSatisfy({ library.isPrepared($0) }),
                  "bundled shader pipelines \(library.lastError ?? "pending")")
            for skin in shaderSkins where library.isPrepared(skin) {
                selectedSkin = skin
                skinHUD.update(status: .resolvingTarget, quartzPoint: center)
                skinHUD.update(status: .listening, quartzPoint: center)
                check(skinHUD.previewDiagnostics().contains("skin=\(skin.rawValue)"),
                      "shader skin selection \(skin.rawValue)")
                check(skinHUD.previewBuiltInDialViewHidden,
                      "shader dial hidden \(skin.rawValue)")
                check(skinHUD.track(quartzPoint: upper) == .send,
                      "shader send geometry \(skin.rawValue)")
                check(skinHUD.track(quartzPoint: lower) == .cancel,
                      "shader cancel geometry \(skin.rawValue)")
                skinHUD.cancelGesture()
            }
        }

        // Exercises every audible completion path long enough for playback to
        // leave the caller. This specifically guards the Core Audio realtime
        // thread isolation crash that affected the earlier implementation.
        let sounds = VoicePointerHUDSound.shared
        sounds.playSend()
        try? await Task.sleep(nanoseconds: 650_000_000)
        sounds.playCancel()
        try? await Task.sleep(nanoseconds: 950_000_000)

        return failures.isEmpty ? "HUDIntegrationProbe: PASS" :
            "HUDIntegrationProbe: FAIL " + failures.joined(separator: ", ")
    }

    private static func quartzPoint(offsetY: CGFloat) -> CGPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let appKit = CGPoint(x: screen.frame.midX, y: screen.frame.midY + offsetY)
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let normalizedY = (screen.frame.maxY - appKit.y) / screen.frame.height
        return CGPoint(x: bounds.midX, y: bounds.minY + normalizedY * bounds.height)
    }
}
