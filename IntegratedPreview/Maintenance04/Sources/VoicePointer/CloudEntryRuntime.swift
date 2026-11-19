import Foundation
import Combine
import VoicePointerCore

/// What the settings section shows: whether the entry is offered, what state the saved key is in and, with a
/// readable key, the gate's persisted state for it.
struct CloudEntryPageState: Equatable {
    enum Key: Equatable {
        case missing
        case saved
        /// A key file is there (or the store is damaged) but it cannot be read back. Removing it starts clean.
        case unreadable
    }

    var isVisible = false
    var key: Key = .missing
    var snapshot: CloudAdmissionStateSnapshot?
    /// False until the first read has come back: the defaults above then mean "not known yet", not "closed".
    var isLoaded = false
    // T4: cached menu projections cannot reuse a page from before a credential change. No secret is exposed.
    var credentialEpoch: UUID?

    /// The cloud route can be used: the entry is offered and a readable key is saved.
    var isActive: Bool { CloudEntry.isConfigured(visible: isVisible, keySaved: key == .saved) }
}

/// The app's one K06 gate and credential probe for the Aliyun route, shared by the dictation path
/// (`makeAdmissionInputsProvider`), the settings section and the key entry. While `cloud.entry.visible` is
/// explicitly false nothing here does any I/O, and the provider answers nil, which the coordinator treats as a
/// denial. An explicit connection click reads the credential only for the
/// existing zero-audio worker handshake; never for the view or a log.
@MainActor
final class CloudEntryRuntime: ObservableObject {
    static let shared = CloudEntryRuntime()
    @Published private(set) var connectionCheck = OnlineConnectionCheckLedger()
    private(set) var credentialChanging = false
    private var observedIdentity: CloudAdmissionIdentity?
    private var credentialEpoch = UUID()
    var settingsCredentialEpoch: UUID { credentialEpoch }

    /// nil when Application Support cannot be resolved; every cloud decision then fails closed.
    private let gate: CloudAdmissionGate?
    private let credentials: CloudCredentialStore
    private let setupAuthorization = CloudCatalogAuthorizationFence()
    private var onlineStore: ProviderSettingsStore?
    func bindOnlineConfiguration(store: ProviderSettingsStore) { onlineStore = store }
    func onlineConfigurationChanged() {
        credentialEpoch = UUID(); observedIdentity = nil
        setupAuthorization.invalidate(); connectionCheck.invalidate()
    }
    /// Current permission projection, without credential IO or quota queries.
    /// The legacy enhancement id remains the existing UI consent token; the
    /// non-Ali provider's own consent is additionally required; Aliyun retains
    /// its existing gate and upload-permission checks.
    func enhancementConsent() -> Set<String> {
        let preferences = onlineStore?.value
        let cloud = CloudEntryPreferences.load()
        var result = cloud.legacyConsent(merging: preferences?.cloudConsent ?? [])
        guard let preferences else { return result }
        let provider = preferences.onlineAPIConfiguration?.provider ?? .aliyunBailian
        let configured = preferences.onlineAPIConfiguration.map {
            (try? $0.validatedEndpoint()) != nil && ($0.provider.isAliyun || result.contains($0.consentID))
        } ?? true
        if !configured || !cloud.enhancementAuthorized(for: preferences.selection, provider: provider) {
            result.remove(CloudEntry.enhanceConsentID)
        }
        return result
    }
    /// Aliyun still requires its per-session admission after this permission
    /// check. A non-Ali provider is independent of Aliyun's persisted pause.
    func isEnhancementUploadAuthorized(for selection: VoiceInputSelection? = nil) -> Bool {
        guard let preferences = onlineStore?.value else { return false }
        let provider = preferences.onlineAPIConfiguration?.provider ?? .aliyunBailian
        return enhancementConsent().contains(CloudEntry.enhanceConsentID)
            && CloudEntry.canEnhance(selection ?? preferences.selection, provider: provider)
    }
    var setupAuthorizationTicket: UUID { setupAuthorization.ticket }

