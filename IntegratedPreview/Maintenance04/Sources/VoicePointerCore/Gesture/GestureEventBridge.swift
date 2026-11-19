import CoreGraphics
import Foundation

/// Monotonic, non-decreasing timestamp in seconds (DispatchTime/uptime clock).
/// Used for gesture message timestamps, admission heartbeats and staleness
/// checks so a wall-clock change can never reorder input history.
public func monotonicTimestampSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

// MARK: - Message

/// One ordered lifecycle message handed to the single consumer.
///
/// `generation` is the runtime generation the gesture started under; the
/// consumer drops gesture-scoped messages whose generation no longer matches
/// the admission authority (the app advanced it after a device reload,
/// permission loss, timeout abort, etc.). `gestureID == 0` marks
/// monitor-level events (`tapFailure`, monitor-level cancel) which are
/// always delivered.
public struct GestureEventMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case begin(GestureActivation)
        case move(CGPoint)
        case end(CGPoint)
        case cancel
        case tapFailure
    }

    public let generation: UInt64
    public let gestureID: UInt64
    public let sequence: UInt64
    public let timestampSeconds: Double
    public let kind: Kind

    public init(
        generation: UInt64,
        gestureID: UInt64,
        sequence: UInt64,
        timestampSeconds: Double,
        kind: Kind
    ) {
        self.generation = generation
        self.gestureID = gestureID
        self.sequence = sequence
        self.timestampSeconds = timestampSeconds
        self.kind = kind
    }

    public var isTerminal: Bool {
        switch kind {
        case .begin, .move: return false
        case .end, .cancel, .tapFailure: return true
        }
    }
}

// MARK: - Admission

/// Thread-safe snapshot the input thread reads synchronously when deciding
/// whether a physical mouse-down may be claimed. All fields are value-type
/// copies so the tap callback never waits on the main actor.
public struct GestureAdmissionSnapshot: Sendable, Equatable {
    public var enabled: Bool
    public var generation: UInt64
    public var acceptingNewGestures: Bool
    public var permissionsGranted: Bool
    public var lastHeartbeatSeconds: Double

    public init(
        enabled: Bool = true,
        generation: UInt64 = 1,
        acceptingNewGestures: Bool = true,
        permissionsGranted: Bool = true,
        lastHeartbeatSeconds: Double = monotonicTimestampSeconds()
    ) {
        self.enabled = enabled
        self.generation = generation
        self.acceptingNewGestures = acceptingNewGestures
        self.permissionsGranted = permissionsGranted
        self.lastHeartbeatSeconds = lastHeartbeatSeconds
    }

    public func isHeartbeatFresh(
        now: Double,
        tolerance: TimeInterval
    ) -> Bool {
        now >= lastHeartbeatSeconds && now - lastHeartbeatSeconds <= tolerance
    }

    public func canAcceptNewGesture(
        now: Double,
        heartbeatTolerance: TimeInterval
    ) -> Bool {
        guard enabled, acceptingNewGestures, permissionsGranted else { return false }
        return isHeartbeatFresh(now: now, tolerance: heartbeatTolerance)
    }
}

/// Owner of the admission snapshot. Written by the app (main actor or any
/// queue), read synchronously by the input thread.
///
/// Synchronization invariant: every field (`snapshotValue`, `overflowClosed`)
/// is accessed only while holding `lock`. `overflowClosed` is latched by
/// `closeForOverflow()` when the mailbox overflows and is cleared only by
/// the explicit recovery call `clearOverflowLatch()`; `update(_:)`
/// deliberately cannot clear it, so a recovering-but-still-stuck app cannot
/// silently reopen admission.
public final class GestureAdmissionAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotValue: GestureAdmissionSnapshot
    private var overflowClosed = false
    private var heartbeatToleranceValue: TimeInterval = 1.0
    private var gapHandler: (@Sendable () -> Void)?
    /// Latched when the current stale period has already been observed and its
    /// generation advanced — by an independent expiry check
    /// (`consumeHeartbeatExpiry`) or by a gap-aware `recordHeartbeat`. It makes
    /// one dead heartbeat advance the generation exactly once: a repeating
    /// 250 ms watchdog cannot re-advance every tick, and a concurrent recovery
    /// cannot double-advance. Cleared whenever the heartbeat is seen fresh,
    /// arming the next stale period as a new expiry. Guarded by `lock`.
    private var expiryLatched = false

    public init(
        initial: GestureAdmissionSnapshot = GestureAdmissionSnapshot(),
        heartbeatTolerance: TimeInterval = 1.0
    ) {
        self.snapshotValue = initial
        self.heartbeatToleranceValue = heartbeatTolerance
    }

    public func snapshot() -> GestureAdmissionSnapshot {
        lock.withLock { snapshotValue }
    }

    public var heartbeatTolerance: TimeInterval { lock.withLock { heartbeatToleranceValue } }

    func configureHeartbeatTolerance(_ tolerance: TimeInterval) {
        precondition(tolerance > 0 && tolerance.isFinite)
        lock.withLock { heartbeatToleranceValue = tolerance }
    }

    /// Replaces snapshot fields. Cannot clear the overflow latch.
    public func update(_ mutate: (inout GestureAdmissionSnapshot) -> Void) {
        lock.withLock { mutate(&snapshotValue) }
    }

    public func canAcceptNewGesture(
        now: Double,
        heartbeatTolerance: TimeInterval
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowClosed else { return false }
        return snapshotValue.canAcceptNewGesture(
            now: now,
            heartbeatTolerance: heartbeatTolerance
        )
    }

    /// Advances the runtime generation and returns the new value. Old
    /// generation messages are dropped by the consumer; the advancing side is
    /// responsible for revoking its own in-flight transaction.
    @discardableResult
    public func advanceGeneration() -> UInt64 {
        lock.withLock {
            snapshotValue.generation &+= 1
            return snapshotValue.generation
        }
    }

    /// Detects a heartbeat gap and revokes the old generation exactly once.
    ///
    /// If the previous heartbeat was already stale (beyond the configured
    /// tolerance) this call is crossing a gap. When no independent expiry
    /// check has latched that gap yet, `recordHeartbeat` is its first
    /// observer: it advances the generation and fires the gap handler
    /// synchronously — outside the lock — so every old-generation lease and
    /// the host session are revoked before the new validity period begins.
    /// When the watchdog already latched the same gap, the generation is NOT
    /// advanced again and the handler does NOT re-fire, so one gap invalidates
    /// once. Either way the timestamp is refreshed and the latch cleared, so a
    /// future stale period is treated as new. A heartbeat that was already
    /// fresh simply updates the timestamp.
    public func recordHeartbeat(now: Double = monotonicTimestampSeconds()) {
        lock.lock()
        // Concurrent callers may sample before waiting for this lock. Never
        // overwrite a newer heartbeat with a delayed older sample.
        guard now >= snapshotValue.lastHeartbeatSeconds else { lock.unlock(); return }
        let wasFresh = snapshotValue.isHeartbeatFresh(
            now: now,
            tolerance: heartbeatToleranceValue
        )
        snapshotValue.lastHeartbeatSeconds = now
        var handler: (@Sendable () -> Void)?
        if !wasFresh, !expiryLatched {
            snapshotValue.generation &+= 1
            handler = gapHandler
        }
        // Fresh now; arm the latch so the next stale period is a new expiry.
        expiryLatched = false
        lock.unlock()
        handler?()
    }

    /// Atomically observes the heartbeat and, on the FIRST sighting of a new
    /// stale period, advances the generation exactly once and returns the new
    /// value; the caller then fires the session-invalidation and lease-release
    /// hooks OUTSIDE the lock. Returns `nil` when the heartbeat is fresh or
    /// when the current stale period was already latched, so a repeating
    /// watchdog timer can never re-advance the generation every check for one
    /// dead heartbeat.
    ///
    /// `now` is sampled INSIDE the lock on the monotonic clock, which folds
    /// the fresh→stale decision and the generation advance into one atomic
    /// step: a `recordHeartbeat` recovery that wins the lock first is seen as
    /// fresh here, so a stale sample taken before the recovery can never
    /// advance the generation out from under a transaction the host just
    /// rebuilt. This is the single authority both the independent watchdog and
    /// the gap-aware `recordHeartbeat` coordinate through.
    /// - Returns: the new generation when this call observed the expiry, or
    ///   `nil` when there was nothing new to expire.
    @discardableResult
    public func consumeHeartbeatExpiry() -> UInt64? {
        lock.lock()
        let now = monotonicTimestampSeconds()
        // Monotonic + sampled under the lock, so `now >= lastHeartbeatSeconds`;
        // a negative difference (heartbeat recorded after our sample) reads as
        // fresh, never as a spurious expiry of a just-recovered session.
        let fresh = now - snapshotValue.lastHeartbeatSeconds <= heartbeatToleranceValue
        if fresh {
            expiryLatched = false
            lock.unlock()
            return nil
        }
        if expiryLatched {
            // Same dead heartbeat already handled; do not re-advance.
            lock.unlock()
            return nil
        }
        expiryLatched = true
        snapshotValue.generation &+= 1
        let generation = snapshotValue.generation
        lock.unlock()
        return generation
    }

    /// Registers a closure the authority calls synchronously from
    /// `recordHeartbeat` when it detects that the previous heartbeat had
    /// already gone stale. The handler runs on the caller's thread and must
    /// be cheap and thread-safe: revoke leases, advance epochs, never call
    /// AppKit inline. Pass `nil` to unregister.
    public func setHeartbeatGapHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { gapHandler = handler }
    }

    public func closeForOverflow() {
        lock.withLock { overflowClosed = true }
    }

    public func clearOverflowLatch() {
        lock.withLock { overflowClosed = false }
    }

    public var overflowLatched: Bool {
        lock.withLock { overflowClosed }
    }
}

