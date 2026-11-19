import Foundation

/// Non-secret connection state shared by settings and the menu. A confirmation is never a connection check.
public enum OnlineConnectionCheckState: Sendable, Equatable {
    case idle
    case running
    case passed(Date)
    case failed(CloudConnectionCheck.Failure)
}

/// Discards an old connection result when the key changes, disappears or the entry is hidden.
public struct OnlineConnectionCheckLedger: Sendable, Equatable {
    public private(set) var state: OnlineConnectionCheckState = .idle
    private var generation = UUID()

    public init() {}

    public mutating func begin() -> UUID {
        generation = UUID()
        state = .running
        return generation
    }

    public mutating func invalidate() {
        generation = UUID()
        state = .idle
    }

    public func isCurrent(_ generation: UUID) -> Bool { generation == self.generation }

    public mutating func complete(_ outcome: CloudConnectionCheck.Outcome, generation: UUID, now: Date = Date()) {
        guard generation == self.generation else { return }
        switch outcome {
        case .connected: state = .passed(now)
        case .failed(let failure): state = .failed(failure)
        }
    }
}

/// T2's temporary projection, ready for T4's state layer. It only consumes the settings' existing facts.
public struct OnlineRouteMenuState: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case switchRoute, openSettings }
    public enum StatusKind: Sendable, Equatable { case reading, needsConfiguration, updating, unverified, checking, passed, unavailable, needsConfirmation, expired, quotaExhausted, balanceBlocked, network, timeout, invalidKey, failed }
    public let statusKind: StatusKind
    public let baseTitle: String
    public let statusSuffix: String
    public let selected: Bool
    public let action: Action
    public var title: String { baseTitle + statusSuffix }

    public init(configuration: OnlineAPIConfiguration?, statusKind: StatusKind,
                mayUse: Bool, selection: VoiceInputSelection?, health: EngineHealthState? = nil) {
        self.statusKind = health.map(Self.healthStatus) ?? statusKind
        baseTitle = OnlineAPIStrings.onlineMenuTitle(configuration?.provider)
        if let health { statusSuffix = health.statusTitle.isEmpty ? "" : " · " + health.statusTitle }
        else { statusSuffix = OnlineAPIStrings.onlineMenuSuffix(statusKind) }
        selected = configuration.map { selection?.mode == .voiceNative && selection?.routeID == $0.routeID } ?? false
        action = mayUse && self.statusKind == .passed ? .switchRoute : .openSettings
    }
    public static func healthStatus(_ health: EngineHealthState) -> StatusKind {
        switch health {
        case .idle, .failed(.notNetworkVerified, _): .unverified
        case .checking: .checking
        case .passed: .passed
        case .failed(.noKey, _): .needsConfiguration
        case .failed(.invalidKey, _): .invalidKey
        case .failed(.network, _): .network
        case .failed(.timeout, _): .timeout
        case .failed(.freeQuotaExhausted, _): .quotaExhausted
        case .failed(.balanceDue, _): .balanceBlocked
        case .failed: .failed
        }
    }

    public init(
        loaded: Bool, keySaved: Bool, credentialChanging: Bool = false,
        preferences: CloudEntryPreferences, status: CloudEntryStatus,
        check: OnlineConnectionCheckState, selection: VoiceInputSelection?, label: String?
    ) {
        let configured = CloudEntry.isConfigured(visible: preferences.visible, keySaved: keySaved)
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        baseTitle = configured && !name.isEmpty ? "在线 API 识别（\(name)）" : "在线 API 识别"
        selected = selection?.mode == .voiceNative && selection?.routeID == CloudEntry.routeID
        var checkFailed = false
        if !loaded {
            statusKind = .reading
        } else if !configured {
            statusKind = .needsConfiguration
        } else if credentialChanging {
            statusKind = .updating
        } else {
            switch check {
            case .idle: statusKind = .unverified
            case .running: statusKind = .checking
            case .passed:
                // A past handshake cannot make a presently blocked route look usable.
                switch status {
                case .confirmed, .unconfirmed, .expired: statusKind = .passed
                case .unavailable: statusKind = .unavailable
                case .paused(.freeQuotaExhausted): statusKind = .quotaExhausted
                case .paused(.accountBalanceBlocked): statusKind = .balanceBlocked
                }
            case .failed(let failure):
                checkFailed = true
                switch failure {
                case .network: statusKind = .network
                case .timeout: statusKind = .timeout
                case .rejectedKey, .noKey, .keyUnreadable: statusKind = .invalidKey
                case .freeQuotaExhausted: statusKind = .quotaExhausted
                default: statusKind = .failed
                }
            }
        }
        statusSuffix = OnlineAPIStrings.onlineMenuSuffix(statusKind)
        // Same status predicate as the settings; it checks storage/policy/evidence/age/quota pause.
        // Unlike the settings' explicit opt-in button, a menu click cannot create either permission.
        action = loaded && configured && !credentialChanging && !checkFailed
            && preferences.routeEnabled && preferences.uploadConsent && status.isUsable
            && selection.map { CloudEntry.supportedLanguages.contains($0.language) } == true
            ? .switchRoute : .openSettings
    }

    /// No writes at all on refusal. A write failure leaves selection and cloud switches as they were.
    @MainActor
    @discardableResult
    public func select(
        store: ProviderSettingsStore,
        onPreferencesChanged: (ProviderPreferences) -> Void,
        notify: () -> Void
    ) throws -> Bool {
        guard action == .switchRoute else { return false }
        var preferences = store.value
        preferences.selection = try VoiceInputSelection(
            mode: .voiceNative, routeID: preferences.onlineAPIConfiguration?.routeID ?? CloudEntry.routeID, language: preferences.selection.language
        )
        try ProviderPreferencesCommit.persistAndNotify(
            preferences, store: store, onPreferencesChanged: onPreferencesChanged, notify: notify
        )
        return true
    }
}

/// The settings and menu share the exact successful persistence → callback → notification sequence.
/// Reconciliation remains at the caller's existing boundary; this function never opens a cloud switch.
public enum ProviderPreferencesCommit {
    @MainActor
    public static func persistAndNotify(
        _ preferences: ProviderPreferences, store: ProviderSettingsStore,
        onPreferencesChanged: (ProviderPreferences) -> Void, notify: () -> Void
    ) throws {
        try store.update(preferences)
        onPreferencesChanged(preferences)
        notify()
    }
}