    private init() {
        #if SETTINGS_REVIEW_HOST
        // The screenshot host never touches the real key or the real gate file: it works in a scratch folder
        // next to its own bundle, which starts empty.
        let scratch = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("cloud-review", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        credentials = CloudCredentialStore(
            service: "settings-review", directory: scratch.appendingPathComponent("credentials", isDirectory: true)
        )
        gate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: scratch.appendingPathComponent("state.json")))
        #else
        credentials = CloudCredentialStore()
        if let url = try? CloudAdmissionStateStore.defaultFileURL() {
            gate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: url))
        } else {
            gate = nil
        }
        #endif
    }

    /// For `VoicePointerCoordinator.init(cloudAdmissionInputs:)`. A dictation on the Aliyun route is asked under
    /// the route switch; one on a local route only under "用于增强本地识别", never under a route switch left on.
    func makeAdmissionInputsProvider() -> CloudAdmissionInputsProvider {
        return { [self] snapshot in
            await self.admissionInputs(snapshot: snapshot)
        }
    }

    func pageState() async -> CloudEntryPageState {
        let epoch = credentialEpoch
        guard CloudEntryPreferences.load().visible else {
            invalidateSetupAuthentication()
            observedIdentity = nil
            return CloudEntryPageState(isLoaded: true, credentialEpoch: epoch)
        }
        let key = await keyState()
        guard isCurrentPageRead(epoch) else { return CloudEntryPageState() }
        if let configuration = onlineStore?.value.onlineAPIConfiguration, !configuration.provider.isAliyun {
            observedIdentity = nil
            return CloudEntryPageState(isVisible: true, key: key, snapshot: nil, isLoaded: true, credentialEpoch: epoch)
        }
        guard key == .saved, let gate else {
            connectionCheck.invalidate()
            observedIdentity = nil
            return CloudEntryPageState(isVisible: true, key: key, snapshot: nil, isLoaded: true, credentialEpoch: epoch)
        }
        let identity = await currentIdentity()
        guard isCurrentPageRead(epoch) else { return CloudEntryPageState() }
        guard let identity else {
            connectionCheck.invalidate()
            observedIdentity = nil
            return CloudEntryPageState(isVisible: true, key: key, snapshot: nil, isLoaded: true, credentialEpoch: epoch)
        }
        let snapshot = await gate.snapshot(for: identity)
        guard isCurrentPageRead(epoch) else {
            return CloudEntryPageState()  // A concurrent key change or withdrawal invalidates this read.
        }
        if let observedIdentity, observedIdentity != identity { connectionCheck.invalidate() }
        observedIdentity = identity
        return CloudEntryPageState(isVisible: true, key: key, snapshot: snapshot, isLoaded: true, credentialEpoch: epoch)
    }

    private func isCurrentPageRead(_ epoch: UUID) -> Bool {
        epoch == credentialEpoch && !credentialChanging && CloudEntryPreferences.load().visible
    }

    /// The confirm and resume button of the settings sheet.
    func confirm(expectedCredentialEpoch: UUID? = nil, setupTicket: UUID? = nil,
                 isAllowed: () -> Bool = { true }) async -> CloudEntryConfirmation {
        guard isAllowed(), !Task.isCancelled else { return .failed }
        if let expectedCredentialEpoch, !isCurrentPageRead(expectedCredentialEpoch) { return .failed }
        guard CloudEntryPreferences.load().visible, let gate,
              let identity = await currentIdentity() else { return .failed }
        guard isAllowed(), !Task.isCancelled else { return .failed }
        if let expectedCredentialEpoch, !isCurrentPageRead(expectedCredentialEpoch) { return .failed }
        let result: CloudEntryConfirmation
        if let setupTicket {
            result = await gate.confirmCatalogSetup(identity: identity, fence: setupAuthorization, ticket: setupTicket)
        } else {
            result = await CloudEntry.confirm(gate: gate, identity: identity)
        }
        guard isAllowed(), !Task.isCancelled else { return .failed }
        if let expectedCredentialEpoch, !isCurrentPageRead(expectedCredentialEpoch) { return .failed }
        RuntimeTrace.record("cloud entry confirm result=\(result)")
        return result
    }

    struct SetupAuthorizationCheckpoint: Sendable {
        let credentialEpoch: UUID
        let confirmation: CloudSetupConfirmationCheckpoint
    }

    /// Only bounded identity/state metadata; no Key content is retained.
    func setupAuthorizationCheckpoint(expectedCredentialEpoch: UUID) async -> SetupAuthorizationCheckpoint? {
        guard isCurrentPageRead(expectedCredentialEpoch), let gate,
              let identity = await currentIdentity(), isCurrentPageRead(expectedCredentialEpoch),
              let confirmation = await gate.setupConfirmationCheckpoint(for: identity),
              isCurrentPageRead(expectedCredentialEpoch) else { return nil }
        return .init(credentialEpoch: expectedCredentialEpoch, confirmation: confirmation)
    }

    func confirmSetupAuthorization(_ checkpoint: SetupAuthorizationCheckpoint, verificationRevision: String,
                                   setupTicket: UUID,
                                   isAllowed: () -> Bool) async -> Bool {
        guard isAllowed(), !Task.isCancelled, isCurrentPageRead(checkpoint.credentialEpoch), let gate else { return false }
        let result = await gate.confirmSetupGuard(checkpoint.confirmation, verificationRevision: verificationRevision,
            catalogFence: setupAuthorization, catalogTicket: setupTicket)
        return isAllowed() && !Task.isCancelled && isCurrentPageRead(checkpoint.credentialEpoch) && result != .failed
    }

    func rollbackSetupConfirmation(_ checkpoint: SetupAuthorizationCheckpoint, verificationRevision: String) async {
        // Cleanup remains available when hidden/cancelled, but never carries an
        // old confirmation into a changed credential. Gate also checks ownership.
        guard checkpoint.credentialEpoch == credentialEpoch, !credentialChanging, let gate else { return }
        _ = await gate.rollbackSetupConfirmation(checkpoint.confirmation, verificationRevision: verificationRevision)
    }

    /// Saves the key the person pasted. A key of the wrong shape throws `CredentialError.invalidKey` before
    /// anything is written. Saving replaces the encrypted file, which gives it a new revision, so an earlier
    /// "free quota only" confirmation does not carry over to the new key.
    @discardableResult
    func saveKey(_ key: String) async throws -> UUID {
        credentialChanging = true
        credentialEpoch = UUID()
        let savingEpoch = credentialEpoch
        observedIdentity = nil
        invalidateSetupAuthentication()
        SettingsLogicRuntime.shared.configurationWillChange()
        defer {
            if credentialEpoch == savingEpoch { credentialChanging = false }
            SettingsLogicRuntime.shared.configurationDidChange()
        }
        try await credentials.save(key, provider: .aliyunBeijing)
        RuntimeTrace.record("cloud key saved provider=aliyun-beijing")
        return savingEpoch
    }

    func removeKey() async throws {
        credentialChanging = true
        credentialEpoch = UUID()
        observedIdentity = nil
        invalidateSetupAuthentication()
        SettingsLogicRuntime.shared.configurationWillChange()
        defer { credentialChanging = false; SettingsLogicRuntime.shared.configurationDidChange() }
        try await credentials.remove(provider: .aliyunBeijing)
        SettingsLogicRuntime.shared.saveUserLabel(nil)
        RuntimeTrace.record("cloud key removed provider=aliyun-beijing")
    }

    /// T4 keeps the T2 generation ledger; only the shared safe adapter may complete it.
    func beginConnectionCheck() -> UUID { connectionCheck.begin() }
    func completeSettingsCheck(_ outcome: CloudConnectionCheck.Outcome, generation: UUID) {
        connectionCheck.complete(outcome, generation: generation)
    }
    func invalidateSettingsCheck() { connectionCheck.invalidate() }

    /// Called on cancel/hide and before every key mutation. It
    /// revokes only pending setup authentication; no K06 permission is opened.
    func invalidateSetupAuthentication() {
        setupAuthorization.invalidate()
        connectionCheck.invalidate()
    }

    /// Caller must be an explicit verify click. Handshake is injectable; this
    /// method is never used for launch/refresh/presence inspection.
    func verifyConnection(expectedCredentialEpoch: UUID, ticket: UUID,
                       handshake: @escaping CloudConnectionVerificationFlow.Handshake = CloudConnectionVerificationFlow.aliyunHandshake,
                       isAllowed: @escaping @MainActor () -> Bool) async -> CloudSetupVerification {
        var generation: UUID?
        func current() -> Bool {
            isAllowed() && !Task.isCancelled && isCurrentPageRead(expectedCredentialEpoch)
                && setupAuthorization.isCurrent(ticket)
                && generation.map { connectionCheck.isCurrent($0) } != false
        }
        guard current() else { return .notNetworkVerified }
        let request = beginConnectionCheck(); generation = request
        let result = await CloudConnectionVerificationFlow.run(
            readKey: { [credentials] in try await credentials.readForPipe(provider: .aliyunBeijing) },
            handshake: handshake, isCurrent: { @MainActor in current() })
        guard current() else { return .notNetworkVerified }
        switch result {
        case .authenticated: completeSettingsCheck(.connected, generation: request)
        case .connectionFailed(let failure): completeSettingsCheck(.failed(failure), generation: request)
        case .failed, .notNetworkVerified: invalidateSettingsCheck()
        }
        return result
    }

    /// Attributes only: no decrypt/readForPipe, no worker, no realtime endpoint. Presence is never validation.
    func credentialPresenceForHealth() async -> OnlineCredentialState {
        let epoch = credentialEpoch
        guard !credentialChanging, CloudEntryPreferences.load().visible else { return .missing }
        do {
            let saved = try await credentials.hasStoredCredentialFile(provider: onlineStore?.value.onlineAPIConfiguration?.credentialSlot ?? .aliyunBeijing)
            guard epoch == credentialEpoch, !credentialChanging, CloudEntryPreferences.load().visible else { return .missing }
            return saved ? .saved : .missing
        } catch { return .unreadable }
    }

    private func admissionInputs(snapshot: VoiceInputSnapshot) async -> CloudAdmissionInputs? {
        let preferences = CloudEntryPreferences.load()
        guard preferences.visible, let gate else { return nil }
        let purpose = CloudEntryPurpose(routeID: snapshot.selection.routeID)
        if let config = snapshot.onlineAPIConfiguration {
            guard config.provider.isAliyun, let identity = try? config.admissionIdentity(),
                  (try? await credentials.storedRevision(provider: config.credentialSlot)) == config.credentialRevision else { return nil }
            return CloudAdmissionInputs(gate: gate, identity: identity, requirements: .init(
                cloudRouteEnabled: preferences.isEnabled(for: purpose), credentialAvailable: true,
                sampleUploadAllowed: preferences.uploadConsent, sessionUploadAllowed: preferences.uploadConsent))
        }
        let saved = await currentCredential()
        return CloudEntry.inputs(preferences: preferences, gate: gate, credential: saved, purpose: purpose)
    }

    private func currentIdentity() async -> CloudAdmissionIdentity? {
        let saved = await currentCredential()
        guard saved.isSaved, let revision = saved.revision else { return nil }
        if let config = onlineStore?.value.onlineAPIConfiguration {
            guard config.provider.isAliyun, config.credentialRevision == revision else { return nil }
            return try? config.admissionIdentity()
        }
        return try? CloudEntry.makeIdentity(credentialRevision: revision)
    }

    /// Key presence and revision only. A store that cannot answer counts as no key.
    private func currentCredential() async -> CloudEntryCredential {
        let slot = onlineStore?.value.onlineAPIConfiguration?.credentialSlot ?? .aliyunBeijing
        guard let revision = try? await credentials.storedRevision(provider: slot) else {
            return .missing
        }
        return CloudEntryCredential(isSaved: true, revision: revision)
    }

    /// Whether a key is saved, and whether the store can read it back. A key that is there but cannot be
    /// decrypted is "unreadable", not "missing": the person has to remove it before saving a new one.
    private func keyState() async -> CloudEntryPageState.Key {
        do {
            return try await credentials.hasStoredCredentialFile(provider: onlineStore?.value.onlineAPIConfiguration?.credentialSlot ?? .aliyunBeijing) ? .saved : .missing
        } catch {
            return .unreadable
        }
    }
}