// MARK: - Mailbox

/// Bounded FIFO mailbox with adjacent-move coalescing.
///
/// Synchronization invariant: `buffer`, `reservedTerminal`, `draining` and
/// every statistics counter are accessed only while holding `condition`
/// (used as lock). Producers enqueue terminal (begin/end/cancel/tapFailure)
/// and move messages; adjacent moves replace the pending tail move, and when
/// the buffer is full moves are evicted (in the terminal case) or dropped so
/// terminals always win. If even after evicting every move there is no room,
/// enqueue returns `.overflow` and the producer revokes the current gesture,
/// closes admission, and terminates it through the single reserved terminal
/// slot. Total storage is therefore bounded at `capacity + 1`.
public final class BoundedGestureMailbox: @unchecked Sendable {
    public enum EnqueueOutcome: Sendable, Equatable {
        case accepted
        case coalescedMove
        case droppedMove
        case overflow
        case rejected
    }

    public struct Statistics: Sendable, Equatable {
        public var capacity: Int = 0
        public var pendingCount: Int = 0
        public var accepted: UInt64 = 0
        public var coalescedMoves: UInt64 = 0
        public var droppedMoves: UInt64 = 0
        public var overflowCount: UInt64 = 0
        public var reservedEnqueued: UInt64 = 0
        public var reservedRejected: UInt64 = 0
        public var delivered: UInt64 = 0
        public var rejectedAfterDraining: UInt64 = 0
    }

    private let condition = NSCondition()
    private let capacity: Int
    private var buffer: [GestureEventMessage] = []
    private var reservedTerminal: GestureEventMessage?
    private var draining = false
    private var statistics = Statistics()

    public init(capacity: Int) {
        precondition(capacity >= 1, "mailbox capacity must be positive")
        self.capacity = capacity
        self.statistics.capacity = capacity
    }

    public var isDraining: Bool {
        condition.withLock { draining }
    }

    public func statisticsSnapshot() -> Statistics {
        condition.withLock {
            var copy = statistics
            copy.pendingCount = buffer.count + (reservedTerminal == nil ? 0 : 1)
            return copy
        }
    }

    public func enqueue(_ message: GestureEventMessage) -> EnqueueOutcome {
        condition.lock()
        defer {
            condition.signal()
            condition.unlock()
        }
        if draining {
            statistics.rejectedAfterDraining += 1
            return .rejected
        }
        switch message.kind {
        case .move:
            if let last = buffer.last, case .move = last.kind {
                buffer[buffer.count - 1] = message
                statistics.coalescedMoves += 1
                return .coalescedMove
            }
            if buffer.count >= capacity {
                statistics.droppedMoves += 1
                return .droppedMove
            }
            buffer.append(message)
            statistics.accepted += 1
            return .accepted

        case .begin, .end, .cancel, .tapFailure:
            if buffer.count >= capacity {
                var evicted = 0
                buffer.removeAll { element in
                    if case .move = element.kind {
                        evicted += 1
                        return true
                    }
                    return false
                }
                statistics.droppedMoves += UInt64(evicted)
                if buffer.count >= capacity {
                    statistics.overflowCount += 1
                    return .overflow
                }
            }
            buffer.append(message)
            statistics.accepted += 1
            return .accepted
        }
    }

    /// Single reserved terminal slot used only after an overflow: the gesture
    /// being revoked terminates through here even though the bounded buffer
    /// is full. A second reserved terminal is counted and dropped; after one
    /// overflow admission is closed, so at most one gesture needs it.
    /// Rejected (returning false) once the mailbox is draining, so a stop can
    /// never strand a reserved terminal behind an already-fired completion.
    @discardableResult
    public func enqueueReservedTerminal(_ message: GestureEventMessage) -> Bool {
        condition.lock()
        defer {
            condition.signal()
            condition.unlock()
        }
        if reservedTerminal == nil, !draining {
            reservedTerminal = message
            statistics.reservedEnqueued += 1
            return true
        }
        statistics.reservedRejected += 1
        return false
    }

    /// Blocks up to `timeout` seconds for the next message. Buffer messages
    /// drain first; the reserved terminal is delivered after the buffer is
    /// empty. Returns nil on timeout, or immediately when empty while
    /// draining.
    public func dequeueWaiting(timeout: TimeInterval) -> GestureEventMessage? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !buffer.isEmpty {
                let message = buffer.removeFirst()
                statistics.delivered += 1
                return message
            }
            if let reserved = reservedTerminal {
                reservedTerminal = nil
                statistics.delivered += 1
                return reserved
            }
            if draining { return nil }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            condition.wait(until: deadline)
        }
    }

    /// Switches the mailbox into drain mode: further enqueues are rejected,
    /// the consumer drains what remains and then sees nil.
    public func beginDraining() {
        condition.lock()
        draining = true
        condition.broadcast()
        condition.unlock()
    }
}

// MARK: - Bridge

/// Single ordered consumer. One dedicated thread dequeues messages from the
/// bounded mailbox in FIFO order and invokes `handler` synchronously; a slow
/// handler makes the mailbox fill, which triggers the documented overflow
/// policy (revoke + close admission) instead of dropping terminals or
/// growing without bound. Order of delivery equals order of enqueue.
///
/// Synchronization invariant: `context` is an immutable let shared with the
/// consumer thread; `context.stopping`/`completions`/`running` are accessed
/// only under `context.lock`. Stopping only flips `stopping` and then calls
/// `mailbox.beginDraining()`, so no enqueue can race the final drain.
public final class GestureEventBridge: @unchecked Sendable {
    private final class ConsumerContext: @unchecked Sendable {
        let mailbox: BoundedGestureMailbox
        let handler: @Sendable (GestureEventMessage) -> Void
        let lock = NSLock()
        var stopping = false
        var completions: [@Sendable () -> Void] = []
        var running = true

        init(
            mailbox: BoundedGestureMailbox,
            handler: @escaping @Sendable (GestureEventMessage) -> Void
        ) {
            self.mailbox = mailbox
            self.handler = handler
        }
    }

    private let context: ConsumerContext

