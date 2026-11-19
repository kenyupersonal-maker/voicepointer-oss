import Foundation

/// Lifecycle of the touch devices as owned by `TouchRuntimeService`. This is
/// device readiness only — it is NOT app-wide armed state: the service owns
/// neither permissions, nor the event tap, nor keyboard shortcuts.
public enum TouchLifecycleState: Sendable, Equatable {
    /// No devices started by this service.
    case idle
    /// A start request is in flight; devices must not be taken over yet.
    case starting
    /// The backend reported devices running for the current generation.
    case running
    /// A stop request is in flight; devices are untakeable.
    case stopping
    /// A reload request is in flight; devices are untakeable.
    case reloading
    /// The last request failed or was refused. Fail-closed: untakeable until
    /// a new explicit request. This state is never used to resurrect a
    /// superseded transitional operation (.starting/.stopping/.reloading of a
    /// dead generation).
    case failed
    /// A device-call deadline elapsed while the backend call was still in
    /// flight. Untakeable. The worker still owns the blocked call; its late
    /// result is reconciled on return. This does NOT claim the resource
    /// stopped or started — query the snapshot for the current truth.
    case timedOut
}

/// Sendable cache value. Reads never touch the backend or the worker thread.
public struct TouchRuntimeSnapshot: Sendable, Equatable {
    public let lifecycleState: TouchLifecycleState
    public let generation: UInt64
    public let devices: [TouchDeviceInfo]
    /// -1 while unknown (failed or never-sampled IOKit query).
    public let connectedServiceCount: Int
    public let status: String
    /// Injected monotonic time at which the payload below was sampled.
    public let sampledMonotonicNs: UInt64
    /// True while devices/status/serviceCount have not been re-sampled for
    /// the current generation (a lifecycle change happened, the refresh is
    /// pending, or the last refresh was discarded as stale).
    public let isStale: Bool
    /// True while a compensating cleanup stop for a superseded/timed-out
    /// operation is queued or blocked on the worker. The service deliberately
    /// does not claim `.idle` while this is set — the compensating stop is
    /// itself a potentially blocking backend call owned by the single worker.
    public let cleanupStopInFlight: Bool
}

public enum TouchRejection: Sendable, Equatable {
    /// The quiesce handshake was refused or its budget elapsed; the device
    /// change did not happen.
    case quiesceUnconfirmed
    /// The intent already holds the bounded number of waiters.
    case waiterLimitReached
    /// The bounded worker queue is full; defensive, unreachable under the
    /// request-coalescing rules.
    case workerQueueFull
    /// Live quiesce handshake tasks already occupy the hard limit (a host
    /// that never answers cannot be force-interrupted), so this new stop or
    /// reload is refused instead of growing the count unboundedly.
    case handshakeBusy
}

/// Exactly-one completion contract per accepted request.
public enum TouchLifecycleOutcome: Sendable, Equatable {
    case started
    case stopped
    case reloaded
    /// The request was replaced by a newer accepted intent before it could
    /// take effect. The device change did not happen on its behalf.
    case superseded
    /// The bounded wait elapsed while the operation was still unresolved.
    /// Resource state is intentionally not claimed; query the snapshot.
    case timedOut
    case rejected(TouchRejection)
    case failed
}

