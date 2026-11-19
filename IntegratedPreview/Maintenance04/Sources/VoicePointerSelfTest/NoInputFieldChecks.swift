import Foundation
import CoreGraphics
@_spi(Testing) import VoicePointerCore

/// Production coordinator with injected boundaries only: no AX, gesture hardware, audio or network.
@MainActor
enum NoInputFieldChecks {
    private final class NoopFocusProvider: FocusProviding, @unchecked Sendable {
        func snapshot(at: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? { nil }
        func setFocused(candidateIdentifier: String) -> Bool { false }
        func isFocused(candidateIdentifier: String) -> Bool { false }
        func synthesizeClick(candidateIdentifier: String) -> Bool { false }
    }
    private final class Composer: ComposerActionExecuting, InlineTranscriptDelivering, KeptDeliveryReporting, @unchecked Sendable {
        private let lock = NSLock()
        private var reason: ComposerSessionStartFailureReason? = .notEditable
        private var unavailable = false
        private var secureField = false
        private var begins = 0, deliveries = 0, performs = 0, drafts = 0, reads = 0
        private var sessions: [(ComposerActionSession, OperationCancellationToken)] = []
        func configure(reason: ComposerSessionStartFailureReason?, unavailable: Bool = false, secureField: Bool = false) {
            lock.withLock { self.reason = reason; self.unavailable = unavailable; self.secureField = secureField }
        }
        var counts: [Int] { lock.withLock { [begins, deliveries, performs, drafts, reads] } }
        func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
            lock.withLock {
                begins += 1
                if unavailable { return .unavailable }
                if let reason { return .forFailure(reason) }
                let id = UInt64(begins)
                let session = ComposerActionSession(testIdentifier: id, cancellationToken: cancellationToken, isSecureField: secureField)
                sessions.append((session, cancellationToken))
                return .ready(session)
            }
        }
        func deliver(text: String, action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
            lock.withLock { deliveries += 1 }
            return session?.isCancelled == false ? .kept : .deliveryFailed
        }
        func perform(_ action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
            lock.withLock { performs += 1 }; return .kept
        }
        func updateDraft(text: String, sequence: UInt64, session: ComposerActionSession?) async -> InlineDraftUpdateOutcome {
            lock.withLock { drafts += 1 }; return .updated
        }
        func takeKeptBaseline(for session: ComposerActionSession?) -> KeptDictationBaseline? {
            lock.withLock { reads += 1 }; return nil
        }
        func takeRevisit(for session: ComposerActionSession?) -> FieldRevisitSample? {
            lock.withLock { reads += 1 }; return nil
        }
        func cancel(session: ComposerActionSession?) {
            // Invalidating the synthetic session needs no editor operation.
            lock.withLock { sessions.first { $0.0 == session }?.1 }?.cancel()
        }
    }

    private final class Observer: DictationEditObserving {
        var began = 0, kept = 0, comparisons = 0, receivers = 0
        func sessionBegan(revisit: FieldRevisitSample?) { began += 1 }
        func dictationKept(_ record: DictationRecord, baseline: KeptDictationBaseline) { kept += 1 }
        func enhancementReceiver() -> (@MainActor @Sendable (EnhancementComparison) -> Void)? {
            receivers += 1; return nil
        }
        func doubaoEnhancementCompared(_ comparison: EnhancementComparison, baseline: KeptDictationBaseline) { comparisons += 1 }
        var untouched: Bool { began == 0 && kept == 0 && comparisons == 0 && receivers == 0 }
    }

