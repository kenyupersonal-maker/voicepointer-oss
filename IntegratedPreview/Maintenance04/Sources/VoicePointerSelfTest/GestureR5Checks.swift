import CoreGraphics
import Foundation
import VoicePointerCore

/// REVISION-5 concurrency-boundary acceptance checks.
///
/// Every mechanism exercised here is the production one: the shared
/// `GestureAdmissionAuthority` heartbeat/generation authority, the
/// `GestureSessionToken` lease, the independent
/// `GestureHeartbeatExpiryWatchdog` owned by `GestureMainQueueAdapter`,
/// `VoiceOperationSafety.invalidate(olderThanGeneration:)` and the type-safe
/// `executeOnMainActor` consumption entry. Only the boundaries are fakes (UI
/// executor, host operation, hook gate), and every fake is lock-protected
/// because the watchdog queue, a background producer and the MainActor all
/// touch them.
///
/// Messages reach the adapter through `GestureMainQueueAdapter.handle`, which
/// is exactly what the App wires as the monitor's `eventHandler`, so no AX,
/// keyboard injection, hardware, permission, install or other-application
/// operation is ever touched. Nothing here cancels a token by hand and calls
/// it a watchdog result: the cancellation is always observed through the real
/// hook chain.
///
/// The checks run on the MainActor, so no wait may block it — a blocked main
/// thread would also stall the very MainActor jobs some checks wait for. All
/// waits are `pollUntil` (suspends the actor) and every gate released in a
/// `defer`.
@MainActor
public enum GestureR5Checks {
    public static func run() async -> [String] {
        var failures: [String] = []
        await checkWatchdogCancelsHostTokenWithoutAnyAdvancement(&failures)
        checkSingleHeartbeatGapExpiresExactlyOnce(&failures)
        await checkDelayedOldHookCannotKillRecoveredToken(&failures)
        await checkMainActorFIFOHoldsItsSlotUntilTheCallbackFinished(&failures)
        await checkExecutionBoundaryRevalidatesAfterInvalidate(&failures)
        return failures
    }

    // MARK: - R5-1 independent watchdog cancels the host operation token

