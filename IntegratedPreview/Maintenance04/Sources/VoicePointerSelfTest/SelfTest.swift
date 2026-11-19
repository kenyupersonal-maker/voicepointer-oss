import Foundation
import CoreGraphics
import CAudioMeterSupport
@_spi(Testing) import VoicePointerCore

private struct CheckSuite {
    private(set) var failures: [String] = []

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
}

@main
@MainActor
struct VoicePointerSelfTest {
    static func main() async {
        if Array(CommandLine.arguments.dropFirst()) == ["--strict-shadow-only"] {
            let failures = await StrictLearningShadowChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            print("STRICT_SHADOW_CHECK failures=\(failures.count) synthetic=1 microphone=0 network=0")
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--r67-caps-only"] {
            let failures = await StrictLearningLedgerChecks.run(only: ["caps"])
            for failure in failures { fputs(failure + "\n", stderr) }
            print("R67_CAPS_ROLLOVER_CHECK failures=\(failures.count) groups=1 microphone=0 network=0")
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--strict-learning-only"] {
            RuntimeTrace.configureForTesting(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("StrictLearning-\(UUID().uuidString).log"))
            let failures = StrictLearningChecks.run()
                + (await StrictLearningLedgerChecks.run())
                + (await StrictLearningShadowChecks.run())
            for failure in failures { fputs(failure + "\n", stderr) }
            print("STRICT_LEARNING_CHECK failures=\(failures.count) synthetic=1 microphone=0 network=0")
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--r67-storage-three-only"] {
            let failures = await StrictLearningLedgerChecks.run(only: ["basic", "caps", "expire"])
            for failure in failures { fputs(failure + "\n", stderr) }
            print("R67_STORAGE_THREE_CHECK failures=\(failures.count) groups=3 microphone=0 network=0")
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--composer-r67-empty-only"] {
            let failures = await ComposerReplayChecks.runR67EmptyOnly()
            for failure in failures { fputs(failure + "\n", stderr) }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--composer-r67-fast-only"] {
            let failures = await ComposerReplayChecks.runR67FastOnly()
            for failure in failures { fputs(failure + "\n", stderr) }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--clear-swipe-only"] {
            let failures = await ComposerReplayChecks.runClearSwipeOnly()
            for failure in failures { fputs(failure + "\n", stderr) }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if ["--composer-replay-only", "--composer-replay-baseline"].contains(CommandLine.arguments.dropFirst().first ?? ""), CommandLine.arguments.count == 2 {
            RuntimeTrace.configureForTesting(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ComposerReplay-\(UUID().uuidString).log"))
            let baseline = CommandLine.arguments[1] == "--composer-replay-baseline"
            let failures = await ComposerReplayChecks.run(baseline: baseline)
            Foundation.exit(baseline || failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--composer-continuity-only"] {
            let failures = await ComposerContinuityChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("COMPOSER_CONTINUITY_PASS cases=1 ax=0 keys=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--snapshot-draft-only"] {
            let failures = SnapshotDraftPlannerChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("SNAPSHOT_DRAFT_PASS cases=1 ax=0 clipboard=0 keys=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--inline-clipboard-only"] {
            let failures = await InlineDraftClipboardChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("INLINE_CLIPBOARD_PASS cases=1 editor=memory clipboard=named ax=0 keys=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--terminal-period-only"] {
            let failures = TerminalPeriodChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("TERMINAL_PERIOD_PASS cases=1 microphone=0 ax=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--composer-ax-queue-only"] {
            let failures = await AXServiceChecks.runComposerQueueReentrancy()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("COMPOSER_AX_QUEUE_PASS cases=1 ax=fake editor=0 clipboard=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--teacher-only"] {
            RuntimeTrace.configureForTesting(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TeacherChecks-\(UUID().uuidString).log"))
            let failures = await TeacherLearningTesting.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("TEACHER_PASS worker=fake audio=synthetic capture=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--memory-only"] {
            let failures = RecognitionMemoryChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("MEMORY_PASS microphone=0 ax=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--delivery-hotfix-only"] {
            RuntimeTrace.configureForTesting(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DeliveryHotfix-\(UUID().uuidString).log"))
            let failures = await ComposerDeliveryHotfixChecks.run() + InlineWritePolicyChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("DELIVERY_HOTFIX_PASS ax=fake clipboard=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--hybrid-draft-only"] {
            let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HybridDraftChecks-\(UUID().uuidString).log")
            RuntimeTrace.configureForTesting(fileURL: log)
            let failures = await HybridChecks.run() + InlineDraftPumpChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("HYBRID_DRAFT_PASS microphone=0 key=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--inline-policy-only"] {
            let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("InlinePolicyChecks-\(UUID().uuidString).log")
            RuntimeTrace.configureForTesting(fileURL: log)
            let failures = InlineWritePolicyChecks.run() + EmptyHintMemoryChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("INLINE_POLICY_PASS ax=0 clipboard=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--send-hotfix-only"] {
            let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SilentSendChecks-\(UUID().uuidString).log")
            RuntimeTrace.configureForTesting(fileURL: log)
            let failures = await SilentSendChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("SEND_HOTFIX_PASS synthetic=1 editor=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--microphone-only"] {
            let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MicrophoneChecks-\(UUID().uuidString).log")
            RuntimeTrace.configureForTesting(fileURL: log)
            let failures = await MicrophoneSilenceChecks.run() + InputDeviceChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("MICROPHONE_PASS synthetic_pcm=1 real_microphone=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--no-input-field-only"] {
            let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("NoFieldChecks-\(UUID().uuidString).log")
            RuntimeTrace.configureForTesting(fileURL: log)
            let failures = await NoInputFieldChecks.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--cloud-fallback-only"] {
            let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CloudFallbackChecks-\(UUID().uuidString).log")
            RuntimeTrace.configureForTesting(fileURL: log)
            let failures = await CloudFallbackTesting.run()
            for failure in failures { fputs(failure + "\n", stderr) }
            if failures.isEmpty { print("CLOUD_FALLBACK_PASS core_cases=2 physical_starts=1 hardware=0 network=0") }
            Foundation.exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--settle-timeout-only"] {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let logURL = root.appendingPathComponent(".cache/supp-s3-timeout/\(UUID().uuidString).log")
            let failures = ComposerSettleChecks.runTimeoutTiming(logURL: logURL) + VoiceIssuePresentationChecks.runSettleTimeout()
            if failures.isEmpty { print("S3_TIMEOUT_PASS capture=0 cloud=0 ax=0 hardware=0"); Foundation.exit(EXIT_SUCCESS) }
            for failure in failures { fputs("✗ \(failure)\n", stderr) }
            Foundation.exit(EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--cloud-setup-only"] {
            let catalog = await CloudModelCatalogChecks.run()
            let failures = await CloudSetupFlowChecks.run() + catalog.failures
            if failures.isEmpty {
                print("CLOUD_SETUP_PASS catalog_checks=\(catalog.checks) flow_scenarios=15 fake_key_reads=\(catalog.fakeKeyReads) fake_requests=\(catalog.fakeRequests) real_requests=0 real_keys=0 audio=0")
                Foundation.exit(EXIT_SUCCESS)
            }
            for failure in failures { fputs("✗ \(failure)\n", stderr) }
            Foundation.exit(EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--haptic-only"] {
            let failures = ZoneHapticChecks.runAll()
            if failures.isEmpty { print("HAPTIC_PASS injected_clock_performer hardware=0 sleep=0"); Foundation.exit(EXIT_SUCCESS) }
            for failure in failures { fputs("✗ \(failure)\n", stderr) }
            Foundation.exit(EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--t147-only"] {
            let failures = ComposerSettleChecks.runTiming() + ComposerExtraQuietChecks.run()
            if failures.isEmpty { print("T147_PASS capture=0 cloud=0 ax=0"); Foundation.exit(EXIT_SUCCESS) }
            for failure in failures { fputs("✗ \(failure)\n", stderr) }
            Foundation.exit(EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--t145-only"] {
            let failures = MagicMouseChordChecks.runAll() + (await TouchSampleRecorderChecks.runAll())
            if failures.isEmpty { print("T145_PASS synthetic_touch_only"); Foundation.exit(EXIT_SUCCESS) }
            for failure in failures { fputs("✗ \(failure)\n", stderr) }
            Foundation.exit(EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--t14-stability-only"] {
            var failures = runGestureRevision2Tests()
            failures += OnlineRouteMenuChecks.run()
            failures += await CoordinatorSafetyChecks.run()
            failures += await ImmediateCancellationChecks.run()
            failures += await CancellationResourceBalanceChecks.run()
            if failures.isEmpty {
                print("T14_STABILITY_PASS capture=0 cloud=0")
                Foundation.exit(EXIT_SUCCESS)
            }
            for failure in failures { fputs("✗ \(failure)\n", stderr) }
            Foundation.exit(EXIT_FAILURE)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--cloud-admission-only"] {
            var failures = await CloudAdmissionGateChecks.run()
            failures += await CloudStreamArbiterChecks.run()
            failures += await CloudEntryChecks.run()
            failures += await CloudConnectionCheckChecks.run()
            if failures.isEmpty {
                print("✓ Cloud admission gate self-test passed")
                Foundation.exit(EXIT_SUCCESS)
            }
            for failure in failures { fputs("✗ \(failure)\n", stderr) }
            Foundation.exit(EXIT_FAILURE)
        }

        let traceURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VoicePointerSelfTest-\(UUID().uuidString).log")
        RuntimeTrace.configureForTesting(fileURL: traceURL)
        // Diagnostic-only resume after the standard self-test failed outside
        // R0, whose 38 production replay cases already passed. No user I/O.
        let excludePassedR0 = Array(CommandLine.arguments.dropFirst()) == ["--r67-selftest-except-r0"]
        var suite = CheckSuite()
        testScoring(&suite)
        testFocusEngine(&suite)
        testStateMachine(&suite)
        testSettings(&suite)
        for failure in await NoInputFieldChecks.run() { suite.expect(false, failure) }
        for failure in await CloudFallbackTesting.run() { suite.expect(false, failure) }
        for failure in ZoneHapticChecks.runAll() { suite.expect(false, failure) }
        for failure in await CloudSetupFlowChecks.run() { suite.expect(false, failure) }
        await testGesturePipeline(&suite)
        for failure in runGestureBridgeStressTests() { suite.expect(false, failure) }
        for failure in runGestureRevision2Tests() { suite.expect(false, failure) }
        for failure in runGestureRevision3Tests() { suite.expect(false, failure) }
        for failure in runGestureRevision4Tests() { suite.expect(false, failure) }
        for failure in await runGestureMainQueueAdapterTest() { suite.expect(false, failure) }
        testRadialReleaseClassifier(&suite)
        testRollbackPlanner(&suite)
        testComposerTextNormalizer(&suite)
        testKeyboardEventShape(&suite)
        await testShortcutControllers(&suite)
        await testCoordinator(&suite)
        await testReleaseSafety(&suite)
        for failure in StabilityModuleChecks.runAll() { suite.expect(false, failure) }
        for failure in await KeyboardOwnershipChecks.run() { suite.expect(false, failure) }
        for failure in await KeyboardFaultChecks.run() { suite.expect(false, failure) }
        for failure in await AXServiceChecks.run() { suite.expect(false, failure) }
        for failure in FocusCancellationChecks.run() { suite.expect(false, failure) }
        for failure in WebFocusWarmupChecks.run() { suite.expect(false, failure) }
        for failure in await TouchRuntimeServiceChecks.runAll() { suite.expect(false, failure) }
        for failure in await TouchRuntimeReentrancyChecks.run() { suite.expect(false, failure) }
        for failure in await CoordinatorSafetyChecks.run() { suite.expect(false, failure) }
        for failure in await ImmediateCancellationChecks.run() { suite.expect(false, failure) }
        for failure in await CancellationResourceBalanceChecks.run() { suite.expect(false, failure) }
        for failure in await LocalCancellationProbe.run() { suite.expect(false, failure) }
        for failure in await DiagnosticBundleChecks.run() { suite.expect(false, failure) }
        for failure in ReleaseAcceptanceTraceChecks.run() { suite.expect(false, failure) }
        for failure in await CloudAdmissionGateChecks.run() { suite.expect(false, failure) }
        for failure in await CloudStreamArbiterChecks.run() { suite.expect(false, failure) }
        for failure in await CloudEntryChecks.run() { suite.expect(false, failure) }
        for failure in await CloudConnectionCheckChecks.run() { suite.expect(false, failure) }
        for failure in OnlineRouteMenuChecks.run() { suite.expect(false, failure) }
        for failure in await SettingsViewModelChecks.run() { suite.expect(false, failure) }
        for failure in R66PermissionSearchChecks.run() { suite.expect(false, failure) }
        for failure in await AppDataManagementChecks.run() { suite.expect(false, failure) }
        for failure in await ModelDownloaderChecks.run() { suite.expect(false, failure) }
        for failure in HybridPureChecks.run() { suite.expect(false, failure) }
        for failure in CloudEnhanceWordingChecks.run() { suite.expect(false, failure) }
        for failure in await HybridWiringChecks.run() { suite.expect(false, failure) }
        for failure in await HybridChecks.run() { suite.expect(false, failure) }
        for failure in await LexiconChecks.run() { suite.expect(false, failure) }
        for failure in await EnhancementLearningChecks.run() { suite.expect(false, failure) }
        for failure in await LocalConfidenceTesting.run() { suite.expect(false, failure) }
        for failure in await DoubaoLearningTesting.run() { suite.expect(false, failure) }
        for failure in LearningChecks.run() { suite.expect(false, failure) }
        for failure in HotwordChecks.run() { suite.expect(false, failure) }
        for failure in RecognitionMemoryChecks.run() { suite.expect(false, failure) }
        for failure in await TeacherLearningTesting.run() { suite.expect(false, failure) }
        for failure in TerminalPeriodChecks.run() { suite.expect(false, failure) }
        for failure in VoiceRoutePreparationChecks.run() { suite.expect(false, failure) }
        for failure in ModelResourceLibraryChecks.run() { suite.expect(false, failure) }
        for failure in AliServiceFailureChecks.run() { suite.expect(false, failure) }
        for failure in VoiceIssuePresentationChecks.run() { suite.expect(false, failure) }
        for failure in await GestureR5Checks.run() { suite.expect(false, failure) }
        for failure in RuntimeRecoveryGateChecks.run() { suite.expect(false, failure) }
        for failure in AudioLevelBufferChecks.run() { suite.expect(false, failure) }
        for failure in CaptureLevelChecks.run() { suite.expect(false, failure) }
        for failure in await MicrophoneSilenceChecks.run() { suite.expect(false, failure) }
        for failure in InputDeviceChecks.run() { suite.expect(false, failure) }
        for failure in await SilentSendChecks.run() { suite.expect(false, failure) }
        for failure in PreviewRenderingPolicyChecks.run() { suite.expect(false, failure) }
        for failure in ComposerFeedbackChecks.run() { suite.expect(false, failure) }
        for failure in await ComposerDeliveryHotfixChecks.run() { suite.expect(false, failure) }
        for failure in EmptyHintMemoryChecks.run() { suite.expect(false, failure) }
        for failure in InlineWritePolicyChecks.run() { suite.expect(false, failure) }
        for failure in ComposerSettleChecks.run() { suite.expect(false, failure) }
        for failure in ComposerExtraQuietChecks.run() { suite.expect(false, failure) }
        for failure in MagicMouseChordChecks.runAll() { suite.expect(false, failure) }
        for failure in MagicMouseEdgeChecks.run() { suite.expect(false, failure) }
        for failure in await TouchSampleRecorderChecks.runAll() { suite.expect(false, failure) }
        for failure in PermissionFeedbackChecks.run() { suite.expect(false, failure) }
        for failure in InlineDraftTransactionChecks.run() { suite.expect(false, failure) }
        for failure in await InlineDraftPumpChecks.run() { suite.expect(false, failure) }
        for failure in await InlineDraftClipboardChecks.run() { suite.expect(false, failure) }
        for failure in SnapshotDraftPlannerChecks.run() { suite.expect(false, failure) }
        for failure in await ComposerContinuityChecks.run() { suite.expect(false, failure) }
        if !excludePassedR0 {
            for failure in await ComposerReplayChecks.run() { suite.expect(false, failure) }
        }
        for failure in await ComposerReplayChecks.runClearSwipeOnly() { suite.expect(false, failure) }
        for failure in EditingIntentClockChecks.run() { suite.expect(false, failure) }
        for failure in SkinParamChecks.run() { suite.expect(false, failure) }
        for failure in ShapedNoiseSoundChecks.run() { suite.expect(false, failure) }
        suite.expect(VPCAudioMeterRunLifecycleExceptionProbe(), "audio lifecycle must contain all 192 fault/restart cases")
        suite.expect(VPCAudioMeterRunLevelFormatProbe(), "audio level must handle float and integer PCM buffers")

        if suite.failures.isEmpty {
            print("✓ VoicePointer self-test passed")
            Foundation.exit(EXIT_SUCCESS)
        }
        for failure in suite.failures { fputs("✗ \(failure)\n", stderr) }
        Foundation.exit(EXIT_FAILURE)
    }

    private static func testScoring(_ suite: inout CheckSuite) {
        let scoring = SmartFocusScoring()
        let point = CGPoint(x: 500, y: 500)
        let composer = FocusCandidate(
            identifier: "composer",
            role: "AXTextArea",
            label: "Message",
            frame: CGRect(x: 300, y: 700, width: 520, height: 100),
            windowFrame: CGRect(x: 100, y: 100, width: 900, height: 760),
            isMultiline: true
        )
        let toolbarSearch = FocusCandidate(
            identifier: "search",
            role: "AXTextField",
            label: "Search",
            frame: CGRect(x: 470, y: 480, width: 180, height: 32),
            windowFrame: CGRect(x: 100, y: 100, width: 900, height: 760),
            isPointerInside: true,
            isInsideToolbar: true
        )
        let ranked = scoring.ranked([toolbarSearch, composer], at: point)
        suite.expect(ranked.first?.candidate.identifier == "composer", "composer should outrank toolbar search")
        // The address bar the user focused and points at is an explicit target, even in a toolbar.
        let focusedAddressBar = FocusCandidate(
            identifier: "omnibox",
            role: "AXTextField",
            label: "Address and search bar",
            frame: CGRect(x: 120, y: 480, width: 1_700, height: 36),
            windowFrame: CGRect(x: 100, y: 100, width: 900, height: 760),
            isPointerInside: true,
            isCurrentlyFocused: true,
            isInsideToolbar: true
        )
        let explicit = scoring.ranked([focusedAddressBar, composer], at: point)
        suite.expect(explicit.first?.candidate.identifier == "omnibox" && (explicit.first?.value ?? 0) >= 80,
                     "a focused address bar under the pointer should be accepted")
        let unfocusedAddressBar = FocusCandidate(
            identifier: "omnibox",
            role: "AXTextField",
            label: "Address and search bar",
            frame: CGRect(x: 120, y: 480, width: 1_700, height: 36),
            windowFrame: CGRect(x: 100, y: 100, width: 900, height: 760),
            isPointerInside: true,
            isInsideToolbar: true
        )
        suite.expect((scoring.score(unfocusedAddressBar, at: point) ?? 0) < 80,
                     "an unfocused address bar must stay below the acceptance score")
        let secure = FocusCandidate(
            identifier: "secure",
            role: "AXTextField",
            frame: CGRect(x: 490, y: 490, width: 100, height: 30),
            isSecure: true,
            isPointerInside: true
        )
        suite.expect(scoring.score(secure, at: point) != nil, "an explicitly pointed secure field is usable")
        let unrelatedSecure = FocusCandidate(identifier: "unrelated-secure", role: "AXTextField",
            frame: CGRect(x: 900, y: 900, width: 100, height: 30), isSecure: true)
        suite.expect(scoring.score(unrelatedSecure, at: point) == nil,
                     "automatic focus must not choose an unrelated secure field")
    }

    private static func testFocusEngine(_ suite: inout CheckSuite) {
        let provider = FakeFocusProvider()
        let engine = SmartFocusEngine(provider: provider)
        let result = engine.focus(at: CGPoint(x: 20, y: 20), mode: .smart)
        suite.expect(result.outcome == .focused, "focus engine should focus accepted candidate")
        suite.expect(provider.focusCalls == 1, "focus engine should activate even a remembered focused field")

        let cancelledProvider = FakeFocusProvider()
        let cancelled = SmartFocusEngine(provider: cancelledProvider).focus(
            at: CGPoint(x: 20, y: 20),
            mode: .smart,
            shouldContinue: { false }
        )
        suite.expect(cancelled.outcome == .cancelled, "cancelled focus work should stop before AX snapshot")
        suite.expect(cancelledProvider.snapshotCalls == 0, "cancelled focus work must have no AX side effect")
    }

    private static func testStateMachine(_ suite: inout CheckSuite) {
        var hold = VoiceStateMachine(mode: .hold)
        let begin = hold.handle(.gestureBegan)
        suite.expect(hold.state == .arming, "hold gesture should arm")
        suite.expect(begin == [.resolveTarget(activationID: 1)], "hold gesture should request target resolution")
        _ = hold.handle(.resolutionStarted)
        suite.expect(hold.handle(.gestureEnded) == [.cancelResolution], "early release should cancel resolution")
        suite.expect(hold.handle(.targetResolved).isEmpty, "late resolution must be ignored")

        var watchdog = VoiceStateMachine(mode: .hold)
        _ = watchdog.handle(.gestureBegan)
        _ = watchdog.handle(.targetResolved)
        suite.expect(watchdog.state == .listening, "resolved target should enter listening")
        suite.expect(watchdog.handle(.watchdog) == [.stopVoice], "watchdog should stop voice once")
        suite.expect(watchdog.handle(.watchdog).isEmpty, "watchdog stop must be idempotent")
        suite.expect(
            watchdog.handle(.gestureEnded).isEmpty,
            "release after watchdog stop must not request another action"
        )
        _ = watchdog.handle(.stopCompleted)
        suite.expect(watchdog.state == .idle, "stop completion should return idle")
        suite.expect(
            watchdog.handle(.gestureEnded).isEmpty,
            "late release after watchdog completion must stay inert"
        )

        var toggle = VoiceStateMachine(mode: .toggle)
        _ = toggle.handle(.gestureBegan)
        _ = toggle.handle(.targetResolved)
        suite.expect(toggle.handle(.gestureEnded).isEmpty, "toggle mode ignores physical release")
        suite.expect(toggle.handle(.gestureBegan) == [.stopVoice], "next toggle gesture should stop voice")
    }

    private static func testSettings(_ suite: inout CheckSuite) {
        let suiteName = "VoicePointerSelfTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            suite.expect(false, "temporary UserDefaults suite unavailable")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        suite.expect(store.value.focusMode == .voiceOnly, "new installations should use voice-only focus")
        suite.expect(!store.value.allowSyntheticClickFallback, "new installations should not synthesize clicks")
        store.update {
            $0.focusMode = .currentOnly
            $0.gesture.trackpadEnabled = false
            $0.voiceShortcut.mode = .toggle
        }
        let restored = SettingsStore(defaults: defaults)
        suite.expect(restored.value.focusMode == .voiceOnly, "old focus mode should normalize to voice-only")
        suite.expect(!restored.value.gesture.trackpadEnabled, "trackpad setting should persist")
        suite.expect(restored.value.voiceShortcut.mode == .toggle, "voice mode should persist")
        suite.expect(restored.value.voiceShortcut.keyCode == 58, "default voice shortcut must be Left Option")
        suite.expect(
            restored.value.gesture.freshChordWindowMilliseconds == 350,
            "gesture freshness filter should persist at the anti-misfire default"
        )
        suite.expect(!restored.value.allowSyntheticClickFallback, "saved click fallback choice should persist")

        var legacy = VoicePointerSettings()
        legacy.voiceShortcut.keyCode = 63
        legacy.voiceShortcut.modifierMaskRawValue = UInt64(1 << 23)
        if let legacyData = try? JSONEncoder().encode(legacy) {
            defaults.set(legacyData, forKey: "voicePointer.settings.v1")
            let migrated = SettingsStore(defaults: defaults)
            suite.expect(migrated.value.voiceShortcut.keyCode == 58, "persisted Fn default must migrate to Left Option")
            suite.expect(
                migrated.value.voiceShortcut.modifierMaskRawValue == UInt64(1 << 19),
                "migrated shortcut must use the Option modifier mask"
            )
        } else {
            suite.expect(false, "legacy settings fixture should encode")
        }
    }

    private static func testGesturePipeline(_ suite: inout CheckSuite) async {
        let driver = MultitouchDriver()
        guard driver.resetTestTouchState() else {
            suite.expect(false, "gesture fixture reset refused real framework state")
            return
        }
        let counters = EventCounters()
        let monitor = MouseGestureMonitor(
            driver: driver,
            configuration: .init(trackpadEnabled: false),
            onBegin: { _ in counters.incrementBegin(); return true },
            onMove: { counters.recordMove($0) },
            onEnd: { counters.recordEnd($0) },
            onCancel: { counters.incrementCancel() }
        )
        guard
            let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: CGPoint(x: 10, y: 10),
                mouseButton: .left
            ),
            let dragged = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: CGPoint(x: 12, y: 11),
                mouseButton: .left
            ),
            let moved = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: 11, y: 12),
                mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: CGPoint(x: 12, y: 11),
                mouseButton: .left
            )
        else {
            suite.expect(false, "CGEvent mouse fixtures should be available")
            return
        }

        driver.injectTestTouchState(kind: .magicMouse, touchCount: 1, frameAgeSeconds: 0.01)
        suite.expect(
            !monitor.processEventForTesting(type: .leftMouseDown, event: down),
            "ordinary one-finger click must pass through"
        )

        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01)
        suite.expect(
            monitor.processEventForTesting(type: .leftMouseDown, event: down),
            "fresh two-finger physical mouseDown must be suppressed"
        )
        suite.expect(counters.snapshot().begin == 1, "recognized gesture must emit begin once")
        suite.expect(
            !monitor.processEventForTesting(type: .mouseMoved, event: moved),
            "mouseMoved fallback must track without suppressing cursor movement"
        )
        suite.expect(
            counters.snapshot().move == CGPoint(x: 11, y: 12),
            "mouseMoved fallback must report its location"
        )
        suite.expect(
            !monitor.processEventForTesting(type: .leftMouseDragged, event: dragged),
            "active drag must be passed through as cursor movement"
        )
        suite.expect(dragged.type == .mouseMoved, "active drag must lose its drag semantics")
        if let syntheticUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: CGPoint(x: 12, y: 11),
            mouseButton: .left
        ) {
            syntheticUp.setIntegerValueField(
                .eventSourceUserData,
                value: voicePointerSyntheticEventUserData
            )
            suite.expect(
                !monitor.processEventForTesting(type: .leftMouseUp, event: syntheticUp),
                "VoicePointer focus-fallback mouseUp must not end the physical gesture"
            )
            suite.expect(counters.snapshot().end == 0, "synthetic focus click must not emit release")
        }
        suite.expect(
            monitor.processEventForTesting(type: .leftMouseUp, event: up),
            "paired physical mouseUp must be suppressed"
        )
        let balanced = counters.snapshot()
        suite.expect(balanced.end == 1, "recognized gesture must emit one paired end")
        suite.expect(balanced.move == CGPoint(x: 12, y: 11), "active drag must report its location")
        suite.expect(balanced.release == CGPoint(x: 12, y: 11), "mouseUp must report its release location")
        suite.expect(
            !monitor.processEventForTesting(type: .leftMouseUp, event: up),
            "an unmatched second mouseUp must pass through"
        )

        let busyMonitor = MouseGestureMonitor(
            driver: driver,
            configuration: .init(trackpadEnabled: false),
            onBegin: { _ in false },
            onEnd: { _ in },
            onCancel: {}
        )
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01)
        suite.expect(
            !busyMonitor.processEventForTesting(type: .leftMouseDown, event: down),
            "a busy consumer must leave mouseDown untouched"
        )
        suite.expect(
            !busyMonitor.processEventForTesting(type: .leftMouseUp, event: up),
            "a busy consumer must not claim the following mouseUp"
        )

        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.30)
        suite.expect(
            !monitor.processEventForTesting(type: .leftMouseDown, event: down),
            "stale raw touch state must not consume a click"
        )

        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            newestTouchAgeSeconds: 1.30
        )
        suite.expect(
            !monitor.processEventForTesting(type: .leftMouseDown, event: down),
            "an old two-finger chord must not trigger a later ordinary click"
        )

        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            newestTouchAgeSeconds: 0.02,
            oldestTouchAgeSeconds: 0.65
        )
        suite.expect(
            !monitor.processEventForTesting(type: .leftMouseDown, event: down),
            "one fresh finger must not make a mixed-age chord eligible"
        )

        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            maximumMovement: 0.12
        )
        suite.expect(
            !monitor.processEventForTesting(type: .leftMouseDown, event: down),
            "a chord already moving before click must not trigger dictation"
        )

        driver.injectTestTouchState(kind: .builtInTrackpad, touchCount: 3, frameAgeSeconds: 0.01)
        suite.expect(
            !monitor.processEventForTesting(type: .leftMouseDown, event: down),
            "disabled trackpad gestures must pass through"
        )

        let trackpadCounters = EventCounters()
        let trackpadMonitor = MouseGestureMonitor(
            driver: driver,
            configuration: .init(trackpadEnabled: true),
            onBegin: { _ in trackpadCounters.incrementBegin(); return true },
            onMove: { trackpadCounters.recordMove($0) },
            onEnd: { trackpadCounters.recordEnd($0) },
            onCancel: { trackpadCounters.incrementCancel() }
        )
        driver.injectTestTouchState(
            kind: .builtInTrackpad,
            touchCount: 3,
            frameAgeSeconds: 0.01
        )
        suite.expect(
            trackpadMonitor.processEventForTesting(type: .leftMouseDown, event: down),
            "fresh three-finger trackpad press must start a gesture"
        )
        if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: 12, wheel2: 0, wheel3: 0) {
            suite.expect(
                trackpadMonitor.processEventForTesting(type: .scrollWheel, event: scroll),
                "active trackpad gesture must suppress system scroll/gesture events"
            )
        }
        if let swipeType = CGEventType(rawValue: 31),
           let swipe = CGEvent(source: nil) {
            swipe.type = swipeType
            suite.expect(
                trackpadMonitor.processEventForTesting(type: swipeType, event: swipe),
                "active trackpad gesture must suppress AppKit swipe events"
            )
        }
        suite.expect(
            driver.injectTestTouchDisplacement(kind: .builtInTrackpad, x: 0, y: 0.08),
            "trackpad displacement fixture must update"
        )
        trackpadMonitor.processTrackpadMotionForTesting()
        suite.expect(
            (trackpadCounters.snapshot().move?.y ?? 10) < -20,
            "positive trackpad surface Y must synthesize an upward Quartz movement"
        )
        suite.expect(
            driver.injectTestTouchDisplacement(kind: .builtInTrackpad, x: 0, y: 0),
            "trackpad return-to-center fixture must update"
        )
        trackpadMonitor.processTrackpadMotionForTesting()
        suite.expect(
            abs((trackpadCounters.snapshot().move?.y ?? 0) - down.location.y) < 1,
            "returning the trackpad chord to its origin must expose the center state"
        )
        suite.expect(
            trackpadMonitor.processEventForTesting(type: .leftMouseUp, event: up),
            "trackpad physical mouseUp must remain paired"
        )
        // Pinch may start only after dictation has ended. Exercise every
        // registered system-gesture type, not only scroll/swipe, while fresh
        // two-finger touch frames are present. No events are posted to macOS.
        // Injection appends a device; remove earlier three-finger fixtures.
        suite.expect(driver.resetTestTouchState(), "post-dictation pinch fixture must reset devices")
        driver.injectTestTouchState(
            kind: .builtInTrackpad, touchCount: 2, frameAgeSeconds: 0.01
        )
        for rawType: UInt32 in [18, 19, 20, 29, 30, 31, 32] {
            if let type = CGEventType(rawValue: rawType), let event = CGEvent(source: nil) {
                event.type = type
                suite.expect(
                    !trackpadMonitor.processEventForTesting(type: type, event: event),
                    "two-finger system gesture type \(rawType) must pass after dictation release"
                )
            } else {
                suite.expect(false, "system gesture fixture \(rawType) must be constructible")
            }
        }
        suite.expect(
            !trackpadMonitor.processEventForTesting(type: .leftMouseDown, event: down),
            "fresh two-finger trackpad press after dictation must not claim a new gesture"
        )
        suite.expect(
            !trackpadMonitor.processEventForTesting(type: .leftMouseUp, event: up),
            "two-finger trackpad mouse-up after dictation must pass through"
        )
        if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: 12, wheel2: 0, wheel3: 0) {
            suite.expect(
                !trackpadMonitor.processEventForTesting(type: .scrollWheel, event: scroll),
                "scroll/gesture events must pass through after trackpad release"
            )
        }
        if let swipeType = CGEventType(rawValue: 31),
           let swipe = CGEvent(source: nil) {
            swipe.type = swipeType
            suite.expect(
                !trackpadMonitor.processEventForTesting(type: swipeType, event: swipe),
                "AppKit swipe events must pass through after trackpad release"
            )
        }
        suite.expect(
            abs((trackpadCounters.snapshot().release?.y ?? 0) - down.location.y) < 1,
            "trackpad release must preserve the last visible center location"
        )

        let failureCounters = EventCounters()
        let failureMonitor = MouseGestureMonitor(
            driver: driver,
            configuration: .init(trackpadEnabled: false),
            onBegin: { _ in failureCounters.incrementBegin(); return true },
            onEnd: { location in failureCounters.recordEnd(location) },
            onCancel: { failureCounters.incrementCancel() },
            onFailure: { failureCounters.incrementFailure() }
        )
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01)
        suite.expect(
            failureMonitor.processEventForTesting(type: .leftMouseDown, event: down),
            "tap-failure fixture must begin an active gesture"
        )
        if let disabledEvent = CGEvent(source: nil) {
            suite.expect(
                !failureMonitor.processEventForTesting(
                    type: .tapDisabledByUserInput,
                    event: disabledEvent
                ),
                "a disabled Event Tap notification must pass through"
            )
            try? await Task.sleep(for: .milliseconds(10))
            let failed = failureCounters.snapshot()
            suite.expect(failed.cancel == 1, "a disabled Event Tap must cancel the active gesture once")
            suite.expect(failed.failure == 1, "a disabled Event Tap must notify the runtime once")
        } else {
            suite.expect(false, "disabled Event Tap fixture should be available")
        }
    }

    private static func testRollbackPlanner(_ suite: inout CheckSuite) {
        let insertion = DictationRollbackPlanner.insertedRange(
            originalText: "你好 world",
            originalSelection: NSRange(location: 2, length: 0),
            currentText: "你好这是听写 world"
        )
        suite.expect(insertion == NSRange(location: 2, length: 4), "rollback must isolate UTF-16 dictation text")
        suite.expect(
            DictationRollbackPlanner.insertedRange(
                originalText: "keep",
                originalSelection: NSRange(location: 1, length: 2),
                currentText: "knewp"
            ) == NSRange(location: 1, length: 3),
            "rollback must isolate dictation that replaced an original selection"
        )
        suite.expect(
            DictationRollbackPlanner.insertedRange(
                originalText: "prefix suffix",
                originalSelection: NSRange(location: 7, length: 0),
                currentText: "unrelated"
            ) == nil,
            "rollback must reject text that changed outside the insertion point"
        )
        suite.expect(
            DictationRollbackPlanner.recoverableInsertionRange(
                originalText: "原文🙂 手打",
                currentText: "原文🙂 手打 本次语音"
            ) == NSRange(
                location: ("原文🙂 手打" as NSString).length,
                length: (" 本次语音" as NSString).length
            ),
            "rollback must recover a single insertion when AX reports a stale caret"
        )
        suite.expect(
            DictationRollbackPlanner.recoverableInsertionRange(
                originalText: "",
                currentText: "整段语音"
            ) == NSRange(location: 0, length: ("整段语音" as NSString).length),
            "rollback must recover dictation inserted into an initially empty composer"
        )
        suite.expect(
            DictationRollbackPlanner.recoverableInsertionRange(
                originalText: "原文保留",
                currentText: "原文被改写"
            ) == nil,
            "rollback recovery must reject non-insertion edits"
        )

        let originalWithEmoji = "开😀终"
        let caretAfterEmoji = ("开😀" as NSString).length
        let dictatedEmoji = "👨‍👩‍👧‍👦"
        let currentWithEmoji = "开😀\(dictatedEmoji)终"
        suite.expect(
            DictationRollbackPlanner.insertedRange(
                originalText: originalWithEmoji,
                originalSelection: NSRange(location: caretAfterEmoji, length: 0),
                currentText: currentWithEmoji
            ) == NSRange(location: caretAfterEmoji, length: (dictatedEmoji as NSString).length),
            "rollback must measure emoji insertion and caret positions in UTF-16"
        )
        suite.expect(
            DictationRollbackPlanner.insertedRange(
                originalText: "A😀B",
                originalSelection: NSRange(location: 2, length: 0),
                currentText: "A😀听写B"
            ) == nil,
            "rollback must reject a caret that splits an emoji surrogate pair"
        )
    }

    private static func testComposerTextNormalizer(_ suite: inout CheckSuite) {
        suite.expect(
            ComposerTextNormalizer.logicalText(
                value: "",
                placeholder: "随心输入",
                characterCount: 0
            ) == "",
            "an empty composer must remain empty"
        )
        suite.expect(
            ComposerTextNormalizer.logicalText(
                value: "随心输入",
                placeholder: "随心输入",
                characterCount: 0
            ) == "",
            "placeholder-backed AXValue must normalize to empty"
        )
        suite.expect(
            ComposerTextNormalizer.logicalText(
                value: "随心输入",
                placeholder: "随心输入",
                characterCount: 4
            ) == "随心输入",
            "real text equal to the placeholder must be preserved"
        )
        suite.expect(
            ComposerTextNormalizer.logicalText(
                value: "真实文本",
                placeholder: "随心输入",
                characterCount: 0
            ) == nil,
            "contradictory AX metadata must fail closed"
        )
        suite.expect(
            ComposerTextNormalizer.logicalText(
                value: "随心输入",
                placeholder: "随心输入",
                characterCount: nil
            ) == nil,
            "ambiguous placeholder text without a count must fail closed"
        )
        suite.expect(
            ComposerTextNormalizer.logicalText(
                value: "普通正文",
                placeholder: "随心输入",
                characterCount: nil
            ) == "普通正文",
            "ordinary AXValue text must remain available"
        )
        suite.expect(
            ComposerTextNormalizer.logicalText(
                value: "\n使用 ChatGPT Work",
                placeholder: nil,
                accessibilityDescription: "使用 ChatGPT Work",
                characterCount: 16
            ) == "",
            "a whitespace-wrapped AXDescription duplicate must normalize to empty chrome"
        )
        suite.expect(
            ComposerTextNormalizer.logicalText(
                value: "使用 ChatGPT Work",
                placeholder: nil,
                accessibilityDescription: "使用 ChatGPT Work",
                characterCount: 15
            ) == "使用 ChatGPT Work",
            "exact user text equal to AXDescription must remain real text"
        )
    }

    private static func testRadialReleaseClassifier(_ suite: inout CheckSuite) {
        let anchor = CGPoint(x: 400, y: 500)
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .send,
                anchor: anchor,
                current: CGPoint(x: 400, y: 460)
            ) == .send,
            "upward Quartz movement must map to send"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .cancel,
                anchor: anchor,
                current: CGPoint(x: 400, y: 540)
            ) == .cancel,
            "downward Quartz movement must map to cancel"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .send,
                anchor: anchor,
                current: anchor
            ) == .stop,
            "no movement must remain stop even when a clamped HUD overlaps an action circle"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .cancel,
                anchor: nil,
                current: CGPoint(x: 400, y: 540)
            ) == .stop,
            "missing gesture anchor must use the safe stop action"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .stop,
                anchor: anchor,
                current: CGPoint(x: 400, y: 240),
                previousAction: .send
            ) == .send,
            "upward overshoot must remain send outside the visible dial"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .stop,
                anchor: anchor,
                current: CGPoint(x: 400, y: 760),
                previousAction: .cancel
            ) == .cancel,
            "downward overshoot must remain cancel outside the visible dial"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .stop,
                anchor: anchor,
                current: CGPoint(x: 400, y: 504),
                previousAction: .cancel
            ) == .stop,
            "returning to the center dead zone must disarm cancel"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .send,
                anchor: anchor,
                current: CGPoint(x: 400, y: 469),
                previousAction: .send
            ) == .send,
            "send must remain armed at the outer edge of its hysteresis band"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .send,
                anchor: anchor,
                current: CGPoint(x: 400, y: 471),
                previousAction: .send
            ) == .stop,
            "returning inside the wide center zone must disarm send"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .cancel,
                anchor: anchor,
                current: CGPoint(x: 400, y: 539),
                previousAction: .send
            ) == .stop,
            "crossing the center must not switch directly to cancel before its boundary"
        )
        suite.expect(
            RadialReleaseClassifier.classify(
                hitAction: .cancel,
                anchor: anchor,
                current: CGPoint(x: 400, y: 540),
                previousAction: .stop
            ) == .cancel,
            "cancel must arm only after leaving the center boundary"
        )
    }

    private static func testKeyboardEventShape(_ suite: inout CheckSuite) {
        let baseFlags: CGEventFlags = [.maskCommand]
        guard
            let down = CGEventKeyboardSender.makeEvent(.leftOption, isDown: true, baseFlags: baseFlags),
            let up = CGEventKeyboardSender.makeEvent(
                .leftOption,
                isDown: false,
                baseFlags: baseFlags.union(.maskAlternate)
            )
        else {
            suite.expect(false, "Left Option keyboard fixtures should be available")
            return
        }
        suite.expect(down.type == .flagsChanged, "Left Option down must use flagsChanged")
        suite.expect(up.type == .flagsChanged, "Left Option up must use flagsChanged")
        suite.expect(
            down.getIntegerValueField(.keyboardEventKeycode) == 58,
            "Left Option down must use the left Option virtual key code"
        )
        suite.expect(down.flags.contains(.maskAlternate), "Left Option down must add the Option flag")
        suite.expect(!up.flags.contains(.maskAlternate), "Left Option up must remove the Option flag")
        suite.expect(
            down.flags.contains(.maskCommand) && up.flags.contains(.maskCommand),
            "Left Option injection must preserve unrelated modifier flags"
        )
    }

    private static func testShortcutControllers(_ suite: inout CheckSuite) async {
        let sender = RecordingKeyboardSender()
        let hold = HoldVoiceShortcutController(sender: sender)
        await hold.modifierDown()
        await hold.modifierDown()
        await hold.modifierUp()
        await hold.modifierUp()
        let events = await sender.events
        suite.expect(events == ["down:leftOption", "up:leftOption"], "hold controller must emit one balanced key pair")
    }

    private static func testCoordinator(_ suite: inout CheckSuite) async {
        let timeline = EventTimeline()
        let sender = RecordingKeyboardSender(timeline: timeline)
        let actions = RecordingComposerActionExecutor(timeline: timeline)
        let provider = FakeFocusProvider()
        let coordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: provider),
            keyboardSender: sender,
            composerActionExecutor: actions
        )
        let activation = GestureActivation(
            location: CGPoint(x: 20, y: 20),
            button: .left,
            match: GestureMatch(
                deviceToken: 1,
                deviceKind: .magicMouse,
                touchCount: 2,
                newestTouchAgeSeconds: 0.02,
                maximumMovement: 0.001
            )
        )
        coordinator.gestureBegan(activation, settings: .init(focusMode: .smart))
        for _ in 0..<30 where coordinator.status != .listening {
            try? await Task.sleep(for: .milliseconds(5))
        }
        suite.expect(coordinator.status == .listening, "coordinator should enter listening after focus")
        await coordinator.gestureEnded()
        suite.expect(coordinator.status == .idle, "hold release should return coordinator to idle")
        let coordinatorEvents = await sender.snapshot()
        suite.expect(coordinatorEvents == ["down:leftOption", "up:leftOption"], "coordinator must balance injected modifier")
        suite.expect(actions.snapshot() == [.stop], "center release must preserve text")
        suite.expect(
            timeline.snapshot() == ["down:leftOption", "up:leftOption", "action:stop"],
            "center release must stop dictation before preserving text"
        )

        let sendTimeline = EventTimeline()
        let sendSender = RecordingKeyboardSender(timeline: sendTimeline)
        let sendActions = RecordingComposerActionExecutor(timeline: sendTimeline)
        let sendCoordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: FakeFocusProvider()),
            keyboardSender: sendSender,
            composerActionExecutor: sendActions
        )
        sendCoordinator.gestureBegan(activation, settings: .init(focusMode: .smart))
        for _ in 0..<30 where sendCoordinator.status != .listening {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await sendCoordinator.gestureEnded(action: .send)
        suite.expect(sendActions.snapshot() == [.send], "upper release must request send once")
        suite.expect(
            sendTimeline.snapshot() == ["down:leftOption", "up:leftOption", "action:send"],
            "send must happen strictly after dictation stops"
        )

        let cancelTimeline = EventTimeline()
        let cancelSender = RecordingKeyboardSender(timeline: cancelTimeline)
        let cancelActions = RecordingComposerActionExecutor(timeline: cancelTimeline)
        let cancelCoordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: FakeFocusProvider()),
            keyboardSender: cancelSender,
            composerActionExecutor: cancelActions
        )
        cancelCoordinator.gestureBegan(activation, settings: .init(focusMode: .smart))
        for _ in 0..<30 where cancelCoordinator.status != .listening {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await cancelCoordinator.gestureEnded(action: .cancel)
        suite.expect(cancelCoordinator.status == .idle, "lower release exits before resource draining")
        await cancelCoordinator.waitForCancelledResources()
        suite.expect(
            cancelActions.snapshot() == [.cancel],
            "lower release must request cancel once"
        )
        suite.expect(
            cancelTimeline.snapshot() == ["down:leftOption", "up:leftOption", "action:cancel"],
            "cancel must happen strictly after dictation stops"
        )

        let earlySender = RecordingKeyboardSender()
        let delayedProvider = FakeFocusProvider(delay: 0.05)
        let earlyCoordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: delayedProvider),
            keyboardSender: earlySender,
            composerActionExecutor: RecordingComposerActionExecutor()
        )
        earlyCoordinator.gestureBegan(activation, settings: .init(focusMode: .smart))
        await earlyCoordinator.gestureEnded()
        try? await Task.sleep(for: .milliseconds(80))
        let earlyEvents = await earlySender.snapshot()
        suite.expect(earlyEvents.isEmpty, "early physical release must not inject a modifier")
        suite.expect(delayedProvider.focusCalls == 0, "cancelled resolution must not focus a stale window")
    }

    private static func testReleaseSafety(_ suite: inout CheckSuite) async {
        let activation = GestureActivation(
            location: CGPoint(x: 20, y: 20),
            button: .left,
            match: GestureMatch(
                deviceToken: 1,
                deviceKind: .magicMouse,
                touchCount: 2,
                newestTouchAgeSeconds: 0.02,
                maximumMovement: 0.001
            )
        )

        for releaseAction in [VoiceReleaseAction.send, .cancel] {
            let actionExecutor = RecordingComposerActionExecutor()
            let sender = RecordingKeyboardSender()
            let coordinator = VoicePointerCoordinator(
                focusEngine: SmartFocusEngine(provider: FakeFocusProvider(delay: 0.05)),
                keyboardSender: sender,
                composerActionExecutor: actionExecutor
            )
            coordinator.gestureBegan(activation, settings: .init(focusMode: .smart))
            await coordinator.gestureEnded(action: releaseAction)
            try? await Task.sleep(for: .milliseconds(80))
            suite.expect(
                actionExecutor.snapshot() == (releaseAction == .send ? [.send] : []),
                "early send waits for ready and executes exactly once; cancel remains immediate"
            )
            let earlyKeyboardEvents = await sender.snapshot()
            suite.expect(
                earlyKeyboardEvents == (releaseAction == .send ? ["down:leftOption", "up:leftOption"] : []),
                "early send balances the shortcut; cancel does not start dictation"
            )
        }

        let cancelActions = RecordingComposerActionExecutor()
        let cancelSender = RecordingKeyboardSender()
        let cancelCoordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: FakeFocusProvider()),
            keyboardSender: cancelSender,
            composerActionExecutor: cancelActions
        )
        cancelCoordinator.gestureBegan(activation, settings: .init(focusMode: .smart))
        for _ in 0..<30 where cancelCoordinator.status != .listening {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await cancelCoordinator.cancel()
        suite.expect(cancelCoordinator.status == .idle, "system cancellation exits before resource draining")
        await cancelCoordinator.waitForCancelledResources()
        suite.expect(cancelActions.snapshot().isEmpty, "system cancellation must not execute send or clear")
        let cancelKeyboardEvents = await cancelSender.snapshot()
        suite.expect(
            cancelKeyboardEvents == ["down:leftOption", "up:leftOption"],
            "cancel must only release the held dictation shortcut"
        )

        let toggleActions = RecordingComposerActionExecutor()
        let toggleSender = RecordingKeyboardSender()
        let toggleCoordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: FakeFocusProvider()),
            keyboardSender: toggleSender,
            composerActionExecutor: toggleActions
        )
        var toggleSettings = VoicePointerSettings(focusMode: .smart)
        toggleSettings.voiceShortcut.mode = .toggle
        toggleCoordinator.gestureBegan(activation, settings: toggleSettings)
        for _ in 0..<30 where toggleCoordinator.status != .listening {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await toggleCoordinator.gestureEnded(action: .send)
        await toggleCoordinator.gestureEnded(action: .cancel)
        suite.expect(toggleCoordinator.status == .listening, "toggle mode must ignore directed physical releases")
        suite.expect(toggleActions.snapshot().isEmpty, "toggle mode direction must not execute send or clear")
        await toggleCoordinator.cancel()
        await toggleCoordinator.waitForCancelledResources()
        suite.expect(
            toggleActions.snapshot().isEmpty,
            "toggle cancellation must remain non-destructive after ignored directions"
        )
        let toggleKeyboardEvents = await toggleSender.snapshot()
        suite.expect(
            toggleKeyboardEvents == ["tap:leftOption", "tap:leftOption"],
            "toggle cancel must only balance the voice shortcut"
        )

        let suspendedActions = SuspendedComposerActionExecutor()
        let raceCoordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: FakeFocusProvider()),
            keyboardSender: RecordingKeyboardSender(),
            composerActionExecutor: suspendedActions
        )
        raceCoordinator.gestureBegan(activation, settings: .init(focusMode: .smart))
        for _ in 0..<30 where raceCoordinator.status != .listening {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let oldCompletion = Task { @MainActor in
            await raceCoordinator.gestureEnded(action: .send)
        }
        for _ in 0..<30 where !suspendedActions.hasStarted {
            try? await Task.sleep(for: .milliseconds(5))
        }
        suite.expect(suspendedActions.hasStarted, "race fixture must suspend an in-flight send")
        raceCoordinator.invalidatePendingActions()
        await raceCoordinator.cancel()
        raceCoordinator.gestureBegan(activation, settings: .init(focusMode: .smart))
        for _ in 0..<30 where raceCoordinator.status != .listening {
            try? await Task.sleep(for: .milliseconds(5))
        }
        suspendedActions.resume(with: .targetChanged)
        await oldCompletion.value
        suite.expect(
            raceCoordinator.status == .listening,
            "a cancelled old completion must not overwrite a newer listening session"
        )
        raceCoordinator.invalidatePendingActions()
        await raceCoordinator.cancel()
    }
}

