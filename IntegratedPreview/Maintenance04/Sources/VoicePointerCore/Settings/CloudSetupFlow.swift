import Foundation

public enum CloudSetupVerification: Sendable, Equatable {
    /// The service accepted a zero-audio connection check for this credential.
    /// This does not assert recognition quality or remaining free quota.
    case authenticated
    case notNetworkVerified
    case failed(HealthFailureReason)
    /// Keep every connection failure intact for the shared Aliyun diagnostics.
    case connectionFailed(CloudConnectionCheck.Failure)
}
public enum CloudSetupResult: Sendable, Equatable {
    case invalidFormat, saveFailed, capabilityMissing, notNetworkVerified
    case verificationFailed(HealthFailureReason), confirmationFailed, enableFailed, cancelled
    case connectionFailed(CloudConnectionCheck.Failure)
    case enabled(authorizedEpoch: UUID), authenticatedWithoutEnhancement(authorizedEpoch: UUID)
    case renewed(authorizedEpoch: UUID)

    public var authorizedEpoch: UUID? {
        switch self {
        case .enabled(let epoch), .authenticatedWithoutEnhancement(let epoch), .renewed(let epoch): epoch
        default: nil
        }
    }
}

/// Ephemeral wizard state, never proof based on credential presence alone.
/// Each new attempt clears the previous success; consumers recheck its epoch
/// when rendering success, advancing, and reporting completion.
public struct CloudSetupAttemptState: Sendable, Equatable {
    public private(set) var generation = UUID()
    public private(set) var isVisible = true
    public private(set) var authorizedEpoch: UUID?
    private var didEnable = false

    public init() {}
    @discardableResult
    public mutating func begin() -> UUID {
        generation = UUID(); authorizedEpoch = nil; didEnable = false
        return generation
    }
    public mutating func appear() { isVisible = true }
    public mutating func dismiss() { isVisible = false; begin() }
    public func isActive(_ request: UUID, isCancelled: Bool) -> Bool {
        isVisible && generation == request && !isCancelled
    }
    @discardableResult
    public mutating func accept(_ result: CloudSetupResult, request: UUID, isCancelled: Bool,
                                credentialIsCurrent: (UUID) -> Bool) -> Bool {
        guard isActive(request, isCancelled: isCancelled) else { return false }
        authorizedEpoch = nil; didEnable = false
        if let epoch = result.authorizedEpoch {
            guard credentialIsCurrent(epoch) else { return false }
            authorizedEpoch = epoch
            if case .enabled = result { didEnable = true }
        }
        return true
    }
    public func isAuthenticated(isCancelled: Bool, credentialIsCurrent: (UUID) -> Bool) -> Bool {
        guard isVisible, !isCancelled, let epoch = authorizedEpoch else { return false }
        return credentialIsCurrent(epoch)
    }
    public func isEnabled(isCancelled: Bool, credentialIsCurrent: (UUID) -> Bool) -> Bool {
        didEnable && isAuthenticated(isCancelled: isCancelled, credentialIsCurrent: credentialIsCurrent)
    }
}

/// Setup and saved renewal share an injected zero-audio connection boundary.
/// One bounded, non-secret checkpoint. Cleanup only closes grants introduced
/// by this attempt; it never writes a previously granted switch back to true.
public struct CloudSetupAuthorizationTransaction: Sendable {
    public let token: UUID
    public let credentialEpoch: UUID
    public let priorPreferences: CloudEntryPreferences
    public let hadValidConfirmation: Bool
    public var confirmationStarted = false
    public var uploadGranted = false
    public var enableStarted = false

    public init(token: UUID, credentialEpoch: UUID, priorPreferences: CloudEntryPreferences,
                hadValidConfirmation: Bool) {
        self.token = token; self.credentialEpoch = credentialEpoch
        self.priorPreferences = priorPreferences; self.hadValidConfirmation = hadValidConfirmation
    }

    public var verificationRevision: String { "user-setup-\(token.uuidString)" }

    public func closingIntroducedGrants(in current: CloudEntryPreferences,
                                       currentCredentialEpoch: UUID) -> CloudEntryPreferences {
        var next = current
        let preserve = currentCredentialEpoch == credentialEpoch && hadValidConfirmation
        if uploadGranted || confirmationStarted {
            if !preserve || !priorPreferences.uploadConsent { next.uploadConsent = false }
        }
        if enableStarted || confirmationStarted {
            if !preserve || !priorPreferences.routeEnabled { next.routeEnabled = false }
            if !preserve || !priorPreferences.enhanceLocal { next.enhanceLocal = false }
        }
        return next
    }
}