    private final class Backend: SpeechInputBackend {
        var isQuiescent = true
        let capabilities: SpeechInputCapabilities
        var startCount = 0, finishCount = 0, cancelCount = 0
        var finishError: String?
        var holdFinish = false, finishing = false
        var startThrows = false
        var contextTermCount = -1
        private var finishWaiter: CheckedContinuation<Void, Never>?
        private var snapshot: VoiceInputSnapshot?
        private var callback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
        private var sequence: UInt64 = 0
        init(mode: VoiceInputMode = .voiceNative) {
            capabilities = .init(deliveryKind: mode == .voiceNative ? .transcriptStream : .externalEditor,
                                 supportsPartialText: mode == .voiceNative, supportsHints: false)
        }
        private enum StartupError: Error { case synthetic }
        func start(snapshot: VoiceInputSnapshot, onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void) async throws {
            startCount += 1; self.snapshot = snapshot; callback = onEvent; isQuiescent = false
            contextTermCount = snapshot.localHotwords.count + (snapshot.localContext?.recent.count ?? 0)
            if startThrows { throw StartupError.synthetic }
            emit(.ready)
        }
        func emit(_ kind: SpeechInputEvent.Kind, code: String? = nil) {
            guard let snapshot else { return }
            sequence += 1
            callback?(.init(sessionID: snapshot.sessionID, sequence: sequence, observedMilliseconds: Double(sequence),
                            kind: kind, text: kind == .partial || kind == .final ? "synthetic_no_field_result" : nil, errorCode: code))
        }
        func finish() async {
            finishCount += 1; finishing = true
            if holdFinish { await withCheckedContinuation { finishWaiter = $0 } }
            if let finishError { emit(.failed, code: finishError) }
            else { emit(capabilities.deliveryKind == .transcriptStream ? .final : .stopped) }
            isQuiescent = true
        }
        func cancel() async { cancelCount += 1; isQuiescent = true }
        func unblockFinish() {
            holdFinish = false
            let waiter = finishWaiter; finishWaiter = nil; waiter?.resume()
        }
    }

