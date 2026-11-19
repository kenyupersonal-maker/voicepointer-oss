// T7 2026-10-02: Deterministic policy + production hybrid/edit runtime, synthetic inputs only.
import Foundation
@preconcurrency import AVFoundation
@_spi(Testing) import VoicePointerCore

@MainActor enum EnhancementLearningChecks {
    typealias P = EnhancementLearningPipeline
    static let local = "use open ai for drafting notes"
    static let reference = "use OpenAI for drafting notes"
    static let instant = Date(timeIntervalSince1970: 1_000)
    static func sample(round: UUID = UUID(), confidence: Double? = 0.99, delta: Double = 0,
                       localText: String = local, referenceText: String = reference) -> EnhancementComparison {
        .init(roundID: round, localText: localText, referenceText: referenceText, localAt: instant,
              referenceAt: instant.addingTimeInterval(delta), localConfidence: confidence, source: .onlineAPI)
    }
    static func run() async -> [String] {
        var failures = pureChecks()
        failures += await runtimeChecks()
        failures += await hybridChecks()
        failures += await localBackendChecks()
        failures += await persistenceChecks()
        print("event=enhancement_learning_checks failures=\(failures.count) synthetic=1 confidence_production=selected_token_minimum")
        return failures
    }
    static func pureChecks() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) { if !ok { failures.append("enhancement policy: " + label) } }
        let c = EnhancementLearningConfiguration()
        let score = P.similarity(local, reference)
        var strictRatio = c; strictRatio.minimumLengthRatio = 1
        var strictAlignment = c; strictAlignment.minimumAlignmentConfidence = score.nextUp
        var exactAlignment = c; exactAlignment.minimumAlignmentConfidence = score
        var strictSimilarity = c; strictSimilarity.minimumSimilarity = score.nextUp
        var bad = c; bad.requiredRounds = 1
        let cases: [(String, EnhancementComparison, Bool, EnhancementLearningConfiguration, P.Decision)] = [
            ("within time window", sample(delta: 8), false, c, .candidate),
            ("outside time window", sample(delta: 8.01), false, c, .timeWindow),
            ("reverse timestamp outside", sample(delta: -8.01), false, c, .timeWindow),
            ("length ratio config", sample(), false, strictRatio, .lengthRatio),
            ("no text match", sample(referenceText: "completely different unrelated writing"), false, c, .lengthRatio),
            ("alignment boundary allowed", sample(), false, exactAlignment, .candidate),
            ("alignment boundary rejected", sample(), false, strictAlignment, .alignment),
            ("similarity boundary rejected", sample(), false, strictSimilarity, .alignment),
            ("user edit excluded", sample(), true, c, .edited),
            ("unknown confidence", sample(confidence: nil), false, c, .unknownConfidence),
            ("invalid confidence", sample(confidence: .nan), false, c, .unknownConfidence),
            ("low confidence", sample(confidence: 0.89), false, c, .lowConfidence),
            ("exact confidence threshold", sample(confidence: 0.9), false, c, .candidate),
            ("unchanged", sample(referenceText: local), false, c, .noDifference),
            ("single round config prohibited", sample(), false, bad, .invalidConfiguration)
        ]
        for (label, input, edited, config, wanted) in cases {
            let result = P.evaluate(input, userEdited: edited, configuration: config, terms: [])
            check(result.decision == wanted, label)
            check(result == P.evaluate(input, userEdited: edited, configuration: config, terms: []), label + " deterministic")
        }
        // Full-context privacy filtering must run even when the difference itself looks like a harmless brand.
        for suffix in [" 13800138000", " a@example.invalid", " ID110101199001010000", " 地址北京市朝阳路",
                       " 金额一千元", " $99", " 我叫张伟", " 住在幸福小区", " passport123", " phone", " 电话一三八零", " 账号秘密"] {
            let input = sample(localText: local + suffix, referenceText: reference + suffix)
            check(P.evaluate(input, userEdited: false, configuration: c, terms: []).decision == .privacy, "privacy sample")
        }
        check(P.containsPrivateInformation("address at Elm street"), "English address context")
        let evaluated = P.evaluate(sample(), userEdited: false, configuration: c, terms: [])
        check(evaluated.differences.count == 1, "existing spelling extractor produces one pair")
        guard let difference = evaluated.differences.first else { return failures }
        let owned: [LexiconTerm] = [
            .init(canonical: difference.canonical), .init(canonical: "Other", variants: [difference.variant]),
            .init(canonical: difference.variant), .init(canonical: "Other", variants: [difference.canonical]),
            .init(canonical: difference.canonical, isEnabled: false)
        ]
        for term in owned {
            check(P.evaluate(sample(), userEdited: false, configuration: c, terms: [term]).decision == .conflict, "existing term conflict")
        }
        check(P.evaluate(sample(), userEdited: false, configuration: c, terms: [], confirmed: [difference]).decision == .conflict,
              "confirmed/pending pair conflict")
        var pool = P.CandidatePool()
        let firstRound = UUID()
        check(pool.ingest(evaluated, roundID: firstRound, now: instant, configuration: c, terms: []).1.isEmpty, "single round cannot promote")
        for _ in 0..<5 {
            check(pool.ingest(evaluated, roundID: firstRound, now: instant, configuration: c, terms: []).0 == .duplicateRound,
                  "same round cannot increase count")
        }
        for confidence: Double? in [nil, 0.1, 0.89] {
            for _ in 0..<4 {
                let low = P.evaluate(sample(confidence: confidence), userEdited: false, configuration: c, terms: [])
                check(pool.ingest(low, roundID: UUID(), now: instant, configuration: c, terms: []).1.isEmpty, "low/unknown never accumulate")
            }
        }
        check(pool.ingest(evaluated, roundID: UUID(), now: instant, configuration: c, terms: []).1.isEmpty, "second round cannot promote")
        let promotion = pool.ingest(evaluated, roundID: UUID(), now: instant, configuration: c, terms: []).1
        check(promotion.count == 1 && promotion.first?.sightings == 3 && pool.count == 0, "all conditions promote third round")
        var configurable = c; configurable.requiredRounds = 2
        var changed = P.CandidatePool()
        _ = changed.ingest(evaluated, roundID: UUID(), now: instant, configuration: c, terms: [])
        check(changed.ingest(evaluated, roundID: UUID(), now: instant, configuration: configurable, terms: []).1.isEmpty,
              "changed config invalidates previous evidence")
        check(changed.ingest(evaluated, roundID: UUID(), now: instant, configuration: configurable, terms: []).1.count == 1,
              "configured two distinct rounds promote")
        var expiring = P.CandidatePool()
        _ = expiring.ingest(evaluated, roundID: UUID(), now: instant, configuration: c, terms: [])
        _ = expiring.ingest(evaluated, roundID: UUID(), now: instant.addingTimeInterval(301), configuration: c, terms: [])
        check(expiring.ingest(evaluated, roundID: UUID(), now: instant.addingTimeInterval(302), configuration: c, terms: []).1.isEmpty,
              "expired sightings cannot promote")
        var limited = c; limited.candidateLimit = 1
        var bounded = P.CandidatePool()
        _ = bounded.ingest(evaluated, roundID: UUID(), now: instant, configuration: limited, terms: [])
        let other = P.evaluate(sample(localText: "use Git Hub for drafting notes", referenceText: "use GitHub for drafting notes"),
                               userEdited: false, configuration: limited, terms: [])
        _ = bounded.ingest(other, roundID: UUID(), now: instant, configuration: limited, terms: [])
        check(bounded.count == 1, "bounded memory pool")
        for decision in [P.Decision.disabled, .unknownConfidence, .candidate, .promoted, .privacy, .edited] {
            check(P.isSafeLog(P.log(decision: decision, candidates: 2, promotions: 0)), "log whitelist")
        }
        check(!P.isSafeLog("event=enhancement_learning decision=unknown candidates=1 promotions=0"), "free reason not logged")
        check(!P.isSafeLog(P.log(decision: .candidate, candidates: 1, promotions: 0) + " text=synthetic"), "extra text key refused")
        return failures
    }

    static func receipt(_ text: String) -> KeptDictationBaseline {
        .init(id: UUID(), processIdentifier: 0, document: text, spanLocation: 0, spanLength: text.utf16.count,
              delivered: text, emptyStateValues: [], editingGeneration: 0, path: "inline", revertTexts: [])
    }
    static func observe(_ runtime: EnhancementLearningRuntime, input: EnhancementComparison = sample(), edited: Bool = false) {
        runtime.enhancementReceiver()?(input)
        let baseline = receipt(reference)
        runtime.dictationKept(.init(rawText: reference, text: reference, hits: [], routeID: "synthetic"), baseline: baseline)
        runtime.sessionBegan(revisit: .init(baselineID: baseline.id,
                                          document: edited ? "use other tools for drafting notes" : reference,
                                          editingGeneration: edited ? 1 : 0))
    }
    static func runtimeChecks() async -> [String] {
        var failures: [String] = [], logs: [String] = []
        var saved: [P.Promotion] = []
        let runtime = EnhancementLearningRuntime(terms: { [] }, now: { instant }, trace: { logs.append($0) },
            persist: { promotion, permit, epoch in
                permit.withAuthorization(epoch) { saved.append(promotion); return true } ?? false
            })
        func check(_ ok: Bool, _ label: String) { if !ok { failures.append("enhancement runtime: " + label) } }
        check(runtime.enhancementReceiver() == nil, "default off")
        for (online, learning) in [(false, false), (false, true)] {
            runtime.authorize(onlineEnabled: online, learningEnabled: learning)
            for _ in 0..<4 { observe(runtime) }
            check(saved.isEmpty && runtime.candidateCount == 0 && runtime.enhancementReceiver() == nil, "online enhancement disabled")
        }
        runtime.authorize(onlineEnabled: true, learningEnabled: false)
        check(runtime.enhancementReceiver() != nil, "online learning follows enhancement without a separate opt-in")
        runtime.authorize(onlineEnabled: false, learningEnabled: false)
        runtime.authorize(onlineEnabled: true, learningEnabled: true)
        observe(runtime, edited: true)
        check(runtime.decision == .edited && runtime.candidateCount == 0, "actual tracker excludes edited piece")
        observe(runtime, input: sample(confidence: nil))
        check(runtime.decision == .unknownConfidence && !runtime.hasObservation, "unknown signal retains no sentence")
        for _ in 0..<3 { observe(runtime) }
        await runtime.waitForPendingWrites()
        check(saved.count == 1 && runtime.promotionCount == 1, "observed unchanged rounds promote")
        for (online, learning) in [(false, true), (false, false)] {
            runtime.authorize(onlineEnabled: true, learningEnabled: true)
            let late = runtime.enhancementReceiver()
            observe(runtime)
            runtime.authorize(onlineEnabled: online, learningEnabled: learning)
            check(runtime.candidateCount == 0 && !runtime.hasObservation, "close clears candidate/observation")
            runtime.authorize(onlineEnabled: true, learningEnabled: true)
            late?(sample())
            check(!runtime.hasObservation, "late callback stays cancelled after reopening")
        }
        var fakeNow = instant
        let expiry = EnhancementLearningRuntime(terms: { [] }, now: { fakeNow }, persist: { _, _, _ in false })
        expiry.authorize(onlineEnabled: true, learningEnabled: true)
        expiry.enhancementReceiver()?(sample())
        let baseline = receipt(reference)
        expiry.dictationKept(.init(rawText: reference, text: reference, hits: [], routeID: "synthetic"), baseline: baseline)
        fakeNow = instant.addingTimeInterval(301)
        expiry.sessionBegan(revisit: .init(baselineID: baseline.id, document: reference, editingGeneration: 0))
        check(expiry.decision == .expired && expiry.candidateCount == 0, "observation expiry injected clock")
        // Writer suspended after evaluation: closing either switch still fences its eventual store commit.
        var resume: CheckedContinuation<Void, Never>?, entered = false, commits = 0
        let lateWriter = EnhancementLearningRuntime(terms: { [] }, now: { instant }, persist: { _, permit, epoch in
            entered = true
            await withCheckedContinuation { resume = $0 }
            return permit.withAuthorization(epoch) { commits += 1; return true } ?? false
        })
        lateWriter.authorize(onlineEnabled: true, learningEnabled: true)
        for _ in 0..<3 { observe(lateWriter) }
        for _ in 0..<100 where !entered { await Task.yield() }
        check(entered, "queued writer reached deterministic barrier")
        lateWriter.authorize(onlineEnabled: false, learningEnabled: true)
        resume?.resume(); await Task.yield()
        check(commits == 0, "withdrawal fences late persistence")
        runtime.authorize(onlineEnabled: false, learningEnabled: false)
        expiry.authorize(onlineEnabled: false, learningEnabled: false)
        check(logs.allSatisfy(P.isSafeLog), "runtime logger only whitelist")
        return failures
    }

    static func hybridChecks() async -> [String] {
        var failures: [String] = []
        var counts: [[Int]] = []
        let cases: [(Bool, Double?)] = [(false, nil), (true, nil), (true, 0.99), (true, 0.89)]
        for (enabled, confidence) in cases {
            var received = 0, permissionCount = 0
            let runtime = EnhancementLearningRuntime(terms: { [] }, now: { instant }, persist: { _, _, _ in false })
            runtime.authorize(onlineEnabled: enabled, learningEnabled: false)
            let receiver = runtime.enhancementReceiver()
            let source = HybridTestingSource(), localBranch = HybridTestingBranch(role: .local)
            let cloud = HybridTestingBranch(role: .cloud), clock = HybridManualClock()
            localBranch.finishStyle = .final(local); localBranch.modelConfidence = confidence
            cloud.finishStyle = .final(reference)
            let learningCallback: (@MainActor @Sendable (EnhancementComparison) -> Void)?
            if let receiver {
                learningCallback = { input in received += 1; receiver(input) }
            } else { learningCallback = nil }
            let session = HybridTestingFactory.make(clock: clock.clock, source: source, local: localBranch, cloud: cloud,
                permission: { permissionCount += 1; return true },
                learningReceiver: learningCallback)
            do {
                let selection = try VoiceInputSelection(mode: .voiceNative, routeID: "qwen17-rolling", language: "zh")
                let snapshot = try VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 0)
                try await session.backend.start(snapshot: snapshot) { _ in }
                for _ in 0..<100 where session.cloudMakes == 0 { await Task.yield() }
                cloud.emitReady()
                // Silence generated in memory; both existing capture views consume the identical buffer.
                _ = source.appendAudio(milliseconds: 20)
                await session.backend.finish()
                counts.append([source.startCount, session.sourceMakes, localBranch.startCount, cloud.startCount,
                               permissionCount, localBranch.finishCount, cloud.finishCount])
                if received != (enabled ? 1 : 0) { failures.append("enhancement hybrid: paired callback count") }
                if enabled {
                    let expected: P.Decision = confidence == nil ? .unknownConfidence : (confidence! < 0.9 ? .lowConfidence : .unobserved)
                    let observable = confidence != nil && confidence! >= 0.9
                    if runtime.decision != expected || runtime.candidateCount != 0 || runtime.hasObservation != observable {
                        failures.append("enhancement hybrid: model score guard on actual paired callback")
                    }
                }
                if localBranch.finishSnapshotIdentities != cloud.finishSnapshotIdentities {
                    failures.append("enhancement hybrid: branches must reuse same capture buffers")
                }
                await session.backend.cancel()
            } catch { failures.append("enhancement hybrid: synthetic session could not run") }
            runtime.authorize(onlineEnabled: false, learningEnabled: false)
        }
        if counts.count != cases.count || !counts.allSatisfy({ $0 == [1, 1, 1, 1, 1, 1, 1] }) {
            failures.append("enhancement hybrid: learning must not add capture/branch/request/permission calls")
        }
        print("event=enhancement_hybrid_probe capture=1 local_requests=1 cloud_requests=1 additional_requests=0 cases=\(counts.count)")
        return failures
    }

    static func localBackendChecks() async -> [String] {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600),
              let samples = buffer.floatChannelData?[0] else { return ["enhancement confidence: synthetic PCM allocation"] }
        buffer.frameLength = 1600
        for index in 0..<1600 { samples[index] = Float(sin(Double(index) * 0.1) * 0.25) }
        let evidence = LocalModelConfidence(probability: 0.97,
            source: LocalModelConfidence.Source.qwenSelectedTokenMinimum.rawValue, tokenCount: 7)!
        do {
            let result = try await MicrophoneCaptureTesting.run(buffers: [buffer], shared: true, confidence: evidence)
            guard result.finals == 1, result.failureCode == nil, result.inferenceCalls > 0,
                  result.confidence == evidence else { return ["enhancement confidence: real local event chain lost evidence"] }
            print("event=enhancement_local_confidence final=1 score_preserved=1 synthetic=1")
            return []
        } catch { return ["enhancement confidence: synthetic local event chain failed"] }
    }

    static func persistenceChecks() async -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) { if !ok { failures.append("enhancement persistence: " + label) } }
        do {
            let preferences = try ProviderPreferences()
            check(preferences.enhanceLearning, "local teacher fresh default true")
            let old = try JSONDecoder().decode(ProviderPreferences.self, from: Data("{}".utf8))
            check(old.enhanceLearning, "local teacher legacy defaults migrate true once")
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".cache/maintenance04-build/enhancement-checks-" + UUID().uuidString)
            let settings = try ProviderSettingsStore(fileURL: root.appendingPathComponent("provider-settings.json"))
            var initialOff = settings.value; initialOff.enhanceLearning = false
            try settings.update(initialOff)
            var notifications = 0
            settings.onChange = { _ in notifications += 1 }
            try settings.update(settings.value)
            check(notifications == 0, "unchanged settings never notify")
            var enabled = settings.value; enabled.enhanceLearning = true
            try settings.update(enabled); try settings.update(enabled)
            check(notifications == 1, "real user toggle notifies once")
            let restarted = try ProviderSettingsStore(fileURL: settings.fileURL)
            check(restarted.value.enhanceLearning, "restart preserves explicit true")
            var off = enabled; off.enhanceLearning = false
            try settings.update(off)
            check(!(try ProviderSettingsStore(fileURL: settings.fileURL)).value.enhanceLearning, "restart preserves false")
            let store = LexiconStore(directory: root.appendingPathComponent("lexicon"))
            _ = try await store.load()
            var pool = P.CandidatePool(); var promotions: [P.Promotion] = []
            let c = EnhancementLearningConfiguration()
            let evaluation = P.evaluate(sample(), userEdited: false, configuration: c, terms: [])
            for _ in 0..<3 { promotions = pool.ingest(evaluation, roundID: UUID(), now: instant, configuration: c, terms: []).1 }
            guard let promotion = promotions.first else { failures.append("enhancement persistence: no qualified promotion"); return failures }
            let permit = EnhancementLearningPermit(), epoch = permit.update(enabled: true)
            let added = try await store.addAutomaticallyLearned(promotion, permit: permit, epoch: epoch)
            check(added?.term.source == .automaticallyLearned && added?.term.learningSightings == 3, "auto source/count preserved")
            check(try await store.addAutomaticallyLearned(promotion, permit: permit, epoch: epoch) == nil, "confirmed/existing cannot be overwritten")
            _ = permit.update(enabled: false)
            check(!permit.allows(epoch), "closed store permit")
            let data = try JSONEncoder().encode(added?.term)
            let text = String(decoding: data, as: UTF8.self)
            check(!text.contains(local) && !text.contains(reference), "only difference pair, never sentence persisted")
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let allowed = Set(["id", "canonical", "variants", "enabled", "source", "createdAt", "hits", "lastHitAt", "learningSightings"])
            check(Set(object?.keys.map { $0 } ?? []).isSubset(of: allowed), "persistent field whitelist")
            let livePermit = EnhancementLearningPermit(), liveEpoch = livePermit.update(enabled: true)
            let daily = LexiconStore(directory: root.appendingPathComponent("unlimited"))
            _ = try await daily.load()
            let today = Date()
            for index in 0..<201 {
                _ = try await daily.add(canonical: "CloudTerm\(index)", variants: ["CloudWrong\(index)"],
                    source: .automaticallyLearned, now: today)
            }
            check(try await daily.addAutomaticallyLearned(promotion, permit: livePermit, epoch: liveEpoch, now: today) != nil,
                  "prior daily and total limits do not stop qualified learning")
        } catch { failures.append("enhancement persistence: synthetic store check failed") }
        return failures
    }
}
