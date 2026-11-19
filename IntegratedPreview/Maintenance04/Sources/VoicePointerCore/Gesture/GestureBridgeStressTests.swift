import CoreGraphics
import Foundation

// Pure-simulation stress tests for the ordered input bridge. No CGEventTap is
// ever created, the MultitouchSupport private framework is never loaded, no
// audio is captured and no permission is requested: gestures are driven
// through `OrderedMouseGestureMonitor.processEventForTesting` with injected
// touch-state closures, and the EventTapWorker lifecycle is exercised with a
// fake installer that installs only a plain CFRunLoopSource.

@_spi(Testing)
public func runGestureBridgeStressTests() -> [String] {
    var failures: [String] = []
    testMailboxOrderingAndBounds(&failures)
    testMailboxMoveFloodBounded(&failures)
    testBridgeDrainsBeforeStopCompletion(&failures)
    testEventTapWorkerLifecycle(&failures)
    testStressGestureCycles(&failures)
    testSlowConsumerMoveFlood(&failures)
    testOverflowLatchesAdmission(&failures)
    testAdmissionExpiry(&failures)
    testLateUpAfterCancel(&failures)
    testOldGenerationDropped(&failures)
    testMonitorRepeatedStop(&failures)
    testRealDriverWiring(&failures)
    return failures
}

// MARK: - Revision 2 (REVISION-2.md) regression tests

@_spi(Testing)
public func runGestureRevision2Tests() -> [String] {
    var failures: [String] = []
    testWorkerReleasesAfterFailedBootstrap(&failures)
    testWorkerStopCompletionAfterCleanup(&failures)
    testMonitorConcurrentDoubleStart(&failures)
    testMonitorStopDuringStartBarrier(&failures)
    testMonitorStartStopStart(&failures)
    testMonitorRepeatedStopWhileStopping(&failures)
    testMonitorRetryAfterFailedStart(&failures)
    testBridgeStopDrainOrdering(&failures)
    testBridgeStopRaceNoStrandedMessages(&failures)
    testAdapterBoundedBacklogWithSlowUI(&failures)
    testAdapterInvalidationSkipsStaleMessages(&failures)
    return failures
}

@_spi(Testing)
public func runGestureRevision3Tests() -> [String] {
    var failures: [String] = []
    testAdapterMainThreadNeverWaitsForSlot(&failures)
    testAdapterExpiredHeartbeatDropsBackloggedEnd(&failures)
    testAdapterHeartbeatRecoveryCannotReviveStaleEnd(&failures)
    testAdapterEpochNotReclaimedWhileBackpressured(&failures)
    testWorkerBootstrapTimeoutKeepsOwnership(&failures)
    testMonitorBootstrapTimeoutKeepsOwnership(&failures)
    return failures
}

private func testAdapterMainThreadNeverWaitsForSlot(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority()
    let ui = ManualUIExecutor()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 60,
        maxInFlight: 1,
        expiryCheckInterval: nil,
        uiExecutor: { block in ui.enqueue(block) },
        execute: { _ in }
    )
    admission.recordHeartbeat()
    adapter.handle(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation)))
    let start = monotonicTimestampSeconds()
    adapter.handle(makeMessage(gestureID: 2, sequence: 2, kind: .begin(fixtureActivation)))
    let elapsed = monotonicTimestampSeconds() - start
    expect(&failures, elapsed < 0.1, "adapter must not wait for a UI slot on main thread")
    expect(&failures, adapter.statisticsSnapshot.droppedQueueTimeout == 1,
           "blocked UI slot must drop the second message without an unbounded wait")
    ui.runOldest()
}

// MARK: - Revision 4: unified identity, heartbeat gap, independent expiry

@_spi(Testing)
public func runGestureRevision4Tests() -> [String] {
    var failures: [String] = []
    testUnifiedInvalidationIdentity(&failures)
    testGapAwareHeartbeatReleasesTrackedGesture(&failures)
    testWatchdogReleasesWhenUIFrozen(&failures)
    testWatchdogDisabledByNilInterval(&failures)
    return failures
}

/// Real-main-queue delivery through the default UI executor; must be async
/// so the main thread can pump the queue while the producer posts.
@_spi(Testing)
public func runGestureMainQueueAdapterTest() async -> [String] {
    var failures: [String] = []
    let admission = GestureAdmissionAuthority()

    final class MainThreadRecorder: @unchecked Sendable {
        let lock = NSLock()
        private var messages: [GestureEventMessage] = []
        private var mainThreadCount = 0

        func append(_ message: GestureEventMessage) {
            lock.lock()
            messages.append(message)
            if Thread.isMainThread { mainThreadCount += 1 }
            lock.unlock()
        }

        var snapshot: [GestureEventMessage] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }

        var count: Int { lock.withLock { messages.count } }
        var onMainThread: Int { lock.withLock { mainThreadCount } }
    }

    let recorder = MainThreadRecorder()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 60,
        maxInFlight: 2,
        execute: { recorder.append($0) }
    )
    admission.recordHeartbeat()
    let producer = Thread(block: {
        adapter.handle(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation)))
        adapter.handle(makeMessage(gestureID: 1, sequence: 2, kind: .move(CGPoint(x: 5, y: 5))))
        adapter.handle(makeMessage(gestureID: 1, sequence: 3, kind: .end(CGPoint.zero)))
        adapter.handle(makeMessage(gestureID: 0, sequence: 4, kind: .tapFailure))
    })
    producer.start()

    let deadline = Date().addingTimeInterval(5)
    while recorder.count < 4 && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    expect(&failures, recorder.count == 4, "all four messages must execute on the real main queue")
    expect(&failures, recorder.onMainThread == recorder.count, "execution must happen on the main thread")
    let sequences = recorder.snapshot.map(\.sequence)
    expect(&failures, sequences == [1, 2, 3, 4], "main-queue delivery must preserve order; got \(sequences)")
    return failures
}

// MARK: - Revision 2 helpers

private final class SharedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}

private final class ErrorBox: @unchecked Sendable {
    var message: String?
}

private func makeFakeMonitor(
    recorder: DeliveryRecorder,
    heartbeatTolerance: TimeInterval,
    heartbeatWatchdogInterval: TimeInterval,
    mailboxCapacity: Int,
    admission: GestureAdmissionAuthority? = nil,
    installer: EventTapInstaller? = nil,
    bootstrapTimeout: TimeInterval = 10
) -> OrderedMouseGestureMonitor {
    OrderedMouseGestureMonitor(
        configuration: GestureConfiguration(),
        touchDevices: { [fixtureDevice] },
        consumeEligibleGesture: { _ in fixtureMatch },
        directionalDisplacement: { _ in .zero },
        admission: admission,
        eventHandler: { recorder.append($0) },
        heartbeatTolerance: heartbeatTolerance,
        heartbeatWatchdogInterval: heartbeatWatchdogInterval,
        mailboxCapacity: mailboxCapacity,
        tapInstaller: installer,
        bootstrapTimeout: bootstrapTimeout
    )
}

/// Compilable fake UI host: the example wiring for the UI side of
/// `GestureMainQueueAdapter`. `handle` runs on the injected serial UI
/// executor. A semaphore holds the first handler when requested; controlled
/// tasks stay owned until the test explicitly releases them.
/// A begin starts a background controlled task and returns immediately —
/// the executor never awaits whole transactions, so release/cancel keep
/// flowing while a task is in flight. The session reset hook clears held
/// state synchronously and bumps a session generation: messages whose
/// entry session no longer matches may not mutate held state when they
/// finish, mirroring how a real UI host gates a cancelled transaction's
/// late completion.
private final class FakeGestureUIHost: @unchecked Sendable {
    private let lock = NSLock()
    private var heldGestureID: UInt64 = 0
    private var completedSends = 0
    private var handledMessages: [(generation: UInt64, kind: String)] = []
    private var messagesWhileTaskInFlight = 0
    private var pendingTaskCount = 0
    private var sessionGeneration = 0
    private var entrySignalled = false
    let firstHandleEntered = DispatchSemaphore(value: 0)
    let releaseFirstHandle = DispatchSemaphore(value: 0)
    private let taskQueue = DispatchQueue(label: "r2-fake-ui-controlled-task")
    private let taskRelease = DispatchSemaphore(value: 0)
    private let taskDrain = DispatchGroup()
    private let blockFirstHandle: Bool

    init(blockFirstHandle: Bool = false) {
        self.blockFirstHandle = blockFirstHandle
    }

    var heldGesture: UInt64 { lock.withLock { heldGestureID } }
    var sendCount: Int { lock.withLock { completedSends } }
    var handled: [(generation: UInt64, kind: String)] { lock.withLock { handledMessages } }
    var messagesProcessedWhileTaskInFlight: Int { lock.withLock { messagesWhileTaskInFlight } }

    /// Runs on the (serial) UI executor.
    func handle(_ message: GestureEventMessage) {
        lock.lock()
        let entrySession = sessionGeneration
        let shouldSignalEntry = !entrySignalled
        entrySignalled = true
        lock.unlock()
        if shouldSignalEntry { firstHandleEntered.signal() }
        if shouldSignalEntry && blockFirstHandle { releaseFirstHandle.wait() }
        lock.lock()
        handledMessages.append((message.generation, Self.kindName(message.kind)))
        let sessionStillCurrent = sessionGeneration == entrySession
        let taskPending = pendingTaskCount > 0
        switch message.kind {
        case .begin:
            if sessionStillCurrent { heldGestureID = message.gestureID }
        case .move:
            break
        case .end:
            // A valid release commits the composition: the simulated Send.
            if sessionStillCurrent {
                completedSends += 1
                heldGestureID = 0
            }
        case .cancel, .tapFailure:
            if sessionStillCurrent { heldGestureID = 0 }
        }
        if taskPending { messagesWhileTaskInFlight += 1 }
        lock.unlock()

        if case .begin = message.kind {
            lock.lock()
            pendingTaskCount += 1
            lock.unlock()
            taskDrain.enter()
            taskQueue.async { [self] in
                taskRelease.wait()
                lock.lock()
                pendingTaskCount -= 1
                lock.unlock()
                taskDrain.leave()
            }
        }
    }

    func finishControlledTasks() -> Bool {
        let count = lock.withLock { pendingTaskCount }
        for _ in 0..<count { taskRelease.signal() }
        return taskDrain.wait(timeout: .now() + 5) == .success
    }

    /// GestureSessionToken reset hook: synchronous, thread-safe, never
    /// queued behind the busy UI executor.
    func resetSession() {
        lock.lock()
        sessionGeneration += 1
        heldGestureID = 0
        lock.unlock()
    }

    private static func kindName(_ kind: GestureEventMessage.Kind) -> String {
        switch kind {
        case .begin: return "begin"
        case .move: return "move"
        case .end: return "end"
        case .cancel: return "cancel"
        case .tapFailure: return "tapFailure"
        }
    }
}

// MARK: - Revision 2: EventTapWorker bootstrap failure

private final class WeakWorkerBox: @unchecked Sendable {
    weak var worker: EventTapWorker?
}

/// Runs one failed bootstrap inside its own function scope so the strong
/// worker reference is provably gone when the caller observes the weak box.
private func runFailedBootstrapScenario(box: WeakWorkerBox) -> (threw: Bool, stopCompleted: Bool) {
    let completion = DispatchSemaphore(value: 0)
    let worker = EventTapWorker(
        installer: { _, _, _ in nil },
        eventHandler: { _, _ in nil }
    )
    box.worker = worker
    var threw = false
    do { try worker.start() } catch { threw = true }
    worker.stop { completion.signal() }
    let stopCompleted = completion.wait(timeout: .now() + 5) == .success
    return (threw, stopCompleted)
}

/// The bootstrap-failure leak (REVISION-2 §1): a nil installer must not
/// leave the worker thread spinning in a permanent CFRunLoopRun. The thread
/// must exit (releasing its strong self reference) so the worker
/// deallocates, and a failed start must be retryable on the same object.
private func testWorkerReleasesAfterFailedBootstrap(_ failures: inout [String]) {
    do {
        let box = WeakWorkerBox()
        let result = runFailedBootstrapScenario(box: box)
        expect(&failures, result.threw, "R2/worker: failed bootstrap must throw")
        expect(
            &failures,
            result.stopCompleted,
            "R2/worker: stop after failed bootstrap must invoke completion"
        )
        // The strong reference ended with the scenario scope; the thread must
        // have exited so the weak reference nils out.
        expect(
            &failures,
            waitUntil(timeout: 2) { box.worker == nil },
            "R2/worker: worker must deallocate after a failed bootstrap (residual run loop thread detected)"
        )
    }

    do {
        // Retry on the same worker object after a failed bootstrap.
        let counter = SharedCounter()
        let order = OrderRecorder()
        let worker = EventTapWorker(
            installer: { runLoop, callback, userInfo in
                if counter.increment() == 1 { return nil }
                return makeFakeInstallation(order: order)(runLoop, callback, userInfo)
            },
            eventHandler: { _, _ in nil }
        )
        var firstThrew = false
        do { try worker.start() } catch { firstThrew = true }
        expect(&failures, firstThrew, "R2/worker: first start must fail")
        do {
            try worker.start()
        } catch {
            failures.append("R2/worker: retry after failed bootstrap must succeed (\(error))")
        }
        expect(&failures, worker.currentState == .running, "R2/worker: retried worker must be running")
        let stopped = DispatchSemaphore(value: 0)
        worker.stop { stopped.signal() }
        expect(&failures, stopped.wait(timeout: .now() + 5) == .success, "R2/worker: retried worker stop must complete")
        expect(&failures, counter.value == 2, "R2/worker: retry must install exactly twice (got \(counter.value))")
        expect(
            &failures,
            order.snapshot == ["enable", "disable", "teardown"],
            "R2/worker: retried install must enable/disable/teardown in order; got \(order.snapshot)"
        )
    }
}

