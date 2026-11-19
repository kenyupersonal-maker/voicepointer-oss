import Foundation

// K06 user-facing opt-in for the Aliyun cloud route (T23 third block).
//
// Pure Foundation, so the self-tests run it. The entry is offered in the settings by default, so a person can
// paste their own key; every switch behind it stays closed until they turn it on. The UserDefaults flag
// `cloud.entry.visible` is only a kill switch: while it is explicitly false `CloudEntry.inputs` is nil, which
// the coordinator reads as "not configured" and runs the dictation on the local route, and the legacy
// consent set is left exactly as it was. Nothing here reads a credential: only "is a key saved" and its
// non-secret revision come in, as `CloudEntryCredential`.

/// What the user chose for the Aliyun cloud route, and for Aliyun enhancing the local route. Every value
/// defaults closed.
public struct CloudEntryPreferences: Sendable, Equatable {
    /// Kill switch for the whole entry. The entry is offered unless this is explicitly false; turn it off with
    /// `defaults write com.kenyu.voicepointer.mac cloud.entry.visible -bool false`.
    public static let visibleKey = "cloud.entry.visible"
    /// The user switched the cloud route on in the settings section.
    public static let routeEnabledKey = "cloud.entry.routeEnabled"
    /// The user allows dictation audio to be sent to Aliyun (sample and session upload).
    public static let uploadConsentKey = "cloud.entry.uploadConsent"
    /// The user switched on "用于增强本地识别": while a bundled local route is selected, the same speech also goes
    /// to the Aliyun recognizer. A missing value reads as off.
    public static let enhanceLocalKey = "cloud.entry.enhanceLocal"
    /// The selection to return to when the cloud route is switched off again.
    public static let previousModeKey = "cloud.entry.previousMode"
    public static let previousRouteIDKey = "cloud.entry.previousRouteID"

    public var visible: Bool
    public var routeEnabled: Bool
    public var uploadConsent: Bool
    public var enhanceLocal: Bool

    public init(
        visible: Bool = true, routeEnabled: Bool = false, uploadConsent: Bool = false, enhanceLocal: Bool = false
    ) {
        self.visible = visible
        self.routeEnabled = routeEnabled
        self.uploadConsent = uploadConsent
        self.enhanceLocal = enhanceLocal
    }

    /// A missing switch reads as false. A missing kill switch reads as "offered".
    public static func load(from defaults: UserDefaults = .standard) -> CloudEntryPreferences {
        CloudEntryPreferences(
            visible: defaults.object(forKey: visibleKey) == nil ? true : defaults.bool(forKey: visibleKey),
            routeEnabled: defaults.bool(forKey: routeEnabledKey),
            uploadConsent: defaults.bool(forKey: uploadConsentKey),
            enhanceLocal: defaults.bool(forKey: enhanceLocalKey)
        )
    }

    public static func setRouteEnabled(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: routeEnabledKey)
    }

    public static func setUploadConsent(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: uploadConsentKey)
    }

    public static func setEnhanceLocal(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: enhanceLocalKey)
    }

    public static func rememberPreviousSelection(
        mode: VoiceInputMode, routeID: String, in defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: previousModeKey)
        defaults.set(routeID, forKey: previousRouteIDKey)
    }

    /// The selection saved when the cloud route was switched on. Never the cloud route itself.
    public static func previousSelection(
        in defaults: UserDefaults = .standard
    ) -> (mode: VoiceInputMode, routeID: String)? {
        guard let rawMode = defaults.string(forKey: previousModeKey),
              let mode = VoiceInputMode(rawValue: rawMode),
              let routeID = defaults.string(forKey: previousRouteIDKey),
              !routeID.isEmpty, routeID != CloudEntry.routeID else { return nil }
        return (mode, routeID)
    }

    /// The Ali backend still checks the older per-provider consent (`AliSpeechBackend.start`). The route's id
    /// (`CloudEntry.provider`) is granted here only while the entry is visible, the route is on and the user
    /// allowed the upload; the enhancement's id (`CloudEntry.enhanceConsentID`) only while the entry is visible,
    /// the enhancement is on and the user allowed the upload. Withdrawing any of them also stops a running cloud
    /// dictation, or the cloud branch of an enhanced one, through `cloudAuthorizationChanged`. The enhancement's
    /// id is never taken over from `stored`: it exists only while these switches say so. The gate itself never
    /// reads this set.
    public func legacyConsent(merging stored: Set<String>) -> Set<String> {
        var result = stored
        result.remove(CloudEntry.enhanceConsentID)
        guard visible, uploadConsent else { return result }
        if routeEnabled { result.insert(CloudEntry.provider) }
        if enhanceLocal { result.insert(CloudEntry.enhanceConsentID) }
        return result
    }

    /// The one switch a cloud dictation for `purpose` needs. Never both: a route switch left on (a crash between
    /// two writes, an older version) must not send an enhanced local dictation, and the other way round.
    public func isEnabled(for purpose: CloudEntryPurpose) -> Bool {
        switch purpose {
        case .route: return routeEnabled
        case .enhanceLocal: return enhanceLocal
        }
    }
    /// Permission and eligibility only. Aliyun admission remains a separate
    /// per-session gate; other providers never inherit its quota pause.
    public func enhancementAuthorized(for selection: VoiceInputSelection,
                                      provider: OnlineAPIProvider = .aliyunBailian) -> Bool {
        visible && uploadConsent && enhanceLocal && CloudEntry.canEnhance(selection, provider: provider)
    }
}