    /// A normal begin/end pair leaves the session lease empty while the host
    /// still holds an in-flight `OperationCancellationToken` (the async text
    /// transaction awaiting IME). When the admission heartbeat dies, the
    /// independent watchdog — with `expiryCheckInterval: 0.01`, its real timer,
    /// no further message and no UI executor advancement — must cancel that
    /// host token through the production hook chain
    /// (`consumeHeartbeatExpiry` → `handleHeartbeatExpiry` →
    /// `onSessionInvalidated` → `VoiceOperationSafety.invalidate(olderThanGeneration:)`),
    /// off the main thread, so the late Send commit finds a cancelled token.
    private static func checkWatchdogCancelsHostTokenWithoutAnyAdvancement(
        _ failures: inout [String]
    ) async {
        let admission = GestureAdmissionAuthority(heartbeatTolerance: 2)
        let safety = VoiceOperationSafety()
        let host = FakeOperationHost()
        let hooks = InvalidationHookRecorder()
        let ui = ManualUIExecutor()
        let adapter = GestureMainQueueAdapter(
            admission: admission,
            heartbeatTolerance: 2,
            maxInFlight: 1,
            expiryCheckInterval: 0.01,
            onSessionInvalidated: {
                hooks.record(onMainThread: Thread.isMainThread)
                // Identical to the App wiring in VoicePointerApplication.
                safety.invalidate(olderThanGeneration: admission.snapshot().generation)
            },
            uiExecutor: { block in ui.enqueue(block) },
            execute: { message in
                switch message.kind {
                case .begin: host.begin(message: message, safety: safety)
                case .end: host.completeTerminal()
                case .move, .cancel, .tapFailure: break
                }
            }
        )

        admission.recordHeartbeat()
        let generation = admission.snapshot().generation
        let gestureID: UInt64 = 801
        adapter.handle(makeMessage(
            generation: generation, gestureID: gestureID, sequence: 1,
            kind: .begin(fixtureActivation())
        ))
        ui.runOldest()
        adapter.handle(makeMessage(
            generation: generation, gestureID: gestureID, sequence: 2,
            kind: .end(CGPoint(x: 12, y: 13))
        ))
        ui.runOldest()

        expect(
            &failures,
            adapter.statisticsSnapshot.executed == 2,
            "R5-1/watchdog-token: the begin/end pair must both execute (executed=\(adapter.statisticsSnapshot.executed))"
        )
        expect(
            &failures,
            adapter.sessionToken.trackedGestureID == 0,
            "R5-1/watchdog-token: the normal terminal must clear the tracked gesture (tracked=\(adapter.sessionToken.trackedGestureID))"
        )
        expect(
            &failures,
            host.terminalCount == 1,
            "R5-1/watchdog-token: the host must have seen exactly one terminal (got \(host.terminalCount))"
        )
        let heldToken = host.heldToken
        expect(
            &failures,
            heldToken != nil,
            "R5-1/watchdog-token: the host must still hold its operation token after the terminal"
        )
        expect(
            &failures,
            heldToken?.isCancelled == false,
            "R5-1/watchdog-token: a normally finished gesture must leave the host token alive"
        )
        let executorRunsBeforeExpiry = ui.runCount

        // The heartbeat dies. Nothing else happens: no further message is
        // produced, the UI executor is never advanced again, and no token is
        // cancelled by hand — only the watchdog's own timer can react.
        admission.update { $0.lastHeartbeatSeconds = monotonicTimestampSeconds() - 5 }
        let cancelled = await pollUntil(timeout: 3) { heldToken?.isCancelled == true }
        expect(
            &failures,
            cancelled,
            "R5-1/watchdog-token: the 0.01s independent watchdog must cancel the host token with no further message and no UI executor advancement"
        )
        expect(
            &failures,
            hooks.callCount == 1,
            "R5-1/watchdog-token: one dead heartbeat must fire the invalidation hook exactly once (got \(hooks.callCount))"
        )
        expect(
            &failures,
            hooks.mainThreadCallCount == 0,
            "R5-1/watchdog-token: the invalidation hook must not run on the main thread (got \(hooks.mainThreadCallCount) main-thread calls)"
        )
        expect(
            &failures,
            ui.runCount == executorRunsBeforeExpiry && ui.pendingCount == 0,
            "R5-1/watchdog-token: the release must not need the UI executor (runs=\(ui.runCount), before=\(executorRunsBeforeExpiry), pending=\(ui.pendingCount))"
        )
        expect(
            &failures,
            adapter.statisticsSnapshot.posted == 2,
            "R5-1/watchdog-token: no message beyond the original pair may be posted (posted=\(adapter.statisticsSnapshot.posted))"
        )
        expect(
            &failures,
            adapter.statisticsSnapshot.releasedExpiredGestures == 0,
            "R5-1/watchdog-token: the hook must fire even though the terminal already cleared the lease (released=\(adapter.statisticsSnapshot.releasedExpiredGestures))"
        )
        host.completePendingSend()
        expect(
            &failures,
            host.sendCount == 0,
            "R5-1/watchdog-token: the cancelled token must block the late Send commit (sends=\(host.sendCount))"
        )
    }

    // MARK: - R5-2 one heartbeat gap expires exactly once