/// A stop requested while the bootstrap is failing must fire its completion
/// only after the worker thread has finished its cleanup (state .stopped),
/// not before.
private func testWorkerStopCompletionAfterCleanup(_ failures: inout [String]) {
    final class StateBox: @unchecked Sendable {
        var state: EventTapWorker.LifecycleState?
    }
    let stateBox = StateBox()
    let slowFail = EventTapWorker(
        installer: { _, _, _ in
            Thread.sleep(forTimeInterval: 0.15)
            return nil
        },
        eventHandler: { _, _ in nil }
    )
    let started = DispatchSemaphore(value: 0)
    Thread(block: {
        do { try slowFail.start() } catch {}
        started.signal()
    }).start()
    Thread.sleep(forTimeInterval: 0.05)
    let stopped = DispatchSemaphore(value: 0)
    slowFail.stop { [stateBox] in
        stateBox.state = slowFail.currentState
        stopped.signal()
    }
    expect(
        &failures,
        stopped.wait(timeout: .now() + 5) == .success,
        "R2/worker: stop during a failing bootstrap must complete"
    )
    expect(
        &failures,
        started.wait(timeout: .now() + 5) == .success,
        "R2/worker: the failing start must still return"
    )
    expect(
        &failures,
        stateBox.state == .stopped,
        "R2/worker: stop completion must fire only after cleanup finished (saw \(String(describing: stateBox.state)))"
    )
    expect(
        &failures,
        slowFail.currentState == .stopped,
        "R2/worker: worker must end stopped after a failing bootstrap plus stop"
    )
}

// MARK: - Revision 2: monitor concurrent start/stop

/// Double start against a gated installer: the second start merges with the
/// first instead of installing a second tap (REVISION-2 §2).
private func testMonitorConcurrentDoubleStart(_ failures: inout [String]) {
    let order = OrderRecorder()
    let counter = SharedCounter()
    let entered = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    let installer: EventTapInstaller = { runLoop, callback, userInfo in
        counter.increment()
        entered.signal()
        gate.wait()
        return makeFakeInstallation(order: order)(runLoop, callback, userInfo)
    }
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 32,
        installer: installer
    )

    let started1 = DispatchSemaphore(value: 0)
    let started2 = DispatchSemaphore(value: 0)
    let box1 = ErrorBox()
    let box2 = ErrorBox()
    Thread(block: {
        do { try monitor.start() } catch { box1.message = "\(error)" }
        started1.signal()
    }).start()
    expect(
        &failures,
        entered.wait(timeout: .now() + 5) == .success,
        "R2/double-start: first installer attempt must begin"
    )
    Thread(block: {
        do { try monitor.start() } catch { box2.message = "\(error)" }
        started2.signal()
    }).start()
    expect(
        &failures,
        started2.wait(timeout: .now() + 0.2) == .timedOut,
        "R2/double-start: the second start must merge (wait) while the first bootstrap is gated"
    )
    expect(
        &failures,
        counter.value == 1,
        "R2/double-start: no second installation may begin while the first start is in flight"
    )
    gate.signal()
    expect(&failures, started1.wait(timeout: .now() + 10) == .success, "R2/double-start: first start must return")
    expect(&failures, started2.wait(timeout: .now() + 10) == .success, "R2/double-start: merged second start must return")
    expect(&failures, box1.message == nil, "R2/double-start: first start must succeed (\(box1.message ?? ""))")
    expect(&failures, box2.message == nil, "R2/double-start: merged start must not report failure (\(box2.message ?? ""))")
    expect(&failures, monitor.isRunningForTesting, "R2/double-start: monitor must be running")
    expect(&failures, counter.value == 1, "R2/double-start: concurrent starts must produce exactly one installation")
    expect(
        &failures,
        order.snapshot == ["enable"],
        "R2/double-start: only the winning start enables the tap; got \(order.snapshot)"
    )
    expect(&failures, drainMonitor(monitor, timeout: 10), "R2/double-start: monitor must stop cleanly")
    expect(
        &failures,
        order.snapshot == ["enable", "disable", "teardown"],
        "R2/double-start: the single installation must be cleaned up exactly once; got \(order.snapshot)"
    )
}

/// Stop requested while the monitor's bootstrap is gated: the tap is never
/// enabled, teardown runs in order, and the stop completion covers the
/// in-flight start (REVISION-2 §2).
private func testMonitorStopDuringStartBarrier(_ failures: inout [String]) {
    let order = OrderRecorder()
    let counter = SharedCounter()
    let entered = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    let installer: EventTapInstaller = { runLoop, callback, userInfo in
        counter.increment()
        entered.signal()
        gate.wait()
        return makeFakeInstallation(order: order)(runLoop, callback, userInfo)
    }
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 32,
        installer: installer
    )

    let started = DispatchSemaphore(value: 0)
    let startBox = ErrorBox()
    Thread(block: {
        do { try monitor.start() } catch { startBox.message = "\(error)" }
        started.signal()
    }).start()
    expect(
        &failures,
        entered.wait(timeout: .now() + 5) == .success,
        "R2/stop-during-start: installer must be entered"
    )

    let stopDone = DispatchSemaphore(value: 0)
    monitor.stop { stopDone.signal() }
    gate.signal()

    expect(&failures, started.wait(timeout: .now() + 10) == .success, "R2/stop-during-start: start must return")
    expect(&failures, startBox.message == nil, "R2/stop-during-start: start must succeed (tap was created; stop in flight)")
    expect(&failures, stopDone.wait(timeout: .now() + 10) == .success, "R2/stop-during-start: stop completion must fire")
    expect(&failures, monitor.isIdleForTesting, "R2/stop-during-start: monitor must be idle after settling")
    expect(&failures, counter.value == 1, "R2/stop-during-start: exactly one install attempt")
    expect(
        &failures,
        order.snapshot == ["disable", "teardown"],
        "R2/stop-during-start: must skip enable and tear down in order; got \(order.snapshot)"
    )
    expect(&failures, monitor.mailboxStatistics.pendingCount == 0, "R2/stop-during-start: mailbox must be empty")
}

/// start → stop → start with the stops and starts interleaved through
/// barriers: exactly two installs, each cleaned up once, and the old run's
/// cleanup cannot stop the new run's bridge (gestures flow after restart)
/// (REVISION-2 §2).
private func testMonitorStartStopStart(_ failures: inout [String]) {
    let order = OrderRecorder()
    let counter = SharedCounter()
    let entered = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    let installer: EventTapInstaller = { runLoop, callback, userInfo in
        if counter.increment() == 1 {
            entered.signal()
            gate.wait()
        }
        return makeFakeInstallation(order: order)(runLoop, callback, userInfo)
    }
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 32,
        installer: installer
    )

    let started1 = DispatchSemaphore(value: 0)
    let startBox1 = ErrorBox()
    Thread(block: {
        do { try monitor.start() } catch { startBox1.message = "\(error)" }
        started1.signal()
    }).start()
    expect(
        &failures,
        entered.wait(timeout: .now() + 5) == .success,
        "R2/start-stop-start: first installer must be gated"
    )

    let stop1Done = DispatchSemaphore(value: 0)
    monitor.stop { stop1Done.signal() }

    let started2 = DispatchSemaphore(value: 0)
    let startBox2 = ErrorBox()
    Thread(block: {
        do { try monitor.start() } catch { startBox2.message = "\(error)" }
        started2.signal()
    }).start()
    expect(
        &failures,
        started2.wait(timeout: .now() + 0.2) == .timedOut,
        "R2/start-stop-start: a start issued while a stop is settling must wait"
    )

    gate.signal()
    expect(&failures, started1.wait(timeout: .now() + 10) == .success, "R2/start-stop-start: first start must return")
    expect(&failures, startBox1.message == nil, "R2/start-stop-start: first start must succeed")
    expect(&failures, started2.wait(timeout: .now() + 15) == .success, "R2/start-stop-start: second start must proceed after the stop settled")
    expect(&failures, startBox2.message == nil, "R2/start-stop-start: second start must succeed")
    expect(&failures, monitor.isRunningForTesting, "R2/start-stop-start: monitor must run the second generation")
    expect(&failures, counter.value == 2, "R2/start-stop-start: exactly two installs (got \(counter.value))")
    expect(&failures, stop1Done.wait(timeout: .now() + 10) == .success, "R2/start-stop-start: the first stop's completion must fire exactly once")

    // The new run's bridge is fresh: if the old run's late cleanup had
    // stopped it, these deliveries would be lost and the final drain would
    // hang.
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("R2/start-stop-start: fixtures unavailable")
        return
    }
    monitor.admission.recordHeartbeat()
    expect(&failures, monitor.processEventForTesting(type: .leftMouseDown, event: down), "R2/start-stop-start: restart gesture down must be claimed")
    _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
    expect(&failures, monitor.processEventForTesting(type: .leftMouseUp, event: up), "R2/start-stop-start: restart gesture up must be claimed")
    expect(&failures, drainMonitor(monitor, timeout: 10), "R2/start-stop-start: monitor must drain after restart")
    expect(
        &failures,
        order.snapshot == ["disable", "teardown", "enable", "disable", "teardown"],
        "R2/start-stop-start: each install must be cleaned up exactly once in order; got \(order.snapshot)"
    )
    let invariants = GestureDeliveryInvariants(messages: recorder.snapshot)
    expect(
        &failures,
        invariants.begunGestures == 1 && invariants.gesturesWithTerminal == 1,
        "R2/start-stop-start: the restart gesture must begin and terminate exactly once"
    )
}

/// Repeated stops while a stop is already in flight: every completion fires
/// exactly once, one install, one cleanup (REVISION-2 §2).
private func testMonitorRepeatedStopWhileStopping(_ failures: inout [String]) {
    let order = OrderRecorder()
    let counter = SharedCounter()
    let installer: EventTapInstaller = { runLoop, callback, userInfo in
        counter.increment()
        return makeFakeInstallation(order: order)(runLoop, callback, userInfo)
    }
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 32,
        installer: installer
    )
    do {
        try monitor.start()
    } catch {
        failures.append("R2/repeated-stop: monitor start must succeed (\(error))")
        return
    }
    expect(&failures, monitor.isRunningForTesting, "R2/repeated-stop: monitor must be running")

    let first = DispatchSemaphore(value: 0)
    let second = DispatchSemaphore(value: 0)
    let third = DispatchSemaphore(value: 0)
    monitor.stop { first.signal() }
    monitor.stop { second.signal() }
    monitor.stop { third.signal() }
    expect(&failures, first.wait(timeout: .now() + 10) == .success, "R2/repeated-stop: first completion must fire")
    expect(&failures, second.wait(timeout: .now() + 10) == .success, "R2/repeated-stop: second completion must fire")
    expect(&failures, third.wait(timeout: .now() + 10) == .success, "R2/repeated-stop: third completion must fire")
    expect(&failures, monitor.isIdleForTesting, "R2/repeated-stop: monitor must be idle after the stops")
    expect(&failures, !monitor.hasLiveBridgeForTesting, "R2/repeated-stop: the stop chain must have removed the bridge")
    expect(&failures, counter.value == 1, "R2/repeated-stop: exactly one install")
    expect(
        &failures,
        order.snapshot == ["enable", "disable", "teardown"],
        "R2/repeated-stop: exactly one cleanup in order; got \(order.snapshot)"
    )

    let afterStop = DispatchSemaphore(value: 0)
    monitor.stop { afterStop.signal() }
    expect(
        &failures,
        afterStop.wait(timeout: .now() + 5) == .success,
        "R2/repeated-stop: stop after everything settled must invoke completion"
    )
}

/// A failed monitor start leaves the monitor idle and retryable
/// (REVISION-2 §2).
private func testMonitorRetryAfterFailedStart(_ failures: inout [String]) {
    let order = OrderRecorder()
    let counter = SharedCounter()
    let installer: EventTapInstaller = { runLoop, callback, userInfo in
        if counter.increment() == 1 { return nil }
        return makeFakeInstallation(order: order)(runLoop, callback, userInfo)
    }
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 32,
        installer: installer
    )
    var firstError: String?
    do { try monitor.start() } catch { firstError = "\(error)" }
    expect(&failures, firstError != nil, "R2/retry: first start with a failing installer must throw")
    expect(&failures, monitor.isIdleForTesting, "R2/retry: failed start must leave the monitor idle")
    do {
        try monitor.start()
    } catch {
        failures.append("R2/retry: start after failure must succeed (\(error))")
    }
    expect(&failures, monitor.isRunningForTesting, "R2/retry: retried monitor must be running")
    expect(&failures, counter.value == 2, "R2/retry: exactly two install attempts")

    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("R2/retry: fixtures unavailable")
        return
    }
    monitor.admission.recordHeartbeat()
    expect(&failures, monitor.processEventForTesting(type: .leftMouseDown, event: down), "R2/retry: gesture after retry must be claimed")
    _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
    expect(&failures, monitor.processEventForTesting(type: .leftMouseUp, event: up), "R2/retry: gesture up after retry must be claimed")
    expect(&failures, drainMonitor(monitor, timeout: 10), "R2/retry: monitor must drain")
    expect(
        &failures,
        order.snapshot == ["enable", "disable", "teardown"],
        "R2/retry: the successful install must be cleaned up exactly once; got \(order.snapshot)"
    )
}

// MARK: - Revision 2: bridge stop drain ordering