/// Key presence and its non-secret revision, as `CloudCredentialStore.isSaved` and `credentialRevision` report them.
public struct CloudEntryCredential: Sendable, Equatable {
    public let isSaved: Bool
    public let revision: String?

    public init(isSaved: Bool, revision: String?) {
        self.isSaved = isSaved
        self.revision = revision
    }

    public static let missing = CloudEntryCredential(isSaved: false, revision: nil)
}

/// The one-line answer for the settings section, derived from the gate's persisted state.
public enum CloudEntryStatus: Sendable, Equatable {
    /// The state could not be read; the gate is failing closed.
    case unavailable
    case unconfirmed
    case confirmed(validUntil: Date)
    case expired
    case paused(CloudAdmissionPauseReason)

    /// How long a console confirmation is honoured. This mirrors the gate's private `maximumGuardAge`
    /// (30 days); the self-test pins both to the same boundary.
    public static let confirmationLifetime: TimeInterval = 30 * 24 * 3_600

    public init(snapshot: CloudAdmissionStateSnapshot?, now: Date = Date()) {
        guard let snapshot else {
            self = .unavailable
            return
        }
        if let reason = snapshot.pauseReason {
            self = .paused(reason)
            return
        }
        guard snapshot.policy == .freeOnly, snapshot.guardEvidence == .userConfirmed else {
            self = .unconfirmed
            return
        }
        guard let observedAt = snapshot.guardObservedAt, observedAt.timeIntervalSince1970.isFinite else {
            self = .unconfirmed
            return
        }
        self = .confirmed(validUntil: observedAt.addingTimeInterval(Self.confirmationLifetime))
    }

    public var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }

    /// Quota acknowledgment never controls whether audio may be uploaded.
    public var isUsable: Bool {
        switch self {
        case .unconfirmed, .confirmed, .expired: true
        case .unavailable, .paused: false
        }
    }

    public func title(timeZone: TimeZone = .current) -> String {
        switch self {
        case .unavailable:
            return "状态读不到，云端保持关闭"
        case .unconfirmed:
            return "未确认"
        case .confirmed:
            return "已确认"
        case .expired:
            return "已确认"
        case .paused(.freeQuotaExhausted):
            return "已暂停：免费额度用完"
        case .paused(.accountBalanceBlocked):
            return "已暂停：账户欠费或余额不足"
        }
    }
}

public enum CloudEntryConfirmation: Sendable, Equatable {
    case confirmed
    case resumed
    case failed
}

/// What a cloud admission is asked for: the Aliyun route itself, or Aliyun enhancing the local route
/// ("用于增强本地识别"). Each purpose is admitted by its own switch only (`CloudEntryPreferences.isEnabled(for:)`).
public enum CloudEntryPurpose: Sendable, Equatable {
    case route
    case enhanceLocal

    /// The purpose of a dictation on `routeID`: the Aliyun route asks as itself; any other route can only be
    /// enhanced.
    public init(routeID: String) {
        self = routeID == CloudEntry.routeID ? .route : .enhanceLocal
    }
}

