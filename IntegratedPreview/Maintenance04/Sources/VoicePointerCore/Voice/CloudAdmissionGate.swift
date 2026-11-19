import Foundation

/// Current-call permissions. Every value defaults closed; the gate never reads credentials
/// or infers upload permission from an older provider-consent setting.
public struct CloudAdmissionRequirements: Sendable, Equatable {
    public let cloudRouteEnabled: Bool
    public let credentialAvailable: Bool
    public let sampleUploadAllowed: Bool
    public let sessionUploadAllowed: Bool

    public init(
        cloudRouteEnabled: Bool = false,
        credentialAvailable: Bool = false,
        sampleUploadAllowed: Bool = false,
        sessionUploadAllowed: Bool = false
    ) {
        self.cloudRouteEnabled = cloudRouteEnabled
        self.credentialAvailable = credentialAvailable
        self.sampleUploadAllowed = sampleUploadAllowed
        self.sessionUploadAllowed = sessionUploadAllowed
    }
}

public enum CloudAdmissionDenial: Sendable, Equatable {
    case storageUnavailable
    case cloudRouteDisabled
    case credentialUnavailable
    case sampleUploadNotAllowed
    case sessionUploadNotAllowed
    case policyDisabled
    case freeOnlyRequired
    case userConfirmationRequired
    case guardEvidenceExpired
    case providerVerificationUnavailable
    case paused(CloudAdmissionPauseReason)
}

public struct CloudAdmissionPermit: Sendable, Equatable {
    public let pauseEpoch: UInt64
    public let stateRevision: UUID
    let identityFingerprint: String

    init(pauseEpoch: UInt64, stateRevision: UUID, identityFingerprint: String) {
        self.pauseEpoch = pauseEpoch
        self.stateRevision = stateRevision
        self.identityFingerprint = identityFingerprint
    }
}

public enum CloudAdmissionDecision: Sendable, Equatable {
    case admitted(CloudAdmissionPermit)
    case denied(CloudAdmissionDenial)
}

public enum CloudAdmissionUpdateResult: Sendable, Equatable {
    case updated
    case unchanged
    case policyDisabled
    case storageUnavailable
}

public enum CloudGuardConfirmationResult: Sendable, Equatable {
    case confirmed
    case freeOnlyPolicyRequired
    case invalidVerificationRevision
    case storageUnavailable
}

public enum CloudQuotaPauseResult: Sendable, Equatable {
    case ignored
    case paused(pauseEpoch: UInt64, persisted: Bool)
    case storageUnavailable
}

public enum CloudQuotaResumeResult: Sendable, Equatable {
    case resumed(pauseEpoch: UInt64)
    case notPaused
    case freeOnlyPolicyRequired
    case invalidVerificationRevision
    case storageUnavailable
}

/// Bound to the identity that produced it, never transferable to a replacement Key.
public struct CloudSetupConfirmationCheckpoint: Sendable {
    fileprivate let identity: CloudAdmissionIdentity
    fileprivate let snapshot: CloudAdmissionStateSnapshot
    public var hadValidConfirmation: Bool { CloudEntryStatus(snapshot: snapshot).isUsable }
    public var hasConfirmedModelQuota: Bool { CloudEntryStatus(snapshot: snapshot).isConfirmed }
}