/// The drain race (REVISION-2 §3): (a) a reserved terminal arriving after a
/// completed stop must be rejected, never silently stranded — pre-fix it
/// was queued forever behind an already-fired completion; (b) with a
/// consumer blocked mid-message, stop must reject further enqueues and
/// still deliver everything already accepted before firing completions.
private func testBridgeStopDrainOrdering(_ failures: inout [String]) {
    do {
        let bridge = GestureEventBridge(capacity: 8, handler: { _ in })
        _ = bridge.enqueue(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation)))
        let stopDone = DispatchSemaphore(value: 0)
        bridge.stop { stopDone.signal() }
        expect(
            &failures,
            stopDone.wait(timeout: .now() + 5) == .success,
            "R2/bridge-stop: stop completion must fire"
        )
        expect(
            &failures,
            bridge.enqueueReservedTerminal(makeMessage(gestureID: 1, sequence: 2, kind: .cancel)) == false,
            "R2/bridge-stop: reserved terminal after stop must be rejected, not stranded"
        )
        let stats = bridge.mailbox.statisticsSnapshot()
        expect(&failures, stats.pendingCount == 0, "R2/bridge-stop: nothing may remain queued after stop completion")
        expect(&failures, stats.reservedRejected >= 1, "R2/bridge-stop: rejected reserved terminal must be counted")
        expect(
            &failures,
            stats.delivered == stats.accepted + stats.reservedEnqueued,
            "R2/bridge-stop: accounting must balance (delivered \(stats.delivered), accepted \(stats.accepted), reserved \(stats.reservedEnqueued))"
        )
    }

    do {
        final class BlockingRecorder: @unchecked Sendable {
            let lock = NSLock()
            private var messages: [GestureEventMessage] = []
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            private var gateFirstMessage = true

            func handle(_ message: GestureEventMessage) {
                lock.lock()
                let shouldGate = gateFirstMessage
                gateFirstMessage = false
                lock.unlock()
                if shouldGate {
                    entered.signal()
                    release.wait()
                }
                lock.lock()
                messages.append(message)
                lock.unlock()
            }

            var count: Int { lock.withLock { messages.count } }
        }
        let blocking = BlockingRecorder()
        let bridge = GestureEventBridge(capacity: 16, handler: { blocking.handle($0) })
        expect(
            &failures,
            bridge.enqueue(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation))) == .accepted,
            "R2/bridge-stop: begin must be accepted"
        )
        expect(
            &failures,
            bridge.enqueue(makeMessage(gestureID: 1, sequence: 2, kind: .move(CGPoint(x: 5, y: 5)))) == .accepted,
            "R2/bridge-stop: move must be accepted"
        )
        expect(
            &failures,
            bridge.enqueue(makeMessage(gestureID: 1, sequence: 3, kind: .end(CGPoint(x: 6, y: 6)))) == .accepted,
            "R2/bridge-stop: end must be accepted"
        )
        expect(
            &failures,
            blocking.entered.wait(timeout: .now() + 2) == .success,
            "R2/bridge-stop: consumer must pick up the first message"
        )

        let stopDone = DispatchSemaphore(value: 0)
        bridge.stop { stopDone.signal() }
        expect(
            &failures,
            bridge.enqueue(makeMessage(gestureID: 2, sequence: 4, kind: .end(CGPoint.zero))) == .rejected,
            "R2/bridge-stop: enqueue after stop must be rejected while draining"
        )
        expect(
            &failures,
            bridge.enqueueReservedTerminal(makeMessage(gestureID: 2, sequence: 5, kind: .cancel)) == false,
            "R2/bridge-stop: reserved terminal must be rejected while draining"
        )
        blocking.release.signal()
        expect(
            &failures,
            stopDone.wait(timeout: .now() + 5) == .success,
            "R2/bridge-stop: completion must fire after the drain"
        )
        expect(
            &failures,
            blocking.count == 3,
            "R2/bridge-stop: every accepted message must be delivered before completion; got \(blocking.count)"
        )
        let stats = bridge.mailbox.statisticsSnapshot()
        expect(&failures, stats.pendingCount == 0, "R2/bridge-stop: mailbox must be empty at completion")
        expect(&failures, stats.rejectedAfterDraining >= 1, "R2/bridge-stop: rejections must be observable")
        expect(&failures, stats.reservedRejected >= 1, "R2/bridge-stop: reserved terminal rejection must be counted")
        expect(
            &failures,
            stats.delivered == stats.accepted + stats.reservedEnqueued,
            "R2/bridge-stop: accounting must balance after drain (delivered \(stats.delivered), accepted \(stats.accepted), reserved \(stats.reservedEnqueued))"
        )
    }
}

/// Randomized producer against concurrent stops: at every stop completion
/// the accounting must balance — nothing accepted is stranded and nothing
/// is delivered twice (aggregate guard for the stop() reorder, REVISION-2
/// §3).
private func testBridgeStopRaceNoStrandedMessages(_ failures: inout [String]) {
    let iterations = 40
    for iteration in 0..<iterations {
        let recorder = DeliveryRecorder()
        let bridge = GestureEventBridge(capacity: 4, handler: { recorder.append($0) })
        let produced = SharedCounter()
        let accepted = SharedCounter()
        let rejected = SharedCounter()
        let overflowed = SharedCounter()
        var randomState = UInt64(truncatingIfNeeded: iteration &+ 0x9E37_79B9)
        let producerDone = DispatchSemaphore(value: 0)
        let producer = Thread(block: {
            for _ in 0..<200 {
                let message = makeMessage(
                    gestureID: 1,
                    sequence: UInt64(produced.increment()),
                    kind: .end(CGPoint.zero)
                )
                switch bridge.enqueue(message) {
                case .accepted: accepted.increment()
                case .rejected: rejected.increment()
                case .overflow: overflowed.increment()
                default: break
                }
            }
            producerDone.signal()
        })
        producer.start()
        // Stop at a randomized moment relative to the producer.
        Thread.sleep(forTimeInterval: Double(nextRandom(&randomState) % 40) / 40_000.0)
        let stopDone = DispatchSemaphore(value: 0)
        bridge.stop { stopDone.signal() }
        expect(&failures, producerDone.wait(timeout: .now() + 10) == .success, "R2/hammer: producer must finish")
        expect(&failures, stopDone.wait(timeout: .now() + 10) == .success, "R2/hammer: stop completion must fire")

        let stats = bridge.mailbox.statisticsSnapshot()
        if stats.pendingCount != 0 {
            failures.append("R2/hammer[\(iteration)]: \(stats.pendingCount) messages stranded after stop completion")
        }
        if stats.accepted != stats.delivered {
            failures.append("R2/hammer[\(iteration)]: accepted \(stats.accepted) != delivered \(stats.delivered)")
        }
        let accounted = accepted.value + rejected.value + overflowed.value
        if accounted != 200 {
            failures.append("R2/hammer[\(iteration)]: enqueue outcomes (\(accounted)) must account for all 200 messages")
        }
        if recorder.count != stats.delivered {
            failures.append("R2/hammer[\(iteration)]: recorder saw \(recorder.count) deliveries, statistics say \(stats.delivered)")
        }
    }
}

// MARK: - Revision 2: bounded main-thread consumption

/// Fake UI executor held at an explicit barrier with continuous input: the
/// total backlog — mailbox plus messages posted to the UI executor — stays
/// bounded, and the executor keeps processing release messages while
/// controlled tasks are still in flight (REVISION-2 §4).
private func testAdapterBoundedBacklogWithSlowUI(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority()
    let host = FakeGestureUIHost()
    let ui = ManualUIExecutor()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 60,
        maxInFlight: 3,
        expiryCheckInterval: nil,
        onSessionInvalidated: { host.resetSession() },
        uiExecutor: { block in ui.enqueue(block) },
        execute: { host.handle($0) }
    )
    let monitor = OrderedMouseGestureMonitor(
        configuration: GestureConfiguration(),
        touchDevices: { [fixtureDevice] },
        consumeEligibleGesture: { _ in fixtureMatch },
        directionalDisplacement: { _ in .zero },
        admission: admission,
        eventHandler: { adapter.handle($0) },
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 8
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("R2/adapter-backlog: fixtures unavailable")
        return
    }

    var maxPending = 0
    var maxInFlight = 0
    var maxTotal = 0
    for _ in 0..<3 {
        monitor.admission.recordHeartbeat()
        expect(&failures, monitor.processEventForTesting(type: .leftMouseDown, event: down), "R2/adapter-backlog: down must be claimed while the UI is slow")
        _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
        _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
        expect(&failures, monitor.processEventForTesting(type: .leftMouseUp, event: up), "R2/adapter-backlog: up must be claimed while the UI is slow")
        let pending = monitor.mailboxStatistics.pendingCount
        let inFlight = adapter.statisticsSnapshot.inFlight
        maxPending = max(maxPending, pending)
        maxInFlight = max(maxInFlight, inFlight)
        maxTotal = max(maxTotal, pending + inFlight)
    }
    expect(&failures, maxInFlight <= 3, "R2/adapter-backlog: posted messages (\(maxInFlight)) must stay within maxInFlight")
    expect(&failures, maxPending <= 9, "R2/adapter-backlog: mailbox pending (\(maxPending)) must stay within capacity+1")
    expect(&failures, maxTotal <= 12, "R2/adapter-backlog: total backlog incl. posted messages (\(maxTotal)) must stay bounded")

    // Posting must saturate the adapter while no UI block can run. The old
    // 0.5s/0.6s timers let task completion race the release/move assertion.
    expect(&failures, ui.waitForPending(3, timeout: 5), "R2/adapter-backlog: UI barrier must hold three posted messages")
    expect(&failures, adapter.statisticsSnapshot.inFlight == 3, "R2/adapter-backlog: adapter must reach its hard cap")
    expect(&failures, monitor.mailboxStatistics.pendingCount <= 9 &&
           monitor.mailboxStatistics.pendingCount + adapter.statisticsSnapshot.inFlight <= 12,
           "R2/adapter-backlog: saturated mailbox and UI backlog stay bounded")
    while host.sendCount < 3 {
        guard ui.runOldestWaiting(timeout: 5) else {
            failures.append("R2/adapter-backlog: expected UI message did not reach the barrier")
            break
        }
    }

    expect(&failures, drainMonitor(monitor, timeout: 20), "R2/adapter-backlog: monitor must drain despite the slow UI")
    while ui.pendingCount > 0 { ui.runOldest() }
    expect(
        &failures,
        adapter.statisticsSnapshot.inFlight == 0,
        "R2/adapter-backlog: all posted messages must finish executing"
    )
    let stats = adapter.statisticsSnapshot
    // Moves may legitimately coalesce or be evicted by terminals under the
    // bounded-mailbox policy (a fast producer can fill the box before the
    // slow consumer dequeues), so only begins and terminals are guaranteed.
    let executedBegins = host.handled.filter { $0.kind == "begin" }.count
    let executedTerminals = host.handled.filter { $0.kind == "end" }.count
    expect(
        &failures,
        executedBegins == 3,
        "R2/adapter-backlog: all three begins must execute (got \(executedBegins))"
    )
    expect(
        &failures,
        executedTerminals == 3,
        "R2/adapter-backlog: all three releases must execute (got \(executedTerminals))"
    )
    expect(
        &failures,
        stats.skippedAtExecution == 0,
        "R2/adapter-backlog: no message may be skipped without invalidation"
    )
    expect(&failures, host.sendCount == 3, "R2/adapter-backlog: every valid release must execute its simulated Send (got \(host.sendCount))")
    expect(&failures, host.heldGesture == 0, "R2/adapter-backlog: the host must not hold a gesture after draining")
    expect(
        &failures,
        host.messagesProcessedWhileTaskInFlight >= 1,
        "R2/adapter-backlog: release/move messages must be processed while a controlled task is still in flight"
    )
    expect(&failures, stats.droppedQueueTimeout == 0, "R2/adapter-backlog: no slot timeout may discard input")
    expect(&failures, host.finishControlledTasks(), "R2/adapter-backlog: controlled tasks must really drain")
}