    private static func activation() -> GestureActivation {
        .init(location: .init(x: 20, y: 20), button: .left,
              match: .init(deviceToken: 1, deviceKind: .magicMouse, touchCount: 2,
                           newestTouchAgeSeconds: 0.01, maximumMovement: 0.001))
    }
    private static func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    static func run() async -> [String] {
        var failures: [String] = [], assertions = 0
        func check(_ value: Bool, _ name: String) {
            assertions += 1
            if !value { failures.append("event=nofield_check,state=failed,case=" + name) }
        }
        let absent: Set<ComposerSessionStartFailureReason> = [.noFrontmostApplication, .wrongProcess, .noFocusedElement, .notEditable]
        for reason in ComposerSessionStartFailureReason.allCases {
            let expected: ComposerSessionStartResult = reason == .secureInput
                ? .secureFieldUnavailable : (absent.contains(reason) ? .noInputField(.init(reason: reason)) : .unavailable)
            check(ComposerSessionStartResult.forFailure(reason) == expected,
                  "reason_" + reason.rawValue)
        }
        check(VoicePointerSettings().focusMode == .voiceOnly, "default_voice_only")
        for mode in [FocusMode.smart, .currentOnly, .voiceOnly] {
            let name = "VoicePointerNoFieldChecks." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: name) else { check(false, "fixture_defaults"); continue }
            defer { defaults.removePersistentDomain(forName: name) }
            let old = VoicePointerSettings(focusMode: mode, gesture: .init(trackpadEnabled: false), allowSyntheticClickFallback: true)
            do {
                defaults.set(try JSONEncoder().encode(old), forKey: "voicePointer.settings.v1")
                let loaded = SettingsStore(defaults: defaults).value
                check(loaded.focusMode == .voiceOnly, "migrate_" + mode.rawValue)
                check(loaded.allowSyntheticClickFallback && !loaded.gesture.trackpadEnabled, "preserve_other_fields_" + mode.rawValue)
                let saved = try JSONDecoder().decode(VoicePointerSettings.self, from: defaults.data(forKey: "voicePointer.settings.v1")!)
                check(saved.focusMode == .voiceOnly, "persist_normalization_" + mode.rawValue)
            } catch { check(false, "settings_fixture_codec") }
        }
        let settings = VoicePointerSettings()
        let native = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "zh")
        let doubao = try! VoiceInputSelection(mode: .doubao, routeID: "doubao-system", language: "zh")
        for selection in [native, doubao] {
            let composer = Composer(), observer = Observer(), backend = Backend(mode: selection.mode)
            composer.configure(reason: nil, secureField: true)
            var records = 0, memories = 0, transcriptTexts = 0
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: NoopFocusProvider()),
                composerActionExecutor: composer,
                transcriptHandler: { if !($0.text ?? "").isEmpty { transcriptTexts += 1 } },
                dictationHandler: { _ in records += 1 }, memoryHandler: { _, _, _ in memories += 1 },
                learningObserver: observer)
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            _ = coordinator.gestureBegan(activation(), settings: settings, selection: selection,
                                          localHotwords: ["synthetic"])
            check(await wait { backend.startCount == 1 }, "secure_backend_" + selection.mode.rawValue)
            if selection.mode == .voiceNative { backend.emit(.partial) }
            await coordinator.gestureEnded()
            check(composer.counts[selection.mode == .voiceNative ? 1 : 2] == 1,
                  "secure_delivered_" + selection.mode.rawValue)
            check(records == 0 && memories == 0 && observer.untouched && transcriptTexts == 0 &&
                  composer.counts[3] == 0 && composer.counts[4] == 0 && backend.contextTermCount == 0,
                  "secure_no_history_learning_reads_" + selection.mode.rawValue)
            await coordinator.applicationWillTerminate()
        }
        // R1: no input field never even queries cloud admission; an editable field still does.
        for hasTarget in [false, true] {
            let composer = Composer(), backend = Backend()
            composer.configure(reason: hasTarget ? nil : .notEditable)
            var admissionCalls = 0
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: NoopFocusProvider()),
                composerActionExecutor: composer, cloudAdmissionInputs: { _ in admissionCalls += 1; return nil })
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            let cloud = try! VoiceInputSelection(mode: .voiceNative, routeID: "aliyun", language: "zh")
            check(coordinator.gestureBegan(activation(), settings: settings, selection: cloud), "cloud_target_start")
            check(await wait { backend.startCount == 1 }, "cloud_target_backend")
            check(admissionCalls == (hasTarget ? 1 : 0), "cloud_target_admission")
            await coordinator.cancel()
            await coordinator.applicationWillTerminate()
        }
        for selection in [native, doubao] {
            for action in [VoiceReleaseAction.stop, .send, .cancel] {
                let composer = Composer(), observer = Observer(), backend = Backend(mode: selection.mode)
                var records = 0, outcomes = 0, failuresShown = 0
                let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: NoopFocusProvider()),
                    composerActionExecutor: composer, outcomeHandler: { _, _, _ in outcomes += 1 },
                    statusHandler: { status, _ in if case .failed = status { failuresShown += 1 } },
                    dictationHandler: { _ in records += 1 }, learningObserver: observer)
                coordinator.setSpeechBackendFactoryForTesting { _ in backend }
                let label = selection.mode.rawValue + "_" + action.rawValue
                check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "start_" + label)
                check(await wait { coordinator.status == .listening }, "listening_" + label)
                check(backend.startCount == 1, "backend_started_" + label)
                if selection.mode == .voiceNative { backend.emit(.partial) }
                check(!coordinator.gestureBegan(activation(), settings: settings, selection: selection), "duplicate_ignored_" + label)
                await coordinator.gestureEnded(action: action)
                check(backend.finishCount == 1 && backend.isQuiescent, "normal_finish_" + label)
                check(Array(composer.counts.dropFirst()) == [0, 0, 0, 0], "no_editor_calls_" + label)
                check(observer.untouched && records == 0 && outcomes == 0, "no_record_learning_feedback_" + label)
                if action == .send {
                    let expected = VoiceIssuePresentationPolicy.resolve(code: .sendNoTarget, stage: .send, safeAction: .refocusInput)
                    check(coordinator.status == .failed(expected.message) && failuresShown == 1 && coordinator.lastIssuePresentation == expected,
                          "no_target_send_hint_" + label)
                } else {
                    check(coordinator.status == .idle && failuresShown == 0 && coordinator.lastIssuePresentation == nil,
                          "quiet_idle_" + label)
                }
                // Same coordinator immediately accepts an ordinary field after a targetless session.
                if selection.mode == .voiceNative && action == .stop {
                    composer.configure(reason: nil)
                    let next = Backend()
                    coordinator.setSpeechBackendFactoryForTesting { _ in next }
                    check(coordinator.gestureBegan(activation(), settings: settings, selection: native), "next_start")
                    check(await wait { coordinator.status == .listening }, "next_listening")
                    await coordinator.gestureEnded()
                    check(composer.counts[1] == 1 && observer.began == 1 && records == 1 && outcomes == 1,
                          "next_normal_delivery")
                }
                await coordinator.applicationWillTerminate()
            }
        }
        // A verified secure role reports its readback limitation; other binding
        // failures keep the existing target-unavailable presentation.
        for reason in ComposerSessionStartFailureReason.allCases where !absent.contains(reason) {
            let composer = Composer(), backend = Backend()
            composer.configure(reason: reason)
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: NoopFocusProvider()), composerActionExecutor: composer)
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            _ = coordinator.gestureBegan(activation(), settings: settings, selection: native)
            let expectedCode: VoiceIssueCode = reason == .secureInput ? .safeInputBlocked : .targetUnavailable
            check(await wait { coordinator.lastIssuePresentation?.code == expectedCode }, "unavailable_" + reason.rawValue)
            check(backend.startCount == 0, "unavailable_no_backend_" + reason.rawValue)
            await coordinator.applicationWillTerminate()
        }
        for error in ["SYNTHETIC_RECOGNITION_FAILURE", "HYBRID_FINAL_INCOMPLETE", "MICROPHONE_NO_SOUND"] {
            for noTarget in [true, false] {
                let composer = Composer(), backend = Backend()
                composer.configure(reason: noTarget ? .notEditable : nil); backend.finishError = error
                let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: NoopFocusProvider()), composerActionExecutor: composer)
                coordinator.setSpeechBackendFactoryForTesting { _ in backend }
                _ = coordinator.gestureBegan(activation(), settings: settings, selection: native)
                check(await wait { coordinator.status == .listening }, "failure_listening")
                // This fixture tests a spoken failure. Silent sends bypass ASR
                // failure separately in SilentSendChecks (S1).
                GestureSpeechActivity.shared.recordCapture(peakLevel: 0.04)
                await coordinator.gestureEnded(action: .send)
                let missingField = VoiceIssuePresentationPolicy.resolve(code: .sendNoTarget, stage: .send, safeAction: .refocusInput)
                check(noTarget ? coordinator.status == .failed(missingField.message) && coordinator.lastIssuePresentation == missingField
                               : coordinator.lastIssuePresentation == VoiceIssuePresentationPolicy.forBackendCode(error),
                      "failure_visibility_" + error + (noTarget ? "_absent" : "_normal"))
                check(backend.isQuiescent && composer.counts[1] == 0, "failed_no_delivery")
                await coordinator.applicationWillTerminate()
            }
        }
        // A failure while still listening is quiet, and a later real field still receives its result.
        do {
            let composer = Composer(), backend = Backend()
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: NoopFocusProvider()), composerActionExecutor: composer)
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            _ = coordinator.gestureBegan(activation(), settings: settings, selection: native)
            check(await wait { coordinator.status == .listening }, "live_failure_listening")
            backend.emit(.failed, code: "SYNTHETIC_RECOGNITION_FAILURE")
            check(await wait { coordinator.status == .idle && backend.isQuiescent }, "live_failure_quiet")
            check(coordinator.lastIssuePresentation == nil, "live_failure_no_toast")
            await coordinator.applicationWillTerminate()
        }
        // An old no-target finish resumes after cancellation and a new normal session; it cannot clear the new flag/state.
        do {
            let composer = Composer(), old = Backend(), next = Backend()
            old.holdFinish = true
            var builds = 0
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: NoopFocusProvider()), composerActionExecutor: composer)
            coordinator.setSpeechBackendFactoryForTesting { _ in builds += 1; return builds == 1 ? old : next }
            _ = coordinator.gestureBegan(activation(), settings: settings, selection: native)
            check(await wait { coordinator.status == .listening }, "race_old_listening")
            let stopping = Task { @MainActor in await coordinator.gestureEnded(action: .send) }
            check(await wait { old.finishing }, "race_finish_waits")
            check(coordinator.status != .idle && composer.counts[1] == 0, "race_no_early_cleanup")
            await coordinator.cancel()
            composer.configure(reason: nil)
            _ = coordinator.gestureBegan(activation(), settings: settings, selection: native)
            old.unblockFinish(); await stopping.value
            check(await wait { coordinator.status == .listening && next.startCount == 1 }, "race_new_listening")
            await coordinator.gestureEnded()
            check(coordinator.status == .idle && composer.counts[1] == 1, "race_only_new_delivered")
            await coordinator.applicationWillTerminate()
        }
        // Startup errors must remain visible even without a field.
        do {
            let composer = Composer(), backend = Backend(); backend.startThrows = true
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: NoopFocusProvider()), composerActionExecutor: composer)
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            _ = coordinator.gestureBegan(activation(), settings: settings, selection: native)
            check(await wait { coordinator.lastIssuePresentation?.code == .recognitionStartFailed }, "startup_error_visible")
            await coordinator.applicationWillTerminate()
        }
        print("NOFIELD_PASS assertions=\(assertions) failures=\(failures.count) ax=0 hardware=0 audio=0 network=0")
        return failures
    }
}