    /// Three watchdog checks over a single heartbeat gap may advance the
    /// generation only once and fire the session hook only once; the
    /// gap-aware `recordHeartbeat` recovery must not advance it a second time
    /// for the same gap. A genuinely new stale period afterwards is a new
    /// expiry, which proves the latch is per-gap and not permanent.
    private static func checkSingleHeartbeatGapExpiresExactlyOnce(_ failures: inout [String]) {
        let admission = GestureAdmissionAuthority(heartbeatTolerance: 0.2)
        let hooks = InvalidationHookRecorder()
        // A 60s interval keeps the real timer inert for the whole check: every
        // expiry observation below is driven through the watchdog's own
        // `performCheck` (via the adapter's testing seam), never faked.
        let adapter = GestureMainQueueAdapter(
            admission: admission,
            heartbeatTolerance: 0.2,
            maxInFlight: 1,
            expiryCheckInterval: 60,
            onSessionInvalidated: { hooks.record(onMainThread: Thread.isMainThread) },
            execute: { _ in }
        )

        admission.recordHeartbeat()
        admission.update { $0.lastHeartbeatSeconds = monotonicTimestampSeconds() - 1 }
        let before = admission.snapshot().generation
        for _ in 0..<3 { adapter.performExpiryCheckForTesting() }
        let afterChecks = admission.snapshot().generation
        expect(
            &failures,
            afterChecks == before + 1,
            "R5-2/exactly-once: three checks over one gap must advance the generation exactly once (before=\(before), after=\(afterChecks))"
        )
        expect(
            &failures,
            hooks.callCount == 1,
            "R5-2/exactly-once: one gap must fire the session hook exactly once (got \(hooks.callCount))"
        )

        admission.recordHeartbeat()
        let generationAfterRecovery = admission.snapshot().generation
        expect(
            &failures,
            generationAfterRecovery == afterChecks,
            "R5-2/exactly-once: recovering the same latched gap must not advance the generation again (got \(generationAfterRecovery), expected \(afterChecks))"
        )
        expect(
            &failures,
            hooks.callCount == 1,
            "R5-2/exactly-once: the gap-aware recovery must not re-fire the session hook (got \(hooks.callCount))"
        )

        admission.update { $0.lastHeartbeatSeconds = monotonicTimestampSeconds() - 1 }
        adapter.performExpiryCheckForTesting()
        expect(
            &failures,
            admission.snapshot().generation == afterChecks + 1,
            "R5-2/exactly-once: a second, genuinely new gap must expire again (got \(admission.snapshot().generation), expected \(afterChecks + 1))"
        )
        expect(
            &failures,
            hooks.callCount == 2,
            "R5-2/exactly-once: the new gap must fire the session hook once more (got \(hooks.callCount))"
        )
    }

    // MARK: - R5-3 a delayed old hook cannot kill the recovered operation