/// The single Aliyun configuration this entry manages, and what the settings turn into for the K06 gate.
public enum CloudEntry {
    public static let routeID = "aliyun"
    /// Provider label shared by the current settings entry and menu; generic menu wording accepts any label.
    public static let displayName = "阿里云"
    public static let provider = "aliyun-beijing"
    /// The legacy consent id of "用于增强本地识别" (`CloudEntryPreferences.legacyConsent`). Only the coordinator
    /// reads it, frozen with a dictation; it is never saved in the provider settings.
    public static let enhanceConsentID = "aliyun-beijing.enhanceLocal"
    /// A fixed local credential slot. It is not an account identifier and is never a key.
    public static let accountReference = "default"
    public static let region = "cn-beijing"
    public static let workspace = "default"
    /// Must equal the model `AliWireCodec` puts in the start message: a confirmation covers this model only.
    public static let modelID = "qwen-audio-3.0-asr-flash-streaming"
    public static let consoleURL = "https://bailian.console.aliyun.com/"
    /// Alibaba Cloud's own page on creating and configuring a Model Studio API key.
    public static let keyHelpURL = "https://help.aliyun.com/zh/model-studio/get-api-key"
    public static let keyPageURL = "https://bailian.console.aliyun.com/cn-beijing/model/settings/api-key"
    public static let freeQuotaURL = "https://bailian.console.aliyun.com/cn-beijing/costing-balance/free-quota"
    /// The languages the Aliyun route recognizes; the settings offer nothing else for it.
    public static let supportedLanguages = ["auto", "zh", "en"]
    /// A dictation the gate denies on the Aliyun route runs on this local route instead. The settings word
    /// their cards after it, so `CloudDictationStart.localFallbackRouteID` is this value.
    public static let localFallbackRouteID = "qwen17-rolling"

    /// Shared configured predicate. Only the existing presence boolean enters it, never a credential.
    public static func isConfigured(visible: Bool, keySaved: Bool) -> Bool {
        visible && keySaved
    }

    public static func makeIdentity(credentialRevision: String) throws -> CloudAdmissionIdentity {
        try CloudAdmissionIdentity(
            provider: provider,
            accountReference: accountReference,
            credentialRevision: credentialRevision,
            region: region,
            workspace: workspace,
            modelID: modelID
        )
    }

    /// nil means "unknown", which the coordinator always treats as a denial. Nil unless the flag is on, a key
    /// is saved and its revision exists. A permit still needs the gate's own answer for these inputs. The
    /// route requirement is the switch of `purpose` only; both purposes share the identity, so one
    /// confirmation and one quota pause cover both.
    public static func inputs(
        preferences: CloudEntryPreferences,
        gate: CloudAdmissionGate,
        credential: CloudEntryCredential,
        purpose: CloudEntryPurpose = .route
    ) -> CloudAdmissionInputs? {
        guard preferences.visible, credential.isSaved, let revision = credential.revision,
              let identity = try? makeIdentity(credentialRevision: revision) else { return nil }
        return CloudAdmissionInputs(
            gate: gate,
            identity: identity,
            requirements: CloudAdmissionRequirements(
                cloudRouteEnabled: preferences.isEnabled(for: purpose),
                credentialAvailable: credential.isSaved,
                sampleUploadAllowed: preferences.uploadConsent,
                sessionUploadAllowed: preferences.uploadConsent
            )
        )
    }

    /// The confirm button. Records `freeOnly` for this exact identity, then only what the user said
    /// (`userConfirmed`): the app cannot check the console switch, so nothing else is ever written. A paused
    /// identity goes through the gate's explicit recheck-and-resume instead, which confirms as well.
    public static func confirm(
        gate: CloudAdmissionGate,
        identity: CloudAdmissionIdentity,
        now: Date = Date()
    ) async -> CloudEntryConfirmation {
        await confirmOnGate(gate: gate, identity: identity, now: now)
    }

    /// Identical policy, identity, 30-day evidence and quota-resume rules. A
    /// setup fence can wrap these synchronous steps without actor reentrancy.
    static func confirmOnGate(gate: isolated CloudAdmissionGate, identity: CloudAdmissionIdentity,
                              now: Date = Date()) -> CloudEntryConfirmation {
        let policy = gate.setPolicy(.freeOnly, for: identity)
        guard policy == .updated || policy == .unchanged else { return .failed }
        let revision = "user-console-\(UUID().uuidString)"
        if gate.snapshot(for: identity)?.pauseReason != nil {
            let resumed = gate.recheckAndResumeAfterQuotaPause(
                for: identity, verificationRevision: revision, observedAt: now, resumeRequestedAt: now
            )
            if case .resumed = resumed { return .resumed }
            return .failed
        }
        let confirmed = gate.confirmFreeOnlyGuard(
            for: identity, verificationRevision: revision, observedAt: now
        )
        return confirmed == .confirmed ? .confirmed : .failed
    }
}