/// Fake UI executor blocked at its first handler: while it is busy, the runtime
/// generation advances and the session token is invalidated synchronously
/// from a background thread. The held gesture is released immediately, the
/// stale move/end are skipped at execution time (no simulated Send for the
/// old generation), and the next gesture under the new generation flows
/// (REVISION-2 §4).
private func testAdapterInvalidationSkipsStaleMessages(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority()
    let host = FakeGestureUIHost(blockFirstHandle: true)
    let ui = ManualUIExecutor()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 60,
        maxInFlight: 4,
        onSessionInvalidated: { host.resetSession() },
        uiExecutor: { block in ui.enqueue(block) },
        execute: { host.handle($0) }
    )
    let monitor = OrderedMouseGestureMonitor(
        configuration: GestureConfiguration(),
        touchDevices: { [fixtureDevice] },
        consumeEligibleGesture: { _ in fixtureMatch },
        directionalDisplacement: { _ in .zero },
        admission: admission,
        eventHandler: { adapter.handle($0) },
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 8
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("R2/adapter-invalidate: fixtures unavailable")
        return
    }

    let generation1 = admission.snapshot().generation
    monitor.admission.recordHeartbeat()
    expect(&failures, monitor.processEventForTesting(type: .leftMouseDown, event: down), "R2/adapter-invalidate: first gesture down must be claimed")
    _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
    expect(&failures, monitor.processEventForTesting(type: .leftMouseUp, event: up), "R2/adapter-invalidate: first gesture up must be claimed")
    expect(&failures, ui.waitForPending(3, timeout: 5), "R2/adapter-invalidate: stale move/end must be posted before invalidation")
    let firstFinished = DispatchSemaphore(value: 0)
    Thread(block: { ui.runOldest(); firstFinished.signal() }).start()
    expect(
        &failures,
        host.firstHandleEntered.wait(timeout: .now() + 5) == .success,
        "R2/adapter-invalidate: the first begin must start executing on the (busy) UI executor"
    )

    // Invalidate while the UI executor is still busy inside the begin: the
    // stale move/end are queued behind it and must be skipped at execution.
    let invalidated = DispatchSemaphore(value: 0)
    let invalidationStart = Date()
    Thread(block: {
        admission.advanceGeneration()
        adapter.sessionToken.invalidate()
        invalidated.signal()
    }).start()
    expect(
        &failures,
        invalidated.wait(timeout: .now() + 5) == .success,
        "R2/adapter-invalidate: invalidation must complete"
    )
    let invalidationElapsed = Date().timeIntervalSince(invalidationStart)
    expect(
        &failures,
        invalidationElapsed < 0.5,
        "R2/adapter-invalidate: invalidation must be synchronous, never queued behind the busy UI executor (took \(invalidationElapsed)s)"
    )
    expect(
        &failures,
        host.heldGesture == 0,
        "R2/adapter-invalidate: a dropped terminal must not leave the UI holding the gesture"
    )
    let generation2 = admission.snapshot().generation
    expect(&failures, generation2 > generation1, "R2/adapter-invalidate: generation must have advanced")
    host.releaseFirstHandle.signal()
    expect(&failures, firstFinished.wait(timeout: .now() + 5) == .success, "R2/adapter-invalidate: held begin must finish before pumping UI")

    // The next gesture under the new generation flows normally.
    monitor.admission.recordHeartbeat()
    expect(&failures, monitor.processEventForTesting(type: .leftMouseDown, event: down), "R2/adapter-invalidate: new-generation down must be claimed")
    expect(&failures, monitor.processEventForTesting(type: .leftMouseUp, event: up), "R2/adapter-invalidate: new-generation up must be claimed")

    while host.sendCount < 1 {
        guard ui.runOldestWaiting(timeout: 5) else {
            failures.append("R2/adapter-invalidate: new-generation UI message did not arrive")
            break
        }
    }

    expect(&failures, drainMonitor(monitor, timeout: 20), "R2/adapter-invalidate: monitor must drain")
    while ui.pendingCount > 0 { ui.runOldest() }
    expect(
        &failures,
        adapter.statisticsSnapshot.inFlight == 0,
        "R2/adapter-invalidate: all posted messages must finish"
    )

    // The stale move/end of generation 1 were posted before the invalidation
    // and must never execute: only the new generation's release may Send.
    let staleEnds = host.handled.filter { $0.generation == generation1 && ($0.kind == "end" || $0.kind == "move") }
    expect(
        &failures,
        staleEnds.isEmpty,
        "R2/adapter-invalidate: stale generation-1 messages must not execute (saw \(staleEnds.map(\.kind)))"
    )
    expect(&failures, host.sendCount == 1, "R2/adapter-invalidate: exactly the new generation's release may execute a Send (got \(host.sendCount))")
    expect(&failures, host.heldGesture == 0, "R2/adapter-invalidate: the host must not hold a gesture at the end")
    let stats = adapter.statisticsSnapshot
    expect(&failures, stats.skippedAtExecution >= 2, "R2/adapter-invalidate: the stale move and end must be skipped at execution time (got \(stats.skippedAtExecution))")
    expect(
        &failures,
        stats.executed >= 3,
        "R2/adapter-invalidate: the new generation's begin/end must execute (got \(stats.executed))"
    )
    expect(&failures, host.finishControlledTasks(), "R2/adapter-invalidate: controlled tasks must really drain")
}

// MARK: - Revision 3: expired-heartbeat transactions and bootstrap timeouts

/// Deterministic stand-in for a busy UI executor: posted blocks queue up and
/// the test drives them one by one (`runOldest`), so "the message sits in the
/// backlog while time passes" never needs a real sleep.
private final class ManualUIExecutor: @unchecked Sendable {
    private let lock = NSCondition()
    private var blocks: [@Sendable () -> Void] = []

    var pendingCount: Int { lock.withLock { blocks.count } }

    func enqueue(_ block: @escaping @Sendable () -> Void) {
        lock.lock()
        blocks.append(block)
        lock.broadcast()
        lock.unlock()
    }

    func waitForPending(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while blocks.count < count {
            if !lock.wait(until: deadline) { return blocks.count >= count }
        }
        return true
    }

    func runOldestWaiting(timeout: TimeInterval) -> Bool {
        guard waitForPending(1, timeout: timeout) else { return false }
        runOldest()
        return true
    }

    /// Runs the oldest posted block to completion, synchronously.
    func runOldest() {
        lock.lock()
        guard !blocks.isEmpty else { lock.unlock(); return }
        let block = blocks.removeFirst()
        lock.unlock()
        block()
    }
}

/// Records what a fake UI host actually executed: held gesture, committed
/// Sends (the side effect that must never fire for a dead transaction) and
/// handled kinds.
private final class GestureHostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var heldGesture: UInt64 = 0
    private var sends = 0
    private var releaseCalls = 0
    private var handledKindNames: [String] = []

    func handle(_ message: GestureEventMessage) {
        lock.lock()
        handledKindNames.append(Self.kindName(message.kind))
        switch message.kind {
        case .begin: heldGesture = message.gestureID
        case .end:
            sends += 1
            heldGesture = 0
        case .cancel, .tapFailure: heldGesture = 0
        case .move: break
        }
        lock.unlock()
    }

    /// Session-invalidation / gesture-dropped hook: synchronous state release.
    func releaseHeld() {
        lock.lock()
        releaseCalls += 1
        heldGesture = 0
        lock.unlock()
    }

    func resetSession() { lock.withLock { heldGesture = 0 } }

    var held: UInt64 { lock.withLock { heldGesture } }
    var sendCount: Int { lock.withLock { sends } }
    var releaseCount: Int { lock.withLock { releaseCalls } }
    var handledKinds: [String] { lock.withLock { handledKindNames } }

    private static func kindName(_ kind: GestureEventMessage.Kind) -> String {
        switch kind {
        case .begin: return "begin"
        case .move: return "move"
        case .end: return "end"
        case .cancel: return "cancel"
        case .tapFailure: return "tapFailure"
        }
    }
}

/// Gates the first handled message behind a semaphore pair so the test can
/// park one message mid-execution on the UI executor (holding its in-flight
/// slot) while everything else queues up behind the adapter's backpressure.
private final class GatedFirstMessageHost: @unchecked Sendable {
    let inner = GestureHostRecorder()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var gateFirst = true

    func handle(_ message: GestureEventMessage) {
        lock.lock()
        let shouldGate = gateFirst
        gateFirst = false
        lock.unlock()
        if shouldGate {
            entered.signal()
            release.wait()
        }
        inner.handle(message)
    }
}

private func makeTimedMessage(
    generation: UInt64,
    gestureID: UInt64,
    sequence: UInt64,
    timestampSeconds: Double,
    kind: GestureEventMessage.Kind
) -> GestureEventMessage {
    GestureEventMessage(
        generation: generation,
        gestureID: gestureID,
        sequence: sequence,
        timestampSeconds: timestampSeconds,
        kind: kind
    )
}

/// REVISION-3 §1 (a) — the controller-reproduced sequence made
/// deterministic: the begin executes and is held, the end is posted but
/// sits in the backlog while the heartbeat expires, then the delayed end is
/// consumed. The dead transaction must be released instead of committing its
/// late Send.
private func testAdapterExpiredHeartbeatDropsBackloggedEnd(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority()
    let host = GestureHostRecorder()
    let ui = ManualUIExecutor()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 1.0,
        maxInFlight: 4,
        expiryCheckInterval: nil,
        onSessionInvalidated: { host.resetSession() },
        onGestureDropped: { _ in host.releaseHeld() },
        uiExecutor: { block in ui.enqueue(block) },
        execute: { host.handle($0) }
    )

    adapter.handle(
        makeTimedMessage(
            generation: 1, gestureID: 1, sequence: 1,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .begin(fixtureActivation)
        )
    )
    expect(&failures, ui.pendingCount == 1, "R3/expired-end: the begin must be posted")
    ui.runOldest()
    expect(&failures, host.held == 1, "R3/expired-end: the executed begin must be held")
    expect(
        &failures,
        adapter.statisticsSnapshot.executed == 1,
        "R3/expired-end: only the begin may have executed so far"
    )

    // The end is posted but NOT executed while the heartbeat goes stale.
    adapter.handle(
        makeTimedMessage(
            generation: 1, gestureID: 1, sequence: 2,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .end(CGPoint(x: 3, y: 3))
        )
    )
    expect(
        &failures,
        ui.pendingCount == 1,
        "R3/expired-end: the end must sit posted behind the busy executor"
    )
    admission.update { $0.lastHeartbeatSeconds = monotonicTimestampSeconds() - 2 }

    ui.runOldest()
    expect(
        &failures,
        host.sendCount == 0,
        "R3/expired-end: the delayed end must not Send after the heartbeat expired (got \(host.sendCount))"
    )
    expect(
        &failures,
        host.held == 0,
        "R3/expired-end: the held gesture must be released, not merely filtered"
    )
    expect(
        &failures,
        adapter.statisticsSnapshot.skippedAtExecution == 1,
        "R3/expired-end: the delayed end must be skipped at execution time"
    )
    expect(
        &failures,
        adapter.statisticsSnapshot.releasedExpiredGestures == 1,
        "R3/expired-end: the dead transaction must be released exactly once (got \(adapter.statisticsSnapshot.releasedExpiredGestures))"
    )
    expect(
        &failures,
        host.releaseCount == 1,
        "R3/expired-end: the host must observe the drop notification exactly once (got \(host.releaseCount))"
    )
    expect(
        &failures,
        adapter.sessionToken.trackedGestureID == 0,
        "R3/expired-end: the token must not keep the dead gesture tracked"
    )

    // A fresh heartbeat bumps the generation (gap-aware recordHeartbeat), so
    // the recovery gesture must use the current generation.
    admission.recordHeartbeat()
    let freshGen1 = admission.snapshot().generation
    adapter.handle(
        makeTimedMessage(
            generation: freshGen1, gestureID: 2, sequence: 3,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .begin(fixtureActivation)
        )
    )
    ui.runOldest()
    adapter.handle(
        makeTimedMessage(
            generation: freshGen1, gestureID: 2, sequence: 4,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .end(CGPoint(x: 4, y: 4))
        )
    )
    ui.runOldest()
    expect(
        &failures,
        host.sendCount == 1,
        "R3/expired-end: the fresh gesture's release must Send (got \(host.sendCount))"
    )
    expect(&failures, host.held == 0, "R3/expired-end: the host must not hold a gesture at the end")
}

/// REVISION-3 §1 (b): the heartbeat expires and then fully recovers to a
/// fresh value BEFORE the same stale end is consumed. The transaction must
/// not revive: even with a fresh heartbeat at execution time, the stale
/// message fails its validity window, so no Send executes.
private func testAdapterHeartbeatRecoveryCannotReviveStaleEnd(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority()
    let host = GestureHostRecorder()
    let ui = ManualUIExecutor()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 1.0,
        maxInFlight: 4,
        expiryCheckInterval: nil,
        onSessionInvalidated: { host.resetSession() },
        onGestureDropped: { _ in host.releaseHeld() },
        uiExecutor: { block in ui.enqueue(block) },
        execute: { host.handle($0) }
    )

    let now = monotonicTimestampSeconds()
    adapter.handle(
        makeTimedMessage(
            generation: 1, gestureID: 1, sequence: 1,
            timestampSeconds: now,
            kind: .begin(fixtureActivation)
        )
    )
    ui.runOldest()
    expect(&failures, host.held == 1, "R3/revive: the executed begin must be held")

    // A stale end: timestamped 3 s ago, beyond the 1 s validity window.
    adapter.handle(
        makeTimedMessage(
            generation: 1, gestureID: 1, sequence: 2,
            timestampSeconds: now - 3,
            kind: .end(CGPoint(x: 3, y: 3))
        )
    )

    // Heartbeat expires, then fully recovers to a fresh value.
    admission.update { $0.lastHeartbeatSeconds = monotonicTimestampSeconds() - 2 }
    admission.recordHeartbeat()

    ui.runOldest()
    expect(
        &failures,
        host.sendCount == 0,
        "R3/revive: a recovered heartbeat must not revive the stale end (got \(host.sendCount))"
    )
    expect(
        &failures,
        host.held == 0,
        "R3/revive: the held gesture must be released after the stale end is skipped"
    )
    expect(
        &failures,
        adapter.statisticsSnapshot.skippedAtExecution == 1,
        "R3/revive: the stale end must be skipped at execution time"
    )
    expect(
        &failures,
        adapter.statisticsSnapshot.releasedExpiredGestures == 1,
        "R3/revive: the dead transaction must be released exactly once (got \(adapter.statisticsSnapshot.releasedExpiredGestures))"
    )
    expect(
        &failures,
        host.releaseCount == 1,
        "R3/revive: the host must observe the drop notification exactly once (got \(host.releaseCount))"
    )
    expect(
        &failures,
        adapter.sessionToken.trackedGestureID == 0,
        "R3/revive: the dead gesture must not stay tracked"
    )

    admission.recordHeartbeat()
    let freshGen2 = admission.snapshot().generation
    adapter.handle(
        makeTimedMessage(
            generation: freshGen2, gestureID: 2, sequence: 3,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .begin(fixtureActivation)
        )
    )
    ui.runOldest()
    adapter.handle(
        makeTimedMessage(
            generation: freshGen2, gestureID: 2, sequence: 4,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .end(CGPoint(x: 4, y: 4))
        )
    )
    ui.runOldest()
    expect(
        &failures,
        host.sendCount == 1,
        "R3/revive: a genuinely fresh gesture must still Send (got \(host.sendCount))"
    )
}

