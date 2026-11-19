import Foundation
@_spi(Testing) import VoicePointerCore

/// Offline-only checks for the AX worker contract. No accessibility calls,
/// permissions, event posting, or hardware are touched.
public enum AXServiceChecks {
    public static func run() async -> [String] {
        var failures = await runComposerQueueReentrancy()
        let worker = AXSerialWorker()
        let started = ContinuousClock.now
        let timedOut = await worker.runBounded(nanoseconds: 20_000_000) {
            try? await Task.sleep(for: .milliseconds(200))
            return true
        }
        let elapsed = started.duration(to: .now)
        if timedOut != nil || elapsed > .milliseconds(150) { failures.append("slow AX timeout") }

        let active = ManagedAtomicCounter()
        let peak = ManagedAtomicCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = await worker.run {
                        let now = active.increment()
                        peak.max(now)
                        try? await Task.sleep(for: .milliseconds(5))
                        active.decrement()
                        return true
                    }
                }
            }
        }
        if peak.value > 1 { failures.append("worker overlap") }

        // A timed-out operation is intentionally non-cooperative: it keeps
        // the single worker lease until it returns. One pending request is
        // allowed; the next one must be rejected rather than accumulating.
        let lease = ManagedAtomicCounter()
        let pendingCalls = ManagedAtomicCounter()
        let rejectedCalls = ManagedAtomicCounter()
        let gate = AXTestGate()
        let late = await worker.runBounded(nanoseconds: 20_000_000) {
            lease.increment()
            await gate.wait()
            lease.decrement()
            return true
        }
        if late != nil || lease.value != 1 { failures.append("timeout must retain real worker ownership") }
        let pending = await worker.runBounded(nanoseconds: 20_000_000) {
            pendingCalls.increment()
            return true
        }
        if pending != nil || pendingCalls.value != 0 { failures.append("pending work overlapped blocked worker") }
        let rejectedAt = ContinuousClock.now
        let rejected = await worker.runBounded(nanoseconds: 5_000_000_000) {
            rejectedCalls.increment()
            return true
        }
        if rejected != nil { failures.append("worker accepted excess pending work") }
        if rejectedAt.duration(to: .now) > .milliseconds(200) {
            failures.append("capacity rejection did not return promptly")
        }
        await gate.open()
        // A serial barrier waits for REAL completion, not the expired
        // caller-facing continuation. Late completions must not resume twice.
        _ = await worker.run { true }
        if lease.value != 0 || pendingCalls.value != 1 || rejectedCalls.value != 0 {
            failures.append("late operation ownership or admission accounting")
        }
        if await worker.runBounded(nanoseconds: 100_000_000, operation: { true }) != true {
            failures.append("worker did not recover after real completion")
        }
        return failures
    }

    /// C1: the real copyAttribute/validate path returns from inside axQueue.
    /// Its in-memory AX fixture also checks the off-queue and cancellation paths.
    public static func runComposerQueueReentrancy() async -> [String] {
        await MacOSComposerActionExecutor.testAXQueueReentrancy()
            ? [] : ["C1 AX queue reentrancy"]
    }
}

private actor AXTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    @discardableResult func increment() -> Int { lock.withLock { storage += 1; return storage } }
    func decrement() { lock.withLock { storage -= 1 } }
    func max(_ value: Int) { lock.withLock { storage = Swift.max(storage, value) } }
}