/// Pure-local, serialized permission gate for cloud requests.
/// A process should own one instance and request a permit immediately before each request.
public actor CloudAdmissionGate {
    /// How long a console confirmation is honoured: 30 days (one hour until 0.5.39). The console switch is
    /// set once and rarely changes, so the person is asked again once a month.
    private static let maximumGuardAge: TimeInterval = 30 * 24 * 3_600
    private let store: CloudAdmissionStateStore
    private var storageFaulted = false

    public init(store: CloudAdmissionStateStore) {
        self.store = store
    }

    public func snapshot(for identity: CloudAdmissionIdentity) -> CloudAdmissionStateSnapshot? {
        guard !storageFaulted else { return nil }
        do {
            return try store.load(for: identity)
        } catch {
            storageFaulted = true
            return nil
        }
    }

    public func setupConfirmationCheckpoint(for identity: CloudAdmissionIdentity) -> CloudSetupConfirmationCheckpoint? {
        snapshot(for: identity).map { .init(identity: identity, snapshot: $0) }
    }

    /// The existing explicit free-only confirm/resume, atomically limited to
    /// the captured revision so a late attempt cannot overwrite newer consent.
    public func confirmSetupGuard(_ checkpoint: CloudSetupConfirmationCheckpoint,
                                  verificationRevision: String, now: Date = Date(),
                                  quotaConfirmed: Bool = true,
                                  catalogFence: CloudCatalogAuthorizationFence? = nil,
                                  catalogTicket: UUID? = nil) -> CloudEntryConfirmation {
        if let catalogFence, let catalogTicket {
            return catalogFence.whileCurrent(catalogTicket) {
                confirmSetupGuard(checkpoint, verificationRevision: verificationRevision, now: now,
                                  quotaConfirmed: quotaConfirmed)
            } ?? .failed
        }
        guard catalogFence == nil && catalogTicket == nil else { return .failed }
        guard !storageFaulted, Self.isValidRevision(verificationRevision) else { return .failed }
        do {
            let (_, result) = try store.transact(for: checkpoint.identity) { current in
                guard current.stateRevision == checkpoint.snapshot.stateRevision else { return (current, CloudEntryConfirmation.failed, false) }
                let next = CloudAdmissionStateSnapshot(
                    policy: .freeOnly, guardEvidence: quotaConfirmed ? .userConfirmed : current.guardEvidence,
                    guardObservedAt: quotaConfirmed ? now : current.guardObservedAt,
                    verificationRevision: verificationRevision,
                    pauseReason: quotaConfirmed ? nil : current.pauseReason, pauseEpoch: current.pauseEpoch,
                    resumeRequestedAt: quotaConfirmed && current.pauseReason != nil ? now : current.resumeRequestedAt,
                    stateRevision: UUID())
                return (next, current.pauseReason == nil ? .confirmed : .resumed, true)
            }
            return result
        } catch {
            storageFaulted = true
            return .failed
        }
    }

    /// Compare-and-restore only this wizard's confirmation. A newer confirmation,
    /// policy withdrawal or quota pause wins. The checkpoint cannot restore a
    /// different credential's confirmation, and restoration invalidates old permits.
    public func rollbackSetupConfirmation(_ checkpoint: CloudSetupConfirmationCheckpoint,
                                          verificationRevision: String) -> CloudAdmissionUpdateResult {
        guard !storageFaulted else { return .storageUnavailable }
        do {
            let (_, changed) = try store.transact(for: checkpoint.identity) { current in
                let before = checkpoint.snapshot
                let ownsGrant = current.verificationRevision == verificationRevision
                    && current.policy == .freeOnly
                    && current.pauseEpoch == before.pauseEpoch
                // Also invalidate an untouched checkpoint: cancellation can
                // arrive before the queued confirm. A late confirm then fails CAS.
                guard ownsGrant || current.stateRevision == before.stateRevision else { return (current, false, false) }
                let next = CloudAdmissionStateSnapshot(
                    policy: before.policy, guardEvidence: before.guardEvidence,
                    guardObservedAt: before.guardObservedAt, verificationRevision: before.verificationRevision,
                    pauseReason: before.pauseReason, pauseEpoch: before.pauseEpoch,
                    resumeRequestedAt: before.resumeRequestedAt, stateRevision: UUID())
                return (next, true, true)
            }
            return changed ? .updated : .unchanged
        } catch {
            storageFaulted = true
            return .storageUnavailable
        }
    }

    /// Explicit policy mutation. Existing `cloudConsent` preferences are not consulted.
    public func setPolicy(
        _ policy: CloudAdmissionPolicy,
        for identity: CloudAdmissionIdentity
    ) -> CloudAdmissionUpdateResult {
        guard !storageFaulted else { return .storageUnavailable }
        do {
            let (_, changed) = try store.transact(for: identity) { current in
                guard current.policy != policy else { return (current, false, false) }
                let next = CloudAdmissionStateSnapshot(
                    policy: policy,
                    guardEvidence: current.guardEvidence,
                    guardObservedAt: current.guardObservedAt,
                    verificationRevision: current.verificationRevision,
                    pauseReason: current.pauseReason,
                    pauseEpoch: current.pauseEpoch,
                    resumeRequestedAt: current.resumeRequestedAt,
                    stateRevision: UUID()
                )
                return (next, true, true)
            }
            return changed ? .updated : .unchanged
        } catch {
            storageFaulted = true
            return .storageUnavailable
        }
    }

    /// Records only what the user explicitly confirmed. It never writes `providerVerified`.
    /// This method does not clear a quota pause; resuming requires the separate explicit method.
    public func confirmFreeOnlyGuard(
        for identity: CloudAdmissionIdentity,
        verificationRevision: String,
        observedAt: Date = Date()
    ) -> CloudGuardConfirmationResult {
        guard Self.isValidRevision(verificationRevision) else { return .invalidVerificationRevision }
        guard !storageFaulted else { return .storageUnavailable }
        do {
            let (_, result) = try store.transact(for: identity) { current in
                guard current.policy == .freeOnly else { return (current, false, false) }
                let next = CloudAdmissionStateSnapshot(
                    policy: current.policy,
                    guardEvidence: .userConfirmed,
                    guardObservedAt: observedAt,
                    verificationRevision: verificationRevision,
                    pauseReason: current.pauseReason,
                    pauseEpoch: current.pauseEpoch,
                    resumeRequestedAt: current.resumeRequestedAt,
                    stateRevision: UUID()
                )
                return (next, true, true)
            }
            return result ? .confirmed : .freeOnlyPolicyRequired
        } catch {
            storageFaulted = true
            return .storageUnavailable
        }
    }

    /// Pauses only on bounded status and code evidence from one HTTP response.
    /// A WebSocket task-failed code must not borrow an earlier handshake status.
    public func recordProviderFailure(
        _ evidence: AliFailureEvidence,
        for identity: CloudAdmissionIdentity
    ) -> CloudQuotaPauseResult {
        let reason: CloudAdmissionPauseReason
        switch (evidence.source, evidence.httpStatus, evidence.providerCode) {
        case (.httpResponse, 403, .freeTierOnly):
            reason = .freeQuotaExhausted
        case (.httpResponse, 400, .arrearage):
            reason = .accountBalanceBlocked
        default:
            return .ignored
        }
        guard !storageFaulted else { return .storageUnavailable }
        do {
            let (_, epoch) = try store.transact(for: identity) { current in
                let nextEpoch = current.pauseEpoch == UInt64.max ? UInt64.max : current.pauseEpoch + 1
                let next = CloudAdmissionStateSnapshot(
                    policy: current.policy,
                    guardEvidence: current.guardEvidence,
                    guardObservedAt: current.guardObservedAt,
                    verificationRevision: current.verificationRevision,
                    pauseReason: reason,
                    pauseEpoch: nextEpoch,
                    resumeRequestedAt: nil,
                    stateRevision: UUID()
                )
                return (next, nextEpoch, true)
            }
            return .paused(pauseEpoch: epoch, persisted: true)
        } catch {
            // The process stays fail-closed. A persistence error is surfaced so callers do
            // not claim that the pause will survive restart.
            storageFaulted = true
            return .storageUnavailable
        }
    }

    /// Clears a persistent pause only after a fresh explicit user recheck for this identity.
    public func recheckAndResumeAfterQuotaPause(
        for identity: CloudAdmissionIdentity,
        verificationRevision: String,
        observedAt: Date = Date(),
        resumeRequestedAt: Date = Date()
    ) -> CloudQuotaResumeResult {
        guard Self.isValidRevision(verificationRevision) else { return .invalidVerificationRevision }
        guard !storageFaulted else { return .storageUnavailable }
        do {
            let (_, outcome) = try store.transact(for: identity) { current in
                guard current.pauseReason != nil else {
                    return (current, ResumeMutation.notPaused, false)
                }
                let next = CloudAdmissionStateSnapshot(
                    policy: current.policy,
                    guardEvidence: .userConfirmed,
                    guardObservedAt: observedAt,
                    verificationRevision: verificationRevision,
                    pauseReason: nil,
                    pauseEpoch: current.pauseEpoch,
                    resumeRequestedAt: resumeRequestedAt,
                    stateRevision: UUID()
                )
                return (next, ResumeMutation.resumed(current.pauseEpoch), true)
            }
            switch outcome {
            case .resumed(let epoch): return .resumed(pauseEpoch: epoch)
            case .notPaused: return .notPaused
            case .policyDisabled: return .freeOnlyPolicyRequired
            }
        } catch {
            storageFaulted = true
            return .storageUnavailable
        }
    }

    public func admission(
        for identity: CloudAdmissionIdentity,
        requirements: CloudAdmissionRequirements = CloudAdmissionRequirements()
    ) -> CloudAdmissionDecision {
        guard !storageFaulted else { return .denied(.storageUnavailable) }
        let state: CloudAdmissionStateSnapshot
        do {
            state = try store.load(for: identity)
        } catch {
            storageFaulted = true
            return .denied(.storageUnavailable)
        }
        if let denial = Self.denial(for: state, requirements: requirements, now: Date()) {
            return .denied(denial)
        }
        return .admitted(CloudAdmissionPermit(
            pauseEpoch: state.pauseEpoch,
            stateRevision: state.stateRevision,
            identityFingerprint: identity.persistenceIdentifier
        ))
    }

    /// Recheck this before applying any response or incremental result. A pause, identity
    /// change, or state revision change makes a previously issued permit stale.
    public func isPermitCurrent(
        _ permit: CloudAdmissionPermit,
        for identity: CloudAdmissionIdentity,
        requirements: CloudAdmissionRequirements
    ) -> Bool {
        guard !storageFaulted,
              permit.identityFingerprint == identity.persistenceIdentifier else { return false }
        let state: CloudAdmissionStateSnapshot
        do {
            state = try store.load(for: identity)
        } catch {
            storageFaulted = true
            return false
        }
        guard Self.denial(for: state, requirements: requirements, now: Date()) == nil else { return false }
        return permit.pauseEpoch == state.pauseEpoch && permit.stateRevision == state.stateRevision
    }

    private enum ResumeMutation {
        case resumed(UInt64)
        case notPaused
        case policyDisabled
    }

    private static func denial(
        for state: CloudAdmissionStateSnapshot,
        requirements: CloudAdmissionRequirements,
        now: Date
    ) -> CloudAdmissionDenial? {
        guard requirements.cloudRouteEnabled else { return .cloudRouteDisabled }
        guard requirements.credentialAvailable else { return .credentialUnavailable }
        guard requirements.sampleUploadAllowed else { return .sampleUploadNotAllowed }
        guard requirements.sessionUploadAllowed else { return .sessionUploadNotAllowed }
        if let reason = state.pauseReason { return .paused(reason) }
        // The console quota checkbox is a recommendation, not upload authorization.
        // Audio still requires all four per-call consent/credential conditions above.
        return nil
    }

    private static func isValidRevision(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
