import Foundation
import VoicePointerCore

/// The device worker only receives an acknowledgement after input admission
/// is closed and the event tap has completed teardown. No AppKit access here.
struct AppTouchQuiesce: TouchQuiesceCoordinating {
    let monitor: OrderedMouseGestureMonitor
    let adapter: GestureMainQueueAdapter
    let safety: VoiceOperationSafety
    let keyboard: KeyboardOwnershipManager

    func quiesce(generation: UInt64) async -> Bool {
        monitor.setEnabled(false)
        adapter.sessionToken.invalidate()
        safety.invalidate()
        let released = await keyboard.releaseAllOwnedAndWait()
        await withCheckedContinuation { continuation in
            monitor.stop { continuation.resume() }
        }
        if !released {
            RuntimeTrace.record("quiesce generation=\(generation) owned key release submission failed")
        }
        // Device shutdown remains necessary if input-posting permission was
        // revoked. All releases were attempted; their failed receipts remain
        // owned for an explicit retry. Do not pretend the OS accepted them.
        return true
    }
}