private final class EventCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var begin = 0
    private var end = 0
    private var cancel = 0
    private var failure = 0
    private var lastMove: CGPoint?
    private var lastRelease: CGPoint?

    func incrementBegin() { lock.withLock { begin += 1 } }
    func recordMove(_ location: CGPoint) { lock.withLock { lastMove = location } }
    func recordEnd(_ location: CGPoint) {
        lock.withLock {
            end += 1
            lastRelease = location
        }
    }
    func incrementCancel() { lock.withLock { cancel += 1 } }
    func incrementFailure() { lock.withLock { failure += 1 } }
    func snapshot() -> (
        begin: Int,
        end: Int,
        cancel: Int,
        failure: Int,
        move: CGPoint?,
        release: CGPoint?
    ) {
        lock.withLock { (begin, end, cancel, failure, lastMove, lastRelease) }
    }
}

private final class FakeFocusProvider: @unchecked Sendable, FocusProviding {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var focused = false
    private(set) var snapshotCalls = 0
    private(set) var focusCalls = 0

    init(delay: TimeInterval = 0) { self.delay = delay }

    func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.withLock { snapshotCalls += 1 }
        let candidate = FocusCandidate(
            identifier: "composer",
            role: "AXTextArea",
            label: "Message",
            frame: CGRect(x: 0, y: 0, width: 400, height: 80),
            isMultiline: true,
            isPointerInside: true
        )
        return FocusSnapshot(contextIdentifier: "fixture", bundleIdentifier: "test.fixture", candidates: [candidate])
    }

    func setFocused(candidateIdentifier: String) -> Bool {
        lock.withLock {
            focusCalls += 1
            focused = true
        }
        return true
    }

    func isFocused(candidateIdentifier: String) -> Bool { lock.withLock { focused } }
    func synthesizeClick(candidateIdentifier: String) -> Bool { false }
}

