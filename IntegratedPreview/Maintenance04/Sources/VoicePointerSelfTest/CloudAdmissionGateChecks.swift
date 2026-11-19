import Foundation
import VoicePointerCore

enum CloudAdmissionGateChecks {
    private static func evidence(status: Int, code: String?) -> AliFailureEvidence {
        let response = HTTPURLResponse(
            url: URL(string: "https://invalid.example/fixture")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = code.flatMap { try? JSONSerialization.data(withJSONObject: ["code": $0]) }
        return AliFailureEvidence.httpResponse(response, body: body)!
    }

    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        do {
            let defaultURL = try CloudAdmissionStateStore.defaultFileURL().standardizedFileURL
            let expectedSuffix = ["com.kenyu.voicepointer.mac", "CloudAdmission-v1", "state.json"]
            expect(
                Array(defaultURL.pathComponents.suffix(expectedSuffix.count)) == expectedSuffix,
                "default state path must belong to the Maintenance04 bundle ID"
            )
            expect(
                !defaultURL.path.contains("com.kenyu.VoicePointer.IntegratedPreview"),
                "default state path must not point at the IntegratedPreview bundle ID"
            )
        } catch {
            expect(false, "default state path must be available for Maintenance04")
        }

        let temporaryDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        )
        let root = temporaryDirectory
            .appendingPathComponent("CloudAdmissionGateChecks-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("state.json", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return ["temporary cloud admission store directory could not be created"]
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let identity: CloudAdmissionIdentity
        do {
            identity = try CloudAdmissionIdentity(
                provider: "aliyun",
                accountReference: "account-ref-opaque-01",
                credentialRevision: "credential-revision-01",
                region: "cn-beijing",
                workspace: "workspace-main",
                modelID: "qwen-realtime-fixture"
            )
        } catch {
            return ["valid cloud admission identity was rejected"]
        }

        let requirements = CloudAdmissionRequirements(
            cloudRouteEnabled: true,
            credentialAvailable: true,
            sampleUploadAllowed: true,
            sessionUploadAllowed: true
        )
        let gate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: fileURL))

        let defaultSnapshot = await gate.snapshot(for: identity)
        expect(defaultSnapshot?.policy == .disabled, "new identity must default to disabled policy")
        expect(defaultSnapshot?.guardEvidence == .unknown, "new identity must default to unknown guard evidence")
        let closedDecision = await gate.admission(for: identity, requirements: requirements)
        if case .denied = closedDecision { expect(false, "unchecked quota permits audio with all explicit permissions") }
        let noInputs = await gate.admission(for: identity)
        expect(noInputs == .denied(.cloudRouteDisabled), "omitted per-call permissions must fail closed")

        expect(await gate.setPolicy(.freeOnly, for: identity) == .updated, "freeOnly must require an explicit policy update")
        let unknownDecision = await gate.admission(for: identity, requirements: requirements)
        if case .denied = unknownDecision { expect(false, "unknown quota acknowledgment is not an upload prerequisite") }

        let missingCredential = CloudAdmissionRequirements(cloudRouteEnabled: true)
        expect(
            await gate.admission(for: identity, requirements: missingCredential) == .denied(.credentialUnavailable),
            "gate must require caller-provided credential availability"
        )
        let missingSample = CloudAdmissionRequirements(cloudRouteEnabled: true, credentialAvailable: true)
        expect(
            await gate.admission(for: identity, requirements: missingSample) == .denied(.sampleUploadNotAllowed),
            "gate must require per-sample upload permission"
        )
        let missingSession = CloudAdmissionRequirements(
            cloudRouteEnabled: true,
            credentialAvailable: true,
            sampleUploadAllowed: true
        )
        expect(
            await gate.admission(for: identity, requirements: missingSession) == .denied(.sessionUploadNotAllowed),
            "gate must require per-session upload permission"
        )

        expect(
            await gate.confirmFreeOnlyGuard(for: identity, verificationRevision: "fixture-1") == .confirmed,
            "explicit guard confirmation should be recorded"
        )
        let confirmedSnapshot = await gate.snapshot(for: identity)
        expect(confirmedSnapshot?.guardEvidence == .userConfirmed, "user action must remain userConfirmed, never providerVerified")
        expect(confirmedSnapshot?.verificationRevision == "fixture-1", "confirmation revision must be identity-scoped")

        let initialPermit: CloudAdmissionPermit
        switch await gate.admission(for: identity, requirements: requirements) {
        case .admitted(let permit): initialPermit = permit
        case .denied(let denial):
            failures.append("confirmed freeOnly identity should admit: \(denial)")
            return failures
        }
        expect(
            await gate.isPermitCurrent(initialPermit, for: identity, requirements: requirements),
            "fresh permit should be current before any failure"
        )

        do {
            let staleIdentity = try CloudAdmissionIdentity(
                provider: "aliyun", accountReference: "account-ref-opaque-01",
                credentialRevision: "credential-revision-01",
                region: "cn-beijing", workspace: "workspace-main", modelID: "stale-guard-fixture"
            )
            expect(await gate.setPolicy(.freeOnly, for: staleIdentity) == .updated,
                   "stale fixture policy should be enabled explicitly")
            expect(await gate.confirmFreeOnlyGuard(
                for: staleIdentity, verificationRevision: "stale-fixture-1",
                observedAt: Date(timeIntervalSinceNow: -(30 * 24 * 3_600 + 1))
            ) == .confirmed, "stale fixture confirmation should be stored")
            if case .denied = await gate.admission(for: staleIdentity, requirements: requirements) {
                expect(false, "30-day quota acknowledgment expiry does not block audio")
            }
        } catch {
            expect(false, "stale guard fixture should be valid")
        }

        let changedIdentities: [CloudAdmissionIdentity]
        do {
            changedIdentities = [
                try CloudAdmissionIdentity(provider: "groq", accountReference: identity.accountReference, credentialRevision: identity.credentialRevision, region: identity.region, workspace: identity.workspace, modelID: identity.modelID),
                try CloudAdmissionIdentity(provider: identity.provider, accountReference: "account-ref-opaque-02", credentialRevision: identity.credentialRevision, region: identity.region, workspace: identity.workspace, modelID: identity.modelID),
                try CloudAdmissionIdentity(provider: identity.provider, accountReference: identity.accountReference, credentialRevision: "credential-revision-02", region: identity.region, workspace: identity.workspace, modelID: identity.modelID),
                try CloudAdmissionIdentity(provider: identity.provider, accountReference: identity.accountReference, credentialRevision: identity.credentialRevision, region: "us-east", workspace: identity.workspace, modelID: identity.modelID),
                try CloudAdmissionIdentity(provider: identity.provider, accountReference: identity.accountReference, credentialRevision: identity.credentialRevision, region: identity.region, workspace: "workspace-alt", modelID: identity.modelID),
                try CloudAdmissionIdentity(provider: identity.provider, accountReference: identity.accountReference, credentialRevision: identity.credentialRevision, region: identity.region, workspace: identity.workspace, modelID: "other-model")
            ]
        } catch {
            return failures + ["identity variation fixture could not be created"]
        }
        for (index, changed) in changedIdentities.enumerated() {
            let snapshot = await gate.snapshot(for: changed)
            expect(snapshot?.policy == .disabled, "identity dimension \(index) must not inherit freeOnly policy")
            expect(snapshot?.guardEvidence == .unknown, "identity dimension \(index) must not inherit guard evidence")
            expect(
                !(await gate.isPermitCurrent(initialPermit, for: changed, requirements: requirements)),
                "identity dimension \(index) must invalidate the old permit"
            )
        }

        let ignored403 = await gate.recordProviderFailure(Self.evidence(status: 403, code: "AccessDenied.Unpurchased"), for: identity)
        let ignored429 = await gate.recordProviderFailure(Self.evidence(status: 429, code: "AllocationQuota.FreeTierOnly"), for: identity)
        let ignoredWrongStatus = await gate.recordProviderFailure(Self.evidence(status: 401, code: "AllocationQuota.FreeTierOnly"), for: identity)
        let ignoredCodeOnly = await gate.recordProviderFailure(
            AliServiceFailure.fromServiceCode("AllocationQuota.FreeTierOnly").evidence!, for: identity
        )
        let ignoredStatusOnly = await gate.recordProviderFailure(Self.evidence(status: 403, code: nil), for: identity)
        expect(ignored403 == .ignored && ignored429 == .ignored && ignoredWrongStatus == .ignored
               && ignoredCodeOnly == .ignored && ignoredStatusOnly == .ignored,
               "only matching service status and code may pause")
        expect(
            await gate.isPermitCurrent(initialPermit, for: identity, requirements: requirements),
            "nonmatching provider errors must not invalidate a permit"
        )

        let pause = await gate.recordProviderFailure(Self.evidence(status: 403, code: "AllocationQuota.FreeTierOnly"), for: identity)
        expect(pause == .paused(pauseEpoch: 1, persisted: true), "exact quota signal must persistently increment pause epoch")
        expect(
            !(await gate.isPermitCurrent(initialPermit, for: identity, requirements: requirements)),
            "pre-pause permit and late response must become stale"
        )

        let concurrentAdmissions = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<96 {
                group.addTask {
                    if case .admitted = await gate.admission(for: identity, requirements: requirements) { return true }
                    return false
                }
            }
            var count = 0
            for await admitted in group where admitted { count += 1 }
            return count
        }
        expect(concurrentAdmissions == 0, "no new request may be admitted after pause completes")

        let restartedGate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: fileURL))
        let restored = await restartedGate.snapshot(for: identity)
        expect(restored?.pauseReason == .freeQuotaExhausted, "quota pause must survive gate/store restart")
        expect(restored?.pauseEpoch == 1, "restarted state must retain pause epoch")
        let restoredAdmission = await restartedGate.admission(for: identity, requirements: requirements)
        expect(restoredAdmission == .denied(.paused(.freeQuotaExhausted)), "restarted gate must remain paused")

        expect(
            await restartedGate.confirmFreeOnlyGuard(for: identity, verificationRevision: "fixture-2") == .confirmed,
            "confirmation alone may update evidence while pause remains set"
        )
        let stillPaused = await restartedGate.admission(for: identity, requirements: requirements)
        expect(stillPaused == .denied(.paused(.freeQuotaExhausted)), "confirmation alone must not resume a paused identity")

        let resumed = await restartedGate.recheckAndResumeAfterQuotaPause(
            for: identity,
            verificationRevision: "fixture-3",
            observedAt: Date(timeIntervalSince1970: 200),
            resumeRequestedAt: Date(timeIntervalSince1970: 201)
        )
        expect(resumed == .resumed(pauseEpoch: 1), "explicit recheck may clear pause without resetting epoch")
        let resumedSnapshot = await restartedGate.snapshot(for: identity)
        expect(resumedSnapshot?.pauseReason == nil, "explicit resume must clear pause reason")
        expect(resumedSnapshot?.guardEvidence == .userConfirmed, "explicit resume must record only user confirmation")
        expect(resumedSnapshot?.resumeRequestedAt == Date(timeIntervalSince1970: 201), "explicit resume time must persist")
        expect(
            !(await restartedGate.isPermitCurrent(initialPermit, for: identity, requirements: requirements)),
            "pre-pause permit must remain stale after explicit resume"
        )

        do {
            let balanceIdentity = try CloudAdmissionIdentity(
                provider: "aliyun", accountReference: "account-ref-opaque-01",
                credentialRevision: "credential-revision-01",
                region: "cn-beijing", workspace: "workspace-main", modelID: "balance-fixture"
            )
            expect(await restartedGate.setPolicy(.freeOnly, for: balanceIdentity) == .updated,
                   "balance fixture policy should be enabled explicitly")
            expect(await restartedGate.confirmFreeOnlyGuard(
                for: balanceIdentity, verificationRevision: "balance-fixture-1"
            ) == .confirmed, "balance fixture needs a separate confirmation")
            let balancePermit: CloudAdmissionPermit?
            if case .admitted(let permit) = await restartedGate.admission(
                for: balanceIdentity, requirements: requirements
            ) { balancePermit = permit } else { balancePermit = nil }
            expect(balancePermit != nil, "balance fixture should begin admitted")
            expect(await restartedGate.recordProviderFailure(Self.evidence(status: 403, code: "Arrearage"), for: balanceIdentity) == .ignored, "wrong-status Arrearage must not pause")
            expect(await restartedGate.recordProviderFailure(Self.evidence(status: 400, code: "Arrearage"), for: balanceIdentity) == .paused(pauseEpoch: 1, persisted: true), "exact account balance error must pause")
            if let balancePermit {
                expect(!(await restartedGate.isPermitCurrent(
                    balancePermit, for: balanceIdentity, requirements: requirements
                )), "balance pause must revoke the old permit")
            }
            let balanceReloaded = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: fileURL))
            expect(await balanceReloaded.admission(
                for: balanceIdentity, requirements: requirements
            ) == .denied(.paused(.accountBalanceBlocked)), "balance pause must survive restart")
        } catch {
            expect(false, "balance pause fixture should be valid")
        }

        let secondPause = await restartedGate.recordProviderFailure(Self.evidence(status: 403, code: "AllocationQuota.FreeTierOnly"), for: identity)
        expect(secondPause == .paused(pauseEpoch: 2, persisted: true), "a later exact quota signal must increment epoch again")
        let persistedData = try? Data(contentsOf: fileURL)
        let persistedText = persistedData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(!persistedText.contains(identity.accountReference), "persistent state must not contain account reference text")
        expect(!persistedText.contains(identity.credentialRevision), "persistent state must not contain credential revision text")
        expect(!persistedText.contains(identity.modelID), "persistent state must not contain raw model identity text")

        let malformedURL = root.appendingPathComponent("malformed.json", isDirectory: false)
        try? Data("not-json".utf8).write(to: malformedURL)
        let malformedGate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: malformedURL))
        expect(
            await malformedGate.admission(for: identity, requirements: requirements) == .denied(.storageUnavailable),
            "malformed persistence must fail closed"
        )

        return failures
    }
}
