import Foundation
import VoicePointerCore

/// Non-view actions shared by the existing settings controls and both wizard
/// entrances. K06 remains the authority for confirmation and every upload.
@MainActor
enum CloudSetupActions {
    struct PersistenceResult { let saved: Bool; let revoked: Bool; let closedEnhancement: Bool }
    enum RouteResult { case enabled, unavailable, unsupportedLanguage, saveFailed }

    @MainActor private final class SetupAttempt {
        var transaction: CloudSetupAuthorizationTransaction
        let checkpoint: CloudEntryRuntime.SetupAuthorizationCheckpoint
        let logic: SettingsLogicRuntime
        let onSelectionChanged: () -> Void
        var committed = false
        init(transaction: CloudSetupAuthorizationTransaction, checkpoint: CloudEntryRuntime.SetupAuthorizationCheckpoint,
             logic: SettingsLogicRuntime, onSelectionChanged: @escaping () -> Void) {
            self.transaction = transaction; self.checkpoint = checkpoint
            self.logic = logic; self.onSelectionChanged = onSelectionChanged
        }
    }
    // One pending grant across all wizard entrances. A newer explicit attempt
    // first closes the old attempt, before it captures any prior authorization.
    private static var setupGeneration = UUID()
    private static var pendingSetupAttempt: SetupAttempt?

    private static func rollbackSetupAttempt(_ attempt: SetupAttempt) async {
        guard !attempt.committed else { return }
        if pendingSetupAttempt?.transaction.token == attempt.transaction.token {
            pendingSetupAttempt = nil
            let before = CloudEntryPreferences.load()
            let after = attempt.transaction.closingIntroducedGrants(in: before,
                currentCredentialEpoch: CloudEntryRuntime.shared.settingsCredentialEpoch)
            if before.routeEnabled && !after.routeEnabled { CloudEntryPreferences.setRouteEnabled(false) }
            if before.enhanceLocal && !after.enhanceLocal { CloudEntryPreferences.setEnhanceLocal(false) }
            if before.uploadConsent && !after.uploadConsent { CloudEntryPreferences.setUploadConsent(false) }
            if before != after {
                attempt.onSelectionChanged()
                attempt.logic.online.enhancement.synchronize()
                NotificationCenter.default.post(name: .voicePointerSettingsChanged, object: nil)
            }
        }
        // Repeatable even after the owner was removed: a cancelled confirm may
        // have completed late. Gate CAS cannot undo a newer successful attempt.
        await CloudEntryRuntime.shared.rollbackSetupConfirmation(attempt.checkpoint,
            verificationRevision: attempt.transaction.verificationRevision)
    }

    private static func reserveSetupAttempt() async -> UUID {
        let token = UUID(); setupGeneration = token
        if let pendingSetupAttempt { await rollbackSetupAttempt(pendingSetupAttempt) }
        return token
    }

    private static func preserveNewerExplicitAuthorization() {
        guard let pendingSetupAttempt else { return }
        pendingSetupAttempt.committed = true
        self.pendingSetupAttempt = nil; setupGeneration = UUID()
    }

