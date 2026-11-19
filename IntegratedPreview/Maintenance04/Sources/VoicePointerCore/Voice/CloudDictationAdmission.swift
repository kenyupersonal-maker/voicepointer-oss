import Foundation

/// Supplies the gate handle, identity and current-call permissions for one cloud dictation. The app
/// layer owns the settings these come from. `nil` (the default everywhere today, because no setting
/// records the user's confirmation yet) means "unknown", which is always a denial.
public typealias CloudAdmissionInputsProvider =
    @MainActor @Sendable (VoiceInputSnapshot) async -> CloudAdmissionInputs?

/// K06 decision taken once, at the start of a dictation on a cloud route.
@_spi(Testing)
public enum CloudDictationStart: Sendable {
    case admitted(CloudStreamAdmission)
    /// `reason` is a finite, trace-safe label; it never carries user text or provider content.
    case denied(reason: String)

    /// A denied cloud dictation runs on this local route instead.
    public static let localFallbackRouteID = CloudEntry.localFallbackRouteID
    /// A targetless dictation may keep its local interaction, but must never open an unused cloud stream.
    public static func targetlessSnapshot(for snapshot: VoiceInputSnapshot) -> VoiceInputSnapshot? {
        guard snapshot.selection.mode == .voiceNative,
              OnlineAPIConfiguration.cloudRouteIDs.contains(snapshot.selection.routeID)
        else { return snapshot }
        return localFallbackSnapshot(for: snapshot)
    }

    /// Anything other than an explicit permit from the gate is a denial.
    @MainActor
    public static func resolve(
        snapshot: VoiceInputSnapshot,
        provider: CloudAdmissionInputsProvider?
    ) async -> CloudDictationStart {
        guard let provider, let inputs = await provider(snapshot) else {
            return .denied(reason: "notConfigured")
        }
        switch await inputs.gate.admission(for: inputs.identity, requirements: inputs.requirements) {
        case .admitted(let permit):
            return .admitted(CloudStreamAdmission(inputs: inputs, permit: permit))
        case .denied(let denial):
            return .denied(reason: denial.traceLabel)
        }
    }

    /// The same dictation (session, language, lexicon revision, hot words) on the local route.
    public static func localFallbackSnapshot(for snapshot: VoiceInputSnapshot) -> VoiceInputSnapshot? {
        guard let selection = try? VoiceInputSelection(
            mode: .voiceNative, routeID: localFallbackRouteID, language: snapshot.selection.language
        ) else { return nil }
        return try? VoiceInputSnapshot(
            sessionID: snapshot.sessionID, selection: selection, lexiconRevision: snapshot.lexiconRevision,
            localHotwords: snapshot.localHotwords, localContext: snapshot.localContext, contextAppKey: snapshot.contextAppKey
        )
    }
}

extension CloudAdmissionDenial {
    /// Exhaustive on purpose: a new denial must be given a label before the module builds.
    var traceLabel: String {
        switch self {
        case .storageUnavailable: return "storageUnavailable"
        case .cloudRouteDisabled: return "cloudRouteDisabled"
        case .credentialUnavailable: return "credentialUnavailable"
        case .sampleUploadNotAllowed: return "sampleUploadNotAllowed"
        case .sessionUploadNotAllowed: return "sessionUploadNotAllowed"
        case .policyDisabled: return "policyDisabled"
        case .freeOnlyRequired: return "freeOnlyRequired"
        case .userConfirmationRequired: return "userConfirmationRequired"
        case .guardEvidenceExpired: return "guardEvidenceExpired"
        case .providerVerificationUnavailable: return "providerVerificationUnavailable"
        case .paused(let reason): return "paused.\(reason.rawValue)"
        }
    }
}