    public init(
        capacity: Int,
        handler: @escaping @Sendable (GestureEventMessage) -> Void
    ) {
        let mailbox = BoundedGestureMailbox(capacity: capacity)
        let context = ConsumerContext(mailbox: mailbox, handler: handler)
        self.context = context
        let thread = Thread(block: { [context] in
            Thread.current.name = "VoicePointerGestureConsumer"
            while true {
                if let message = context.mailbox.dequeueWaiting(timeout: 0.05) {
                    context.handler(message)
                    continue
                }
                context.lock.lock()
                let stopping = context.stopping
                context.lock.unlock()
                if stopping { break }
            }
            context.lock.lock()
            context.running = false
            let completions = context.completions
            context.completions = []
            context.lock.unlock()
            for completion in completions {
                DispatchQueue.global().async { completion() }
            }
        })
        thread.name = "VoicePointerGestureConsumer"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    public func enqueue(_ message: GestureEventMessage) -> BoundedGestureMailbox.EnqueueOutcome {
        context.mailbox.enqueue(message)
    }

    @discardableResult
    public func enqueueReservedTerminal(_ message: GestureEventMessage) -> Bool {
        context.mailbox.enqueueReservedTerminal(message)
    }

    public var mailbox: BoundedGestureMailbox { context.mailbox }

    public var isRunning: Bool {
        context.lock.withLock { context.running }
    }

    /// Asynchronous stop: rejects new enqueues, drains everything already
    /// queued (terminals are never silently dropped), then invokes each
    /// completion once on a global queue. Never blocks the calling thread.
    /// Repeat stops are safe: completions registered while the drain is
    /// still in flight are invoked by the consumer thread; completions
    /// arriving after it exited are invoked directly.
    ///
    /// Ordering proof: `beginDraining()` runs BEFORE the consumer can ever
    /// observe `stopping`. From that instant every enqueue (including the
    /// reserved terminal slot) is rejected under the mailbox condition, and
    /// the consumer's nil-return requires an empty buffer plus an empty
    /// reserved slot under that same condition — so once the consumer exits,
    /// nothing it accepted can still be queued, and the completions fire
    /// only after the consumer thread has exited.
    public func stop(completion: (@Sendable () -> Void)? = nil) {
        context.mailbox.beginDraining()
        context.lock.lock()
        let running = context.running
        if running, let completion {
            context.completions.append(completion)
        }
        context.stopping = true
        context.lock.unlock()

        if running { return }
        if let completion {
            DispatchQueue.global().async { completion() }
        }
    }
}

// MARK: - Ordered monitor (new production path)

/// New-production mouse gesture monitor.
///
/// The CGEventTap lives on a dedicated CFRunLoop thread owned by
/// `EventTapWorker`. The tap callback only reads thread-safe snapshots
/// (multitouch driver state, admission snapshot), performs the existing
/// recognition/pairing logic inside `GestureRecognitionCore`, and enqueues
/// ordered `GestureEventMessage`s. One consumer thread delivers them in
/// order to `eventHandler`.
///
/// Do NOT forward each message with `DispatchQueue.main.async` from
/// `eventHandler`: that parks an unbounded backlog on the main queue and the
/// generation may advance between delivery and execution. Wire
/// `GestureMainQueueAdapter` in instead — it keeps the backlog bounded
/// (mailbox + at most `maxInFlight` posted messages) and re-validates
/// session/generation/gestureID/heartbeat at execution time.
///
/// Whether a mouse-down is swallowed is decided synchronously inside the
/// tap callback from the admission snapshot (`admission.canAcceptNewGesture`)
/// — it never waits for the main actor, HUD, AX or device start/stop.
///
/// Start/stop lifecycle: one worker run at a time, guarded by a condition
/// variable. Concurrent `start()` calls merge (the loser waits for the
/// winner instead of installing a second tap); `stop()` covers a start
/// still in flight; a failed start can be retried. `start()` blocks on the
/// bootstrap and must not be called from the main thread — production code
/// uses `startAsync(completion:)`.
///
/// Overflow policy: when the bounded mailbox cannot accept a terminal, the
/// current gesture is revoked at the input layer, admission is closed via
/// `admission.closeForOverflow()`, and the gesture terminates through the
/// single reserved terminal slot. A stopped monitor can no longer observe
/// the physical mouse-up for a down it swallowed; that up will pass to the
/// system unobserved (documented boundary), and the monitor emits a final
/// cancel while stopping so the app can clean up.
///
/// Synchronization invariant for `@unchecked Sendable`: `admission`,
/// `bridgeState`, `bridgeBox`, `core`, `watchdogTimer`, `tapInstaller`,
/// `eventHandler`, `heartbeatTolerance`, `mailboxCapacity` are let-immutable;
/// `bridgeState`, `bridgeBox` and `admission` are internally locked; the
/// core's state is under the core's internal lock. `lifecycleState`,
/// `worker`, `pendingWorker`, `stopRequestedDuringStart` and `stopCompletions` are guarded by
/// `monitorCondition`, which is never held while calling into the worker or
/// the bridge. Lock order is monitorCondition → bridgeBox; nothing ever
/// acquires them in reverse.
public final class OrderedMouseGestureMonitor: @unchecked Sendable {
    private final class BridgeState: @unchecked Sendable {
        // Synchronization invariant: all fields below are accessed only
        // while holding `lock`.
        let lock = NSLock()
        var activeGesture: (id: UInt64, generation: UInt64)?
        var nextGestureID: UInt64 = 1
        var sequence: UInt64 = 0
        var staleDropped: UInt64 = 0
        var delivered: UInt64 = 0

        func allocate(generation: UInt64) -> (id: UInt64, sequence: UInt64) {
            lock.withLock {
                let id = nextGestureID
                nextGestureID += 1
                sequence += 1
                let allocated = sequence
                activeGesture = (id, generation)
                return (id, allocated)
            }
        }

        func clearActive(matchingID: UInt64? = nil) -> (id: UInt64, generation: UInt64)? {
            lock.withLock {
                guard let active = activeGesture else { return nil }
                if let matchingID, active.id != matchingID { return nil }
                activeGesture = nil
                return (id: active.id, generation: active.generation)
            }
        }

        func currentActive() -> (id: UInt64, generation: UInt64)? {
            lock.withLock { activeGesture.map { (id: $0.id, generation: $0.generation) } }
        }

        func nextSequence() -> UInt64 {
            lock.withLock {
                sequence += 1
                return sequence
            }
        }

        func activeGeneration() -> UInt64? {
            lock.withLock { activeGesture?.generation }
        }
    }

    private final class BridgeBox: @unchecked Sendable {
        // Synchronization invariant: `bridge` is accessed only while holding
        // `lock`.
        let lock = NSLock()
        var bridge: GestureEventBridge?

        func enqueue(_ message: GestureEventMessage) -> BoundedGestureMailbox.EnqueueOutcome {
            lock.withLock { bridge?.enqueue(message) ?? .rejected }
        }

        func enqueueReservedTerminal(_ message: GestureEventMessage) {
            lock.withLock { _ = bridge?.enqueueReservedTerminal(message) }
        }

        func replace(_ bridge: GestureEventBridge?) {
            lock.withLock { self.bridge = bridge }
        }

        func currentBridge() -> GestureEventBridge? {
            lock.withLock { bridge }
        }

        /// Removes the current bridge from the box and stops it. The stop
        /// chain calls this only AFTER `core.cancelActiveGesture()` has
        /// enqueued the final cancel, and no new run can begin until
        /// `finishStop()` has run, so the bridge removed here is always the
        /// one this run created — an older run's cleanup can never stop a
        /// newer run's bridge.
        func stopCurrent(completion: (@Sendable () -> Void)?) {
            lock.lock()
            let current = bridge
            bridge = nil
            lock.unlock()
            if let current {
                current.stop(completion: completion)
            } else if let completion {
                DispatchQueue.global().async { completion() }
            }
        }

        func currentMailboxStatistics() -> BoundedGestureMailbox.Statistics? {
            lock.withLock { bridge?.mailbox.statisticsSnapshot() }
        }
    }

    /// Lifecycle of the worker thread. `idle` means no run is in flight —
    /// not "the monitor is off": the consumer bridge may still exist.
    private enum MonitorLifecycle: Equatable {
        case idle
        case starting
        case running
        case stopping
    }

    public let admission: GestureAdmissionAuthority
    private let core: GestureRecognitionCore
    private let bridgeState: BridgeState
    private let bridgeBox: BridgeBox
    private let monitorCondition = NSCondition()
    private var lifecycleState: MonitorLifecycle = .idle
    private var worker: EventTapWorker?
    private var pendingWorker: EventTapWorker?
    private var stopRequestedDuringStart = false
    private var stopCompletions: [@Sendable () -> Void] = []
    private let tapInstaller: EventTapInstaller
    private let eventHandler: @Sendable (GestureEventMessage) -> Void
    private let heartbeatTolerance: TimeInterval
    private let watchdogTimer: DispatchSourceTimer
    private let watchdogQueue = DispatchQueue(label: "com.kenyu.VoicePointer.gesture-heartbeat-watchdog")
    private let mailboxCapacity: Int
    private let bootstrapTimeout: TimeInterval

    /// Longest a merged start() waits for an in-flight start/stop to settle
    /// before reporting an explicit failure (bootstrap is bounded at 10 s by
    /// the worker; the bridge drain of a bounded mailbox is fast).
    private static let mergeWaitTimeout: TimeInterval = 30