    @discardableResult
    static func saveKey(_ key: String, logic: SettingsLogicRuntime, label: String? = nil) async throws -> UUID {
        let epoch = try await CloudEntryRuntime.shared.saveKey(key)
        if let label { logic.saveUserLabel(label.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return epoch
    }
    static func persist(_ preferences: ProviderPreferences, store: ProviderSettingsStore,
                        credentialAvailable: Bool, onSelectionChanged: () -> Void,
                        onPersisted: (Bool) -> Void = { _ in }, reconcileAfterPersistence: Bool = false) -> PersistenceResult {
        let before = CloudEntryPreferences.load()
        func reconcile() {
            CloudEntryPreferences.reconcile(.init(selection: preferences.selection,
                credentialAvailable: credentialAvailable, entryVisible: before.visible))
        }
        if !reconcileAfterPersistence { reconcile() }
        do {
            try ProviderPreferencesCommit.persistAndNotify(preferences, store: store,
                onPreferencesChanged: { _ in
                    if reconcileAfterPersistence { reconcile() }
                    onPersisted(before.enhanceLocal && !CloudEntryPreferences.load().enhanceLocal)
                    onSelectionChanged()
                },
                notify: { NotificationCenter.default.post(name: .voicePointerSettingsChanged, object: nil) })
            let after = CloudEntryPreferences.load()
            let closed = before.enhanceLocal && !after.enhanceLocal
            return .init(saved: true, revoked: after != before, closedEnhancement: closed)
        } catch {
            let after = CloudEntryPreferences.load()
            let closed = before.enhanceLocal && !after.enhanceLocal
            if after != before { onSelectionChanged() }
            return .init(saved: false, revoked: after != before, closedEnhancement: closed)
        }
    }
    static func enableEnhancement(selection: VoiceInputSelection, page: CloudEntryPageState,
                                  removing: Bool, logic: SettingsLogicRuntime,
                                  onSelectionChanged: () -> Void, grantUploadConsent: Bool = true) -> Bool {
        guard CloudEnhanceWording.refusal(selection: selection, keySaved: page.isActive, removing: removing) == nil else { return false }
        if grantUploadConsent { CloudEntryPreferences.setUploadConsent(true) }
        logic.online.setEnhancementFromUser(true, authorized: CloudEntryStatus(snapshot: page.snapshot).isUsable)
        onSelectionChanged()
        logic.online.enhancement.synchronize()
        let enabled = CloudEntryPreferences.load().enhanceLocal
        if enabled && grantUploadConsent { preserveNewerExplicitAuthorization() }
        return enabled
    }
    static func enableRoute(store: ProviderSettingsStore, page: CloudEntryPageState, removing: Bool,
                            previousLocalRouteID: String, persist: (ProviderPreferences) -> Bool,
                            onSelectionChanged: () -> Void, manageAuthorization: Bool = true) -> RouteResult {
        guard page.isActive, !removing else { return .unavailable }
        let current = store.value.selection
        guard CloudEntry.supportedLanguages.contains(current.language),
              let selection = try? VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.routeID, language: current.language)
        else { return .unsupportedLanguage }
        if current.mode == .doubao || !VoiceRouteOption.cloudRouteIDs.contains(current.routeID) {
            CloudEntryPreferences.rememberPreviousSelection(mode: current.mode, routeID: previousLocalRouteID)
        }
        if manageAuthorization { CloudEntryPreferences.setUploadConsent(true) }
        CloudEntryPreferences.setRouteEnabled(true)
        var preferences = store.value; preferences.selection = selection
        if persist(preferences) {
            if manageAuthorization { preserveNewerExplicitAuthorization() }
            return .enabled
        }
        if manageAuthorization {
            CloudEntryPreferences.setUploadConsent(false)
            CloudEntryPreferences.setRouteEnabled(false)
        }
        onSelectionChanged()
        return .saveFailed
    }
    static func flowActions(store: ProviderSettingsStore, logic: SettingsLogicRuntime,
                            onSelectionChanged: @escaping () -> Void,
                            isVisible: @escaping () -> Bool = { true },
                            handshake: @escaping CloudConnectionVerificationFlow.Handshake = CloudConnectionVerificationFlow.aliyunHandshake) -> CloudSetupFlow.Actions {
        let runtime = CloudEntryRuntime.shared
        var ticket = runtime.setupAuthorizationTicket
        var requestToken: UUID?
        var attempt: SetupAttempt?
        func current(_ epoch: UUID) -> Bool {
            return isVisible() && !Task.isCancelled && runtime.settingsCredentialEpoch == epoch
                && !runtime.credentialChanging && CloudEntryPreferences.load().visible
                && runtime.setupAuthorizationTicket == ticket
                && (requestToken == nil || requestToken == setupGeneration)
        }
        func ownsAttempt() -> Bool {
            guard let attempt else { return false }
            return pendingSetupAttempt?.transaction.token == attempt.transaction.token
        }
        return .init(save: { key in
            requestToken = await reserveSetupAttempt()
            guard isVisible(), !Task.isCancelled,
                  requestToken == setupGeneration,
                  runtime.setupAuthorizationTicket == ticket, CloudEntryPreferences.load().visible,
                  !runtime.credentialChanging else { throw CancellationError() }
            let epoch = try await saveKey(key, logic: logic)
            ticket = runtime.setupAuthorizationTicket
            guard current(epoch) else { throw CancellationError() }
            return epoch
        }, verify: { epoch in
            guard current(epoch) else { return .notNetworkVerified }
            return await runtime.verifyConnection(expectedCredentialEpoch: epoch,
                ticket: ticket, handshake: handshake, isAllowed: { current(epoch) })
        }, confirm: { epoch in
            guard current(epoch), ownsAttempt(), let attempt else { return false }
            attempt.transaction.confirmationStarted = true
            return await runtime.confirmSetupAuthorization(attempt.checkpoint,
                verificationRevision: attempt.transaction.verificationRevision,
                setupTicket: ticket,
                isAllowed: { current(epoch) && ownsAttempt() })
        }, allowUpload: { epoch in
            if current(epoch), ownsAttempt(), let attempt {
                attempt.transaction.uploadGranted = true
                CloudEntryPreferences.setUploadConsent(true)
            }
        }, enable: { purpose, epoch in
            let page = await runtime.pageState()
            guard current(epoch), ownsAttempt(), let attempt, page.credentialEpoch == epoch,
                  CloudEntryStatus(snapshot: page.snapshot).isUsable else { return false }
            attempt.transaction.enableStarted = true
            let selection = store.value.selection
            if purpose == .enhanceLocal {
                return enableEnhancement(selection: selection, page: page, removing: false,
                    logic: logic, onSelectionChanged: onSelectionChanged, grantUploadConsent: false)
            }
            let previous = VoiceRouteOption.cloudRouteIDs.contains(selection.routeID) ? CloudEntry.localFallbackRouteID : selection.routeID
            return enableRoute(store: store, page: page, removing: false, previousLocalRouteID: previous,
                persist: { persist($0, store: store, credentialAvailable: page.isActive,
                    onSelectionChanged: onSelectionChanged, reconcileAfterPersistence: true).saved },
                onSelectionChanged: onSelectionChanged, manageAuthorization: false) == .enabled
        }, refresh: {
            let page = await runtime.pageState()
            logic.update(page: page, selection: store.value.selection)
            NotificationCenter.default.post(name: .voicePointerSettingsChanged, object: nil)
        }, credentialIsCurrent: current,
            canVerifyWithoutAudio: true,
            beginAuthorization: { epoch in
                if requestToken == nil { requestToken = await reserveSetupAttempt() }
                guard current(epoch), let token = requestToken,
                      let checkpoint = await runtime.setupAuthorizationCheckpoint(expectedCredentialEpoch: epoch),
                      current(epoch) else { return nil }
                let transaction = CloudSetupAuthorizationTransaction(token: token, credentialEpoch: epoch,
                    priorPreferences: CloudEntryPreferences.load(),
                    hadValidConfirmation: checkpoint.confirmation.hadValidConfirmation)
                let next = SetupAttempt(transaction: transaction, checkpoint: checkpoint,
                    logic: logic, onSelectionChanged: onSelectionChanged)
                attempt = next; pendingSetupAttempt = next
                return token
            }, authorizationIsCurrent: { token in
                token == attempt?.transaction.token && ownsAttempt()
            }, commitAuthorization: { token in
                guard token == attempt?.transaction.token, ownsAttempt(), let attempt else { return false }
                attempt.committed = true; pendingSetupAttempt = nil
                return true
            }, rollbackAuthorization: { token in
                guard token == attempt?.transaction.token, let attempt else { return }
                await rollbackSetupAttempt(attempt)
            })
    }

    /// Verify-only settings click. No key save, confirmation, consent or route change.
    static func verifySavedConnection(isVisible: @escaping @MainActor () -> Bool,
                                   handshake: @escaping CloudConnectionVerificationFlow.Handshake = CloudConnectionVerificationFlow.aliyunHandshake) async -> CloudSetupVerification {
        let runtime = CloudEntryRuntime.shared
        return await runtime.verifyConnection(expectedCredentialEpoch: runtime.settingsCredentialEpoch,
            ticket: runtime.setupAuthorizationTicket, handshake: handshake, isAllowed: isVisible)
    }
}
