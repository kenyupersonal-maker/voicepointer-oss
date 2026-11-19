// Block 1 — SpeechStartupPolicy.swift
// Decides whether a startup-time readiness/failure state justifies rejecting
// the session right after backend.start returns.

public enum SpeechStartupPolicy {

    /// - Returns: true if the session should be rejected (cancelled) immediately.
    public static func shouldReject(
        deliveryKind: SpeechDeliveryKind,
        ready: Bool,
        failed: Bool
    ) -> Bool {
        // Any confirmed failure rejects regardless of delivery kind.
        if failed { return true }

        switch deliveryKind {
        case .externalEditor:
            // Editor-delivery backends must be fully ready before start returns,
            // because the first deliverable may be requested immediately.
            return !ready
        case .transcriptStream:
            // Streaming backends may still be preparing (network/model loading)
            // in the background after start returns; readiness arrives as an
            // async event. Pending readiness is a valid, non-rejected state.
            return false
        }
    }
}

// Design notes (no behavior):
// - start() throws for synchronous/immediate errors (bad config, missing model
//   file). Those never reach this policy because throwing already fails startup.
// - A later .failed event is delivered through the existing backend event
//   callback and handled by the Coordinator's normal failure cleanup path.
// - This policy never fabricates readiness (no fake .ready), never polls, and
//   never introduces fixed sleeps to "wait" for readiness.