    public convenience init(
        driver: MultitouchDriver,
        configuration: GestureConfiguration,
        admission: GestureAdmissionAuthority? = nil,
        eventHandler: @escaping @Sendable (GestureEventMessage) -> Void,
        heartbeatTolerance: TimeInterval = 1.0,
        heartbeatWatchdogInterval: TimeInterval = 0.25,
        mailboxCapacity: Int = 128
    ) {
        self.init(
            configuration: configuration,
            touchDevices: { driver.devices },
            consumeEligibleGesture: { configuration in
                driver.consumeEligibleGesture(configuration: configuration)
            },
            directionalDisplacement: { token in
                driver.directionalDisplacement(deviceToken: token)
            },
            admission: admission,
            eventHandler: eventHandler,
            heartbeatTolerance: heartbeatTolerance,
            heartbeatWatchdogInterval: heartbeatWatchdogInterval,
            mailboxCapacity: mailboxCapacity,
            recordDown: { button, c in
                guard !driver.isTestingTouchState else { return }
                driver.recordLatestMouseDown(button: button, configuration: c, recorder: TouchSampleRecorder.shared)
            },
            recordUp: { button in
                guard !driver.isTestingTouchState else { return }
                TouchSampleRecorder.shared.recordUp(button: button)
            },
            configureRecording: {
                guard !driver.isTestingTouchState else { return }
                TouchSampleRecorder.shared.configure($0)
            },
            decisionTrace: { driver.mouseDecisionTrace }
        )
    }

    /// Testing seam: injects the touch-state providers (and optionally the
    /// tap installer and a shared admission authority) instead of reading a
    /// real `MultitouchDriver`, so pure-simulation stress tests can drive
    /// tens of thousands of gesture cycles without loading the private
    /// framework and without creating a real event tap.
    @_spi(Testing)
    public init(
        configuration: GestureConfiguration,
        touchDevices: @escaping @Sendable () -> [TouchDeviceInfo],
        consumeEligibleGesture: @escaping @Sendable (GestureConfiguration) -> GestureMatch?,
        directionalDisplacement: @escaping @Sendable (UInt) -> CGPoint?,
        admission externalAdmission: GestureAdmissionAuthority? = nil,
        eventHandler: @escaping @Sendable (GestureEventMessage) -> Void,
        heartbeatTolerance: TimeInterval = 1.0,
        heartbeatWatchdogInterval: TimeInterval = 0.25,
        mailboxCapacity: Int = 128,
        tapInstaller: EventTapInstaller? = nil,
        bootstrapTimeout: TimeInterval = 10,
        recordDown: @escaping @Sendable (PhysicalMouseButton, GestureConfiguration) -> Void = { _, _ in },
        recordUp: @escaping @Sendable (PhysicalMouseButton) -> Void = { _ in },
        configureRecording: @escaping @Sendable (GestureConfiguration) -> Void = { _ in },
        decisionTrace: @escaping @Sendable () -> String = { "" }
    ) {
        let admission = externalAdmission ?? GestureAdmissionAuthority()
        let bridgeState = BridgeState()
        let bridgeBox = BridgeBox()
        let appHandler = eventHandler
        let tolerance = heartbeatTolerance
        let capacity = mailboxCapacity
        let mask = OrderedMouseGestureMonitor.combinedEventMask()

        let emit: @Sendable (GestureRecognitionCore.GestureEmission) -> Bool = { emission in
            let timestamp = monotonicTimestampSeconds()
            let message: GestureEventMessage
            switch emission {
            case .began(let activation):
                let generation = admission.snapshot().generation
                let allocated = bridgeState.allocate(generation: generation)
                message = GestureEventMessage(
                    generation: generation,
                    gestureID: allocated.id,
                    sequence: allocated.sequence,
                    timestampSeconds: timestamp,
                    kind: .begin(activation)
                )
            case .moved(let location):
                guard let active = bridgeState.currentActive() else { return true }
                message = GestureEventMessage(
                    generation: active.generation,
                    gestureID: active.id,
                    sequence: bridgeState.nextSequence(),
                    timestampSeconds: timestamp,
                    kind: .move(location)
                )
            case .ended(let location):
                if let active = bridgeState.clearActive() {
                    message = GestureEventMessage(
                        generation: active.generation,
                        gestureID: active.id,
                        sequence: bridgeState.nextSequence(),
                        timestampSeconds: timestamp,
                        kind: .end(location)
                    )
                } else {
                    return true
                }
            case .canceled:
                if let active = bridgeState.clearActive() {
                    message = GestureEventMessage(
                        generation: active.generation,
                        gestureID: active.id,
                        sequence: bridgeState.nextSequence(),
                        timestampSeconds: timestamp,
                        kind: .cancel
                    )
                } else {
                    message = GestureEventMessage(
                        generation: admission.snapshot().generation,
                        gestureID: 0,
                        sequence: bridgeState.nextSequence(),
                        timestampSeconds: timestamp,
                        kind: .cancel
                    )
                }
            case .tapFailed:
                message = GestureEventMessage(
                    generation: admission.snapshot().generation,
                    gestureID: 0,
                    sequence: bridgeState.nextSequence(),
                    timestampSeconds: timestamp,
                    kind: .tapFailure
                )
            }

            if bridgeBox.enqueue(message) == .overflow {
                // Bounded overflow policy: revoke the current gesture at the
                // input layer, close admission, terminate through the
                // reserved terminal slot.
                admission.closeForOverflow()
                _ = bridgeState.clearActive(matchingID: message.gestureID)
                bridgeBox.enqueueReservedTerminal(
                    GestureEventMessage(
                        generation: message.generation,
                        gestureID: message.gestureID,
                        sequence: bridgeState.nextSequence(),
                        timestampSeconds: monotonicTimestampSeconds(),
                        kind: .cancel
                    )
                )
                return false
            }
            return true
        }

        let core = GestureRecognitionCore(
            configuration: configuration,
            timerQueue: DispatchQueue(label: "com.kenyu.VoicePointer.gesture-trackpad-tracking"),
            touchDevices: touchDevices,
            consumeEligibleGesture: consumeEligibleGesture,
            directionalDisplacement: directionalDisplacement,
            claimBegin: { _ in
                admission.canAcceptNewGesture(
                    now: monotonicTimestampSeconds(),
                    heartbeatTolerance: tolerance
                )
            },
            emit: emit,
            trace: { RuntimeTrace.record($0) },
            recordDown: recordDown, recordUp: recordUp, configureRecording: configureRecording, decisionTrace: decisionTrace
        )

        bridgeBox.replace(GestureEventBridge(
            capacity: capacity,
            handler: Self.makeDeliverClosure(
                admission: admission,
                bridgeState: bridgeState,
                appHandler: appHandler
            )
        ))

        let interval = max(0.01, heartbeatWatchdogInterval)
        let watchdogTimer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        watchdogTimer.schedule(deadline: .now() + interval, repeating: interval)
        watchdogTimer.setEventHandler { [weak core] in
            guard let core else { return }
            let snapshot = admission.snapshot()
            let now = monotonicTimestampSeconds()
            let heartbeatStale = !snapshot.enabled
                || !snapshot.isHeartbeatFresh(now: now, tolerance: tolerance)
            if let activeGeneration = bridgeState.activeGeneration() {
                if heartbeatStale || activeGeneration != snapshot.generation {
                    core.cancelActiveGesture()
                }
            }
        }
        watchdogTimer.resume()

        self.eventHandler = eventHandler
        self.heartbeatTolerance = heartbeatTolerance
        self.admission = admission
        self.bridgeState = bridgeState
        self.bridgeBox = bridgeBox
        self.tapInstaller = tapInstaller ?? { runLoop, callback, userInfo in
            OrderedMouseGestureMonitor.makeTapInstallation(
                runLoop: runLoop,
                eventMask: mask,
                callback: callback,
                userInfo: userInfo
            )
        }
        self.mailboxCapacity = mailboxCapacity
        self.bootstrapTimeout = bootstrapTimeout
        self.core = core
        self.watchdogTimer = watchdogTimer
    }

    deinit {
        watchdogTimer.cancel()
        core.cancelActiveGesture()
        worker?.stop()
        pendingWorker?.stop()
        bridgeBox.stopCurrent(completion: nil)
    }

    public func update(configuration: GestureConfiguration) {
        core.update(configuration: configuration)
    }

    public func setEnabled(_ enabled: Bool) {
        admission.update { $0.enabled = enabled }
        if !enabled {
            core.cancelActiveGesture()
        }
    }

