import CoreGraphics
import Foundation

/// The sources a worker thread installs on its own CFRunLoop. Created,
/// enabled, disabled and released strictly on the owning worker thread, in
/// that order, so the tap's userInfo/refcon never outlives the thread that
/// created it.
public struct EventTapInstallation {
    let source: CFRunLoopSource
    let enable: @Sendable () -> Void
    let disable: @Sendable () -> Void
    let teardown: @Sendable () -> Void

    init(
        source: CFRunLoopSource,
        enable: @escaping @Sendable () -> Void,
        disable: @escaping @Sendable () -> Void,
        teardown: @escaping @Sendable () -> Void
    ) {
        self.source = source
        self.enable = enable
        self.disable = disable
        self.teardown = teardown
    }
}

/// Produces the tap installation on the worker thread. Receives the
/// @convention(c) callback and the userInfo opaque pointer that refers to
/// the worker itself; the worker guarantees it stays alive until the
/// installation is torn down.
public typealias EventTapInstaller = @Sendable (
    _ runLoop: CFRunLoop,
    _ callback: CGEventTapCallBack,
    _ userInfo: UnsafeMutableRawPointer
) -> EventTapInstallation?

/// Owns the dedicated CFRunLoop thread a CGEventTap lives on.
///
/// - Tap creation, invalidation and release happen on the owning worker
///   thread in that order (create → add source → enable → disable → remove
///   → invalidate → release); the userInfo refcon is therefore never
///   dangling, because the thread body retains the worker until after
///   teardown completes.
/// - `start()` blocks only until the worker thread reports whether the tap
///   was created (bounded by thread bootstrap). `stop(_:)` is fully
///   asynchronous: it signals the worker run loop, returns immediately, and
///   invokes its completion on a global queue once the thread has exited.
///   The main thread never synchronously waits for the worker to stop.
/// - Stop is idempotent and safe during startup: a stop requested while
///   starting is honored right after the tap is created, and every stop's
///   completion is invoked exactly once.
/// - Bootstrap failure (no run loop, no stop source, or a nil installer
///   result) never enters the run loop: the thread runs the same teardown
///   tail, publishes `.stopped`, fires any stop completions registered while
///   starting, and exits — releasing the thread body's strong self
///   reference so the worker deallocates once the app drops it. A failed
///   start can be retried on the same worker object.
///
/// Synchronization invariant for `@unchecked Sendable`: `state`,
/// `stopRequestedDuringStart`, `stopCompletions`, `bootstrapSuccess`,
/// `bootstrapError`, `workerRunLoop` and `stopSourceRef` are accessed only
/// while holding `lifecycle` (NSCondition used as lock). `installationRef`
/// is touched only by the worker thread (thread body and the stop command,
/// which runs on the worker run loop), so it needs no lock. `installer` and
/// `eventHandler` are immutable lets.
final class EventTapWorker: @unchecked Sendable {
    enum LifecycleState: Equatable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    private let lifecycle = NSCondition()
    private var state: LifecycleState = .idle
    private var stopRequestedDuringStart = false
    private var stopCompletions: [@Sendable () -> Void] = []
    private var bootstrapSuccess = false
    private var bootstrapError: Error?
    private var workerRunLoop: CFRunLoop?
    private var stopSourceRef: CFRunLoopSource?
    private var installationRef: EventTapInstallation?
    private let installer: EventTapInstaller
    private let eventHandler: @Sendable (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        EventTapWorker.handleTapEvent(type: type, event: event, userInfo: userInfo)
    }

    static func handleTapEvent(
        type: CGEventType,
        event: CGEvent,
        userInfo: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let worker = Unmanaged<EventTapWorker>.fromOpaque(userInfo).takeUnretainedValue()
        return worker.eventHandler(type, event)
    }