/// Async device lifecycle service (VP-B, revision 2).
///
/// Wraps the synchronous `TouchDriverBackend` calls on one dedicated worker
/// thread. Lifecycle requests from any thread return immediately: generation
/// advancement and untakeable-state publication happen on the caller thread
/// under `stateLock`, never behind a blocked device call. Only the blocking
/// backend call itself runs on the worker, serialized, max concurrency 1.
///
/// Deadline semantics (R2): every accepted intent — start included — carries
/// a total budget registered at acceptance, so the queued phase is bounded
/// too; a queued intent whose budget expires resolves `.timedOut`, never
/// executes later, and never reports success. A worker call additionally
/// carries its own mutation deadline; when it elapses the state becomes
/// `.timedOut` (untakeable) and the resource is deliberately NOT claimed
/// stopped or started. Swift cannot interrupt a blocked private call, so the
/// worker keeps ownership; when the call eventually returns, the late result
/// is reconciled and a compensating `stop` runs exactly once for a late
/// start/reload success — that compensating stop is itself a blocking
/// backend call whose pending state stays visible in the snapshot. Only a new
/// explicit request (and, for stop/reload, a fresh quiesce confirmation) may
/// return the devices to `.running`.
///
/// State-commit semantics (R2): every rejection/timeout commit happens under
/// `stateLock` together with its generation check; a superseded intent can
/// never write state, older observers never overwrite a newer generation's
/// committed state, and transitional states of dead operations are never
/// restored — a rejection or a no-call timeout fails closed (`.failed`).
///
/// Thread lifecycle (R2): the worker's idle wait is bounded and the strong
/// service binding lives only inside one pump iteration, so a released
/// service can deallocate (its deinit sets the stop flag) instead of being
/// pinned forever by its own parked thread. While a backend call is blocked
/// the thread legitimately keeps the service alive; it exits promptly once
/// the call returns and the owner is gone.
///
/// Concurrency model — every field's guard:
/// - stateLock: generation, lifecycleState, snapshot, activeIntent, inFlight,
///   snapshotQueued, cleanupStopPending, liveHandshakeTasks, handshakeTask.
///   Never held across backend calls, quiesce awaits, scheduler calls, or
///   completion invocation.
/// - workerCondition: workerCommands, workerStopRequested (worker queue only).
/// - completions are invoked after stateLock is released and may reenter the
///   service freely.
public final class TouchRuntimeService: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Deadline for one device call on the worker thread.
        public var mutationBudgetNs: UInt64 = 2_000_000_000
        /// Deadline for the quiesce handshake of a stop/reload request.
        public var quiesceBudgetNs: UInt64 = 1_000_000_000
        /// Extra slack on top of both budgets bounding each waiter.
        public var requestBudgetSlackNs: UInt64 = 500_000_000
        /// Waiters merged into one intent, bounding completion memory.
        public var waiterLimit = 16
        /// Worker queue depth excluding in-flight work and priority cleanup.
        public var workerQueueLimit = 8
        /// Real-time idle wait of the worker thread between pumps; the
        /// bounded wait is what lets a released service's thread exit.
        public var idleWaitSeconds: TimeInterval = 0.5
        /// Hard cap on live quiesce handshake tasks. Cooperative cancellation
        /// keeps the steady-state count at 1; a host that never answers is
        /// bounded here and further stop/reload requests are refused with
        /// `.handshakeBusy` instead of growing the count unboundedly.
        public var handshakeTaskLimit = 2

        public init(
            mutationBudgetNs: UInt64 = 2_000_000_000,
            quiesceBudgetNs: UInt64 = 1_000_000_000,
            requestBudgetSlackNs: UInt64 = 500_000_000,
            waiterLimit: Int = 16,
            workerQueueLimit: Int = 8,
            idleWaitSeconds: TimeInterval = 0.5,
            handshakeTaskLimit: Int = 2
        ) {
            self.mutationBudgetNs = mutationBudgetNs
            self.quiesceBudgetNs = quiesceBudgetNs
            self.requestBudgetSlackNs = requestBudgetSlackNs
            self.waiterLimit = waiterLimit
            self.workerQueueLimit = workerQueueLimit
            self.idleWaitSeconds = idleWaitSeconds
            self.handshakeTaskLimit = handshakeTaskLimit
        }
    }

    private enum IntentOp: Sendable, Equatable, CustomStringConvertible {
        case start, stop, reload

        var description: String {
            switch self {
            case .start: return "start"
            case .stop: return "stop"
            case .reload: return "reload"
            }
        }
    }

    /// All fields guarded by the service's stateLock.
    private final class Intent: @unchecked Sendable {
        let op: IntentOp
        let generation: UInt64
        let acceptedAtNs: UInt64
        let deadlineNs: UInt64
        var phase: Phase = .quiescing
        var completions: [@Sendable (TouchLifecycleOutcome) -> Void] = []
        var isResolved = false

        enum Phase: Sendable { case quiescing, dispatched }

        init(op: IntentOp, generation: UInt64, acceptedAtNs: UInt64, deadlineNs: UInt64) {
            self.op = op
            self.generation = generation
            self.acceptedAtNs = acceptedAtNs
            self.deadlineNs = deadlineNs
        }
    }

    private struct Delivery {
        let completions: [@Sendable (TouchLifecycleOutcome) -> Void]
        let outcome: TouchLifecycleOutcome
    }

    private struct InFlight {
        let op: IntentOp
        let generation: UInt64
        var timedOut = false
        var cleanupDone = false
    }

    /// Guards exactly-one accounting per handshake task. A task that is
    /// cancelled moves live→cancelling immediately (its completion will land
    /// asynchronously, or never, if the host is non-cooperative); the task
    /// body's report moves whatever bucket it is in →finalized exactly once.
    private final class HandshakeTicket: @unchecked Sendable {
        private let lock = NSLock()
        private enum Phase { case live, cancelling, finalized }
        private var phase: Phase = .live

        /// Returns true when this call transitions the ticket live→cancelled.
        func tryCancel() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard phase == .live else { return false }
            phase = .cancelling
            return true
        }

        /// Returns the buckets the task leaves, or nil when already finalized.
        func tryFinalize() -> (leaveLive: Bool, leaveCancelling: Bool)? {
            lock.lock()
            defer { lock.unlock() }
            switch phase {
            case .live:
                phase = .finalized
                return (leaveLive: true, leaveCancelling: false)
            case .cancelling:
                phase = .finalized
                return (leaveLive: false, leaveCancelling: true)
            case .finalized:
                return nil
            }
        }
    }

    private enum WorkerCommand: Sendable, CustomStringConvertible {
        case mutate(op: IntentOp, generation: UInt64)
        case snapshot
        case cleanupStop(generation: UInt64)

        var description: String {
            switch self {
            case .mutate(let op, let generation): return "mutate(\(op), gen \(generation))"
            case .snapshot: return "snapshot"
            case .cleanupStop(let generation): return "cleanupStop(gen \(generation))"
            }
        }
    }

    private enum PostLockAction: Sendable {
        case enqueueMutate(op: IntentOp, generation: UInt64)
        case enqueueSnapshot
        case enqueueCleanupStop(generation: UInt64)
    }

    // stateLock-guarded
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var lifecycleState: TouchLifecycleState = .idle
    private var snapshot = TouchRuntimeSnapshot(
        lifecycleState: .idle, generation: 0, devices: [],
        connectedServiceCount: -1, status: "", sampledMonotonicNs: 0,
        isStale: true, cleanupStopInFlight: false
    )
    private var activeIntent: Intent?
    private var inFlight: InFlight?
    private var snapshotQueued = false
    private var cleanupStopPending = false
    /// Quiesce handshake accounting, each bucket bounded by
    /// `handshakeTaskLimit`: live tasks (created, not yet cancelled or
    /// answered) and cancelling tasks (cancelled, awaiting an asynchronous or
    /// never-arriving completion from a possibly non-cooperative host).
    /// Superseded handshakes are cancelled cooperatively; a host that never
    /// answers fills the cancelling bucket until further stop/reload requests
    /// are refused instead of growing either bucket unboundedly.
    private var liveHandshakeTasks = 0
    private var cancellingHandshakeTasks = 0
    private var handshakeTask: (generation: UInt64, task: Task<Void, Never>, ticket: HandshakeTicket)?
    private enum DeadlineKind: Hashable { case request, quiesce, mutation }
    private var deadlines: [DeadlineKind: TouchDeadlineCancellation] = [:]

    private let backend: any TouchDriverBackend
    private let quiesce: any TouchQuiesceCoordinating
    private let scheduler: any TouchTimeoutScheduling
    private let clock: @Sendable () -> UInt64
    private let configuration: Configuration

    // workerCondition-guarded
    private let workerCondition = NSCondition()
    private var workerCommands: [WorkerCommand] = []
    private var workerStopRequested = false

    public init(
        backend: any TouchDriverBackend,
        quiesce: any TouchQuiesceCoordinating = UnwiredQuiesceCoordinator(),
        scheduler: any TouchTimeoutScheduling = DispatchTimeoutScheduler(),
        clock: @escaping @Sendable () -> UInt64 = touchDefaultMonotonicClock,
        configuration: Configuration = Configuration()
    ) {
        self.backend = backend
        self.quiesce = quiesce
        self.scheduler = scheduler
        self.clock = clock
        self.configuration = configuration
        let thread = Thread { [weak self] in
            // One dedicated thread for the whole service lifetime. The strong
            // binding lives only inside one iteration and is released when the
            // iteration ends, so a released service can deallocate (its deinit
            // sets the stop flag) instead of being pinned by its own parked
            // thread. While a backend call is blocked the thread legitimately
            // keeps the service alive; it exits promptly once the call returns
            // and the owner is gone.
            while let service = self {
                if !service.workerPump() { return }
            }
        }
        thread.name = "com.kenyu.VoicePointer.touch-runtime"
        thread.start()
    }

    deinit {
        for token in deadlines.values { token.cancel() }
        workerCondition.lock()
        workerStopRequested = true
        workerCondition.signal()
        workerCondition.unlock()
    }

    // MARK: - Public API

    /// Cached snapshot. Never calls the backend, never waits on the worker.
    @_spi(Testing)
    public var outstandingHandshakeTaskCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return liveHandshakeTasks + cancellingHandshakeTasks
    }

    public var stateSnapshot: TouchRuntimeSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshot
    }

    /// Brings devices up. Start requires no quiesce handshake (it creates no
    /// takeover risk); the completion fires exactly once.
    public func requestStart(_ completion: @escaping @Sendable (TouchLifecycleOutcome) -> Void) {
        let plan = submit(op: .start, completion: completion)
        run(plan)
    }

    /// Stops devices. The host quiesce handshake must confirm for the current
    /// generation before the worker performs the device change.
    public func requestStop(_ completion: @escaping @Sendable (TouchLifecycleOutcome) -> Void) {
        let plan = submit(op: .stop, completion: completion)
        run(plan)
    }

    /// Reloads devices. Same quiesce gate as stop; consecutive reload requests
    /// merge into at most one pending intent.
    public func requestReload(_ completion: @escaping @Sendable (TouchLifecycleOutcome) -> Void) {
        let plan = submit(op: .reload, completion: completion)
        run(plan)
    }

    /// Asynchronously refreshes devices/status/serviceCount into the cached
    /// snapshot. Coalesced; never blocks the caller.
    public func requestSnapshotRefresh() {
        var shouldEnqueue = false
        stateLock.lock()
        if !snapshotQueued {
            snapshotQueued = true
            shouldEnqueue = true
        }
        stateLock.unlock()
        if shouldEnqueue, !enqueueWorker(.snapshot, priority: false) {
            stateLock.lock()
            snapshotQueued = false
            stateLock.unlock()
        }
    }

    // MARK: - Intent submission (caller thread; never blocks on the worker)

    private struct SubmissionPlan {
        var immediate: Delivery?
        var superseded: Delivery?
        var intent: Intent?
        var staleHandshakeTask: Task<Void, Never>?
        var staleDeadlines: [TouchDeadlineCancellation] = []
    }

    private func submit(op: IntentOp, completion: @escaping @Sendable (TouchLifecycleOutcome) -> Void) -> SubmissionPlan {
        var plan = SubmissionPlan()
        let acceptedAt = clock()
        stateLock.lock()
        // A resolved intent may still occupy activeIntent until a newer one
        // replaces it; only an UNRESOLVED intent blocks idempotent fulfillment.
        let hasLiveIntent: Bool = {
            if let active = activeIntent, !active.isResolved { return true }
            return false
        }()
        let isIdleSafe = lifecycleState == .idle && !hasLiveIntent && inFlight == nil
        let canFulfillImmediately = (op == .start && lifecycleState == .running && !hasLiveIntent && inFlight == nil)
            || (op == .stop && isIdleSafe)

        if canFulfillImmediately {
            // Idempotent request: no device work, no generation churn.
            plan.immediate = Delivery(completions: [completion], outcome: op == .start ? .started : .stopped)
        } else if let active = activeIntent, !active.isResolved, active.op == op {
            // Merge into the pending intent: at most one pending intent per op.
            if active.completions.count >= configuration.waiterLimit {
                plan.immediate = Delivery(completions: [completion], outcome: .rejected(.waiterLimitReached))
            } else {
                active.completions.append(completion)
            }
        } else if op != .start,
                  liveHandshakeTasks >= configuration.handshakeTaskLimit
                  || cancellingHandshakeTasks >= configuration.handshakeTaskLimit {
            // Hard cap: a host that never answers its handshake (cooperative
            // cancellation cannot force it) must not let a flood grow live
            // tasks unboundedly. Fail this request closed, atomically, before
            // any generation or state change.
            plan.immediate = Delivery(completions: [completion], outcome: .rejected(.handshakeBusy))
        } else {
            // New accepted intent: advance the generation and publish the
            // untakeable state right here on the caller thread, ahead of any
            // blocked device worker.
            generation &+= 1
            plan.staleDeadlines = Array(deadlines.values)
            deadlines.removeAll(keepingCapacity: true)
            // Any outstanding handshake belongs to an older generation once a
            // new intent is accepted; cancel it whether that intent died by
            // supersede or by its own deadline, so dead tasks cannot pile up
            // against the hard cap.
            if let stale = handshakeTask, stale.generation != generation {
                if stale.ticket.tryCancel() {
                    liveHandshakeTasks -= 1
                    cancellingHandshakeTasks += 1
                }
                plan.staleHandshakeTask = stale.task
                handshakeTask = nil
            }
            if let old = activeIntent, !old.isResolved {
                old.isResolved = true
                plan.superseded = Delivery(completions: old.completions, outcome: .superseded)
                old.completions = []
            }
            let intent = Intent(op: op, generation: generation, acceptedAtNs: acceptedAt,
                deadlineNs: acceptedAt + configuration.quiesceBudgetNs + configuration.mutationBudgetNs + configuration.requestBudgetSlackNs)
            let transitional: TouchLifecycleState
            switch op {
            case .start:
                transitional = .starting
                intent.phase = .dispatched
            case .stop: transitional = .stopping
            case .reload: transitional = .reloading
            }
            activeIntent = intent
            lifecycleState = transitional
            snapshot = updatedSnapshot(state: transitional, stale: true)
            // The requesting caller is the intent's first waiter; merged
            // requests append below the same waiterLimit bound.
            intent.completions.append(completion)
            plan.intent = intent
        }
        stateLock.unlock()
        plan.staleHandshakeTask?.cancel()
        for token in plan.staleDeadlines { token.cancel() }
        return plan
    }

    private func run(_ plan: SubmissionPlan) {
        if let intent = plan.intent {
            scheduleRequestBudget(generation: intent.generation, deadlineNs: intent.deadlineNs)
        }
        if let immediate = plan.immediate { deliver(immediate) }
        if let superseded = plan.superseded { deliver(superseded) }
        guard let intent = plan.intent else { return }
        // Total budget for every intent, registered at acceptance so the
        // queued phase is bounded too — not only the handshake and the
        // worker call.
        if intent.op == .start {
            dispatchMutation(op: intent.op, generation: intent.generation)
        } else {
            beginQuiescePhase(generation: intent.generation)
        }
    }

    // MARK: - Quiesce phase (stop/reload)

    private func beginQuiescePhase(generation intentGeneration: UInt64) {
        var staleTask: Task<Void, Never>?
        stateLock.lock()
        guard let active = activeIntent, active.generation == intentGeneration,
              !active.isResolved, active.phase == .quiescing,
              handshakeTask?.generation != intentGeneration else {
            stateLock.unlock()
            return
        }
        // Revalidate at actual task creation, not just at submit: caller
        // completions can reenter and supersede this plan before run(plan).
        guard liveHandshakeTasks < configuration.handshakeTaskLimit,
              cancellingHandshakeTasks < configuration.handshakeTaskLimit else {
            active.isResolved = true
            let delivery = Delivery(completions: active.completions, outcome: .rejected(.handshakeBusy))
            active.completions = []
            lifecycleState = .failed
            snapshot = updatedSnapshot(state: .failed, stale: true)
            stateLock.unlock()
            deliver(delivery)
            return
        }
        let quiesceDeadline = active.acceptedAtNs + configuration.quiesceBudgetNs
        if let stale = handshakeTask, stale.generation != intentGeneration {
            if stale.ticket.tryCancel() {
                liveHandshakeTasks -= 1
                cancellingHandshakeTasks += 1
            }
            staleTask = stale.task
            handshakeTask = nil
        }
        liveHandshakeTasks += 1
        let ticket = HandshakeTicket()
        let task = Task { [weak self, ticket] in
            guard let self else { return }
            let confirmed = await self.quiesce.quiesce(generation: intentGeneration)
            self.handleQuiesceResult(
                generation: intentGeneration,
                confirmed: confirmed,
                ticket: ticket
            )
        }
        handshakeTask = (generation: intentGeneration, task: task, ticket: ticket)
        stateLock.unlock()
        staleTask?.cancel()

        scheduleDeadline(.quiesce, generation: intentGeneration, at: quiesceDeadline) { [weak self] in
            self?.handleQuiesceDeadline(generation: intentGeneration)
        }
    }

    private func handleQuiesceResult(
        generation intentGeneration: UInt64,
        confirmed: Bool,
        ticket: HandshakeTicket
    ) {
        var deliveries: [Delivery] = []
        var actions: [PostLockAction] = []
        stateLock.lock()
        if let leave = ticket.tryFinalize() {
            if leave.leaveLive { liveHandshakeTasks -= 1 }
            if leave.leaveCancelling { cancellingHandshakeTasks -= 1 }
        }
        if handshakeTask?.generation == intentGeneration {
            handshakeTask = nil
        }
        guard let active = activeIntent, active.generation == intentGeneration,
              !active.isResolved, active.phase == .quiescing else {
            // Late or superseded confirmation is invalid by generation.
            stateLock.unlock()
            return
        }
        if confirmed {
            active.phase = .dispatched
            actions.append(.enqueueMutate(op: active.op, generation: intentGeneration))
        } else {
            // Fail closed, atomically with the generation check: a refused
            // handshake must not resurrect a transitional state of a dead
            // operation, and a newer generation's state cannot be overwritten
            // because the commit happens under this same lock.
            active.isResolved = true
            deliveries.append(Delivery(
                completions: active.completions,
                outcome: .rejected(.quiesceUnconfirmed)
            ))
            active.completions = []
            lifecycleState = .failed
            snapshot = updatedSnapshot(state: .failed, stale: true)
        }
        stateLock.unlock()
        run(actions)
        deliverAll(deliveries)
    }

    private func handleQuiesceDeadline(generation intentGeneration: UInt64) {
        var deliveries: [Delivery] = []
        stateLock.lock()
        if let active = activeIntent, active.generation == intentGeneration,
           !active.isResolved, active.phase == .quiescing {
            active.isResolved = true
            deliveries.append(Delivery(
                completions: active.completions,
                outcome: .rejected(.quiesceUnconfirmed)
            ))
            active.completions = []
            // Same-lock commit, guarded by the generation check above: no
            // blind restoration of a transitional state.
            lifecycleState = .failed
            snapshot = updatedSnapshot(state: .failed, stale: true)
        }
        stateLock.unlock()
        deliverAll(deliveries)
    }

    /// Bounded waiters: every request resolves within quiesce + mutation
    /// budgets plus slack, whatever happens to the device call.
    private func scheduleRequestBudget(generation intentGeneration: UInt64, deadlineNs: UInt64) {
        scheduleDeadline(.request, generation: intentGeneration, at: deadlineNs) { [weak self] in
            self?.handleRequestBudgetDeadline(generation: intentGeneration)
        }
    }

    private func handleRequestBudgetDeadline(generation intentGeneration: UInt64) {
        var deliveries: [Delivery] = []
        stateLock.lock()
        if let active = activeIntent, active.generation == intentGeneration, !active.isResolved {
            active.isResolved = true
            deliveries.append(Delivery(completions: active.completions, outcome: .timedOut))
            active.completions = []
            if let flight = inFlight, flight.generation == intentGeneration {
                // A device call is (or was) owned by the worker for this
                // intent: the resource state is genuinely unknown.
                lifecycleState = .timedOut
                snapshot = updatedSnapshot(state: .timedOut, stale: true)
            } else {
                // Nothing was ever dispatched (handshake phase or still
                // queued): fail closed instead of resurrecting a transitional
                // state. The queued command is discarded by the worker's
                // generation check, so the expired operation cannot run later
                // or report success.
                lifecycleState = .failed
                snapshot = updatedSnapshot(state: .failed, stale: true)
            }
        }
        stateLock.unlock()
        deliverAll(deliveries)
    }

    // MARK: - Worker thread

    /// Pumps at most one command; returns false when the thread should exit.
    /// The idle wait is bounded by `idleWaitSeconds`, and the strong service
    /// binding lives only inside one pump iteration, so a released service can
    /// deallocate instead of being pinned by its parked thread.
    private func workerPump() -> Bool {
        workerCondition.lock()
        if workerCommands.isEmpty && !workerStopRequested {
            workerCondition.wait(until: Date().addingTimeInterval(configuration.idleWaitSeconds))
        }
        if workerStopRequested {
            workerCondition.unlock()
            return false
        }
        guard !workerCommands.isEmpty else {
            // Idle: end this iteration; the loop re-checks the weak reference.
            workerCondition.unlock()
            return true
        }
        let command = workerCommands.removeFirst()
        workerCondition.unlock()
        execute(command)
        return true
    }

    private func enqueueWorker(_ command: WorkerCommand, priority: Bool) -> Bool {
        workerCondition.lock()
        defer { workerCondition.unlock() }
        if !priority && workerCommands.count >= configuration.workerQueueLimit {
            return false
        }
        if priority {
            // Compensating cleanup must precede any queued mutation so a late
            // success cannot leave devices running under a newer start.
            workerCommands.insert(command, at: 0)
        } else {
            workerCommands.append(command)
        }
        workerCondition.signal()
        return true
    }

    private func execute(_ command: WorkerCommand) {
        switch command {
        case .mutate(let op, let intentGeneration):
            guard beginInFlight(op: op, generation: intentGeneration) else {
                // Superseded or expired while queued: no device call on its
                // behalf, and no late success either.
                return
            }
            let success: Bool
            switch op {
            case .start: success = backend.start()
            case .stop:
                backend.stop()
                success = true
            case .reload: success = backend.reload()
            }
            finishInFlight(op: op, generation: intentGeneration, success: success)
        case .snapshot:
            let sampledGeneration = currentGeneration()
            let devices = backend.devices()
            let serviceCount = backend.connectedServiceCount()
            let status = backend.status()
            handleSnapshotResult(
                generation: sampledGeneration,
                devices: devices,
                serviceCount: serviceCount,
                status: status,
                sampledAtNs: clock()
            )
        case .cleanupStop(let cleanedGeneration):
            // A blocking backend call like any other: the worker owns it, the
            // snapshot shows it as pending, and nothing claims .idle until it
            // actually returns.
            backend.stop()
            handleCleanupStopFinished(generation: cleanedGeneration)
        }
    }

    private func beginInFlight(op: IntentOp, generation intentGeneration: UInt64) -> Bool {
        let now = clock()
        stateLock.lock()
        guard let active = activeIntent, !active.isResolved, active.phase == .dispatched,
              active.generation == intentGeneration, active.op == op,
              now < active.deadlineNs, inFlight == nil else {
            stateLock.unlock()
            return false
        }
        // Validation and ownership transfer share a linearization point.
        // Cancellation after this point owns a real in-flight call whose
        // late result must be reconciled; it cannot be a queued resurrection.
        inFlight = InFlight(op: op, generation: intentGeneration)
        stateLock.unlock()
        // Independent timeout observer for this one worker call.
        let deadline = clock() + configuration.mutationBudgetNs
        scheduleDeadline(.mutation, generation: intentGeneration, at: deadline) { [weak self] in
            self?.handleMutationDeadline(generation: intentGeneration)
        }
        return true
    }

    private func handleMutationDeadline(generation intentGeneration: UInt64) {
        var deliveries: [Delivery] = []
        stateLock.lock()
        guard let flight = inFlight, flight.generation == intentGeneration, !flight.timedOut else {
            stateLock.unlock()
            return
        }
        inFlight?.timedOut = true
        // The timed-out call's intent may already have been superseded; a
        // newer generation owns the lifecycle state and must not be rolled
        // back to .timedOut by this older observer.
        if activeIntent?.generation == intentGeneration {
            lifecycleState = .timedOut
            snapshot = updatedSnapshot(state: .timedOut, stale: true)
            if let active = activeIntent, !active.isResolved {
                active.isResolved = true
                deliveries.append(Delivery(completions: active.completions, outcome: .timedOut))
                active.completions = []
            }
        }
        stateLock.unlock()
        deliverAll(deliveries)
    }

    private func finishInFlight(op: IntentOp, generation intentGeneration: UInt64, success: Bool) {
        var deliveries: [Delivery] = []
        var actions: [PostLockAction] = []
        var reconcileState: TouchLifecycleState?
        stateLock.lock()
        guard let flight = inFlight, flight.generation == intentGeneration else {
            stateLock.unlock()
            return
        }
        let active = activeIntent
        let isCurrent = !flight.timedOut && active?.generation == intentGeneration
            && active?.op == op && active?.isResolved == false

        if isCurrent {
            let outcome: TouchLifecycleOutcome
            switch (op, success) {
            case (.start, true): outcome = .started
            case (.stop, true): outcome = .stopped
            case (.reload, true): outcome = .reloaded
            case (_, false): outcome = .failed
            }
            lifecycleState = success ? (op == .stop ? .idle : .running) : .failed
            snapshot = updatedSnapshot(state: lifecycleState, stale: true)
            if let active, !active.isResolved {
                active.isResolved = true
                deliveries.append(Delivery(completions: active.completions, outcome: outcome))
                active.completions = []
            }
            inFlight = nil
            actions.append(.enqueueSnapshot)
        } else {
            // Late result: never auto-ready or re-arm, and never write state
            // over a newer generation. Exactly one compensating stop for a
            // late start/reload success; a late stop success already left the
            // devices down, so only reconcile.
            if !flight.cleanupDone {
                inFlight?.cleanupDone = true
                if success && op != .stop {
                    cleanupStopPending = true
                    snapshot = updatedSnapshot(state: lifecycleState, stale: true)
                    actions.append(.enqueueCleanupStop(generation: intentGeneration))
                }
            }
            if success && op == .stop && lifecycleState == .timedOut
                && generation == intentGeneration {
                reconcileState = .idle
            }
            inFlight = nil
        }
        stateLock.unlock()
        if let reconcileState {
            stateLock.lock()
            if lifecycleState == .timedOut && generation == intentGeneration {
                lifecycleState = reconcileState
                snapshot = updatedSnapshot(state: reconcileState, stale: true)
            }
            stateLock.unlock()
        }
        run(actions)
        deliverAll(deliveries)
    }

    private func handleCleanupStopFinished(generation cleanedGeneration: UInt64) {
        var actions: [PostLockAction] = []
        stateLock.lock()
        cleanupStopPending = false
        snapshot = updatedSnapshot(state: lifecycleState, stale: true)
        // Reconcile only the generation this cleanup belongs to; a newer
        // generation's state is never overwritten by old cleanup work.
        if lifecycleState == .timedOut && generation == cleanedGeneration {
            lifecycleState = .idle
            snapshot = updatedSnapshot(state: .idle, stale: true)
            actions.append(.enqueueSnapshot)
        }
        stateLock.unlock()
        run(actions)
    }

    // MARK: - Snapshot refresh

    private func handleSnapshotResult(
        generation sampledGeneration: UInt64,
        devices newDevices: [TouchDeviceInfo],
        serviceCount: Int,
        status: String,
        sampledAtNs: UInt64
    ) {
        stateLock.lock()
        snapshotQueued = false
        if sampledGeneration == generation {
            // A lifecycle change during sampling bumps the generation; stale
            // results are discarded and never overwrite the newer generation.
            snapshot = TouchRuntimeSnapshot(
                lifecycleState: lifecycleState,
                generation: generation,
                devices: newDevices,
                connectedServiceCount: serviceCount,
                status: status,
                sampledMonotonicNs: sampledAtNs,
                isStale: false,
                cleanupStopInFlight: cleanupStopPending
            )
        }
        stateLock.unlock()
    }

    // MARK: - Shared helpers

    /// At most three live timer registrations belong to this service. Slots
    /// are reserved while validating the generation, before installing the
    /// timer outside the lock. A superseding caller can cancel even an
    /// installation that has not returned yet.
    private func scheduleDeadline(
        _ kind: DeadlineKind, generation intentGeneration: UInt64,
        at deadline: UInt64, body: @escaping @Sendable () -> Void
    ) {
        let slot = TouchDeadlineCancellation()
        stateLock.lock()
        guard let active = activeIntent, active.generation == intentGeneration,
              !active.isResolved else { stateLock.unlock(); return }
        let previous = deadlines.updateValue(slot, forKey: kind)
        stateLock.unlock()
        previous?.cancel()
        let timer = scheduler.scheduleCancellable(deadlineNs: deadline) { [weak self, slot] in
            guard slot.take() else { return }
            if let self {
                self.stateLock.lock()
                if self.deadlines[kind] === slot { self.deadlines[kind] = nil }
                self.stateLock.unlock()
            }
            body()
        }
        slot.install { timer.cancel() }
    }

    private func dispatchMutation(op: IntentOp, generation intentGeneration: UInt64) {
        if !enqueueWorker(.mutate(op: op, generation: intentGeneration), priority: false) {
            var deliveries: [Delivery] = []
            stateLock.lock()
            if let active = activeIntent, active.generation == intentGeneration, !active.isResolved {
                active.isResolved = true
                deliveries.append(Delivery(
                    completions: active.completions,
                    outcome: .rejected(.workerQueueFull)
                ))
                active.completions = []
                // Fail closed, in-lock: no transitional state is resurrected.
                lifecycleState = .failed
                snapshot = updatedSnapshot(state: .failed, stale: true)
            }
            stateLock.unlock()
            deliverAll(deliveries)
        }
    }

    private func run(_ actions: [PostLockAction]) {
        for action in actions {
            switch action {
            case .enqueueMutate(let op, let intentGeneration):
                dispatchMutation(op: op, generation: intentGeneration)
            case .enqueueSnapshot:
                requestSnapshotRefresh()
            case .enqueueCleanupStop(let cleanedGeneration):
                // Priority insert: never dropped, always ahead of queued
                // mutations so cleanup cannot be starved behind new work.
                _ = enqueueWorker(.cleanupStop(generation: cleanedGeneration), priority: true)
            }
        }
    }

    private func deliver(_ delivery: Delivery) {
        for completion in delivery.completions {
            completion(delivery.outcome)
        }
    }

    private func deliverAll(_ deliveries: [Delivery]) {
        for delivery in deliveries { deliver(delivery) }
    }

    /// Caller holds stateLock.
    private func updatedSnapshot(state: TouchLifecycleState, stale: Bool) -> TouchRuntimeSnapshot {
        TouchRuntimeSnapshot(
            lifecycleState: state,
            generation: generation,
            devices: snapshot.devices,
            connectedServiceCount: snapshot.connectedServiceCount,
            status: snapshot.status,
            sampledMonotonicNs: snapshot.sampledMonotonicNs,
            isStale: stale,
            cleanupStopInFlight: cleanupStopPending
        )
    }

    private func currentGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation
    }
}
