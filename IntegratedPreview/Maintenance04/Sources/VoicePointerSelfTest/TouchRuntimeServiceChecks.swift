import Foundation
@_spi(Testing) import VoicePointerCore

/// VP-B deterministic checks for TouchRuntimeService.
///
/// The tests drive the real service state machine; the fake backend only
/// simulates the hardware boundary (blocking calls, call counting, fabricated
/// device payloads) and the fake quiesce host simulates the App-side
/// handshake. No real driver lifecycle function, device, permission, or IOKit
/// query is touched. All timing is deterministic: an injected monotonic clock
/// plus a manual scheduler that fires deadline callbacks exactly when the
/// test says — no sleeps, no enlarged budgets.
enum TouchRuntimeServiceChecks {
    static func runAll() async -> [String] {
        var failures: [String] = []
        await checkNonBlockingRequestsWhileBackendBlocked(&failures)
        await checkSerializationIdempotenceAndMerging(&failures)
        await checkQuiesceGate(&failures)
        await checkLifecycleSequences(&failures)
        await checkTimeoutsAndCleanup(&failures)
        await checkSnapshotCacheAndLateResults(&failures)
        await checkCompletionContracts(&failures)
        await checkQueuedStartTotalDeadline(&failures)
        await checkServiceThreadLifecycle(&failures)
        await checkAtomicStateCommits(&failures)
        await checkHandshakeTaskBounding(&failures)
        return failures
    }

    private static func expect(
        _ failures: inout [String],
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { failures.append(message) }
    }

    /// Polls with cooperative yields only — no real time dependence.
    private static func waitUntil(_ condition: @escaping () -> Bool, maxSpins: Int = 200_000) async -> Bool {
        var spins = 0
        while !condition() {
            if spins >= maxSpins { return condition() }
            await Task.yield()
            spins += 1
        }
        return true
    }

    /// Bounded real-time poll for thread-exit facts, which depend on the
    /// worker's real idle wait rather than injected clocks.
    private static func pollUntilRealtime(_ condition: @escaping () -> Bool, polls: Int = 150, stepMs: UInt64 = 20) async -> Bool {
        var remaining = polls
        while !condition() {
            if remaining <= 0 { return condition() }
            try? await Task.sleep(for: .milliseconds(stepMs))
            remaining -= 1
        }
        return true
    }

