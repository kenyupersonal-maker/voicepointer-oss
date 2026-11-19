import Combine
import Foundation
import AppKit
import VoicePointerCore

/// Learning from the person's own corrections. When a dictation was left in a field, this keeps track of where
/// in the field it sits (`EditSpanTracker`). The next gesture in the same field takes a look at the field for
/// free (the session start reads its text anyway); if the person changed the dictated words by hand in the
/// meantime, `CorrectionLearner` works out which "wrong spelling → right spelling" pairs that stands for, and
/// their small spelling corrections become lexicon entries automatically. Nothing here reads or writes
/// the field: the only Accessibility work is the executor's, already there.
///
/// Memory only. The receipt of a dictation (its text, the field's text) lives here for at most five minutes,
/// the pending pairs until the app quits or a week passes; the log gets counts and reasons, never text.
@MainActor
final class CorrectionLearningRuntime: ObservableObject, DictationEditObserving {
    static let shared = CorrectionLearningRuntime()

    /// Corrections seen and waiting for the person's decision, most recently seen first.
    @Published private(set) var pending: [CorrectionLedger.Entry] = []

    struct LearnedEntry: Identifiable {
        let id = UUID()
        let termID: UUID
        let variant: String
        let canonical: String
        let hotwordOnly: Bool
    }
    @Published private(set) var justLearned: [LearnedEntry] = []
    private var suppressed = Set<String>()
    private var learningGeneration: UInt64 = 0
    private let humanPermit = EnhancementLearningPermit()
    private var injectedLexicon: LexiconRuntime?
    private var lexicon: LexiconRuntime { injectedLexicon ?? .shared }
    /// The production spell checker runs on the main actor; probes inject a fixed dictionary.
    var isOrdinaryEnglishWord: @MainActor (String) -> Bool = { text in
        guard !text.isEmpty, text.allSatisfy({ $0.asciiValue != nil && $0.isLetter }) else { return false }
        return NSSpellChecker.shared.checkSpelling(of: text.lowercased(), startingAt: 0,
            language: "en_US", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// Whether the person turned learning on. The app sets it once the settings exist; until then, off.
    var isEnabled: @MainActor () -> Bool = { false }

    /// How long after a dictation the next gesture still counts as a look at it.
    static let observationLifetime: TimeInterval = 300

    private struct Observation {
        let record: DictationRecord
        let baselineID: UUID
        var tracker: EditSpanTracker
        let startedAt: Date
    }

    private var observation: Observation?
    private var expiry: Task<Void, Never>?
    private var ledger = CorrectionLedger()
    private var injectedEnhancement: EnhancementLearningRuntime?
    private var teacherOnline = false
    private lazy var teacher = TeacherLearningRuntime(
        terms: { [weak self] in self?.lexicon.terms ?? [] },
        confirmed: { [weak self] in
            (self?.pending.map { .init(variant: $0.variant, canonical: $0.canonical) } ?? [])
                + (self?.suppressed.compactMap { key -> EnhancementLearningPipeline.Difference? in
                    let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
                    return parts.count == 2 ? .init(variant: parts[0], canonical: parts[1]) : nil
                } ?? [])
        },
        ordinary: { [weak self] in self?.isOrdinaryEnglishWord($0) ?? false },
        trace: { RuntimeTrace.record($0) },
        persist: { [weak self] promotion, permit, epoch in
            guard let self else { return false }
            return await self.lexicon.addTeacherLearned(promotion, permit: permit, epoch: epoch)
                .map { added in
                    self.justLearned.insert(.init(termID: added.term.id, variant: promotion.difference.variant,
                        canonical: promotion.difference.canonical, hotwordOnly: promotion.hotwordOnly), at: 0)
                    self.justLearned = Array(self.justLearned.prefix(5))
                    return true
                } ?? false
        })
    private lazy var strict = StrictLearningRuntime(
        lexicon: lexicon,
        ordinaryEnglish: { [weak self] word in self?.isOrdinaryEnglishWord(word) ?? true }
    )

    // The existing correction observer remains the only field-reading path.
    private lazy var enhancement = injectedEnhancement ?? EnhancementLearningRuntime(
        terms: { LexiconRuntime.shared.terms },
        confirmed: { [weak self] in
            self?.pending.map { EnhancementLearningPipeline.Difference(variant: $0.variant, canonical: $0.canonical) } ?? []
        },
        trace: { RuntimeTrace.record($0) },
        persist: { promotion, permit, epoch in
            await LexiconRuntime.shared.addAutomaticallyLearned(promotion, permit: permit, epoch: epoch)
        }
    )

    func synchronizeEnhancement(preferences: ProviderPreferences, cloud supplied: CloudEntryPreferences? = nil) {
        // Production restores ONLY strict evidence-based teacher learning. The old
        // permissive candidate pool and hotword re-recognition stay closed.
        if injectedEnhancement == nil {
            let cloud = supplied ?? CloudEntryPreferences.load()
            let provider = preferences.onlineAPIConfiguration?.provider ?? .aliyunBailian
            let configReady = preferences.onlineAPIConfiguration.map {
                ($0.provider.isAliyun || preferences.cloudConsent.contains($0.consentID))
                    && (try? $0.validatedEndpoint()) != nil
            } ?? true
            teacherOnline = preferences.enhanceLearning && configReady
                && cloud.enhancementAuthorized(for: preferences.selection, provider: provider)
            strict.authorize(
                online: teacherOnline,
                doubao: preferences.enhanceLearning && preferences.selection.mode == .doubao
            )
            teacher.authorize(online: false, doubao: false)
            teacher.cancelWork()
            enhancement.authorize(onlineEnabled: false, learningEnabled: false, doubaoEnabled: false)
            return
        }
        let cloud = supplied ?? CloudEntryPreferences.load()
        let provider = preferences.onlineAPIConfiguration?.provider ?? .aliyunBailian
        let configurationAuthorized = preferences.onlineAPIConfiguration.map {
            ($0.provider.isAliyun || preferences.cloudConsent.contains($0.consentID)) && (try? $0.validatedEndpoint()) != nil
        } ?? true
        teacherOnline = configurationAuthorized && cloud.enhancementAuthorized(for: preferences.selection, provider: provider)
        teacher.authorize(online: teacherOnline, doubao: preferences.enhanceLearning && preferences.selection.mode == .doubao)
        enhancement.authorize(
            onlineEnabled: teacherOnline,
            learningEnabled: preferences.enhanceLearning,
            doubaoEnabled: preferences.selection.mode == .doubao
        )
    }
    var isOnlineEnhancementLearningAuthorized: Bool {
        injectedEnhancement == nil ? teacherOnline : enhancement.isOnlineAuthorized
    }
    func enhancementReceiver() -> (@MainActor @Sendable (EnhancementComparison) -> Void)? {
        if injectedEnhancement != nil { return enhancement.enhancementReceiver() }
        guard teacherOnline else { return nil }
        return { [weak self] input in self?.strict.receive(input) }
    }
    func teacherFinalObserved(text: String, roundID: UUID, source: EnhancementComparison.Source) {
        guard injectedEnhancement == nil else { return }
        strict.observeTeacherFinal(text, roundID: roundID, source: source)
    }
    func teacherFinalReceiver() -> (@MainActor @Sendable (UUID, String) -> Void)? {
        guard injectedEnhancement == nil, teacherOnline else { return nil }
        return { [weak self] roundID, text in
            self?.teacherFinalObserved(text: text, roundID: roundID, source: .onlineAPI)
        }
    }
    func undoAutomaticallyLearned(_ term: LexiconTerm) async -> Bool {
        await strict.undoAutomaticallyLearned(term)
    }

    func configureTeacherRecheck(recognize: @escaping TeacherLearningRuntime.Recognizer, cancel: @escaping @Sendable () async -> Void) {
        // No production recheck: a candidate supplied as a hotword cannot confirm itself.
        if injectedEnhancement != nil { teacher.configure(recognize: recognize, cancel: cancel) }
    }
    func cancelTeacherRecheck() { teacher.cancelWork() }
    func pauseTeacherRecheck() { teacher.pause() }
    func resumeTeacherRecheck() { teacher.resume() }
    func waitForTeacherCancellation() async { await teacher.waitForCancellation() }
    func teacherDictationDelivered(roundID: UUID) { teacher.delivered(roundID: roundID) }
    // T8: Passive reference and RAM-local result, independent of the online authorization path.
    func doubaoEnhancementCompared(_ comparison: EnhancementComparison, baseline: KeptDictationBaseline) {
        if injectedEnhancement == nil {
            strict.receive(comparison)
            return
        }
        enhancement.doubaoEnhancementReceiver()?(comparison)
        enhancement.dictationKept(DictationRecord(id: comparison.roundID, date: comparison.referenceAt,
            rawText: comparison.referenceText, text: comparison.referenceText, hits: [], routeID: "doubao"), baseline: baseline)
    }

    init(enhancement: EnhancementLearningRuntime? = nil, lexicon: LexiconRuntime? = nil) {
        injectedEnhancement = enhancement; injectedLexicon = lexicon
    }

    static func runAuthorizationProbe() -> Bool {
        var logs: [String] = []
        let pipe = EnhancementLearningRuntime(terms: { [] }, trace: { logs.append($0) }, persist: { _, _, _ in false })
        let runtime = CorrectionLearningRuntime(enhancement: pipe)
        var preferences = try! ProviderPreferences()
        preferences.selection = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "zh")
        preferences.cloudConsent = [CloudEntry.provider]
        preferences.enhanceLearning = false
        let enabled = CloudEntryPreferences(visible: true, uploadConsent: true, enhanceLocal: true)
        runtime.synchronizeEnhancement(preferences: preferences, cloud: enabled)
        var passed = runtime.isOnlineEnhancementLearningAuthorized && runtime.enhancementReceiver() != nil
        for cloud in [CloudEntryPreferences(visible: true, uploadConsent: true, enhanceLocal: false),
                      CloudEntryPreferences(visible: true, uploadConsent: false, enhanceLocal: true)] {
            runtime.synchronizeEnhancement(preferences: preferences, cloud: cloud)
            passed = passed && !runtime.isOnlineEnhancementLearningAuthorized && runtime.enhancementReceiver() == nil
        }
        preferences.selection = try! VoiceInputSelection(mode: .doubao)
        runtime.synchronizeEnhancement(preferences: preferences, cloud: enabled)
        passed = passed && runtime.enhancementReceiver() == nil && pipe.doubaoEnhancementReceiver() == nil
        preferences.enhanceLearning = true
        runtime.synchronizeEnhancement(preferences: preferences, cloud: enabled)
        passed = passed && pipe.doubaoEnhancementReceiver() != nil && runtime.enhancementReceiver() == nil
            && logs.allSatisfy(EnhancementLearningPipeline.isSafeLog)
        runtime.discardForDataRemoval()
        print("R57_ITEM4_AUTHORIZATION passed=\(passed ? 1 : 0) network=0 keys=0 audio=0")
        return passed
    }

    static func runAutomaticLearningProbe() async -> Bool {
        let store = LexiconStore(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cache/r57/Human-Learning-" + UUID().uuidString))
        let lexicon = LexiconRuntime(store: store)
        await lexicon.reload()
        let pipe = EnhancementLearningRuntime(terms: { [] }, persist: { _, _, _ in false })
        let runtime = CorrectionLearningRuntime(enhancement: pipe, lexicon: lexicon)
        final class LearningSwitch { var enabled = true }
        let learningSwitch = LearningSwitch()
        runtime.isEnabled = { learningSwitch.enabled }
        runtime.isOrdinaryEnglishWord = { ["coder", "code"].contains($0.lowercased()) }
        func learn(_ variant: String, _ canonical: String, _ confidence: CorrectionPlausibility.Confidence) async {
            var outcome = CorrectionLearner.Outcome(); outcome.kind = .evaluated
            outcome.candidates = [.init(variant: variant, canonical: canonical, confidence: confidence)]
            await runtime.apply(outcome, dictationID: UUID())
        }
        await learn("蓝呀", "蓝牙", .strong)
        await learn("Corder", "Qoder", .weak)
        var passed = lexicon.terms.count == 2 && runtime.pending.isEmpty && runtime.justLearned.count == 2
        if let entry = runtime.justLearned.first {
            await runtime.undo(entry)
            await learn("Corder", "Qoder", .weak)
            passed = passed && lexicon.terms.count == 1 && runtime.justLearned.count == 1
        } else { passed = false }
        _ = await lexicon.add(canonical: "Manual", variants: ["Mispell"], source: .manual)
        await learn("Mispell", "Another", .strong)
        passed = passed && lexicon.terms.count == 2
        _ = await lexicon.add(canonical: "CloudGuess", variants: ["CloudMis"], source: .automaticallyLearned)
        await learn("CloudMis", "HumanChoice", .weak)
        passed = passed && lexicon.terms.first(where: { $0.canonical == "HumanChoice" })?.source == .learned
            && lexicon.terms.first(where: { $0.canonical == "CloudGuess" })?.variants.isEmpty == true
        await learn("coder", "Qoder", .weak)
        passed = passed && lexicon.terms.first(where: { $0.canonical == "Qoder" })?.variants.isEmpty == true
            && lexicon.snapshot(applying: true)?.apply(to: "Qoder and coder")?.text == "Qoder and coder"
        let normalWordRecord = DictationRecord(rawText: "使用 coder", text: "使用 coder", hits: [], routeID: "qwen06-rolling")
        let hotwordOutcome = CorrectionLearner.evaluate(record: normalWordRecord, editedDictation: "使用 Qoder",
            finalDocument: "使用 Qoder，还会使用 coder", terms: [], ordinaryEnglishWords: ["coder", "code"])
        passed = passed && hotwordOutcome.candidates.count == 1
        let before = lexicon.terms.count
        learningSwitch.enabled = false; runtime.stopLearning()
        await learn("OffMis", "OffChoice", .strong)
        passed = passed && lexicon.terms.count == before
        learningSwitch.enabled = true
        let record = DictationRecord(rawText: "尝试 NoHumMis", text: "尝试 NoHumMis", hits: [], routeID: "qwen06-rolling")
        let id = UUID()
        runtime.dictationKept(record, baseline: KeptDictationBaseline(id: id, processIdentifier: getpid(),
            document: record.text, spanLocation: 0, spanLength: record.text.utf16.count, delivered: record.text,
            emptyStateValues: [], editingGeneration: 0, path: "paste", revertTexts: []))
        runtime.sessionBegan(revisit: FieldRevisitSample(baselineID: id, document: "尝试 NoHumChoice", editingGeneration: 0))
        passed = passed && lexicon.terms.count == before
        runtime.stopLearning()
        print("R57_ITEM6_AUTOMATIC passed=\(passed ? 1 : 0) cases=8 network=0 keys=0 audio=0")
        return passed
    }

    #if SETTINGS_REVIEW_HOST
    /// Review-window entries are generated locally and never enter the dictation edit observer.
    func installSettingsReviewFixture(pendingCount: Int) {
        var fixture = CorrectionLedger()
        let count = min(max(0, pendingCount), CorrectionLedger.maximumEntries)
        let candidates = (0..<count).map { index in
            CorrectionLearner.Candidate(
                variant: "合成错写\(index + 1)",
                canonical: "合成修正\(index + 1)",
                confidence: .weak
            )
        }
        if !candidates.isEmpty {
            _ = fixture.note(candidates, dictationID: UUID(), now: Date(timeIntervalSince1970: 1_791_000_000))
        }
        ledger = fixture
        pending = fixture.entries
    }
    #endif

    // MARK: - From the coordinator

    func dictationKept(_ record: DictationRecord, baseline: KeptDictationBaseline) {
        enhancement.dictationKept(record, baseline: baseline)
        forgetObservation()
        guard isEnabled() else { return }
        guard baseline.delivered == record.text else {
            RuntimeTrace.record("learn baseline rejected reason=textMismatch")
            return
        }
        guard let tracker = EditSpanTracker(
            document: baseline.document,
            spanLocation: baseline.spanLocation,
            spanLength: baseline.spanLength,
            delivered: record.text,
            emptyStateValues: baseline.emptyStateValues,
            editingGeneration: baseline.editingGeneration,
            revertTexts: baseline.revertTexts
        ) else {
            RuntimeTrace.record("learn baseline rejected reason=span path=\(baseline.path)")
            return
        }
        observation = Observation(record: record, baselineID: baseline.id, tracker: tracker, startedAt: Date())
        scheduleExpiry(baselineID: baseline.id)
    }

    func sessionBegan(revisit: FieldRevisitSample?) {
        enhancement.sessionBegan(revisit: revisit)
        guard var current = observation else { return }
        forgetObservation()
        guard isEnabled() else { return }
        guard Date().timeIntervalSince(current.startedAt) <= Self.observationLifetime else {
            RuntimeTrace.record("learn revisit skipped reason=expired")
            return
        }
        guard let revisit, revisit.baselineID == current.baselineID else {
            RuntimeTrace.record("learn revisit skipped reason=otherField")
            return
        }
        // Whether a key or mouse press happened since the dictation, and how many non-breaking spaces the
        // field showed: the two things this feature still has to learn about real editors.
        let human = revisit.editingGeneration != current.tracker.baselineGeneration
        let spaces = revisit.document?.filter { $0 == "\u{00A0}" || $0 == "\u{202F}" }.count ?? 0
        let event = current.tracker.observe(document: revisit.document, editingGeneration: revisit.editingGeneration)
        RuntimeTrace.record("learn revisit event=\(Self.label(event)) human=\(human) nbsp=\(spaces)")
        if event == .undone { RecognitionMemoryRuntime.shared.remove(id: current.record.id) }
        if event == .dictationEdited, human {
            RecognitionMemoryRuntime.shared.replace(id: current.record.id, text: current.tracker.dictation)
        }
        guard event == .dictationEdited else { return }
        evaluate(record: current.record, edited: current.tracker.dictation, finalDocument: current.tracker.document)
    }

    // MARK: - From the settings page

    /// Entries not seen for a week are dropped.
    func refresh() {
        ledger.prune(now: Date())
        pending = ledger.entries
    }

    /// What became of a click on "加入词库".
    enum AcceptResult {
        case added(LexiconStore.AddResult)
        /// The lexicon changed since the suggestion was made and now has its own say (a short reason label).
        case refused(String)
        case failed(LexiconStore.StoreError)
    }

    /// The person confirmed a pending correction: it becomes an ordinary lexicon entry, from their own choice.
    /// The lexicon may have changed since the suggestion was made, so it is asked again first: a suggestion is
    /// never allowed to take a wrong spelling from another entry or to switch an entry back on.
    func accept(_ entry: CorrectionLedger.Entry) async -> AcceptResult {
        let key = Self.pairKey(variant: entry.variant, canonical: entry.canonical)
        guard isEnabled(), lexicon.availability == .ready else { return skip("disabled") }
        guard !suppressed.contains(key) else { return skip("undone") }
        let generation = learningGeneration
        let epoch = humanPermit.update(enabled: true)
        let hotwordOnly = isOrdinaryEnglishWord(entry.variant)
        let result = await lexicon.addHumanCorrection(canonical: entry.canonical, variant: entry.variant,
            hotwordOnly: hotwordOnly, permit: humanPermit, epoch: epoch)
        switch result {
        case .added(let added):
            ledger.remove(entry.id)
            pending = ledger.entries
            if generation == learningGeneration {
                justLearned.insert(LearnedEntry(termID: added.term.id, variant: entry.variant,
                    canonical: added.term.canonical, hotwordOnly: hotwordOnly), at: 0)
                if justLearned.count > 5 { justLearned.removeLast(justLearned.count - 5) }
            }
            RuntimeTrace.record(hotwordOnly ? "learn auto added kind=hotwordOnly"
                : "learn auto added confidence=\(entry.confidence.rawValue) sightings=\(entry.sightings)")
            return .added(added)
        case .skipped(let reason):
            ledger.remove(entry.id); pending = ledger.entries
            return skip(reason)
        }
    }

    private func skip(_ reason: String) -> AcceptResult {
        RuntimeTrace.record("learn auto skipped reason=\(reason)")
        return .refused(reason)
    }

    private static func pairKey(variant: String, canonical: String) -> String {
        LexiconText.foldKey(variant) + "\u{001F}" + canonical
    }

    func undo(_ entry: LearnedEntry) async {
        teacher.cancelWork()
        suppressed.insert(Self.pairKey(variant: entry.variant, canonical: entry.canonical))
        // Revoke a queued write before removing the pair, so it cannot recreate it after Undo.
        learningGeneration &+= 1; _ = humanPermit.update(enabled: false)
        if await lexicon.undoHumanCorrection(termID: entry.termID, canonical: entry.canonical,
                                            variant: entry.hotwordOnly ? nil : entry.variant) {
            justLearned.removeAll { $0.id == entry.id }
            RuntimeTrace.record("learn auto undone")
        }
    }

    /// The person does not want this pair suggested again (until the app is quit).
    func dismiss(_ entry: CorrectionLedger.Entry) {
        ledger.dismiss(entry.id)
        pending = ledger.entries
        RuntimeTrace.record("learn dismiss confidence=\(entry.confidence.rawValue) sightings=\(entry.sightings)")
    }

    /// Learning was turned off: nothing is observed and nothing is kept.
    func stopLearning() {
        learningGeneration &+= 1; _ = humanPermit.update(enabled: false)
        forgetObservation()
        ledger.removeAll()
        pending = []
    }

    func discardForDataRemoval() {
        teacher.cancelWork()
        RecognitionMemoryRuntime.shared.clear(reason: "dataRemoval")
        stopLearning()
        justLearned = []
        enhancement.authorize(onlineEnabled: false, learningEnabled: false, doubaoEnabled: false)
    }

    // MARK: - The receipt's lifetime

    private func forgetObservation() {
        observation = nil
        expiry?.cancel()
        expiry = nil
    }

    /// The receipt (the whole field's text) does not outlive its five minutes, whether or not another gesture
    /// comes.
    private func scheduleExpiry(baselineID: UUID) {
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.observationLifetime))
            guard !Task.isCancelled else { return }
            self?.expire(baselineID: baselineID)
        }
    }

    private func expire(baselineID: UUID) {
        guard observation?.baselineID == baselineID else { return }
        forgetObservation()
        RuntimeTrace.record("learn observation expired")
    }

    // MARK: - Evaluation

    /// The comparison runs off the main actor (Chinese pinyin transliteration takes a moment); only its
    /// answer comes back.
    private func evaluate(record: DictationRecord, edited: String, finalDocument: String) {
        let terms = lexicon.terms
        let generation = learningGeneration
        let ordinaryEnglishWords = Set((record.text + " " + edited)
            .split(whereSeparator: { $0.asciiValue == nil || !$0.isLetter })
            .map(String.init).filter(isOrdinaryEnglishWord).map { $0.lowercased() })
        let work = Task.detached(priority: .utility) {
            CorrectionLearner.evaluate(
                record: record, editedDictation: edited, finalDocument: finalDocument, terms: terms,
                ordinaryEnglishWords: ordinaryEnglishWords
            )
        }
        Task { [weak self] in
            let outcome = await work.value
            guard let self, self.learningGeneration == generation else { return }
            await self.apply(outcome, dictationID: record.id)
        }
    }

    private func apply(_ outcome: CorrectionLearner.Outcome, dictationID: UUID) async {
        // No late writes: the person may have turned learning off while the comparison ran.
        guard isEnabled() else { return }
        let rejects = outcome.rejectionSummary.isEmpty ? "none" : outcome.rejectionSummary
        RuntimeTrace.record(
            "learn evaluate kind=\(outcome.kind.rawValue) candidates=\(outcome.candidates.count) " +
            "reverted=\(outcome.revertedTermIDs.count) rejects=\(rejects)"
        )
        guard !outcome.candidates.isEmpty else { return }
        let generation = learningGeneration
        for candidate in outcome.candidates {
            guard isEnabled(), generation == learningGeneration else { break }
            _ = ledger.note([candidate], dictationID: dictationID, now: Date())
            guard let entry = ledger.entries.first(where: {
                $0.variant == candidate.variant && $0.canonical == candidate.canonical
            }) else { continue }
            _ = await accept(entry)
        }
        pending = []
    }

    private static func label(_ event: EditSpanTracker.Event) -> String {
        switch event {
        case .unchanged: return "unchanged"
        case .outsideEdit: return "outsideEdit"
        case .dictationEdited: return "dictationEdited"
        case .cleared: return "cleared"
        case .undone: return "undone"
        case .ambiguous: return "ambiguous"
        case .tooLarge: return "tooLarge"
        case .noHumanInput: return "noHumanInput"
        }
    }
}
