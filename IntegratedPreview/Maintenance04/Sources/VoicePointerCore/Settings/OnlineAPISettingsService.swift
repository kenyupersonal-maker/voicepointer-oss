import Foundation

/// Production storage/admission bridge. Construction and migration never read a plaintext key.
@MainActor public final class OnlineAPISettingsService {
    public let store: ProviderSettingsStore
    public let credentials: CloudCredentialStore
    public let gate: CloudAdmissionGate
    public let defaults: UserDefaults
    public var onRefresh: () -> Void = {}
    public private(set) var busy = false
    private var enhancementRevocation: UInt64 = 0
    private static let preferenceKeys = [CloudEntryPreferences.routeEnabledKey, CloudEntryPreferences.uploadConsentKey,
        CloudEntryPreferences.enhanceLocalKey, CloudEntryPreferences.previousModeKey, CloudEntryPreferences.previousRouteIDKey]

    public init(store: ProviderSettingsStore, credentials: CloudCredentialStore, gate: CloudAdmissionGate,
                defaults: UserDefaults = .standard) {
        self.store = store; self.credentials = credentials; self.gate = gate; self.defaults = defaults
    }
    /// Explicit asynchronous startup migration; preserves selection, consent, endpoint and 3.0.
    public func migrateLegacy() async throws {
        guard !busy, store.value.onlineAPIConfiguration == nil else { return }
        busy = true; defer { busy = false }
        let previous = store.value
        let ali = try await credentials.storedRevision(provider: .aliyunBeijing)
        let groq = try await credentials.storedRevision(provider: .groq)
        try Task.checkCancellation()
        guard store.value == previous,
              let config = OnlineAPIConfiguration.migrateLegacy(selection: previous.selection, aliyunEndpoint: previous.aliyunEndpoint,
                aliyunRevision: ali, groqRevision: groq) else { return }
        var next = previous; next.onlineAPIConfiguration = config; next.onlineAPIMaskedKey = "••••"
        try store.update(next); onRefresh()
    }
    public func complete(_ configuration: OnlineAPIConfiguration, draft: OnlineAPIDraftKey,
                         purpose: OnlineAPISetupPurpose, quotaConfirmed: Bool, availableModelIDs: [String]? = nil) async throws -> OnlineAPIConfiguration {
        guard !busy else { throw OnlineAPICompletionError.busy }
        busy = true; defer { busy = false }
        let previous = store.value
        let enhancementEpoch = enhancementRevocation
        let raw = Self.preferenceKeys.map { defaults.object(forKey: $0) }
        var expected = previous
        var settingsCheckpoint: ProviderSettingsStore.Checkpoint?
        var credentialCheckpoint: CloudCredentialStore.SetupCheckpoint?
        var writtenRevision: String?
        var confirmation: CloudSetupConfirmationCheckpoint?
        let confirmationRevision = "user-console-" + UUID().uuidString
        let masked = draft.masked
        func current() throws {
            guard store.value == expected else { throw OnlineAPICompletionError.busy }
            guard purpose != .enhanceLocal || enhancementEpoch == enhancementRevocation else { throw CancellationError() }
        }
        let actions = OnlineAPICompletionTransaction.Actions(capture: {
            settingsCheckpoint = try self.store.checkpoint()
            credentialCheckpoint = try await self.credentials.setupCheckpoint(provider: configuration.credentialSlot)
            try current()
        }, saveKey: { key in
            try current()
            guard let checkpoint = credentialCheckpoint else { throw OnlineAPICompletionError.storage }
            writtenRevision = try await self.credentials.saveForSetup(key, checkpoint: checkpoint)
            return writtenRevision!
        }, confirm: { saved in
            try current()
            let identity = try saved.admissionIdentity()
            guard let checkpoint = await self.gate.setupConfirmationCheckpoint(for: identity) else { throw OnlineAPICompletionError.storage }
            confirmation = checkpoint; try Task.checkCancellation()
            let result = await self.gate.confirmSetupGuard(checkpoint, verificationRevision: confirmationRevision,
                                                           quotaConfirmed: quotaConfirmed)
            guard result != .failed else { throw OnlineAPICompletionError.storage }
        }, allowUpload: { saved, purpose in
            try current()
            var next = expected
            // The selected provider owns upload consent. Previous providers cannot inherit a new key's grant.
            next.cloudConsent.subtract(ProviderPreferences.allowedConsentIDs)
            next.cloudConsent.insert(saved.consentID)
            try self.store.update(next); expected = next
            let priorConsent = CloudEntryPreferences.load(from: self.defaults).uploadConsent
            CloudEntryPreferences.setUploadConsent(purpose == .enhanceLocal || saved.provider.isAliyun || priorConsent, in: self.defaults)
        }, activate: { saved, purpose in
            try current()
            if purpose == .route {
                if previous.selection.mode == .doubao || !OnlineAPIConfiguration.cloudRouteIDs.contains(previous.selection.routeID) {
                    CloudEntryPreferences.rememberPreviousSelection(mode: previous.selection.mode, routeID: previous.selection.routeID, in: self.defaults)
                }
                var next = expected
                next.selection = try VoiceInputSelection(mode: .voiceNative, routeID: saved.routeID, language: previous.selection.language)
                try self.store.update(next); expected = next
                CloudEntryPreferences.setRouteEnabled(saved.provider.isAliyun, in: self.defaults)
            } else {
                guard CloudEntry.canEnhance(previous.selection, provider: saved.provider) else { throw OnlineAPICompletionError.invalid }
                CloudEntryPreferences.setRouteEnabled(false, in: self.defaults)
                CloudEntryPreferences.setEnhanceLocal(true, in: self.defaults)
            }
        }, persist: { saved in
            try current()
            var next = expected; next.onlineAPIConfiguration = saved; next.onlineAPIMaskedKey = masked
            next.onlineAPIAvailableModelIDs = availableModelIDs.map { saved.provider.modelIDs.filter(Set($0).contains) } ?? [saved.modelID]
            if saved.provider.isAliyun { next.aliyunEndpoint = try saved.validatedEndpoint().absoluteString }
            try self.store.update(next); expected = next
        }, refresh: {
            try current(); self.onRefresh()
        }, rollback: {
            var failed = false
            // Rollback deliberately awaits even when its parent task is cancelled.
            if let confirmation {
                if await self.gate.rollbackSetupConfirmation(confirmation, verificationRevision: confirmationRevision) == .storageUnavailable { failed = true }
            }
            if let checkpoint = credentialCheckpoint {
                do { try await self.credentials.restoreSetup(checkpoint, expectedRevision: writtenRevision) } catch { failed = true }
            }
            if let checkpoint = settingsCheckpoint {
                do { try self.store.restore(checkpoint, expected: expected) } catch { failed = true }
            }
            for (key, value) in zip(Self.preferenceKeys, raw) {
                if enhancementEpoch != self.enhancementRevocation,
                   key == CloudEntryPreferences.enhanceLocalKey || key == CloudEntryPreferences.uploadConsentKey { continue }
                if let value { self.defaults.set(value, forKey: key) } else { self.defaults.removeObject(forKey: key) }
            }
            if failed {
                CloudEntryPreferences.setUploadConsent(false, in: self.defaults)
                CloudEntryPreferences.setRouteEnabled(false, in: self.defaults)
                CloudEntryPreferences.setEnhanceLocal(false, in: self.defaults)
            }
            self.onRefresh()
            if failed { throw OnlineAPICompletionError.rollback }
        })
        return try await OnlineAPICompletionTransaction.run(configuration: configuration, draft: draft,
            purpose: purpose, quotaConfirmed: quotaConfirmed, actions: actions)
    }
    public func snapshot(for configuration: OnlineAPIConfiguration) async -> CloudAdmissionStateSnapshot? {
        guard let identity = try? configuration.admissionIdentity() else { return nil }
        return await gate.snapshot(for: identity)
    }
    public func confirmedModels(for configuration: OnlineAPIConfiguration) async -> Set<String> {
        guard configuration.provider.isAliyun else { return [] }
        var confirmed: Set<String> = []
        for id in configuration.provider.modelIDs {
            var value = configuration; value.modelID = id
            if CloudEntryStatus(snapshot: await snapshot(for: value)).isConfirmed { confirmed.insert(id) }
        }
        return confirmed
    }
    /// Explicitly re-use a configured route or enhancement. Presence is metadata only;
    /// Ali admission still requires this exact provider/model confirmation.
    public func activate(_ configuration: OnlineAPIConfiguration, purpose: OnlineAPISetupPurpose,
                         reconfirm: Bool = false) async throws {
        guard !busy, store.value.onlineAPIConfiguration == configuration else { throw OnlineAPICompletionError.busy }
        busy = true; defer { busy = false }
        let previous = store.value, checkpoint = try store.checkpoint()
        let enhancementEpoch = enhancementRevocation
        let raw = Self.preferenceKeys.map { defaults.object(forKey: $0) }
        var expected = previous
        var confirmation: CloudSetupConfirmationCheckpoint?
        let verification = "user-console-" + UUID().uuidString
        do {
            guard try await credentials.storedRevision(provider: configuration.credentialSlot) == configuration.credentialRevision else { throw CredentialError.missing }
            if configuration.provider.isAliyun {
                let identity = try configuration.admissionIdentity()
                guard let captured = await gate.setupConfirmationCheckpoint(for: identity) else { throw OnlineAPICompletionError.storage }
                confirmation = captured
                if reconfirm {
                    try Task.checkCancellation()
                    guard await gate.confirmSetupGuard(captured, verificationRevision: verification) != .failed else { throw OnlineAPICompletionError.storage }
                } else {
                    guard CloudEntryStatus(snapshot: await gate.snapshot(for: identity)).isUsable else { throw OnlineAPICompletionError.invalid }
                }
            }
            try Task.checkCancellation()
            guard store.value == previous else { throw OnlineAPICompletionError.busy }
            guard purpose != .enhanceLocal || enhancementEpoch == enhancementRevocation else { throw CancellationError() }
            var next = previous; next.cloudConsent.insert(configuration.consentID)
            if purpose == .route {
                if previous.selection.mode == .doubao || !OnlineAPIConfiguration.cloudRouteIDs.contains(previous.selection.routeID) {
                    CloudEntryPreferences.rememberPreviousSelection(mode: previous.selection.mode, routeID: previous.selection.routeID, in: defaults)
                }
                next.selection = try VoiceInputSelection(mode: .voiceNative, routeID: configuration.routeID, language: previous.selection.language)
            } else {
                guard CloudEntry.canEnhance(previous.selection, provider: configuration.provider) else { throw OnlineAPICompletionError.invalid }
            }
            try store.update(next); expected = next
            let priorConsent = CloudEntryPreferences.load(from: defaults).uploadConsent
            CloudEntryPreferences.setUploadConsent(purpose == .enhanceLocal || configuration.provider.isAliyun || priorConsent, in: defaults)
            CloudEntryPreferences.setRouteEnabled(purpose == .route && configuration.provider.isAliyun, in: defaults)
            if purpose == .enhanceLocal { CloudEntryPreferences.setEnhanceLocal(true, in: defaults) }
            try Task.checkCancellation(); onRefresh(); try Task.checkCancellation()
        } catch {
            if reconfirm, let confirmation { _ = await gate.rollbackSetupConfirmation(confirmation, verificationRevision: verification) }
            try store.restore(checkpoint, expected: expected)
            for (key, value) in zip(Self.preferenceKeys, raw) {
                if enhancementEpoch != enhancementRevocation,
                   key == CloudEntryPreferences.enhanceLocalKey || key == CloudEntryPreferences.uploadConsentKey { continue }
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            onRefresh(); throw error
        }
    }
    /// Inline selection: no key write, no route/provider swap, and no unvalidated model commit.
    public func commitModel(_ configuration: OnlineAPIConfiguration, quotaConfirmed: Bool,
                            purpose: OnlineAPISetupPurpose) async throws -> OnlineAPIConfiguration {
        guard !busy, let prior = store.value.onlineAPIConfiguration,
              prior.provider == configuration.provider, prior.endpointOverride == configuration.endpointOverride,
              prior.credentialRevision == configuration.credentialRevision else { throw OnlineAPICompletionError.busy }
        _ = try configuration.validatedEndpoint()
        busy = true; defer { busy = false }
        guard try await credentials.storedRevision(provider: configuration.credentialSlot) == configuration.credentialRevision else { throw CredentialError.missing }
        try Task.checkCancellation()
        let checkpoint = try store.checkpoint(), previous = store.value
        var expected = previous
        var guardCheckpoint: CloudSetupConfirmationCheckpoint?
        let revision = "user-console-" + UUID().uuidString
        do {
            if configuration.provider.isAliyun {
                let identity = try configuration.admissionIdentity()
                guard let captured = await gate.setupConfirmationCheckpoint(for: identity) else { throw OnlineAPICompletionError.storage }
                guardCheckpoint = captured
                if !quotaConfirmed, !captured.hasConfirmedModelQuota {
                    throw OnlineAPICompletionError.invalid
                }
                try Task.checkCancellation()
                guard await gate.confirmSetupGuard(captured, verificationRevision: revision,
                                                  quotaConfirmed: quotaConfirmed) != .failed else { throw OnlineAPICompletionError.storage }
            }
            try Task.checkCancellation()
            guard store.value == previous else { throw OnlineAPICompletionError.busy }
            var next = previous; next.onlineAPIConfiguration = configuration
            if var models = next.onlineAPIAvailableModelIDs, !models.contains(configuration.modelID) {
                models.append(configuration.modelID); next.onlineAPIAvailableModelIDs = configuration.provider.modelIDs.filter(Set(models).contains)
            }
            if purpose == .route, previous.selection.mode == .voiceNative,
               previous.selection.routeID == prior.routeID { next.selection.routeID = configuration.routeID }
            try store.update(next); expected = next
            try Task.checkCancellation(); onRefresh(); try Task.checkCancellation()
            return configuration
        } catch {
            if let guardCheckpoint { _ = await gate.rollbackSetupConfirmation(guardCheckpoint, verificationRevision: revision) }
            try store.restore(checkpoint, expected: expected); onRefresh(); throw error
        }
    }
    /// 30-day confirmation: no network, key validation, decryption or key display.
    public func reconfirm(_ configuration: OnlineAPIConfiguration) async throws {
        guard !busy, store.value.onlineAPIConfiguration == configuration, configuration.provider.isAliyun else { throw OnlineAPICompletionError.busy }
        busy = true; defer { busy = false }
        let identity = try configuration.admissionIdentity()
        guard let checkpoint = await gate.setupConfirmationCheckpoint(for: identity) else { throw OnlineAPICompletionError.storage }
        let revision = "user-console-" + UUID().uuidString
        do {
            try Task.checkCancellation()
            guard store.value.onlineAPIConfiguration == configuration,
                  await gate.confirmSetupGuard(checkpoint, verificationRevision: revision) != .failed else { throw OnlineAPICompletionError.storage }
            try Task.checkCancellation(); onRefresh(); try Task.checkCancellation()
        } catch { _ = await gate.rollbackSetupConfirmation(checkpoint, verificationRevision: revision); throw error }
    }
    public func disable(_ configuration: OnlineAPIConfiguration, purpose: OnlineAPISetupPurpose) throws {
        if purpose == .enhanceLocal {
            guard store.value.onlineAPIConfiguration == configuration else { throw OnlineAPICompletionError.busy }
            withdrawEnhancement()
            return
        }
        guard !busy, store.value.onlineAPIConfiguration == configuration else { throw OnlineAPICompletionError.busy }
        if purpose == .route {
            var next = store.value
            if next.selection.mode == .voiceNative, OnlineAPIConfiguration.cloudRouteIDs.contains(next.selection.routeID) {
                next.selection = try VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.localFallbackRouteID, language: next.selection.language)
            }
            next.cloudConsent.remove(configuration.consentID)
            try store.update(next)
            CloudEntryPreferences.setRouteEnabled(false, in: defaults)
        } else { CloudEntryPreferences.setEnhanceLocal(false, in: defaults) }
        if !CloudEntryPreferences.load(from: defaults).routeEnabled && !CloudEntryPreferences.load(from: defaults).enhanceLocal {
            CloudEntryPreferences.setUploadConsent(false, in: defaults)
        }
        onRefresh()
    }
    /// Explicit user withdrawal wins over an in-flight activation and its rollback.
    /// It never restores upload permission or changes the selected provider.
    public func withdrawEnhancement() {
        enhancementRevocation &+= 1
        CloudEntryPreferences.setEnhanceLocal(false, in: defaults)
        if !CloudEntryPreferences.load(from: defaults).routeEnabled {
            CloudEntryPreferences.setUploadConsent(false, in: defaults)
        }
        onRefresh()
    }
    public func remove(_ configuration: OnlineAPIConfiguration) async throws {
        guard !busy, store.value.onlineAPIConfiguration == configuration else { throw OnlineAPICompletionError.busy }
        busy = true; defer { busy = false }
        let checkpoint = try store.checkpoint(), previous = store.value
        let raw = Self.preferenceKeys.map { defaults.object(forKey: $0) }
        var next = previous
        next.onlineAPIConfiguration = nil; next.onlineAPIMaskedKey = nil; next.onlineAPIAvailableModelIDs = nil
        next.cloudConsent.remove(configuration.consentID)
        if previous.selection.mode == .voiceNative, OnlineAPIConfiguration.cloudRouteIDs.contains(previous.selection.routeID) {
            next.selection = try VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.localFallbackRouteID, language: previous.selection.language)
        }
        do {
            try store.update(next)
            CloudEntryPreferences.setRouteEnabled(false, in: defaults)
            CloudEntryPreferences.setEnhanceLocal(false, in: defaults)
            CloudEntryPreferences.setUploadConsent(false, in: defaults)
            try await credentials.trashCredential(provider: configuration.credentialSlot, expectedRevision: configuration.credentialRevision)
        } catch {
            try store.restore(checkpoint, expected: store.value == previous ? previous : next)
            for (key, value) in zip(Self.preferenceKeys, raw) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            onRefresh(); throw error
        }
        onRefresh()
    }
}