    /// The old invalidation hook is parked on a background gate after the
    /// expiry generation already advanced. While it is parked the heartbeat
    /// recovers and a new gesture installs a new token through the real
    /// adapter path. Releasing the old hook then runs the production
    /// `VoiceOperationSafety.invalidate(olderThanGeneration:)` with the
    /// generation read at the moment of the call — exactly the App's hook
    /// shape, never a value captured before the delay: the newer operation
    /// must survive it, and the predicate must still cancel a genuinely older
    /// one (positive control), so the survival is not a no-op invalidate.
    private static func checkDelayedOldHookCannotKillRecoveredToken(_ failures: inout [String]) async {
        let admission = GestureAdmissionAuthority(heartbeatTolerance: 0.2)
        let safety = VoiceOperationSafety()
        let host = FakeOperationHost()
        let gate = HookGate()
        let ui = ManualUIExecutor()
        let adapter = GestureMainQueueAdapter(
            admission: admission,
            heartbeatTolerance: 0.2,
            maxInFlight: 1,
            expiryCheckInterval: 60,
            onSessionInvalidated: {
                // Strictly the App's hook shape: the generation is read at the
                // moment `invalidate` is called, i.e. AFTER the delay, never
                // from a value captured before it.
                gate.pause(entryGeneration: admission.snapshot().generation, onMainThread: Thread.isMainThread)
                defer { gate.markFinished() }
                let generationAtCall = admission.snapshot().generation
                gate.recordInvalidated(generation: generationAtCall)
                safety.invalidate(olderThanGeneration: generationAtCall)
            },
            uiExecutor: { block in ui.enqueue(block) },
            execute: { message in
                switch message.kind {
                case .begin: host.begin(message: message, safety: safety)
                case .end: host.completeTerminal()
                case .move, .cancel, .tapFailure: break
                }
            }
        )

        admission.recordHeartbeat()
        let oldGeneration = admission.snapshot().generation
        let oldGestureID: UInt64 = 900
        adapter.handle(makeMessage(
            generation: oldGeneration, gestureID: oldGestureID, sequence: 1,
            kind: .begin(fixtureActivation())
        ))
        ui.runOldest()
        adapter.handle(makeMessage(
            generation: oldGeneration, gestureID: oldGestureID, sequence: 2,
            kind: .end(CGPoint(x: 20, y: 21))
        ))
        ui.runOldest()
        let oldToken = host.heldToken
        expect(
            &failures,
            oldToken != nil,
            "R5-3/delayed-hook: the old gesture must have installed a host token"
        )

        admission.update { $0.lastHeartbeatSeconds = monotonicTimestampSeconds() - 1 }
        // The watchdog check runs on a background thread so its hook parks
        // there, exactly like a delayed expiry callback in production.
        let checker = Thread(block: { adapter.performExpiryCheckForTesting() })
        checker.start()
        // The parked hook is always released, on every exit path.
        defer { gate.release() }
        guard await pollUntil(timeout: 3, { gate.hasEntered }) else {
            failures.append("R5-3/delayed-hook: the background expiry hook never reached the gate")
            return
        }
        let expiryGeneration = admission.snapshot().generation
        expect(
            &failures,
            expiryGeneration == oldGeneration + 1,
            "R5-3/delayed-hook: the expiry must already have advanced the generation while the hook is parked (old=\(oldGeneration), now=\(expiryGeneration))"
        )
        expect(
            &failures,
            gate.entryGeneration == expiryGeneration,
            "R5-3/delayed-hook: the hook must have been parked by the expiry that advanced the generation (entry=\(gate.entryGeneration), expected=\(expiryGeneration))"
        )
        expect(
            &failures,
            gate.invalidatedGeneration == nil,
            "R5-3/delayed-hook: the parked hook must not have reached its invalidate call yet"
        )
        expect(
            &failures,
            gate.mainThreadCallCount == 0,
            "R5-3/delayed-hook: the expiry hook must run off the main thread"
        )
        expect(
            &failures,
            oldToken?.isCancelled == false,
            "R5-3/delayed-hook: the parked hook must not have invalidated anything yet"
        )

        // Recovery while the old hook is still parked, then a real new gesture
        // under the recovered generation installs a new token.
        admission.recordHeartbeat()
        expect(
            &failures,
            admission.snapshot().generation == expiryGeneration,
            "R5-3/delayed-hook: recovery from the latched gap must not advance the generation again (got \(admission.snapshot().generation))"
        )
        let newGeneration = admission.snapshot().generation
        let newGestureID: UInt64 = 901
        adapter.handle(makeMessage(
            generation: newGeneration, gestureID: newGestureID, sequence: 3,
            kind: .begin(fixtureActivation())
        ))
        ui.runOldest()
        let newToken = host.heldToken
        expect(
            &failures,
            newToken != nil && newToken !== oldToken,
            "R5-3/delayed-hook: the recovered gesture must have installed a new host token"
        )
        expect(
            &failures,
            adapter.sessionToken.trackedGestureID == newGestureID,
            "R5-3/delayed-hook: the recovered gesture must be tracked (tracked=\(adapter.sessionToken.trackedGestureID))"
        )

        gate.release()
        guard await pollUntil(timeout: 3, { gate.hasFinished }) else {
            failures.append("R5-3/delayed-hook: the released hook never finished")
            return
        }
        expect(&failures, !gate.didTimeOut, "R5-3/delayed-hook: the hook gate must not time out")
        expect(
            &failures,
            gate.callCount == 1,
            "R5-3/delayed-hook: one gap must fire the hook exactly once (got \(gate.callCount))"
        )
        expect(
            &failures,
            gate.invalidatedGeneration == newGeneration,
            "R5-3/delayed-hook: the released hook must invalidate with the generation current at call time (used=\(gate.invalidatedGeneration.map(String.init) ?? "nil"), new=\(newGeneration))"
        )
        expect(
            &failures,
            newToken?.isCancelled == false,
            "R5-3/delayed-hook: the delayed old hook must not kill the token installed after recovery"
        )
        var committed = false
        _ = newToken?.commitIfValid { committed = true }
        expect(
            &failures,
            committed,
            "R5-3/delayed-hook: the recovered operation must still be able to commit its side effect"
        )
        expect(
            &failures,
            adapter.sessionToken.trackedGestureID == newGestureID,
            "R5-3/delayed-hook: the delayed old hook must not disturb the new session lease"
        )
        expect(
            &failures,
            oldToken?.isCancelled == true,
            "R5-3/delayed-hook: the superseded old token must end up cancelled"
        )

        // Positive control, run last because install() supersedes the current
        // token: the predicate must still cancel a genuinely older operation,
        // so the survival above is not the result of a no-op invalidate.
        let staleToken = OperationCancellationToken()
        safety.install(staleToken, generation: oldGeneration, gestureID: 902)
        safety.invalidate(olderThanGeneration: expiryGeneration)
        expect(
            &failures,
            staleToken.isCancelled,
            "R5-3/delayed-hook: invalidate(olderThanGeneration:) must still cancel a genuinely older operation"
        )
    }