private final class EventTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.withLock { events.append(event) } }
    func snapshot() -> [String] { lock.withLock { events } }
}

private actor RecordingKeyboardSender: KeyboardEventSending {
    private(set) var events: [String] = []
    private let timeline: EventTimeline?

    init(timeline: EventTimeline? = nil) {
        self.timeline = timeline
    }

    func snapshot() -> [String] { events }
    func keyDown(_ modifier: VoiceModifier) {
        let event = "down:\(modifier.rawValue)"
        events.append(event)
        timeline?.append(event)
    }
    func keyUp(_ modifier: VoiceModifier) {
        let event = "up:\(modifier.rawValue)"
        events.append(event)
        timeline?.append(event)
    }
    func tap(_ modifier: VoiceModifier) {
        let event = "tap:\(modifier.rawValue)"
        events.append(event)
        timeline?.append(event)
    }
}

private final class RecordingComposerActionExecutor: @unchecked Sendable, ComposerActionExecuting {
    private let lock = NSLock()
    private let timeline: EventTimeline?
    private var actions: [VoiceReleaseAction] = []

    init(timeline: EventTimeline? = nil) {
        self.timeline = timeline
    }

    func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
        .ready(ComposerActionSession(cancellationToken: cancellationToken))
    }

    func perform(
        _ action: VoiceReleaseAction,
        session: ComposerActionSession?
    ) async -> ComposerActionOutcome {
        lock.withLock { actions.append(action) }
        timeline?.append("action:\(action.rawValue)")
        switch action {
        case .stop: return .kept
        case .send: return .sent
        case .cancel: return .clearedCurrentInput
        }
    }

    func cancel(session: ComposerActionSession?) {}
    func snapshot() -> [VoiceReleaseAction] { lock.withLock { actions } }
}

@MainActor
private final class SuspendedComposerActionExecutor: ComposerActionExecuting {
    private var continuation: CheckedContinuation<ComposerActionOutcome, Never>?
    private(set) var hasStarted = false

    func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
        .ready(ComposerActionSession(cancellationToken: cancellationToken))
    }

    func perform(
        _ action: VoiceReleaseAction,
        session: ComposerActionSession?
    ) async -> ComposerActionOutcome {
        hasStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    nonisolated func cancel(session: ComposerActionSession?) {}

    func resume(with outcome: ComposerActionOutcome) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: outcome)
    }
}