    /// Starts the event tap on its dedicated CFRunLoop thread.
    ///
    /// COMPATIBILITY ENTRY: this call blocks until the worker's bootstrap
    /// resolves — up to ~10 s when the system is wedged — so it must never
    /// be called from the main thread. Production code should use the
    /// non-blocking `startAsync(completion:)`.
    ///
    /// Concurrency: a start already in flight is merged (this call waits for
    /// it and returns the same outcome instead of installing a second tap);
    /// a stop in flight is waited out. A failed start leaves the monitor
    /// idle so it can be retried.
    public func start() throws {
        monitorCondition.lock()
        while true {
            switch lifecycleState {
            case .running:
                monitorCondition.unlock()
                return
            case .starting, .stopping:
                // Merge with the in-flight start / wait out the in-flight
                // stop. A stopped run settles to .idle, where this caller
                // retries with its own worker.
                if !monitorCondition.wait(until: Date().addingTimeInterval(Self.mergeWaitTimeout)) {
                    monitorCondition.unlock()
                    throw MouseGestureMonitorError.eventTapUnavailable
                }
            case .idle:
                lifecycleState = .starting
                stopRequestedDuringStart = false
                if bridgeBox.currentBridge() == nil {
                    bridgeBox.replace(makeBridge())
                }
                // Created under the lock so a concurrent stop() can reach the
                // bootstrap through `pendingWorker` and ask it to skip enable.
                let newWorker = EventTapWorker(
                    installer: tapInstaller,
                    eventHandler: { [weak self] type, event in
                        guard let self else { return Unmanaged.passUnretained(event) }
                        return self.handleTapEvent(type: type, event: event)
                    }
                )
                pendingWorker = newWorker
                monitorCondition.broadcast()
                monitorCondition.unlock()

                do {
                    try newWorker.start(bootstrapTimeout: bootstrapTimeout)
                } catch {
                    // Two failure shapes with opposite ownership rules.
                    let workerState = newWorker.currentState
                    if workerState == .stopped || workerState == .idle {
                        // Resolved failure (nil installer, failed bootstrap):
                        // the worker guarantees its teardown finished BEFORE
                        // start() returned, so it owns no resources and
                        // ownership can be released right now.
                        monitorCondition.lock()
                        pendingWorker = nil
                        let requestedStop = stopRequestedDuringStart
                        if lifecycleState == .starting {
                            lifecycleState = requestedStop ? .stopping : .idle
                        }
                        monitorCondition.broadcast()
                        monitorCondition.unlock()
                        if requestedStop {
                            // The failed bootstrap still owes the stop its
                            // full teardown: cancel + bridge drain + completions.
                            runStopChain(worker: nil)
                        }
                        throw error
                    }
                    // Bootstrap timeout: the worker thread is STILL inside
                    // the installer — nothing has been torn down. Dropping
                    // ownership here (R2's bug) would let a second worker
                    // overlap the wedged install and let stop completions
                    // promise a cleanup that has not happened. Keep the
                    // worker, park the monitor in .stopping, and drive the
                    // real teardown through the worker's stop completion;
                    // only that chain's finishStop returns the monitor to
                    // .idle, where a retry may create a new worker.
                    monitorCondition.lock()
                    if lifecycleState == .starting {
                        lifecycleState = .stopping
                    }
                    monitorCondition.broadcast()
                    monitorCondition.unlock()
                    newWorker.stop { [self] in
                        monitorCondition.lock()
                        if pendingWorker === newWorker {
                            pendingWorker = nil
                        }
                        monitorCondition.unlock()
                        // A stop requested while starting already registered
                        // its completion; this chain drains it after the real
                        // bridge teardown, exactly once.
                        runStopChain(worker: nil)
                    }
                    throw error
                }

                monitorCondition.lock()
                guard lifecycleState == .starting else {
                    // Only a stop transitions .starting; it already owns this
                    // worker's teardown.
                    monitorCondition.unlock()
                    return
                }
                worker = newWorker
                pendingWorker = nil
                let stopRequested = stopRequestedDuringStart
                lifecycleState = stopRequested ? .stopping : .running
                monitorCondition.broadcast()
                monitorCondition.unlock()
                if stopRequested {
                    runStopChain(worker: newWorker)
                }
                return
            }
        }
    }

    /// Non-blocking production entry point: performs the bootstrap on a
    /// global queue — never the main thread — and reports the outcome on a
    /// global queue. Concurrent calls go through the same lifecycle state
    /// machine as `start()` (merged, never double-installing).
    public func startAsync(completion: @escaping @Sendable (_ error: (any Error)?) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try start()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Asynchronous stop: never blocks the calling (e.g. main) thread. Stops
    /// accepting events (a stop requested while starting is honored as soon
    /// as the bootstrap resolves), emits a final cancel for any gesture whose
    /// down was swallowed, drains the mailbox so every queued terminal is
    /// delivered, then invokes each stop completion exactly once.
    ///
    /// The stop covers in-flight starts, and the old run's completion cannot
    /// stop a newer run's bridge: a new run may only begin after `finishStop`
    /// has returned the monitor to `.idle`, which happens after the old
    /// bridge has fully drained.
    public func stop(completion: (@Sendable () -> Void)? = nil) {
        monitorCondition.lock()
        switch lifecycleState {
        case .idle:
            if bridgeBox.currentBridge() == nil {
                monitorCondition.unlock()
                core.cancelActiveGesture()
                if let completion {
                    DispatchQueue.global().async { completion() }
                }
                return
            }
            if let completion { stopCompletions.append(completion) }
            lifecycleState = .stopping
            monitorCondition.broadcast()
            monitorCondition.unlock()
            runStopChain(worker: nil)
        case .starting:
            if let completion { stopCompletions.append(completion) }
            stopRequestedDuringStart = true
            let pending = pendingWorker
            monitorCondition.unlock()
            // Forward the stop into the bootstrap so the tap is never enabled;
            // the completion itself is fired by finishStop() after the drain.
            pending?.stop()
        case .running:
            if let completion { stopCompletions.append(completion) }
            let currentWorker = worker
            worker = nil
            lifecycleState = .stopping
            monitorCondition.broadcast()
            monitorCondition.unlock()
            runStopChain(worker: currentWorker)
        case .stopping:
            if let completion { stopCompletions.append(completion) }
            monitorCondition.unlock()
        }
    }

    /// Drives the full asynchronous stop of the current run: worker teardown
    /// (when there is one), core cancel (so the final cancel message is
    /// enqueued while the bridge is still the live one), bridge drain, then
    /// back to `.idle` with every registered stop completion fired exactly
    /// once. Holds no lock while calling into the worker or the bridge.
    private func runStopChain(worker stoppedWorker: EventTapWorker?) {
        let core = self.core
        let bridgeBox = self.bridgeBox
        let finish: @Sendable () -> Void = {
            core.cancelActiveGesture()
            bridgeBox.stopCurrent(completion: { self.finishStop() })
        }
        if let stoppedWorker {
            stoppedWorker.stop { finish() }
        } else {
            finish()
        }
    }

    private func finishStop() {
        monitorCondition.lock()
        let completions = stopCompletions
        stopCompletions = []
        if lifecycleState == .stopping {
            lifecycleState = .idle
        }
        monitorCondition.broadcast()
        monitorCondition.unlock()
        for completion in completions {
            DispatchQueue.global().async { completion() }
        }
    }

    private func makeBridge() -> GestureEventBridge {
        GestureEventBridge(
            capacity: mailboxCapacity,
            handler: Self.makeDeliverClosure(
                admission: admission,
                bridgeState: bridgeState,
                appHandler: eventHandler
            )
        )
    }

    // MARK: - Tap event entry point

    /// Tap-callback entry: pre-flight admission checks then the shared
    /// recognition core. Runs on the worker thread only.
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        preEventAdmissionChecks()
        return core.process(type: type, event: event)
    }

    private func preEventAdmissionChecks() {
        let snapshot = admission.snapshot()
        guard let activeGeneration = bridgeState.activeGeneration() else { return }
        let now = monotonicTimestampSeconds()
        let generationAdvanced = snapshot.generation != activeGeneration
        let heartbeatStale = !snapshot.isHeartbeatFresh(now: now, tolerance: heartbeatTolerance)
        if generationAdvanced || heartbeatStale {
            core.cancelActiveGesture()
        }
    }

    /// Consumer-side generation filter: gesture-scoped messages whose
    /// generation no longer matches admission are counted and dropped;
    /// everything else (and every monitor-level message) is delivered.
    private static func makeDeliverClosure(
        admission: GestureAdmissionAuthority,
        bridgeState: BridgeState,
        appHandler: @escaping @Sendable (GestureEventMessage) -> Void
    ) -> @Sendable (GestureEventMessage) -> Void {
        { message in
            if message.gestureID != 0,
               message.generation != admission.snapshot().generation {
                bridgeState.lock.lock()
                bridgeState.staleDropped += 1
                bridgeState.lock.unlock()
                return
            }
            bridgeState.lock.lock()
            bridgeState.delivered += 1
            bridgeState.lock.unlock()
            appHandler(message)
        }
    }

