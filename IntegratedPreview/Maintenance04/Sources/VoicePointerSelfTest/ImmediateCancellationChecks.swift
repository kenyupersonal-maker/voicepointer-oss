// T13: Controlled late-final and resource-owner tests against the production coordinator. No AX/capture/worker.
import Foundation
import CoreGraphics
@_spi(Testing) import VoicePointerCore

@MainActor enum ImmediateCancellationChecks {
    private final class Backend: SpeechInputBackend, SpeechCaptureCancellationInvalidating {
        var isQuiescent = true
        let capabilities = SpeechInputCapabilities(deliveryKind: .transcriptStream, supportsPartialText: true, supportsHints: false)
        var snapshot: VoiceInputSnapshot?
        var callback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
        var cancelCount = 0, finishCount = 0
        var holdCancel = true, holdFinish = false
        var cancelling = false, finishing = false
        var acceptsPCM = true
        func invalidateCaptureForCancellation() { acceptsPCM = false }
        private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
        private var finishWaiters: [CheckedContinuation<Void, Never>] = []
        func start(snapshot: VoiceInputSnapshot, onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void) async throws {
            self.snapshot = snapshot; callback = onEvent; isQuiescent = false
            onEvent(.init(sessionID: snapshot.sessionID, sequence: 0, observedMilliseconds: 0, kind: .ready))
        }
        func finish() async {
            finishCount += 1; finishing = true
            if holdFinish { await withCheckedContinuation { finishWaiters.append($0) } }
            else { isQuiescent = true }
        }
        func cancel() async {
            cancelCount += 1; cancelling = true
            if holdCancel { await withCheckedContinuation { cancelWaiters.append($0) } }
            else { isQuiescent = true }
        }
        func lateFinal() {
            guard let snapshot else { return }
            // Deliberately retains the callback after cancel: the coordinator must reject the stale event itself.
            callback?(.init(sessionID: snapshot.sessionID, sequence: 1, observedMilliseconds: 1, kind: .final, text: "synthetic_t13_final"))
            callback?(.init(sessionID: snapshot.sessionID, sequence: 2, observedMilliseconds: 2, kind: .partial, text: "synthetic_t13_late"))
        }
        func partial() {
            guard let snapshot else { return }
            callback?(.init(sessionID: snapshot.sessionID, sequence: 1, observedMilliseconds: 1, kind: .partial, text: "synthetic_t13_draft"))
        }
        func release() {
            isQuiescent = true; holdCancel = false; holdFinish = false
            let waiting = cancelWaiters + finishWaiters; cancelWaiters = []; finishWaiters = []
            waiting.forEach { $0.resume() }
        }
    }
    private final class DraftComposer: ComposerActionExecuting, InlineTranscriptDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var updateOwned = false, writeCount = 0, cancellationCount = 0
        var updating: Bool { lock.withLock { updateOwned } }
        var writes: Int { lock.withLock { writeCount } }
        var cancellations: Int { lock.withLock { cancellationCount } }
        private var pending: CheckedContinuation<Void, Never>?
        private var sessions: [(ComposerActionSession, OperationCancellationToken)] = []
        var beginCount: Int { lock.withLock { sessions.count } }
        var newestIsValid: Bool { lock.withLock { sessions.last?.1.isCancelled == false } }
        func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
            lock.withLock {
                let session = ComposerActionSession(testIdentifier: UInt64(sessions.count + 1), cancellationToken: cancellationToken)
                sessions.append((session, cancellationToken)); return .ready(session)
            }
        }
        func updateDraft(text: String, sequence: UInt64, session: ComposerActionSession?) async -> InlineDraftUpdateOutcome {
            // Simulates an operation already queued in the AX worker, ignoring Task cancellation.
            await withCheckedContinuation { continuation in lock.withLock { updateOwned = true; pending = continuation } }
            lock.withLock { updateOwned = false }
            guard session?.areDraftUpdatesCancelled == false else { return .abandoned }
            lock.withLock { writeCount += 1 }; return .updated
        }
        func release() {
            let continuation = lock.withLock { let current = pending; pending = nil; return current }
            continuation?.resume()
        }
        func perform(_ action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
            guard session?.isCancelled == false else { return .targetChanged }
            if action == .cancel { lock.withLock { cancellationCount += 1 } }
            return .nothingToCancel
        }
        func deliver(text: String, action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
            await perform(action, session: session)
        }
        func cancel(session: ComposerActionSession?) {
            lock.withLock { sessions.first { $0.0 == session }?.1 }?.cancel()
        }
    }
    private final class Focus: FocusProviding, @unchecked Sendable {
        func snapshot(at: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? {
            .init(contextIdentifier: "synthetic_t13", bundleIdentifier: nil,
                  candidates: [.init(identifier: "synthetic_t13", role: "AXTextArea", frame: .init(x: 0, y: 0, width: 100, height: 40))])
        }
        func setFocused(candidateIdentifier: String) -> Bool { true }
        func isFocused(candidateIdentifier: String) -> Bool { true }
        func synthesizeClick(candidateIdentifier: String) -> Bool { true }
    }
    private final class Composer: ComposerActionExecuting, TranscriptDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [VoiceReleaseAction] = []
        private var sessions: [(ComposerActionSession, OperationCancellationToken)] = []
        var delivered: [VoiceReleaseAction] { lock.withLock { actions } }
        func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
            lock.withLock {
                let session = ComposerActionSession(testIdentifier: UInt64(sessions.count + 1), cancellationToken: cancellationToken)
                sessions.append((session, cancellationToken)); return .ready(session)
            }
        }
        func perform(_ action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
            guard session?.isCancelled == false else { return .targetChanged }
            lock.withLock { actions.append(action) }
            return action == .cancel ? .clearArmed : .kept
        }
        func deliver(text: String, action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
            await perform(action, session: session)
        }
        func cancel(session: ComposerActionSession?) {
            let token = lock.withLock { sessions.first { $0.0 == session }?.1 }
            token?.cancel()
        }
    }
    private static func activation() -> GestureActivation {
        .init(location: .init(x: 20, y: 20), button: .left,
              match: .init(deviceToken: 1, deviceKind: .magicMouse, touchCount: 2, newestTouchAgeSeconds: 0.01, maximumMovement: 0.001))
    }
    private static func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
    static func run() async -> [String] {
        var failures: [String] = [], cases = 0
        func check(_ result: Bool, _ code: String) { cases += 1; if !result { failures.append("event=cancel_check,state=failed,case=" + code) } }
        let settings = VoicePointerSettings(focusMode: .smart)
        let selection = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "zh")
        // A Stop is already waiting for a final when Cancel arrives. Neither finish nor cleanup may block UI exit.
        do {
            let composer = Composer(), old = Backend(), next = Backend()
            old.holdFinish = true; next.holdCancel = false
            var builds = 0, finals = 0
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: composer,
                transcriptHandler: { if $0.kind == .final { finals += 1 } })
            coordinator.setSpeechBackendFactoryForTesting { _ in builds += 1; return builds == 1 ? old : next }
            check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "start_old")
            check(await wait { coordinator.status == .listening }, "old_listening")
            let stopping = Task { @MainActor in await coordinator.gestureEnded(action: .stop) }
            check(await wait { old.finishing }, "stop_waits_final")
            await coordinator.cancel()
            check(coordinator.status == .idle && !old.isQuiescent, "cancel_idle_before_drain")
            check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "next_queued")
            old.lateFinal()
            check(finals == 0 && composer.delivered.isEmpty, "late_final_no_delivery")
            check(await wait { old.cancelling }, "cleanup_owns_old")
            check(builds == 1, "new_capture_waits_old_owner")
            old.release(); await stopping.value
            await coordinator.waitForCancelledResources()
            check(await wait { coordinator.status == .listening && builds == 2 }, "next_starts_after_drain")
            old.lateFinal(); next.lateFinal()
            check(await wait { composer.delivered == [.stop] && coordinator.status == .idle }, "only_next_delivered")
            check(finals == 1 && next.cancelCount == 0, "old_cleanup_preserves_next")
            await coordinator.applicationWillTerminate()
        }
        // Fifty real coordinator cancel/start transitions, with an intentionally late old final each time.
        do {
            let composer = Composer()
            var backends: [Backend] = [], finals = 0
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: composer,
                transcriptHandler: { if $0.kind == .final { finals += 1 } })
            coordinator.setSpeechBackendFactoryForTesting { _ in let backend = Backend(); backends.append(backend); return backend }
            check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "rapid_initial")
            check(await wait { coordinator.status == .listening }, "rapid_initial_ready")
            for round in 0..<50 {
                guard let old = backends.last else { check(false, "rapid_missing"); break }
                // Exercise the production synchronous invalidation path and direct async Cancel alternately.
                if round % 2 == 0 { coordinator.invalidatePendingActions() } else { await coordinator.cancel() }
                check(coordinator.status == .idle, "rapid_idle")
                check(!old.acceptsPCM, "rapid_pcm_closed_before_cancel_returns")
                check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "rapid_begin")
                await coordinator.gestureEnded(action: .cancel, expectedSessionID: old.snapshot?.sessionID)
                check(coordinator.status != .idle, "rapid_old_release_cannot_cancel_new")
                old.lateFinal()
                check(finals == 0 && composer.delivered.isEmpty, "rapid_stale_discard")
                check(await wait { old.cancelling }, "rapid_cleanup_started")
                old.release()
                await coordinator.waitForCancelledResources()
                check(await wait { backends.count == round + 2 && coordinator.status == .listening }, "rapid_new_owner")
                old.lateFinal()
                check(coordinator.status == .listening && finals == 0, "rapid_late_cleanup_no_state_mutation")
            }
            if let last = backends.last {
                last.lateFinal()
                check(await wait { composer.delivered == [.stop] && coordinator.status == .idle }, "rapid_final_delivery")
            }
            check(backends.count == 51 && backends.dropLast().allSatisfy { $0.cancelCount == 1 }, "fifty_unique_owners")
            check(finals == 1 && !composer.delivered.contains(.send), "no_send_or_duplicate_delivery")
            await coordinator.applicationWillTerminate()
        }
        // Swipe Cancel uses existing target-bound cancellation, without asking the native backend to finish.
        do {
            let composer = Composer(), backend = Backend()
            var feedback: ComposerActionFeedback?
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: composer,
                outcomeHandler: { _, _, value in feedback = value })
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "swipe_begin")
            check(await wait { coordinator.status == .listening }, "swipe_ready")
            await coordinator.gestureEnded(action: .cancel)
            check(coordinator.status == .idle && backend.finishCount == 0, "swipe_exits_without_final")
            check(await wait { backend.cancelling }, "swipe_cancel_not_finish")
            backend.lateFinal(); check(composer.delivered.isEmpty, "swipe_late_final_ignored")
            backend.release(); await coordinator.waitForCancelledResources()
            check(composer.delivered == [.cancel] && feedback?.message == "再下滑清空"
                && feedback?.statusChannelOwnsToast == false, "swipe_existing_action_light_hint")
            await coordinator.applicationWillTerminate()
        }
        // Preserve the original valid-Undo assertion. Also exercise a newer
        // activation: installing its parent token intentionally revokes the old
        // Undo, which must never operate on the next editor session.
        for queueNext in [false, true] {
            let composer = DraftComposer(), backend = Backend(), next = Backend()
            backend.holdCancel = false; next.holdCancel = false
            var builds = 0
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: composer)
            coordinator.setSpeechBackendFactoryForTesting { _ in builds += 1; return builds == 1 ? backend : next }
            check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "draft_begin")
            check(await wait { coordinator.status == .listening }, "draft_ready")
            backend.partial()
            check(await wait { composer.updating }, "draft_writer_owned")
            await coordinator.gestureEnded(action: .cancel)
            check(coordinator.status == .idle && composer.writes == 0, "draft_cancel_immediate")
            if queueNext {
                check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "draft_next_queued")
                check(!composer.newestIsValid, "draft_old_undo_revoked_by_new_activation")
            }
            var drained = false, drainEntered = false
            let draining = Task { @MainActor in
                drainEntered = true
                await coordinator.waitForCancelledResources(); drained = true
            }
            check(await wait { drainEntered }, "draft_drain_entered")
            check(!drained, "drain_waits_owned_writer")
            check(composer.beginCount == 1 && builds == 1, "draft_new_editor_capture_wait_owned_writer")
            composer.release(); await draining.value
            if queueNext {
                check(composer.writes == 0 && composer.cancellations == 0, "draft_stale_undo_cannot_touch_new_editor")
            } else {
                check(composer.writes == 0 && composer.cancellations == 1, "draft_revoked_undo_parent_valid")
                check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "draft_next_after_drain")
            }
            check(await wait { coordinator.status == .listening && builds == 2 }, "draft_new_owner_after_undo_drain")
            check(composer.newestIsValid && composer.beginCount == 2 && backend.cancelCount == 1
                  && next.cancelCount == 0, "draft_old_cleanup_preserves_new_token_and_backend")
            await coordinator.applicationWillTerminate()
            check(next.isQuiescent && next.cancelCount == 1, "draft_shutdown_true_drain")
        }
        // Shutdown/data deletion must wait for actual resource closure, and cannot admit another session meanwhile.
        do {
            let backend = Backend(), composer = Composer()
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: composer)
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            check(coordinator.gestureBegan(activation(), settings: settings, selection: selection), "shutdown_begin")
            check(await wait { coordinator.status == .listening }, "shutdown_ready")
            var drained = false
            let shutdown = Task { @MainActor in await coordinator.applicationWillTerminate(); drained = true }
            check(await wait { backend.cancelling }, "shutdown_cleanup_started")
            check(!drained && !coordinator.gestureBegan(activation(), settings: settings, selection: selection), "shutdown_waits_denies_begin")
            backend.lateFinal(); check(composer.delivered.isEmpty, "shutdown_late_final_ignored")
            backend.release(); await shutdown.value
            check(drained && backend.isQuiescent, "shutdown_drained_before_return")
        }
        let log = "event=immediate_cancel_checks,state=\(failures.isEmpty ? "passed" : "failed"),cases=\(cases),rapid_cycles=50,capture=0,cloud=0"
        let whitelist = "^event=immediate_cancel_checks,state=(passed|failed),cases=[0-9]+,rapid_cycles=50,capture=0,cloud=0$"
        check(log.range(of: whitelist, options: .regularExpression) != nil
            && "event=immediate_cancel_checks,state=unknown,cases=1,rapid_cycles=50,capture=0,cloud=0".range(of: whitelist, options: .regularExpression) == nil,
              "log_whitelist")
        print(log)
        return failures
    }
}
