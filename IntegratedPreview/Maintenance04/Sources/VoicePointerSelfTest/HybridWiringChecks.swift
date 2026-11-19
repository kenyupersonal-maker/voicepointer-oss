import Foundation
@_spi(Testing) import VoicePointerCore

/// How "用于增强本地识别" is wired into the settings and the coordinator (T13, sub-task D):
/// - the one reconciliation of the cloud switches, over every combination of switches and circumstances, in
///   memory and in a temporary UserDefaults suite;
/// - every decision the coordinator takes about the enhancement (`HybridSessionPolicy`): freezing, withdrawal,
///   asking the gate, the start line, the guard on a cloud final, and that no line it writes can carry text or
///   look like a cloud route started without a permit;
/// - the constants the settings, the gate and the hybrid backend must agree on;
/// - the coordinator itself up to its backend start (`coordinatorChecks`, in HybridWiringCoordinatorChecks).
/// Offline: no key, network, microphone or worker; nothing outside temporary files and a temporary suite.
@MainActor
enum HybridWiringChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        failures += reconcileChecks()
        failures += persistedReconcileChecks()
        failures += contextChecks()
        failures += sessionPolicyChecks()
        failures += finalGuardChecks()
        failures += traceSafetyChecks()
        failures += constantChecks()
        failures += await coordinatorChecks()
        return failures
    }

    // MARK: - Fixtures

    private static let routeIDs = [
        "qwen17-rolling", "qwen06-rolling", "qwen06-incremental", "aliyun", "apple-speech", "sensevoice",
        "groq-v3", "QWEN17-ROLLING", "qwen17-rolling ",
    ]
    private static let languages = ["zh", "en", "auto", "yue", "ja", "ZH"]

    /// Every selection of the grid (both modes, the routes and the languages above).
    private static func selections() -> [VoiceInputSelection] {
        var result: [VoiceInputSelection] = []
        for mode in [VoiceInputMode.doubao, .voiceNative] {
            for routeID in routeIDs {
                for language in languages {
                    if let selection = try? VoiceInputSelection(mode: mode, routeID: routeID, language: language) {
                        result.append(selection)
                    }
                }
            }
        }
        return result
    }

    private static func label(_ selection: VoiceInputSelection) -> String {
        "\(selection.mode.rawValue)/\(selection.routeID)/\(selection.language)"
    }

    /// All 2^count combinations, bit i of the index as element i.
    private static func combinations(_ count: Int) -> [[Bool]] {
        (0..<(1 << count)).map { mask in (0..<count).map { mask & (1 << $0) != 0 } }
    }

    private static func bits(_ values: [Bool]) -> String {
        values.map { $0 ? "1" : "0" }.joined()
    }

    private static func preferences(_ bits: [Bool]) -> CloudEntryPreferences {
        CloudEntryPreferences(visible: bits[0], routeEnabled: bits[1], uploadConsent: bits[2], enhanceLocal: bits[3])
    }

    private static func context(_ bits: [Bool]) -> CloudEntryReconcileContext {
        CloudEntryReconcileContext(
            selectionIsCloudRoute: bits[0], selectionCanBeEnhanced: bits[1],
            credentialAvailable: bits[2], entryVisible: bits[3]
        )
    }

    // MARK: - Reconciliation (in memory)

    /// Every one of the 2^8 combinations of the four switches and the four facts of the context.
    static func reconcileChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            if !condition { failures.append("hybrid wiring: reconcile " + label()) }
        }
        var count = 0
        for p in combinations(4) {
            let before = preferences(p)
            for c in combinations(4) {
                count += 1
                let ctx = context(c)
                let after = before.reconciled(ctx)
                let name = "prefs(visible,route,upload,enhance)=\(bits(p)) context(cloud,enhanceable,key,visible)=\(bits(c))"
                expect(after.reconciled(ctx) == after, "\(name): not idempotent")
                expect(after.visible == before.visible, "\(name): the kill switch changed")
                expect(!after.routeEnabled || before.routeEnabled, "\(name): opened the route switch")
                expect(!after.enhanceLocal || before.enhanceLocal, "\(name): opened the enhancement")
                expect(!after.uploadConsent || before.uploadConsent, "\(name): opened the upload permission")
                expect(!after.uploadConsent || after.routeEnabled || after.enhanceLocal,
                       "\(name): the upload permission survived with both uses off")
                expect(!after.routeEnabled || ctx.selectionIsCloudRoute,
                       "\(name): the route switch stayed on next to another route")
                expect(!after.enhanceLocal || (ctx.credentialAvailable && ctx.entryVisible),
                       "\(name): the enhancement stayed on without a key and the entry")
                // The whole table, written from the rules rather than read back from the code.
                let route = before.routeEnabled && c[0]
                let enhance = before.enhanceLocal && c[2] && c[3]
                let expected = CloudEntryPreferences(
                    visible: before.visible, routeEnabled: route,
                    uploadConsent: before.uploadConsent && (route || enhance), enhanceLocal: enhance
                )
                expect(after == expected, "\(name): got \(after), expected \(expected)")
                // A retained enhancement consent is filtered by the frozen session's route policy.
                let consent = after.legacyConsent(merging: [])
                expect(!(!c[0] && consent.contains(CloudEntry.provider)),
                       "\(name): the consent set carries the route next to another route")
                expect(consent.isEmpty || (after.visible && after.uploadConsent),
                       "\(name): the consent set grants a use without the upload permission")
            }
        }
        expect(count == 256, "covered \(count) combinations, expected 256")

        // The two states the settings produce on purpose are left alone, so reconciling right after switching
        // something on never undoes it.
        let onCloud = CloudEntryPreferences(visible: true, routeEnabled: true, uploadConsent: true)
        let cloudContext = CloudEntryReconcileContext(
            selectionIsCloudRoute: true, selectionCanBeEnhanced: false, credentialAvailable: true, entryVisible: true)
        expect(onCloud.reconciled(cloudContext) == onCloud, "the Aliyun route switched on must stay on")
        let enhanced = CloudEntryPreferences(visible: true, uploadConsent: true, enhanceLocal: true)
        let localContext = CloudEntryReconcileContext(
            selectionIsCloudRoute: false, selectionCanBeEnhanced: true, credentialAvailable: true, entryVisible: true)
        expect(enhanced.reconciled(localContext) == enhanced, "an enhanced local route must stay enhanced")
        // Leaving the Aliyun route for an enhanceable local route: the route switch goes, the upload permission
        // goes with it unless the enhancement still uses it.
        let both = CloudEntryPreferences(visible: true, routeEnabled: true, uploadConsent: true, enhanceLocal: true)
        expect(both.reconciled(localContext) == enhanced, "leaving the route keeps an enhancement that still applies")
        expect(onCloud.reconciled(localContext) == CloudEntryPreferences(visible: true),
               "leaving the route without the enhancement takes the upload permission along")
        for selection in [try! VoiceInputSelection(mode: .doubao),
                          try! VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.routeID, language: "zh"),
                          try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "ja")] {
            let after = enhanced.reconciled(.init(selection: selection, credentialAvailable: true, entryVisible: true))
            expect(after.enhanceLocal && after.uploadConsent, "switching method/language preserves the user's choice")
            if HybridSessionPolicy.freezesEnhancement(consent: after.legacyConsent(merging: []), selection: selection) {
                if case .skip = HybridSessionPolicy.admissionPlan(for: selection, cloudDrainOutstanding: 0) {} else {
                    expect(false, "retained preference must skip an ineligible frozen session")
                }
            }
        }
        for (key, visible) in [(false, true), (true, false)] {
            let after = enhanced.reconciled(.init(selectionIsCloudRoute: false, selectionCanBeEnhanced: true,
                credentialAvailable: key, entryVisible: visible))
            expect(!after.enhanceLocal && !after.uploadConsent, "deleting key or hiding entry still closes enhancement")
        }
        return failures
    }

    // MARK: - Reconciliation (persisted)

    /// The same through `reconcile(_:in:)` on a temporary suite: each switch key absent, false or true; the kill
    /// switch absent or off; every context. Only keys that close are written, and only with false.
    static func persistedReconcileChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            if !condition { failures.append("hybrid wiring: persisted reconcile " + label()) }
        }
        let suiteName = "vp.selftest.hybridwiring.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return ["hybrid wiring: temporary UserDefaults suite unavailable"]
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let switchKeys = [
            CloudEntryPreferences.routeEnabledKey, CloudEntryPreferences.uploadConsentKey,
            CloudEntryPreferences.enhanceLocalKey,
        ]
        let untouchedKeys = [
            CloudEntryPreferences.visibleKey, CloudEntryPreferences.previousModeKey,
            CloudEntryPreferences.previousRouteIDKey,
        ]
        /// The kill switch (present, value) and the remembered selection, which reconciling never writes.
        func untouched() -> String {
            let visible = defaults.object(forKey: CloudEntryPreferences.visibleKey) == nil
                ? "absent" : "\(defaults.bool(forKey: CloudEntryPreferences.visibleKey))"
            return "visible=\(visible) previous=\(defaults.string(forKey: CloudEntryPreferences.previousModeKey) ?? "nil")/"
                + (defaults.string(forKey: CloudEntryPreferences.previousRouteIDKey) ?? "nil")
        }
        // nil: absent.
        let states: [Bool?] = [nil, false, true]
        var count = 0
        for route in states {
            for upload in states {
                for enhance in states {
                    for visibleOff in [false, true] {
                        for c in combinations(4) {
                            count += 1
                            for key in switchKeys + untouchedKeys { defaults.removeObject(forKey: key) }
                            for (key, value) in zip(switchKeys, [route, upload, enhance]) {
                                if let value { defaults.set(value, forKey: key) }
                            }
                            if visibleOff { defaults.set(false, forKey: CloudEntryPreferences.visibleKey) }
                            defaults.set(VoiceInputMode.doubao.rawValue, forKey: CloudEntryPreferences.previousModeKey)
                            defaults.set("qwen06-rolling", forKey: CloudEntryPreferences.previousRouteIDKey)
                            let untouchedBefore = untouched()
                            let presentBefore = switchKeys.map { defaults.object(forKey: $0) != nil }

                            let ctx = context(c)
                            let loaded = CloudEntryPreferences.load(from: defaults)
                            let wrote = CloudEntryPreferences.reconcile(ctx, in: defaults)
                            let after = CloudEntryPreferences.load(from: defaults)
                            let name = "stored(route,upload,enhance)=\([route, upload, enhance]) visibleOff=\(visibleOff) context=\(bits(c))"
                            expect(after == loaded.reconciled(ctx), "\(name): stored \(after), expected \(loaded.reconciled(ctx))")
                            expect(wrote == (loaded.reconciled(ctx) != loaded), "\(name): reported \(wrote)")
                            for (index, key) in switchKeys.enumerated() where !presentBefore[index] {
                                expect(defaults.object(forKey: key) == nil, "\(name): wrote the absent key \(key)")
                            }
                            expect(untouched() == untouchedBefore,
                                   "\(name): touched the kill switch or the previous selection (\(untouched()))")
                            expect(!CloudEntryPreferences.reconcile(ctx, in: defaults), "\(name): a second reconcile wrote again")
                            expect(CloudEntryPreferences.load(from: defaults) == after, "\(name): a second reconcile changed the switches")
                        }
                    }
                }
            }
        }
        expect(count == 27 * 2 * 16, "covered \(count) combinations, expected \(27 * 2 * 16)")
        return failures
    }

    // MARK: - Context from a selection

    static func contextChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            if !condition { failures.append("hybrid wiring: context " + label()) }
        }
        for selection in selections() {
            let name = label(selection)
            let resolvable = HybridSpeechRoute.resolve(
                isVoiceNative: selection.mode == .voiceNative, localRouteID: selection.routeID,
                language: selection.language
            ) != nil
            expect(CloudEntry.canEnhance(selection) == resolvable, "\(name): canEnhance disagrees with the hybrid route")
            for facts in combinations(2) {
                let ctx = CloudEntryReconcileContext(selection: selection, credentialAvailable: facts[0], entryVisible: facts[1])
                expect(ctx.selectionIsCloudRoute == (selection.mode == .voiceNative && selection.routeID == CloudEntry.routeID),
                       "\(name): the Aliyun route is voiceNative with its route id, and nothing else")
                expect(ctx.selectionCanBeEnhanced == resolvable, "\(name): enhanceable exactly when the hybrid route resolves")
                expect(ctx.credentialAvailable == facts[0] && ctx.entryVisible == facts[1], "\(name): the facts pass through")
            }
        }
        func can(_ mode: VoiceInputMode, _ routeID: String, _ language: String) -> Bool {
            (try? VoiceInputSelection(mode: mode, routeID: routeID, language: language)).map { CloudEntry.canEnhance($0) } ?? false
        }
        expect(can(.voiceNative, "qwen17-rolling", "zh") && can(.voiceNative, "qwen06-rolling", "auto"),
               "the bundled Qwen routes in zh/en/auto can be enhanced")
        expect(!can(.voiceNative, "aliyun", "zh"), "the Aliyun route is never enhanced")
        expect(!can(.doubao, "qwen17-rolling", "zh"), "Doubao is never enhanced, whatever route id it keeps")
        expect(!can(.voiceNative, "apple-speech", "zh") && !can(.voiceNative, "qwen17-rolling", "yue"),
               "Apple speech and a language the cloud does not take are not enhanced")
        return failures
    }

    // MARK: - Coordinator decisions

    static func sessionPolicyChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            if !condition { failures.append("hybrid wiring: session " + label()) }
        }
        let enhanceID = CloudEntry.enhanceConsentID
        let consentSets: [Set<String>] = [
            [], [CloudEntry.provider], [enhanceID], [CloudEntry.provider, enhanceID], ["groq", enhanceID],
        ]

        // Frozen when the gesture begins: the enhancement's id and an eligible local Qwen route.
        for selection in selections() {
            for consent in consentSets {
                let expected = CloudEntry.canEnhance(selection) && consent.contains(enhanceID)
                expect(HybridSessionPolicy.freezesEnhancement(consent: consent, selection: selection) == expected,
                       "\(label(selection)) consent=\(consent.sorted()): freeze should be \(expected)")
            }
        }

        // Withdrawal: only for a dictation begun with the enhancement, only once, and only when the new set
        // lacks its id. A dictation without the enhancement never reacts to a consent change.
        for frozen in [false, true] {
            for already in [false, true] {
                for allowed in consentSets {
                    let expected = frozen && !already && !allowed.contains(enhanceID)
                    expect(
                        HybridSessionPolicy.withdrawsEnhancement(frozen: frozen, alreadyWithdrawn: already, allowed: allowed)
                            == expected,
                        "frozen=\(frozen) withdrawn=\(already) allowed=\(allowed.sorted()): withdrawal should be \(expected)"
                    )
                }
            }
        }

        // Asking the gate: exactly when the hybrid route resolves and no cloud branch is draining.
        for selection in selections() {
            let resolved = HybridSpeechRoute.resolve(
                isVoiceNative: selection.mode == .voiceNative, localRouteID: selection.routeID,
                language: selection.language
            )
            for outstanding in [0, 1, 3] {
                let plan = HybridSessionPolicy.admissionPlan(for: selection, cloudDrainOutstanding: outstanding)
                let name = "\(label(selection)) outstanding=\(outstanding)"
                if let resolved {
                    let expected: HybridSessionPolicy.AdmissionPlan = outstanding == 0 ? .ask(resolved) : .skip(.previousCloudDraining)
                    expect(plan == expected, "\(name): got \(plan), expected \(expected)")
                } else {
                    let knownRoute = selection.mode == .voiceNative && HybridSpeechRoute.localRouteIDs.contains(selection.routeID)
                    let expected: HybridSessionPolicy.AdmissionPlan = .skip(knownRoute ? .languageUnsupported : .routeIneligible)
                    expect(plan == expected, "\(name): got \(plan), expected \(expected)")
                }
            }
        }
        func plan(_ routeID: String, _ language: String, outstanding: Int = 0) -> HybridSessionPolicy.AdmissionPlan? {
            (try? VoiceInputSelection(mode: .voiceNative, routeID: routeID, language: language)).map {
                HybridSessionPolicy.admissionPlan(for: $0, cloudDrainOutstanding: outstanding)
            }
        }
        if case .ask(let route)? = plan("qwen06-rolling", "en") {
            expect(route.localRouteID == "qwen06-rolling" && route.language == "en", "the asked route is the selection's")
        } else {
            expect(false, "qwen06-rolling/en must ask the gate")
        }
        expect(plan("qwen17-rolling", "yue") == .skip(.languageUnsupported), "a Qwen route in yue is a language skip")
        expect(plan("apple-speech", "zh") == .skip(.routeIneligible), "Apple speech is a route skip")
        expect(plan("sensevoice", "zh") == .skip(.routeIneligible), "another local model is a route skip")
        expect(plan("qwen17-rolling", "zh", outstanding: 1) == .skip(.previousCloudDraining),
               "a draining cloud branch keeps the next dictation local")
        expect(plan("apple-speech", "zh", outstanding: 1) == .skip(.routeIneligible),
               "an ineligible route is reported as such even while a branch drains")

        // The lines, exactly (field names are fixed for the scripts that read them).
        expect(HybridSessionPolicy.admittedTrace(epoch: 7) == "hybrid admission admitted epoch=7", "admitted line")
        expect(HybridSessionPolicy.deniedTrace(reason: "cloudRouteDisabled")
                   == "hybrid admission denied reason=cloudRouteDisabled fallback=localOnly", "denied line")
        expect(HybridSessionPolicy.deniedTrace(reason: "paused.freeQuotaExhausted")
                   == "hybrid admission denied reason=paused.freeQuotaExhausted fallback=localOnly", "denied line with a pause")
        for hostile in ["route=aliyun", "", "has space", "用户的话", String(repeating: "a", count: 65), "a\nb"] {
            expect(HybridSessionPolicy.deniedTrace(reason: hostile) == "hybrid admission denied reason=unknown fallback=localOnly",
                   "a reason that is not a plain label (\(hostile.debugDescription)) is written as unknown")
        }
        expect(HybridSessionPolicy.SkipReason.allCases.map(\.rawValue)
                   == ["routeIneligible", "languageUnsupported", "previousCloudDraining", "constructFailed", "consentWithdrawn"],
               "the skip reasons are the fixed vocabulary")
        for reason in HybridSessionPolicy.SkipReason.allCases {
            expect(HybridSessionPolicy.skippedTrace(reason) == "hybrid skipped reason=\(reason.rawValue)", "skip line \(reason)")
        }
        expect(HybridSessionPolicy.backendStartSuffix(enhancementFrozen: false, hybridBackend: false) == "",
               "without the enhancement the start line gets nothing")
        expect(HybridSessionPolicy.backendStartSuffix(enhancementFrozen: false, hybridBackend: true) == "",
               "without the enhancement the start line gets nothing, whatever the backend")
        expect(HybridSessionPolicy.backendStartSuffix(enhancementFrozen: true, hybridBackend: false) == " hybrid=off",
               "an enhanced dictation on the plain local backend says hybrid=off")
        expect(HybridSessionPolicy.backendStartSuffix(enhancementFrozen: true, hybridBackend: true) == " hybrid=aliyun",
               "an enhanced dictation on the hybrid backend says hybrid=aliyun")
        return failures
    }

    // MARK: - The guard on a cloud final

    private static let guardLexicon = LexiconSnapshot(revision: 3, terms: [
        LexiconTerm(canonical: "Claude Code", variants: ["cloud code"]),
        LexiconTerm(canonical: "第四版", variants: ["第3版"]),
        LexiconTerm(canonical: "对齐了", variants: ["没对齐"]),
        LexiconTerm(canonical: "main swift", variants: ["main.swift"]),
    ])

    private static func final(_ text: String?, _ source: SpeechTranscriptSource?) -> SpeechInputEvent {
        SpeechInputEvent(
            sessionID: UUID(uuidString: "6F9D3C1E-5B7A-4C2D-9E8F-0A1B2C3D4E5F")!, sequence: 4,
            observedMilliseconds: 1_200, kind: .final, text: text, transcriptSource: source
        )
    }

    /// The final text path as the coordinator runs it: the real lexicon corrector, then the policy.
    private static func guarded(_ event: SpeechInputEvent) -> (corrected: SpeechInputEvent, hits: Int, result: HybridSessionPolicy.GuardedFinal) {
        let corrected = DictationCorrector(lexicon: guardLexicon).correct(event, mode: .voiceNative)
        return (corrected.event, corrected.hits.count, HybridSessionPolicy.guardedFinal(event, corrected: corrected))
    }

    static func finalGuardChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            if !condition { failures.append("hybrid wiring: final guard " + label()) }
        }

        // A spelling fix on a cloud final passes, with its hits, and the event keeps its source.
        let fix = final("打开 cloud code 看看", .cloudEnhancement)
        let fixed = guarded(fix)
        expect(fixed.corrected.text == "打开 Claude Code 看看" && fixed.hits == 1, "fixture: the lexicon must fix the spelling")
        expect(fixed.result.event == fixed.corrected && fixed.result.hits.count == 1,
               "a spelling fix on a cloud final is kept with its hit")
        expect(fixed.result.trace == "hybrid projection guard result=accepted hits=1", "accepted line: \(fixed.result.trace ?? "nil")")
        expect(fixed.result.event.transcriptSource == .cloudEnhancement,
               "the corrected cloud final keeps its source (DictationRecord.replacingText must carry it, CONTRACT §2.2)")

        // A projection that touches a number, a negation or code falls back to the cloud's own raw text, with no
        // hits: the event as it came, not the local draft and not the projection.
        let refused: [(String, String, String)] = [
            ("改成第3版", "digits", "第四版"), ("还是没对齐", "negation", "对齐了"), ("打开 main.swift 看看", "code", "main swift"),
            ("打开 cloud code 改成第3版", "digits", "第四版"),
        ]
        for (raw, reason, canonical) in refused {
            let event = final(raw, .cloudEnhancement)
            let run = guarded(event)
            expect(run.corrected.text?.contains(canonical) == true && run.hits > 0, "fixture: the lexicon must rewrite \(raw)")
            expect(run.result.event == event, "\(reason): a refused projection must keep the cloud raw event, got \(run.result.event.text ?? "nil")")
            expect(run.result.event.text == raw, "\(reason): the kept text must be the cloud raw text")
            expect(run.result.hits.isEmpty, "\(reason): a refused projection keeps no hits")
            expect(run.result.trace == "hybrid projection guard result=rawFallback reason=\(reason) hits=0",
                   "\(reason) line: \(run.result.trace ?? "nil")")
        }

        // A cloud final the lexicon leaves alone: nothing to check, nothing written.
        let plain = final("今天天气不错", .cloudEnhancement)
        let untouched = guarded(plain)
        expect(untouched.result.event == plain && untouched.result.hits.isEmpty && untouched.result.trace == nil,
               "an unchanged cloud final is kept as it is, without a line")
        let empty = final(nil, .cloudEnhancement)
        expect(guarded(empty).result.event == empty && guarded(empty).result.trace == nil, "a final without text is left alone")

        // A local final (and one from an adapter that sets no source) keeps exactly the corrector's result, even
        // where the guard would refuse it: the local path is unchanged by this mode.
        for source in [SpeechTranscriptSource.local, nil] {
            let event = final("改成第3版", source)
            let run = guarded(event)
            expect(run.result.event == run.corrected && run.result.event.text == "改成第四版" && run.result.hits.count == 1,
                   "source \(String(describing: source)): a local final keeps the corrector's text and hits")
            expect(run.result.trace == nil, "source \(String(describing: source)): a local final writes no guard line")
        }
        return failures
    }

    // MARK: - Trace safety

    /// Every line the wiring can write: only fixed words, counts and finite labels; never the dictation's text;
    /// never a substring the coordinator checks read as a cloud route started without a permit.
    static func traceSafetyChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            if !condition { failures.append("hybrid wiring: trace " + label()) }
        }
        var lines: [String] = []
        for epoch: UInt64 in [0, 1, UInt64.max] { lines.append(HybridSessionPolicy.admittedTrace(epoch: epoch)) }
        let gateLabels = [
            "notConfigured", "storageUnavailable", "cloudRouteDisabled", "credentialUnavailable", "sampleUploadNotAllowed",
            "sessionUploadNotAllowed", "policyDisabled", "freeOnlyRequired", "userConfirmationRequired", "guardEvidenceExpired",
            "providerVerificationUnavailable", "paused.freeQuotaExhausted", "paused.accountBalanceBlocked",
            "route=aliyun", "cloud admission admitted", "打开 cloud code 看看",
        ]
        for reason in gateLabels { lines.append(HybridSessionPolicy.deniedTrace(reason: reason)) }
        for reason in HybridSessionPolicy.SkipReason.allCases { lines.append(HybridSessionPolicy.skippedTrace(reason)) }
        let texts = ["打开 cloud code 看看", "改成第3版", "还是没对齐", "打开 main.swift 看看", "今天天气不错"]
        for text in texts {
            for source in [SpeechTranscriptSource.cloudEnhancement, .local, nil] {
                if let line = guarded(final(text, source)).result.trace { lines.append(line) }
            }
        }
        expect(lines.count == 3 + gateLabels.count + HybridSessionPolicy.SkipReason.allCases.count + 4,
               "expected every admitted, denied, skipped and guard line, got \(lines.count)")
        var suffixes: [String] = []
        for frozen in [false, true] {
            for hybrid in [false, true] {
                suffixes.append(HybridSessionPolicy.backendStartSuffix(enhancementFrozen: frozen, hybridBackend: hybrid))
            }
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789=. ".unicodeScalars)
        for line in lines + suffixes {
            expect(!line.contains("route=aliyun"), "\(line.debugDescription) contains route=aliyun")
            expect(!line.contains("cloud admission admitted"), "\(line.debugDescription) contains cloud admission admitted")
            expect(line.unicodeScalars.allSatisfy(allowed.contains), "\(line.debugDescription) has a character outside the fixed vocabulary")
            expect(!texts.contains { line.contains($0) } && !line.contains("cloud code") && !line.contains("main.swift"),
                   "\(line.debugDescription) carries dictated text")
        }
        for line in lines {
            expect(line.hasPrefix("hybrid "), "\(line.debugDescription) does not start with the hybrid prefix")
        }
        for suffix in suffixes where !suffix.isEmpty {
            expect(suffix.hasPrefix(" hybrid="), "\(suffix.debugDescription) is not a trailing hybrid field")
        }
        return failures
    }

    // MARK: - Constants shared by the settings, the gate and the hybrid backend

    static func constantChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            if !condition { failures.append("hybrid wiring: constants " + label()) }
        }
        expect(HybridSpeechRoute.cloudRouteID == CloudEntry.routeID, "the hybrid cloud branch is the settings' Aliyun route")
        expect(HybridSpeechRoute.cloudLanguages == Set(CloudEntry.supportedLanguages),
               "the enhancement takes exactly the languages the Aliyun route takes")
        expect(HybridSpeechRoute.localRouteIDs.contains(CloudEntry.localFallbackRouteID),
               "the local route a denied Aliyun dictation falls back to can be enhanced")
        expect(HybridFinalSelector.incompleteCode == "HYBRID_FINAL_INCOMPLETE", "the incomplete code is the fixed one")
        expect(VoiceIssuePresentationPolicy.forBackendCode(HybridFinalSelector.incompleteCode).code == .recognitionIncomplete,
               "the selector's incomplete code is allow-listed and has its own words")

        // The enhancement's consent id: distinct from the route's, namespaced under the provider (so it can never
        // read as another provider), never saved in the provider settings, and independent in the legacy set.
        let enhanceID = CloudEntry.enhanceConsentID
        expect(enhanceID == "aliyun-beijing.enhanceLocal", "the enhancement's consent id is the fixed one")
        expect(enhanceID != CloudEntry.provider && !CloudEntry.provider.hasPrefix(enhanceID),
               "the route's id is not the enhancement's id, nor a longer form of it")
        expect(enhanceID.hasPrefix(CloudEntry.provider + "."), "the enhancement's id is namespaced under the provider")
        expect(!ProviderPreferences.allowedConsentIDs.contains(enhanceID),
               "the provider settings never store the enhancement's id (it only lives in the merged set)")
        let both = CloudEntryPreferences(visible: true, routeEnabled: true, uploadConsent: true, enhanceLocal: true)
        var routeOnly = both
        routeOnly.enhanceLocal = false
        var enhanceOnly = both
        enhanceOnly.routeEnabled = false
        expect(both.legacyConsent(merging: ["groq"]) == ["groq", CloudEntry.provider, enhanceID], "both uses grant both ids")
        expect(routeOnly.legacyConsent(merging: ["groq"]) == ["groq", CloudEntry.provider],
               "switching the enhancement off takes only its id away")
        expect(enhanceOnly.legacyConsent(merging: ["groq"]) == ["groq", enhanceID],
               "switching the route off takes only its id away")
        return failures
    }
}