    private static func combinedEventMask() -> CGEventMask {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .mouseMoved,
            .scrollWheel,
            .keyDown,
        ]
        let namedMask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        return GestureRecognitionCore.systemGestureEventRawTypes.reduce(namedMask) {
            $0 | (CGEventMask(1) << $1)
        }
    }

    private static func makeTapInstallation(
        runLoop: CFRunLoop,
        eventMask: CGEventMask,
        callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer
    ) -> EventTapInstallation? {
        // The handle is only touched on the worker thread (create, enable,
        // disable, invalidate, release happen there in order); @unchecked
        // carries that single-thread ownership across the Sendable closures.
        final class TapHandle: @unchecked Sendable {
            let tap: CFMachPort
            let source: CFRunLoopSource
            init(tap: CFMachPort, source: CFRunLoopSource) {
                self.tap = tap
                self.source = source
            }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: userInfo
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }
        let handle = TapHandle(tap: tap, source: source)
        return EventTapInstallation(
            source: source,
            enable: { CGEvent.tapEnable(tap: handle.tap, enable: true) },
            disable: { CGEvent.tapEnable(tap: handle.tap, enable: false) },
            teardown: {
                CFMachPortInvalidate(handle.tap)
            }
        )
    }

    // MARK: - Testing

    /// Exercises the same recognition + enqueue path the tap callback uses,
    /// without creating a real event tap.
    @_spi(Testing)
    public func processEventForTesting(type: CGEventType, event: CGEvent) -> Bool {
        handleTapEvent(type: type, event: event) == nil
    }

    @_spi(Testing)
    public func processTrackpadMotionForTesting() {
        core.emitTrackpadMovement()
    }

    @_spi(Testing)
    public var mailboxStatistics: BoundedGestureMailbox.Statistics {
        bridgeBox.currentMailboxStatistics() ?? BoundedGestureMailbox.Statistics()
    }

    @_spi(Testing)
    public var deliveryStatistics: (delivered: UInt64, staleDropped: UInt64) {
        bridgeState.lock.lock()
        defer { bridgeState.lock.unlock() }
        return (bridgeState.delivered, bridgeState.staleDropped)
    }

    @_spi(Testing)
    public var isRunningForTesting: Bool {
        monitorCondition.withLock { lifecycleState == .running }
    }

    @_spi(Testing)
    public var isIdleForTesting: Bool {
        monitorCondition.withLock { lifecycleState == .idle }
    }

    /// Whether the consumer bridge still exists (false once a stop chain has
    /// drained it; a later start creates a fresh bridge).
    @_spi(Testing)
    public var hasLiveBridgeForTesting: Bool {
        bridgeBox.currentBridge() != nil
    }
}

// MARK: - Bounded main-thread consumption

/// Session-scoped cancellation token for UI-side gesture state.
///
/// `invalidate()` runs synchronously on the calling thread and touches
/// nothing but its own lock: it never queues behind the busy UI executor or
/// the monitor's consumer. It bumps the session epoch, forgets the tracked
/// active gesture and invokes the reset hook — which is what clears any UI
/// state a dropped terminal would otherwise leave behind (a released
/// gesture can never be stranded in the "held" state). Messages validated
/// against an older epoch are dead the moment `invalidate()` returns, and
/// the next gesture under the new epoch flows without any explicit unlock.
public final class GestureSessionToken: @unchecked Sendable {
    private let lock = NSLock()
    private let admission: GestureAdmissionAuthority
    private var activeGestureID: UInt64 = 0
    private var activeGestureGeneration: UInt64 = 0
    private var releasedCount: UInt64 = 0
    private let onSessionInvalidated: (@Sendable () -> Void)?
    private let onGestureDropped: (@Sendable (UInt64) -> Void)?

    /// - Parameters:
    ///   - admission: the shared authority whose `generation` IS the session
    ///     epoch. Messages are stamped with this generation at input time;
    ///     invalidation advances it so backlogged messages from the old
    ///     generation are rejected at the consumer.
    ///   - onSessionInvalidated: synchronous hook fired on whichever thread
    ///     calls `invalidate()`. Must be cheap and thread-safe.
    ///   - onGestureDropped: synchronous hook fired exactly once per gesture
    ///     when the lease is released (heartbeat gap, expired transaction,
    ///     invalidation). Must be cheap and thread-safe.
    public init(
        admission: GestureAdmissionAuthority,
        onSessionInvalidated: (@Sendable () -> Void)? = nil,
        onGestureDropped: (@Sendable (UInt64) -> Void)? = nil
    ) {
        self.admission = admission
        self.onSessionInvalidated = onSessionInvalidated
        self.onGestureDropped = onGestureDropped
    }

    /// The session epoch — delegated to the shared admission authority so
    /// every message and every invalidation speak the same identity.
    public var epoch: UInt64 {
        admission.snapshot().generation
    }

    /// Gesture the UI side currently holds (0 when none).
    public var trackedGestureID: UInt64 {
        lock.withLock { activeGestureID }
    }

    /// Total gestures released through this token (all paths: gap handler,
    /// expired transaction, invalidation).
    public var releasedGesturesCount: UInt64 {
        lock.withLock { releasedCount }
    }

    /// Invalidates the session: advances the shared admission generation
    /// (killing every backlogged message from the old generation), clears
    /// the tracked gesture lease, and fires both hooks synchronously.
    public func invalidate() {
        admission.advanceGeneration()
        lock.lock()
        activeGestureID = 0
        activeGestureGeneration = 0
        lock.unlock()
        onSessionInvalidated?()
    }

    func beginGesture(id: UInt64, generation: UInt64) {
        lock.withLock {
            activeGestureID = id
            activeGestureGeneration = generation
        }
    }

    /// Clears the tracked gesture when `id` is the one currently held.
    /// - Returns: `true` only when this call was the one that released the
    ///   gesture — the caller that receives `true` owns the release (and any
    ///   exactly-once notification tied to it); `false` means someone else
    ///   already released it or it never matched.
    @discardableResult
    func endGesture(id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGestureID == id else { return false }
        activeGestureID = 0
        activeGestureGeneration = 0
        return true
    }

    /// Releases every tracked gesture whose generation is older than
    /// `generation`. Called by the heartbeat gap handler and the expiry
    /// watchdog to revoke leases from the previous generation without
    /// disturbing a gesture that started under the new one.
    /// - Returns: the number of gestures actually released.
    @discardableResult
    func releaseGestures(olderThanGeneration generation: UInt64) -> UInt64 {
        lock.lock()
        guard activeGestureID != 0, activeGestureGeneration < generation else {
            lock.unlock()
            return 0
        }
        let droppedID = activeGestureID
        activeGestureID = 0
        activeGestureGeneration = 0
        releasedCount += 1
        let dropHook = onGestureDropped
        lock.unlock()
        dropHook?(droppedID)
        return 1
    }

    /// Handles a newly-observed heartbeat expiry whose generation was already
    /// advanced atomically by the authority (`consumeHeartbeatExpiry`, or the
    /// gap-aware `recordHeartbeat`). Releases any lease from an older
    /// generation — exactly once, firing `onGestureDropped` — AND fires the
    /// session-invalidation hook REGARDLESS of whether a physical gesture was
    /// still held.
    ///
    /// That unconditional session hook is the REVISION-5 §1 fix: when the
    /// terminal `end` was already consumed, `endGesture` cleared
    /// `trackedGestureID` back to 0, so there is no lease left for
    /// `releaseGestures` to notify through — yet the host may still have an
    /// independent operation token in flight (an async text transaction awaiting
    /// IME for up to ~3 s). Firing `onSessionInvalidated` here is what lets the
    /// host cancel that token even though the gesture lease is already gone.
    /// Both hooks run outside the token lock.
    func handleHeartbeatExpiry(olderThanGeneration generation: UInt64) {
        releaseGestures(olderThanGeneration: generation)
        onSessionInvalidated?()
    }

    func isActiveGesture(id: UInt64) -> Bool {
        lock.withLock { activeGestureID == id }
    }
}

