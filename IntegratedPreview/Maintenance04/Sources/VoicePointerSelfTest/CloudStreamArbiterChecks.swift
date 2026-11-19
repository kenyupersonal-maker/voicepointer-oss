import Foundation
@_spi(Testing) import VoicePointerCore

/// K06 per-stream arbitration and start-of-dictation decision. Pure and offline: one temporary state
/// file, no network, microphone, credential, worker or recognizer.
@MainActor
enum CloudStreamArbiterChecks {
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

        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("CloudStreamArbiterChecks-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return ["temporary arbiter store directory could not be created"]
        }
        defer { try? FileManager.default.removeItem(at: root) }

        func identity(_ model: String) throws -> CloudAdmissionIdentity {
            try CloudAdmissionIdentity(
                provider: "aliyun", accountReference: "account-ref-opaque-01",
                credentialRevision: "credential-revision-01",
                region: "cn-beijing", workspace: "workspace-main", modelID: model
            )
        }
        let open = CloudAdmissionRequirements(
            cloudRouteEnabled: true, credentialAvailable: true,
            sampleUploadAllowed: true, sessionUploadAllowed: true
        )
        let gate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: root.appendingPathComponent("state.json")))

        /// Explicit policy and user confirmation, then a real permit from the gate.
        func admitted(_ model: String) async -> CloudStreamAdmission? {
            guard let id = try? identity(model),
                  await gate.setPolicy(.freeOnly, for: id) == .updated,
                  await gate.confirmFreeOnlyGuard(for: id, verificationRevision: "arbiter-fixture") == .confirmed,
                  case .admitted(let permit) = await gate.admission(for: id, requirements: open) else { return nil }
            return CloudStreamAdmission(
                inputs: CloudAdmissionInputs(gate: gate, identity: id, requirements: open), permit: permit
            )
        }

        // Frames and events: forwarded before a revocation, dropped after it; other epochs never deliver.
        guard let quota = await admitted("arbiter-quota"), let quotaID = try? identity("arbiter-quota") else {
            return failures + ["arbiter fixture: the gate did not admit an explicitly confirmed identity"]
        }
        let stream = CloudStreamArbiter(admission: quota)
        expect(stream.epoch == 0 && !stream.isRevoked, "a new stream starts under the permit epoch, unrevoked")
        expect(await stream.verifyPermit(), "a fresh permit must verify against the gate")
        expect(stream.admitFrame() && stream.admitFrame(), "frames pass before any revocation")
        expect(stream.admitEvent(startedUnderEpoch: 0), "a transcript from the stream's own epoch is delivered")
        expect(!stream.admitEvent(startedUnderEpoch: 7), "a transcript from another epoch has no delivery right")

        // Evidence the gate does not accept as a pause must neither pause nor revoke.
        let notExact: [(String, AliFailureEvidence)] = [
            ("403 with another code", evidence(status: 403, code: "AccessDenied.Unpurchased")),
            ("429 with the quota code", evidence(status: 429, code: "AllocationQuota.FreeTierOnly")),
            ("403 status only", evidence(status: 403, code: nil)),
            ("WebSocket code only", AliServiceFailure.fromServiceCode("AllocationQuota.FreeTierOnly").evidence!),
        ]
        for (label, item) in notExact {
            expect(await stream.recordProviderFailure(item) == .notAPause, "\(label) must not pause")
        }
        expect(!stream.isRevoked && stream.admitFrame(), "non-exact evidence must leave the stream running")
        expect(await gate.snapshot(for: quotaID)?.pauseEpoch == 0, "non-exact evidence must not touch the pause epoch")

        // Exact evidence pauses persistently and revokes at once.
        let paused = await stream.recordProviderFailure(evidence(status: 403, code: "AllocationQuota.FreeTierOnly"))
        expect(paused == .paused(epoch: 1), "exact quota evidence must pause and report the new epoch")
        expect(stream.revocation == .providerPause, "an accepted pause must revoke the stream")
        let dropped = stream.counts.framesDropped
        expect(!stream.admitFrame() && stream.counts.framesDropped == dropped + 1, "no frame may leave after the pause")
        expect(!stream.admitEvent(startedUnderEpoch: 0), "a late transcript from the paused stream is dropped")
        expect(!(await stream.verifyPermit()), "the old permit must not verify after the pause")
        expect(!stream.revoke(reason: .permitStale) && stream.revocation == .providerPause, "revocation is one-way")
        expect(
            await gate.admission(for: quotaID, requirements: open) == .denied(.paused(.freeQuotaExhausted)),
            "the pause must be persisted for later dictations"
        )

        // The balance block is the other accepted pause.
        if let balance = await admitted("arbiter-balance") {
            let stopped = CloudStreamArbiter(admission: balance)
            expect(
                await stopped.recordProviderFailure(evidence(status: 400, code: "Arrearage")) == .paused(epoch: 1)
                    && stopped.isRevoked,
                "400 with Arrearage must pause and revoke"
            )
        } else { failures.append("arbiter fixture: balance identity was not admitted") }

        // A pause recorded elsewhere is noticed at the next gate read.
        if let other = await admitted("arbiter-elsewhere"), let otherID = try? identity("arbiter-elsewhere") {
            let bystander = CloudStreamArbiter(admission: other)
            _ = await gate.recordProviderFailure(evidence(status: 403, code: "AllocationQuota.FreeTierOnly"), for: otherID)
            expect(!(await bystander.verifyPermit()), "a permit paused by another path must stop verifying")
            expect(bystander.revocation == .permitStale && !bystander.admitFrame(), "the stale stream must stop forwarding")
        } else { failures.append("arbiter fixture: bystander identity was not admitted") }

        // Failing closed: exact evidence that cannot be persisted still revokes.
        let brokenURL = root.appendingPathComponent("broken.json")
        try? Data("not-json".utf8).write(to: brokenURL)
        let brokenGate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: brokenURL))
        let unsafe = CloudStreamArbiter(admission: CloudStreamAdmission(
            inputs: CloudAdmissionInputs(gate: brokenGate, identity: quotaID, requirements: open), permit: quota.permit
        ))
        expect(
            await unsafe.recordProviderFailure(evidence(status: 403, code: "AllocationQuota.FreeTierOnly")) == .storageUnavailable
                && unsafe.isRevoked,
            "a pause that cannot be persisted must still stop the stream"
        )

        // Start of dictation: anything but an explicit permit is a denial that falls back to local.
        guard let selection = try? VoiceInputSelection(mode: .voiceNative, routeID: "aliyun", language: "auto"),
              let snapshot = try? VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 4),
              let startID = try? identity("arbiter-start") else {
            return failures + ["start fixture could not be created"]
        }
        func denialReason(_ start: CloudDictationStart) -> String {
            switch start {
            case .denied(let reason): return reason
            case .admitted: return "admitted"
            }
        }
        expect(
            denialReason(await CloudDictationStart.resolve(snapshot: snapshot, provider: nil)) == "notConfigured",
            "no admission inputs must be a denial"
        )
        expect(
            denialReason(await CloudDictationStart.resolve(snapshot: snapshot, provider: { _ in nil })) == "notConfigured",
            "inputs that cannot be built must be a denial"
        )
        expect(
            denialReason(await CloudDictationStart.resolve(snapshot: snapshot, provider: { _ in
                CloudAdmissionInputs(gate: gate, identity: startID, requirements: CloudAdmissionRequirements())
            })) == "cloudRouteDisabled",
            "closed per-call permissions must be a denial"
        )
        let openProvider: CloudAdmissionInputsProvider = { _ in
            CloudAdmissionInputs(gate: gate, identity: startID, requirements: open)
        }
        expect(
            denialReason(await CloudDictationStart.resolve(snapshot: snapshot, provider: openProvider)) == "admitted",
            "quota acknowledgment is optional when all audio permissions are present"
        )
        _ = await gate.setPolicy(.freeOnly, for: startID)
        _ = await gate.confirmFreeOnlyGuard(for: startID, verificationRevision: "arbiter-start-fixture")
        expect(
            denialReason(await CloudDictationStart.resolve(snapshot: snapshot, provider: openProvider)) == "admitted",
            "an explicitly confirmed identity may be admitted"
        )
        _ = await gate.recordProviderFailure(evidence(status: 403, code: "AllocationQuota.FreeTierOnly"), for: startID)
        expect(
            denialReason(await CloudDictationStart.resolve(snapshot: snapshot, provider: openProvider)) == "paused.freeQuotaExhausted",
            "a paused identity must be denied at the next dictation start"
        )
        let fallback = CloudDictationStart.localFallbackSnapshot(for: snapshot)
        expect(
            fallback?.sessionID == snapshot.sessionID && fallback?.lexiconRevision == 4
                && fallback?.selection.language == "auto" && fallback?.selection.mode == .voiceNative
                && fallback?.selection.routeID == "qwen17-rolling",
            "the local fallback must keep the session, language and lexicon revision"
        )
        return failures
    }
}
