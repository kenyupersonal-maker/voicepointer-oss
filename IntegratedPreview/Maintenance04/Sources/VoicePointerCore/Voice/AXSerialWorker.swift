import Foundation

private final class AXOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; guard !completed else { return false }; completed = true; return true }
}

/// Serial async context for cross-process AX work. The operation itself may
/// suspend, while the actor preserves ordering between sessions.
public actor AXSerialWorker {
    /// A bounded caller can time out while its AX operation still owns the queue. Shutdown waits for the owner.
    public func drain() async {
        while boundedOutstanding > 0 { try? await Task.sleep(for: .milliseconds(5)) }
        await run { () }
    }
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var boundedOutstanding = 0
    public init() {}

    public func run<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        busy = true
        defer {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()
            } else {
                busy = false
            }
        }
        return await operation()
    }

    public func runBounded<T: Sendable>(nanoseconds: UInt64, operation: @Sendable @escaping () async -> T) async -> T? {
        guard boundedOutstanding < 2 else { return nil }
        boundedOutstanding += 1
        let once = AXOnce<T?>()
        return await withCheckedContinuation { continuation in
            let timer = Task.detached {
                do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
                if once.take() { continuation.resume(returning: nil) }
            }
            Task {
                let value = await self.run(operation)
                boundedOutstanding -= 1
                timer.cancel()
                if once.take() { continuation.resume(returning: value) }
            }
        }
    }
}