    init(
        installer: @escaping EventTapInstaller,
        eventHandler: @escaping @Sendable (CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    ) {
        self.installer = installer
        self.eventHandler = eventHandler
    }

    deinit {
        // Best effort: the thread body retains the worker, so deinit can only
        // run once the thread has exited (or never started).
    }

    /// Starts the worker thread and its tap. Blocks until the thread reports
    /// bootstrap success or failure, bounded by `bootstrapTimeout` (thread
    /// startup is milliseconds; the bound exists so a wedged installer
    /// cannot block the caller forever). Throws
    /// `MouseGestureMonitorError.eventTapUnavailable` when the tap cannot be
    /// created — or when the bootstrap did not resolve in time.
    ///
    /// The outcome is a real lifecycle statement, not a best guess:
    /// - A normal return means the tap is installed and enabled.
    /// - A thrown failure from a *resolved* bootstrap (nil installer result,
    ///   no run loop, no stop source) means the thread has ALREADY finished
    ///   its teardown — the worker is `.stopped` and owns no resources, so
    ///   a retry on the same object is safe.
    /// - A timeout throw means the opposite: the worker thread is still
    ///   inside the installer and NOTHING has been torn down yet. The worker
    ///   is still `.starting`; the caller must keep ownership (issue
    ///   `stop` to drive the eventual teardown) instead of assuming the
    ///   failure cleaned anything up. A second `start` on this worker is
    ///   explicitly rejected until the thread really exits.
    func start(bootstrapTimeout: TimeInterval = 10) throws {
        lifecycle.lock()
        while state == .stopping {
            guard lifecycle.wait(until: Date().addingTimeInterval(5)) else { break }
        }
        if state == .stopping {
            lifecycle.unlock()
            throw MouseGestureMonitorError.eventTapUnavailable
        }
        guard state == .idle || state == .stopped else {
            // A start is already running or the worker never finished —
            // reject explicitly instead of silently pretending success.
            lifecycle.unlock()
            throw MouseGestureMonitorError.eventTapUnavailable
        }
        state = .starting
        bootstrapSuccess = false
        bootstrapError = nil
        stopRequestedDuringStart = false
        lifecycle.unlock()

        let bootstrapSemaphore = DispatchSemaphore(value: 0)
        let thread = Thread(block: { [self] in
            Thread.current.name = "VoicePointerEventTap"
            self.threadMain(bootstrapSemaphore: bootstrapSemaphore)
        })
        thread.name = "VoicePointerEventTap"
        thread.stackSize = 512 * 1024
        thread.start()

        let signal = bootstrapSemaphore.wait(timeout: .now() + bootstrapTimeout)
        lifecycle.lock()
        let success = bootstrapSuccess
        let error = bootstrapError
        if signal == .timedOut {
            // The thread never bootstrapped (yet). Ask it to tear down
            // immediately if it ever wakes up and report failure to the
            // caller — the worker keeps its resources and ownership until
            // the real teardown runs; only `stop` drives it from here.
            stopRequestedDuringStart = true
            lifecycle.unlock()
            throw MouseGestureMonitorError.eventTapUnavailable
        }
        lifecycle.unlock()
        if !success {
            throw error ?? MouseGestureMonitorError.eventTapUnavailable
        }
    }

    /// Asynchronous stop. Safe to call repeatedly, before `start`, while a
    /// start is in flight, or after the thread has already exited. The
    /// completion is invoked exactly once per call, on a global queue, after
    /// the tap has been disabled, removed, invalidated and released in order
    /// on the worker thread.
    func stop(completion: (@Sendable () -> Void)? = nil) {
        lifecycle.lock()
        let currentState = state
        switch currentState {
        case .idle, .stopped:
            lifecycle.unlock()
            if let completion {
                DispatchQueue.global().async { completion() }
            }
            return
        case .starting:
            if let completion { stopCompletions.append(completion) }
            stopRequestedDuringStart = true
            lifecycle.unlock()
            return
        case .running:
            if let completion { stopCompletions.append(completion) }
            state = .stopping
            let stopSource = stopSourceRef
            let runLoop = workerRunLoop
            lifecycle.unlock()
            if let stopSource, let runLoop {
                CFRunLoopSourceSignal(stopSource)
                CFRunLoopWakeUp(runLoop)
            }
            return
        case .stopping:
            if let completion { stopCompletions.append(completion) }
            lifecycle.unlock()
            return
        }
    }

    var currentState: LifecycleState {
        lifecycle.withLock { state }
    }

    /// Routes an event through the exact same handling path the real tap
    /// callback uses; for pure-simulation tests only (no tap involved).
    func simulateTapEventForTesting(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        EventTapWorker.handleTapEvent(
            type: type,
            event: event,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    // MARK: - Worker thread

    private func threadMain(bootstrapSemaphore: DispatchSemaphore) {
        guard let runLoop = CFRunLoopGetCurrent() else {
            recordBootstrapFailure()
            finishThread(runLoop: nil, stopSource: nil)
            bootstrapSemaphore.signal()
            return
        }

        var context = CFRunLoopSourceContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil,
            hash: nil,
            schedule: nil,
            cancel: nil,
            perform: { info in
                guard let info else { return }
                let worker = Unmanaged<EventTapWorker>.fromOpaque(info).takeUnretainedValue()
                worker.performStopCommand()
            }
        )
        guard let stopSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else {
            recordBootstrapFailure()
            finishThread(runLoop: runLoop, stopSource: nil)
            bootstrapSemaphore.signal()
            return
        }
        CFRunLoopAddSource(runLoop, stopSource, .defaultMode)

        // Runs outside the lifecycle lock: a slow installer must never block
        // stop() or a concurrent start().
        let installation = installer(
            runLoop,
            EventTapWorker.tapCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        // Returns whether the thread should enter its run loop: false both
        // when the bootstrap failed (never park a failed run) and when a stop
        // already won the bootstrap race (the tail below tears down instead).
        let enterRunLoop: Bool = lifecycle.withLock {
            workerRunLoop = runLoop
            stopSourceRef = stopSource
            guard let installation else {
                // Bootstrap failed: the thread must NOT enter the run loop.
                // The shared teardown tail clears the published refs, fires
                // every stop completion registered while starting, and lets
                // the thread (and its strong self reference) exit.
                state = .stopping
                bootstrapSuccess = false
                bootstrapError = MouseGestureMonitorError.eventTapUnavailable
                return false
            }
            installationRef = installation
            CFRunLoopAddSource(runLoop, installation.source, .defaultMode)
            if stopRequestedDuringStart {
                // Stop won the bootstrap race: never enable the tap; the
                // teardown tail runs disable → remove → teardown in order.
                state = .stopping
                bootstrapSuccess = true
                return false
            }
            installation.enable()
            state = .running
            bootstrapSuccess = true
            return true
        }

        // Ordering guarantee: on every path that never enters the run loop
        // (bootstrap failure, or stop winning the bootstrap race), the full
        // teardown runs BEFORE the bootstrap semaphore is signalled, so
        // `start()` only returns once the outcome is final — a resolved
        // failure means the worker is already `.stopped` and owns no
        // resources. Only a timeout can leave the thread mid-install, and
        // then `start()` threw without touching the worker's state.
        if !enterRunLoop {
            finishThread(runLoop: runLoop, stopSource: stopSource)
            bootstrapSemaphore.signal()
            return
        }

        bootstrapSemaphore.signal()
        CFRunLoopRun()
        finishThread(runLoop: runLoop, stopSource: stopSource)
    }

    private func recordBootstrapFailure() {
        lifecycle.lock()
        bootstrapSuccess = false
        bootstrapError = MouseGestureMonitorError.eventTapUnavailable
        state = .stopping
        lifecycle.broadcast()
        lifecycle.unlock()
    }

    /// End-of-thread cleanup, always executed on the worker thread: tears the
    /// installation down in order (unless the stop command already did),
    /// removes the stop source, clears the published refs, publishes
    /// `.stopped` and then — and only then — fires every registered stop
    /// completion exactly once. Because this is the single exit path for the
    /// thread body, the thread's strong self reference is released right
    /// after it returns, even when the bootstrap failed.
    private func finishThread(runLoop: CFRunLoop?, stopSource: CFRunLoopSource?) {
        if let installation = installationRef {
            installation.disable()
            if let runLoop {
                CFRunLoopRemoveSource(runLoop, installation.source, .defaultMode)
            }
            installation.teardown()
            installationRef = nil
        }
        if let runLoop, let stopSource {
            CFRunLoopRemoveSource(runLoop, stopSource, .defaultMode)
        }
        lifecycle.lock()
        workerRunLoop = nil
        stopSourceRef = nil
        let completions = stopCompletions
        stopCompletions = []
        state = .stopped
        lifecycle.broadcast()
        lifecycle.unlock()
        for completion in completions {
            DispatchQueue.global().async { completion() }
        }
    }

    /// Runs on the worker run loop when a stop was signalled: disables the
    /// tap, removes its source, invalidates and releases the mach port, then
    /// stops the run loop. Same thread that created the tap, in order.
    private func performStopCommand() {
        if let installation = installationRef {
            installation.disable()
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), installation.source, .defaultMode)
            installation.teardown()
            installationRef = nil
        }
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}