/// REVISION-3 §1 (c): the stale end waits at the consumer backpressure
/// point (the single in-flight slot is held by a gated begin), the session
/// is invalidated and recovers with a new gesture — the stale end must be
/// dropped at the post-slot epoch re-check, never re-claimed into the new
/// session.
private func testAdapterEpochNotReclaimedWhileBackpressured(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority()
    let gatedHost = GatedFirstMessageHost()
    let ui = ManualUIExecutor()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 60,
        maxInFlight: 1,
        expiryCheckInterval: nil,
        onSessionInvalidated: { gatedHost.inner.releaseHeld() },
        uiExecutor: { block in ui.enqueue(block) },
        execute: { gatedHost.handle($0) }
    )
    let now = monotonicTimestampSeconds()

    let begin1Done = DispatchSemaphore(value: 0)
    Thread(block: {
        adapter.handle(
            makeTimedMessage(
                generation: 1, gestureID: 1, sequence: 1,
                timestampSeconds: now,
                kind: .begin(fixtureActivation)
            )
        )
        begin1Done.signal()
    }).start()
    expect(
        &failures,
        waitUntil(timeout: 5) { ui.pendingCount == 1 },
        "R3/epoch: the gated begin must be posted"
    )

    // Drive the begin's executeOnUI on a helper thread: it parks inside the
    // host (holding the only in-flight slot) until released.
    let begin1Executed = DispatchSemaphore(value: 0)
    Thread(block: {
        ui.runOldest()
        begin1Executed.signal()
    }).start()
    expect(
        &failures,
        gatedHost.entered.wait(timeout: .now() + 5) == .success,
        "R3/epoch: the gated begin must be executing"
    )

    // The stale end now blocks at the adapter's backpressure point.
    let end1Done = DispatchSemaphore(value: 0)
    Thread(block: {
        adapter.handle(
            makeTimedMessage(
                generation: 1, gestureID: 1, sequence: 2,
                timestampSeconds: now,
                kind: .end(CGPoint(x: 3, y: 3))
            )
        )
        end1Done.signal()
    }).start()
    expect(
        &failures,
        end1Done.wait(timeout: .now() + 0.3) == .timedOut,
        "R3/epoch: the stale end must sit at the backpressure point"
    )

    // Invalidate, then recover: fresh heartbeat and a new-generation gesture.
    adapter.sessionToken.invalidate()
    admission.recordHeartbeat()
    let recoveredGen = admission.snapshot().generation
    let begin2Done = DispatchSemaphore(value: 0)
    Thread(block: {
        adapter.handle(
            makeTimedMessage(
                generation: recoveredGen, gestureID: 2, sequence: 3,
                timestampSeconds: monotonicTimestampSeconds(),
                kind: .begin(fixtureActivation)
            )
        )
        begin2Done.signal()
    }).start()
    expect(
        &failures,
        begin2Done.wait(timeout: .now() + 0.3) == .timedOut,
        "R3/epoch: the new begin must wait for the single slot"
    )

    gatedHost.release.signal()
    expect(
        &failures,
        begin1Executed.wait(timeout: .now() + 5) == .success,
        "R3/epoch: the gated begin must finish executing"
    )
    expect(
        &failures,
        end1Done.wait(timeout: .now() + 5) == .success,
        "R3/epoch: the stale end's handle must return after the epoch re-check"
    )
    expect(
        &failures,
        begin2Done.wait(timeout: .now() + 5) == .success,
        "R3/epoch: the new begin must post once the slot frees"
    )
    expect(
        &failures,
        waitUntil(timeout: 5) { ui.pendingCount == 1 },
        "R3/epoch: the new begin's closure must be posted"
    )
    ui.runOldest()
    adapter.handle(
        makeTimedMessage(
            generation: recoveredGen, gestureID: 2, sequence: 4,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .end(CGPoint(x: 4, y: 4))
        )
    )
    ui.runOldest()

    let stats = adapter.statisticsSnapshot
    expect(
        &failures,
        stats.droppedInvalidSession == 1,
        "R3/epoch: the stale end must be dropped at the post-slot epoch re-check (got \(stats.droppedInvalidSession))"
    )
    expect(
        &failures,
        stats.skippedAtExecution == 0,
        "R3/epoch: nothing reached the UI executor stale (got \(stats.skippedAtExecution))"
    )
    expect(
        &failures,
        gatedHost.inner.sendCount == 1,
        "R3/epoch: only the new gesture's release may Send (got \(gatedHost.inner.sendCount))"
    )
    expect(
        &failures,
        gatedHost.inner.held == 0,
        "R3/epoch: the host must not hold a gesture at the end"
    )
    expect(
        &failures,
        gatedHost.inner.handledKinds == ["begin", "begin", "end"],
        "R3/epoch: only the two begins and the new end may execute; got \(gatedHost.inner.handledKinds)"
    )
}


/// REVISION-3 §2 (worker level): the bootstrap times out while the
/// installer is still gated. The timeout must NOT be confused with a
/// finished teardown: the worker stays `.starting` (it still owns the
/// install), a second `start` is explicitly rejected, stop completions
/// wait for the real teardown, and once the installer returns the
/// teardown runs exactly once — after which a retry on the same object
/// succeeds. Also pins the nil-installer ordering: a resolved failure
/// returns only AFTER its cleanup finished.
private func testWorkerBootstrapTimeoutKeepsOwnership(_ failures: inout [String]) {
    do {
        // Resolved-failure control: the nil-installer bootstrap must have
        // finished its cleanup BEFORE start() returned, so the failure is
        // deterministically .stopped (and retryable).
        let resolved = EventTapWorker(
            installer: { _, _, _ in nil },
            eventHandler: { _, _ in nil }
        )
        var threw = false
        do { try resolved.start(bootstrapTimeout: 2) } catch { threw = true }
        expect(&failures, threw, "R3/worker-timeout: a nil installer must still throw")
        expect(
            &failures,
            resolved.currentState == .stopped,
            "R3/worker-timeout: a resolved failure must return only after cleanup (saw \(resolved.currentState))"
        )
    }

    let order = OrderRecorder()
    let calls = SharedCounter()
    let entered = DispatchSemaphore(value: 0)
    let releaseInstaller = DispatchSemaphore(value: 0)
    let worker = EventTapWorker(
        installer: { runLoop, callback, userInfo in
            if calls.increment() == 1 {
                entered.signal()
                releaseInstaller.wait()
            }
            return makeFakeInstallation(order: order)(runLoop, callback, userInfo)
        },
        eventHandler: { _, _ in nil }
    )

    // Bootstrap timeout: the installer is gated, so start() throws quickly —
    // while the worker thread is still inside the installer.
    var timedOut = false
    do { try worker.start(bootstrapTimeout: 0.3) } catch { timedOut = true }
    expect(&failures, timedOut, "R3/worker-timeout: the gated bootstrap must time out")
    expect(
        &failures,
        worker.currentState == .starting,
        "R3/worker-timeout: a timed-out worker must still be starting — nothing was torn down (saw \(worker.currentState))"
    )

    // A second start on the still-bootstrapping worker is explicitly
    // rejected; it must not silently pretend success.
    var secondThrew = false
    do { try worker.start(bootstrapTimeout: 0.3) } catch { secondThrew = true }
    expect(&failures, secondThrew, "R3/worker-timeout: a second start before teardown must be explicitly rejected")

    // Stop completions may not be honoured before the real teardown.
    let stopDone = DispatchSemaphore(value: 0)
    let repeatedStopDone = DispatchSemaphore(value: 0)
    worker.stop { stopDone.signal() }
    worker.stop { repeatedStopDone.signal() }
    expect(
        &failures,
        stopDone.wait(timeout: .now() + 0.3) == .timedOut,
        "R3/worker-timeout: the stop completion must not fire before the real teardown"
    )

    // Release the installer: the teardown runs exactly once, in order, and
    // both stop completions fire — once each.
    releaseInstaller.signal()
    expect(
        &failures,
        stopDone.wait(timeout: .now() + 5) == .success,
        "R3/worker-timeout: the stop completion must fire after the real teardown"
    )
    expect(
        &failures,
        repeatedStopDone.wait(timeout: .now() + 5) == .success,
        "R3/worker-timeout: the repeated stop completion must fire exactly once"
    )
    expect(
        &failures,
        order.snapshot == ["disable", "teardown"],
        "R3/worker-timeout: the abandoned install must skip enable and tear down exactly once; got \(order.snapshot)"
    )
    expect(
        &failures,
        worker.currentState == .stopped,
        "R3/worker-timeout: the worker must end stopped"
    )

    // Retry on the same object now succeeds and installs afresh.
    do {
        try worker.start(bootstrapTimeout: 5)
    } catch {
        failures.append("R3/worker-timeout: retry after the real teardown must succeed (\(error))")
    }
    expect(&failures, worker.currentState == .running, "R3/worker-timeout: the retried worker must run")
    let finalStop = DispatchSemaphore(value: 0)
    worker.stop { finalStop.signal() }
    expect(
        &failures,
        finalStop.wait(timeout: .now() + 5) == .success,
        "R3/worker-timeout: the retried worker's stop must complete"
    )
    expect(
        &failures,
        order.snapshot == ["disable", "teardown", "enable", "disable", "teardown"],
        "R3/worker-timeout: exactly one abandoned teardown plus one full run; got \(order.snapshot)"
    )
}

/// REVISION-3 §2 (monitor level): after a bootstrap timeout the monitor
/// keeps the old worker's ownership — it is NOT idle, stop completions are
/// not honoured before the real teardown, and a retry cannot run a second
/// installer while the first is still blocked. Releasing the installer
/// tears the old run down exactly once, completes the stop, and the retry
/// then succeeds with its own worker.
private func testMonitorBootstrapTimeoutKeepsOwnership(_ failures: inout [String]) {
    let order = OrderRecorder()
    let calls = SharedCounter()
    let entered = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    let installer: EventTapInstaller = { runLoop, callback, userInfo in
        if calls.increment() == 1 {
            entered.signal()
            gate.wait()
        }
        return makeFakeInstallation(order: order)(runLoop, callback, userInfo)
    }
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 16,
        installer: installer,
        bootstrapTimeout: 0.3
    )

    // start #1: the installer is gated, so the bootstrap times out fast and
    // start() throws promptly — while the old worker is still installing.
    let started1 = DispatchSemaphore(value: 0)
    let startBox1 = ErrorBox()
    Thread(block: {
        do { try monitor.start() } catch { startBox1.message = "\(error)" }
        started1.signal()
    }).start()
    expect(
        &failures,
        entered.wait(timeout: .now() + 5) == .success,
        "R3/monitor-timeout: the installer must be entered"
    )
    expect(
        &failures,
        started1.wait(timeout: .now() + 5) == .success,
        "R3/monitor-timeout: the timed-out start must return promptly"
    )
    expect(
        &failures,
        startBox1.message != nil,
        "R3/monitor-timeout: the timed-out start must throw"
    )

    // Ownership retained: the monitor must NOT report idle while the old
    // worker's installer has not returned yet.
    expect(
        &failures,
        !monitor.isIdleForTesting,
        "R3/monitor-timeout: the monitor must keep stopping ownership after a bootstrap timeout"
    )

    // A stop must not honour its completion before the real teardown.
    let stopDone = DispatchSemaphore(value: 0)
    monitor.stop { stopDone.signal() }
    expect(
        &failures,
        stopDone.wait(timeout: .now() + 0.3) == .timedOut,
        "R3/monitor-timeout: the stop completion must wait for the real worker teardown"
    )

    // A retry must wait out the retained stopping state — no second
    // installer may run while the first is still blocked.
    let started2 = DispatchSemaphore(value: 0)
    let startBox2 = ErrorBox()
    Thread(block: {
        do { try monitor.start() } catch { startBox2.message = "\(error)" }
        started2.signal()
    }).start()
    expect(
        &failures,
        started2.wait(timeout: .now() + 0.3) == .timedOut,
        "R3/monitor-timeout: a retry during the retained stopping state must wait"
    )
    expect(
        &failures,
        calls.value == 1,
        "R3/monitor-timeout: no second installer before the old worker exits (got \(calls.value))"
    )

    // Release the installer: the old worker tears down exactly once, the
    // stop completes, and the retry proceeds with its own worker.
    gate.signal()
    expect(
        &failures,
        stopDone.wait(timeout: .now() + 5) == .success,
        "R3/monitor-timeout: the stop completion must fire once the teardown is real"
    )
    expect(
        &failures,
        started2.wait(timeout: .now() + 15) == .success,
        "R3/monitor-timeout: the retrying start must finish after the teardown"
    )
    expect(
        &failures,
        startBox2.message == nil,
        "R3/monitor-timeout: the retrying start must succeed (got \(startBox2.message ?? "nil"))"
    )
    expect(
        &failures,
        monitor.isRunningForTesting,
        "R3/monitor-timeout: the monitor must run the retried worker"
    )
    expect(
        &failures,
        calls.value == 2,
        "R3/monitor-timeout: exactly two installs after the retry (got \(calls.value))"
    )
    expect(
        &failures,
        order.snapshot == ["disable", "teardown", "enable"],
        "R3/monitor-timeout: the abandoned worker must tear down exactly once before the retry enables; got \(order.snapshot)"
    )

    // Final stop completes cleanly and the second run tears down once.
    let finalStop = DispatchSemaphore(value: 0)
    monitor.stop { finalStop.signal() }
    expect(
        &failures,
        finalStop.wait(timeout: .now() + 5) == .success,
        "R3/monitor-timeout: the final stop must complete"
    )
    expect(
        &failures,
        monitor.isIdleForTesting,
        "R3/monitor-timeout: the monitor must end idle"
    )
    expect(
        &failures,
        order.snapshot == ["disable", "teardown", "enable", "disable", "teardown"],
        "R3/monitor-timeout: exactly one teardown per run; got \(order.snapshot)"
    )
}