    // MARK: - R5-4 MainActor FIFO and the in-flight slot boundary

    /// Through the real type-safe `executeOnMainActor` entry with
    /// `maxInFlight == 1`, three messages produced from a detached task must
    /// reach the callback in FIFO order, each callback must run on the real
    /// MainActor (`MainActor.assertIsolated`), the single in-flight slot must
    /// still be held for the whole callback body, and it may return to zero
    /// only after the last callback actually finished.
    private static func checkMainActorFIFOHoldsItsSlotUntilTheCallbackFinished(
        _ failures: inout [String]
    ) async {
        let admission = GestureAdmissionAuthority(heartbeatTolerance: 5)
        admission.recordHeartbeat()
        let box = AdapterBox()
        let recorder = ExecutionRecorder()
        let adapter = GestureMainQueueAdapter(
            admission: admission,
            heartbeatTolerance: 5,
            maxInFlight: 1,
            expiryCheckInterval: nil,
            executeOnMainActor: { message in
                MainActor.assertIsolated()
                let inFlightAtEntry = box.inFlight
                let onMainThread = Thread.isMainThread
                let inFlightAtExit = box.inFlight
                recorder.recordCallback(
                    sequence: message.sequence,
                    inFlightAtEntry: inFlightAtEntry,
                    inFlightAtExit: inFlightAtExit,
                    onMainThread: onMainThread
                )
            }
        )
        box.attach(adapter)
        expect(
            &failures,
            adapter.maximumInFlight == 1,
            "R5-4/main-actor-fifo: the type-safe entry must run with one in-flight slot (got \(adapter.maximumInFlight))"
        )

        let generation = admission.snapshot().generation
        let gestureID: UInt64 = 810
        let producer = Task.detached { () -> (afterSecondPost: Int, afterThirdPost: Int) in
            adapter.handle(makeMessage(
                generation: generation, gestureID: gestureID, sequence: 1,
                kind: .begin(fixtureActivation())
            ))
            adapter.handle(makeMessage(
                generation: generation, gestureID: gestureID, sequence: 2,
                kind: .move(CGPoint(x: 31, y: 32))
            ))
            // The second handle can only return once the first callback has
            // fully finished and released the single slot.
            let afterSecondPost = recorder.callbackCount
            adapter.handle(makeMessage(
                generation: generation, gestureID: gestureID, sequence: 3,
                kind: .end(CGPoint(x: 33, y: 34))
            ))
            return (afterSecondPost, recorder.callbackCount)
        }
        let observed = await producer.value
        guard await pollUntil(timeout: 3, { adapter.statisticsSnapshot.executed == 3 }) else {
            failures.append(
                "R5-4/main-actor-fifo: the three messages never all executed (executed=\(adapter.statisticsSnapshot.executed))"
            )
            return
        }
        expect(
            &failures,
            recorder.observedSequences == [1, 2, 3],
            "R5-4/main-actor-fifo: MainActor delivery must be FIFO; got \(recorder.observedSequences)"
        )
        expect(
            &failures,
            recorder.mainThreadCount == 3,
            "R5-4/main-actor-fifo: every callback must run on the real main thread (got \(recorder.mainThreadCount)/3)"
        )
        expect(
            &failures,
            recorder.entryInFlight == [1, 1, 1],
            "R5-4/main-actor-fifo: the slot must be held while each callback runs; got \(recorder.entryInFlight)"
        )
        expect(
            &failures,
            recorder.exitInFlight == [1, 1, 1],
            "R5-4/main-actor-fifo: the slot must still be held when the callback body ends, so only the adapter's defer can release it; got \(recorder.exitInFlight)"
        )
        expect(
            &failures,
            observed.afterSecondPost >= 1 && observed.afterThirdPost >= 2,
            "R5-4/main-actor-fifo: the producer may only post the next message after the previous callback actually finished (afterSecond=\(observed.afterSecondPost), afterThird=\(observed.afterThirdPost))"
        )
        expect(
            &failures,
            adapter.statisticsSnapshot.inFlight == 0,
            "R5-4/main-actor-fifo: the slot must return to zero once the last callback finished (inFlight=\(adapter.statisticsSnapshot.inFlight))"
        )
        expect(
            &failures,
            adapter.statisticsSnapshot.skippedAtExecution == 0
                && adapter.statisticsSnapshot.droppedStaleHeartbeat == 0
                && adapter.statisticsSnapshot.droppedStaleGeneration == 0,
            "R5-4/main-actor-fifo: a healthy session must not skip or drop anything (skipped=\(adapter.statisticsSnapshot.skippedAtExecution))"
        )
        expect(
            &failures,
            adapter.sessionToken.trackedGestureID == 0,
            "R5-4/main-actor-fifo: the terminal must clear the tracked gesture"
        )
    }

