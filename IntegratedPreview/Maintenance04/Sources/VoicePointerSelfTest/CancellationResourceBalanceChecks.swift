import Foundation
import CoreGraphics
@_spi(Testing) import VoicePointerCore

/// Actual coordinator → Doubao backend → ownership manager, with a synthetic
/// posting boundary only. No private provider files, AX, keyboard or capture.
@MainActor enum CancellationResourceBalanceChecks {
    private final class Posts: KeyboardEventPosting, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(Bool, UInt64)] = []
        private let releaseIndex: Int
        let releaseEntered = DispatchSemaphore(value: 0)
        let allowRelease = DispatchSemaphore(value: 0)
        init(releaseIndex: Int) { self.releaseIndex = releaseIndex }
        var snapshot: [(Bool, UInt64)] { lock.withLock { events } }
        func waitForRelease() -> Bool { releaseEntered.wait(timeout: .now() + 2) == .success }
        func post(modifier: VoiceModifier, isDown: Bool, marker: UInt64) -> KeyboardEventPostResult {
            let count = lock.withLock { events.append((isDown, marker)); return events.count }
            if count == releaseIndex { releaseEntered.signal(); allowRelease.wait() }
            return .submitted
        }
    }
    private final class Composer: ComposerActionExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [OperationCancellationToken] = []
        private var sessions: [ComposerActionSession] = []
        private var actions = 0
        var beginCount: Int { lock.withLock { sessions.count } }
        var actionCount: Int { lock.withLock { actions } }
        var newestIsValid: Bool { lock.withLock { tokens.last?.isCancelled == false } }
        func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
            lock.withLock {
                let session = ComposerActionSession(testIdentifier: UInt64(sessions.count + 1), cancellationToken: cancellationToken)
                sessions.append(session); tokens.append(cancellationToken)
                return .ready(session)
            }
        }
        func perform(_ action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
            lock.withLock { actions += 1 }; return .kept
        }
        func cancel(session: ComposerActionSession?) {
            let token = lock.withLock { sessions.firstIndex { $0 == session }.map { tokens[$0] } }
            token?.cancel()
        }
    }
    private final class Focus: FocusProviding, @unchecked Sendable {
        func snapshot(at: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? {
            .init(contextIdentifier: "synthetic_t14", bundleIdentifier: nil, candidates: [
                .init(identifier: "synthetic_t14", role: "AXTextArea", frame: .init(x: 0, y: 0, width: 100, height: 40))
            ])
        }
        func setFocused(candidateIdentifier: String) -> Bool { true }
        func isFocused(candidateIdentifier: String) -> Bool { true }
        func synthesizeClick(candidateIdentifier: String) -> Bool { true }
    }
    private static func wait(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }
    static func run() async -> [String] {
        var failures: [String] = [], cases = 0
        func check(_ value: Bool, _ label: String) {
            cases += 1
            if !value { failures.append("event=cancel_balance,state=failed,case=" + label) }
        }
        let activation = GestureActivation(location: .init(x: 20, y: 20), button: .left,
            match: .init(deviceToken: 1, deviceKind: .magicMouse, touchCount: 2, newestTouchAgeSeconds: 0.01, maximumMovement: 0.001))
        for mode in [VoiceActivationMode.hold, .toggle] {
            let posts = Posts(releaseIndex: mode == .hold ? 2 : 3), composer = Composer()
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()),
                keyboardOwnership: .init(backend: posts), composerActionExecutor: composer)
            var settings = VoicePointerSettings(focusMode: .smart)
            settings.voiceShortcut.mode = mode == .hold ? .hold : .toggle
            check(coordinator.gestureBegan(activation, settings: settings), "begin")
            check(await wait { coordinator.status == .listening }, "listening")
            let oldSessionID = coordinator.currentSessionID
            await coordinator.cancel(); await coordinator.cancel()
            check(coordinator.status == .idle, "idle_before_resource_release")
            let entered = await Task.detached { posts.waitForRelease() }.value
            check(entered, "release_owned")
            check(coordinator.gestureBegan(activation, settings: settings), "next_queued")
            await coordinator.gestureEnded(action: .cancel, expectedSessionID: oldSessionID)
            check(coordinator.status != .idle && composer.beginCount == 1, "old_release_cannot_cancel_or_start_next")
            let prefix = mode == .hold ? [true, false] : [true, false, true]
            check(posts.snapshot.map(\.0) == prefix, "no_new_acquire_before_old_release")
            posts.allowRelease.signal()
            await coordinator.waitForCancelledResources()
            check(await wait { coordinator.status == .listening && composer.beginCount == 2 }, "next_after_true_drain")
            check(composer.newestIsValid && composer.actionCount == 0, "old_cleanup_cannot_cancel_or_undo_new_editor")
            await coordinator.cancel(); await coordinator.cancel()
            await coordinator.waitForCancelledResources()
            let events = posts.snapshot
            let expected = mode == .hold ? [true, false, true, false] : [true, false, true, false, true, false, true, false]
            check(events.map(\.0) == expected, "exact_balanced_hold_or_toggle_release")
            let half = expected.count / 2
            check(events.count == expected.count && Set(events.prefix(half).map(\.1)).count == 1 &&
                  Set(events.suffix(half).map(\.1)).count == 1 && events.first?.1 != events.last?.1,
                  "unique_owner_release_order")
            let count = events.count
            await coordinator.applicationWillTerminate()
            check(posts.snapshot.count == count && !composer.newestIsValid, "termination_true_drain_no_duplicate_release")
        }
        print("event=cancel_balance_checks,state=\(failures.isEmpty ? "passed" : "failed"),cases=\(cases),modes=2,capture=0,cloud=0")
        return failures
    }
}
