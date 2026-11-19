import Foundation
@_spi(Testing) import VoicePointerCore

/// HP-28: "用于增强本地识别" as a stored switch, as a legacy consent id and as an admission purpose, through the
/// real gate on a temporary state file. The point of the purposes: a route switch left on (a crash between two
/// writes, an older version) must never admit a dictation on a local route that was not enhanced on purpose.
@MainActor
extension CloudEntryChecks {
    static func enhanceLocalChecks() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            if !condition { failures.append("cloud entry enhance: " + label()) }
        }

        let suiteName = "vp.selftest.cloudentry.enhance.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return ["cloud entry enhance: temporary UserDefaults suite unavailable"]
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("CloudEntryEnhanceChecks-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return ["cloud entry enhance: temporary state directory could not be created"]
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: root.appendingPathComponent("state.json")))

        // Off unless switched on, for a fresh install and an upgrade alike (the key is simply missing).
        expect(CloudEntryPreferences.enhanceLocalKey == "cloud.entry.enhanceLocal", "the stored key is the fixed one")
        expect(!CloudEntryPreferences().enhanceLocal, "a freshly built preference set has the enhancement off")
        let fresh = CloudEntryPreferences.load(from: defaults)
        expect(!fresh.enhanceLocal && fresh == CloudEntryPreferences(), "a missing key reads as the enhancement off")
        CloudEntryPreferences.setRouteEnabled(true, in: defaults)
        CloudEntryPreferences.setUploadConsent(true, in: defaults)
        expect(!CloudEntryPreferences.load(from: defaults).enhanceLocal, "the route's switches do not switch the enhancement on")
        CloudEntryPreferences.setEnhanceLocal(true, in: defaults)
        let stored = CloudEntryPreferences.load(from: defaults)
        expect(stored.enhanceLocal && stored.routeEnabled && stored.uploadConsent && stored.visible,
               "the enhancement persists next to the other switches")
        CloudEntryPreferences.setRouteEnabled(false, in: defaults)
        CloudEntryPreferences.setUploadConsent(false, in: defaults)
        expect(CloudEntryPreferences.load(from: defaults).enhanceLocal, "the other switches do not switch the enhancement off")
        CloudEntryPreferences.setEnhanceLocal(false, in: defaults)
        expect(CloudEntryPreferences.load(from: defaults) == CloudEntryPreferences(), "switching it off again reads as off")
        expect(CloudEntryPreferences(enhanceLocal: true) != CloudEntryPreferences(), "the enhancement takes part in equality")

        // The legacy consent set, for every combination of the four switches and several stored sets. The route's
        // id behaves as before; the enhancement's id is granted only by its own switches, never taken over.
        let enhanceID = CloudEntry.enhanceConsentID
        let storedSets: [Set<String>] = [
            [], ["groq"], [CloudEntry.provider], [enhanceID], ["groq", enhanceID], [CloudEntry.provider, enhanceID],
        ]
        for mask in 0..<16 {
            let visible = mask & 1 != 0, route = mask & 2 != 0, upload = mask & 4 != 0, enhance = mask & 8 != 0
            let preferences = CloudEntryPreferences(
                visible: visible, routeEnabled: route, uploadConsent: upload, enhanceLocal: enhance)
            for storedSet in storedSets {
                var expected = storedSet.subtracting([enhanceID])
                if visible, route, upload { expected.insert(CloudEntry.provider) }
                if visible, enhance, upload { expected.insert(enhanceID) }
                expect(preferences.legacyConsent(merging: storedSet) == expected,
                       "visible=\(visible) route=\(route) upload=\(upload) enhance=\(enhance) stored=\(storedSet.sorted()): got \(preferences.legacyConsent(merging: storedSet).sorted()), expected \(expected.sorted())")
            }
        }

        // Admission inputs by purpose: each purpose takes its own switch only; key, identity and the upload
        // permissions are shared, and the default purpose is the route's (every existing caller).
        let saved = CloudEntryCredential(isSaved: true, revision: "enhance-revision-01")
        for mask in 0..<16 {
            let visible = mask & 1 != 0, route = mask & 2 != 0, upload = mask & 4 != 0, enhance = mask & 8 != 0
            let preferences = CloudEntryPreferences(
                visible: visible, routeEnabled: route, uploadConsent: upload, enhanceLocal: enhance)
            let name = "visible=\(visible) route=\(route) upload=\(upload) enhance=\(enhance)"
            let byDefault = CloudEntry.inputs(preferences: preferences, gate: gate, credential: saved)
            let forRoute = CloudEntry.inputs(preferences: preferences, gate: gate, credential: saved, purpose: .route)
            let forEnhance = CloudEntry.inputs(preferences: preferences, gate: gate, credential: saved, purpose: .enhanceLocal)
            expect(preferences.isEnabled(for: .route) == route && preferences.isEnabled(for: .enhanceLocal) == enhance,
                   "\(name): each purpose reads its own switch")
            guard visible else {
                expect(byDefault == nil && forRoute == nil && forEnhance == nil, "\(name): with the entry off there are no inputs")
                continue
            }
            guard let byDefault, let forRoute, let forEnhance else {
                expect(false, "\(name): a visible entry with a saved key must give inputs for both purposes")
                continue
            }
            expect(byDefault.requirements == forRoute.requirements && byDefault.identity == forRoute.identity,
                   "\(name): the default purpose is the route's")
            expect(forRoute.requirements == CloudAdmissionRequirements(
                cloudRouteEnabled: route, credentialAvailable: true, sampleUploadAllowed: upload, sessionUploadAllowed: upload),
                   "\(name): the route's requirements")
            expect(forEnhance.requirements == CloudAdmissionRequirements(
                cloudRouteEnabled: enhance, credentialAvailable: true, sampleUploadAllowed: upload, sessionUploadAllowed: upload),
                   "\(name): the enhancement's requirements take the enhancement's switch, never the route's")
            expect(forEnhance.identity == forRoute.identity, "\(name): both purposes use the same identity")
        }
        expect(CloudEntryPurpose(routeID: CloudEntry.routeID) == .route, "a dictation on the Aliyun route asks as the route")
        for routeID in ["qwen17-rolling", "qwen06-rolling", "qwen06-incremental", "apple-speech", "sensevoice", "ALIYUN", "aliyun "] {
            expect(CloudEntryPurpose(routeID: routeID) == .enhanceLocal, "\(routeID) can only ask as an enhancement")
        }

        // Through the real gate, on a confirmed identity, so that only the purpose's switch decides.
        guard let revision = saved.revision, let identity = try? CloudEntry.makeIdentity(credentialRevision: revision) else {
            return failures + ["cloud entry enhance: identity fixture could not be created"]
        }
        expect(await CloudEntry.confirm(gate: gate, identity: identity) == .confirmed, "fixture: the confirmation must be recorded")
        guard let localSelection = try? VoiceInputSelection(mode: .voiceNative, routeID: "qwen17-rolling", language: "zh"),
              let cloudSelection = try? VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.routeID, language: "zh"),
              let local = try? VoiceInputSnapshot(sessionID: UUID(), selection: localSelection, lexiconRevision: 0),
              let cloud = try? VoiceInputSnapshot(sessionID: UUID(), selection: cloudSelection, lexiconRevision: 0) else {
            return failures + ["cloud entry enhance: snapshot fixtures could not be created"]
        }
        /// The provider the app installs, with these switches instead of the stored ones.
        func start(_ preferences: CloudEntryPreferences, _ snapshot: VoiceInputSnapshot) async -> String {
            let provider: CloudAdmissionInputsProvider = { snapshot in
                CloudEntry.inputs(
                    preferences: preferences, gate: gate, credential: saved,
                    purpose: CloudEntryPurpose(routeID: snapshot.selection.routeID)
                )
            }
            switch await CloudDictationStart.resolve(snapshot: snapshot, provider: provider) {
            case .admitted: return "admitted"
            case .denied(let reason): return reason
            }
        }
        let residue = CloudEntryPreferences(visible: true, routeEnabled: true, uploadConsent: true, enhanceLocal: false)
        expect(await start(residue, local) == "cloudRouteDisabled",
               "a route switch left on must not admit a local dictation that was not enhanced (HP-28)")
        expect(await start(residue, cloud) == "admitted", "the same switches still admit the Aliyun route itself")
        let enhanceOnly = CloudEntryPreferences(visible: true, routeEnabled: false, uploadConsent: true, enhanceLocal: true)
        // G1: entering and leaving the online route does not revoke a separately enabled enhancement.
        CloudEntryPreferences.setEnhanceLocal(true, in: defaults)
        CloudEntryPreferences.setUploadConsent(true, in: defaults)
        CloudEntryPreferences.setRouteEnabled(true, in: defaults)
        CloudEntryPreferences.leaveRoute(reconciling: .init(selection: cloudSelection,
            credentialAvailable: true, entryVisible: true), in: defaults)
        CloudEntryPreferences.reconcile(.init(selection: localSelection,
            credentialAvailable: true, entryVisible: true), in: defaults)
        let returned = CloudEntryPreferences.load(from: defaults)
        expect(!returned.routeEnabled && returned.uploadConsent && returned.enhanceLocal
            && HybridSessionPolicy.freezesEnhancement(consent: returned.legacyConsent(merging: []), selection: localSelection),
            "leaving online retains an enabled enhancement in the next local session")
        expect(await start(returned, local) == "admitted", "returned local enhancement is admitted without network")
        CloudEntryPreferences.setEnhanceLocal(false, in: defaults)
        CloudEntryPreferences.setRouteEnabled(true, in: defaults)
        CloudEntryPreferences.leaveRoute(reconciling: .init(selection: cloudSelection,
            credentialAvailable: true, entryVisible: true), in: defaults)
        let returnedOff = CloudEntryPreferences.load(from: defaults)
        expect(!returnedOff.uploadConsent && !HybridSessionPolicy.freezesEnhancement(
            consent: returnedOff.legacyConsent(merging: []), selection: localSelection),
            "leaving online without enhancement revokes upload and freezes no hybrid")
        // G2: revoking only permission immediately updates both UI entrances, without restoring that permission.
        CloudEntryPreferences.setEnhanceLocal(true, in: defaults)
        CloudEntryPreferences.setUploadConsent(true, in: defaults)
        let source = OnlineEnhancementPreferenceSource(defaults: defaults)
        var changes = 0
        source.onChange = { changes += 1 }
        expect(source.enhanceLocalWithOnlineAPI, "permission-backed enhancement displays on")
        CloudEntryPreferences.setUploadConsent(false, in: defaults)
        source.synchronize()
        expect(!source.enhanceLocalWithOnlineAPI && changes == 1
            && CloudEntryPreferences.load(from: defaults).enhanceLocal
            && !CloudEntryPreferences.load(from: defaults).uploadConsent,
            "revoked upload displays off and never regrants permission")
        expect(await start(enhanceOnly, local) == "admitted", "the enhancement admits an enhanced local dictation")
        expect(await start(enhanceOnly, cloud) == "cloudRouteDisabled", "the enhancement never admits the Aliyun route")
        let noUpload = CloudEntryPreferences(visible: true, routeEnabled: false, uploadConsent: false, enhanceLocal: true)
        expect(await start(noUpload, local) == "sampleUploadNotAllowed", "the enhancement still needs the upload permission")
        let hidden = CloudEntryPreferences(visible: false, routeEnabled: true, uploadConsent: true, enhanceLocal: true)
        expect(await start(hidden, local) == "notConfigured", "with the entry off the enhancement is not configured")
        expect(await start(enhanceOnly, local) == "admitted", "fixture: still admitted before the pause")
        _ = await gate.recordProviderFailure(Self.quotaEvidence(), for: identity)
        expect(await start(enhanceOnly, local) == "paused.freeQuotaExhausted",
               "one quota pause of the shared identity stops the enhancement as well")
        return failures
    }

    /// Exact evidence of a used-up free quota: HTTP 403 with `AllocationQuota.FreeTierOnly` in the same response.
    private static func quotaEvidence() -> AliFailureEvidence {
        let response = HTTPURLResponse(
            url: URL(string: "https://invalid.example/fixture")!, statusCode: 403, httpVersion: nil, headerFields: nil
        )!
        let body = try? JSONSerialization.data(withJSONObject: ["code": "AllocationQuota.FreeTierOnly"])
        return AliFailureEvidence.httpResponse(response, body: body)!
    }
}