    // MARK: - R5-5 the execution boundary re-validates

    /// One message is posted from the MainActor itself while the single slot
    /// is free, so `handle` cannot block and the posted MainActor job cannot
    /// have run yet. Invalidating the session before the actor is yielded must
    /// be caught by the execution-boundary re-validation: the callback never
    /// runs, the message is counted as skipped (not as a pre-post drop), and
    /// the slot returns to zero.
    private static func checkExecutionBoundaryRevalidatesAfterInvalidate(
        _ failures: inout [String]
    ) async {
        let admission = GestureAdmissionAuthority(heartbeatTolerance: 5)
        admission.recordHeartbeat()
        let callbacks = LockedCounter()
        let adapter = GestureMainQueueAdapter(
            admission: admission,
            heartbeatTolerance: 5,
            maxInFlight: 1,
            expiryCheckInterval: nil,
            executeOnMainActor: { _ in
                MainActor.assertIsolated()
                callbacks.increment()
            }
        )
        let generation = admission.snapshot().generation
        adapter.handle(makeMessage(
            generation: generation, gestureID: 820, sequence: 1,
            kind: .begin(fixtureActivation())
        ))
        // All three observations are taken while this check still owns the
        // MainActor synchronously, so the posted job cannot have run yet.
        let postedBeforeYield = adapter.statisticsSnapshot.posted
        let inFlightBeforeYield = adapter.statisticsSnapshot.inFlight
        let callbacksBeforeYield = callbacks.snapshot
        expect(
            &failures,
            postedBeforeYield == 1,
            "R5-5/revalidation: the single message must really have been posted (posted=\(postedBeforeYield))"
        )
        expect(
            &failures,
            inFlightBeforeYield == 1,
            "R5-5/revalidation: the free slot must be held by the posted-but-not-yet-run message (inFlight=\(inFlightBeforeYield))"
        )
        expect(
            &failures,
            callbacksBeforeYield == 0,
            "R5-5/revalidation: the callback must not run before the actor is yielded (got \(callbacksBeforeYield))"
        )

        // Still on the MainActor, before yielding: kill the session.
        adapter.sessionToken.invalidate()

        guard await pollUntil(timeout: 3, { adapter.statisticsSnapshot.skippedAtExecution == 1 }) else {
            failures.append(
                "R5-5/revalidation: the posted message was never re-validated at the execution boundary (skipped=\(adapter.statisticsSnapshot.skippedAtExecution))"
            )
            return
        }
        expect(
            &failures,
            callbacks.snapshot == 0,
            "R5-5/revalidation: a session invalidated before the yield must leave the callback unexecuted (got \(callbacks.snapshot))"
        )
        expect(
            &failures,
            adapter.statisticsSnapshot.executed == 0,
            "R5-5/revalidation: nothing may be counted as executed (executed=\(adapter.statisticsSnapshot.executed))"
        )
        expect(
            &failures,
            adapter.statisticsSnapshot.inFlight == 0,
            "R5-5/revalidation: the skipped message must release its slot (inFlight=\(adapter.statisticsSnapshot.inFlight))"
        )
        expect(
            &failures,
            adapter.statisticsSnapshot.droppedInvalidSession == 0,
            "R5-5/revalidation: the message must be rejected by the execution boundary, not by the pre-post filter (droppedInvalidSession=\(adapter.statisticsSnapshot.droppedInvalidSession))"
        )
        expect(
            &failures,
            adapter.sessionToken.trackedGestureID == 0,
            "R5-5/revalidation: the skipped begin must not leave a tracked gesture"
        )
    }
}

