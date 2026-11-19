// T4 2026-10-02: Service adapters receive safe presence/metadata only; never API Key contents.
import Foundation

public enum OnlineCredentialState: String, Sendable { case missing, saved, unreadable }
public struct OnlineAPICapabilities: Sendable, Equatable {
    public let canReadExpiry: Bool, canReadQuota: Bool, supportsLightweightValidation: Bool
    public init(canReadExpiry: Bool = false, canReadQuota: Bool = false, supportsLightweightValidation: Bool = false) {
        self.canReadExpiry = canReadExpiry; self.canReadQuota = canReadQuota
        self.supportsLightweightValidation = supportsLightweightValidation
    }
}
public struct OnlineAPIReadOnlyMetadata: Sendable, Equatable {
    public let expiresAt: Date?
    public let remainingFreeUnits: Int?
    /// Only a trusted service response may supply metadata; there is no key-content parsing API.
    public init(serviceExpiresAt: Date? = nil, serviceRemainingFreeUnits: Int? = nil) {
        expiresAt = serviceExpiresAt; remainingFreeUnits = serviceRemainingFreeUnits.map { max(0, $0) }
    }
}
public enum OnlineAPIValidation: Sendable, Equatable {
    case verified, notNetworkVerified, failed(HealthFailureReason)
    public var healthResult: EngineHealthResult {
        switch self { case .verified: .passed(.providerVerified)
        case .notNetworkVerified: .failed(.notNetworkVerified)
        case .failed(let reason): .failed(reason) }
    }
}
@MainActor public protocol OnlineAPIHealthAdapter {
    var displayName: String { get }
    var keyHelpURL: URL { get }
    var docURL: URL { get }
    var capabilities: OnlineAPICapabilities { get }
    func validate(credential: OnlineCredentialState) async -> OnlineAPIValidation
}

/// The app injects the configuration page's selected-model, zero-audio probe.
/// The inert default is used by fixtures and cannot claim network verification from presence alone.
@MainActor public struct AliyunOnlineAPIProvider: OnlineAPIHealthAdapter {
    public let displayName = "阿里云"
    public let keyHelpURL = URL(string: CloudEntry.keyHelpURL)!
    public let docURL: URL
    public let capabilities: OnlineAPICapabilities
    private let checkSaved: (@MainActor () async -> OnlineAPIValidation)?
    public init(docURL: URL = URL(string: CloudEntry.keyHelpURL)!,
                checkSaved: (@MainActor () async -> OnlineAPIValidation)? = nil) {
        self.docURL = docURL; self.checkSaved = checkSaved
        capabilities = OnlineAPICapabilities(supportsLightweightValidation: checkSaved != nil)
    }
    public func validate(credential: OnlineCredentialState) async -> OnlineAPIValidation {
        switch credential {
        case .missing: return .failed(.noKey)
        case .unreadable: return .failed(.invalidKey)
        case .saved: return await checkSaved?() ?? .notNetworkVerified
        }
    }
    /// Adapter boundary for existing Ali failure evidence; no raw service message leaves it.
    public static func failure(_ value: CloudConnectionCheck.Failure) -> HealthFailureReason {
        switch value {
        case .noKey: .noKey
        case .keyUnreadable, .rejectedKey: .invalidKey
        case .freeQuotaExhausted: .freeQuotaExhausted
        case .network: .network
        case .timeout: .timeout
        case .noAccess: .noAccess
        case .balanceDue: .balanceDue
        case .rateLimited: .rateLimited
        case .modelUnavailable: .modelUnavailable
        case .serviceUnavailable: .serviceUnavailable
        case .worker: .worker
        case .taskStartFailed: .taskStartFailed
        case .notClosed: .notClosed
        case .unknown: .unavailable
        }
    }
}

/// Two UI entrances read this object; its storage key is the original preference, with no enabling migration.
@MainActor public final class OnlineEnhancementPreferenceSource {
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private let uploadAuthorized: () -> Bool
    private let reconcileStored: ((VoiceInputSelection, Bool, Bool) -> Void)?
    private var observed: Bool
    public var onChange: (() -> Void)?
    public init(defaults: UserDefaults = .standard) {
        let switches = CloudEntryPreferences.load(from: defaults)
        observed = switches.enhanceLocal && switches.visible && switches.uploadConsent
        read = { CloudEntryPreferences.load(from: defaults).enhanceLocal }
        write = { CloudEntryPreferences.setEnhanceLocal($0, in: defaults) }
        uploadAuthorized = {
            let value = CloudEntryPreferences.load(from: defaults)
            return value.visible && value.uploadConsent
        }
        reconcileStored = { selection, available, visible in
            CloudEntryPreferences.reconcile(.init(selection: selection, credentialAvailable: available, entryVisible: visible), in: defaults)
        }
    }
    public init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read; self.write = write; uploadAuthorized = { true }
        reconcileStored = nil; observed = read()
    }
    /// Display permission-backed state, while retaining the remembered preference for explicit user actions.
    /// A revoked permission is never restored by reading or synchronizing this source.
    public var enhanceLocalWithOnlineAPI: Bool { read() && uploadAuthorized() }
    public func setFromUser(_ wanted: Bool, configured: Bool, authorized: Bool) {
        guard !wanted || (configured && authorized) else { return }
        if read() != wanted { write(wanted) }
        synchronize()
    }
    public func synchronize() {
        let current = enhanceLocalWithOnlineAPI
        guard current != observed else { return }
        observed = current; onChange?()
    }  // Save/check/launch refreshes never enable a switch.
    public func reconcile(selection: VoiceInputSelection, credentialAvailable: Bool, visible: Bool) {
        if let reconcileStored { reconcileStored(selection, credentialAvailable, visible) }
        else if read() && (!credentialAvailable || !visible) { write(false) }
        synchronize()
    }
    public func isEffective(method: RecognitionMethod, configured: Bool) -> Bool {
        method == .local && configured && enhanceLocalWithOnlineAPI
    }
    public func isEffective(selection: VoiceInputSelection, configured: Bool,
                            provider: OnlineAPIProvider = .aliyunBailian) -> Bool {
        configured && enhanceLocalWithOnlineAPI && CloudEntry.canEnhance(selection, provider: provider)
    }
}

