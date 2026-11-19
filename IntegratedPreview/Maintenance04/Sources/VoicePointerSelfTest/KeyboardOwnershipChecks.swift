import Foundation
import CoreGraphics
@_spi(Testing) import VoicePointerCore

/// Pure, deterministic checks for the ownership boundary. This file never
/// touches the real event tap or posts a real keyboard event.
public enum KeyboardOwnershipChecks {
    final class FakeBackend: KeyboardEventPosting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [(VoiceModifier, Bool, UInt64)] = []
        var beforePost: (() -> Void)?
        var physicallyHeld: Set<VoiceModifier> = []
        func isPhysicalHeld(_ modifier: VoiceModifier) -> Bool { physicallyHeld.contains(modifier) }
        func post(modifier: VoiceModifier, isDown: Bool, marker: UInt64) -> KeyboardEventPostResult {
            beforePost?()
            lock.lock(); events.append((modifier, isDown, marker)); lock.unlock()
            return .submitted
        }
    }

    public static func run() async -> [String] {
        var failures: [String] = []
        let backend = FakeBackend()
        let manager = KeyboardOwnershipManager(backend: backend)
        let cancelled = OperationCancellationToken(); cancelled.cancel()
        if await manager.acquire(modifier: .leftOption, mode: .hold, cancellationToken: cancelled) != nil || !backend.events.isEmpty {
            failures.append("cancel-before-commit must not submit down")
        }

        let token = OperationCancellationToken()
        guard let lease = await manager.acquire(modifier: .leftOption, mode: .hold, cancellationToken: token) else {
            failures.append("valid acquire should create lease")
            return failures
        }
        let released = await lease.releaseAndWait()
        lease.release()
        if !released { failures.append("matching up should report submitted") }
        if backend.events.map(\.1) != [true, false] { failures.append("owned down must have exactly one matching up") }
        if token.isCancelled { failures.append("normal release must not cancel composer operation token") }

        backend.physicallyHeld = [.leftOption]
        let rejected = await manager.acquire(modifier: .leftOption, mode: .hold, cancellationToken: OperationCancellationToken())
        if rejected != nil { failures.append("physically held same modifier must reject") }
        backend.physicallyHeld = []
        for physical: CGEventFlags in [[], [.maskShift], [.maskAlternate], [.maskAlternate, .maskCommand]] {
            let up = CGEventKeyboardPostBackend.makeOwnedEvent(
                modifier: .leftOption, isDown: false, marker: 42, physicalFlags: physical
            )
            if up?.flags != physical { failures.append("owned up must preserve exact hardware flags") }
            let down = CGEventKeyboardPostBackend.makeOwnedEvent(
                modifier: .leftOption, isDown: true, marker: 42, physicalFlags: physical
            )
            if down?.flags != physical.union(.maskAlternate) { failures.append("owned down must preserve hardware flags") }
        }
        return failures
    }
}