// MARK: - Helpers

private func expect(_ failures: inout [String], _ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

/// Waits for a condition without ever blocking the MainActor: the checks run
/// there, and a blocked main thread would also stall the MainActor jobs the
/// check is waiting for.
private func pollUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

/// Payload rule used by production: a fresh monotonic timestamp and the
/// current admission generation, sampled when the message is created.
private func makeMessage(
    generation: UInt64,
    gestureID: UInt64,
    sequence: UInt64,
    kind: GestureEventMessage.Kind,
    timestampSeconds: Double = monotonicTimestampSeconds()
) -> GestureEventMessage {
    GestureEventMessage(
        generation: generation,
        gestureID: gestureID,
        sequence: sequence,
        timestampSeconds: timestampSeconds,
        kind: kind
    )
}

private func fixtureActivation() -> GestureActivation {
    GestureActivation(
        location: CGPoint(x: 30, y: 40),
        button: .left,
        match: GestureMatch(
            deviceToken: 3,
            deviceKind: .magicMouse,
            touchCount: 2,
            newestTouchAgeSeconds: 0.02,
            maximumMovement: 0.001
        )
    )
}

// MARK: - Fakes (all lock-protected: watchdog queue / producer / MainActor)

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var snapshot: Int { lock.withLock { value } }
}

/// The MainActor callback must read the adapter's live in-flight count, but
/// the adapter does not exist yet while its own callback is written. The box
/// closes that cycle and is attached before the first message is produced.
private final class AdapterBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var adapter: GestureMainQueueAdapter?
    func attach(_ adapter: GestureMainQueueAdapter) { lock.withLock { self.adapter = adapter } }
    var inFlight: Int { lock.withLock { adapter?.statisticsSnapshot.inFlight ?? -1 } }
}

/// Deterministic stand-in for the UI executor: posted blocks queue up and the
/// test advances them one by one, so "the UI executor was never advanced" is a
/// fact about the code path instead of a timing assumption.
private final class ManualUIExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [@Sendable () -> Void] = []
    private var runs = 0

    func enqueue(_ block: @escaping @Sendable () -> Void) {
        lock.withLock { blocks.append(block) }
    }

    func runOldest() {
        lock.lock()
        guard !blocks.isEmpty else { lock.unlock(); return }
        let block = blocks.removeFirst()
        runs += 1
        lock.unlock()
        block()
    }

    var pendingCount: Int { lock.withLock { blocks.count } }
    var runCount: Int { lock.withLock { runs } }
}

/// Host-side stand-in for the App: one `OperationCancellationToken` per
/// gesture installed into the shared `VoiceOperationSafety` under the
/// message's own generation, and the Send committed only through
/// `commitIfValid` — the production linearization point.
private final class FakeOperationHost: @unchecked Sendable {
    private let lock = NSLock()
    private let sends = LockedCounter()
    private var pendingToken: OperationCancellationToken?
    private var terminals = 0

    func begin(message: GestureEventMessage, safety: VoiceOperationSafety) {
        let token = OperationCancellationToken()
        safety.install(token, generation: message.generation, gestureID: message.gestureID)
        lock.withLock { pendingToken = token }
    }

