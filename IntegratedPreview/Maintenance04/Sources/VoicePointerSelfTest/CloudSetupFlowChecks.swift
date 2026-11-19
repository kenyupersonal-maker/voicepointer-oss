import Foundation
import VoicePointerCore

@MainActor
enum CloudSetupFlowChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        let epoch = UUID()
        for scenario in 0..<15 {
            var events: [String] = []
            var current = true
            var visible = true
            let fence = CloudCatalogAuthorizationFence(), ticket = fence.ticket
            let actions = CloudSetupFlow.Actions(
                save: { _ in events.append("save"); if scenario == 14 { current = false }; return epoch },
                verify: { _ in
                    events.append("verify")
                    if scenario == 1 { return .failed(.network) }
                    if scenario == 3 { return .notNetworkVerified }
                    if scenario == 4 { current = false }
                    if scenario == 7 { return .connectionFailed(.noAccess) }
                    if scenario == 8 { return .failed(.invalidKey) }
                    if scenario == 9 { fence.invalidate() }
                    if scenario == 10 || scenario == 11 { visible = false }
                    return .authenticated
                },
                confirm: { _ in
                    events.append("confirm")
                    if scenario == 12 { current = false }
                    if scenario == 13 { fence.invalidate() }
                    return true
                },
                allowUpload: { _ in events.append("upload") },
                enable: { _, _ in events.append("enable"); return true },
                refresh: { events.append("refresh") },
                credentialIsCurrent: { $0 == epoch && current && fence.isCurrent(ticket) },
                canVerifyWithoutAudio: scenario != 5,
                beginAuthorization: { _ in UUID() }, authorizationIsCurrent: { _ in true },
                commitAuthorization: { _ in true }, rollbackAuthorization: { _ in })
            let result = await CloudSetupFlow.run(draft: scenario == 0 ? "wrong-format" : "sk-synthetic-placeholder",
                quotaAcknowledged: true, purpose: .enhanceLocal, actions: actions,
                enhancementLanguageSupported: scenario != 6, isVisible: { visible })
            let expected: [String]
            switch scenario {
            case 0: expected = []; if result != .invalidFormat { failures.append("wizard format failure") }
            case 1: expected = ["save", "verify", "refresh"]; if result != .verificationFailed(.network) { failures.append("wizard verify failure") }
            case 2: expected = ["save", "verify", "confirm", "upload", "enable", "refresh"]; if result != .enabled(authorizedEpoch: epoch) { failures.append("wizard ordered success bound to saved epoch") }
            case 3: expected = ["save", "verify", "refresh"]; if result != .notNetworkVerified { failures.append("wizard honest unverified") }
            case 5: expected = []; if result != .capabilityMissing { failures.append("wizard pre-save unavailable endpoint preserves credential") }
            case 6: expected = ["save", "verify", "confirm", "refresh"]; if result != .authenticatedWithoutEnhancement(authorizedEpoch: epoch) { failures.append("wizard unsupported language continues without upload or enhancement") }
            case 7: expected = ["save", "verify", "refresh"]; if result != .connectionFailed(.noAccess) { failures.append("wizard keeps typed connection failure without granting consent") }
            case 8: expected = ["save", "verify", "refresh"]; if result != .verificationFailed(.invalidKey) { failures.append("wizard 401 does not authorize") }
            case 9, 10, 11: expected = ["save", "verify"]; if result != .cancelled { failures.append("wizard revoked/hidden/cancel fence") }
            case 12, 13: expected = ["save", "verify", "confirm"]; if result != .cancelled { failures.append("wizard late confirmation cannot upload or enable") }
            case 14: expected = ["save"]; if result != .cancelled { failures.append("wizard late save cannot verify new epoch") }
            default: expected = ["save", "verify"]; if result != .cancelled { failures.append("wizard stale epoch cancels") }
            }
            if events != expected { failures.append("wizard side-effect order \(scenario)") }
        }
        failures += await retryChecks()
        failures += publicationChecks()
        failures += await lateVerificationChecks()
        failures += await savedCredentialChecks()
        failures += await visibilityRetryChecks()
        failures += await rollbackChecks()
        failures += await confirmationCheckpointChecks()
        failures += await CloudConnectionVerificationChecks.run()
        return failures
    }

    private static func visibilityRetryChecks() async -> [String] {
        var failures: [String] = [], events: [String] = []
        var attempt = CloudSetupAttemptState()
        let epoch = UUID(), oldRequest = attempt.begin()
        let actions = CloudSetupFlow.Actions(save: { _ in events.append("save"); return epoch },
            verify: { _ in events.append("catalog"); return .authenticated },
            confirm: { _ in events.append("confirm"); return true },
            allowUpload: { _ in events.append("upload") }, enable: { _, _ in events.append("enable"); return true },
            refresh: { events.append("refresh") }, credentialIsCurrent: { $0 == epoch },
            beginAuthorization: { _ in UUID() }, authorizationIsCurrent: { _ in true },
            commitAuthorization: { _ in true }, rollbackAuthorization: { _ in })
        // The production window guard calls dismiss on hide and appear on
        // visibility restoration. Neither operation restores old success.
        attempt.dismiss()
        let hidden = await CloudSetupFlow.renewSavedCredential(credentialEpoch: epoch,
            quotaAcknowledged: true, actions: actions, isVisible: { attempt.isVisible })
        if hidden != .cancelled || !events.isEmpty { failures.append("hidden wizard cannot start catalog validation") }
        attempt.appear(); let request = attempt.begin()
        let result = await CloudSetupFlow.renewSavedCredential(credentialEpoch: epoch,
            quotaAcknowledged: true, actions: actions, isVisible: { attempt.isActive(request, isCancelled: false) })
        if result != .renewed(authorizedEpoch: epoch) || events != ["catalog", "confirm", "refresh"] {
            failures.append("restored visible wizard can explicitly validate without save/upload/enable")
        }
        if attempt.accept(.enabled(authorizedEpoch: epoch), request: oldRequest, isCancelled: false,
                          credentialIsCurrent: actions.credentialIsCurrent) {
            failures.append("restoring visibility cannot revive the previous request")
        }
        return failures
    }

    /// Every flow callback below is injected. No runtime, credential store,
    /// microphone, backend.prepare/run-task or network adapter is constructed.
    @MainActor private final class FakeAuthorization {
        @MainActor final class Attempt {
            var transaction: CloudSetupAuthorizationTransaction
            let priorConfirmation: String?
            var committed = false
            init(_ transaction: CloudSetupAuthorizationTransaction, priorConfirmation: String?) {
                self.transaction = transaction; self.priorConfirmation = priorConfirmation
            }
        }
        var epoch = UUID()
        var preferences = CloudEntryPreferences()
        var confirmation: String?
        var pending: Attempt?
        var visible = true
        var events: [String] = []
        var afterUpload: () -> Void = {}
        var onEnable: @MainActor () async -> Bool = { true }
        var onConfirm: @MainActor () async -> Void = {}
        var onRollback: () -> Void = {}

        func rollback(_ attempt: Attempt) {
            guard !attempt.committed else { return }
            events.append("rollback")
            if pending?.transaction.token == attempt.transaction.token {
                pending = nil
                preferences = attempt.transaction.closingIntroducedGrants(in: preferences, currentCredentialEpoch: epoch)
            }
            if epoch == attempt.transaction.credentialEpoch,
               confirmation == attempt.transaction.verificationRevision {
                confirmation = attempt.priorConfirmation
            }
            onRollback()
        }
        func actions() -> CloudSetupFlow.Actions {
            var attempt: Attempt?
            return .init(save: { _ in self.events.append("save"); return self.epoch },
                verify: { _ in self.events.append("verify"); return .authenticated },
                confirm: { _ in
                    guard let attempt else { return false }
                    self.events.append("confirm"); attempt.transaction.confirmationStarted = true
                    await self.onConfirm()
                    self.confirmation = attempt.transaction.verificationRevision
                    return true
                }, allowUpload: { _ in
                    guard let attempt else { return }
                    self.events.append("upload"); attempt.transaction.uploadGranted = true
                    self.preferences.uploadConsent = true; self.afterUpload()
                }, enable: { purpose, _ in
                    guard let attempt else { return false }
                    self.events.append("enable"); attempt.transaction.enableStarted = true
                    if purpose == .route { self.preferences.routeEnabled = true }
                    else { self.preferences.enhanceLocal = true }
                    return await self.onEnable()
                }, refresh: { self.events.append("refresh") },
                credentialIsCurrent: { $0 == self.epoch },
                beginAuthorization: { epoch in
                    if let pending = self.pending { self.rollback(pending) }
                    let next = Attempt(.init(token: UUID(), credentialEpoch: epoch, priorPreferences: self.preferences,
                        hadValidConfirmation: self.confirmation != nil), priorConfirmation: self.confirmation)
                    attempt = next; self.pending = next
                    return next.transaction.token
                }, authorizationIsCurrent: { self.pending?.transaction.token == $0 },
                commitAuthorization: { token in
                    guard let attempt, self.pending?.transaction.token == token else { return false }
                    attempt.committed = true; self.pending = nil
                    return true
                }, rollbackAuthorization: { token in
                    guard let attempt, attempt.transaction.token == token else { return }
                    self.rollback(attempt)
                })
        }
        func run(purpose: CloudEntryPurpose = .enhanceLocal) async -> CloudSetupResult {
            await CloudSetupFlow.run(draft: "sk-synthetic-placeholder", quotaAcknowledged: true,
                purpose: purpose, actions: actions(), isVisible: { self.visible })
        }
    }

    private static func rollbackChecks() async -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("wizard rollback: " + label) } }
        for purpose in [CloudEntryPurpose.enhanceLocal, .route] {
            let fake = FakeAuthorization(); fake.onEnable = { false }
            expect(await fake.run(purpose: purpose) == .enableFailed, "enable failure result")
            expect(!fake.preferences.uploadConsent && !fake.preferences.routeEnabled && !fake.preferences.enhanceLocal
                && fake.confirmation == nil, "enable failure closes only new grants")
            expect(fake.events == ["save", "verify", "confirm", "upload", "enable", "rollback", "refresh"], "failure cleanup precedes refresh")
        }
        let hidden = FakeAuthorization(); hidden.afterUpload = { hidden.visible = false }
        expect(await hidden.run() == .cancelled && !hidden.preferences.uploadConsent && hidden.confirmation == nil,
            "hidden immediately after upload cleans consent before enable")
        expect(!hidden.events.contains("enable"), "hidden flow cannot enable")

        let lateEpoch = FakeAuthorization()
        lateEpoch.onEnable = { lateEpoch.epoch = UUID(); lateEpoch.confirmation = nil; return true }
        expect(await lateEpoch.run() == .cancelled && !lateEpoch.preferences.uploadConsent
            && !lateEpoch.preferences.enhanceLocal && lateEpoch.confirmation == nil, "changed epoch never restores old authorization")

        let preexisting = FakeAuthorization()
        preexisting.preferences = .init(uploadConsent: true, enhanceLocal: true)
        preexisting.confirmation = "previous-valid-same-credential"
        preexisting.onEnable = { false }
        expect(await preexisting.run(purpose: .route) == .enableFailed, "preexisting enable failure")
        expect(preexisting.preferences.uploadConsent && preexisting.preferences.enhanceLocal
            && !preexisting.preferences.routeEnabled && preexisting.confirmation == "previous-valid-same-credential",
            "valid same-credential grants survive failure")

        let changedKey = FakeAuthorization()
        changedKey.preferences = .init(uploadConsent: true, enhanceLocal: true)
        // A replacement credential has no confirmation, even if old switches were true.
        changedKey.onEnable = { false }
        expect(await changedKey.run() == .enableFailed && !changedKey.preferences.uploadConsent
            && !changedKey.preferences.enhanceLocal && changedKey.confirmation == nil, "old true switches do not authorize a replacement key")

        // Cancellation while enable is suspended must clean up before that callback returns.
        let cancelled = FakeAuthorization()
        var releaseEnable: CheckedContinuation<Bool, Never>?
        var reachedEnable: CheckedContinuation<Void, Never>?
        var cleaned: CheckedContinuation<Void, Never>?
        cancelled.onEnable = {
            await withCheckedContinuation { continuation in
                releaseEnable = continuation; reachedEnable?.resume(); reachedEnable = nil
            }
        }
        cancelled.onRollback = { cleaned?.resume(); cleaned = nil }
        let cancelledTask = Task { @MainActor in await cancelled.run() }
        await withCheckedContinuation { reachedEnable = $0 }
        await withCheckedContinuation { continuation in cleaned = continuation; cancelledTask.cancel() }
        expect(!cancelled.preferences.uploadConsent && !cancelled.preferences.enhanceLocal && cancelled.confirmation == nil,
            "task cancellation cleans an outstanding enable callback")
        releaseEnable?.resume(returning: true)
        expect(await cancelledTask.value == .cancelled, "late enable completion remains cancelled")

        // A confirm that ignored cancellation can still finish late; the second
        // cleanup must remove its receipt even though the pending owner is gone.
        let lateConfirm = FakeAuthorization()
        var releaseConfirm: CheckedContinuation<Void, Never>?
        var reachedConfirm: CheckedContinuation<Void, Never>?
        var confirmCleaned: CheckedContinuation<Void, Never>?
        lateConfirm.onConfirm = {
            await withCheckedContinuation { continuation in
                releaseConfirm = continuation; reachedConfirm?.resume(); reachedConfirm = nil
            }
        }
        lateConfirm.onRollback = { confirmCleaned?.resume(); confirmCleaned = nil }
        let confirmTask = Task { @MainActor in await lateConfirm.run() }
        await withCheckedContinuation { reachedConfirm = $0 }
        await withCheckedContinuation { continuation in confirmCleaned = continuation; confirmTask.cancel() }
        releaseConfirm?.resume()
        expect(await confirmTask.value == .cancelled && lateConfirm.confirmation == nil && !lateConfirm.preferences.uploadConsent,
            "late confirmation cannot leak a cancelled grant")

        // A newer explicit attempt takes ownership and succeeds before the old
        // callback returns. Old cleanup must neither undo it nor resurrect itself.
        let newer = FakeAuthorization()
        var releaseOld: CheckedContinuation<Bool, Never>?
        var reachedOld: CheckedContinuation<Void, Never>?
        newer.onEnable = {
            await withCheckedContinuation { continuation in
                releaseOld = continuation; reachedOld?.resume(); reachedOld = nil
            }
        }
        let oldTask = Task { @MainActor in await newer.run() }
        await withCheckedContinuation { reachedOld = $0 }
        newer.onEnable = { true }
        expect(await newer.run(purpose: .route) == .enabled(authorizedEpoch: newer.epoch), "newer attempt succeeds")
        let successfulConfirmation = newer.confirmation
        releaseOld?.resume(returning: true)
        expect(await oldTask.value == .cancelled && newer.preferences.uploadConsent && newer.preferences.routeEnabled
            && !newer.preferences.enhanceLocal && newer.confirmation == successfulConfirmation,
            "late old attempt cannot undo newer successful consent")
        let renewal = FakeAuthorization()
        renewal.preferences = .init(uploadConsent: true, enhanceLocal: true)
        renewal.confirmation = "previous-valid-same-credential"
        let renewalBefore = renewal.preferences
        let renewed = await CloudSetupFlow.renewSavedCredential(credentialEpoch: renewal.epoch,
            quotaAcknowledged: true, actions: renewal.actions(), isVisible: { true })
        expect(renewed == .renewed(authorizedEpoch: renewal.epoch) && renewal.preferences == renewalBefore
            && renewal.events == ["verify", "confirm", "refresh"], "saved renewal owns a confirmation-only transaction")
        let cancelledRenewal = FakeAuthorization()
        cancelledRenewal.preferences = .init(uploadConsent: true, enhanceLocal: true)
        cancelledRenewal.confirmation = "previous-valid-same-credential"
        cancelledRenewal.onConfirm = { cancelledRenewal.visible = false }
        let failedRenewal = await CloudSetupFlow.renewSavedCredential(credentialEpoch: cancelledRenewal.epoch,
            quotaAcknowledged: true, actions: cancelledRenewal.actions(), isVisible: { cancelledRenewal.visible })
        expect(failedRenewal == .cancelled && cancelledRenewal.preferences.uploadConsent
            && cancelledRenewal.preferences.enhanceLocal && cancelledRenewal.confirmation == "previous-valid-same-credential",
            "cancelled saved renewal restores its receipt and preserves preexisting grants")
        return failures
    }

    /// Real local gate code against a fresh synthetic state file only. No
    /// credential files or provider callbacks are involved in these CAS assertions.
    private static func confirmationCheckpointChecks() async -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("wizard confirmation CAS: " + label) } }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("b2-m4-synthetic-\(UUID().uuidString)", isDirectory: true)
        let gate = CloudAdmissionGate(store: .init(fileURL: directory.appendingPathComponent("state.json")))
        guard let identity = try? CloudEntry.makeIdentity(credentialRevision: "synthetic-revision-1"),
              let checkpoint = await gate.setupConfirmationCheckpoint(for: identity) else { return ["wizard confirmation CAS: fixture unavailable"] }
        expect(await gate.confirmSetupGuard(checkpoint, verificationRevision: "synthetic-attempt-1") == .confirmed, "explicit confirm")
        expect(await gate.rollbackSetupConfirmation(checkpoint, verificationRevision: "synthetic-attempt-1") == .updated, "new confirmation rollback")
        expect(CloudEntryStatus(snapshot: await gate.snapshot(for: identity)).isConfirmed == false, "new confirmation removed")
        guard let abortedBeforeConfirm = await gate.setupConfirmationCheckpoint(for: identity) else {
            return failures + ["wizard confirmation CAS: cancellation fixture unavailable"]
        }
        _ = await gate.rollbackSetupConfirmation(abortedBeforeConfirm, verificationRevision: "synthetic-aborted")
        expect(await gate.confirmSetupGuard(abortedBeforeConfirm, verificationRevision: "synthetic-aborted") == .failed,
            "cancel before queued confirm invalidates its transaction")

        _ = await CloudEntry.confirm(gate: gate, identity: identity)
        guard let prior = await gate.snapshot(for: identity), let renewal = await gate.setupConfirmationCheckpoint(for: identity) else {
            return failures + ["wizard confirmation CAS: renewal fixture unavailable"]
        }
        expect(renewal.hadValidConfirmation, "valid same-credential checkpoint")
        _ = await gate.confirmSetupGuard(renewal, verificationRevision: "synthetic-renewal")
        _ = await gate.rollbackSetupConfirmation(renewal, verificationRevision: "synthetic-renewal")
        let restored = await gate.snapshot(for: identity)
        expect(restored?.verificationRevision == prior.verificationRevision && restored?.guardObservedAt == prior.guardObservedAt,
            "preserve previous confirmation without renewing its expiry")
        guard let old = await gate.setupConfirmationCheckpoint(for: identity) else { return failures + ["wizard confirmation CAS: old fixture unavailable"] }
        _ = await gate.confirmSetupGuard(old, verificationRevision: "synthetic-old")
        guard let newest = await gate.setupConfirmationCheckpoint(for: identity) else { return failures + ["wizard confirmation CAS: newest fixture unavailable"] }
        _ = await gate.confirmSetupGuard(newest, verificationRevision: "synthetic-newest")
        expect(await gate.rollbackSetupConfirmation(old, verificationRevision: "synthetic-old") == .unchanged, "stale rollback ignored")
        expect(await gate.confirmSetupGuard(old, verificationRevision: "synthetic-late-old") == .failed, "stale confirmation ignored")
        expect(await gate.snapshot(for: identity)?.verificationRevision == "synthetic-newest", "newer confirmation remains")

        guard let replacement = try? CloudEntry.makeIdentity(credentialRevision: "synthetic-revision-2"),
              let replacementCheckpoint = await gate.setupConfirmationCheckpoint(for: replacement) else {
            return failures + ["wizard confirmation CAS: replacement fixture unavailable"]
        }
        expect(!CloudEntryStatus(snapshot: await gate.snapshot(for: replacement)).isConfirmed,
               "replacement key cannot inherit a quota acknowledgment")
        _ = await gate.confirmSetupGuard(replacementCheckpoint, verificationRevision: "synthetic-replacement")
        _ = await gate.rollbackSetupConfirmation(replacementCheckpoint, verificationRevision: "synthetic-replacement")
        expect(!CloudEntryStatus(snapshot: await gate.snapshot(for: replacement)).isConfirmed,
            "replacement rollback never restores old key confirmation")
        guard let fenced = await gate.setupConfirmationCheckpoint(for: replacement) else {
            return failures + ["wizard confirmation CAS: catalog fence fixture unavailable"]
        }
        let fence = CloudCatalogAuthorizationFence(), ticket = fence.ticket
        fence.invalidate()
        expect(await gate.confirmSetupGuard(fenced, verificationRevision: "synthetic-revoked-catalog",
            catalogFence: fence, catalogTicket: ticket) == .failed, "endpoint revoke blocks the queued transactional confirm")
        expect(!CloudEntryStatus(snapshot: await gate.snapshot(for: replacement)).isConfirmed,
            "revoked catalog cannot create confirmation")
        return failures
    }

    private static func savedCredentialChecks() async -> [String] {
        var failures: [String] = []
        let local = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen17-rolling", language: "yue")
        let cloud = try! VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.routeID, language: "zh")
        if CloudSetupFlow.settingsPurpose(for: local) != .enhanceLocal
            || CloudSetupFlow.settingsPurpose(for: cloud) != .route {
            failures.append("key replacement preserves local/cloud purpose even with unsupported language")
        }
        let provider = AliyunOnlineAPIProvider()
        let defaultValidation = await provider.validate(credential: .saved)
        if provider.capabilities.supportsLightweightValidation || defaultValidation != .notNetworkVerified {
            failures.append("AUTH default remains unavailable; saved presence is not authentication")
        }
        // The fake catalog verifier is the only authentication operation. Any
        // save/upload/ASR-route activation would appear in the exact event trace.
        let epoch = UUID()
        for scenario in 0..<10 {
            var events: [String] = []
            var currentEpoch = scenario == 4 ? UUID() : epoch
            var visible = scenario != 9
            var savedKey = "sk-synthetic-saved-placeholder"
            var selection = local
            let originalSelection = selection
            var preferences = CloudEntryPreferences(uploadConsent: false)
            let originalPreferences = preferences
            let actions = CloudSetupFlow.Actions(
                save: { value in events.append("save"); savedKey = value; return UUID() },
                verify: { requestedEpoch in
                    events.append("catalog-auth")
                    if requestedEpoch != epoch { failures.append("saved authentication uses the captured credential epoch") }
                    if scenario == 2 { return .failed(.network) }
                    if scenario == 3 { return .notNetworkVerified }
                    if scenario == 5 { currentEpoch = UUID() }
                    if scenario == 6 { visible = false }
                    return .authenticated
                },
                confirm: { requestedEpoch in
                    events.append("confirm")
                    if requestedEpoch != epoch || currentEpoch != epoch { failures.append("saved confirmation uses the authenticated current epoch") }
                    if scenario == 8 { currentEpoch = UUID() }
                    return scenario != 7
                },
                allowUpload: { _ in events.append("upload"); preferences.uploadConsent = true },
                enable: { _, _ in events.append("ASR-route"); selection = cloud; return true },
                refresh: { events.append("refresh") },
                credentialIsCurrent: { $0 == currentEpoch }, canVerifyWithoutAudio: scenario != 1,
                beginAuthorization: { _ in UUID() }, authorizationIsCurrent: { _ in true },
                commitAuthorization: { _ in true }, rollbackAuthorization: { _ in })
            let result = await CloudSetupFlow.renewSavedCredential(credentialEpoch: epoch,
                quotaAcknowledged: true, actions: actions, isVisible: { visible })
            let expectedResult: CloudSetupResult
            let expectedEvents: [String]
            switch scenario {
            case 0: expectedResult = .renewed(authorizedEpoch: epoch); expectedEvents = ["catalog-auth", "confirm", "refresh"]
            case 1: expectedResult = .capabilityMissing; expectedEvents = []
            case 2: expectedResult = .verificationFailed(.network); expectedEvents = ["catalog-auth", "refresh"]
            case 3: expectedResult = .notNetworkVerified; expectedEvents = ["catalog-auth", "refresh"]
            case 4, 9: expectedResult = .cancelled; expectedEvents = []
            case 5, 6: expectedResult = .cancelled; expectedEvents = ["catalog-auth"]
            case 7: expectedResult = .confirmationFailed; expectedEvents = ["catalog-auth", "confirm"]
            default: expectedResult = .cancelled; expectedEvents = ["catalog-auth", "confirm"]
            }
            if result != expectedResult || events != expectedEvents {
                failures.append("saved renewal catalog-only order and epoch/cancel boundary \(scenario)")
            }
            if savedKey != "sk-synthetic-saved-placeholder" || selection != originalSelection || preferences != originalPreferences {
                failures.append("saved renewal never saves, uploads or starts ASR; selection/switches unchanged \(scenario)")
            }
            if scenario == 0 {
                var attempt = CloudSetupAttemptState()
                let request = attempt.begin()
                if !attempt.accept(result, request: request, isCancelled: false,
                                   credentialIsCurrent: actions.credentialIsCurrent)
                    || !attempt.isAuthenticated(isCancelled: false,
                                                credentialIsCurrent: actions.credentialIsCurrent)
                    || attempt.isEnabled(isCancelled: false,
                                         credentialIsCurrent: actions.credentialIsCurrent) {
                    failures.append("saved renewal publication binds epoch without enabling")
                }
                currentEpoch = UUID()
                if attempt.isAuthenticated(isCancelled: false,
                                           credentialIsCurrent: actions.credentialIsCurrent) {
                    failures.append("saved renewal cannot retain success after credential changes")
                }
                events = []
                currentEpoch = epoch
                let withoutAcknowledgement = await CloudSetupFlow.renewSavedCredential(credentialEpoch: epoch,
                    quotaAcknowledged: false, actions: actions, isVisible: { true })
                if withoutAcknowledgement != .renewed(authorizedEpoch: epoch) || events.contains("confirm") {
                    failures.append("unchecked setup must not block or record a quota acknowledgment")
                }
            }
        }
        let cancelled = await Task { @MainActor in
            var events: [String] = []
            let actions = CloudSetupFlow.Actions(save: { _ in events.append("save"); return epoch },
                verify: { _ in
                    events.append("catalog-auth")
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .authenticated
                }, confirm: { _ in events.append("confirm"); return true },
                allowUpload: { _ in events.append("upload") }, enable: { _, _ in events.append("ASR-route"); return true },
                refresh: { events.append("refresh") }, credentialIsCurrent: { $0 == epoch },
                beginAuthorization: { _ in UUID() }, authorizationIsCurrent: { _ in true },
                commitAuthorization: { _ in true }, rollbackAuthorization: { _ in })
            let result = await CloudSetupFlow.renewSavedCredential(credentialEpoch: epoch,
                quotaAcknowledged: true, actions: actions, isVisible: { true })
            return result == .cancelled && events == ["catalog-auth"]
        }.value
        if !cancelled { failures.append("saved renewal Task cancellation cannot confirm or activate") }
        return failures
    }

    private static func retryChecks() async -> [String] {
        var failures: [String] = []
        for purpose in [CloudEntryPurpose.enhanceLocal, .route] {
            var attempt = CloudSetupAttemptState()
            var epoch = UUID()
            var events: [String] = []
            var verification = CloudSetupVerification.authenticated
            let actions = CloudSetupFlow.Actions(
                save: { _ in events.append("save"); epoch = UUID(); return epoch },
                verify: { _ in events.append("verify"); return verification },
                confirm: { _ in events.append("confirm"); return true },
                allowUpload: { _ in events.append("upload") },
                enable: { _, _ in events.append("enable"); return true },
                refresh: { events.append("refresh") }, credentialIsCurrent: { $0 == epoch },
                beginAuthorization: { _ in UUID() }, authorizationIsCurrent: { _ in true },
                commitAuthorization: { _ in true }, rollbackAuthorization: { _ in })
            let firstRequest = attempt.begin()
            let first = await CloudSetupFlow.run(draft: "sk-synthetic-first", quotaAcknowledged: true,
                purpose: purpose, actions: actions, isVisible: { attempt.isVisible })
            if first != .enabled(authorizedEpoch: epoch) ||
                !attempt.accept(first, request: firstRequest, isCancelled: false, credentialIsCurrent: actions.credentialIsCurrent) ||
                !attempt.isEnabled(isCancelled: false, credentialIsCurrent: actions.credentialIsCurrent) {
                failures.append("wizard retry fixture first success")
            }
            let oldEpoch = epoch
            // This is the same state transition used for back/edit/new verify.
            let retryRequest = attempt.begin()
            if attempt.isAuthenticated(isCancelled: false, credentialIsCurrent: actions.credentialIsCurrent) ||
                attempt.isEnabled(isCancelled: false, credentialIsCurrent: actions.credentialIsCurrent) {
                failures.append("wizard retry clears success before saving another key")
            }
            events = []; verification = .failed(.invalidKey)
            let retry = await CloudSetupFlow.run(draft: "sk-synthetic-replacement", quotaAcknowledged: true,
                purpose: purpose, actions: actions, isVisible: { attempt.isVisible })
            if epoch == oldEpoch || retry != .verificationFailed(.invalidKey) || retry.authorizedEpoch != nil ||
                events != ["save", "verify", "refresh"] {
                failures.append("wizard failed replacement does not confirm upload or enable")
            }
            _ = attempt.accept(retry, request: retryRequest, isCancelled: false, credentialIsCurrent: actions.credentialIsCurrent)
            if attempt.accept(first, request: firstRequest, isCancelled: false, credentialIsCurrent: { _ in true }) ||
                attempt.isAuthenticated(isCancelled: false, credentialIsCurrent: { _ in true }) ||
                attempt.isEnabled(isCancelled: false, credentialIsCurrent: { _ in true }) {
                failures.append("wizard old success cannot repaint or complete failed retry")
            }
            // A saved key with an unverified response has different semantics
            // from capabilityMissing, which returns before save is called.
            events = []; verification = .notNetworkVerified
            let beforeUnverified = epoch
            let unverified = await CloudSetupFlow.run(draft: "sk-synthetic-unverified", quotaAcknowledged: true,
                purpose: purpose, actions: actions, isVisible: { true })
            if epoch == beforeUnverified || unverified != .notNetworkVerified ||
                events != ["save", "verify", "refresh"] || unverified.authorizedEpoch != nil {
                failures.append("wizard post-save unverified cannot promise original credential preserved")
            }
        }
        return failures
    }

    private static func publicationChecks() -> [String] {
        var failures: [String] = []
        let savedEpoch = UUID(), originalEndpoint = UUID()
        var epoch = savedEpoch, endpoint = originalEndpoint
        let current: (UUID) -> Bool = { $0 == epoch && endpoint == originalEndpoint }
        var attempt = CloudSetupAttemptState()
        let request = attempt.begin()
        let success = CloudSetupResult.enabled(authorizedEpoch: savedEpoch)
        _ = attempt.accept(success, request: request, isCancelled: false, credentialIsCurrent: current)
        epoch = UUID()
        if attempt.isAuthenticated(isCancelled: false, credentialIsCurrent: current) ||
            attempt.isEnabled(isCancelled: false, credentialIsCurrent: current) ||
            attempt.accept(success, request: request, isCancelled: false, credentialIsCurrent: current) {
            failures.append("wizard epoch mutation blocks success display and close true")
        }
        epoch = savedEpoch
        _ = attempt.accept(success, request: request, isCancelled: false, credentialIsCurrent: current)
        endpoint = UUID()
        if attempt.isAuthenticated(isCancelled: false, credentialIsCurrent: current) ||
            attempt.isEnabled(isCancelled: false, credentialIsCurrent: current) ||
            attempt.accept(success, request: request, isCancelled: false, credentialIsCurrent: current) {
            failures.append("wizard endpoint mutation blocks success display and close true")
        }
        endpoint = originalEndpoint
        _ = attempt.accept(success, request: request, isCancelled: false, credentialIsCurrent: current)
        if attempt.isAuthenticated(isCancelled: true, credentialIsCurrent: current) ||
            attempt.isEnabled(isCancelled: true, credentialIsCurrent: current) ||
            attempt.accept(success, request: request, isCancelled: true, credentialIsCurrent: current) {
            failures.append("wizard cancelled success cannot display or complete")
        }
        attempt.dismiss()
        if attempt.isAuthenticated(isCancelled: false, credentialIsCurrent: current) ||
            attempt.isEnabled(isCancelled: false, credentialIsCurrent: current) ||
            attempt.accept(success, request: request, isCancelled: false, credentialIsCurrent: current) {
            failures.append("wizard hidden success cannot display or complete")
        }
        attempt.appear()
        if attempt.accept(success, request: request, isCancelled: false, credentialIsCurrent: current) ||
            attempt.isEnabled(isCancelled: false, credentialIsCurrent: current) {
            failures.append("wizard reopened view rejects previous visibility epoch")
        }
        return failures
    }

    private static func lateVerificationChecks() async -> [String] {
        var failures: [String] = []
        for interruption in 0..<4 {
            var attempt = CloudSetupAttemptState()
            let savedEpoch = UUID(), originalEndpoint = UUID()
            var epoch = savedEpoch, endpoint = originalEndpoint
            var events: [String] = []
            let gate = VerificationGate()
            let actions = CloudSetupFlow.Actions(
                save: { _ in events.append("save"); return savedEpoch },
                verify: { _ in events.append("verify"); return await gate.verify() },
                confirm: { _ in events.append("confirm"); return true },
                allowUpload: { _ in events.append("upload") },
                enable: { _, _ in events.append("enable"); return true },
                refresh: { events.append("refresh") },
                credentialIsCurrent: { $0 == epoch && endpoint == originalEndpoint },
                beginAuthorization: { _ in UUID() }, authorizationIsCurrent: { _ in true },
                commitAuthorization: { _ in true }, rollbackAuthorization: { _ in })
            let request = attempt.begin()
            let worker = Task { @MainActor in
                await CloudSetupFlow.run(draft: "sk-synthetic-delayed", quotaAcknowledged: true,
                    purpose: .enhanceLocal, actions: actions,
                    isVisible: { attempt.isActive(request, isCancelled: Task.isCancelled) })
            }
            await gate.waitUntilStarted()
            switch interruption {
            case 0: epoch = UUID()
            case 1: endpoint = UUID()
            case 2: worker.cancel()
            default: attempt.dismiss()
            }
            // Fake provider ignores cancellation and completes late anyway.
            gate.complete(.authenticated)
            let result = await worker.value
            if result != .cancelled || result.authorizedEpoch != nil || events != ["save", "verify"] {
                failures.append("wizard late verification cannot authorize side effects \(interruption)")
            }
            _ = attempt.accept(result, request: request, isCancelled: worker.isCancelled,
                credentialIsCurrent: actions.credentialIsCurrent)
            if attempt.isAuthenticated(isCancelled: worker.isCancelled, credentialIsCurrent: actions.credentialIsCurrent) ||
                attempt.isEnabled(isCancelled: worker.isCancelled, credentialIsCurrent: actions.credentialIsCurrent) {
                failures.append("wizard late verification cannot publish completion \(interruption)")
            }
        }
        return failures
    }

    @MainActor
    private final class VerificationGate {
        private var started = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var response: CheckedContinuation<CloudSetupVerification, Never>?
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func verify() async -> CloudSetupVerification {
            await withCheckedContinuation {
                response = $0; started = true; waiter?.resume(); waiter = nil
            }
        }
        func complete(_ result: CloudSetupVerification) { response?.resume(returning: result); response = nil }
    }
}