/// Bounded single-consumer dispatcher from the ordered gesture bridge to a
/// UI thread (the main thread in production).
///
/// Wire `handle(_:)` as the monitor's `eventHandler` (and pass the monitor's
/// `admission` here so both sides share one authority). The monitor's
/// consumer thread calls `handle` in order; each message is re-validated
/// (session epoch, runtime generation, gesture liveness, heartbeat and its
/// own validity window) and then handed to `execute` with at most
/// `maxInFlight` messages outstanding. Unlike a per-message
/// `DispatchQueue.main.async` — which parks an unbounded backlog on the main
/// queue and lets stale begins/ends execute — the adapter applies
/// backpressure: when the UI is busy the consumer thread blocks on the
/// in-flight slots, the bounded mailbox fills, moves coalesce and the
/// documented overflow policy takes over. The total backlog is therefore
/// always bounded: `mailbox.pendingCount + inFlight ≤ capacity + 1 + maxInFlight`.
///
/// Transaction liveness: every message is re-checked at execution time, not
/// just begins — a heartbeat that expired (even if it later recovered) or a
/// message older than its validity window kills the transaction it belongs
/// to. A killed transaction is released exactly once through the
/// thread-safe `sessionToken` lease plus the synchronous `onGestureDropped`
/// hook, from whichever thread detected the death (the consumer thread for
/// post-time drops, the UI executor for execution-time drops) — the release
/// never waits for the main thread to recover, and the hook must stay cheap
/// and thread-safe: modify the lease, schedule UI work, never call AppKit
/// inline from a background thread. A released transaction cannot be revived
/// by a later heartbeat refresh: its terminal fails the gesture-liveness
/// check. `execute` is the commit point — the side effect runs only after all
/// final validity checks pass, and an already-committed Send is not promised
/// to be retractable.
///
/// `execute` runs on the UI executor and must NOT run whole focus/text
/// transactions inline: synchronously start the controlled task and return,
/// so later release/cancel messages keep flowing while the task is in
/// flight. Invalidating `sessionToken` is synchronous from any thread and
/// immediately kills every message validated under the previous epoch.
public final class GestureMainQueueAdapter: @unchecked Sendable {
    public struct Statistics: Sendable, Equatable {
        public var posted = 0
        public var executed = 0
        public var droppedStaleGeneration = 0
        public var droppedStaleHeartbeat = 0
        public var droppedInvalidSession = 0
        public var droppedQueueTimeout = 0
        public var skippedAtExecution = 0
        public var releasedExpiredGestures = 0
        public var inFlight = 0
    }

    public let sessionToken: GestureSessionToken
    private let admission: GestureAdmissionAuthority
    private let heartbeatTolerance: TimeInterval
    private let messageValidityWindow: TimeInterval
    private let slots: DispatchSemaphore
    private let maxInFlight: Int
    private let onGestureDropped: (@Sendable (UInt64) -> Void)?
    private let uiExecutor: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let execute: (@Sendable (GestureEventMessage) -> Void)?
    private let executeOnMainActor: (@MainActor @Sendable (GestureEventMessage) -> Void)?
    private let stateLock = NSLock()
    private var statistics = Statistics()
    private let expiryWatchdog: GestureHeartbeatExpiryWatchdog?

    /// - Parameters:
    ///   - admission: the same authority the monitor consults (generations
    ///     and heartbeats are shared truth).
    ///   - maxInFlight: hard cap on messages posted to the UI executor but
    ///     not yet finished.
    ///   - messageValidityWindow: how old (seconds, by the monotonic clock
    ///     the message timestamps use) a message may be when it executes
    ///     before its transaction is considered dead. Defaults to
    ///     `heartbeatTolerance`, so a message is only ever as long-lived as
    ///     the freshness budget the session itself uses; tests inject small
    ///     windows (and small timestamps) to stay deterministic without
    ///     sleeping or inflating the production thresholds.
    ///   - expiryCheckInterval: how often the independent expiry watchdog
    ///     checks for a stale heartbeat and releases the held gesture lease.
    ///     `nil` disables the watchdog (for tests that isolate other
    ///     mechanisms). Defaults to 0.25 s.
    ///   - onSessionInvalidated: synchronous hook fired on whichever thread
    ///     invalidates the session token — via `sessionToken.invalidate()`, or
    ///     via a newly-observed heartbeat expiry (independent watchdog / gap
    ///     recovery) even when no gesture lease remains (REVISION-5 §1). Must
    ///     be cheap and thread-safe.
    ///   - onGestureDropped: synchronous hook fired exactly once per
    ///     transaction when it dies (heartbeat expired or message past its
    ///     validity window), on whichever thread detected the death — the
    ///     consumer thread or the UI executor. Must be cheap and
    ///     thread-safe: modify a lease / schedule UI work; never call
    ///     AppKit inline from a background thread.
    ///   - uiExecutor: how a validated message is posted to the UI thread.
    ///     Defaults to `DispatchQueue.main.async`; tests inject a serial
    ///     queue.
    ///   - execute: runs on the UI executor; must be quick — start the
    ///     controlled task, do not await it.
    public convenience init(
        admission: GestureAdmissionAuthority,
        heartbeatTolerance: TimeInterval? = nil,
        maxInFlight: Int = 4,
        messageValidityWindow: TimeInterval? = nil,
        expiryCheckInterval: TimeInterval? = 0.25,
        onSessionInvalidated: (@Sendable () -> Void)? = nil,
        onGestureDropped: (@Sendable (UInt64) -> Void)? = nil,
        uiExecutor: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil,
        execute: @escaping @Sendable (GestureEventMessage) -> Void
    ) {
        self.init(
            admission: admission,
            heartbeatTolerance: heartbeatTolerance,
            maxInFlight: maxInFlight,
            messageValidityWindow: messageValidityWindow,
            expiryCheckInterval: expiryCheckInterval,
            onSessionInvalidated: onSessionInvalidated,
            onGestureDropped: onGestureDropped,
            uiExecutor: uiExecutor,
            execute: execute,
            executeOnMainActor: nil
        )
    }

    /// Type-safe MainActor consumption entry (REVISION-5 §2). The host hands a
    /// `@MainActor @Sendable (GestureEventMessage) -> Void` closure and the
    /// adapter runs the FULL generation / heartbeat / validity-window /
    /// gesture-liveness validation at the real MainActor execution point,
    /// calling the closure there — no `MainActor.assumeIsolated`, no
    /// `unsafeBitCast`, no bypassed actor check.
    ///
    /// The in-flight slot is acquired on the consumer thread BEFORE the Task is
    /// created and released only AFTER the closure returns on the MainActor, so
    /// the single fixed-capacity semaphore covers each message's whole
    /// lifecycle and `maxInFlight` truly bounds concurrency. One Task per
    /// message is compliant precisely because of that coverage; with
    /// `maxInFlight == 1` the next Task is not created until the previous one
    /// has fully finished, which is what makes delivery FIFO. Validation runs
    /// INSIDE the Task, never before it, so a message can never be pre-approved
    /// on the consumer thread and then run unconstrained.
    ///
    /// - Parameters: mirror the any-queue entry, minus `uiExecutor`/`execute`;
    ///   `maxInFlight` defaults to 1 (the production single-slot contract).
    public convenience init(
        admission: GestureAdmissionAuthority,
        heartbeatTolerance: TimeInterval? = nil,
        maxInFlight: Int = 1,
        messageValidityWindow: TimeInterval? = nil,
        expiryCheckInterval: TimeInterval? = 0.25,
        onSessionInvalidated: (@Sendable () -> Void)? = nil,
        onGestureDropped: (@Sendable (UInt64) -> Void)? = nil,
        executeOnMainActor: @escaping @MainActor @Sendable (GestureEventMessage) -> Void
    ) {
        self.init(
            admission: admission,
            heartbeatTolerance: heartbeatTolerance,
            maxInFlight: maxInFlight,
            messageValidityWindow: messageValidityWindow,
            expiryCheckInterval: expiryCheckInterval,
            onSessionInvalidated: onSessionInvalidated,
            onGestureDropped: onGestureDropped,
            uiExecutor: nil,
            execute: nil,
            executeOnMainActor: executeOnMainActor
        )
    }

