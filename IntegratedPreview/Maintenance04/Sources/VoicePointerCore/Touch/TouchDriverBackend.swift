import Foundation

/// Hardware boundary behind `TouchRuntimeService`. Implementations are called
/// only from the service's dedicated worker thread and may block; production
/// delegates to the existing synchronous `MultitouchDriver` without changing
/// its API, tests fabricate devices without touching real lifecycle calls.
public protocol TouchDriverBackend: Sendable {
    /// Blocking device start; true when devices are running afterwards.
    func start() -> Bool
    /// Blocking device stop. Must be idempotent.
    func stop()
    /// Blocking device reload; true when devices are running afterwards.
    func reload() -> Bool
    /// Blocking driver status string copy.
    func status() -> String
    /// Blocking device snapshot.
    func devices() -> [TouchDeviceInfo]
    /// Blocking IOKit service count; -1 when the query fails.
    func connectedServiceCount() -> Int
}

/// Production backend: composes the existing `MultitouchDriver` unchanged.
/// The service serializes every call onto its own dedicated thread, so the
/// driver's internal lifecycle lock is never contended from other threads.
public struct MultitouchDriverBackend: TouchDriverBackend {
    private let driver: MultitouchDriver

    public init(driver: MultitouchDriver) {
        self.driver = driver
    }

    public func start() -> Bool { driver.start() }
    public func stop() { driver.stop() }
    public func reload() -> Bool { driver.reload() }
    public func status() -> String { driver.status }
    public func devices() -> [TouchDeviceInfo] { driver.devices }
    public func connectedServiceCount() -> Int { driver.connectedServiceCount }
}

/// Host-side quiesce handshake. Before the service performs a device stop or
/// reload, the host must close input admission, invalidate in-flight voice
/// transactions, release keys this app holds, and disable the event tap.
public protocol TouchQuiesceCoordinating: Sendable {
    /// Returns true only once the host has confirmed the actions above for
    /// `generation`. Must not synchronously wait on the device worker thread
    /// and must not touch UI. The handshake runs on the cooperative pool.
    func quiesce(generation: UInt64) async -> Bool
}

/// Production default: refuses. The host has not proven it closed input
/// admission, invalidated transactions, released keys, or disabled the tap,
/// so the service fails stop/reload requests closed instead of pretending the
/// host acted. The app wires a real coordinator during integration.
public struct UnwiredQuiesceCoordinator: TouchQuiesceCoordinating {
    public init() {}

    public func quiesce(generation: UInt64) async -> Bool { false }
}

/// Deadline scheduler for lifecycle timeouts. Deadlines are expressed in the
/// service's injected monotonic nanoseconds, which keeps timeout behavior
/// deterministic under test (a manual scheduler fires callbacks when the test
/// advances the clock; production uses the real clock).
public protocol TouchTimeoutScheduling: Sendable {
    /// Arranges `body` to run once when the monotonic clock reaches
    /// `deadlineNs`. Implementations choose the execution thread; `body` is
    /// safe to call from anywhere.
    func schedule(deadlineNs: UInt64, _ body: @escaping @Sendable () -> Void)
    func scheduleCancellable(deadlineNs: UInt64, _ body: @escaping @Sendable () -> Void) -> TouchDeadlineCancellation
}

/// Cancellation may arrive before a scheduler has installed its timer.
/// The registration then cancels immediately instead of losing that race.
public final class TouchDeadlineCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var action: (@Sendable () -> Void)?
    public init() {}
    public func install(_ action: @escaping @Sendable () -> Void) {
        let cancelNow = lock.withLock {
            if ended { return true }
            self.action = action
            return false
        }
        if cancelNow { action() }
    }
    public func cancel() {
        let cleanup: (@Sendable () -> Void)? = lock.withLock {
            guard !ended else { return nil }
            ended = true
            defer { action = nil }
            return action
        }
        cleanup?()
    }
    public func take() -> Bool {
        lock.withLock {
            guard !ended else { return false }
            ended = true
            action = nil
            return true
        }
    }
}

public extension TouchTimeoutScheduling {
    func scheduleCancellable(deadlineNs: UInt64, _ body: @escaping @Sendable () -> Void) -> TouchDeadlineCancellation {
        let token = TouchDeadlineCancellation()
        schedule(deadlineNs: deadlineNs) {
            if token.take() { body() }
        }
        return token
    }
}

/// The monotonic clock the service uses by default.
public let touchDefaultMonotonicClock: @Sendable () -> UInt64 = {
    DispatchTime.now().uptimeNanoseconds
}

/// Production scheduler: dispatch timers derived from the same injected
/// clock, so `schedule` and the service's deadline math cannot drift apart.
public struct DispatchTimeoutScheduler: TouchTimeoutScheduling {
    private let clock: @Sendable () -> UInt64
    private let queue: DispatchQueue

    public init(
        clock: @escaping @Sendable () -> UInt64 = touchDefaultMonotonicClock,
        queue: DispatchQueue = DispatchQueue(label: "com.kenyu.VoicePointer.touch-timeouts")
    ) {
        self.clock = clock
        self.queue = queue
    }

    public func schedule(deadlineNs: UInt64, _ body: @escaping @Sendable () -> Void) {
        let now = clock()
        let delay = deadlineNs > now ? Double(deadlineNs - now) / 1_000_000_000 : 0
        queue.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: body))
    }

    public func scheduleCancellable(deadlineNs: UInt64, _ body: @escaping @Sendable () -> Void) -> TouchDeadlineCancellation {
        let token = TouchDeadlineCancellation()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let now = clock()
        let delay = deadlineNs > now ? Double(deadlineNs - now) / 1_000_000_000 : 0
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler {
            if token.take() { body() }
            timer.setEventHandler {}
            timer.cancel()
        }
        timer.resume()
        token.install {
            timer.setEventHandler {}
            timer.cancel()
        }
        return token
    }
}
