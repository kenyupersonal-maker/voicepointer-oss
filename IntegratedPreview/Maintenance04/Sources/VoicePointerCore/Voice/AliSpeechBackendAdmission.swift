import Foundation

/// K06 enforcement for the Ali stream, entirely on the host side. The worker binary is built from a
/// different tree, so nothing here touches the host/worker protocol: every decision is taken before a
/// frame is written to, or an event is accepted from, the worker.
@MainActor
extension AliSpeechBackend {

    /// Frames are capped at 100 ms of 16 kHz mono 16-bit PCM, so the gate is consulted at least once per
    /// 100 ms of audio (see `CloudStreamArbiter` for the full cadence).
    static let admissionFrameBytes = 3_200

    /// Last stop before one PCM frame is handed to the worker. Once this returns false the stream has
    /// been cancelled and no later frame in it may be forwarded.
    func frameMayForward() async -> Bool {
        guard let arbiter else { return false }
        if !arbiter.isRevoked { _ = await arbiter.verifyPermit() }
        guard arbiter.admitFrame() else {
            await settleRevocation()
            return false
        }
        return true
    }

    /// Before a transcript event is delivered: the gate must still recognise the permit and the event's
    /// epoch tag (the epoch this stream started under) must be the arbiter's.
    func eventMayDeliver() async -> Bool {
        guard let arbiter else { return false }
        if !arbiter.isRevoked { _ = await arbiter.verifyPermit() }
        guard textMayDeliverNow() else {
            await settleRevocation()
            return false
        }
        return true
    }

    /// Synchronous last check for text about to be handed to the coordinator.
    func textMayDeliverNow() -> Bool {
        guard let arbiter, let admission else { return false }
        return arbiter.admitEvent(startedUnderEpoch: admission.permit.pauseEpoch)
    }

    /// Before the key is read or a worker is launched: no new request for a permit the gate dropped.
    func streamMayPrepare() async -> Bool {
        guard let arbiter else { return false }
        if !arbiter.isRevoked { _ = await arbiter.verifyPermit() }
        guard !arbiter.isRevoked else {
            await settleRevocation()
            return false
        }
        return true
    }

    /// Gives the gate the finite evidence of a failed stream. Only what the gate accepts as a pause
    /// revokes; every other failure keeps the ordinary failure path. Runs once per stream, and also
    /// when the user cancelled at the same moment, so a confirmed pause is never lost.
    func pauseIfConfirmed(by error: any Error) async {
        guard let arbiter, !pauseEvidenceHandled,
              let evidence = (error as? AliServiceFailure)?.evidence else { return }
        pauseEvidenceHandled = true
        switch await arbiter.recordProviderFailure(evidence) {
        case .notAPause:
            return
        case .paused(let epoch):
            let inFlightCancelled = await settleRevocation()
            RuntimeTrace.record(
                "cloud pause epoch=\(epoch) inFlightCancelled=\(inFlightCancelled) framesDropped=\(arbiter.counts.framesDropped)"
            )
        case .storageUnavailable:
            await settleRevocation()
        }
    }

    /// After the arbiter is revoked: cancel the live worker session once (every caller waits for that
    /// same cancellation), remember why for the terminal event, and record a counts-only trace line.
    /// A provider pause is reported by the `cloud pause` line in `pauseIfConfirmed`, which knows the
    /// gate's epoch. Returns how many in-flight sessions the cancellation reached (0 or 1).
    @discardableResult
    func settleRevocation() async -> Int {
        guard let arbiter, let reason = arbiter.revocation else { return 0 }
        if let running = revocationTask { return await running.value }
        if failureCode == nil || failureCode == "ALI_STREAM_FAILED" || failureCode == "ALI_TRANSCRIBE_FAILED" {
            failureCode = "ALI_CLOUD_REVOKED"
        }
        let client = transport
        let task = Task { @MainActor () -> Int in
            var inFlightCancelled = 0
            if let client, !(await client.isQuiescent()) { inFlightCancelled = 1 }
            await client?.cancel()
            return inFlightCancelled
        }
        revocationTask = task
        let inFlightCancelled = await task.value
        if reason != .providerPause {
            RuntimeTrace.record(
                "cloud stream revoked reason=\(reason.rawValue) inFlightCancelled=\(inFlightCancelled) framesDropped=\(arbiter.counts.framesDropped)"
            )
        }
        return inFlightCancelled
    }
}