/// Both wizard entrances share this explicit save → verify → confirm → consent
/// → enable order. A connection check never grants upload on its own.
@MainActor
public enum CloudSetupFlow {
    /// Editing a local setup must not turn its key replacement into a cloud-route selection.
    public static func settingsPurpose(for selection: VoiceInputSelection) -> CloudEntryPurpose {
        selection.mode == .voiceNative && selection.routeID != CloudEntry.routeID
            ? .enhanceLocal : .route
    }

    public struct Actions {
        public let canVerifyWithoutAudio: Bool
        public let save: (String) async throws -> UUID
        public let verify: (UUID) async -> CloudSetupVerification
        public let confirm: (UUID) async -> Bool
        public let allowUpload: (UUID) -> Void
        public let enable: (CloudEntryPurpose, UUID) async -> Bool
        public let refresh: () async -> Void
        public let credentialIsCurrent: (UUID) -> Bool
        public let beginAuthorization: (UUID) async -> UUID?
        public let authorizationIsCurrent: (UUID) -> Bool
        public let commitAuthorization: (UUID) -> Bool
        public let rollbackAuthorization: @MainActor @Sendable (UUID) async -> Void
        public init(save: @escaping (String) async throws -> UUID,
                    verify: @escaping (UUID) async -> CloudSetupVerification,
                    confirm: @escaping (UUID) async -> Bool,
                    allowUpload: @escaping (UUID) -> Void,
                    enable: @escaping (CloudEntryPurpose, UUID) async -> Bool,
                    refresh: @escaping () async -> Void,
                    credentialIsCurrent: @escaping (UUID) -> Bool,
                    canVerifyWithoutAudio: Bool = true,
                    beginAuthorization: @escaping (UUID) async -> UUID?,
                    authorizationIsCurrent: @escaping (UUID) -> Bool,
                    commitAuthorization: @escaping (UUID) -> Bool,
                    rollbackAuthorization: @escaping @MainActor @Sendable (UUID) async -> Void) {
            self.save = save; self.verify = verify; self.confirm = confirm
            self.allowUpload = allowUpload; self.enable = enable; self.refresh = refresh
            self.credentialIsCurrent = credentialIsCurrent
            self.canVerifyWithoutAudio = canVerifyWithoutAudio
            self.beginAuthorization = beginAuthorization; self.authorizationIsCurrent = authorizationIsCurrent
            self.commitAuthorization = commitAuthorization; self.rollbackAuthorization = rollbackAuthorization
        }
    }

    /// Explicit renewal uses the same zero-audio connection dependency as setup,
    /// bound to the saved epoch. It never saves a key, grants upload, or selects/enables a route.
    public static func renewSavedCredential(credentialEpoch: UUID, quotaAcknowledged: Bool,
                                            actions: Actions, isVisible: () -> Bool) async -> CloudSetupResult {
        func current() -> Bool {
            isVisible() && !Task.isCancelled && actions.credentialIsCurrent(credentialEpoch)
        }
        guard current() else { return .cancelled }
        guard actions.canVerifyWithoutAudio else { return .capabilityMissing }
        let verification = await actions.verify(credentialEpoch)
        guard current() else { return .cancelled }
        switch verification {
        case .notNetworkVerified: await actions.refresh(); return current() ? .notNetworkVerified : .cancelled
        case .failed(let reason): await actions.refresh(); return current() ? .verificationFailed(reason) : .cancelled
        case .connectionFailed(let failure): await actions.refresh(); return current() ? .connectionFailed(failure) : .cancelled
        case .authenticated: break
        }
        return await authorize(epoch: credentialEpoch, purpose: nil, actions: actions,
                               enhancementLanguageSupported: true, quotaAcknowledged: quotaAcknowledged, isVisible: isVisible)
    }

    public static func run(draft: String, quotaAcknowledged: Bool, purpose: CloudEntryPurpose,
                           actions: Actions, enhancementLanguageSupported: Bool = true,
                           isVisible: () -> Bool) async -> CloudSetupResult {
        await saveAndVerify(draft: draft, quotaAcknowledged: quotaAcknowledged, purpose: purpose,
                            actions: actions, enhancementLanguageSupported: enhancementLanguageSupported,
                            isVisible: isVisible)
    }