    // MARK: - Fixtures

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var isMarked = false
        func mark() { lock.lock(); isMarked = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return isMarked }
    }

    /// Collects exactly-once completion outcomes.
    private final class OutcomeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [TouchLifecycleOutcome] = []
        func append(_ outcome: TouchLifecycleOutcome) {
            lock.lock(); outcomes.append(outcome); lock.unlock()
        }
        var snapshot: [TouchLifecycleOutcome] {
            lock.lock(); defer { lock.unlock() }; return outcomes
        }
        func count(_ target: TouchLifecycleOutcome) -> Int {
            snapshot.filter { $0 == target }.count
        }
    }

    /// Hardware boundary fake: counts calls, enforces the single-thread /
    /// max-concurrency-1 contract, and can block the NEXT call of one op on a
    /// barrier that the test releases deterministically.
    private final class FakeTouchBackend: TouchDriverBackend, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var startCalls = 0
        private(set) var stopCalls = 0
        private(set) var reloadCalls = 0
        private(set) var statusCalls = 0
        private(set) var devicesCalls = 0
        private(set) var serviceCountCalls = 0
        private(set) var maxInFlight = 0
        private(set) var distinctThreads: Set<ObjectIdentifier> = []
        private var inFlight = 0
        private var barriers: [String: DispatchSemaphore] = [:]
        private var devicesValue: [TouchDeviceInfo] = []
        private var statusValue = "fake driver has not started"
        private var serviceCountValue = -1

        /// Arms a one-shot barrier: the next call of `key` blocks until
        /// releaseBarrier.
        func armBarrier(_ key: String) {
            lock.lock(); barriers[key] = DispatchSemaphore(value: 0); lock.unlock()
        }

        func releaseBarrier(_ key: String) {
            lock.lock()
            let semaphore = barriers[key]
            barriers[key] = nil
            lock.unlock()
            semaphore?.signal()
        }

        func setDevices(_ devices: [TouchDeviceInfo]) {
            lock.lock(); devicesValue = devices; lock.unlock()
        }

        func setStatus(_ status: String) {
            lock.lock(); statusValue = status; lock.unlock()
        }

        func setServiceCount(_ count: Int) {
            lock.lock(); serviceCountValue = count; lock.unlock()
        }

        private func enter() {
            lock.lock()
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            distinctThreads.insert(ObjectIdentifier(Thread.current))
            lock.unlock()
        }

        private func exit() {
            lock.lock(); inFlight -= 1; lock.unlock()
        }

        private func gate(_ key: String) {
            lock.lock(); let semaphore = barriers[key]; lock.unlock()
            semaphore?.wait()
        }

        func start() -> Bool {
            enter(); defer { exit() }
            lock.lock(); startCalls += 1; lock.unlock()
            gate("start")
            return true
        }

        func stop() {
            enter(); defer { exit() }
            lock.lock(); stopCalls += 1; lock.unlock()
            gate("stop")
        }

        func reload() -> Bool {
            enter(); defer { exit() }
            lock.lock(); reloadCalls += 1; lock.unlock()
            gate("reload")
            return true
        }

        func status() -> String {
            enter(); defer { exit() }
            lock.lock(); statusCalls += 1; lock.unlock()
            gate("snapshot")
            return statusValue
        }

        func devices() -> [TouchDeviceInfo] {
            enter(); defer { exit() }
            lock.lock(); devicesCalls += 1; lock.unlock()
            gate("snapshot")
            return devicesValue
        }

        func connectedServiceCount() -> Int {
            enter(); defer { exit() }
            lock.lock(); serviceCountCalls += 1; lock.unlock()
            gate("snapshot")
            return serviceCountValue
        }
    }

    /// App-side quiesce fake. `holdRequests()` suspends handshakes until the
    /// test confirms; `setAutoAnswer` answers future handshakes immediately.
    private final class FakeQuiesceHost: TouchQuiesceCoordinating, @unchecked Sendable {
        private let lock = NSLock()
        private var requestCountStorage = 0
        private var generationsStorage: [UInt64] = []
        private var pending: [(generation: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
        private var autoAnswer: Bool?
        private var cancelAware = true
        private var cancelledGenerations: Set<UInt64> = []

        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requestCountStorage }
        var generations: [UInt64] { lock.lock(); defer { lock.unlock() }; return generationsStorage }

        var onQuiesce: (@Sendable () -> Void)?

        /// Number of handshakes currently suspended in this host.
        var pendingCount: Int {
            lock.lock(); defer { lock.unlock() }; return pending.count
        }

        func setCancelAware(_ value: Bool) {
            lock.lock(); cancelAware = value; lock.unlock()
        }

        func holdRequests() {
            lock.lock(); autoAnswer = nil; lock.unlock()
        }

        func setAutoAnswer(_ value: Bool) {
            lock.lock(); autoAnswer = value; lock.unlock()
        }

        /// Resumes every suspended handshake with `result`.
        func confirmAll(_ result: Bool) {
            lock.lock()
            let suspended = pending
            pending = []
            lock.unlock()
            for entry in suspended { entry.continuation.resume(returning: result) }
        }

        /// Resumes only the handshake asked for `generation`.
        func confirmGeneration(_ generation: UInt64, _ result: Bool) {
            lock.lock()
            var resumed: [CheckedContinuation<Bool, Never>] = []
            pending = pending.filter { entry in
                if entry.generation == generation {
                    resumed.append(entry.continuation)
                    return false
                }
                return true
            }
            lock.unlock()
            for continuation in resumed { continuation.resume(returning: result) }
        }

        func quiesce(generation: UInt64) async -> Bool {
            let immediate = recordRequest(generation: generation)
            onQuiesce?()
            if let immediate { return immediate }
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if let immediate = suspendOrAnswer(generation: generation, continuation) {
                        continuation.resume(returning: immediate)
                    }
                }
            }, onCancel: {
                cancelGeneration(generation)
            })
        }

        /// Sync helpers so the async entry point never locks directly.
        private func recordRequest(generation: UInt64) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            requestCountStorage += 1
            generationsStorage.append(generation)
            return autoAnswer
        }

        /// Returns the immediate answer, or nil after parking the continuation.
        private func suspendOrAnswer(
            generation: UInt64,
            _ continuation: CheckedContinuation<Bool, Never>
        ) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            if cancelAware && cancelledGenerations.remove(generation) != nil { return false }
            if let immediate = autoAnswer { return immediate }
            pending.append((generation, continuation))
            return nil
        }

        /// A cancelled handshake answers false so its continuation cannot
        /// leak; a non-cooperative host (cancelAware == false) leaves it
        /// suspended, which is the case the service's hard cap must defend.
        private func cancelGeneration(_ generation: UInt64) {
            lock.lock()
            guard cancelAware else { lock.unlock(); return }
            cancelledGenerations.insert(generation)
            var suspended: [CheckedContinuation<Bool, Never>] = []
            pending = pending.filter { entry in
                if entry.generation == generation { suspended.append(entry.continuation); return false }
                return true
            }
            lock.unlock()
            for continuation in suspended { continuation.resume(returning: false) }
        }
    }

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var nowNs: UInt64
        init(startNs: UInt64 = 1_000_000_000) { nowNs = startNs }
        var now: UInt64 { lock.lock(); defer { lock.unlock() }; return nowNs }
        func advance(_ ns: UInt64) { lock.lock(); nowNs += ns; lock.unlock() }
        var reader: @Sendable () -> UInt64 { { self.now } }
    }

    /// Fires deadline callbacks only when the test advances the clock — the
    /// service's budget logic is exercised without any real waiting.
    private final class ManualTimeoutScheduler: TouchTimeoutScheduling, @unchecked Sendable {
        private let lock = NSLock()
        private var timers: [(deadline: UInt64, body: @Sendable () -> Void)] = []

        func schedule(deadlineNs: UInt64, _ body: @escaping @Sendable () -> Void) {
            lock.lock(); timers.append((deadlineNs, body)); lock.unlock()
        }

        @discardableResult
        func fireDue(now: UInt64) -> Int {
            lock.lock()
            let due = timers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            timers.removeAll { $0.deadline <= now }
            lock.unlock()
            for timer in due { timer.body() }
            return due.count
        }

        var pendingCount: Int {
            lock.lock(); defer { lock.unlock() }; return timers.count
        }
    }

    private struct Fixture {
        let service: TouchRuntimeService
        let backend: FakeTouchBackend
        let host: FakeQuiesceHost
        let clock: ManualClock
        let scheduler: ManualTimeoutScheduler
    }

    private static func makeFixture(
        configuration: TouchRuntimeService.Configuration = TouchRuntimeService.Configuration(
            mutationBudgetNs: 500_000_000,
            quiesceBudgetNs: 200_000_000,
            requestBudgetSlackNs: 50_000_000
        ),
        autoConfirmQuiesce: Bool = true,
        backendOverride: FakeTouchBackend? = nil
    ) -> Fixture {
        let backend = backendOverride ?? FakeTouchBackend()
        let host = FakeQuiesceHost()
        if autoConfirmQuiesce { host.setAutoAnswer(true) }
        let clock = ManualClock()
        let scheduler = ManualTimeoutScheduler()
        let service = TouchRuntimeService(
            backend: backend,
            quiesce: host,
            scheduler: scheduler,
            clock: clock.reader,
            configuration: configuration
        )
        return Fixture(service: service, backend: backend, host: host, clock: clock, scheduler: scheduler)
    }

    // TouchDeviceInfo's memberwise initializer is internal to VoicePointerCore
    // and MultitouchDriver.swift is read-only this round, so the fake's
    // observable payload discriminators are the status string and the sampled
    // monotonic timestamp instead of device arrays.

    /// Fires the mutation deadline of an in-flight device call. The request
    /// budget (quiesce + mutation + slack) stays pending at this point.
    private static func fireMutationDeadline(_ fixture: Fixture) {
        fixture.clock.advance(600_000_000)
        fixture.scheduler.fireDue(now: fixture.clock.now)
    }

    // MARK: - 1. Blocked backend never blocks requests, reads, or MainActor

    private static func checkNonBlockingRequestsWhileBackendBlocked(_ failures: inout [String]) async {
        let fixture = makeFixture()
        fixture.backend.armBarrier("start")
        fixture.backend.armBarrier("snapshot")
        fixture.host.setAutoAnswer(true)

        let startOutcomes = OutcomeCollector()
        fixture.service.requestStart { startOutcomes.append($0) }
        expect(&failures, startOutcomes.snapshot.isEmpty, "a blocked start must not complete synchronously")
        _ = await waitUntil { fixture.backend.startCalls == 1 }

        let starting = fixture.service.stateSnapshot
        expect(&failures, starting.lifecycleState == .starting && starting.generation == 1,
               "a blocked start must publish .starting for generation 1, got \(starting)")

        fixture.service.requestSnapshotRefresh()
        let cachedRead = fixture.service.stateSnapshot
        expect(&failures, cachedRead.lifecycleState == .starting,
               "snapshot reads must return the cache instantly while sampling is blocked")
        expect(&failures, fixture.backend.devicesCalls == 0,
               "cache reads must not trigger backend sampling")

        // The MainActor must keep executing while the device worker is stuck.
        let mainActorRan = LockedFlag()
        Task { @MainActor in mainActorRan.mark() }
        let ran = await pollUntilRealtime { mainActorRan.isSet }
        expect(&failures, ran, "MainActor must keep running while the device worker is blocked")

        // A stop supersedes the stuck start before the barrier is released.
        let stopOutcomes = OutcomeCollector()
        fixture.service.requestStop { stopOutcomes.append($0) }
        expect(&failures, startOutcomes.snapshot == [.superseded],
               "the superseded start must resolve exactly once with .superseded")
        expect(&failures, stopOutcomes.snapshot.isEmpty,
               "the stop must stay unresolved while the worker is stuck")
        let stopping = fixture.service.stateSnapshot
        expect(&failures, stopping.lifecycleState == .stopping && stopping.generation == 2,
               "stop must publish .stopping for generation 2 from the caller thread")

        // Release the stuck start: the late success runs a compensating stop
        // ahead of the queued snapshot sample and the stop intent.
        fixture.backend.releaseBarrier("start")
        fixture.backend.releaseBarrier("snapshot")
        let stopped = await waitUntil { stopOutcomes.snapshot == [.stopped] }
        expect(&failures, stopped, "the stop intent must complete after the stuck start returns")
        expect(&failures, fixture.backend.startCalls == 1 && fixture.backend.reloadCalls == 0,
               "superseded work must not duplicate device calls")
        expect(&failures, fixture.backend.stopCalls == 2,
               "a late start success must run exactly one compensating stop before the stop intent, got \(fixture.backend.stopCalls)")
        expect(&failures, fixture.backend.maxInFlight == 1,
               "backend calls must never overlap")
        expect(&failures, fixture.backend.distinctThreads.count == 1,
               "all backend calls must run on the one dedicated worker thread")
        let drained = fixture.service.stateSnapshot
        expect(&failures, drained.lifecycleState == .idle,
               "the service must end idle after the stop completes")
    }

    // MARK: - 2. One worker thread, concurrency 1, idempotence, reload merging

    private static func checkSerializationIdempotenceAndMerging(_ failures: inout [String]) async {
        let fixture = makeFixture()

        for _ in 0..<5 { fixture.service.requestStart { _ in } }
        let startsRunning = await waitUntil { fixture.service.stateSnapshot.lifecycleState == .running }
        expect(&failures, startsRunning, "the start flood must leave the devices running")
        expect(&failures, fixture.backend.startCalls == 1,
               "repeated start must be idempotent (1 device call), got \(fixture.backend.startCalls)")
        expect(&failures, fixture.service.stateSnapshot.generation == 1,
               "idempotent and merged starts must not churn generations, got \(fixture.service.stateSnapshot.generation)")

        for _ in 0..<5 { fixture.service.requestStop { _ in } }
        let stopsIdle = await waitUntil { fixture.service.stateSnapshot.lifecycleState == .idle }
        expect(&failures, stopsIdle, "the stop flood must leave the devices idle")
        expect(&failures, fixture.backend.stopCalls == 1,
               "repeated stop must be idempotent (1 device call), got \(fixture.backend.stopCalls)")
        expect(&failures, fixture.service.stateSnapshot.generation == 2,
               "stop must advance the generation exactly once, got \(fixture.service.stateSnapshot.generation)")

        // Reload flood: hold the handshake so every request sees the same
        // pending intent; waiters are bounded and the excess is rejected
        // explicitly instead of accumulating closures.
        fixture.host.holdRequests()
        var reloadOutcomes: [OutcomeCollector] = []
        for _ in 0..<100 {
            let collector = OutcomeCollector()
            reloadOutcomes.append(collector)
            fixture.service.requestReload { collector.append($0) }
        }
        let resolved = await waitUntil {
            reloadOutcomes.dropFirst(16).allSatisfy { $0.snapshot.count == 1 }
        }
        expect(&failures, resolved, "waiters beyond the limit must be rejected explicitly")
        expect(&failures, fixture.backend.reloadCalls == 0,
               "no device call may happen before the quiesce confirm")

        fixture.host.setAutoAnswer(true)
        fixture.host.confirmAll(true)
        let floodSettled = await pollUntilRealtime {
            reloadOutcomes.allSatisfy { $0.snapshot.count == 1 }
        }
        expect(&failures, floodSettled, "every flood request must resolve exactly once")
        let reloadedCount = reloadOutcomes.map { $0.count(.reloaded) }.reduce(0, +)
        let rejectedCount = reloadOutcomes.map { $0.count(.rejected(.waiterLimitReached)) }.reduce(0, +)
        expect(&failures, reloadedCount == 16,
               "at most waiterLimit merged reloads must resolve with .reloaded, got \(reloadedCount), gen=\(fixture.service.stateSnapshot.generation) stopCalls=\(fixture.backend.stopCalls) reloadCalls=\(fixture.backend.reloadCalls)")
        expect(&failures, rejectedCount == 84,
               "waiters beyond the limit must be rejected with .waiterLimitReached, got \(rejectedCount)")
        expect(&failures, fixture.backend.reloadCalls == 1,
               "a reload flood must merge into exactly one device call, got \(fixture.backend.reloadCalls)")
        expect(&failures, fixture.service.stateSnapshot.generation == 3,
               "merged reloads must not advance the generation further, got \(fixture.service.stateSnapshot.generation)")
        expect(&failures, fixture.backend.maxInFlight == 1 && fixture.backend.distinctThreads.count == 1,
               "all backend calls must stay serialized on the one worker thread")
    }

    // MARK: - 3. Quiesce gate, budget timeout, stale confirmations, reentrancy

    private static func checkQuiesceGate(_ failures: inout [String]) async {
        let fixture = makeFixture()
        fixture.service.requestStart { _ in }
        _ = await waitUntil { fixture.service.stateSnapshot.lifecycleState == .running }

        // Handshake held: no device change may happen before the confirm.
        fixture.host.holdRequests()
        let reloadOutcomes = OutcomeCollector()
        fixture.service.requestReload { reloadOutcomes.append($0) }
        // submit() advanced the generation synchronously before returning.
        let reloadGeneration = fixture.service.stateSnapshot.generation
        _ = await pollUntilRealtime { fixture.host.requestCount >= 1 }
        expect(&failures, fixture.host.requestCount == 1 && fixture.host.generations == [reloadGeneration],
               "the handshake must be asked for the current generation")
        expect(&failures, fixture.backend.reloadCalls == 0 && fixture.backend.stopCalls == 0,
               "no device change may happen before the quiesce confirm")

        // Quiesce budget elapses: explicit rejection, prior state restored.
        fixture.clock.advance(300_000_000)
        fixture.scheduler.fireDue(now: fixture.clock.now)
        let rejected = await waitUntil { reloadOutcomes.snapshot == [.rejected(.quiesceUnconfirmed)] }
        expect(&failures, rejected, "a quiesce budget timeout must reject the request explicitly")
        expect(&failures, fixture.service.stateSnapshot.lifecycleState == .failed,
               "a rejected handshake must fail closed instead of claiming the devices' prior state")

        // A confirmation arriving after the rejection is invalid.
        fixture.host.confirmAll(true)
        _ = await pollUntilRealtime { fixture.host.pendingCount == 0 }
        let expiredHandshakeExited = await pollUntilRealtime {
            fixture.service.outstandingHandshakeTaskCount == 0
        }
        expect(&failures, expiredHandshakeExited,
               "the expired handshake must actually leave the service before the next independent scenario")
        expect(&failures, fixture.backend.reloadCalls == 0,
               "a late quiesce confirm must not dispatch the rejected intent")

        // A newer generation invalidates the older handshake's confirm.
        fixture.host.holdRequests()
        let lateReloadOutcomes = OutcomeCollector()
        fixture.service.requestReload { lateReloadOutcomes.append($0) }
        _ = await waitUntil { fixture.host.requestCount == 2 }
        let stopOutcomes = OutcomeCollector()
        fixture.service.requestStop { stopOutcomes.append($0) }
        expect(&failures, lateReloadOutcomes.snapshot == [.superseded],
               "the newer stop must supersede the quiesce-bound reload immediately")
        fixture.host.setAutoAnswer(true)
        fixture.host.confirmAll(true)
        let stopped = await waitUntil { stopOutcomes.snapshot == [.stopped] }
        expect(&failures, stopped, "the stop intent must proceed after its own confirm: outcomes=\(stopOutcomes.snapshot), state=\(fixture.service.stateSnapshot.lifecycleState), gen=\(fixture.service.stateSnapshot.generation), hostGenerations=\(fixture.host.generations), pending=\(fixture.host.pendingCount)")
        expect(&failures, fixture.backend.reloadCalls == 0,
               "the stale generation's confirm must never dispatch the reload")

        // Synchronous reentrancy from the handshake and from completions must
        // not deadlock: the service never holds stateLock across either.
        let reentrantHost = FakeQuiesceHost()
        reentrantHost.setAutoAnswer(true)
        reentrantHost.onQuiesce = { _ = fixture.service.stateSnapshot }
        let reentrantService = TouchRuntimeService(
            backend: fixture.backend,
            quiesce: reentrantHost,
            scheduler: fixture.scheduler,
            clock: fixture.clock.reader
        )
        let reentrantOutcome = OutcomeCollector()
        reentrantService.requestStart { _ in }
        _ = await waitUntil { reentrantService.stateSnapshot.lifecycleState == .running }
        reentrantService.requestStop { outcome in
            _ = reentrantService.stateSnapshot
            reentrantService.requestSnapshotRefresh()
            reentrantOutcome.append(outcome)
        }
        let reentrantStopped = await pollUntilRealtime { reentrantOutcome.snapshot == [.stopped] }
        expect(&failures, reentrantStopped, "synchronous reentrant callbacks must not deadlock")
    }

    // MARK: - 4. Sequences: start→stop, start→reload→stop, reload merging

    private static func checkLifecycleSequences(_ failures: inout [String]) async {
        // start→stop with the start stuck on the hardware boundary.
        let fixture = makeFixture()
        fixture.backend.armBarrier("start")
        let startOutcomes = OutcomeCollector()
        fixture.service.requestStart { startOutcomes.append($0) }
        _ = await waitUntil { fixture.backend.startCalls == 1 }
        let stopOutcomes = OutcomeCollector()
        fixture.service.requestStop { stopOutcomes.append($0) }
        expect(&failures, startOutcomes.snapshot == [.superseded],
               "stop must supersede the in-flight start immediately")
        fixture.backend.releaseBarrier("start")
        let stopped = await waitUntil { stopOutcomes.snapshot == [.stopped] }
        expect(&failures, stopped, "start→stop must end with a fulfilled stop")
        expect(&failures, fixture.backend.startCalls == 1 && fixture.backend.stopCalls == 2,
               "expected [start, compensating stop, stop intent], got start=\(fixture.backend.startCalls) stop=\(fixture.backend.stopCalls)")
        expect(&failures, fixture.service.stateSnapshot.generation == 2,
               "start→stop must advance the generation to 2, got \(fixture.service.stateSnapshot.generation)")

        // start→reload→stop: the superseded reload must not run at all.
        let sequence = makeFixture()
        sequence.backend.armBarrier("start")
        let seqStart = OutcomeCollector()
        sequence.service.requestStart { seqStart.append($0) }
        _ = await waitUntil { sequence.backend.startCalls == 1 }
        let seqReload = OutcomeCollector()
        sequence.service.requestReload { seqReload.append($0) }
        let seqStop = OutcomeCollector()
        sequence.service.requestStop { seqStop.append($0) }
        expect(&failures, seqReload.snapshot == [.superseded],
               "stop must supersede the quiesce-bound reload immediately")
        sequence.backend.releaseBarrier("start")
        let seqStopped = await waitUntil { seqStop.snapshot == [.stopped] }
        expect(&failures, seqStopped, "start→reload→stop must end with a fulfilled stop")
        expect(&failures, seqStart.snapshot == [.superseded] && seqReload.snapshot == [.superseded],
               "both earlier intents must resolve exactly once as superseded")
        expect(&failures, sequence.backend.reloadCalls == 0,
               "a superseded reload must never reach the backend")
        expect(&failures, sequence.backend.startCalls == 1 && sequence.backend.stopCalls == 2,
               "expected [start, compensating stop, stop], got start=\(sequence.backend.startCalls) stop=\(sequence.backend.stopCalls)")
        expect(&failures, sequence.service.stateSnapshot.generation == 3,
               "start→reload→stop must advance the generation to 3, got \(sequence.service.stateSnapshot.generation)")

        // Reload during an in-flight reload merges into the same intent.
        let merger = makeFixture()
        merger.service.requestStart { _ in }
        _ = await waitUntil { merger.service.stateSnapshot.lifecycleState == .running }
        merger.backend.armBarrier("reload")
        let generationBefore = merger.service.stateSnapshot.generation
        let firstReload = OutcomeCollector()
        merger.service.requestReload { firstReload.append($0) }
        _ = await waitUntil { merger.backend.reloadCalls == 1 }
        let secondReload = OutcomeCollector()
        merger.service.requestReload { secondReload.append($0) }
        expect(&failures, merger.service.stateSnapshot.generation == generationBefore + 1,
               "a merged duplicate reload must not advance the generation")
        merger.backend.releaseBarrier("reload")
        let bothReloaded = await pollUntilRealtime {
            firstReload.snapshot == [.reloaded] && secondReload.snapshot == [.reloaded]
        }
        expect(&failures, bothReloaded, "merged reloads must resolve together exactly once")
        expect(&failures, merger.backend.reloadCalls == 1,
               "duplicate reloads must merge into one device call, got \(merger.backend.reloadCalls)")
    }

    // MARK: - 5. Timeouts: explicit result, no retry, cleanup exactly once

    private static func checkTimeoutsAndCleanup(_ failures: inout [String]) async {
        // Bootstrap start timeout.
        let fixture = makeFixture()
        fixture.backend.armBarrier("start")
        let startOutcomes = OutcomeCollector()
        fixture.service.requestStart { startOutcomes.append($0) }
        _ = await waitUntil { fixture.backend.startCalls == 1 }
        fireMutationDeadline(fixture)
        let timedOut = await waitUntil {
            startOutcomes.snapshot == [.timedOut]
                && fixture.service.stateSnapshot.lifecycleState == .timedOut
        }
        expect(&failures, timedOut, "a blocked start must resolve .timedOut with state .timedOut")
        for _ in 0..<50 { await Task.yield() }
        expect(&failures, fixture.backend.startCalls == 1,
               "a timed-out start must not be retried behind the stuck call")
        expect(&failures, fixture.backend.maxInFlight == 1,
               "the worker must keep owning the blocked call; no parallel retry")

        fixture.backend.releaseBarrier("start")
        let cleaned = await waitUntil { fixture.backend.stopCalls == 1 }
        expect(&failures, cleaned, "the late start success must trigger compensating cleanup")
        let idle = await waitUntil { fixture.service.stateSnapshot.lifecycleState == .idle }
        expect(&failures, idle, "cleanup must reconcile the service to .idle")

        let recovered = OutcomeCollector()
        fixture.service.requestStart { recovered.append($0) }
        let restarted = await waitUntil { recovered.snapshot == [.started] }
        expect(&failures, restarted, "a new explicit request must be able to recover after cleanup")
        expect(&failures, fixture.backend.startCalls == 2,
               "recovery must be a fresh start call, got \(fixture.backend.startCalls)")

        // Stop timeout: the timed-out state must not claim the resource stopped.
        fixture.backend.armBarrier("stop")
        let stopOutcomes = OutcomeCollector()
        fixture.service.requestStop { stopOutcomes.append($0) }
        _ = await waitUntil { fixture.backend.stopCalls == 2 }
        fireMutationDeadline(fixture)
        let stopTimedOut = await waitUntil {
            stopOutcomes.snapshot == [.timedOut]
                && fixture.service.stateSnapshot.lifecycleState == .timedOut
        }
        expect(&failures, stopTimedOut, "a blocked stop must resolve .timedOut without claiming success")
        fixture.backend.releaseBarrier("stop")
        let stopDrained = await waitUntil { fixture.service.stateSnapshot.lifecycleState == .idle }
        expect(&failures, stopDrained, "the late stop success must reconcile to .idle")
        expect(&failures, fixture.backend.stopCalls == 2,
               "a late stop success needs no compensating call (cleanup exactly-once), got \(fixture.backend.stopCalls)")

        // Reload timeout.
        fixture.backend.armBarrier("reload")
        let reloadOutcomes = OutcomeCollector()
        fixture.service.requestReload { reloadOutcomes.append($0) }
        _ = await waitUntil { fixture.backend.reloadCalls == 1 }
        fireMutationDeadline(fixture)
        let reloadTimedOut = await waitUntil {
            reloadOutcomes.snapshot == [.timedOut]
                && fixture.service.stateSnapshot.lifecycleState == .timedOut
        }
        expect(&failures, reloadTimedOut, "a blocked reload must resolve .timedOut with state .timedOut")
        fixture.backend.releaseBarrier("reload")
        let reloadDrained = await waitUntil {
            fixture.service.stateSnapshot.lifecycleState == .idle && fixture.backend.stopCalls == 3
        }
        expect(&failures, reloadDrained,
               "a late reload success must run exactly one compensating stop and reconcile to .idle")
    }

    // MARK: - 6. Snapshot cache: late results discarded, reads touch nothing

    private static func checkSnapshotCacheAndLateResults(_ failures: inout [String]) async {
        let fixture = makeFixture()
        fixture.backend.setStatus("old status")
        fixture.backend.setServiceCount(3)

        fixture.service.requestStart { _ in }
        _ = await waitUntil { fixture.service.stateSnapshot.lifecycleState == .running }
        fixture.service.requestSnapshotRefresh()
        let fresh = await waitUntil {
            fixture.service.stateSnapshot.isStale == false
                && fixture.service.stateSnapshot.status == "old status"
        }
        expect(&failures, fresh, "a current-generation refresh must make the snapshot fresh")
        let firstSample = fixture.service.stateSnapshot.sampledMonotonicNs

        // Block sampling, then bump the generation while the sample is stuck.
        // Let the worker park before measuring: readsBefore must not race a
        // just-woken sample job.
        try? await Task.sleep(for: .milliseconds(50))
        fixture.backend.armBarrier("snapshot")
        let readsBefore = (
            status: fixture.backend.statusCalls,
            devices: fixture.backend.devicesCalls,
            serviceCount: fixture.backend.serviceCountCalls
        )
        fixture.service.requestSnapshotRefresh()
        _ = await waitUntil { fixture.backend.devicesCalls == readsBefore.devices + 1 }
        let generationBeforeStop = fixture.service.stateSnapshot.generation
        let stopOutcomes = OutcomeCollector()
        fixture.host.holdRequests()
        fixture.service.requestStop { stopOutcomes.append($0) }
        expect(&failures, stopOutcomes.snapshot.isEmpty,
               "the stop must stay in the handshake phase while the worker samples")

        // The stuck sample will post for the old generation and must be
        // discarded: the newer generation keeps the last snapshot, marked
        // stale, and no read ever triggers the backend.
        fixture.backend.setStatus("late-sample")
        fixture.backend.releaseBarrier("snapshot")
        let sampleSettled = await pollUntilRealtime {
            fixture.backend.statusCalls == readsBefore.status + 1
                && fixture.backend.devicesCalls == readsBefore.devices + 1
                && fixture.backend.serviceCountCalls == readsBefore.serviceCount + 1
        }
        expect(&failures, sampleSettled,
               "the blocked sample's three backend calls must settle after release")

        for _ in 0..<1_000 { _ = fixture.service.stateSnapshot }
        let readsAfter = (
            status: fixture.backend.statusCalls,
            devices: fixture.backend.devicesCalls,
            serviceCount: fixture.backend.serviceCountCalls
        )
        // Exactly the one in-flight sample, and nothing from the 1_000 reads.
        expect(&failures, readsAfter.status == readsBefore.status + 1
            && readsAfter.devices == readsBefore.devices + 1
            && readsAfter.serviceCount == readsBefore.serviceCount + 1,
               "snapshot reads must never trigger backend/IOKit sampling, before=\(readsBefore) after=\(readsAfter) gen=\(fixture.service.stateSnapshot.generation) state=\(fixture.service.stateSnapshot.lifecycleState)")

        let stillStale = await waitUntil { fixture.service.stateSnapshot.isStale == true }
        expect(&failures, stillStale, "a discarded stale refresh must keep the snapshot marked stale")
        let cached = fixture.service.stateSnapshot
        expect(&failures, cached.status == "old status",
               "a late sample must not overwrite the snapshot payload for a newer generation")
        expect(&failures, cached.sampledMonotonicNs == firstSample,
               "the discarded late sample must not update the sampled timestamp")
        expect(&failures, cached.generation == generationBeforeStop + 1,
               "the snapshot generation must follow lifecycle changes")

        // A refresh for the current generation applies normally afterwards.
        fixture.clock.advance(1_000_000)
        fixture.backend.setStatus("current status")
        fixture.service.requestSnapshotRefresh()
        let refreshed = await waitUntil {
            fixture.service.stateSnapshot.isStale == false
                && fixture.service.stateSnapshot.status == "current status"
        }
        expect(&failures, refreshed, "a current-generation refresh must apply its sample, got stale=\(fixture.service.stateSnapshot.isStale) status=\(fixture.service.stateSnapshot.status) gen=\(fixture.service.stateSnapshot.generation) state=\(fixture.service.stateSnapshot.lifecycleState)")
        expect(&failures, fixture.service.stateSnapshot.sampledMonotonicNs > firstSample,
               "the applied refresh must carry its own (later) sample time, got \(fixture.service.stateSnapshot.sampledMonotonicNs) vs \(firstSample)")
        expect(&failures, fixture.service.stateSnapshot.generation == generationBeforeStop + 1,
               "a refresh must never change the generation")

        fixture.host.confirmAll(true)
        _ = await waitUntil { stopOutcomes.snapshot == [.stopped] }
    }
    // MARK: - 7. Completion contracts: merges, limits, duplicates, cleanup

    private static func checkCompletionContracts(_ failures: inout [String]) async {
        let fixture = makeFixture()
        fixture.service.requestStart { _ in }
        _ = await waitUntil { fixture.service.stateSnapshot.lifecycleState == .running }

        // Duplicate stop while one stop is in flight: merged, both complete
        // exactly once, one device call, no double cleanup.
        fixture.backend.armBarrier("stop")
        let firstStop = OutcomeCollector()
        let secondStop = OutcomeCollector()
        fixture.service.requestStop { firstStop.append($0) }
        _ = await waitUntil { fixture.backend.stopCalls == 1 }
        fixture.service.requestStop { secondStop.append($0) }
        fixture.backend.releaseBarrier("stop")
        let bothStopped = await waitUntil {
            firstStop.snapshot == [.stopped] && secondStop.snapshot == [.stopped]
        }
        expect(&failures, bothStopped, "merged duplicate stops must both complete exactly once")
        expect(&failures, fixture.backend.stopCalls == 1,
               "merged duplicate stops must share one device call, got \(fixture.backend.stopCalls)")

        // Duplicate stop while already idle: immediate, no device work.
        let idleFirst = OutcomeCollector()
        let idleSecond = OutcomeCollector()
        fixture.service.requestStop { idleFirst.append($0) }
        fixture.service.requestStop { idleSecond.append($0) }
        let idleResolved = await waitUntil {
            idleFirst.snapshot == [.stopped] && idleSecond.snapshot == [.stopped]
        }
        expect(&failures, idleResolved, "idempotent stops must complete immediately")
        expect(&failures, fixture.backend.stopCalls == 1,
               "idempotent stops must not touch the device again, got \(fixture.backend.stopCalls)")

        // Waiter limit: 1 accepted + 15 merged = 16 waiters; the rest are
        // rejected explicitly instead of accumulating unbounded closures.
        fixture.backend.armBarrier("start")
        var startCollectors: [OutcomeCollector] = []
        for _ in 0..<20 {
            let collector = OutcomeCollector()
            startCollectors.append(collector)
            fixture.service.requestStart { collector.append($0) }
        }
        let limitResolved = await waitUntil {
            startCollectors.dropFirst(16).allSatisfy { $0.snapshot.count == 1 }
        }
        expect(&failures, limitResolved, "waiters beyond the limit must resolve immediately")
        fixture.backend.releaseBarrier("start")
        let limitSettled = await waitUntil {
            startCollectors.allSatisfy { $0.snapshot.count == 1 }
        }
        expect(&failures, limitSettled, "every waiter-limit request must resolve exactly once")
        expect(&failures, fixture.service.stateSnapshot.lifecycleState == .running,
               "the accepted start must leave the devices running")
        let startedCount = startCollectors.map { $0.count(.started) }.reduce(0, +)
        let limitedCount = startCollectors.map { $0.count(.rejected(.waiterLimitReached)) }.reduce(0, +)
        expect(&failures, startedCount == 16 && limitedCount == 4,
               "expected 16 started and 4 explicitly limited waiters, got \(startedCount)/\(limitedCount), gen=\(fixture.service.stateSnapshot.generation) startCalls=\(fixture.backend.startCalls)")
        expect(&failures, fixture.backend.startCalls == 2,
               "merged starts must share one device call per intent, got \(fixture.backend.startCalls)")

        // A stop submitted while an earlier start is already timed out must
        // not re-resolve the timed-out waiters, and the late return must run
        // cleanup exactly once before the stop intent.
        let timeoutFixture = makeFixture()
        timeoutFixture.backend.armBarrier("start")
        let lateStart = OutcomeCollector()
        timeoutFixture.service.requestStart { lateStart.append($0) }
        _ = await waitUntil { timeoutFixture.backend.startCalls == 1 }
        fireMutationDeadline(timeoutFixture)
        _ = await waitUntil { lateStart.snapshot == [.timedOut] }
        let lateStop = OutcomeCollector()
        timeoutFixture.service.requestStop { lateStop.append($0) }
        expect(&failures, lateStart.snapshot == [.timedOut],
               "a timed-out start must not be re-resolved by the newer request")
        timeoutFixture.backend.releaseBarrier("start")
        let lateStopped = await waitUntil { lateStop.snapshot == [.stopped] }
        expect(&failures, lateStopped, "the stop intent must complete after the late return")
        expect(&failures, timeoutFixture.backend.stopCalls == 2,
               "expected exactly [compensating stop, stop intent] after the late return, got \(timeoutFixture.backend.stopCalls)")
    }

    // MARK: - R2.8 A queued start must carry a total deadline from acceptance

    private static func checkQueuedStartTotalDeadline(_ failures: inout [String]) async {
        let fixture = makeFixture(configuration: TouchRuntimeService.Configuration(
            mutationBudgetNs: 20_000_000,
            quiesceBudgetNs: 20_000_000,
            requestBudgetSlackNs: 10_000_000
        ))
        fixture.backend.armBarrier("snapshot")
        fixture.service.requestSnapshotRefresh()
        _ = await waitUntil { fixture.backend.devicesCalls == 1 }

        // The worker is stuck sampling, so this start can only queue.
        let startOutcomes = OutcomeCollector()
        fixture.service.requestStart { startOutcomes.append($0) }
        expect(&failures, fixture.scheduler.pendingCount >= 1,
               "a queued start must have its total deadline registered at acceptance time")

        fixture.clock.advance(60_000_000)
        fixture.scheduler.fireDue(now: fixture.clock.now)
        let timedOut = await waitUntil { startOutcomes.snapshot == [.timedOut] }
        expect(&failures, timedOut, "the queued start's total budget must resolve the waiter exactly once with .timedOut")
        expect(&failures, startOutcomes.snapshot.count == 1, "the start completion must fire exactly once")
        expect(&failures, fixture.service.stateSnapshot.lifecycleState == .failed,
               "the expired queued start must fail closed, got \(fixture.service.stateSnapshot.lifecycleState)")

        fixture.backend.releaseBarrier("snapshot")
        let drainedCalls = await waitUntil { fixture.backend.devicesCalls >= 1 }
        expect(&failures, drainedCalls, "the queued snapshot sample must run after the barriers release")
        for _ in 0..<200 { await Task.yield() }
        expect(&failures, fixture.backend.startCalls == 0,
               "an expired queued start must never enter the backend")
        expect(&failures, fixture.service.stateSnapshot.lifecycleState != .running,
               "the expired start must not make the devices running")
    }

    // MARK: - R2.9 The idle worker must not pin the service; late exit after a blocked call

    private static func checkServiceThreadLifecycle(_ failures: inout [String]) async {
        // Idle service: let the worker park in its idle wait first (a bare
        // create-and-drop would race the thread's first iteration), then
        // release the owner — the thread must still exit.
        var idleFixture: Fixture? = makeFixture()
        var probeService: TouchRuntimeService? = idleFixture?.service
        guard probeService != nil else {
            failures.append("checkServiceThreadLifecycle: fixture service missing")
            return
        }
        probeService?.requestSnapshotRefresh()
        _ = await waitUntil { probeService?.stateSnapshot.sampledMonotonicNs != 0 }
        try? await Task.sleep(for: .milliseconds(50))
        weak let weakIdle = probeService
        probeService = nil
        idleFixture = nil
        let idleExited = await pollUntilRealtime { weakIdle == nil }
        expect(&failures, idleExited,
               "releasing a parked idle service must let the worker thread exit (weak reference nil), not park forever")

        // Blocked backend: the thread may keep the service alive while the
        // call is stuck, but must exit once the call returns.
        let backend = FakeTouchBackend()
        backend.armBarrier("start")
        var blockedFixture: Fixture? = makeFixture(backendOverride: backend)
        weak let weakBlocked = blockedFixture?.service
        blockedFixture?.service.requestStart { _ in }
        _ = await waitUntil { backend.startCalls == 1 }
        blockedFixture = nil
        let aliveWhileBlocked = await pollUntilRealtime { weakBlocked != nil }
        expect(&failures, aliveWhileBlocked,
               "while a backend call is blocked the worker still owns the service resources")
        backend.releaseBarrier("start")
        let lateExit = await pollUntilRealtime { weakBlocked == nil }
        expect(&failures, lateExit,
               "after the blocked call returns and the owner is gone, the thread must exit promptly")
    }

    // MARK: - R2.10 State commits are generation-guarded and fail closed

    private static func checkAtomicStateCommits(_ failures: inout [String]) async {
        // (a) stop supersedes a starting intent; the stop's quiesce is then
        // rejected: the dead start must not be resurrected as .starting, and
        // the later cleanup of that start must not resurrect it either.
        let fixture = makeFixture()
        fixture.backend.armBarrier("start")
        let startOutcomes = OutcomeCollector()
        fixture.service.requestStart { startOutcomes.append($0) }
        _ = await waitUntil { fixture.backend.startCalls == 1 }
        fixture.host.holdRequests()
        let stopOutcomes = OutcomeCollector()
        fixture.service.requestStop { stopOutcomes.append($0) }
        expect(&failures, startOutcomes.snapshot == [.superseded],
               "the stop must supersede the in-flight start exactly once")
        _ = await waitUntil { fixture.host.requestCount == 1 }
        fixture.clock.advance(300_000_000)
        fixture.scheduler.fireDue(now: fixture.clock.now)
        let rejected = await waitUntil { stopOutcomes.snapshot == [.rejected(.quiesceUnconfirmed)] }
        expect(&failures, rejected, "the stop's quiesce budget must reject explicitly")
        expect(&failures, fixture.service.stateSnapshot.lifecycleState == .failed,
               "quiesce rejection must fail closed, not resurrect the dead .starting operation, got \(fixture.service.stateSnapshot.lifecycleState)")
        fixture.backend.releaseBarrier("start")
        let cleaned = await waitUntil { fixture.backend.stopCalls == 1 }
        expect(&failures, cleaned, "the superseded start's late success must still be cleaned up")
        expect(&failures, fixture.service.stateSnapshot.lifecycleState == .failed,
               "the late cleanup of a superseded start must not resurrect the dead transition, got \(fixture.service.stateSnapshot.lifecycleState)")

        // (b) an older intent's rejection must never overwrite a newer
        // generation's committed state: reject only the dead reload's
        // handshake while the newer stop's handshake is still pending.
        let sequence = makeFixture()
        sequence.backend.armBarrier("start")
        sequence.service.requestStart { _ in }
        _ = await waitUntil { sequence.backend.startCalls == 1 }
        sequence.host.holdRequests()
        let reloadOutcomes = OutcomeCollector()
        sequence.service.requestReload { reloadOutcomes.append($0) }
        _ = await pollUntilRealtime { sequence.host.requestCount >= 1 }
        let reloadGeneration = sequence.service.stateSnapshot.generation
        let seqStopOutcomes = OutcomeCollector()
        sequence.service.requestStop { seqStopOutcomes.append($0) }
        expect(&failures, reloadOutcomes.snapshot == [.superseded],
               "the newer stop must supersede the held reload")
        expect(&failures, sequence.service.stateSnapshot.lifecycleState == .stopping,
               "the newer generation owns the lifecycle state")
        sequence.host.confirmGeneration(reloadGeneration, false)
        for _ in 0..<50 { await Task.yield() }
        expect(&failures, sequence.service.stateSnapshot.lifecycleState == .stopping,
               "the old intent's rejection must not overwrite the newer generation's state, got \(sequence.service.stateSnapshot.lifecycleState)")
        expect(&failures, sequence.backend.stopCalls == 0 && sequence.backend.reloadCalls == 0,
               "neither the rejected reload nor the pending stop may touch the device yet")
        sequence.host.confirmAll(true)
        sequence.backend.releaseBarrier("start")
        let stopped = await waitUntil { seqStopOutcomes.snapshot == [.stopped] }
        expect(&failures, stopped, "the newer stop must complete after the stuck start returns")
        expect(&failures, sequence.service.stateSnapshot.lifecycleState == .idle,
               "the sequence must end idle without stale transitional states")
    }

    // MARK: - R2.11 Handshake tasks and cleanup ownership stay bounded

    private static func checkHandshakeTaskBounding(_ failures: inout [String]) async {
        let fixture = makeFixture(configuration: TouchRuntimeService.Configuration(
            mutationBudgetNs: 500_000_000,
            quiesceBudgetNs: 200_000_000,
            requestBudgetSlackNs: 50_000_000,
            waiterLimit: 16,
            workerQueueLimit: 8,
            idleWaitSeconds: 0.5,
            handshakeTaskLimit: 4
        ))
        fixture.service.requestStart { _ in }
        _ = await waitUntil { fixture.service.stateSnapshot.lifecycleState == .running }
        fixture.host.holdRequests()

        var collectors: [OutcomeCollector] = []
        for index in 0..<30 {
            let collector = OutcomeCollector()
            collectors.append(collector)
            // Alternating ops: a same-op flood merges into one intent, so the
            // bounding check needs a chain of superseded intents instead.
            if index % 2 == 0 {
                fixture.service.requestStop { collector.append($0) }
            } else {
                fixture.service.requestReload { collector.append($0) }
            }
        }
        fixture.clock.advance(300_000_000)
        fixture.scheduler.fireDue(now: fixture.clock.now)
        let allResolved = await waitUntil {
            collectors.allSatisfy { $0.snapshot.count == 1 }
        }
        expect(&failures, allResolved, "every flood request must resolve exactly once")
        expect(&failures, fixture.host.pendingCount <= 4,
               "a flood with a never-answering host must stay within the handshake cap, got \(fixture.host.pendingCount)")
        expect(&failures, fixture.backend.stopCalls == 0 && fixture.backend.reloadCalls == 0,
               "no superseded stop/reload may reach the device")
        var total = 0
        var kinds = ""
        for collector in collectors {
            for outcome in collector.snapshot {
                total += 1
                switch outcome {
                case .superseded: kinds += "S"
                case .rejected(.quiesceUnconfirmed): kinds += "Q"
                case .rejected(.handshakeBusy): kinds += "B"
                default: kinds += "?"
                }
            }
        }
        expect(&failures, total == 30, "each of the 30 requests completes exactly once, got \(total)")
        expect(&failures, !kinds.contains("?"),
               "every flood outcome must be superseded, quiesce-rejected, or handshake-busy, got \(kinds)")
        let superseded = collectors.map { $0.count(.superseded) }.reduce(0, +)
        let quiesceRejected = collectors.map { $0.count(.rejected(.quiesceUnconfirmed)) }.reduce(0, +)
        let busyRejected = collectors.map { $0.count(.rejected(.handshakeBusy)) }.reduce(0, +)
        expect(&failures, superseded + quiesceRejected + busyRejected == 30,
               "the flood must resolve within bounded kinds, got \(superseded)+\(quiesceRejected)+\(busyRejected)")
    }
}
