import Combine
import Foundation
import VoicePointerCore

/// Credential-free observable state. Saved-model health checks are scheduled by settings events only.
@MainActor final class OnlineAPIRuntime: ObservableObject {
    static let shared = OnlineAPIRuntime()
    @Published private(set) var panel = OnlineAPIPanelSnapshot.empty
    private(set) var service: OnlineAPISettingsService?
    private var generation: UInt64 = 0
    private var validatedDrafts: [String: OnlineAPIValidatedModels] = [:]
    private var validatedSelections: Set<OnlineAPIConfiguration> = []
    private var attention: OnlineAPIPanelSnapshot.Attention?
    private var observedHealthConfiguration: OnlineAPIConfiguration?
    private var migrating = false

    func bind(store: ProviderSettingsStore, changed: @escaping () -> Void) {
        if service?.store === store { return }
        let credentials: CloudCredentialStore
        let gate: CloudAdmissionGate
        #if SETTINGS_REVIEW_HOST
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("online-review-" + UUID().uuidString)
        credentials = CloudCredentialStore(directory: scratch.appendingPathComponent("keys"), recoveryDirectory: scratch.appendingPathComponent("recovery"))
        gate = CloudAdmissionGate(store: .init(fileURL: scratch.appendingPathComponent("gate.json")))
        #else
        credentials = CloudCredentialStore()
        guard let path = try? CloudAdmissionStateStore.defaultFileURL() else { return }
        gate = CloudAdmissionGate(store: .init(fileURL: path))
        #endif
        let next = OnlineAPISettingsService(store: store, credentials: credentials, gate: gate)
        observedHealthConfiguration = store.value.onlineAPIConfiguration
        migrating = true
        next.onRefresh = { [weak self] in
            guard let self else { return }
            let healthChanged = self.observedHealthConfiguration != store.value.onlineAPIConfiguration
            if healthChanged && !self.migrating { SettingsLogicRuntime.shared.configurationWillChange() }
            self.observedHealthConfiguration = store.value.onlineAPIConfiguration
            if healthChanged { self.validatedSelections.removeAll() }
            if healthChanged { CloudEntryRuntime.shared.onlineConfigurationChanged() }
            changed()
            NotificationCenter.default.post(name: .voicePointerSettingsChanged, object: nil)
            if healthChanged && !self.migrating { SettingsLogicRuntime.shared.configurationDidChange() }
            Task { await self.refresh() }
        }
        service = next
        CloudEntryRuntime.shared.bindOnlineConfiguration(store: store)
        Task { [weak self] in
            try? await next.migrateLegacy()
            self?.migrating = false
            await self?.refresh()
        }
    }
    var purpose: OnlineAPISetupPurpose {
        guard let store = service?.store, let config = store.value.onlineAPIConfiguration else { return .route }
        return config.provider.supportsEnhanceLocal && store.value.selection.mode == .voiceNative
            && !OnlineAPIConfiguration.cloudRouteIDs.contains(store.value.selection.routeID) ? .enhanceLocal : .route
    }
    func validator() -> any OnlineAPIValidating { RecordingValidator(owner: self) }
    private struct RecordingValidator: OnlineAPIValidating {
        let owner: OnlineAPIRuntime
        func validate(draft: OnlineAPIDraftKey, providerOverride: OnlineAPIProvider?, endpointOverride: String?) async -> OnlineAPIValidationResult {
            let result = await OnlineAPILiveValidation.service().validate(draft: draft, providerOverride: providerOverride, endpointOverride: endpointOverride)
            if !Task.isCancelled, case .success(let models) = result { await owner.record(models) }
            return result
        }
    }
    private func record(_ models: OnlineAPIValidatedModels) {
        if validatedDrafts.count >= 8 { validatedDrafts.removeAll() }
        validatedDrafts[models.credentialRevision] = models
    }
    func complete(_ config: OnlineAPIConfiguration, _ draft: OnlineAPIDraftKey,
                  _ purpose: OnlineAPISetupPurpose, _ confirmed: Bool) async throws -> OnlineAPIConfiguration {
        guard let service, let models = validatedDrafts[draft.revision],
              models.provider == config.provider, models.endpointOverride == config.endpointOverride,
              models.availableModelIDs.contains(config.modelID) else { throw OnlineAPICompletionError.invalid }
        let saved = try await service.complete(config, draft: draft, purpose: purpose, quotaConfirmed: confirmed, availableModelIDs: models.availableModelIDs)
        validatedDrafts.removeValue(forKey: draft.revision)
        attention = nil
        return saved
    }
    func refresh() async {
        generation &+= 1; let expected = generation
        guard let service, let config = service.store.value.onlineAPIConfiguration else { panel = .empty; return }
        let available = (try? await service.credentials.storedRevision(provider: config.credentialSlot)) == config.credentialRevision
        let snapshot = await service.snapshot(for: config)
        let confirmed = await service.confirmedModels(for: config)
        guard expected == generation, service.store.value.onlineAPIConfiguration == config else { return }
        var nextAttention = attention
        var until: Date?
        if !available { nextAttention = .keyRejected }
        if config.provider.isAliyun {
            switch CloudEntryStatus(snapshot: snapshot) {
            case .confirmed(let date): until = date
            case .paused(.freeQuotaExhausted): nextAttention = .freeQuotaExhausted
            case .expired, .unconfirmed: nextAttention = .confirmationExpired
            case .unavailable: if nextAttention == nil { nextAttention = .keyRejected }
            case .paused(.accountBalanceBlocked): nextAttention = .keyRejected
            }
        }
        // Legacy candidates remain selectable only through a fresh, explicit inline handshake.
        let models = OnlineAPIModelAvailabilityCache.models(configuration: config,
            existing: service.store.value.onlineAPIAvailableModelIDs ?? config.provider.modelIDs)
        panel = .init(configuration: config, availableModelIDs: models, maskedKey: service.store.value.onlineAPIMaskedKey ?? "••••",
            confirmedModelIDs: confirmed, quotaValidUntil: until, attention: nextAttention)
    }
    func validateModel(_ configuration: OnlineAPIConfiguration) async -> OnlineAPIPanelModel.CheckResult {
        guard let service, let before = service.store.value.onlineAPIConfiguration,
              before.provider == configuration.provider, before.credentialRevision == configuration.credentialRevision else {
            return .failed(.init(provider: configuration.provider, cause: .cancelled))
        }
        let result = await OnlineAPILiveValidation.checkModel(configuration: configuration, credentials: service.credentials)
        guard !Task.isCancelled, service.store.value.onlineAPIConfiguration == before else { return .failed(.init(provider: configuration.provider, cause: .cancelled)) }
        if case .ready = result { OnlineAPIModelAvailabilityCache.record(configuration: configuration, modelID: configuration.modelID, passed: true) }
        switch result {
        case .ready: validatedSelections.insert(configuration); return .available
        case .failed(let cause): return .failed(.init(provider: configuration.provider, cause: cause))
        case .models: return .failed(.init(provider: configuration.provider, cause: .noModels))
        }
    }
    /// The card uses the identical selected-model probe as the panel. No model sweep, audio, or writes.
    func checkSavedHealth() async -> OnlineAPIValidation {
        guard let service, let configuration = service.store.value.onlineAPIConfiguration else { return .notNetworkVerified }
        let epoch = CloudEntryRuntime.shared.settingsCredentialEpoch
        let result = await OnlineAPILiveValidation.checkModel(configuration: configuration, credentials: service.credentials)
        guard !Task.isCancelled, service.store.value.onlineAPIConfiguration == configuration,
              CloudEntryRuntime.shared.settingsCredentialEpoch == epoch else { return .notNetworkVerified }
        switch result {
        case .ready: return .verified
        case .models: return .failed(.modelUnavailable)
        case .failed(.connection(let failure)): return .failed(AliyunOnlineAPIProvider.failure(failure))
        case .failed(.cancelled): return .notNetworkVerified
        case .failed(.noModels): return .failed(.modelUnavailable)
        case .failed(.insufficientQuota): return .failed(.balanceDue)
        case .failed: return .failed(.unavailable)
        }
    }
    func commitModel(_ configuration: OnlineAPIConfiguration, _ confirmed: Bool) async throws -> OnlineAPIConfiguration {
        guard let service, validatedSelections.remove(configuration) != nil else { throw OnlineAPICompletionError.invalid }
        return try await service.commitModel(configuration, quotaConfirmed: confirmed, purpose: purpose)
    }
    func reconfirm() async throws {
        guard let service, let configuration = panel.configuration else { throw OnlineAPICompletionError.invalid }
        try await service.reconfirm(configuration); attention = nil; await refresh()
    }
    func disable() async throws {
        guard let service, let configuration = panel.configuration else { throw OnlineAPICompletionError.invalid }
        try Task.checkCancellation(); try service.disable(configuration, purpose: purpose); await refresh()
    }
    func activate(purpose: OnlineAPISetupPurpose, reconfirm: Bool = false) async throws {
        guard let service, let configuration = service.store.value.onlineAPIConfiguration else { throw OnlineAPICompletionError.invalid }
        guard panel.attention != .keyRejected && panel.attention != .freeQuotaExhausted else { throw OnlineAPICompletionError.invalid }
        try await service.activate(configuration, purpose: purpose, reconfirm: reconfirm); await refresh()
    }
    func disable(purpose: OnlineAPISetupPurpose) async throws {
        guard let service, let configuration = service.store.value.onlineAPIConfiguration else { throw OnlineAPICompletionError.invalid }
        try Task.checkCancellation(); try service.disable(configuration, purpose: purpose); await refresh()
    }
    func remove() async throws {
        guard let service, let configuration = panel.configuration else { throw OnlineAPICompletionError.invalid }
        try await service.remove(configuration); attention = nil; await refresh()
    }
    func failed(code: String) {
        if code.hasSuffix("AUTH_FAILED") || code.hasSuffix("HTTP_401") { attention = .keyRejected }
        if code.hasSuffix("FREE_QUOTA_EXHAUSTED") { attention = .freeQuotaExhausted }
        Task { await refresh() }
    }
}
