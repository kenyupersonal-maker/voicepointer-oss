import Foundation
import VoicePointerCore

/// Offline regressions for synchronous completion reentrancy and cancellable
/// lifecycle deadlines. No driver, IOKit, event tap, or MainActor blocking.
public enum TouchRuntimeReentrancyChecks {
    private final class Backend: TouchDriverBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var startBlocked = true
        private var entered = false
        private var starts = 0
        private var stops = 0
        private var reloads = 0
        var startCalls: Int { lock.withLock { starts } }
        var stopCalls: Int { lock.withLock { stops } }
        var reloadCalls: Int { lock.withLock { reloads } }
        var startEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func releaseStart() { lock.lock(); startBlocked = false; lock.unlock() }
        func start() -> Bool {
            lock.lock(); starts += 1; entered = true; lock.unlock()
            while true {
                lock.lock(); let blocked = startBlocked; lock.unlock()
                if !blocked { return true }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        func stop() { lock.withLock { stops += 1 } }
        func reload() -> Bool { lock.withLock { reloads += 1 }; return true }
        func status() -> String { "fake" }
        func devices() -> [TouchDeviceInfo] { [] }
        func connectedServiceCount() -> Int { 0 }
    }

    private final class Host: TouchQuiesceCoordinating, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedGenerations: [UInt64] = []
        var generations: [UInt64] { lock.withLock { recordedGenerations } }
        private var blockFirst = true
        func allowFirst() { lock.lock(); blockFirst = false; lock.unlock() }
        func quiesce(generation: UInt64) async -> Bool {
            append(generation)
            while true {
                let blocked = isFirstBlocked
                if !blocked { return true }
                await Task.yield()
            }
        }
        private var isFirstBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blockFirst }
        private func append(_ generation: UInt64) { lock.withLock { recordedGenerations.append(generation) } }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock(); private var value: T
        init(_ value: T) { self.value = value }
        func set(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
        func update(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
        var get: T { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Payload: @unchecked Sendable {
        let deinitBox: Box<Bool>
        init(_ box: Box<Bool>) { deinitBox = box }
        deinit { deinitBox.set(true) }
        func touch() { _ = deinitBox.get }
    }

    public static func run() async -> [String] {
        var failures: [String] = []
        await checkReentrantSupersession(&failures)
        await checkCancellationRegistration(&failures)
        await checkDispatchCancellationReleasesPayload(&failures)
        return failures
    }

    private static func checkReentrantSupersession(_ failures: inout [String]) async {
        let backend = Backend(); let host = Host()
        defer { backend.releaseStart(); host.allowFirst() }
        let service = TouchRuntimeService(backend: backend, quiesce: host,
            configuration: .init(mutationBudgetNs: 1_000_000_000, quiesceBudgetNs: 1_000_000_000,
                requestBudgetSlackNs: 100_000_000, idleWaitSeconds: 0.01))
        let startOutcome = Box<[TouchLifecycleOutcome]>([])
        let stopOutcome = Box<[TouchLifecycleOutcome]>([])
        service.requestStart { outcome in
            startOutcome.update { $0.append(outcome) }
            if outcome == .superseded { service.requestStop { result in stopOutcome.update { $0.append(result) } } }
        }
        guard await poll({ backend.startEntered }) else { failures.append("start did not enter"); return }
        let reloadOutcome = Box<[TouchLifecycleOutcome]>([])
        service.requestReload { result in reloadOutcome.update { $0.append(result) } }
        backend.releaseStart()
        guard await poll({ startOutcome.get == [.superseded] }) else {
            host.allowFirst()
            failures.append("reentrant supersession did not resolve all completions"); return
        }
        host.allowFirst()
        guard await poll({ stopOutcome.get.count == 1 && reloadOutcome.get.count == 1 }) else {
            failures.append("reentrant supersession did not resolve all completions"); return
        }
        if startOutcome.get != [.superseded] || reloadOutcome.get != [.superseded] || stopOutcome.get != [.stopped] {
            failures.append("old start/reload outcomes were not superseded before reentrant stop")
        }
        if backend.reloadCalls != 0 || backend.stopCalls != 2 || host.generations != [3] {
            failures.append("stale reload reached host/device or cancelled the new stop")
        }
    }

    private static func checkCancellationRegistration(_ failures: inout [String]) async {
        let before = TouchDeadlineCancellation(); let beforeCleanup = Box(0)
        before.cancel(); before.install { beforeCleanup.update { $0 += 1 } }
        let after = TouchDeadlineCancellation(); let afterCleanup = Box(0)
        after.install { afterCleanup.update { $0 += 1 } }; after.cancel(); after.cancel()
        if beforeCleanup.get != 1 || afterCleanup.get != 1 || before.take() || after.take() {
            failures.append("deadline cancellation did not run cleanup exactly once")
        }

        let scheduler = ManualScheduler(); let manualBody = Box(false)
        let registration = scheduler.scheduleCancellable(deadlineNs: 10, { manualBody.set(true) })
        registration.cancel(); scheduler.fire(10)
        if manualBody.get { failures.append("cancelled manual deadline executed body") }
    }

    private static func checkDispatchCancellationReleasesPayload(_ failures: inout [String]) async {
        let released = Box(false)
        let scheduler = DispatchTimeoutScheduler()
        let cancellation = registerPayload(scheduler, released: released)
        if released.get { failures.append("timer did not retain the probe before cancellation") }
        cancellation.cancel()
        guard await poll({ released.get }, milliseconds: 500) else { failures.append("cancelled dispatch timer retained payload"); return }
    }

    private static func registerPayload(_ scheduler: DispatchTimeoutScheduler, released: Box<Bool>) -> TouchDeadlineCancellation {
        let payload = Payload(released)
        return scheduler.scheduleCancellable(deadlineNs: DispatchTime.now().uptimeNanoseconds + 2_000_000_000) {
            payload.touch()
        }
    }

    private static func poll(_ condition: @escaping () -> Bool, milliseconds: Int = 2_000) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }

    private final class ManualScheduler: TouchTimeoutScheduling, @unchecked Sendable {
        private let lock = NSLock(); private var bodies: [(UInt64, @Sendable () -> Void)] = []
        func schedule(deadlineNs: UInt64, _ body: @escaping @Sendable () -> Void) { lock.lock(); bodies.append((deadlineNs, body)); lock.unlock() }
        func fire(_ now: UInt64) {
            lock.lock(); let due = bodies.filter { $0.0 <= now }; bodies.removeAll { $0.0 <= now }; lock.unlock()
            due.forEach { $0.1() }
        }
    }
}