    /// The terminal ends the gesture but not the operation: the text
    /// transaction stays in flight (awaiting IME) holding its token.
    func completeTerminal() { lock.withLock { terminals += 1 } }

    /// The late commit a real transaction performs once IME settles.
    func completePendingSend() {
        lock.lock()
        let token = pendingToken
        lock.unlock()
        guard let token else { return }
        _ = token.commitIfValid { sends.increment() }
    }

    var heldToken: OperationCancellationToken? { lock.withLock { pendingToken } }
    var sendCount: Int { sends.snapshot }
    var terminalCount: Int { lock.withLock { terminals } }
}

private final class InvalidationHookRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var mainThreadCalls = 0

    func record(onMainThread: Bool) {
        lock.withLock {
            calls += 1
            if onMainThread { mainThreadCalls += 1 }
        }
    }

    var callCount: Int { lock.withLock { calls } }
    var mainThreadCallCount: Int { lock.withLock { mainThreadCalls } }
}

/// Parks the first invalidation hook on a background thread so the test can
/// interleave a recovery and a new operation while the old hook is still in
/// flight. The wait is bounded and the release always happens, so a production
/// regression fails the check instead of hanging the suite.
private final class HookGate: @unchecked Sendable {
    private let lock = NSLock()
    private let allow = DispatchSemaphore(value: 0)
    private var pauseArmed = true
    private var released = false
    private var entered = false
    private var finished = false
    private var timedOut = false
    private var calls = 0
    private var mainThreadCalls = 0
    private var generationAtEntry: UInt64 = 0
    private var usedGeneration: UInt64?

    func pause(entryGeneration generation: UInt64, onMainThread: Bool) {
        lock.lock()
        calls += 1
        if onMainThread { mainThreadCalls += 1 }
        generationAtEntry = generation
        entered = true
        let shouldPause = pauseArmed
        pauseArmed = false
        lock.unlock()
        guard shouldPause else { return }
        if allow.wait(timeout: .now() + 5) == .timedOut {
            lock.withLock { timedOut = true }
        }
    }

    func recordInvalidated(generation: UInt64) { lock.withLock { usedGeneration = generation } }
    func markFinished() { lock.withLock { finished = true } }

    /// Idempotent, so the `defer` safety net can never double-signal.
    func release() {
        lock.lock()
        let shouldSignal = !released
        released = true
        lock.unlock()
        if shouldSignal { allow.signal() }
    }

    var hasEntered: Bool { lock.withLock { entered } }
    var hasFinished: Bool { lock.withLock { finished } }
    var didTimeOut: Bool { lock.withLock { timedOut } }
    var callCount: Int { lock.withLock { calls } }
    var mainThreadCallCount: Int { lock.withLock { mainThreadCalls } }
    var entryGeneration: UInt64 { lock.withLock { generationAtEntry } }
    var invalidatedGeneration: UInt64? { lock.withLock { usedGeneration } }
}

/// What the MainActor callbacks actually observed: delivery order, whether the
/// in-flight slot was held for the whole callback body, and whether the
/// callback really ran on the main thread.
private final class ExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sequences: [UInt64] = []
    private var inFlightAtEntry: [Int] = []
    private var inFlightAtExit: [Int] = []
    private var mainThreadHits = 0

    func recordCallback(sequence: UInt64, inFlightAtEntry entry: Int, inFlightAtExit exit: Int, onMainThread: Bool) {
        lock.withLock {
            sequences.append(sequence)
            inFlightAtEntry.append(entry)
            inFlightAtExit.append(exit)
            if onMainThread { mainThreadHits += 1 }
        }
    }

    var observedSequences: [UInt64] { lock.withLock { sequences } }
    var entryInFlight: [Int] { lock.withLock { inFlightAtEntry } }
    var exitInFlight: [Int] { lock.withLock { inFlightAtExit } }
    var mainThreadCount: Int { lock.withLock { mainThreadHits } }
    var callbackCount: Int { lock.withLock { sequences.count } }
}