    private init(
        admission: GestureAdmissionAuthority,
        heartbeatTolerance: TimeInterval?,
        maxInFlight: Int,
        messageValidityWindow: TimeInterval?,
        expiryCheckInterval: TimeInterval?,
        onSessionInvalidated: (@Sendable () -> Void)?,
        onGestureDropped: (@Sendable (UInt64) -> Void)?,
        uiExecutor: (@Sendable (@escaping @Sendable () -> Void) -> Void)?,
        execute: (@Sendable (GestureEventMessage) -> Void)?,
        executeOnMainActor: (@MainActor @Sendable (GestureEventMessage) -> Void)?
    ) {
        precondition(maxInFlight >= 1, "maxInFlight must be positive")
        precondition(
            (execute != nil) != (executeOnMainActor != nil),
            "exactly one execution entry (execute / executeOnMainActor) must be provided"
        )
        precondition(executeOnMainActor == nil || maxInFlight == 1,
            "MainActor FIFO consumption requires one in-flight slot")
        let heartbeatTolerance = heartbeatTolerance ?? admission.heartbeatTolerance
        admission.configureHeartbeatTolerance(heartbeatTolerance)
        self.admission = admission
        self.heartbeatTolerance = heartbeatTolerance
        self.messageValidityWindow = messageValidityWindow ?? heartbeatTolerance
        self.maxInFlight = maxInFlight
        self.slots = DispatchSemaphore(value: maxInFlight)
        self.sessionToken = GestureSessionToken(
            admission: admission,
            onSessionInvalidated: onSessionInvalidated,
            onGestureDropped: onGestureDropped
        )
        self.onGestureDropped = onGestureDropped
        self.uiExecutor = uiExecutor ?? { block in DispatchQueue.main.async(execute: block) }
        self.execute = execute
        self.executeOnMainActor = executeOnMainActor

        if let interval = expiryCheckInterval, interval > 0 {
            self.expiryWatchdog = GestureHeartbeatExpiryWatchdog(
                admission: admission,
                token: sessionToken,
                checkInterval: interval
            )
        } else {
            self.expiryWatchdog = nil
        }

        admission.setHeartbeatGapHandler { [weak sessionToken, weak admission] in
            guard let token = sessionToken, let admission else { return }
            let currentGen = admission.snapshot().generation
            // Fires the session-invalidation hook even when the terminal `end`
            // already cleared the lease (REVISION-5 §1), and releases any
            // older-generation lease exactly once.
            token.handleHeartbeatExpiry(olderThanGeneration: currentGen)
        }
    }

    deinit {
        expiryWatchdog?.cancel()
        admission.setHeartbeatGapHandler(nil)
    }

    public var maximumInFlight: Int { maxInFlight }

    public var statisticsSnapshot: Statistics {
        stateLock.withLock {
            var copy = statistics
            copy.releasedExpiredGestures += Int(sessionToken.releasedGesturesCount)
            return copy
        }
    }

    /// Test seam: triggers an immediate expiry check through the watchdog,
    /// bypassing the timer. No-op when the watchdog is disabled.
    public func performExpiryCheckForTesting() {
        expiryWatchdog?.checkNow()
    }

    /// The closure to hand to `OrderedMouseGestureMonitor`'s `eventHandler`.
    /// Runs on the monitor's single consumer thread.
    public func handle(_ message: GestureEventMessage) {
        let epoch = sessionToken.epoch

        // Post-time validation (consumer thread): cheap, droppable filters.
        if message.gestureID != 0,
           message.generation != admission.snapshot().generation {
            bump { $0.droppedStaleGeneration += 1 }
            return
        }
        if message.gestureID != 0 {
            switch message.kind {
            case .begin:
                if !admission.canAcceptNewGesture(
                    now: monotonicTimestampSeconds(),
                    heartbeatTolerance: heartbeatTolerance
                ) {
                    bump { $0.droppedStaleHeartbeat += 1 }
                    return
                }
            case .move, .end, .cancel:
                // A stale heartbeat kills the CURRENT transaction, not just
                // this message. Dropping the terminal alone would leave the
                // UI holding the gesture: release the thread-safe lease
                // synchronously here — this consumer thread, not a possibly
                // wedged UI thread — and notify the host exactly once.
                if !admission.snapshot().isHeartbeatFresh(
                    now: monotonicTimestampSeconds(),
                    tolerance: heartbeatTolerance
                ) {
                    bump { $0.droppedStaleHeartbeat += 1 }
                    releaseDeadTransaction(gestureID: message.gestureID)
                    return
                }
            case .tapFailure:
                break
            }
        }

        // Never park the UI thread, and never let a wedged UI executor hold
        // the input consumer forever. A timed-out terminal releases its lease
        // so the next gesture can start cleanly after recovery.
        let deadline = Thread.isMainThread
            ? DispatchTime.now()
            : DispatchTime.now() + min(heartbeatTolerance, messageValidityWindow)
        guard slots.wait(timeout: deadline) == .success else {
            bump { $0.droppedQueueTimeout += 1 }
            switch message.kind {
            case .begin: break
            case .move, .end, .cancel, .tapFailure:
                releaseDeadTransaction(gestureID: message.gestureID)
            }
            return
        }

        // Re-check after the (possibly long) wait: invalidation that
        // happened while blocked must still cancel this message.
        if sessionToken.epoch != epoch {
            slots.signal()
            bump { $0.droppedInvalidSession += 1 }
            return
        }

        bump {
            $0.posted += 1
            $0.inFlight += 1
        }
        if let callback = executeOnMainActor {
            Task { @MainActor [self] in
                defer { finishDispatch() }
                guard prepareExecution(message, epoch: epoch) else { return }
                callback(message)
            }
        } else {
            uiExecutor { [self] in
                defer { finishDispatch() }
                guard prepareExecution(message, epoch: epoch) else { return }
                execute?(message)
            }
        }
    }

    /// Runs on the UI executor: full re-validation immediately before the
    /// message is allowed to act (the generation may have advanced, the
    /// heartbeat expired — permanently killing the transaction, even if it
    /// later recovers — the message aged past its validity window, or the
    /// gesture been superseded between delivery and execution).
    private func prepareExecution(_ message: GestureEventMessage, epoch: UInt64) -> Bool {
        var valid = sessionToken.epoch == epoch
        if valid, message.gestureID != 0,
           message.generation != admission.snapshot().generation {
            valid = false
        }
        if valid, message.gestureID != 0 {
            let now = monotonicTimestampSeconds()
            let heartbeatFresh = admission.snapshot().isHeartbeatFresh(
                now: now,
                tolerance: heartbeatTolerance
            )
            let messageWithinWindow = now - message.timestampSeconds <= messageValidityWindow
            switch message.kind {
            case .begin:
                if !heartbeatFresh || !messageWithinWindow {
                    valid = false
                }
            case .move, .end, .cancel:
                // Moves and terminals must belong to the gesture the UI
                // actually holds, and the session evidence must still cover
                // them: a heartbeat that expired — or a message older than
                // its validity window — kills the whole transaction, and a
                // later heartbeat refresh cannot revive it.
                if !sessionToken.isActiveGesture(id: message.gestureID)
                    || !heartbeatFresh
                    || !messageWithinWindow {
                    valid = false
                }
            case .tapFailure:
                break
            }
        }

        if valid {
            if case .begin = message.kind {
                sessionToken.beginGesture(
                    id: message.gestureID,
                    generation: message.generation
                )
            }
            if message.isTerminal {
                sessionToken.endGesture(id: message.gestureID)
            }
            bump { $0.executed += 1 }
            return true
        } else {
            // A skipped move/terminal must not leave the UI holding the
            // gesture: release the dead transaction (exactly once —
            // `endGesture` reports whether this call is the releaser) and
            // notify the host synchronously, before the statistics bookkeeping.
            if message.gestureID != 0 {
                switch message.kind {
                case .begin:
                    break
                case .move, .end, .cancel, .tapFailure:
                    releaseDeadTransaction(gestureID: message.gestureID)
                }
            }
            bump { $0.skippedAtExecution += 1 }
        }

        return false
    }

    private func finishDispatch() {
        bump { $0.inFlight -= 1 }
        slots.signal()
    }

    /// Releases a dead transaction exactly once: clears the thread-safe
    /// lease (the token's tracked gesture) and fires `onGestureDropped`
    /// synchronously on the detecting thread. Safe to call redundantly —
    /// only the call that actually wins the release notifies, so a gesture
    /// that was already released (or never held) produces neither a double
    /// release nor a double notification.
    private func releaseDeadTransaction(gestureID: UInt64) {
        guard gestureID != 0 else { return }
        if sessionToken.endGesture(id: gestureID) {
            bump { $0.releasedExpiredGestures += 1 }
            onGestureDropped?(gestureID)
        }
    }

    private func bump(_ mutate: (inout Statistics) -> Void) {
        stateLock.lock()
        mutate(&statistics)
        stateLock.unlock()
    }
}