// MARK: - Revision 4 tests

/// REVISION-4 §1: token.epoch IS admission.generation — there is no second
/// counter. invalidate() advances the shared generation so every backlogged
/// message from the old generation is rejected by the same mechanism the
/// consumer already uses.
private func testUnifiedInvalidationIdentity(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 60,
        expiryCheckInterval: nil,
        execute: { _ in }
    )

    let gen1 = admission.snapshot().generation
    expect(
        &failures,
        adapter.sessionToken.epoch == gen1,
        "R4/identity: token.epoch must equal admission.generation (token=\(adapter.sessionToken.epoch), admission=\(gen1))"
    )

    adapter.sessionToken.invalidate()
    let gen2 = admission.snapshot().generation
    expect(
        &failures,
        gen2 > gen1,
        "R4/identity: invalidate() must advance the shared generation (before=\(gen1), after=\(gen2))"
    )
    expect(
        &failures,
        adapter.sessionToken.epoch == gen2,
        "R4/identity: token.epoch must track the post-invalidation generation"
    )

    // advanceGeneration() from the admission side must also be visible
    // through the token — they share one counter.
    let gen3 = admission.advanceGeneration()
    expect(
        &failures,
        adapter.sessionToken.epoch == gen3,
        "R4/identity: admission.advanceGeneration() must be visible through token.epoch"
    )
}

/// REVISION-4 §2: gap-aware recordHeartbeat detects that the previous
/// heartbeat was already stale, advances the generation, and fires the gap
/// handler which releases the tracked gesture synchronously — even before
/// any consumer-side message arrives.
private func testGapAwareHeartbeatReleasesTrackedGesture(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority(heartbeatTolerance: 0.1)
    let host = GestureHostRecorder()
    let ui = ManualUIExecutor()
    final class DropBox: @unchecked Sendable {
        let lock = NSLock()
        var ids: [UInt64] = []
    }
    let drops = DropBox()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 0.1,
        expiryCheckInterval: nil,
        onGestureDropped: { id in
            drops.lock.lock()
            drops.ids.append(id)
            drops.lock.unlock()
            host.releaseHeld()
        },
        uiExecutor: { block in ui.enqueue(block) },
        execute: { host.handle($0) }
    )

    let gen1 = admission.snapshot().generation
    adapter.handle(
        makeTimedMessage(
            generation: gen1, gestureID: 42, sequence: 1,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .begin(fixtureActivation)
        )
    )
    ui.runOldest()
    expect(&failures, host.held == 42, "R4/gap: the begin must execute and hold the gesture")

    // Let the heartbeat go stale, then call recordHeartbeat — the gap-aware
    // path must detect the staleness, bump the generation, and fire the gap
    // handler which releases the tracked gesture.
    Thread.sleep(forTimeInterval: 0.15)
    let genBefore = admission.snapshot().generation
    admission.recordHeartbeat()
    let genAfter = admission.snapshot().generation
    expect(
        &failures,
        genAfter > genBefore,
        "R4/gap: recordHeartbeat after staleness must advance the generation (before=\(genBefore), after=\(genAfter))"
    )
    expect(
        &failures,
        host.held == 0,
        "R4/gap: the gap handler must release the held gesture synchronously"
    )
    drops.lock.lock()
    let capturedDrops = drops.ids
    drops.lock.unlock()
    expect(
        &failures,
        capturedDrops == [42],
        "R4/gap: onGestureDropped must fire exactly once for the released gesture (got \(capturedDrops))"
    )
    expect(
        &failures,
        adapter.sessionToken.trackedGestureID == 0,
        "R4/gap: the token must not keep the released gesture tracked"
    )
}

/// REVISION-4 §3: the independent expiry watchdog releases the tracked
/// gesture even when the UI executor is frozen (all in-flight slots full).
/// The watchdog runs on its own timer, not behind the adapter's backpressure.
private func testWatchdogReleasesWhenUIFrozen(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority(heartbeatTolerance: 0.1)
    let host = GestureHostRecorder()
    let ui = ManualUIExecutor()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 0.1,
        maxInFlight: 1,
        expiryCheckInterval: 0.05,
        onGestureDropped: { _ in host.releaseHeld() },
        uiExecutor: { block in ui.enqueue(block) },
        execute: { host.handle($0) }
    )

    let gen = admission.snapshot().generation
    adapter.handle(
        makeTimedMessage(
            generation: gen, gestureID: 99, sequence: 1,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .begin(fixtureActivation)
        )
    )
    ui.runOldest()
    expect(&failures, host.held == 99, "R4/watchdog: the begin must execute and hold the gesture")

    // Let the heartbeat go stale but do NOT post any further messages — the
    // watchdog's independent timer must detect the expiry and release the
    // gesture without any consumer-thread involvement.
    Thread.sleep(forTimeInterval: 0.15)
    adapter.performExpiryCheckForTesting()
    expect(
        &failures,
        host.held == 0,
        "R4/watchdog: the expiry check must release the held gesture even with no consumer messages"
    )
    expect(
        &failures,
        adapter.sessionToken.trackedGestureID == 0,
        "R4/watchdog: the token must not keep the expired gesture tracked"
    )
    expect(
        &failures,
        adapter.statisticsSnapshot.releasedExpiredGestures >= 1,
        "R4/watchdog: the released-expired counter must reflect the watchdog release"
    )
}

/// The watchdog is disabled when expiryCheckInterval is nil: no timer fires,
/// no expiry check runs, and a stale heartbeat does not release the gesture
/// through the watchdog path (only the consumer-thread path can).
private func testWatchdogDisabledByNilInterval(_ failures: inout [String]) {
    let admission = GestureAdmissionAuthority(heartbeatTolerance: 0.1)
    let host = GestureHostRecorder()
    let ui = ManualUIExecutor()
    let adapter = GestureMainQueueAdapter(
        admission: admission,
        heartbeatTolerance: 0.1,
        expiryCheckInterval: nil,
        onGestureDropped: { _ in host.releaseHeld() },
        uiExecutor: { block in ui.enqueue(block) },
        execute: { host.handle($0) }
    )

    let gen = admission.snapshot().generation
    adapter.handle(
        makeTimedMessage(
            generation: gen, gestureID: 77, sequence: 1,
            timestampSeconds: monotonicTimestampSeconds(),
            kind: .begin(fixtureActivation)
        )
    )
    ui.runOldest()
    expect(&failures, host.held == 77, "R4/no-watchdog: the begin must execute")

    // Let the heartbeat go stale and wait longer than the watchdog would
    // have taken if it were enabled. With nil interval, the gesture stays.
    Thread.sleep(forTimeInterval: 0.2)
    adapter.performExpiryCheckForTesting()
    expect(
        &failures,
        host.held == 77,
        "R4/no-watchdog: with nil expiryCheckInterval the watchdog must not fire (gesture still held)"
    )
    expect(
        &failures,
        adapter.sessionToken.trackedGestureID == 77,
        "R4/no-watchdog: the token must keep the gesture tracked when the watchdog is disabled"
    )
}

// MARK: - Fixtures and helpers

private func expect(_ failures: inout [String], _ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

private func nextRandom(_ state: inout UInt64) -> UInt64 {
    var value = state
    value ^= value << 13
    value ^= value >> 7
    value ^= value << 17
    state = value
    return value
}

private func makeMouseEvent(_ type: CGEventType, at location: CGPoint) -> CGEvent? {
    CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: location,
        mouseButton: .left
    )
}

private let fixtureMatch = GestureMatch(
    deviceToken: 7,
    deviceKind: .magicMouse,
    touchCount: 2,
    newestTouchAgeSeconds: 0.02,
    oldestTouchAgeSeconds: 0.05,
    maximumMovement: 0
)

private let fixtureActivation = GestureActivation(
    location: CGPoint(x: 100, y: 100),
    button: .left,
    match: fixtureMatch
)

private let fixtureDevice = TouchDeviceInfo(
    token: 7,
    kind: .magicMouse,
    familyID: 0,
    sensorRows: 12,
    sensorColumns: 10,
    touchCount: 2,
    lastFrameAgeSeconds: 0.01,
    callbackCount: 1,
    rawTouchCount: 2,
    stageMask: 0x10,
    directionalDisplacement: .zero
)

/// Records everything the single consumer delivers, optionally sleeping per
/// message to emulate a slow consumer.
private final class DeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [GestureEventMessage] = []
    let microsecondsPerMessage: Int32

    init(microsecondsPerMessage: Int32 = 0) {
        self.microsecondsPerMessage = microsecondsPerMessage
    }

    func append(_ message: GestureEventMessage) {
        if microsecondsPerMessage > 0 { usleep(useconds_t(microsecondsPerMessage)) }
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var snapshot: [GestureEventMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return messages.count
    }
}

/// Stops the monitor and blocks until the mailbox has fully drained, so all
/// in-flight messages are visible in the recorder.
private func drainMonitor(_ monitor: OrderedMouseGestureMonitor, timeout: TimeInterval) -> Bool {
    let drained = DispatchSemaphore(value: 0)
    monitor.stop { drained.signal() }
    return drained.wait(timeout: .now() + timeout) == .success
}

private struct GestureDeliveryInvariants {
    var sequenceInversions = 0
    var gesturesWithMultipleTerminals = 0
    var gesturesWithMultipleBegins = 0
    var begunGestures = 0
    var gesturesWithTerminal = 0

    init(messages: [GestureEventMessage]) {
        var previousSequence: UInt64 = 0
        var begins: [UInt64: Int] = [:]
        var terminals: [UInt64: Int] = [:]
        for message in messages {
            if message.sequence <= previousSequence { sequenceInversions += 1 }
            previousSequence = message.sequence
            guard message.gestureID != 0 else { continue }
            if case .begin = message.kind { begins[message.gestureID, default: 0] += 1 }
            if message.isTerminal { terminals[message.gestureID, default: 0] += 1 }
        }
        gesturesWithMultipleBegins = begins.values.filter { $0 > 1 }.count
        gesturesWithMultipleTerminals = terminals.values.filter { $0 > 1 }.count
        begunGestures = begins.count
        gesturesWithTerminal = terminals.count
    }
}

// MARK: - Mailbox unit tests

private func makeMessage(
    gestureID: UInt64,
    sequence: UInt64,
    kind: GestureEventMessage.Kind
) -> GestureEventMessage {
    GestureEventMessage(
        generation: 1,
        gestureID: gestureID,
        sequence: sequence,
        // Mirrors the production emitter: fresh monotonic timestamps, so
        // the adapter's validity-window validation sees a live message
        // (a zero stamp would read as infinitely old).
        timestampSeconds: monotonicTimestampSeconds(),
        kind: kind
    )
}

private func testMailboxOrderingAndBounds(_ failures: inout [String]) {
    do {
        let mailbox = BoundedGestureMailbox(capacity: 4)
        expect(
            &failures,
            mailbox.enqueue(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation))) == .accepted,
            "mailbox begin should be accepted"
        )
        expect(
            &failures,
            mailbox.enqueue(makeMessage(gestureID: 1, sequence: 2, kind: .move(CGPoint(x: 1, y: 1)))) == .accepted,
            "mailbox move should be accepted"
        )
        expect(
            &failures,
            mailbox.enqueue(makeMessage(gestureID: 1, sequence: 3, kind: .move(CGPoint(x: 2, y: 2)))) == .coalescedMove,
            "adjacent move must coalesce into the pending tail"
        )
        expect(
            &failures,
            mailbox.enqueue(makeMessage(gestureID: 1, sequence: 4, kind: .end(CGPoint(x: 3, y: 3)))) == .accepted,
            "mailbox end should be accepted"
        )
        var kinds: [String] = []
        while let message = mailbox.dequeueWaiting(timeout: 0) {
            switch message.kind {
            case .begin: kinds.append("begin")
            case .move: kinds.append("move")
            case .end: kinds.append("end")
            case .cancel: kinds.append("cancel")
            case .tapFailure: kinds.append("tapFailure")
            }
        }
        expect(&failures, kinds == ["begin", "move", "end"], "mailbox must deliver FIFO with the coalesced tail move; got \(kinds)")
    }

    do {
        // A terminal evicts buffered moves instead of overflowing.
        let mailbox = BoundedGestureMailbox(capacity: 2)
        _ = mailbox.enqueue(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation)))
        expect(
            &failures,
            mailbox.enqueue(makeMessage(gestureID: 1, sequence: 2, kind: .move(CGPoint(x: 1, y: 1)))) == .accepted,
            "capacity-2 mailbox should accept begin+move"
        )
        expect(
            &failures,
            mailbox.enqueue(makeMessage(gestureID: 1, sequence: 3, kind: .end(CGPoint(x: 2, y: 2)))) == .accepted,
            "terminal must evict moves instead of overflowing"
        )
        var kinds: [String] = []
        while let message = mailbox.dequeueWaiting(timeout: 0) {
            switch message.kind {
            case .begin: kinds.append("begin")
            case .move: kinds.append("move")
            case .end: kinds.append("end")
            case .cancel: kinds.append("cancel")
            case .tapFailure: kinds.append("tapFailure")
            }
        }
        expect(&failures, kinds == ["begin", "end"], "evicted move must not be delivered; got \(kinds)")
        let stats = mailbox.statisticsSnapshot()
        expect(&failures, stats.droppedMoves == 1, "evicted move must be counted")
    }

    do {
        // Terminals cannot be evicted: a full terminal buffer overflows.
        let mailbox = BoundedGestureMailbox(capacity: 2)
        _ = mailbox.enqueue(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation)))
        _ = mailbox.enqueue(makeMessage(gestureID: 2, sequence: 2, kind: .begin(fixtureActivation)))
        expect(
            &failures,
            mailbox.enqueue(makeMessage(gestureID: 3, sequence: 3, kind: .begin(fixtureActivation))) == .overflow,
            "terminal into a full terminal buffer must report overflow"
        )
        expect(
            &failures,
            mailbox.enqueue(makeMessage(gestureID: 1, sequence: 4, kind: .move(CGPoint.zero))) == .droppedMove,
            "move into a full terminal buffer must be dropped"
        )
    }

    do {
        // Reserved terminal: stored exactly once, delivered after the buffer.
        let mailbox = BoundedGestureMailbox(capacity: 1)
        _ = mailbox.enqueue(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation)))
        mailbox.enqueueReservedTerminal(makeMessage(gestureID: 1, sequence: 2, kind: .cancel))
        mailbox.enqueueReservedTerminal(makeMessage(gestureID: 1, sequence: 3, kind: .cancel))
        var kinds: [String] = []
        while let message = mailbox.dequeueWaiting(timeout: 0) {
            switch message.kind {
            case .begin: kinds.append("begin")
            case .move: kinds.append("move")
            case .end: kinds.append("end")
            case .cancel: kinds.append("cancel")
            case .tapFailure: kinds.append("tapFailure")
            }
        }
        expect(&failures, kinds == ["begin", "cancel"], "reserved terminal must be delivered once after the buffer; got \(kinds)")
        let stats = mailbox.statisticsSnapshot()
        expect(&failures, stats.reservedRejected == 1, "second reserved terminal must be rejected")

        mailbox.beginDraining()
        expect(
            &failures,
            mailbox.enqueue(makeMessage(gestureID: 9, sequence: 9, kind: .end(CGPoint.zero))) == .rejected,
            "enqueue after draining must be rejected"
        )
        expect(
            &failures,
            mailbox.dequeueWaiting(timeout: 0) == nil,
            "empty draining mailbox must return nil immediately"
        )
    }
}

