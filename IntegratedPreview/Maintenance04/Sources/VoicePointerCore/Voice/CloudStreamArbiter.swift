import Foundation

// K06 host-side stream arbitration (T23 second block).
//
// `CloudAdmissionGate` stays the only authority: it alone issues permits and records pauses. This file
// adds the per-stream latch the Ali backend consults between gate reads, plus the small value types that
// carry the gate handle to the places that need it. Nothing here performs I/O of its own, reads a clock,
// or ever sees transcript text, credentials or provider response bodies.

/// What the settings layer knows about one cloud call: which gate to ask, whose account and model this
/// is, and what the user has allowed right now. The coordinator asks the gate with these values itself;
/// a provider closure cannot mint a permit because `CloudAdmissionPermit` has no public initializer.
public struct CloudAdmissionInputs: Sendable {
    public let gate: CloudAdmissionGate
    public let identity: CloudAdmissionIdentity
    public let requirements: CloudAdmissionRequirements

    public init(
        gate: CloudAdmissionGate,
        identity: CloudAdmissionIdentity,
        requirements: CloudAdmissionRequirements
    ) {
        self.gate = gate
        self.identity = identity
        self.requirements = requirements
    }
}

/// The inputs plus the permit the gate issued for them: everything one cloud stream needs to stay under
/// K06 control after it has started.
@_spi(Testing)
public struct CloudStreamAdmission: Sendable {
    public let inputs: CloudAdmissionInputs
    public let permit: CloudAdmissionPermit

    public init(inputs: CloudAdmissionInputs, permit: CloudAdmissionPermit) {
        self.inputs = inputs
        self.permit = permit
    }
}

/// One cloud stream's local send/deliver decisions. Created from the permit the gate issued when the
/// dictation started; once revoked it never forwards another frame or delivers another event.
///
/// Check cadence (deliberate choice, cheap enough not to sample): the gate is read before the stream
/// prepares (before the key is read or a worker launched), before every audio frame (frames are capped
/// at 100 ms of PCM, so a permit is re-verified at least every 100 ms of audio: about ten small state
/// file reads per second on the gate's own executor, never on the main thread), and before every
/// partial or final transcript is handed on. Between gate reads the latch below is the synchronous
/// last word, so a revocation takes effect before the very next frame or event.
@_spi(Testing)
public final class CloudStreamArbiter: @unchecked Sendable {
    public enum Revocation: String, Sendable, Equatable {
        /// The gate no longer recognises the permit (pause, identity or revision change, expiry, storage fault).
        case permitStale
        /// This stream itself received evidence the gate accepted as a persistent pause.
        case providerPause
        /// Exact evidence arrived but the pause could not be persisted; the stream fails closed.
        case storageUnavailable
    }

    public enum PauseOutcome: Sendable, Equatable {
        /// The gate did not accept the evidence as a pause: nothing is revoked here.
        case notAPause
        case paused(epoch: UInt64)
        case storageUnavailable
    }

    public struct Counts: Sendable, Equatable {
        /// Frames handed to the transport before any revocation.
        public let framesForwarded: Int
        /// Frames refused because the stream was revoked.
        public let framesDropped: Int
        /// Transcript events refused because the stream was revoked or the epoch tag did not match.
        public let eventsDropped: Int
    }

    public let admission: CloudStreamAdmission
    /// The pause epoch this stream started under.
    public let epoch: UInt64

    private let lock = NSLock()
    private var revocationReason: Revocation?
    private var forwarded = 0
    private var droppedFrames = 0
    private var droppedEvents = 0

    public init(admission: CloudStreamAdmission) {
        self.admission = admission
        self.epoch = admission.permit.pauseEpoch
    }

    public var isRevoked: Bool { lock.withLock { revocationReason != nil } }
    public var revocation: Revocation? { lock.withLock { revocationReason } }
    public var counts: Counts {
        lock.withLock {
            Counts(framesForwarded: forwarded, framesDropped: droppedFrames, eventsDropped: droppedEvents)
        }
    }

    /// One-way. Returns true only for the call that performed the revocation; the first reason sticks.
    @discardableResult
    public func revoke(reason: Revocation) -> Bool {
        lock.withLock {
            guard revocationReason == nil else { return false }
            revocationReason = reason
            return true
        }
    }

    /// Synchronous last step before one frame is handed to the transport.
    public func admitFrame() -> Bool {
        lock.withLock {
            guard revocationReason == nil else {
                droppedFrames += 1
                return false
            }
            forwarded += 1
            return true
        }
    }

    /// Synchronous last step before transcript text produced under `startedUnderEpoch` is delivered.
    /// A revoked stream, or an event tagged with any other epoch, has no delivery right.
    public func admitEvent(startedUnderEpoch: UInt64) -> Bool {
        lock.withLock {
            guard revocationReason == nil, startedUnderEpoch == epoch else {
                droppedEvents += 1
                return false
            }
            return true
        }
    }

    /// Re-reads the gate. A permit the gate no longer recognises revokes this stream.
    public func verifyPermit() async -> Bool {
        guard !isRevoked else { return false }
        let inputs = admission.inputs
        let current = await inputs.gate.isPermitCurrent(
            admission.permit, for: inputs.identity, requirements: inputs.requirements
        )
        if !current { revoke(reason: .permitStale) }
        return current && !isRevoked
    }

    /// The only place a provider failure reaches the gate from a stream. The gate alone decides whether
    /// the evidence is exact (same-response 403 + `AllocationQuota.FreeTierOnly`, or 400 + `Arrearage`);
    /// this stream is revoked when, and only when, the gate paused or could not prove the pause safe.
    public func recordProviderFailure(_ evidence: AliFailureEvidence) async -> PauseOutcome {
        let inputs = admission.inputs
        switch await inputs.gate.recordProviderFailure(evidence, for: inputs.identity) {
        case .ignored:
            return .notAPause
        case .paused(let pauseEpoch, _):
            revoke(reason: .providerPause)
            return .paused(epoch: pauseEpoch)
        case .storageUnavailable:
            revoke(reason: .storageUnavailable)
            return .storageUnavailable
        }
    }
}