@MainActor public final class OnlineAPIConfigViewModel {
    public private(set) var phase: SettingsLoadState = .idle
    public private(set) var credential: OnlineCredentialState = .missing
    public private(set) var isVisible = true
    public private(set) var userLabel: String?
    public private(set) var metadata: OnlineAPIReadOnlyMetadata?
    public let provider: any OnlineAPIHealthAdapter
    public let enhancement: OnlineEnhancementPreferenceSource
    public var onChange: (() -> Void)?
    public init(provider: any OnlineAPIHealthAdapter, enhancement: OnlineEnhancementPreferenceSource) {
        self.provider = provider; self.enhancement = enhancement
    }
    public var keySaved: Bool { credential == .saved }
    public var isConfigured: Bool { CloudEntry.isConfigured(visible: isVisible, keySaved: keySaved) }
    public var displayName: String {
        let label = userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? provider.displayName : label
    }
    public var recognitionTitle: String { displayName.isEmpty ? "在线 API 识别" : "在线 API 识别（\(displayName)）" }
    public var showsEnhancementSwitch: Bool { isConfigured }
    public var enhancementAction: HealthNextAction? { isConfigured ? nil : .configureAPI }
    public var enhanceLocalWithOnlineAPI: Bool { enhancement.enhanceLocalWithOnlineAPI }
    public var expiresAt: Date? { provider.capabilities.canReadExpiry ? metadata?.expiresAt : nil }
    public var remainingFreeUnits: Int? { provider.capabilities.canReadQuota ? metadata?.remainingFreeUnits : nil }
    public func update(credential: OnlineCredentialState, visible: Bool, userLabel: String? = nil,
                       metadata: OnlineAPIReadOnlyMetadata? = nil) {
        let changed = self.credential != credential || isVisible != visible || self.userLabel != userLabel
            || self.metadata != metadata || phase == .idle
        self.credential = credential; isVisible = visible; self.userLabel = userLabel; self.metadata = metadata
        phase = credential == .unreadable ? .error : isConfigured ? .content : .empty
        enhancement.synchronize()
        if changed { onChange?() }
    }
    public func setEnhancementFromUser(_ value: Bool, authorized: Bool) {
        enhancement.setFromUser(value, configured: isConfigured, authorized: authorized)
    }
    public func applyFixture(phase: SettingsLoadState) { self.phase = phase }
}

public struct DoubaoDetection: Sendable, Equatable {
    public let installed: Bool
    /// nil means the public API could not supply a list; it does not mean disabled.
    public let enabledInSystem: Bool?
    public init(installed: Bool, enabledInSystem: Bool?) { self.installed = installed; self.enabledInSystem = enabledInSystem }
    public var result: EngineHealthResult {
        if !installed { return .failed(.doubaoNotInstalled) }
        guard let enabledInSystem else { return .failed(.inspectionUnavailable) }
        return enabledInSystem ? .passed(.publicInputSource) : .failed(.doubaoNotEnabled)
    }
}

/// Shared production/test dispatch. Each closure reads only the facts for the selected method.
@MainActor public final class RecognitionHealthProvider: EngineHealthProviding {
    public let online: any OnlineAPIHealthAdapter
    private let doubao: () async -> DoubaoDetection
    private let local: () async -> EngineHealthResult
    private let credential: () async -> OnlineCredentialState
    public init(online: any OnlineAPIHealthAdapter, doubao: @escaping () async -> DoubaoDetection,
                local: @escaping () async -> EngineHealthResult, credential: @escaping () async -> OnlineCredentialState) {
        self.online = online; self.doubao = doubao; self.local = local; self.credential = credential
    }
    public func check(_ method: RecognitionMethod) async -> EngineHealthResult {
        switch method {
        case .doubao: return await doubao().result
        case .local: return await local()
        case .online:
            let saved = await credential()
            let result = await online.validate(credential: saved)
            if result == .verified && !online.capabilities.supportsLightweightValidation { return .failed(.notNetworkVerified) }
            return result.healthResult
        }
    }
}