private func testMailboxMoveFloodBounded(_ failures: inout [String]) {
    let mailbox = BoundedGestureMailbox(capacity: 16)
    _ = mailbox.enqueue(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation)))
    var maxPending = 0
    for index in 0..<100_000 {
        _ = mailbox.enqueue(
            makeMessage(gestureID: 1, sequence: UInt64(index + 2), kind: .move(CGPoint(x: Double(index), y: 0)))
        )
        if index % 8192 == 0 {
            maxPending = max(maxPending, mailbox.statisticsSnapshot().pendingCount)
        }
    }
    let stats = mailbox.statisticsSnapshot()
    expect(&failures, maxPending <= 17, "mailbox pending (\(maxPending)) must stay within capacity+1 during flood")
    expect(&failures, stats.pendingCount <= 17, "mailbox pending (\(stats.pendingCount)) must stay bounded")
    expect(&failures, stats.coalescedMoves >= 99_000, "adjacent moves must coalesce under flood (coalesced \(stats.coalescedMoves))")
    expect(&failures, stats.overflowCount == 0, "move-only flood must never overflow")

    _ = mailbox.enqueue(makeMessage(gestureID: 1, sequence: 200_000, kind: .end(CGPoint.zero)))
    var deliveredMoves = 0
    var sawEnd = false
    while let message = mailbox.dequeueWaiting(timeout: 0) {
        switch message.kind {
        case .move: deliveredMoves += 1
        case .end: sawEnd = true
        default: break
        }
    }
    expect(&failures, sawEnd, "terminal after flood must be delivered")
    expect(&failures, deliveredMoves >= 1, "at least the coalesced tail move must survive the flood")
}

// MARK: - Bridge (ordered consumer)

private func testBridgeDrainsBeforeStopCompletion(_ failures: inout [String]) {
    let recorder = DeliveryRecorder()
    let bridge = GestureEventBridge(capacity: 16, handler: { recorder.append($0) })
    _ = bridge.enqueue(makeMessage(gestureID: 1, sequence: 1, kind: .begin(fixtureActivation)))
    _ = bridge.enqueue(makeMessage(gestureID: 1, sequence: 2, kind: .move(CGPoint(x: 5, y: 5))))
    _ = bridge.enqueue(makeMessage(gestureID: 1, sequence: 3, kind: .end(CGPoint(x: 6, y: 6))))
    _ = bridge.enqueue(makeMessage(gestureID: 0, sequence: 4, kind: .tapFailure))

    let drained = DispatchSemaphore(value: 0)
    bridge.stop { drained.signal() }
    expect(
        &failures,
        drained.wait(timeout: .now() + 5) == .success,
        "bridge stop completion must fire"
    )
    expect(
        &failures,
        !bridge.isRunning,
        "bridge consumer thread must exit after stop"
    )
    expect(
        &failures,
        recorder.count == 4,
        "all queued messages (terminals included) must be delivered before stop completion; got \(recorder.count)"
    )
    expect(
        &failures,
        bridge.enqueue(makeMessage(gestureID: 1, sequence: 5, kind: .end(CGPoint.zero))) == .rejected,
        "enqueue after stop must be rejected"
    )

    let second = DispatchSemaphore(value: 0)
    bridge.stop { second.signal() }
    expect(
        &failures,
        second.wait(timeout: .now() + 5) == .success,
        "repeated bridge stop must still invoke its completion exactly once"
    )
}

// MARK: - EventTapWorker lifecycle

private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private func makeFakeInstallation(order: OrderRecorder) -> EventTapInstaller {
    { _, _, _ in
        var context = CFRunLoopSourceContext()
        guard let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else { return nil }
        return EventTapInstallation(
            source: source,
            enable: { order.append("enable") },
            disable: { order.append("disable") },
            teardown: { order.append("teardown") }
        )
    }
}

private func testEventTapWorkerLifecycle(_ failures: inout [String]) {
    do {
        // Installer failure surfaces as a thrown start and a stop completion
        // that fires immediately.
        let failing = EventTapWorker(
            installer: { _, _, _ in nil },
            eventHandler: { _, _ in nil }
        )
        var threw = false
        do { try failing.start() } catch { threw = true }
        expect(&failures, threw, "failing installer must make start() throw")
        let completion = DispatchSemaphore(value: 0)
        failing.stop { completion.signal() }
        expect(
            &failures,
            completion.wait(timeout: .now() + 2) == .success,
            "stop after failed start must invoke completion"
        )
    }

    do {
        // Stop requested while the installer is still running: the tap is
        // never enabled, teardown still runs in order, completion fires once.
        let order = OrderRecorder()
        let slow = EventTapWorker(
            installer: { runLoop, callback, userInfo in
                Thread.sleep(forTimeInterval: 0.15)
                return makeFakeInstallation(order: order)(runLoop, callback, userInfo)
            },
            eventHandler: { _, _ in nil }
        )
        let started = DispatchSemaphore(value: 0)
        Thread(block: {
            do { try slow.start() } catch {}
            started.signal()
        }).start()
        Thread.sleep(forTimeInterval: 0.05)
        let stopped = DispatchSemaphore(value: 0)
        slow.stop { stopped.signal() }
        expect(
            &failures,
            stopped.wait(timeout: .now() + 5) == .success,
            "stop during start must complete after the bootstrap finishes"
        )
        expect(
            &failures,
            started.wait(timeout: .now() + 5) == .success,
            "concurrent start() must still return"
        )
        expect(
            &failures,
            slow.currentState == .stopped,
            "worker stopped during start must end in .stopped"
        )
        expect(
            &failures,
            order.snapshot == ["disable", "teardown"],
            "stop during start must skip enable and still tear down in order; got \(order.snapshot)"
        )
    }

    do {
        // Repeated stop after a normal start: every completion fires exactly
        // once and enable/disable/teardown run in that order on the worker.
        let order = OrderRecorder()
        let worker = EventTapWorker(
            installer: makeFakeInstallation(order: order),
            eventHandler: { _, _ in nil }
        )
        do {
            try worker.start()
        } catch {
            failures.append("worker start with fake installer must succeed")
            return
        }
        expect(&failures, worker.currentState == .running, "worker must be running after start")

        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        let third = DispatchSemaphore(value: 0)
        worker.stop { first.signal() }
        worker.stop { second.signal() }
        worker.stop { third.signal() }
        expect(&failures, first.wait(timeout: .now() + 5) == .success, "first stop completion must fire")
        expect(&failures, second.wait(timeout: .now() + 5) == .success, "second stop completion must fire")
        expect(&failures, third.wait(timeout: .now() + 5) == .success, "third stop completion must fire")
        expect(&failures, worker.currentState == .stopped, "worker must be stopped")
        expect(
            &failures,
            order.snapshot == ["enable", "disable", "teardown"],
            "worker must enable, disable and tear down in order; got \(order.snapshot)"
        )

        let afterStop = DispatchSemaphore(value: 0)
        worker.stop { afterStop.signal() }
        expect(
            &failures,
            afterStop.wait(timeout: .now() + 2) == .success,
            "stop after exit must invoke its completion immediately"
        )
    }

    do {
        // Stop before start: completion fires immediately, once.
        let fresh = EventTapWorker(
            installer: makeFakeInstallation(order: OrderRecorder()),
            eventHandler: { _, _ in nil }
        )
        let completion = DispatchSemaphore(value: 0)
        fresh.stop { completion.signal() }
        expect(
            &failures,
            completion.wait(timeout: .now() + 2) == .success,
            "stop before start must invoke completion"
        )
    }
}

// MARK: - OrderedMouseGestureMonitor stress

/// ≥10,000 begin/move/end gesture cycles with randomly interleaved cancels
/// (tap-disabled event, Escape key) and runtime generation switches.
///
/// The physical input thread is simulated faster than any real device: every
/// 64 cycles the producer pauses until the consumer has fully drained, which
/// both keeps the bounded mailbox from overflowing under an artificial
/// firehose (real input arrives at most a few hundred events per second) and
/// verifies the consumer actually keeps up.
private func testStressGestureCycles(_ failures: inout [String]) {
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.05,
        mailboxCapacity: 512
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110)),
        let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
        let disabled = CGEvent(source: nil)
    else {
        failures.append("stress test fixtures unavailable")
        return
    }

    let cycles = 12_000
    var pairingFailures = 0
    var generationAdvances = 0
    var randomState: UInt64 = 0x9E3779B97F4A7C15
    for cycle in 0..<cycles {
        if cycle % 64 == 0 { monitor.admission.recordHeartbeat() }
        let claimedDown = monitor.processEventForTesting(type: .leftMouseDown, event: down)
        _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
        _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
        switch nextRandom(&randomState) % 100 {
        case ..<5:
            monitor.admission.advanceGeneration()
            generationAdvances += 1
        case 5..<10:
            _ = monitor.processEventForTesting(type: .tapDisabledByTimeout, event: disabled)
        case 10..<13:
            _ = monitor.processEventForTesting(type: .keyDown, event: escape)
        default:
            break
        }
        let claimedUp = monitor.processEventForTesting(type: .leftMouseUp, event: up)
        if claimedDown != claimedUp { pairingFailures += 1 }
        if cycle % 64 == 63 {
            let drained = waitUntil(timeout: 10) {
                monitor.mailboxStatistics.pendingCount == 0
            }
            if !drained {
                failures.append("stress consumer fell behind at cycle \(cycle) (pending \(monitor.mailboxStatistics.pendingCount))")
                break
            }
        }
    }

    expect(
        &failures,
        drainMonitor(monitor, timeout: 10),
        "stress monitor stop must drain"
    )
    expect(
        &failures,
        pairingFailures == 0,
        "\(pairingFailures)/\(cycles) cycles broke mouse down/up pairing"
    )

    let messages = recorder.snapshot
    let invariants = GestureDeliveryInvariants(messages: messages)
    expect(
        &failures,
        invariants.sequenceInversions == 0,
        "delivered sequences must be strictly increasing (\(invariants.sequenceInversions) inversions)"
    )
    expect(
        &failures,
        invariants.gesturesWithMultipleTerminals == 0,
        "each accepted gesture must have at most one terminal (\(invariants.gesturesWithMultipleTerminals) violations)"
    )
    expect(
        &failures,
        invariants.gesturesWithMultipleBegins == 0,
        "each accepted gesture must have at most one begin (\(invariants.gesturesWithMultipleBegins) violations)"
    )
    let missingTerminals = invariants.begunGestures - invariants.gesturesWithTerminal
    expect(
        &failures,
        missingTerminals <= generationAdvances,
        "only generation-advanced gestures may lack a terminal (missing \(missingTerminals), advances \(generationAdvances))"
    )
    expect(
        &failures,
        messages.count >= cycles * 2,
        "stress run must actually flow begin/end traffic (\(messages.count) messages for \(cycles) cycles)"
    )
    let stats = monitor.deliveryStatistics
    expect(
        &failures,
        stats.delivered >= UInt64(cycles) * 2,
        "consumer must deliver the bulk of the stress traffic (delivered \(stats.delivered))"
    )
}

