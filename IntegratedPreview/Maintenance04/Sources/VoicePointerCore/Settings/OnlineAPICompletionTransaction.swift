import Foundation

public enum OnlineAPICompletionError: Error, Sendable { case invalid, busy, storage, rollback }

/// One owner, six ordered stages. Cancellation is a failure until the final synchronous UI refresh.
/// Actions hold only an opaque in-memory checkpoint; no draft is encoded or used in diagnostics.
@MainActor public enum OnlineAPICompletionTransaction {
    public struct Actions {
        public var capture: () async throws -> Void
        public var saveKey: (OnlineAPIDraftKey) async throws -> String
        public var confirm: (OnlineAPIConfiguration) async throws -> Void
        public var allowUpload: (OnlineAPIConfiguration, OnlineAPISetupPurpose) throws -> Void
        public var activate: (OnlineAPIConfiguration, OnlineAPISetupPurpose) throws -> Void
        public var persist: (OnlineAPIConfiguration) throws -> Void
        public var refresh: () throws -> Void
        public var rollback: () async throws -> Void
        public init(capture: @escaping () async throws -> Void, saveKey: @escaping (OnlineAPIDraftKey) async throws -> String,
                    confirm: @escaping (OnlineAPIConfiguration) async throws -> Void,
                    allowUpload: @escaping (OnlineAPIConfiguration, OnlineAPISetupPurpose) throws -> Void,
                    activate: @escaping (OnlineAPIConfiguration, OnlineAPISetupPurpose) throws -> Void,
                    persist: @escaping (OnlineAPIConfiguration) throws -> Void,
                    refresh: @escaping () throws -> Void, rollback: @escaping () async throws -> Void) {
            self.capture = capture; self.saveKey = saveKey; self.confirm = confirm; self.allowUpload = allowUpload
            self.activate = activate; self.persist = persist; self.refresh = refresh; self.rollback = rollback
        }
    }
    public static func run(configuration: OnlineAPIConfiguration, draft: OnlineAPIDraftKey,
                           purpose: OnlineAPISetupPurpose, quotaConfirmed: Bool, actions: Actions) async throws -> OnlineAPIConfiguration {
        _ = try configuration.validatedEndpoint()
        guard !draft.isEmpty, configuration.credentialRevision == draft.revision,
              purpose != .enhanceLocal || configuration.provider.supportsEnhanceLocal else { throw OnlineAPICompletionError.invalid }
        try Task.checkCancellation()
        var captured = false
        do {
            // Set before awaiting: a partially captured checkpoint must also be released/rolled back.
            captured = true; try await actions.capture(); try Task.checkCancellation()
            var saved = configuration
            saved.credentialRevision = try await actions.saveKey(draft); try Task.checkCancellation()
            guard !saved.credentialRevision.isEmpty, saved.credentialRevision != configuration.credentialRevision else { throw OnlineAPICompletionError.storage }
            if saved.provider.isAliyun { try await actions.confirm(saved); try Task.checkCancellation() }
            if purpose != .configure {
                try actions.allowUpload(saved, purpose); try Task.checkCancellation()
                try actions.activate(saved, purpose); try Task.checkCancellation()
            }
            try actions.persist(saved); try Task.checkCancellation()
            try actions.refresh(); try Task.checkCancellation()
            return saved
        } catch {
            if captured {
                do { try await actions.rollback() }
                catch { throw OnlineAPICompletionError.rollback }
            }
            throw error
        }
    }
}