    /// An explicit replacement during renewal updates the credential and confirmation
    /// only. It must not reuse setup's upload/route/enhancement authorization.
    public static func replaceSavedCredential(draft: String, quotaAcknowledged: Bool,
                                              actions: Actions, isVisible: () -> Bool) async -> CloudSetupResult {
        await saveAndVerify(draft: draft, quotaAcknowledged: quotaAcknowledged, purpose: nil,
                            actions: actions, enhancementLanguageSupported: true, isVisible: isVisible)
    }

    private static func saveAndVerify(draft: String, quotaAcknowledged: Bool, purpose: CloudEntryPurpose?,
                                      actions: Actions, enhancementLanguageSupported: Bool,
                                      isVisible: () -> Bool) async -> CloudSetupResult {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 3,
              !key.contains(where: { $0.isWhitespace }) else { return .invalidFormat }
        guard isVisible(), !Task.isCancelled else { return .cancelled }
        // An unavailable connection check is a known limitation, not a rejected
        // key. Preserve any existing credential instead of overwriting it.
        guard actions.canVerifyWithoutAudio else { return .capabilityMissing }
        let epoch: UUID
        do { epoch = try await actions.save(key) }
        catch is CancellationError { return .cancelled }
        catch { return .saveFailed }
        func current() -> Bool { isVisible() && !Task.isCancelled && actions.credentialIsCurrent(epoch) }
        guard current() else { return .cancelled }
        let verification = await actions.verify(epoch)
        guard current() else { return .cancelled }
        switch verification {
        case .notNetworkVerified: await actions.refresh(); return current() ? .notNetworkVerified : .cancelled
        case .failed(let reason): await actions.refresh(); return current() ? .verificationFailed(reason) : .cancelled
        case .connectionFailed(let failure): await actions.refresh(); return current() ? .connectionFailed(failure) : .cancelled
        case .authenticated: break
        }
        return await authorize(epoch: epoch, purpose: purpose, actions: actions,
                               enhancementLanguageSupported: enhancementLanguageSupported,
                               quotaAcknowledged: quotaAcknowledged, isVisible: isVisible)
    }

    private static func authorize(epoch: UUID, purpose: CloudEntryPurpose?, actions: Actions,
                                  enhancementLanguageSupported: Bool, quotaAcknowledged: Bool,
                                  isVisible: () -> Bool) async -> CloudSetupResult {
        func current() -> Bool { isVisible() && !Task.isCancelled && actions.credentialIsCurrent(epoch) }
        guard let token = await actions.beginAuthorization(epoch) else { return .cancelled }
        func authorizedCurrent() -> Bool { current() && actions.authorizationIsCurrent(token) }
        let rollback = actions.rollbackAuthorization
        return await withTaskCancellationHandler(operation: {
            @MainActor func finishAttempt() async -> CloudSetupResult {
                guard authorizedCurrent() else { return .cancelled }
                if quotaAcknowledged {
                    guard await actions.confirm(epoch) else { return authorizedCurrent() ? .confirmationFailed : .cancelled }
                }
                guard authorizedCurrent() else { return .cancelled }
                guard let purpose else {
                    await actions.refresh()
                    return authorizedCurrent() ? .renewed(authorizedEpoch: epoch) : .cancelled
                }
                if purpose == .enhanceLocal && !enhancementLanguageSupported {
                    await actions.refresh()
                    return authorizedCurrent() ? .authenticatedWithoutEnhancement(authorizedEpoch: epoch) : .cancelled
                }
                actions.allowUpload(epoch)
                guard authorizedCurrent() else { return .cancelled }
                guard await actions.enable(purpose, epoch) else {
                    return authorizedCurrent() ? .enableFailed : .cancelled
                }
                guard authorizedCurrent() else { return .cancelled }
                await actions.refresh()
                return authorizedCurrent() ? .enabled(authorizedEpoch: epoch) : .cancelled
            }
            let result = await finishAttempt()
            if result.authorizedEpoch == epoch,
               authorizedCurrent(), actions.commitAuthorization(token) { return result }
            // Cleanup deliberately ignores visibility and Task cancellation.
            await rollback(token)
            if result == .enableFailed { await actions.refresh() }
            return result.authorizedEpoch == epoch ? .cancelled : result
        }, onCancel: {
            // An uncooperative callback must not retain this attempt's consent
            // until it eventually returns. The token makes both cleanups idempotent.
            Task { @MainActor in await rollback(token) }
        })
    }
}
