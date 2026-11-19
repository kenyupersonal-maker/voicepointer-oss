import AppKit
import AVFoundation
import CAudioMeterSupport
@_spi(Testing) import VoicePointerCore

@MainActor
final class ComposerProbeTextView: NSTextView {
    private(set) var receivedReturnCount = 0

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36, !modifiers.contains(.shift) {
            receivedReturnCount += 1
            string = ""
            setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        super.keyDown(with: event)
    }
}

@main
@MainActor
final class VoicePointerApplication: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum MenuTag: Int {
        case status = 100
        case enabled = 101
        case permission = 102
        case trackpad = 103
        case clickFallback = 104
        case settings = 105
        case routes = 106
        case focusSmart = 201
        case focusCurrent = 202
        case focusVoiceOnly = 203
        case voiceHold = 301
        case voiceToggle = 302
        case routeDoubao = 401
        case routeQwen17 = 402
        case routeQwen06 = 403
        case routeAliyun = 404
    }

    private let settings = SettingsStore.shared
    private let touchDriver = MultitouchDriver()
    private let hud = StatusHUD()
    private lazy var hangWatchdog = MainThreadHangWatchdog(onRecovered: { [weak self] in
        Task { @MainActor [weak self] in self?.reconcileHUDIfSessionEnded() }
    })
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var coordinator: VoicePointerCoordinator?
    private var gestureMonitor: OrderedMouseGestureMonitor?
    private var gestureAdapter: GestureMainQueueAdapter?
    private var touchService: TouchRuntimeService?
    private let keyboardOwnership = KeyboardOwnershipManager()
    private let admission = GestureAdmissionAuthority(initial: .init(enabled: false, acceptingNewGestures: false, permissionsGranted: false))
    private var heartbeatTimer: Timer?
    private var runtimeTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var pendingSendOwner: UUID?
    private var queuedGestureMessages: [GestureEventMessage] = []
    /// A later same-field upward gesture is classified before old-send queue replay.
    /// While undecided its events stay in RAM, not admitted as a new session.
    private var pendingDoubaoSecondGesture: [GestureEventMessage] = []
    private var rejectedDeferredGestures: Set<UInt64> = []
    private var sendQueueTask: Task<Void, Never>?
    private var runtimeEpoch: UInt64 = 0
    private var stopRequestPending = false
    private var armedAdmissionGeneration: UInt64 = 0
    private var activeGestureID: UInt64?
    private var terminationPending = false
    private var runtimeStatus: VoicePointerRuntimeStatus = .idle
    private var pendingOutputDuckingNotice = false
    private var appEnabled = UserDefaults.standard.bool(forKey: "voicePointer.preview.startEnabled")
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var permissionSettingsPageVisible = false
    private struct PermissionSnapshot: Sendable, Equatable {
        var accessibility = false
        var listen = false
        var post = false
        var conflict = false
        var foregroundBundleID: String?
        var granted: Bool { accessibility && listen && post }
    }
    private let permissionScanQueue = DispatchQueue(label: "com.kenyu.voicepointer.permission-scan", qos: .utility)
    private var permissionSnapshot = PermissionSnapshot()
    private var permissionScanInFlight = false
    private var permissionScanAgain = false
    private var permissionStablePolls = 0
    private var permissionAlertShown = false
    private var permissionAlertPending = false
    private var recoveryGate = RuntimeRecoveryGate()
    private enum RuntimeArmState { case stopped, arming, armed, stopping }
    private var runtimeArmState: RuntimeArmState = .stopped
    private static let requiredPermissionStablePolls = 1
    private var nextRuntimeRecoveryAttempt = Date.distantPast
    private var runtimeRecoveryBackoff: TimeInterval = 0.5
    private var hardwareTimer: Timer?
    private var touchTelemetryTimer: Timer?
    private var lastMultitouchServiceCount = -1
    private var lastTouchTelemetry: [UInt: String] = [:]
    private var providerSettingsController: ProviderSettingsController?
    private var firstRunWindow: FirstRunWindow?
    private var preparedMenuLocalRoutes: Set<String> = []
    private var routeReadinessInFlight = false
    private var menuCloudPage = CloudEntryPageState()
    private var menuCloudRefreshInFlight = false
    private var menuCloudSelectionInFlight = false
    private var lastMenuProjectionTrace: String?
    private var lastForegroundBundleID: String?

    static func main() {
        if CommandLine.arguments.contains("--self-test-main-menu") {
            let result = StandardApplicationMenu.selfCheck(in: NSApplication.shared)
            print(result)
            fflush(stdout)
            Foundation.exit(result.hasPrefix("ApplicationMenuProbe: PASS") ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        // T12 fixed, explicit uninstall helper: no delegate instance, settings load, listeners or capture.
        if CommandLine.arguments.contains("--unregister-login-item-for-uninstall") {
            guard CommandLine.arguments.count == 3, CommandLine.arguments.contains("--confirmed-data-removal") else { Foundation.exit(64) }
            let processes = NSRunningApplication.runningApplications(withBundleIdentifier: LoginItemService.officialBundleIdentifier)
                .filter { !$0.isTerminated }.map {
                    AppDataProcessGuard.Identity(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                        bundlePath: $0.bundleURL?.standardizedFileURL.path, executablePath: $0.executableURL?.standardizedFileURL.path)
                }
            guard AppDataProcessGuard.mayUninstall(processes, helperPID: ProcessInfo.processInfo.processIdentifier) else { Foundation.exit(65) }
            Task { @MainActor in
                do {
                    try await LoginItemService.shared.unregisterForUninstall()
                    print("event=uninstall_login_item,status=passed")
                    Foundation.exit(EXIT_SUCCESS)
                } catch {
                    print("event=uninstall_login_item,status=failed")
                    Foundation.exit(EXIT_FAILURE)
                }
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--self-test-settings-logic") {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            Task { @MainActor in
                let passed = await SettingsLogicRuntimeProbe.run()
                fflush(stdout)
                Foundation.exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            application.run()
            return
        }
        if CommandLine.arguments.contains(where: {
            $0.hasPrefix("--self-test-") || $0.hasPrefix("--probe-") || $0.hasPrefix("--preview-hud")
        }) {
            RuntimeTrace.configureForTesting(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("VoicePointerProbe-\(UUID().uuidString).log"))
        }
#if VOICEPOINTER_TEST_ENTRY
        if CommandLine.arguments.contains("--self-test-t34-entry") {
            T34TestEntry.launch()
            return
        }
#endif
        if CommandLine.arguments.contains("--diagnose-touch") {
            runTouchDiagnostics()
            return
        }
        if CommandLine.arguments.contains("--diagnose-focus") {
            runFocusDiagnostics()
            return
        }
        if CommandLine.arguments.contains("--self-test-runtime") {
            runRuntimeSelfTest()
            return
        }
        if CommandLine.arguments.contains("--self-test-main-hang-watchdog") {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            Task { @MainActor in
                let result = await MainThreadHangWatchdogProbe.run()
                print(result)
                fflush(stdout)
                Foundation.exit(result.hasPrefix("MainHangWatchdogProbe: PASS") ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            application.run()
            return
        }
        if CommandLine.arguments.contains("--self-test-ordered-runtime") {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.schedule(deadline: .now() + 30)
            watchdog.setEventHandler { Foundation.exit(EXIT_FAILURE) }
            watchdog.resume()
            Task { @MainActor in
                let result = await OrderedRuntimeProbe.run()
                watchdog.cancel()
                print(result)
                fflush(stdout)
                Foundation.exit(result.hasPrefix("OrderedRuntimeProbe: PASS") ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            application.run()
            return
        }
        if CommandLine.arguments.contains("--self-test-hud") {
            runHUDIntegrationProbe()
            return
        }
        if CommandLine.arguments.contains("--self-test-audio-meter") {
            runAudioMeterProbe()
            return
        }
        if CommandLine.arguments.contains("--probe-recognition-microphones") {
            runRecognitionMicrophoneProbe()
            return
        }
        if CommandLine.arguments.contains("--probe-voice-shortcut") {
            runVoiceShortcutProbe()
            return
        }
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--preview-hud") }) {
            runHUDPreview()
            return
        }
        if CommandLine.arguments.contains("--self-test-native-delivery") {
            let prefix = "--composer-editor="
            guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
                  let path = arg.split(separator: "=", maxSplits: 1).last.map(String.init),
                  path.hasPrefix("/") else {
                print("NativeDeliveryProbe: FAIL stage=args missing --composer-editor=ABS_PATH")
                fflush(stdout)
                exit(1)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.finishLaunching()
            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            watchdog.schedule(deadline: .now() + 60)
            watchdog.setEventHandler { @Sendable in
                FileHandle.standardError.write(Data("VoicePointerApplication: watchdog timeout, exiting\n".utf8))
                exit(1)
            }
            watchdog.resume()
            Task { @MainActor in
                let result = await NativeDeliveryProbe.run(editorExecutable: path)
                watchdog.cancel()
                print(result)
                fflush(stdout)
                exit(result.hasPrefix("NativeDeliveryProbe: PASS") ? 0 : 1)
            }
            NSApp.run()
            return
        }
        if CommandLine.arguments.contains("--self-test-composer-actions") {
            guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--composer-editor=") }) else {
                fputs("FAIL composer probe requires --composer-editor=/absolute/path/to/RemoteComposerEditor\n", stderr)
                Foundation.exit(EXIT_FAILURE)
            }
            RuntimeTrace.configureForTesting(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("VoicePointerRemoteComposerProbe-\(UUID().uuidString).log"))
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            watchdog.schedule(deadline: .now() + 90)
            watchdog.setEventHandler { @Sendable in
                FileHandle.standardError.write(Data("RemoteComposerProbe: watchdog timeout\n".utf8))
                Foundation.exit(EXIT_FAILURE)
            }
            watchdog.resume()
            let editorPath = String(argument.dropFirst("--composer-editor=".count))
            Task { @MainActor in
                let result = CommandLine.arguments.contains("--secure-field-probe")
                    ? await RemoteComposerProbe.runSecure(editorExecutable: editorPath)
                    : await RemoteComposerProbe.run(editorExecutable: editorPath)
                watchdog.cancel()
                print(result)
                fflush(stdout)
                Foundation.exit(result.hasPrefix("RemoteComposerProbe: PASS") ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            application.run()
            return
        }
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--watch-touch=") }),
           let seconds = Double(argument.split(separator: "=").last ?? "") {
            watchTouchFrames(for: min(max(seconds, 1), 60))
            return
        }
        let application = NSApplication.shared
        let delegate = VoicePointerApplication()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--self-test-application-lifecycle") {
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                fputs("ApplicationLifecycleProbe: FAIL timeout phase=\(ApplicationLifecycleProbeState.shared.phase)\n", stderr)
                Foundation.exit(EXIT_FAILURE)
            }
        }
        // NSApplication's delegate is weak. Keep it alive through the run loop,
        // including Objective-C termination callbacks in optimized builds.
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func runTouchDiagnostics() {
        let driver = MultitouchDriver()
        let persistedShortcut = SettingsStore.shared.value.voiceShortcut
        let started = driver.start()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        print("started=\(started)")
        print("accessibility=\(AccessibilityPermission.isTrusted ? "granted" : "missing")")
        print("inputMonitoring=\(EventAccessPermission.canListen ? "granted" : "missing")")
        print("eventPosting=\(EventAccessPermission.canPost ? "granted" : "missing")")
        print("voiceShortcut=leftOption expectedKeyCode=58 actualKeyCode=\(persistedShortcut.keyCode)")
        print("secureInput=\(SecureInputGuard.isEnabled ? "enabled" : "disabled")")
        print("iokitServices=\(driver.connectedServiceCount)")
        print(driver.status)
        for (index, device) in driver.devices.enumerated() {
            print("device[\(index)] kind=\(device.kind.rawValue) family=0x\(String(device.familyID, radix: 16)) sensor=\(device.sensorRows)x\(device.sensorColumns) touches=\(device.touchCount) rawTouches=\(device.rawTouchCount) callbacks=\(device.callbackCount) stages=0x\(String(device.stageMask, radix: 16)) delta=\(String(format: "%.4f", device.directionalDisplacement.x)),\(String(format: "%.4f", device.directionalDisplacement.y))")
        }
        let monitor = MouseGestureMonitor(
            driver: driver,
            configuration: .init(),
            onBegin: { _ in true },
            onEnd: { _ in },
            onCancel: {}
        )
        do {
            try monitor.start()
            print("eventTap=active")
            monitor.stop()
        } catch {
            print("eventTap=unavailable error=\(error.localizedDescription)")
        }
        print("reload=\(driver.reload())")
        driver.stop()
    }

    private static func runFocusDiagnostics() {
        guard AccessibilityPermission.isTrusted else {
            print("outcome=unavailable accessibility=missing")
            return
        }
        guard let point = CGEvent(source: nil)?.location else {
            print("outcome=unavailable pointer=missing")
            return
        }
        let engine = SmartFocusEngine(provider: MacOSAccessibilityProvider())
        let result = engine.focus(at: point, mode: .smart)
        print("pointer=\(Int(point.x)),\(Int(point.y))")
        print("outcome=\(String(describing: result.outcome))")
        if let candidate = result.candidate {
            print("candidate role=\(candidate.role) label=\(candidate.label) frame=\(candidate.frame) score=\(result.score ?? 0)")
        }
    }

    private static func runHUDPreview() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        let hud = StatusHUD(capturesMicrophoneLevels: false)
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        var location = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--preview-hud-point=") }) {
            let values = argument.dropFirst("--preview-hud-point=".count).split(separator: ",")
            if values.count == 2, let x = Double(values[0]), let y = Double(values[1]), x.isFinite, y.isFinite {
                location = CGPoint(x: x, y: y)
            }
        }
        let previewDuration = CommandLine.arguments
            .first(where: { $0.hasPrefix("--preview-hud-duration=") })
            .flatMap { Double($0.dropFirst("--preview-hud-duration=".count)) }
            .map { $0.isFinite ? min(max($0, 1), 30) : 5 } ?? 5
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--preview-hud-outcome=") }),
           let outcome = ComposerActionOutcome(rawValue: String(argument.dropFirst("--preview-hud-outcome=".count))) {
            // Exercise the actual release -> completion -> coordinator status
            // ordering, without starting any runtime or posting input events.
            hud.update(status: .listening, quartzPoint: location)
            _ = hud.releaseAction(at: location)
            hud.complete(outcome: outcome, action: .stop)
            let feedback = ComposerActionFeedback(outcome: outcome)
            hud.update(
                status: feedback.shouldPresent && feedback.kind == .warning ? .failed(feedback.message) : .idle,
                quartzPoint: location
            )
            print("HUDPreview \(hud.previewDiagnostics())")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + previewDuration) {
                hud.cancelGesture()
                application.terminate(nil)
            }
            application.run()
            return
        }
        if CommandLine.arguments.contains("--preview-hud-failed") {
            hud.update(status: .failed("未找到可编辑输入框"), quartzPoint: location)
            print("HUDPreview \(hud.previewDiagnostics())")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + previewDuration) {
                hud.cancelGesture()
                application.terminate(nil)
            }
            application.run()
            return
        }
        hud.update(status: .listening, quartzPoint: location)
        let previewPoint: CGPoint
        if CommandLine.arguments.contains("--preview-hud-send") {
            previewPoint = CGPoint(x: location.x, y: location.y - 58)
        } else if CommandLine.arguments.contains("--preview-hud-cancel") ||
                    CommandLine.arguments.contains("--preview-hud-undo") {
            previewPoint = CGPoint(x: location.x, y: location.y + 58)
        } else {
            previewPoint = location
        }
        _ = hud.track(quartzPoint: previewPoint)
        if CommandLine.arguments.contains("--preview-hud-toast") {
            hud.previewCenterHint("已发送")
        }
        print("HUDPreview \(hud.previewDiagnostics())")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + previewDuration) {
            hud.cancelGesture()
            application.terminate(nil)
        }
        application.run()
    }

    private static func runHUDIntegrationProbe() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        Task { @MainActor in
            let result = await HUDIntegrationProbe.run()
            print(result)
            fflush(stdout)
            Foundation.exit(result.hasPrefix("HUDIntegrationProbe: PASS") ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        application.run()
    }

    /// Runs the real AVAudioEngine tap long enough to prove that Core Audio can
    /// invoke the Swift callback repeatedly without crossing actor isolation.
    private static func runRecognitionMicrophoneProbe() {
        print("MIC_PROBE_PID=\(ProcessInfo.processInfo.processIdentifier)")
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 30)
        watchdog.setEventHandler { Foundation.exit(EXIT_FAILURE) }
        watchdog.resume()
        Task { @MainActor in
            await InputDeviceInventory.waitUntilReady()
            var allPassed = true
            let originalDefault = InputDeviceInventory.defaultInputID()
            let aggregateMode = CommandLine.arguments.contains("--probe-microphone-private-aggregate")
            var aggregate: PrivateAggregateCaptureProbe?
            var aggregateStayedBound = true
            if aggregateMode {
                do { aggregate = try await PrivateAggregateCaptureProbe.create() }
                catch {
                    print("MIC_PRIVATE_AGGREGATE created=0 destroyed=0 defaultUnchanged=\(InputDeviceInventory.defaultInputID() == originalDefault ? 1 : 0)")
                    watchdog.cancel(); fflush(stdout); Foundation.exit(EXIT_FAILURE)
                }
            }
            let inventory = InputDeviceInventory.read()
            let nondefaultProbe = aggregateMode || CommandLine.arguments.contains("--probe-microphone-nondefault")
            let builtin = aggregate.map { probe in inventory.devices.first { $0.key == probe.pinnedKey } } ?? (nondefaultProbe
                ? inventory.devices.first { $0.id != inventory.defaultID }
                : inventory.devices.first { $0.kind == .builtin })
            print("MIC_INPUT default=\(inventory.devices.first { $0.id == inventory.defaultID }?.kind.rawValue ?? "unknown") inputs=\(inventory.devices.count) nondefault=\(nondefaultProbe ? builtin?.kind.rawValue ?? "missing" : "unused")")
            if nondefaultProbe && builtin == nil {
                if let aggregate {
                    let destroyed = await aggregate.close()
                    print("MIC_PRIVATE_AGGREGATE created=1 destroyed=\(destroyed ? 1 : 0) defaultUnchanged=\(InputDeviceInventory.defaultInputID() == originalDefault ? 1 : 0)")
                    watchdog.cancel(); fflush(stdout); Foundation.exit(EXIT_FAILURE)
                }
                print("MIC_CAPTURE policy=pinned state=skippedNoSecondInput callbacks=0 nonzero=0 reopens=0 ignored=0")
                watchdog.cancel(); fflush(stdout); Foundation.exit(EXIT_SUCCESS)
            }
            let policies: [InputDevicePolicy] = nondefaultProbe ? [.pinned] : CommandLine.arguments.contains("--probe-microphone-auto-only")
                ? InputDevicePolicy.allCases.filter { $0.rawValue == "auto" } : InputDevicePolicy.allCases
            for policy in policies {
                if policy == .pinned && builtin == nil {
                    print("MIC_CAPTURE policy=pinned state=missingBuiltin callbacks=0 nonzero=0 reopens=0 ignored=0")
                    allPassed = false; continue
                }
                InputDeviceRuntime.shared.beginIntent(policyOverride: policy, pinnedOverride: policy == .pinned ? builtin?.key : nil)
                CaptureLevelBus.shared.invalidate()
                GestureSpeechActivity.shared.beginGesture()
                MicrophoneLevelMonitor.usesRecognizerBus = true
                let meter = MicrophoneLevelMonitor(), capture = RecognitionCaptureSmoke(online: CommandLine.arguments.contains("--probe-online-microphone"))
                let baseline = meter.sampleCount
                meter.start()
                do {
                    try await capture.start()
                    try await Task.sleep(for: .seconds(2))
                    let meterSamples = meter.sampleCount - baseline
                    let result = await capture.stop()
                    meter.stop()
                    if let aggregate {
                        aggregateStayedBound = capture.matchesDeviceHash(aggregate.pinnedKey)
                            && InputDeviceRuntime.shared.selection().chosen?.key == aggregate.pinnedKey
                    }
                    let passed = result.callbacks > 0 && result.nonzero > 0 && result.reopens == 0 && meterSamples > 0 && capture.failure == nil && aggregateStayedBound
                    allPassed = allPassed && passed
                    print("MIC_CAPTURE policy=\(policy.rawValue) callbacks=\(result.callbacks) nonzero=\(result.nonzero) reopens=\(result.reopens) ignored=\(result.ignored) meterSamples=\(meterSamples) state=\(passed ? "passed" : "failed")")
                } catch {
                    let result = await capture.stop(); meter.stop(); allPassed = false
                    print("MIC_CAPTURE policy=\(policy.rawValue) callbacks=\(result.callbacks) nonzero=\(result.nonzero) reopens=\(result.reopens) ignored=\(result.ignored) state=\(SpeechFailureDiagnostics.localCode(for: error))")
                }
            }
            if let aggregate {
                let destroyed = await aggregate.close()
                let unchanged = InputDeviceInventory.defaultInputID() == originalDefault
                allPassed = allPassed && destroyed && unchanged
                print("MIC_PRIVATE_AGGREGATE created=1 destroyed=\(destroyed ? 1 : 0) defaultUnchanged=\(unchanged ? 1 : 0) bound=\(aggregateStayedBound ? 1 : 0)")
            }
            watchdog.cancel()
            fflush(stdout)
            Foundation.exit(allPassed ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        application.run()
    }

    private static func runAudioMeterProbe() {
        MicrophoneLevelMonitor.usesRecognizerBus = false
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let monitor = MicrophoneLevelMonitor()
        var maximumLevel: Float = 0
        var cycleSamples: [UInt64] = []
        var allCyclesRunning = true
        for _ in 0..<3 {
            let baselineSamples = monitor.sampleCount
            monitor.start()
            let deadline = Date(timeIntervalSinceNow: 0.65)
            while Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
                maximumLevel = max(maximumLevel, monitor.level)
            }
            allCyclesRunning = allCyclesRunning && monitor.isRunning
            cycleSamples.append(monitor.sampleCount - baselineSamples)
            monitor.stop()
        }
        let receivedEveryCycle = cycleSamples.allSatisfy { $0 > 0 }
        let passed = allCyclesRunning && receivedEveryCycle
        print(
            "AudioMeterProbe: \(passed ? "PASS" : "FAIL") " +
            "cycles=\(cycleSamples.map(String.init).joined(separator: ",")) " +
            "maxLevel=\(String(format: "%.4f", maximumLevel))"
        )
        Foundation.exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func runComposerActionProbe() {
        RuntimeTrace.configureForTesting(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePointerComposerProbe-\(UUID().uuidString).log"))
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        StandardApplicationMenu.install(in: application)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let textView = ComposerProbeTextView(frame: NSRect(x: 20, y: 20, width: 480, height: 140))
        textView.isEditable = true
        textView.string = "原文🙂"
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)
        Task { @MainActor in
            let result = await ComposerActionIntegrationProbe.run(textView: textView)
            print(result)
            fflush(stdout)
            window.orderOut(nil)
            Foundation.exit(
                result.hasPrefix("ComposerActionProbe: PASS")
                    ? EXIT_SUCCESS
                    : EXIT_FAILURE
            )
        }
        application.run()
    }

    private static func watchTouchFrames(for seconds: Double) {
        let driver = MultitouchDriver()
        guard driver.start() else {
            print(driver.status)
            return
        }
        print("Watching touch counts for \(Int(seconds))s; no coordinates are recorded.")
        let deadline = Date(timeIntervalSinceNow: seconds)
        var previous = [UInt: (Int32, UInt64)]()
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
            for device in driver.devices {
                let state = (device.touchCount, device.callbackCount)
                if let old = previous[device.token], old == state { continue }
                print("kind=\(device.kind.rawValue) active=\(device.touchCount) raw=\(device.rawTouchCount) callbacks=\(device.callbackCount) stages=0x\(String(device.stageMask, radix: 16)) frameAge=\(String(format: "%.3f", device.lastFrameAgeSeconds))")
                previous[device.token] = state
            }
        }
        driver.stop()
    }

    private static func runRuntimeSelfTest() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let driver = MultitouchDriver()
        let persistedShortcut = SettingsStore.shared.value.voiceShortcut
        let started = driver.start()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        let devices = driver.devices
        print("accessibility=\(AccessibilityPermission.isTrusted ? "granted" : "missing")")
        print("inputMonitoring=\(EventAccessPermission.canListen ? "granted" : "missing")")
        print("eventPosting=\(EventAccessPermission.canPost ? "granted" : "missing")")
        print("voiceShortcut=leftOption expectedKeyCode=58 actualKeyCode=\(persistedShortcut.keyCode)")
        print("driverStarted=\(started) devices=\(devices.count)")
        for (index, device) in devices.enumerated() {
            print("device[\(index)] kind=\(device.kind.rawValue) family=0x\(String(device.familyID, radix: 16)) sensor=\(device.sensorRows)x\(device.sensorColumns) callbacks=\(device.callbackCount)")
        }
        expect(AccessibilityPermission.isTrusted, "Accessibility permission is missing")
        expect(EventAccessPermission.canListen, "Input Monitoring permission is missing")
        expect(EventAccessPermission.canPost, "event synthesis permission is missing")
        expect(persistedShortcut.keyCode == 58, "persisted voice shortcut is not Left Option")
        expect(started, "private multitouch driver did not start")
        expect(devices.contains(where: { $0.kind == .magicMouse }), "Magic Mouse was not detected")

        let tapProbe = MouseGestureMonitor(
            driver: driver,
            configuration: .init(),
            onBegin: { _ in true },
            onEnd: { _ in },
            onCancel: {}
        )
        do {
            try tapProbe.start()
            print("eventTap=active")
        } catch {
            failures.append("global event tap failed: \(error.localizedDescription)")
            print("eventTap=failed")
        }
        tapProbe.stop()
        driver.stop()

        // Synthetic multitouch fixtures run in VoicePointerSelfTest, in a
        // process that never loads the real private framework. Never inject
        // fake device pointers into this real-runtime probe after driver.start.
        print("syntheticGestureChecks=separate VoicePointerSelfTest process")

        if let optionDown = CGEventKeyboardSender.makeEvent(.leftOption, isDown: true, baseFlags: []),
           let optionUp = CGEventKeyboardSender.makeEvent(.leftOption, isDown: false, baseFlags: [.maskAlternate]) {
            expect(optionDown.type == .flagsChanged, "Left Option down event has the wrong type")
            expect(optionDown.getIntegerValueField(.keyboardEventKeycode) == 58, "Left Option used the wrong key code")
            expect(optionDown.flags.contains(.maskAlternate), "Left Option down event is missing the Option flag")
            expect(!optionUp.flags.contains(.maskAlternate), "Left Option up event retained the Option flag")
        } else {
            failures.append("Left Option event fixtures could not be created")
        }

        if failures.isEmpty {
            print("PASS runtime integration self-test")
            Foundation.exit(EXIT_SUCCESS)
        }
        for failure in failures { fputs("FAIL \(failure)\n", stderr) }
        Foundation.exit(EXIT_FAILURE)
    }

    /// Runs the real Left Option event pair against Doubao while an ephemeral
    /// local text view owns focus. Any recognized speech stays in this
    /// process and disappears when the probe exits.
    private static func runVoiceShortcutProbe() {
        guard EventAccessPermission.canPost else {
            fputs("FAIL event posting permission is missing\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "VoicePointer Shortcut Probe"
        let textView = NSTextView(frame: NSRect(x: 20, y: 20, width: 480, height: 120))
        textView.isEditable = true
        textView.string = ""
        window.contentView?.addSubview(textView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate()
        window.makeFirstResponder(textView)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))

        let doubaoPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.bytedance.inputmethod.doubaoime"
        ).first?.processIdentifier
        let baseline = visibleWindowSnapshot()
        guard
            let down = CGEventKeyboardSender.makeEvent(.leftOption, isDown: true, baseFlags: []),
            let up = CGEventKeyboardSender.makeEvent(.leftOption, isDown: false, baseFlags: [.maskAlternate])
        else {
            fputs("FAIL unable to create Left Option events\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }

        down.post(tap: .cghidEventTap)
        var observed = baseline
        let deadline = Date(timeIntervalSinceNow: 1.8)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            observed.formUnion(visibleWindowSnapshot())
        }
        up.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))

        let newWindows = observed.subtracting(baseline)
        let doubaoWindows = newWindows.filter { entry in
            guard let doubaoPID else { return entry.owner.localizedCaseInsensitiveContains("doubao") }
            return entry.ownerPID == doubaoPID || entry.owner.localizedCaseInsensitiveContains("doubao")
        }
        print("doubaoRunning=\(doubaoPID != nil)")
        print("leftOptionPosted=down+up hold=1.8s")
        print("newVisibleWindows=\(newWindows.count)")
        for entry in newWindows.sorted(by: { $0.owner < $1.owner }) {
            print("window owner=\(entry.owner) pid=\(entry.ownerPID) id=\(entry.windowID)")
        }
        print("probeTextLength=\(textView.string.count)")
        if !doubaoWindows.isEmpty || !textView.string.isEmpty {
            print("PASS Doubao reacted to synthetic Left Option hold")
            Foundation.exit(EXIT_SUCCESS)
        }
        fputs("FAIL no observable Doubao reaction to synthetic Left Option hold\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }

    private struct VisibleWindow: Hashable {
        let windowID: Int
        let ownerPID: pid_t
        let owner: String
    }

    private static func visibleWindowSnapshot() -> Set<VisibleWindow> {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return Set(raw.compactMap { item in
            guard
                let windowID = item[kCGWindowNumber as String] as? Int,
                let ownerPID = item[kCGWindowOwnerPID as String] as? pid_t,
                let owner = item[kCGWindowOwnerName as String] as? String
            else { return nil }
            return VisibleWindow(windowID: windowID, ownerPID: ownerPID, owner: owner)
        })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputDeviceInventory.start()
        StandardApplicationMenu.install(in: NSApplication.shared)
        if CommandLine.arguments.contains("--self-test-application-lifecycle") {
            ApplicationLifecycleProbeState.shared.mark("didFinishLaunching")
            guard VPCAudioMeterRunLifecycleExceptionProbe() else {
                fputs("ApplicationLifecycleProbe: FAIL audio exception containment\n", stderr)
                Foundation.exit(EXIT_FAILURE)
            }
            // Enter from an AppKit run-loop callback, just like Quit or an
            // Apple event. Calling terminate inside a Swift Task would itself
            // occupy MainActor while AppKit runs its termination modal loop.
            ApplicationLifecycleProbeState.shared.mark("requestTerminate")
            let timer = Timer(timeInterval: 0.01, target: NSApplication.shared,
                              selector: #selector(NSApplication.terminate(_:)),
                              userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        RuntimeTrace.reset()
        RuntimeTrace.record("application launched")
        OutputVolumeController.shared.onUnsupported = { [weak self] in
            self?.pendingOutputDuckingNotice = true
        }
        OutputVolumeController.shared.start() // Reconcile any safely-recoverable interrupted duck.
        RuntimeTrace.record(ReleaseAcceptanceTrace.applicationReady)
        InlineWriteRuntime.shared.recordActiveDenials()
        observers.append(NotificationCenter.default.addObserver(forName: InlineWriteRuntime.demoted, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hud.showInlinePolicyNotice() }
        })
        hangWatchdog.start()
        Task {
            let loginItem = await LoginItemService.shared.reconcile()
            RuntimeTrace.record(
                "loginItem desired=\(loginItem.desiredEnabled) system=\(loginItem.systemState.rawValue) failure=\(loginItem.failureReason != nil)"
            )
        }
        do {
            providerSettingsController = try ProviderSettingsController()
        } catch {
            providerSettingsController = nil
        }
        if let providerSettingsController {
            do {
                firstRunWindow = try FirstRunWindow(provider: providerSettingsController)
                firstRunWindow?.onPermissionVisibilityChanged = { [weak self] visible in
                    guard let self else { return }
                    self.startPermissionPolling()
                    if visible { self.requestPermissionRefresh() }
                }
            } catch {
                RuntimeTrace.record("onboarding progress unavailable; existing settings preserved")
            }
        } else {
            firstRunWindow = nil
        }
        configureStatusItem()
        observers.append(NotificationCenter.default.addObserver(forName: InputDeviceRuntime.notice, object: nil, queue: .main) { [weak self] note in
            guard let message = note.userInfo?["message"] as? String else { return }
            Task { @MainActor [weak self] in self?.hud.showMicrophoneNotice(message) }
        })
        VoicePointerHUDSound.shared.prepare()
        LexiconRuntime.shared.start()
        CorrectionLearningRuntime.shared.isEnabled = { [weak self] in
            self?.providerSettingsController?.store.value.learnCorrections ?? false
        }
        let provider = MacOSAccessibilityProvider()
        coordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: provider),
            keyboardOwnership: keyboardOwnership,
            outcomeHandler: { [weak self] outcome, action, feedback in
                guard let self else { return }
                if action == .send && [.doubaoTextTimeout, .sendTargetChangedBeforeReturn, .sendStillPresent].contains(outcome) {
                    VoicePointerHUDSound.shared.playFailure()
                }
                // Toasts are shown by the following status update; this
                // callback keeps completion-owned gesture hints visible.
                let outcomeFeedback = feedback.statusChannelOwnsToast
                    ? feedback.withPresentationAllowed(false)
                    : feedback
                self.hud.complete(outcome: outcome, action: action, feedback: outcomeFeedback)
            },
            statusHandler: { [weak self] status, location in
                guard let self else { return }
                self.runtimeStatus = status
                let phase: String
                switch status {
                case .idle: phase = "idle"
                case .resolvingTarget: phase = "resolvingTarget"
                case .listening: phase = "listening"
                case .failed:
                    self.pendingOutputDuckingNotice = false
                    OutputVolumeController.shared.forceRestore() // Abnormal ASR/target end.
                    phase = "failed"
                }
                MainHangStateStore.shared.setPhase(phase)
                MainHangStateStore.shared.withOperation(.hudUpdate) {
                    self.hud.update(
                        status: status,
                        quartzPoint: location,
                        allowsDirectedRelease: self.settings.value.voiceShortcut.mode == .hold,
                        onlineSettingsAction: self.onlineFailureSettingsAction(status)
                    )
                }
                if case .listening = status { self.showPendingOutputDuckingNotice() }
                self.updateStatusAppearance()
            },
            transcriptHandler: { [weak self] event in
                RuntimeTrace.record(
                    "transcript kind=\(event.kind.rawValue) utf16=\(event.text?.utf16.count ?? 0)"
                )
                if event.kind == .failed, let code = event.errorCode, let provider = self?.providerSettingsController?.store.value.onlineAPIConfiguration?.provider {
                    OnlineAPIRuntime.shared.failed(code: SpeechFailureDiagnostics.code(code, provider: provider))
                }
            },
            cloudAdmissionInputs: CloudEntryRuntime.shared.makeAdmissionInputsProvider(),
            dictationHandler: { record in LexiconRuntime.shared.record(record) },
            memoryHandler: { record, appKey, cloudSeen in RecognitionMemoryRuntime.shared.record(record, appKey: appKey, cloudSeen: cloudSeen) },
            // Keep human-correction observation; do not provision the teacher-only PCM ring.
            learningObserver: CorrectionLearningRuntime.shared
        )

        guard let coordinator else { return }
        if let providerSettingsController {
            // A crash between two settings writes (or an older version) can leave a cloud switch on that the saved
            // selection does not use. Close those before anything can start a dictation.
            Self.reconcileCloudSwitches(for: providerSettingsController.store.value.selection)
            configureProviderSettingsCallbacks(providerSettingsController)
            synchronizeLearning(preferences: providerSettingsController.store.value)
            SettingsLogicRuntime.shared.scheduleRefresh(selection: providerSettingsController.store.value.selection, trigger: .launch)
            DictationHealthObservation.receive = { selection, failure in
                SettingsLogicRuntime.shared.recordDictation(selection: selection, failure: failure)
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .voicePointerSettingsLogicChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMenuRouteReadiness(); self?.refreshMenuStates() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let controller = self?.providerSettingsController else { return }
                SettingsLogicRuntime.shared.scheduleRefresh(selection: controller.store.value.selection, trigger: .foreground)
            }
        })
        let safety = coordinator.operationSafety
        let gestureAdmission = admission
        let adapter = GestureMainQueueAdapter(
            admission: admission,
            maxInFlight: 1,
            onSessionInvalidated: {
                safety.invalidate(olderThanGeneration: gestureAdmission.snapshot().generation)
            },
            onGestureDropped: { gestureID in safety.invalidate(gestureID: gestureID) },
            executeOnMainActor: { [weak self] message in
                self?.consumeGesture(message)
            }
        )
        gestureAdapter = adapter
        let monitor = OrderedMouseGestureMonitor(
            driver: touchDriver,
            configuration: settings.value.gesture,
            admission: admission,
            eventHandler: { message in adapter.handle(message) }
        )
        gestureMonitor = monitor
        touchService = TouchRuntimeService(
            backend: MultitouchDriverBackend(driver: touchDriver),
            quiesce: AppTouchQuiesce(
                monitor: monitor, adapter: adapter,
                safety: safety, keyboard: keyboardOwnership
            )
        )
        heartbeatTimer = scheduleMainActorTimer(every: 0.1, mode: .common) { [weak self] in
            guard let self else { return }
            self.admission.recordHeartbeat()
            if self.runtimeArmState == .armed,
               (self.admission.snapshot().generation != self.armedAdmissionGeneration ||
                self.admission.overflowLatched) {
                self.recoveryGate.latch(.inputSessionInvalidated)
                self.disarmRuntime(reason: "inputGenerationInvalidated")
            }
        }

        installLifecycleObservers()
        requestPermissionRefresh()
        RuntimeTrace.record("touchDriver status=\(touchService?.stateSnapshot.status ?? "pending")")
        startTouchTelemetry()
        startHardwarePolling()
        startPermissionPolling()
        updateStatusAppearance()
        if firstRunWindow?.shouldAutoShow == true {
            Task { @MainActor [weak self] in self?.firstRunWindow?.showWindow(nil) }
        }
    }

    // AppKit enters an ordinary nonisolated Objective-C trampoline. All actor
    // state is touched only by the explicitly scheduled MainActor task.
    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationLifecycleProbeState.shared.mark("shouldTerminate")
        Task { @MainActor [weak self] in
            guard let self else {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
                return
            }
            self.beginApplicationTermination()
        }
        return .terminateLater
    }

    private func beginApplicationTermination() {
        ApplicationLifecycleProbeState.shared.mark("beginTermination")
        guard !terminationPending else { return }
        terminationPending = true
        appEnabled = false
        disarmRuntime(reason: "applicationTerminate")
        Task { @MainActor [weak self] in
            guard let self else { NSApplication.shared.reply(toApplicationShouldTerminate: true); return }
            let released = await self.keyboardOwnership.releaseAllOwnedAndWait()
            if !released { RuntimeTrace.record("termination keyUp submission unconfirmed") }
            await self.runtimeTask?.value
            // Drain ASR ownership before allowing AppKit to exit. Scheduling
            // this from applicationWillTerminate would be too late.
            await self.coordinator?.applicationWillTerminate()
            await LexiconRuntime.shared.flush()
            await TouchSampleRecorder.shared.beginDataRemoval()
            TouchSampleRecorder.shared.endDataRemoval(permanently: true)
            self.finishApplicationCleanup()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
    }

    private func finishApplicationCleanup() {
        coordinator?.operationSafety.invalidate()
        keyboardOwnership.releaseAllOwned()
        gestureMonitor?.setEnabled(false)
        hangWatchdog.stop()
        permissionTimer?.invalidate()
        hardwareTimer?.invalidate()
        touchTelemetryTimer?.invalidate()
        heartbeatTimer?.invalidate()
        hud.cancelGesture()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        RuntimeTrace.record("application terminated")
        RuntimeTrace.flush()
        ApplicationLifecycleProbeState.shared.didCleanup()
    }

    private func reconcileHUDIfSessionEnded() {
        if runtimeArmState != .armed {
            hud.cancelGesture()
            return
        }
        switch runtimeStatus {
        case .idle, .failed:
            hud.cancelGesture()
        case .resolvingTarget, .listening:
            break
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        // Cleanup has completed before replying true above. This terminal
        // callback must not schedule work which cannot run before exit.
        RuntimeTrace.record("application willTerminate notification")
        RuntimeTrace.flush()
        if CommandLine.arguments.contains("--self-test-application-lifecycle") {
            let passed = ApplicationLifecycleProbeState.shared.cleanupCount == 1
            print("ApplicationLifecycleProbe: \(passed ? "PASS" : "FAIL") cleanupCount=\(ApplicationLifecycleProbeState.shared.cleanupCount) audioFaultCases=192")
            fflush(stdout)
            if !passed { Foundation.exit(EXIT_FAILURE) }
        }
    }

    private func showPendingOutputDuckingNotice() {
        guard pendingOutputDuckingNotice, case .listening = runtimeStatus else { return }
        pendingOutputDuckingNotice = false
        hud.showMicrophoneNotice("这个输出设备不支持调音量，没有压低")
    }

    private func consumeGesture(_ message: GestureEventMessage) {
        guard let coordinator else { return }
        guard !conflictingApplication else {
            appEnabled = false
            disarmRuntime(reason: "conflictingInstance")
            return
        }
        if rejectedDeferredGestures.contains(message.gestureID) {
            if case .end = message.kind { rejectedDeferredGestures.remove(message.gestureID) }
            return
        }
        if pendingSendOwner != nil,
           providerSettingsController?.store.value.selection.mode == .doubao {
            switch message.kind {
            case .begin:
                if pendingDoubaoSecondGesture.isEmpty {
                    pendingDoubaoSecondGesture = [message]
                    return
                }
            case .move:
                if pendingDoubaoSecondGesture.first?.gestureID == message.gestureID {
                    if let last = pendingDoubaoSecondGesture.last, case .move = last.kind {
                        pendingDoubaoSecondGesture[pendingDoubaoSecondGesture.count - 1] = message
                    } else { pendingDoubaoSecondGesture.append(message) }
                    return
                }
            case .end(let location):
                if let first = pendingDoubaoSecondGesture.first,
                   first.gestureID == message.gestureID,
                   case let .begin(activation) = first.kind {
                    let action = RadialReleaseClassifier.classify(
                        hitAction: .stop, anchor: activation.location, current: location
                    )
                    if action == .send, coordinator.expeditePendingDoubaoSend() {
                        pendingDoubaoSecondGesture.removeAll()
                        return
                    }
                    queuedGestureMessages.append(contentsOf: pendingDoubaoSecondGesture)
                    pendingDoubaoSecondGesture.removeAll()
                }
            case .cancel, .tapFailure:
                pendingDoubaoSecondGesture.removeAll()
            }
        }
        if pendingSendOwner != nil {
            switch message.kind {
            case .begin, .move, .end:
                // Keep the old operation token installed until its send completes.
                // Coalesce movement, but retain every begin/end pair in order.
                if case .move = message.kind, let last = queuedGestureMessages.last,
                   case .move = last.kind, last.gestureID == message.gestureID {
                    queuedGestureMessages[queuedGestureMessages.count - 1] = message
                } else if queuedGestureMessages.count < 32 { queuedGestureMessages.append(message) }
                else {
                    rejectDeferredGestures(reason: "capacity")
                    return
                }
                if sendQueueTask == nil {
                    let owner = pendingSendOwner
                    sendQueueTask = Task { @MainActor [weak self] in
                        RuntimeTrace.record("composer gesture queue state=waiting")
                        let wait = await ComposerGestureDeferral.wait { [weak self] in self?.pendingSendOwner == owner }
                        guard let self, !Task.isCancelled else { return }
                        if wait == .timedOut {
                            self.rejectDeferredGestures(reason: "timeout")
                            self.sendQueueTask = nil
                            return // Leave the landed old write/send alive; explain the queued press's timeout.
                        }
                        guard wait == .ready else { return }
                        self.sendQueueTask = nil
                        let queued = self.queuedGestureMessages
                        self.queuedGestureMessages.removeAll()
                        RuntimeTrace.record("composer gesture queue state=replaying count=\(queued.count)")
                        for event in queued { self.consumeGesture(event) }
                    }
                }
                return
            case .cancel, .tapFailure:
                sendQueueTask?.cancel(); sendQueueTask = nil
                queuedGestureMessages.removeAll()
                pendingDoubaoSecondGesture.removeAll()
                pendingSendOwner = nil
            }
        }
        switch message.kind {
        case .begin(let activation):
            guard appEnabled, runtimeArmState == .armed,
                  message.generation == armedAdmissionGeneration,
                  allRequiredPermissionsGranted else { return }
            let token = OperationCancellationToken()
            // Register before the second admission check. Independent
            // invalidation then cancels this exact operation, including
            // invalidation racing the UI-side begin.
            coordinator.operationSafety.install(token, generation: message.generation, gestureID: message.gestureID)
            guard !token.isCancelled, message.generation == admission.snapshot().generation,
                  admission.snapshot().isHeartbeatFresh(
                    now: monotonicTimestampSeconds(), tolerance: 1
                  ) else {
                token.cancel()
                return
            }
            guard let providerSettingsController else {
                token.cancel()
                return
            }
            MainHangStateStore.shared.setRouteID(providerSettingsController.store.value.selection.routeID)
            MainHangStateStore.shared.setTargetBundleID(lastForegroundBundleID)
            InputDeviceRuntime.shared.beginIntent()
            MicrophoneLevelMonitor.usesRecognizerBus = providerSettingsController.store.value.selection.mode != .doubao
            CaptureLevelBus.shared.invalidate()
            let context = RecognitionMemoryRuntime.shared.freeze(preferences: providerSettingsController.store.value, appKey: lastForegroundBundleID)
            let practiceSink = providerSettingsController.store.value.selection.mode == .voiceNative
                ? firstRunWindow?.capturePracticeSink() : nil
            let previousPracticeSessionID = coordinator.currentSessionID
            if coordinator.gestureBegan(activation, settings: settings.value, cancellationToken: token, selection: providerSettingsController.store.value.selection, cloudConsent: CloudEntryRuntime.shared.enhancementConsent(), aliyunEndpoint: providerSettingsController.store.value.aliyunEndpoint, onlineAPIConfiguration: providerSettingsController.store.value.onlineAPIConfiguration, lexicon: LexiconRuntime.shared.snapshot(applying: providerSettingsController.store.value.applyPersonalLexicon), localHotwords: context?.terms ?? [], localContext: context, contextAppKey: lastForegroundBundleID ?? "", practiceSink: practiceSink) {
                if practiceSink != nil, coordinator.currentSessionID != nil,
                   coordinator.currentSessionID != previousPracticeSessionID {
                    firstRunWindow?.watchPracticeSession(token: token, coordinator: coordinator)
                }
                activeGestureID = message.gestureID
                OutputVolumeController.shared.begin() // Only an admitted gesture changes output volume.
                let deviceID = touchDriver.devices.first { $0.token == activation.match.deviceToken }?.deviceID
                hud.beginGesture(deviceKind: activation.match.deviceKind, deviceID: deviceID)
                showPendingOutputDuckingNotice()
            } else {
                token.cancel()
            }
        case .move(let location):
            guard activeGestureID == message.gestureID else { return }
            _ = hud.track(quartzPoint: location)
        case .end(let location):
            guard activeGestureID == message.gestureID else { return }
            activeGestureID = nil
            pendingOutputDuckingNotice = false
            OutputVolumeController.shared.release() // Send/cancel cues restore synchronously before playback.
            let action = hud.releaseAction(at: location)
            let releaseSessionID = coordinator.currentSessionID
            releaseTask?.cancel()
            let owner = UUID()
            // Retain ownership for both final paste/keep and Return confirmation.
            // A queued begin must not install a token over either transaction.
            if action != .cancel { pendingSendOwner = owner }
            releaseTask = Task { @MainActor [weak self, weak coordinator] in
                if action == .cancel, await coordinator?.hasCancelContent(expectedSessionID: releaseSessionID) == true,
                   !Task.isCancelled {
                    self?.hud.playEarlyCancelSound()
                }
                await coordinator?.gestureEnded(action: action, expectedSessionID: releaseSessionID)
                if self?.pendingSendOwner == owner {
                    self?.pendingSendOwner = nil
                    self?.pendingDoubaoSecondGesture.removeAll()
                }
            }
        case .cancel:
            activeGestureID = nil
            pendingOutputDuckingNotice = false
            OutputVolumeController.shared.forceRestore()
            coordinator.invalidatePendingActions()
            hud.cancelGesture()
            releaseTask?.cancel()
            releaseTask = Task { @MainActor [weak coordinator] in await coordinator?.waitForCancelledResources() }
        case .tapFailure:
            recoveryGate.latch(.eventTapDisabled)
            disarmRuntime(reason: "eventTapDisabled")
        }
    }

    private func rejectDeferredGestures(reason: String) {
        for event in queuedGestureMessages {
            if case .begin = event.kind { rejectedDeferredGestures.insert(event.gestureID) }
            if case .end = event.kind { rejectedDeferredGestures.remove(event.gestureID) }
        }
        queuedGestureMessages.removeAll()
        RuntimeTrace.record("composer gesture queue state=rejected reason=\(reason)")
        hud.complete(feedback: .init(message: "上一轮还在确认，这次没开始，请稍后再按", kind: .info), action: .stop)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStates()
        refreshMenuRouteReadiness()
        refreshMenuCloudState()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "VoicePointer")
        statusItem = item

        let menu = NSMenu(title: "VoicePointer")
        menu.delegate = self
        menu.addItem(taggedItem(.status, title: "正在启动", action: nil))
        menu.addItem(.separator())
        menu.addItem(taggedItem(.enabled, title: "暂停监听", action: #selector(toggleEnabled)))
        let routeItem = NSMenuItem(title: "识别方式", action: nil, keyEquivalent: "")
        let routeMenu = NSMenu(title: SettingsStrings.recognition)
        routeMenu.delegate = self
        routeMenu.addItem(taggedItem(.routeDoubao, title: SettingsStrings.doubao, action: #selector(selectMenuRoute(_:))))
        routeMenu.addItem(taggedItem(.routeQwen17, title: SettingsStrings.modelMenuTitle(.qwen17), action: #selector(selectMenuRoute(_:))))
        routeMenu.addItem(taggedItem(.routeQwen06, title: SettingsStrings.modelMenuTitle(.qwen06), action: #selector(selectMenuRoute(_:))))
        routeMenu.addItem(taggedItem(.routeAliyun, title: SettingsStrings.online + SettingsStrings.menuSuffix(.reading), action: #selector(selectMenuRoute(_:))))
        routeMenu.addItem(.separator())
        let manageRoutes = NSMenuItem(title: SettingsStrings.manageRecognition, action: #selector(showVoiceSettings), keyEquivalent: "")
        manageRoutes.target = self
        routeMenu.addItem(manageRoutes)
        routeItem.submenu = routeMenu
        routeItem.tag = MenuTag.routes.rawValue
        menu.addItem(routeItem)
        menu.addItem(taggedItem(.settings, title: "设置…", action: #selector(showProviderSettings)))
        menu.addItem(.separator())
        let about = NSMenuItem(title: "关于 VoicePointer", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let feedback = NSMenuItem(title: "反馈问题…", action: #selector(copyDiagnostics), keyEquivalent: "")
        feedback.target = self
        menu.addItem(feedback)
        let quit = NSMenuItem(title: "退出 VoicePointer", action: #selector(terminate), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        self.menu = menu
        refreshMenuRouteReadiness()
        refreshMenuCloudState()
    }

    private func taggedItem(_ tag: MenuTag, title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.tag = tag.rawValue
        item.target = self
        return item
    }

    private func hapticTestItem(title: String, pattern: NSHapticFeedbackManager.FeedbackPattern) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(playHaptic(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = pattern.rawValue
        return item
    }

    @objc private func playHaptic(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let pattern = NSHapticFeedbackManager.FeedbackPattern(rawValue: rawValue) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let monitor = gestureMonitor
        let adapter = gestureAdapter
        let authority = admission
        let safety = coordinator?.operationSafety
        let keyboard = keyboardOwnership
        let hangWatchdog = hangWatchdog
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard let bundleID else { return }
            if bundleID == "com.apple.systempreferences" {
                // Tear down the global filter BEFORE a user can revoke TCC
                // permissions. This path neither waits for MainActor nor
                // performs private-device lifecycle calls on this thread.
                authority.update { $0.acceptingNewGestures = false; $0.permissionsGranted = false }
                adapter?.sessionToken.invalidate()
                safety?.invalidate()
                keyboard.releaseAllOwned()
                monitor?.setEnabled(false)
                monitor?.stop {}
                RuntimeTrace.record("input interlock systemSettings activated; event tap stop requested")
            }
            Task { @MainActor [weak self] in
                self?.observeForegroundApplication(bundleID)
            }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let launched = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                let launchedBundleID = launched.bundleIdentifier else { return }
            InlineWriteRuntime.shared.noteApplicationRestart(bundle: launchedBundleID)
            // Extract plain values before hopping actors; never carry
            // NSRunningApplication across the Task boundary.
            let launchedPID = launched.processIdentifier
            let ownPID = ProcessInfo.processInfo.processIdentifier
            guard PreviewInstancePolicy.isConflictingEntry(
                ownPID: ownPID, bundleID: launchedBundleID, pid: launchedPID
            ) else {
                Task { @MainActor [weak self] in self?.requestPermissionRefresh() }
                return
            }
            // Same immediate non-MainActor teardown as the systemSettings
            // interlock: deny admission, invalidate tokens, release keys,
            // and stop the event tap before scheduling MainActor changes.
            authority.update { $0.acceptingNewGestures = false; $0.permissionsGranted = false }
            adapter?.sessionToken.invalidate()
            safety?.invalidate()
            keyboard.releaseAllOwned()
            monitor?.setEnabled(false)
            monitor?.stop {}
            RuntimeTrace.record("input interlock conflictingInstance launched bundleID=\(launchedBundleID) pid=\(launchedPID)")
            Task { @MainActor [weak self] in
                self?.handleConflictingInstanceLaunched()
                self?.requestPermissionRefresh()
            }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestPermissionRefresh() }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            hangWatchdog.suspendForSleep()
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            hangWatchdog.resumeAfterWake()
            Task { @MainActor in self?.reloadTouchStack() }
        })
        // Screen layout/refresh changes do not invalidate touch devices.
        // HUD placement reads the current screens when presented. Device
        // connection changes and wake still use the existing reload path.
    }

    private func observeForegroundApplication(_ bundleID: String) {
        lastForegroundBundleID = bundleID
        let isSettings = bundleID == "com.apple.systempreferences"
        recoveryGate.observeSystemSettingsFrontmost(isSettings)
        if isSettings {
            disarmRuntime(reason: "systemSettingsSafetyInterlock")
        }
        updateStatusAppearance()
        requestPermissionRefresh()
    }

    /// Defensive process exclusion only. The daily app has no lock
    /// cooperation, so this check is not atomic cross-app exclusion.
    private var conflictingApplication: Bool {
        permissionSnapshot.conflict
    }

    private func handleConflictingInstanceLaunched() {
        permissionSnapshot.conflict = true
        appEnabled = false
        disarmRuntime(reason: "conflictingInstanceLaunched")
        updateStatusAppearance()
    }

    private func presentInstanceConflictAlert() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let switchable = PreviewInstancePolicy.switchableEntry(
            ownPID: ownPID,
            entries: runningVoicePointerEntries()
        ) != nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = InstanceConflictPrompt.title
        alert.informativeText = switchable
            ? InstanceConflictPrompt.message : InstanceConflictPrompt.legacyMessage
        if switchable {
            alert.addButton(withTitle: InstanceConflictPrompt.switchButtonTitle)
        }
        alert.addButton(withTitle: InstanceConflictPrompt.dismissButtonTitle)
        RuntimeTrace.record("instance conflict guidance shown")
        let response = alert.runModal()
        if switchable && response == .alertFirstButtonReturn {
            switchToRunningVoicePointer()
        }
    }

    private func runningVoicePointerEntries() -> [PreviewInstancePolicy.RunningEntry] {
        NSWorkspace.shared.runningApplications.compactMap { running in
            guard let bundleID = running.bundleIdentifier else { return nil }
            return PreviewInstancePolicy.RunningEntry(
                bundleID: bundleID, pid: running.processIdentifier
            )
        }
    }

    private func switchToRunningVoicePointer() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let runningApplications = NSWorkspace.shared.runningApplications
        let entries = runningApplications.compactMap { running -> PreviewInstancePolicy.RunningEntry? in
            guard let bundleID = running.bundleIdentifier else { return nil }
            return PreviewInstancePolicy.RunningEntry(
                bundleID: bundleID,
                pid: running.processIdentifier
            )
        }
        guard let conflictingEntry = PreviewInstancePolicy.switchableEntry(
            ownPID: ownPID,
            entries: entries
        ),
        let target = runningApplications.first(where: {
            $0.processIdentifier == conflictingEntry.pid
        }) else {
            RuntimeTrace.record("instance conflict switch target unavailable")
            return
        }

        if target.activate(options: [.activateAllWindows]) {
            RuntimeTrace.record("instance conflict existing app activated")
        } else {
            RuntimeTrace.record("instance conflict activation unavailable")
        }
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        let onboardingVisible = firstRunWindow?.window?.isVisible == true
            && firstRunWindow?.window?.isMiniaturized == false
        guard permissionSettingsPageVisible || onboardingVisible else { return }
        permissionTimer = scheduleMainActorTimer(every: 1.5, mode: .common) { [weak self] in
            self?.requestPermissionRefresh()
        }
    }

    nonisolated private static func collectPermissionSnapshot() -> PermissionSnapshot {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let workspace = NSWorkspace.shared
        let entries: [PreviewInstancePolicy.RunningEntry] = workspace.runningApplications.compactMap { running in
            guard let bundleID = running.bundleIdentifier else { return nil }
            return PreviewInstancePolicy.RunningEntry(bundleID: bundleID, pid: running.processIdentifier)
        }
        return PermissionSnapshot(
            accessibility: AccessibilityPermission.isTrusted,
            listen: EventAccessPermission.canListen,
            post: EventAccessPermission.canPost,
            conflict: PreviewInstancePolicy.hasConflict(ownPID: ownPID, entries: entries),
            foregroundBundleID: workspace.frontmostApplication?.bundleIdentifier
        )
    }

    private func requestPermissionRefresh() {
        guard !terminationPending else { return }
        if permissionScanInFlight {
            permissionScanAgain = true
            return
        }
        permissionScanInFlight = true
        permissionScanQueue.async { [weak self] in
            let snapshot = Self.collectPermissionSnapshot()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permissionScanInFlight = false
                let changed = self.permissionSnapshot != snapshot
                self.permissionSnapshot = snapshot
                SettingsLogicRuntime.shared.permissions.update([
                    .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .denied,
                    .accessibility: snapshot.accessibility ? .granted : .denied,
                    .inputMonitoring: snapshot.listen ? .granted : .denied
                ])
                if let bundleID = snapshot.foregroundBundleID,
                   bundleID != self.lastForegroundBundleID {
                    self.observeForegroundApplication(bundleID)
                }
                if changed {
                    RuntimeTrace.record(
                        "permissions accessibility=\(snapshot.accessibility) " +
                        "inputMonitoring=\(snapshot.listen) posting=\(snapshot.post) " +
                        "conflict=\(snapshot.conflict)"
                    )
                }
                self.pollAccessibilityPermissionNow()
                if self.permissionScanAgain {
                    self.permissionScanAgain = false
                    self.requestPermissionRefresh()
                }
            }
        }
    }

    private func pollAccessibilityPermissionNow() {
        guard appEnabled else {
            permissionStablePolls = 0
            disarmRuntime(reason: "appDisabled")
            updateStatusAppearance()
            return
        }
        guard !conflictingApplication else {
            // Another instance wins; stay disabled until the user explicitly
            // re-enables. Never re-enable automatically when the other quits.
            appEnabled = false
            permissionStablePolls = 0
            disarmRuntime(reason: "conflictingInstance")
            updateStatusAppearance()
            return
        }
        guard allRequiredPermissionsGranted else {
            permissionStablePolls = 0
            if runtimeArmState == .armed || runtimeArmState == .arming {
                recoveryGate.latch(.permissionLost)
            }
            disarmRuntime(reason: "permissionLost")
            updateStatusAppearance()
            if !permissionAlertShown {
                if !permissionSnapshot.accessibility { _ = AccessibilityPermission.requestIfNeeded() }
                if !permissionSnapshot.listen { _ = EventAccessPermission.requestListenIfNeeded() }
                if !permissionSnapshot.post { _ = EventAccessPermission.requestPostIfNeeded() }
                presentPermissionAlertIfNeeded()
                requestPermissionRefresh()
            }
            return
        }
        guard !recoveryGate.systemSettingsFrontmost else {
            permissionStablePolls = 0
            updateStatusAppearance()
            return
        }
        permissionStablePolls = min(
            permissionStablePolls + 1,
            Self.requiredPermissionStablePolls
        )
        guard permissionStablePolls >= Self.requiredPermissionStablePolls,
              runtimeArmState == .stopped,
              Date() >= nextRuntimeRecoveryAttempt else {
            updateStatusAppearance()
            return
        }
        if recoveryGate.recoverTransientInterruption(
            permissionsGranted: true, now: monotonicTimestampSeconds()
        ) {
            RuntimeTrace.record("runtime transient interruption recovered after teardown")
        }
        armRuntimeIfNeeded(reason: "permissionRecovered")
        updateStatusAppearance()
    }

    private var allRequiredPermissionsGranted: Bool {
        permissionSnapshot.granted
    }

    private func presentPermissionAlertIfNeeded() {
        guard !permissionAlertShown, !permissionAlertPending, appEnabled,
              !CommandLine.arguments.contains(where: {
                  $0.hasPrefix("--self-test-") || $0.hasPrefix("--probe-") ||
                  $0.hasPrefix("--preview-hud")
              }) else { return }
        guard !currentlyMissingPermissions().isEmpty else { return }
        // 2026-11-07: read once more after 1.5 s so a single transient false read never raises the
        // alert, and run the alert from a run-loop block instead of this main-queue job. A modal loop
        // entered inside a main-queue job keeps every other MainActor job waiting (11-05: 7.3 s stall).
        permissionAlertPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.permissionAlertPending = false
            guard !self.permissionAlertShown, self.appEnabled,
                  !self.currentlyMissingPermissions().isEmpty else { return }
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.showPermissionAlertNow()
                }
            }
        }
    }

    private func currentlyMissingPermissions() -> [PermissionFeedbackKind] {
        PermissionFeedback.missing(
            accessibility: AccessibilityPermission.isTrusted,
            inputMonitoring: EventAccessPermission.canListen,
            eventPosting: EventAccessPermission.canPost
        )
    }

    private func showPermissionAlertNow() {
        guard !permissionAlertShown, appEnabled else { return }
        let missing = currentlyMissingPermissions()
        guard !missing.isEmpty else { return }
        permissionAlertShown = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "VoicePointer 尚未启动全局监听"
        alert.informativeText = "当前缺少：\(missing.map(\.displayName).joined(separator: "、"))。只需处理上面列出的权限。\n\n若开关已开启仍提示缺失，请移除旧条目，再添加“应用程序”中的 VoicePointer，并退出后重启。"
        for kind in missing {
            alert.addButton(withTitle: "打开\(kind.displayName)")
        }
        alert.addButton(withTitle: "稍后")
        RuntimeTrace.record("permission guidance shown missing=\(missing.map(\.rawValue).joined(separator: ",")) " +
            "accessibilityMissing=\(missing.contains(.accessibility) ? 1 : 0) " +
            "inputMonitoringMissing=\(missing.contains(.inputMonitoring) ? 1 : 0) " +
            "eventPostingMissing=\(missing.contains(.eventPosting) ? 1 : 0)")
        let response = alert.runModal()
        let selectedIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard selectedIndex >= 0, selectedIndex < missing.count else { return }
        NSWorkspace.shared.open(missing[selectedIndex].settingsURL)
    }

    private func armRuntimeIfNeeded(reason: String, ignoreBackoff: Bool = false) {
        guard appEnabled, !conflictingApplication, !terminationPending, runtimeArmState == .stopped,
              recoveryGate.mayAutomaticallyArm(permissionsGranted: allRequiredPermissionsGranted),
              ignoreBackoff || Date() >= nextRuntimeRecoveryAttempt,
              let service = touchService, let monitor = gestureMonitor else { return }
        guard !service.stateSnapshot.cleanupStopInFlight else { return }
        runtimeEpoch &+= 1
        let epoch = runtimeEpoch
        runtimeArmState = .arming
        admission.update { $0.acceptingNewGestures = false; $0.permissionsGranted = false }
        runtimeTask = Task { @MainActor [weak self] in
            let outcome = await withCheckedContinuation { continuation in
                service.requestStart { continuation.resume(returning: $0) }
            }
            guard let self, self.runtimeEpoch == epoch, !Task.isCancelled else { return }
            guard outcome == .started, self.appEnabled, !self.conflictingApplication,
                  self.allRequiredPermissionsGranted else {
                self.failRuntimeArm(reason: "deviceStart-\(outcome)")
                return
            }
            let tapStarted = await withCheckedContinuation { continuation in
                monitor.startAsync { error in continuation.resume(returning: error == nil) }
            }
            guard self.runtimeEpoch == epoch, !Task.isCancelled else { return }
            guard tapStarted, self.appEnabled, !self.conflictingApplication,
                  self.allRequiredPermissionsGranted else {
                self.failRuntimeArm(reason: "eventTapStart")
                return
            }
            self.admission.clearOverflowLatch()
            self.admission.recordHeartbeat()
            self.admission.update {
                $0.permissionsGranted = true
                $0.acceptingNewGestures = true
            }
            monitor.setEnabled(true)
            self.armedAdmissionGeneration = self.admission.snapshot().generation
            self.runtimeArmState = .armed
            self.permissionStablePolls = Self.requiredPermissionStablePolls
            self.nextRuntimeRecoveryAttempt = .distantPast
            self.runtimeRecoveryBackoff = 0.5
            RuntimeTrace.record("runtime armed reason=\(reason)")
            self.updateStatusAppearance()
        }
    }

    private func failRuntimeArm(reason: String) {
        // An OS-level denial may outlive cached preflight results. Never
        // repeatedly restart the private touch driver during that interval.
        recoveryGate.latch(.eventTapStartFailed)
        nextRuntimeRecoveryAttempt = Date().addingTimeInterval(runtimeRecoveryBackoff)
        runtimeRecoveryBackoff = min(runtimeRecoveryBackoff * 2, 8)
        disarmRuntime(reason: "armFailed-\(reason)")
    }

    private func disarmRuntime(reason: String) {
        pendingOutputDuckingNotice = false
        OutputVolumeController.shared.forceRestore() // Also called on terminate, permission loss and event-tap failure.
        coordinator?.operationSafety.invalidate()
        guard runtimeArmState != .stopped, runtimeArmState != .stopping else { return }
        runtimeEpoch &+= 1
        runtimeArmState = .stopping
        permissionStablePolls = 0
        activeGestureID = nil
        admission.update { $0.acceptingNewGestures = false; $0.permissionsGranted = false }
        gestureAdapter?.sessionToken.invalidate()
        gestureMonitor?.setEnabled(false)
        sendQueueTask?.cancel(); sendQueueTask = nil
        queuedGestureMessages.removeAll()
        pendingDoubaoSecondGesture.removeAll()
        pendingSendOwner = nil
        coordinator?.invalidatePendingActions()
        hud.cancelGesture()
        releaseTask?.cancel()
        runtimeTask?.cancel()
        requestRuntimeStop(reason: reason)
    }

    private func requestRuntimeStop(reason: String) {
        guard runtimeArmState == .stopping, !stopRequestPending else { return }
        guard let service = touchService else { runtimeArmState = .stopped; return }
        let epoch = runtimeEpoch
        stopRequestPending = true
        // A canceled arm can still have a queued tap start. Drain it before
        // teardown completes, so automatic recovery never overlaps listeners.
        let previousRuntimeTask = runtimeTask
        runtimeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await previousRuntimeTask?.value
            await self.coordinator?.cancel()
            let result = await withCheckedContinuation { continuation in
                service.requestStop { continuation.resume(returning: $0) }
            }
            guard self.runtimeEpoch == epoch else { return }
            self.stopRequestPending = false
            if result == .stopped && !service.stateSnapshot.cleanupStopInFlight {
                self.runtimeArmState = .stopped
            } else {
                // Retain the stopping gate until the service confirms its
                // late cleanup. Never re-arm an unresolved private call.
                self.runtimeStatus = .failed("触控设备未能正常停止，监听已暂停，请点“检查权限并重新连接”")
            }
            RuntimeTrace.record("runtime disarm reason=\(reason) result=\(result)")
            self.updateStatusAppearance()
        }
    }

    private func startHardwarePolling() {
        lastMultitouchServiceCount = touchService?.stateSnapshot.connectedServiceCount ?? -1
        hardwareTimer?.invalidate()
        hardwareTimer = scheduleMainActorTimer(every: 5) { [weak self] in
            self?.pollTouchHardware()
        }
    }

    private func startTouchTelemetry() {
        touchTelemetryTimer?.invalidate()
        pollTouchTelemetry()
        touchTelemetryTimer = scheduleMainActorTimer(every: 1.0) { [weak self] in
            self?.pollTouchTelemetry()
        }
    }

    private func pollTouchTelemetry() {
        touchService?.requestSnapshotRefresh()
        for device in touchService?.stateSnapshot.devices ?? [] {
            let stateKey = "kind=\(device.kind.rawValue) active=\(device.touchCount) " +
                "raw=\(device.rawTouchCount) callbacks=\(device.callbackCount) " +
                "stages=0x\(String(device.stageMask, radix: 16))"
            let snapshot = stateKey + " " +
                "frameAge=\(String(format: "%.4f", device.lastFrameAgeSeconds)) " +
                "delta=\(String(format: "%.4f", device.directionalDisplacement.x))," +
                "\(String(format: "%.4f", device.directionalDisplacement.y))"
            guard lastTouchTelemetry[device.token] != stateKey else { continue }
            lastTouchTelemetry[device.token] = stateKey
            RuntimeTrace.record("touchState \(snapshot)")
        }
    }

    private func pollTouchHardware() {
        let snapshot = touchService?.stateSnapshot
        if runtimeArmState == .stopping, !stopRequestPending {
            if snapshot?.lifecycleState == .idle && snapshot?.cleanupStopInFlight == false {
                runtimeArmState = .stopped
            } else {
                requestRuntimeStop(reason: "lateStopRetry")
            }
        }
        let currentCount = snapshot?.connectedServiceCount ?? -1
        guard currentCount >= 0 else { return }
        defer { lastMultitouchServiceCount = currentCount }
        guard lastMultitouchServiceCount >= 0,
              currentCount != lastMultitouchServiceCount else { return }
        reloadTouchStack()
    }

    private func reloadTouchStack() {
        if runtimeArmState == .armed || runtimeArmState == .arming {
            disarmRuntime(reason: "manualOrHardwareReload")
        } else if runtimeArmState == .stopped {
            armRuntimeIfNeeded(reason: "manualOrHardwareReload", ignoreBackoff: true)
        }
    }

    private func refreshMenuStates() {
        guard let menu else { return }
        // 智能聚焦暂不做，需要时恢复。
        for tag in [MenuTag.focusSmart, .focusCurrent, .focusVoiceOnly, .clickFallback] {
            menu.item(withTag: tag.rawValue)?.isHidden = true
        }
        menu.item(withTag: MenuTag.enabled.rawValue)?.title = appEnabled ? "暂停监听" : "恢复监听"
        menu.item(withTag: MenuTag.trackpad.rawValue)?.state = settings.value.gesture.trackpadEnabled ? .on : .off
        menu.item(withTag: MenuTag.clickFallback.rawValue)?.state = settings.value.allowSyntheticClickFallback ? .on : .off
        menu.item(withTag: MenuTag.focusSmart.rawValue)?.state = settings.value.focusMode == .smart ? .on : .off
        menu.item(withTag: MenuTag.focusCurrent.rawValue)?.state = settings.value.focusMode == .currentOnly ? .on : .off
        menu.item(withTag: MenuTag.focusVoiceOnly.rawValue)?.state = settings.value.focusMode == .voiceOnly ? .on : .off
        menu.item(withTag: MenuTag.voiceHold.rawValue)?.state = settings.value.voiceShortcut.mode == .hold ? .on : .off
        menu.item(withTag: MenuTag.voiceToggle.rawValue)?.state = settings.value.voiceShortcut.mode == .toggle ? .on : .off
        let selected = providerSettingsController?.store.value.selection
        let routeMenu = menu.item(withTag: MenuTag.routes.rawValue)?.submenu
        routeMenu?.item(withTag: MenuTag.routeDoubao.rawValue)?.state = selected?.mode == .doubao ? .on : .off
        let routeVM = SettingsLogicRuntime.shared.menu
        var projectedOnlineKind = OnlineRouteMenuState.StatusKind.unavailable
        styleRecognitionMenu(routeMenu?.item(withTag: MenuTag.routeDoubao.rawValue), base: SettingsStrings.doubao,
            suffix: SettingsStrings.menuSuffix(routeVM.options.states[.doubao]))
        routeMenu?.item(withTag: MenuTag.routeQwen17.rawValue)?.state = selected?.mode == .voiceNative && selected?.routeID == "qwen17-rolling" ? .on : .off
        routeMenu?.item(withTag: MenuTag.routeQwen06.rawValue)?.state = selected?.mode == .voiceNative && selected?.routeID == "qwen06-rolling" ? .on : .off
        if let onlineItem = routeMenu?.item(withTag: MenuTag.routeAliyun.rawValue) {
            let state = onlineMenuState(page: menuCloudPage)
            projectedOnlineKind = state.statusKind
            styleRecognitionMenu(onlineItem, base: state.baseTitle, suffix: state.statusSuffix)
            onlineItem.state = state.selected ? .on : .off
        }
        for (tag, id) in [(MenuTag.routeQwen17, LocalModelID.qwen17), (.routeQwen06, .qwen06)] {
            let value = SettingsLogicRuntime.shared.local.models.first(where: { $0.id == id }).map { SettingsStrings.localModelStatus($0.state) }
            styleRecognitionMenu(routeMenu?.item(withTag: tag.rawValue), base: SettingsStrings.modelMenuTitle(id),
                suffix: value.map { $0.isEmpty ? "" : " · " + $0 } ?? SettingsStrings.menuSuffix(routeVM.localHealth[id]))
        }
        let projection = ReleaseAcceptanceTrace.menu(selection: selected,
            doubao: routeVM.options.states[.doubao],
            qwen17: routeVM.localHealth[.qwen17], prepare17: routeVM.localPreparation[.qwen17] != true,
            qwen06: routeVM.localHealth[.qwen06], prepare06: routeVM.localPreparation[.qwen06] != true,
            online: projectedOnlineKind)
        if lastMenuProjectionTrace != projection {
            lastMenuProjectionTrace = projection
            RuntimeTrace.record(projection)
        }
        updateStatusAppearance()
    }

    private func styleRecognitionMenu(_ item: NSMenuItem?, base: String, suffix: String) {
        guard let item else { return }
        item.title = base + suffix
        let title = NSMutableAttributedString(string: base, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: suffix, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        item.attributedTitle = title
    }

    private func onlineMenuState(page: CloudEntryPageState) -> OnlineRouteMenuState {
        let preferences = providerSettingsController?.store.value
        let config = preferences?.onlineAPIConfiguration
        let panel = OnlineAPIRuntime.shared.panel
        let kind: OnlineRouteMenuState.StatusKind
        if config == nil { kind = .needsConfiguration }
        else if panel.configuration != config { kind = .reading }
        else {
            switch panel.attention {
            case nil: kind = .passed
            case .keyRejected: kind = .invalidKey
            case .confirmationExpired: kind = .expired
            case .freeQuotaExhausted: kind = .quotaExhausted
            }
        }
        let cloud = CloudEntryPreferences.load()
        let mayUse = panel.configuration == config && panel.attention == nil && (config.map { preferences?.cloudConsent.contains($0.consentID) == true
            && (!$0.provider.isAliyun || cloud.routeEnabled && cloud.uploadConsent) } ?? false)
        return OnlineRouteMenuState(configuration: config, statusKind: kind, mayUse: mayUse, selection: preferences?.selection,
            health: config == nil ? nil : SettingsLogicRuntime.shared.health.states[.online])
    }

    /// Presence and gate state only; menu refresh never tests a connection or reads a key value.
    private func refreshMenuCloudState() {
        guard !menuCloudRefreshInFlight else { return }
        menuCloudRefreshInFlight = true
        Task { @MainActor [weak self] in
            let page = await CloudEntryRuntime.shared.pageState()
            guard let self else { return }
            await OnlineAPIRuntime.shared.refresh()
            self.menuCloudPage = page
            self.menuCloudRefreshInFlight = false
            self.refreshMenuStates()
        }
    }

    private func selectOnlineMenuRoute(_ controller: ProviderSettingsController) {
        guard !menuCloudSelectionInFlight else { return }
        menuCloudSelectionInFlight = true
        let previous = controller.store.value
        let previousCloud = CloudEntryPreferences.load()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.menuCloudSelectionInFlight = false }
            let page = await CloudEntryRuntime.shared.pageState()
            await OnlineAPIRuntime.shared.refresh()
            self.menuCloudPage = page
            // A settings change or withdrawal while reading cannot revive an older menu click.
            guard controller.store.value == previous, CloudEntryPreferences.load() == previousCloud else {
                self.showVoiceSettings()
                self.refreshMenuStates()
                return
            }
            do {
                let switched = try self.onlineMenuState(page: page).select(
                    store: controller.store,
                    onPreferencesChanged: { controller.onPreferencesChanged?($0) },
                    notify: { NotificationCenter.default.post(name: .voicePointerSettingsChanged, object: nil) }
                )
                if !switched { self.showVoiceSettings() }
            } catch {
                self.showVoiceSettings()
            }
            self.refreshMenuStates()
        }
    }

    private func refreshMenuRouteReadiness() {
        // T11: The same external-library presence gate is used by settings and the worker.
        guard !routeReadinessInFlight else { return }
        routeReadinessInFlight = true
        let language = providerSettingsController?.store.value.selection.language ?? "zh"
        Task.detached(priority: .utility) {
            let prepared = Set(LocalModelID.allCases.filter {
                VoiceNativeModelPreparation.isLocalPrepared(routeID: $0.rawValue, language: language)
            }.map(\.rawValue))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.preparedMenuLocalRoutes = prepared
                self.routeReadinessInFlight = false
                SettingsLogicRuntime.shared.menu.updateLocalPreparation(Dictionary(uniqueKeysWithValues:
                    LocalModelID.allCases.map { ($0, prepared.contains($0.rawValue)) }))
                self.refreshMenuStates()
            }
        }
    }

    @objc private func selectMenuRoute(_ sender: NSMenuItem) {
        guard let controller = providerSettingsController else { return }
        let routeID: String
        switch sender.tag {
        case MenuTag.routeDoubao.rawValue: routeID = "doubao"
        case MenuTag.routeQwen17.rawValue: routeID = "qwen17-rolling"
        case MenuTag.routeQwen06.rawValue: routeID = "qwen06-rolling"
        case MenuTag.routeAliyun.rawValue:
            selectOnlineMenuRoute(controller)
            return
        default: showVoiceSettings(); return
        }
        if let id = LocalModelID(rawValue: routeID) {
            guard preparedMenuLocalRoutes.contains(routeID), case .passed = SettingsLogicRuntime.shared.menu.localHealth[id] else {
                controller.showLocalModel(id)
                return
            }
        }
        var prefs = controller.store.value
        prefs.selection.mode = routeID == "doubao" ? .doubao : .voiceNative
        if routeID != "doubao" { prefs.selection.routeID = routeID }
        do {
            try controller.store.update(prefs)
            controller.onPreferencesChanged?(prefs)
            NotificationCenter.default.post(name: .voicePointerSettingsChanged, object: nil)
            refreshMenuStates()
        } catch {
            showVoiceSettings()
        }
    }

    private func updateStatusAppearance() {
        MainHangStateStore.shared.withOperation(.statusPermissionRead) {
            updateStatusAppearanceNow()
        }
    }

    private func updateStatusAppearanceNow() {
        let permission = permissionSnapshot.accessibility
        let inputMonitoring = permissionSnapshot.listen
        let canPost = permissionSnapshot.post
        let deviceCount = touchService?.stateSnapshot.devices.count ?? 0
        let title: String
        if !appEnabled { title = "已停用" }
        else if recoveryGate.systemSettingsFrontmost { title = "系统设置中：监听已暂停" }
        else if recoveryGate.requiresManualRecovery { title = "监听已暂停，请手动重新连接" }
        else if !permission || !canPost { title = "需要辅助功能权限" }
        else if !inputMonitoring { title = "需要输入监控权限" }
        else if deviceCount == 0 { title = "未发现触控设备" }
        else { title = "\(runtimeStatus.title) · \(deviceCount) 个触控设备" }
        let route = providerSettingsController?.store.value.selection
        let routeLabel: String
        if route?.mode == .doubao { routeLabel = "豆包输入法" }
        else {
            switch route?.routeID {
            case "qwen17-rolling": routeLabel = "千问 1.7B"
            case "qwen06-rolling": routeLabel = "千问 0.6B"
            case "aliyun", "groq-v3", "groq-turbo", "openai-transcribe", "openai-mini-transcribe", "siliconflow-sensevoice":
                routeLabel = providerSettingsController?.store.value.onlineAPIConfiguration.map { OnlineAPIStrings.modelName($0.modelID) }
                    ?? OnlineAPIStrings.modelName(AliWireCodec.legacyModelID)
            case "apple-speech": routeLabel = "Apple 识别"
            default: routeLabel = "其他方式"
            }
        }
        menu?.item(withTag: MenuTag.status.rawValue)?.title = "\(title) · \(routeLabel)"
        statusItem?.button?.contentTintColor = {
            switch runtimeStatus {
            case .listening: return .systemGreen
            case .resolvingTarget: return .systemYellow
            case .failed: return .systemRed
            case .idle: return !recoveryGate.requiresManualRecovery && permission && inputMonitoring && canPost && deviceCount > 0 ? nil : .systemOrange
            }
        }()
    }

    /// Closes the cloud switches (route, "用于增强本地识别", upload permission) that `selection` does not use. It only
    /// ever closes; whether a key is saved is not known here, so that rule is left to the settings page and the gate.
    private static func reconcileCloudSwitches(for selection: VoiceInputSelection) {
        let preferences = CloudEntryPreferences.load()
        let closed = CloudEntryPreferences.reconcile(
            CloudEntryReconcileContext(selection: selection, credentialAvailable: true, entryVisible: preferences.visible)
        )
        if closed { RuntimeTrace.record("cloud switches reconciled closed=true") }
    }

    private func configureProviderSettingsCallbacks(_ controller: ProviderSettingsController) {
        SettingsLogicRuntime.shared.onBeforeDataRemoval = { [weak self] all in
            guard let self else { throw AppDataFailure.removal }
            self.coordinator?.invalidatePendingActions()
            if all {
                self.appEnabled = false
                self.disarmRuntime(reason: "dataRemoval")
                await TouchSampleRecorder.shared.beginDataRemoval()
                TouchSampleRecorder.shared.endDataRemoval(permanently: true)
                await self.runtimeTask?.value
                await self.coordinator?.applicationWillTerminate()
                self.finishApplicationCleanup()
            } else {
                await self.coordinator?.cancel()
                await self.coordinator?.waitForCancelledResources()
            }
            CorrectionLearningRuntime.shared.discardForDataRemoval()
            if all {
                await LexiconRuntime.shared.discardForDataRemoval()
                RuntimeTrace.suspendForDataRemoval()
            }
        }
        SettingsLogicRuntime.shared.onEnhancementAuthorizationChanged = { [weak self] in
            guard let preferences = self?.providerSettingsController?.store.value else { return }
            self?.synchronizeLearning(preferences: preferences)
        }
        SettingsLogicRuntime.shared.onCloudAuthorizationClosed = { [weak self] in
            CloudEntryPreferences.setRouteEnabled(false)
            CloudEntryPreferences.setUploadConsent(false)
            SettingsLogicRuntime.shared.online.enhancement.synchronize()
            self?.coordinator?.cloudAuthorizationChanged(CloudEntryRuntime.shared.enhancementConsent())
            if let preferences = self?.providerSettingsController?.store.value {
                self?.synchronizeLearning(preferences: preferences)
            }
        }
        controller.onPreferencesChanged = { [weak self] preferences in
            RecognitionMemoryRuntime.shared.setEnabled(preferences.useRecentContextLocally)
            // The menu bar's route switch, the first-run window and the settings all write the selection and then
            // report it here: close the cloud switches the new selection does not use before the consent goes to
            // the coordinator. (What is not known yet, such as whether a key is saved, never closes anything.)
            Self.reconcileCloudSwitches(for: preferences.selection)
            self?.synchronizeLearning(preferences: preferences)
            SettingsLogicRuntime.shared.scheduleRefresh(selection: preferences.selection, trigger: .selection)
            self?.coordinator?.cloudAuthorizationChanged(CloudEntryRuntime.shared.enhancementConsent())
        }
        // Every actual preferences change (including the lexicon page) uses this same immediate callback.
        controller.store.onChange = { [weak controller] preferences in controller?.onPreferencesChanged?(preferences) }
        controller.onInteractionChanged = { [weak self] invalidatesSession in
            guard let self else { return }
            self.gestureMonitor?.update(configuration: self.settings.value.gesture)
            if invalidatesSession {
                self.coordinator?.invalidatePendingActions()
                Task { @MainActor in await self.coordinator?.waitForCancelledResources() }
            }
            self.refreshMenuStates()
        }
        controller.onRecheck = { [weak self] in self?.checkPermissionAndStart() }
        controller.onPermissionPageVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.permissionSettingsPageVisible = visible
            self.startPermissionPolling()
            if visible { self.requestPermissionRefresh() }
        }
        controller.onShowOnboarding = { [weak self] in
            guard let self else { return }
            if let firstRunWindow = self.firstRunWindow {
                firstRunWindow.showWindow(nil)
            } else {
                let alert = NSAlert()
                alert.messageText = "首次引导暂时无法打开"
                alert.informativeText = "引导进度无法读取；当前语音设置仍然保留。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    private func synchronizeLearning(preferences: ProviderPreferences) {
        CorrectionLearningRuntime.shared.synchronizeEnhancement(preferences: preferences)
        coordinator?.doubaoLearningAuthorizationChanged(selection: preferences.selection, learningEnabled: preferences.enhanceLearning)
    }

    private func providerSettingsFailureReason() -> String {
        do {
            _ = try ProviderSettingsStore(
                fileURL: IntegratedRuntimePaths.dataRoot.appendingPathComponent("provider-settings.json"))
            return "controllerUnavailable"
        } catch ProviderSettingsStore.SettingsError.malformed {
            return "malformed"
        } catch ProviderSettingsStore.SettingsError.symlink {
            return "unsafePath"
        } catch {
            return "storageUnavailable"
        }
    }

    private func exportProviderSettingsDiagnostic(reason: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "VoicePointer-settings-diagnostic.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let report = "VoicePointer settings diagnostic\nversion=\(version)\nreason=\(reason)\nconfigurationContent=excluded\ncredentialContent=excluded\n"
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "诊断未能导出"
            alert.informativeText = "请选择其他保存位置后重试。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func presentProviderSettingsRecovery() {
        let reason = providerSettingsFailureReason()
        let recoverable = reason == "malformed"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "语音方案设置无法读取"
        alert.informativeText = recoverable
            ? "可恢复默认设置；原配置会先备份，已保存的密钥不会改动。"
            : "现有配置不会被自动更改。可导出不含配置内容和密钥的诊断。"
        if recoverable { alert.addButton(withTitle: "恢复默认设置（原配置已备份）") }
        alert.addButton(withTitle: "导出诊断")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if recoverable, response == .alertFirstButtonReturn {
            do {
                let fileURL = IntegratedRuntimePaths.dataRoot.appendingPathComponent("provider-settings.json")
                _ = try ProviderSettingsStore.recoverMalformed(fileURL: fileURL)
                let controller = try ProviderSettingsController()
                providerSettingsController = controller
                configureProviderSettingsCallbacks(controller)
                firstRunWindow = try? FirstRunWindow(provider: controller)
                firstRunWindow?.onPermissionVisibilityChanged = { [weak self] visible in
                    guard let self else { return }
                    self.startPermissionPolling()
                    if visible { self.requestPermissionRefresh() }
                }
                appEnabled = false
                disarmRuntime(reason: "providerSettingsRecovered")
                coordinator?.cloudAuthorizationChanged([])
                refreshMenuStates()
                RuntimeTrace.record("provider settings recovered backupCreated=true")
                controller.show()
            } catch {
                RuntimeTrace.record("provider settings recovery failed")
                let failure = NSAlert()
                failure.messageText = "未能恢复默认设置"
                failure.informativeText = "请导出诊断；应用不会自动启用听写。"
                failure.addButton(withTitle: "好")
                failure.runModal()
            }
        } else if response == (recoverable ? .alertSecondButtonReturn : .alertFirstButtonReturn) {
            exportProviderSettingsDiagnostic(reason: reason)
        }
    }

    @objc private func showProviderSettings() {
        if let providerSettingsController {
            providerSettingsController.showVoicePage()
        } else {
            presentProviderSettingsRecovery()
        }
    }

    @objc private func showVoiceSettings() {
        if let providerSettingsController {
            providerSettingsController.showVoicePage()
        } else {
            showProviderSettings()
        }
    }
    private func onlineFailureSettingsAction(_ status: VoicePointerRuntimeStatus) -> (() -> Void)? {
        guard case .failed = status, let issue = coordinator?.lastIssuePresentation,
              providerSettingsController?.store.value.onlineAPIConfiguration != nil,
              [.apiKeyInvalid, .apiKeyMissing, .credentialUnreadable, .freeQuotaExhausted, .balanceDue,
               .modelUnavailable, .accessDenied, .endpointInvalid, .networkFailed, .responseTimeout].contains(issue.code) else { return nil }
        return { [weak self] in self?.providerSettingsController?.showVoicePage(online: true) }
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showHUDSkinSettings() {
        if let providerSettingsController {
            providerSettingsController.showAppearancePage()
        } else {
            showProviderSettings()
        }
    }

    @objc private func toggleEnabled() {
        if !appEnabled, providerSettingsController == nil {
            presentProviderSettingsRecovery()
            refreshMenuStates()
            return
        }
        if !appEnabled, conflictingApplication {
            presentInstanceConflictAlert()
            refreshMenuStates()
            return
        }
        appEnabled.toggle()
        if !appEnabled {
            disarmRuntime(reason: "userDisabled")
        } else if allRequiredPermissionsGranted {
            if recoveryGate.authorizeManualRecovery(permissionsGranted: true) {
                armRuntimeIfNeeded(reason: "userEnabled", ignoreBackoff: true)
            }
        } else {
            // Explicit user enable with missing permissions: invoke the
            // existing explicit permission flow.
            checkPermissionAndStart()
        }
        refreshMenuStates()
    }

    @objc private func selectFocusMode(_ sender: NSMenuItem) {
        let mode: FocusMode
        switch sender.tag {
        case MenuTag.focusCurrent.rawValue: mode = .currentOnly
        case MenuTag.focusVoiceOnly.rawValue: mode = .voiceOnly
        default: mode = .smart
        }
        settings.update { $0.focusMode = mode }
        refreshMenuStates()
    }

    @objc private func selectVoiceMode(_ sender: NSMenuItem) {
        let mode: VoiceShortcutMode = sender.tag == MenuTag.voiceToggle.rawValue ? .toggle : .hold
        settings.update { $0.voiceShortcut.mode = mode }
        coordinator?.invalidatePendingActions()
        Task { @MainActor in await coordinator?.waitForCancelledResources() }
        refreshMenuStates()
    }

    @objc private func toggleTrackpad() {
        settings.update { $0.gesture.trackpadEnabled.toggle() }
        gestureMonitor?.update(configuration: settings.value.gesture)
        refreshMenuStates()
    }

    @objc private func toggleClickFallback() {
        settings.update { $0.allowSyntheticClickFallback.toggle() }
        refreshMenuStates()
    }

    @objc private func checkPermissionAndStart() {
        _ = AccessibilityPermission.requestIfNeeded()
        _ = EventAccessPermission.requestListenIfNeeded()
        _ = EventAccessPermission.requestPostIfNeeded()
        recoveryGate.observeSystemSettingsFrontmost(
            lastForegroundBundleID == "com.apple.systempreferences"
        )
        if recoveryGate.authorizeManualRecovery(permissionsGranted: allRequiredPermissionsGranted) {
            permissionStablePolls = Self.requiredPermissionStablePolls
            armRuntimeIfNeeded(reason: "manualPermissionCheck", ignoreBackoff: true)
        } else {
            disarmRuntime(reason: "manualPermissionCheckFailed")
            startPermissionPolling()
        }
        refreshMenuStates()
        requestPermissionRefresh()
    }

    @objc private func reloadDevices() {
        reloadTouchStack()
    }

    @objc private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnostics, forType: .string)
    }

    @objc private func terminate() {
        NSApplication.shared.terminate(nil)
    }

    private var diagnostics: String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let permission = AccessibilityPermission.isTrusted ? "granted" : "missing"
        let inputMonitoring = EventAccessPermission.canListen ? "granted" : "missing"
        let eventPosting = EventAccessPermission.canPost ? "granted" : "missing"
        let secureInput = SecureInputGuard.isEnabled ? "enabled" : "disabled"
        let deviceLines = (touchService?.stateSnapshot.devices ?? []).enumerated().map { index, device in
            "device[\(index)]: kind=\(device.kind.rawValue), family=0x\(String(device.familyID, radix: 16)), sensor=\(device.sensorRows)x\(device.sensorColumns), touches=\(device.touchCount), rawTouches=\(device.rawTouchCount), callbacks=\(device.callbackCount), stages=0x\(String(device.stageMask, radix: 16)), frameAge=\(String(format: "%.3f", device.lastFrameAgeSeconds))"
        }
        return ([
            "VoicePointer diagnostics",
            "OS: \(os)",
            "Accessibility: \(permission)",
            "Input Monitoring: \(inputMonitoring)",
            "Event Posting: \(eventPosting)",
            "Secure Input: \(secureInput)",
            "Driver: \(touchService?.stateSnapshot.status ?? "pending")",
            "IOKit services: \(touchService?.stateSnapshot.connectedServiceCount ?? -1)",
        ] + deviceLines).joined(separator: "\n")
    }


}

private final class RuntimeEventCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var beginCount = 0
    private var endCount = 0
    private var cancelCount = 0

    func begin() { lock.withLock { beginCount += 1 } }
    func end() { lock.withLock { endCount += 1 } }
    func cancel() { lock.withLock { cancelCount += 1 } }
    func snapshot() -> (begin: Int, end: Int, cancel: Int) {
        lock.withLock { (beginCount, endCount, cancelCount) }
    }
}
