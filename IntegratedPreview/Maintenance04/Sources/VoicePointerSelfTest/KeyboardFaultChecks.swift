import Foundation
@_spi(Testing) import VoicePointerCore

/// Deterministic ownership fault checks. The fake is synchronous, but all
/// waits happen on the manager's worker queue; the test entry point is never
/// MainActor-blocked and never touches a real keyboard or event tap.
public enum KeyboardFaultChecks {
    private struct Event: Sendable { let modifier: VoiceModifier; let down: Bool }

    private final class FakeBackend: KeyboardEventPosting, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Event] = []
        var failNextUp = false
        var blockUp = false
        var blockPhysical = false
        let upEntered = DispatchSemaphore(value: 0)
        let physicalEntered = DispatchSemaphore(value: 0)
        let releaseUp = DispatchSemaphore(value: 0)
        let releasePhysical = DispatchSemaphore(value: 0)
        var physicalHeld = false

        var events: [Event] { lock.lock(); defer { lock.unlock() }; return stored }
        func isPhysicalHeld(_ modifier: VoiceModifier) -> Bool {
            if blockPhysical {
                physicalEntered.signal()
                _ = releasePhysical.wait(timeout: .now() + 2)
            }
            return physicalHeld
        }
        func post(modifier: VoiceModifier, isDown: Bool, marker: UInt64) -> KeyboardEventPostResult {
            if !isDown && blockUp {
                upEntered.signal()
                _ = releaseUp.wait(timeout: .now() + 2)
            }
            lock.lock(); defer { lock.unlock() }
            stored.append(Event(modifier: modifier, down: isDown))
            if !isDown && failNextUp { failNextUp = false; return .failed(reason: "fakeUpFailure") }
            return .submitted
        }
    }

    private actor BoolBox {
        var value: Bool?
        func put(_ value: Bool) { self.value = value }
        func get() -> Bool? { value }
    }

    public static func run() async -> [String] {
        var failures: [String] = []
        await checkSharedReleaseReceipt(&failures)
        await checkRetryAfterUpFailure(&failures)
        await checkTogglePartialUp(&failures)
        await checkToggleStopPartialUp(&failures)
        await checkPendingCancellation(&failures)
        await checkCancellationSemantics(&failures)
        return failures
    }

    private static func checkSharedReleaseReceipt(_ failures: inout [String]) async {
        let backend = FakeBackend(); let manager = KeyboardOwnershipManager(backend: backend)
        guard let lease = await manager.acquire(modifier: .leftOption, mode: .hold, cancellationToken: OperationCancellationToken()) else { failures.append("receipt setup acquire"); return }
        backend.blockUp = true
        lease.release()
        guard await wait(backend.upEntered) else { failures.append("up gate did not enter"); return }
        let receipt = BoolBox()
        let waiter = Task { await receipt.put(await lease.releaseAndWait()) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(30))
        while await receipt.get() == nil, ContinuousClock.now < deadline { await Task.yield() }
        if await receipt.get() != nil { failures.append("duplicate waiter returned before shared up receipt") }
        backend.releaseUp.signal()
        await waiter.value
        if await receipt.get() != true { failures.append("shared up receipt did not confirm") }
    }

    private static func wait(_ gate: DispatchSemaphore) async -> Bool {
        await Task.detached { blockingWait(gate) }.value
    }

    private static func blockingWait(_ gate: DispatchSemaphore) -> Bool {
        gate.wait(timeout: .now() + 2) == .success
    }

    private static func checkRetryAfterUpFailure(_ failures: inout [String]) async {
        let backend = FakeBackend(); let manager = KeyboardOwnershipManager(backend: backend)
        let token = OperationCancellationToken()
        guard let lease = await manager.acquire(modifier: .leftOption, mode: .hold, cancellationToken: token) else { failures.append("retry setup acquire"); return }
        backend.failNextUp = true
        if await lease.releaseAndWait() { failures.append("failed up reported success") }
        if !(await lease.releaseAndWait()) { failures.append("explicit up retry failed") }
        let events = backend.events
        if events.filter({ !$0.down }).count != 2 || events.filter(\.down).count != 1 { failures.append("retry must be exactly one down and two up attempts") }
    }

    private static func checkTogglePartialUp(_ failures: inout [String]) async {
        let backend = FakeBackend(); backend.failNextUp = true
        let manager = KeyboardOwnershipManager(backend: backend)
        let token = OperationCancellationToken()
        if await manager.acquire(modifier: .leftOption, mode: .toggle, cancellationToken: token) != nil { failures.append("partial toggle must report acquire failure") }
        if !(await manager.releaseAllOwnedAndWait()) { failures.append("partial toggle cleanup failed") }
        let events = backend.events
        if events.filter(\.down).count != 1 || events.filter({ !$0.down }).count != 2 { failures.append("partial toggle retry must send only compensating up") }
    }

    private static func checkToggleStopPartialUp(_ failures: inout [String]) async {
        let backend = FakeBackend()
        let manager = KeyboardOwnershipManager(backend: backend)
        guard let lease = await manager.acquire(modifier: .leftOption, mode: .toggle, cancellationToken: .init()) else {
            failures.append("toggle stop setup"); return
        }
        backend.failNextUp = true
        if await lease.releaseAndWait() { failures.append("toggle stop partial up reported success") }
        if !(await lease.releaseAndWait()) { failures.append("toggle stop up retry failed") }
        if backend.events.filter(\.down).count != 2 || backend.events.filter({ !$0.down }).count != 3 {
            failures.append("toggle stop retry must not emit a third down")
        }
    }

    private static func checkPendingCancellation(_ failures: inout [String]) async {
        let backend = FakeBackend(); backend.blockPhysical = true
        let manager = KeyboardOwnershipManager(backend: backend)
        let token = OperationCancellationToken()
        let acquireTask = Task { await manager.acquire(modifier: .leftOption, mode: .hold, cancellationToken: token) }
        guard await wait(backend.physicalEntered) else {
            failures.append("pending physical gate did not start"); return
        }
        manager.releaseAllOwned()
        backend.releasePhysical.signal()
        _ = await manager.releaseAllOwnedAndWait()
        _ = await acquireTask.value
        if !backend.events.isEmpty || !token.isCancelled { failures.append("shutdown must cancel pending acquire before down") }
    }

    private static func checkCancellationSemantics(_ failures: inout [String]) async {
        let backend = FakeBackend(); let manager = KeyboardOwnershipManager(backend: backend)
        let token = OperationCancellationToken()
        guard let lease = await manager.acquire(modifier: .leftOption, mode: .hold, cancellationToken: token) else { failures.append("cancel setup acquire"); return }
        lease.release()
        if await lease.releaseAndWait() == false { failures.append("shared release receipt failed") }
        if token.isCancelled { failures.append("normal release cancelled operation token") }
        lease.cancel()
        if !token.isCancelled { failures.append("cancel after release did not cancel token") }

        let secondToken = OperationCancellationToken()
        guard await manager.acquire(modifier: .leftOption, mode: .hold, cancellationToken: secondToken) != nil else { failures.append("releaseAll setup acquire"); return }
        _ = await manager.releaseAllOwnedAndWait()
        if !secondToken.isCancelled { failures.append("releaseAll did not cancel owned token") }
    }
}