/// ≥100,000 move emissions against a deliberately slow consumer: adjacent
/// moves coalesce, the mailbox stays bounded and the single terminal still
/// arrives in order.
private func testSlowConsumerMoveFlood(_ failures: inout [String]) {
    let recorder = DeliveryRecorder(microsecondsPerMessage: 2_000)
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 16
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("flood test fixtures unavailable")
        return
    }

    monitor.admission.recordHeartbeat()
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseDown, event: down),
        "flood gesture down must be claimed"
    )
    var maxPending = 0
    for index in 0..<100_000 {
        _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
        if index % 2048 == 0 {
            monitor.admission.recordHeartbeat()
            maxPending = max(maxPending, monitor.mailboxStatistics.pendingCount)
        }
    }
    let statsBeforeStop = monitor.mailboxStatistics
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseUp, event: up),
        "flood gesture up must be claimed (paired)"
    )
    expect(
        &failures,
        drainMonitor(monitor, timeout: 15),
        "flood monitor stop must drain"
    )

    expect(
        &failures,
        maxPending <= 17,
        "monitor mailbox pending (\(maxPending)) must stay within capacity+1 during move flood"
    )
    expect(
        &failures,
        statsBeforeStop.pendingCount <= 17,
        "monitor mailbox pending (\(statsBeforeStop.pendingCount)) must stay bounded"
    )
    expect(
        &failures,
        statsBeforeStop.coalescedMoves >= 90_000,
        "adjacent moves must coalesce under slow-consumer flood (coalesced \(statsBeforeStop.coalescedMoves))"
    )
    expect(
        &failures,
        statsBeforeStop.overflowCount == 0,
        "move-only flood must never overflow the mailbox"
    )

    let messages = recorder.snapshot
    let invariants = GestureDeliveryInvariants(messages: messages)
    expect(
        &failures,
        invariants.sequenceInversions == 0,
        "delivered sequences must stay strictly increasing during flood"
    )
    expect(
        &failures,
        invariants.gesturesWithMultipleTerminals == 0,
        "flood gesture must terminate exactly once"
    )
    expect(
        &failures,
        invariants.begunGestures == 1 && invariants.gesturesWithTerminal == 1,
        "flood must consist of exactly one gesture with one terminal"
    )
    var sawEnd = false
    for message in messages {
        if case .end = message.kind { sawEnd = true }
    }
    expect(&failures, sawEnd, "flood gesture end must be delivered despite the slow consumer")
}

/// Terminal backlog against a slow consumer: the mailbox reports overflow,
/// admission latches closed, the revoked gesture terminates through the
/// reserved slot, pairing still holds and admission recovers only after the
/// explicit unlatch.
private func testOverflowLatchesAdmission(_ failures: inout [String]) {
    let recorder = DeliveryRecorder(microsecondsPerMessage: 3_000)
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 8
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("overflow test fixtures unavailable")
        return
    }

    var pairingFailures = 0
    var latchedDowns = 0
    var maxPending = 0
    for _ in 0..<40 {
        monitor.admission.recordHeartbeat()
        let claimedDown = monitor.processEventForTesting(type: .leftMouseDown, event: down)
        _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
        let claimedUp = monitor.processEventForTesting(type: .leftMouseUp, event: up)
        if claimedDown != claimedUp { pairingFailures += 1 }
        if !claimedDown { latchedDowns += 1 }
        maxPending = max(maxPending, monitor.mailboxStatistics.pendingCount)
    }

    expect(
        &failures,
        pairingFailures == 0,
        "down/up pairing must hold through the overflow episode"
    )
    expect(
        &failures,
        monitor.admission.overflowLatched,
        "mailbox overflow must latch admission closed"
    )
    expect(
        &failures,
        latchedDowns >= 1,
        "overflow-latched admission must reject new downs"
    )
    expect(
        &failures,
        maxPending <= 9,
        "mailbox pending (\(maxPending)) must stay within capacity+1 through the overflow episode"
    )

    let stats = monitor.mailboxStatistics
    expect(
        &failures,
        stats.overflowCount >= 1,
        "overflow must be reported in statistics"
    )
    expect(
        &failures,
        stats.reservedEnqueued >= 1,
        "revoked gesture must terminate through the reserved terminal slot"
    )

    // Admission recovers only after the explicit unlatch, and only once the
    // backlog has actually drained.
    _ = waitUntil(timeout: 10) { monitor.mailboxStatistics.pendingCount == 0 }
    monitor.admission.clearOverflowLatch()
    monitor.admission.recordHeartbeat()
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseDown, event: down),
        "admission must accept new gestures after explicit recovery"
    )
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseUp, event: up),
        "recovered gesture up must stay paired"
    )

    expect(
        &failures,
        drainMonitor(monitor, timeout: 15),
        "overflow monitor stop must drain"
    )
    let invariants = GestureDeliveryInvariants(messages: recorder.snapshot)
    expect(
        &failures,
        invariants.gesturesWithMultipleTerminals == 0,
        "each accepted gesture must have at most one terminal through the overflow episode"
    )
    expect(
        &failures,
        invariants.sequenceInversions == 0,
        "delivered sequences must stay strictly increasing through the overflow episode"
    )
}

/// A stale admission heartbeat must (a) make the watchdog cancel the active
/// gesture and (b) reject new gestures until refreshed.
private func testAdmissionExpiry(_ failures: inout [String]) {
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 0.3,
        heartbeatWatchdogInterval: 0.05,
        mailboxCapacity: 32
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("expiry test fixtures unavailable")
        return
    }

    monitor.admission.recordHeartbeat()
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseDown, event: down),
        "fresh heartbeat must admit a new gesture"
    )
    monitor.admission.update { $0.lastHeartbeatSeconds = monotonicTimestampSeconds() - 10 }
    expect(
        &failures,
        waitUntil(timeout: 2) {
            recorder.snapshot.contains { message in
                if case .cancel = message.kind { return true }
                return false
            }
        },
        "watchdog must cancel the active gesture after heartbeat expiry"
    )
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseUp, event: up),
        "late up after watchdog cancellation must still be swallowed"
    )
    expect(
        &failures,
        !monitor.processEventForTesting(type: .leftMouseDown, event: down),
        "expired heartbeat must reject new gestures"
    )
    monitor.admission.recordHeartbeat()
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseDown, event: down),
        "refreshed heartbeat must admit new gestures again"
    )
    expect(
        &failures,
        drainMonitor(monitor, timeout: 10),
        "expiry monitor stop must drain"
    )
}

/// A mouse-up that arrives after the gesture was canceled (but whose down was
/// swallowed) must be consumed, never forwarded to the target application.
private func testLateUpAfterCancel(_ failures: inout [String]) {
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 32
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("late-up test fixtures unavailable")
        return
    }

    monitor.admission.recordHeartbeat()
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseDown, event: down),
        "down must be claimed before cancellation"
    )
    _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
    monitor.setEnabled(false)
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseUp, event: up),
        "late up after cancel must be swallowed to avoid an orphan release"
    )
    monitor.setEnabled(true)
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseDown, event: down),
        "monitor must accept a new gesture after re-enabling"
    )
    _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseUp, event: up),
        "second gesture up must be claimed"
    )
    expect(
        &failures,
        drainMonitor(monitor, timeout: 10),
        "late-up monitor stop must drain"
    )
    let messages = recorder.snapshot
    let invariants = GestureDeliveryInvariants(messages: messages)
    expect(
        &failures,
        invariants.begunGestures == 2 && invariants.gesturesWithTerminal == 2,
        "both gestures must begin and terminate exactly once"
    )
    var cancelCount = 0
    var endCount = 0
    for message in messages {
        switch message.kind {
        case .cancel: cancelCount += 1
        case .end: endCount += 1
        default: break
        }
    }
    expect(&failures, cancelCount == 1, "canceled gesture must deliver exactly one cancel")
    expect(&failures, endCount == 1, "completed gesture must deliver exactly one end")
}

/// Messages emitted after the runtime generation advanced must produce no
/// app-visible terminal action: the consumer drops them and counts them as
/// stale. (A begin emitted while the generation was still current may have
/// been delivered before the switch — that delivery was legitimate at the
/// time, so only post-switch emissions are asserted here.)
private func testOldGenerationDropped(_ failures: inout [String]) {
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 32
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("old-generation test fixtures unavailable")
        return
    }

    monitor.admission.recordHeartbeat()
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseDown, event: down),
        "down must be claimed before the generation switch"
    )
    _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
    monitor.admission.advanceGeneration()
    // The next tap event first cancels the stale-generation gesture (that
    // cancel carries the old generation and must be dropped by the consumer),
    // then finds no active gesture and passes the drag through.
    _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseUp, event: up),
        "late up after generation switch must still be swallowed"
    )
    expect(
        &failures,
        drainMonitor(monitor, timeout: 10),
        "old-generation monitor stop must drain"
    )
    let staleTerminals = recorder.snapshot.filter { message in
        message.gestureID != 0 && message.isTerminal
    }
    expect(
        &failures,
        staleTerminals.isEmpty,
        "old-generation gesture must never deliver a terminal to the app (got \(staleTerminals.count))"
    )
    let stats = monitor.deliveryStatistics
    expect(
        &failures,
        stats.staleDropped >= 1,
        "old-generation cancel must be counted as stale (dropped \(stats.staleDropped))"
    )

    // A gesture started under the new generation behaves normally.
    let freshRecorder = DeliveryRecorder()
    let freshMonitor = makeFakeMonitor(
        recorder: freshRecorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 32
    )
    freshMonitor.admission.recordHeartbeat()
    expect(
        &failures,
        freshMonitor.processEventForTesting(type: .leftMouseDown, event: down),
        "new-generation gesture must be admitted"
    )
    _ = freshMonitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
    expect(
        &failures,
        freshMonitor.processEventForTesting(type: .leftMouseUp, event: up),
        "new-generation gesture up must be claimed"
    )
    expect(
        &failures,
        drainMonitor(freshMonitor, timeout: 10),
        "new-generation monitor stop must drain"
    )
    let freshInvariants = GestureDeliveryInvariants(messages: freshRecorder.snapshot)
    expect(
        &failures,
        freshInvariants.begunGestures == 1 && freshInvariants.gesturesWithTerminal == 1,
        "new-generation gesture must begin and terminate exactly once"
    )
}

/// Repeated monitor stops: every completion fires exactly once, and the final
/// drain delivers every queued terminal before the first completion.
private func testMonitorRepeatedStop(_ failures: inout [String]) {
    let recorder = DeliveryRecorder()
    let monitor = makeFakeMonitor(
        recorder: recorder,
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 8
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("stop test fixtures unavailable")
        return
    }

    monitor.admission.recordHeartbeat()
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseDown, event: down),
        "stop test gesture down must be claimed"
    )
    _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
    expect(
        &failures,
        monitor.processEventForTesting(type: .leftMouseUp, event: up),
        "stop test gesture up must be claimed"
    )

    let first = DispatchSemaphore(value: 0)
    let second = DispatchSemaphore(value: 0)
    let third = DispatchSemaphore(value: 0)
    monitor.stop { first.signal() }
    monitor.stop { second.signal() }
    monitor.stop { third.signal() }
    expect(&failures, first.wait(timeout: .now() + 5) == .success, "first monitor stop completion must fire")
    expect(&failures, second.wait(timeout: .now() + 5) == .success, "second monitor stop completion must fire")
    expect(&failures, third.wait(timeout: .now() + 5) == .success, "third monitor stop completion must fire")

    var sawBegin = false
    var sawEnd = false
    for message in recorder.snapshot {
        switch message.kind {
        case .begin: sawBegin = true
        case .end: sawEnd = true
        default: break
        }
    }
    expect(&failures, sawBegin, "queued begin must be delivered before stop completion")
    expect(&failures, sawEnd, "queued terminal must be delivered before stop completion")

    let afterStop = DispatchSemaphore(value: 0)
    monitor.stop { afterStop.signal() }
    expect(
        &failures,
        afterStop.wait(timeout: .now() + 5) == .success,
        "monitor stop after being stopped must invoke its completion"
    )
}

/// Sanity wiring through the real `MultitouchDriver` consume path using the
/// in-memory test injection (a handful of cycles only: the shim's injected
/// device list is process-global and bounded).
private func testRealDriverWiring(_ failures: inout [String]) {
    let driver = MultitouchDriver()
    let recorder = DeliveryRecorder()
    let monitor = OrderedMouseGestureMonitor(
        driver: driver,
        configuration: GestureConfiguration(),
        eventHandler: { recorder.append($0) },
        heartbeatTolerance: 60,
        heartbeatWatchdogInterval: 0.5,
        mailboxCapacity: 32
    )
    guard
        let down = makeMouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)),
        let dragged = makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 105)),
        let up = makeMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110))
    else {
        failures.append("real-driver test fixtures unavailable")
        return
    }

    monitor.admission.recordHeartbeat()
    let cycles = 3
    for cycle in 0..<cycles {
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01)
        let claimedDown = monitor.processEventForTesting(type: .leftMouseDown, event: down)
        _ = monitor.processEventForTesting(type: .leftMouseDragged, event: dragged)
        let claimedUp = monitor.processEventForTesting(type: .leftMouseUp, event: up)
        expect(
            &failures,
            claimedDown && claimedUp,
            "real driver cycle \(cycle) must stay paired"
        )
    }
    expect(
        &failures,
        drainMonitor(monitor, timeout: 10),
        "real-driver monitor stop must drain"
    )
    let messages = recorder.snapshot
    let invariants = GestureDeliveryInvariants(messages: messages)
    expect(
        &failures,
        invariants.begunGestures == cycles,
        "every real-driver cycle must begin a gesture (got \(invariants.begunGestures))"
    )
    expect(
        &failures,
        invariants.gesturesWithTerminal == cycles,
        "every real-driver gesture must terminate exactly once"
    )
    expect(
        &failures,
        invariants.sequenceInversions == 0,
        "real-driver deliveries must be strictly ordered"
    )
}
