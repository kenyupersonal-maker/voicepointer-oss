import Foundation

/// Independent expiry observer for the gesture heartbeat.
///
/// Runs a `DispatchSourceTimer` on a private serial queue. On each tick it
/// asks the authority to `consumeHeartbeatExpiry()` — an atomic fresh→stale
/// observation that advances the generation exactly once per stale period and
/// returns non-nil only for the first tick that sees the new expiry. When it
/// does, the watchdog releases every tracked gesture whose generation is older
/// than the current one AND fires the session-invalidation hook regardless of
/// whether a gesture was still held (REVISION-5 §1). This is the R4 §3
/// "independent release channel" — it fires even when the UI executor is
/// frozen, all adapter in-flight slots are full, the terminal `end` was
/// already consumed, and no further input message will ever arrive, so a dead
/// transaction can never strand the UI in the "held" state nor leave the host's
/// independent operation token uncancelled just because the main queue is wedged.
///
/// The timer handler captures `[weak self]` (the adapter owns the watchdog,
/// the adapter is retained by the UI executor's in-flight closures — a
/// strong capture would create a cycle through the timer's dispatch queue).
/// `cancel()` stops the timer; the adapter's `deinit` calls it and also
/// unregisters the admission gap handler, so the watchdog is
/// non-self-retaining and closeable.
///
/// `checkNow()` is a test seam: it runs the same check the timer would,
/// synchronously on the caller's thread, bypassing the timer schedule.
final class GestureHeartbeatExpiryWatchdog: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private weak var admission: GestureAdmissionAuthority?
    private weak var token: GestureSessionToken?

    init(
        admission: GestureAdmissionAuthority,
        token: GestureSessionToken,
        checkInterval: TimeInterval
    ) {
        self.admission = admission
        self.token = token
        let queue = DispatchQueue(label: "VoicePointer.GestureHeartbeatExpiryWatchdog")
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + checkInterval,
            repeating: checkInterval,
            leeway: .milliseconds(Int(checkInterval * 500))
        )
        self.timer = source
        source.setEventHandler { [weak self] in
            self?.performCheck()
        }
        source.resume()
    }

    deinit {
        timer.cancel()
    }

    func cancel() {
        timer.cancel()
    }

    /// Test seam: runs an immediate expiry check on the caller's thread.
    func checkNow() {
        performCheck()
    }

    private func performCheck() {
        guard let admission = admission, let token = token else { return }
        // Atomic fresh→stale observation + single generation advance, done
        // inside the authority lock. Returns non-nil only on the FIRST check of
        // a new stale period, so this repeating timer can never re-advance the
        // generation for one dead heartbeat, and a heartbeat that recovered
        // since we were scheduled is seen as fresh — never killing a
        // transaction the host just rebuilt.
        guard let newGeneration = admission.consumeHeartbeatExpiry() else { return }
        // Outside the lock: release any old-generation lease exactly once AND
        // fire the session-invalidation hook even when no gesture is held, so
        // the host cancels its independent operation token.
        token.handleHeartbeatExpiry(olderThanGeneration: newGeneration)
    }
}
