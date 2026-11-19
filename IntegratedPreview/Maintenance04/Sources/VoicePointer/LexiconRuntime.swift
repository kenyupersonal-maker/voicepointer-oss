import Combine
import Foundation
import VoicePointerCore

/// The app's one personal lexicon: the store on disk, the frozen matcher the dictation path reads at the start
/// of each dictation, and what the settings page shows (the entries and the recent dictations).
///
/// The list of recent dictations lives in memory only: the words a person just spoke are not written to disk
/// for the sake of a correction button. Entries, once the person adds them, are what the store keeps.
@MainActor
final class LexiconRuntime: ObservableObject {
    static let shared = LexiconRuntime()

    enum Availability: Equatable {
        case loading
        case ready
        /// lexicon.json exists but is not a lexicon. The person may move it aside and start over.
        case malformed
        case unsupportedVersion
        case unavailable
    }

    static let recentLimit = 20
    /// Recent dictations older than this are dropped the next time the list is touched.
    static let recentLifetime: TimeInterval = 12 * 3_600

    @Published private(set) var availability: Availability = .loading
    @Published private(set) var terms: [LexiconTerm] = []
    @Published private(set) var recent: [DictationRecord] = []

    private let store: LexiconStore
    /// Only the installed app uses its ordinary defaults; preview/test stores must opt in.
    private let migrationDefaults: UserDefaults?
    private static let legacyAutoArchiveKey = "lexicon.archive.before0.5.66.completed"
    private var snapshot = LexiconSnapshot.empty
    private var started = false
    private var strictAutomaticReady: Bool {
        migrationDefaults?.bool(forKey: Self.legacyAutoArchiveKey) == true
    }

    private init() {
        #if SETTINGS_REVIEW_HOST
        // The screenshot host never reads or writes the real lexicon or its preferences.
        store = LexiconStore(
            directory: Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("lexicon-review", isDirectory: true)
        )
        migrationDefaults = nil
        #else
        store = LexiconStore()
        migrationDefaults = .standard
        #endif
    }

    init(store: LexiconStore, migrationDefaults: UserDefaults? = nil) {
        self.store = store
        self.migrationDefaults = migrationDefaults
    }

    // MARK: - Dictation path

    /// Reads the lexicon once, at launch (and again from the settings page's retry).
    func start() {
        guard !started else { return }
        started = true
        Task { await reload() }
    }

    /// The matcher for the next dictation, or nil when the person turned the lexicon off.
    func snapshot(applying: Bool) -> LexiconSnapshot? {
        guard applying, availability == .ready else { return nil }
        return strictAutomaticReady ? snapshot : LexiconSnapshot(
            revision: snapshot.revision, terms: terms.filter { $0.source != .automaticallyLearned }
        )
    }

    /// The lexicon's words for the recognizer on this Mac to listen for, best first and within the limits
    /// (`RecognitionHotwords`): nothing while the person turned hot words or the lexicon off, or while the
    /// lexicon is not readable.
    func hotwords(applying: Bool) -> [String] {
        guard applying, availability == .ready else { return [] }
        return RecognitionHotwords.select(from: strictAutomaticReady
            ? terms : terms.filter { $0.source != .automaticallyLearned })
    }

    /// From the coordinator: a dictation just finished on a route that hands the app the text.
    func record(_ dictation: DictationRecord) {
        pruneRecent()
        recent.insert(dictation, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        var counts: [UUID: Int] = [:]
        for hit in dictation.hits { counts[hit.termID, default: 0] += 1 }
        Task {
            await store.recordHits(counts)
            if migrationDefaults?.bool(forKey: Self.legacyAutoArchiveKey) == true {
                // Expire lazily after real dictations, never by deleting without archived bytes.
                try? await store.expireAutomaticTerms()
            }
            snapshot = await store.snapshot()
            terms = await store.allTerms()
        }
    }

    /// Pending hit counters go to disk (settings closing, app quitting).
    func flush() async {
        try? await store.flush()
    }

    // MARK: - Settings page

    func reload() async {
        do {
            snapshot = try await store.load()
            if let defaults = migrationDefaults {
                if defaults.bool(forKey: Self.legacyAutoArchiveKey) {
                    let currentTerms = await store.allTerms()
                    RuntimeTrace.record("lexicon archive moved=0 kept=\(currentTerms.count) result=skipped")
                } else {
                    do {
                        let migrated = try await store.archiveLegacyAutomaticTerms()
                        // The completion marker is deliberately the last mutation.
                        defaults.set(true, forKey: Self.legacyAutoArchiveKey)
                        let outcome = migrated.moved > 0 ? "ok" : "skipped"
                        RuntimeTrace.record("lexicon archive moved=\(migrated.moved) kept=\(migrated.kept) result=\(outcome)")
                    } catch {
                        let currentTerms = await store.allTerms()
                        RuntimeTrace.record("lexicon archive moved=0 kept=\(currentTerms.count) result=failed")
                    }
                }
            }
            // Legacy migration must complete first. Expiration never touches an unarchived old entry.
            if migrationDefaults?.bool(forKey: Self.legacyAutoArchiveKey) == true {
                try? await store.expireAutomaticTerms()
            }
            snapshot = await store.snapshot()
            terms = await store.allTerms()
            availability = .ready
            RuntimeTrace.record("lexicon loaded terms=\(terms.count) rules=\(snapshot.ruleCount)")
        } catch let error as LexiconStore.StoreError {
            snapshot = .empty
            terms = []
            switch error {
            case .malformed: availability = .malformed
            case .unsupportedVersion: availability = .unsupportedVersion
            default: availability = .unavailable
            }
            RuntimeTrace.record("lexicon load failed reason=\(availability)")
        } catch {
            snapshot = .empty
            terms = []
            availability = .unavailable
            RuntimeTrace.record("lexicon load failed reason=unknown")
        }
    }

    /// The person chose to move an unreadable lexicon.json aside and start with an empty lexicon.
    func recoverMalformed() async -> Bool {
        do {
            _ = try await store.recoverMalformed()
            RuntimeTrace.record("lexicon recovered")
            await reload()
            return true
        } catch {
            RuntimeTrace.record("lexicon recover failed")
            // Whatever state the file is in now is what the page should show.
            await reload()
            return false
        }
    }

    @discardableResult
    func add(
        canonical: String, variants: [String], source: LexiconSource
    ) async -> Result<LexiconStore.AddResult, LexiconStore.StoreError> {
        await change {
            let result = try await store.add(canonical: canonical, variants: variants, source: source)
            RuntimeTrace.record(
                "lexicon add source=\(source.rawValue) variants=\(result.term.variants.count) merged=\(result.kind == .mergedIntoExisting)"
            )
            return result
        }
    }

    @discardableResult
    func update(
        id: UUID, canonical: String, variants: [String], isEnabled: Bool
    ) async -> Result<LexiconStore.AddResult, LexiconStore.StoreError> {
        await change {
            let result = try await store.update(id: id, canonical: canonical, variants: variants, isEnabled: isEnabled)
            RuntimeTrace.record("lexicon update variants=\(result.term.variants.count) enabled=\(isEnabled)")
            return result
        }
    }

    // Automatic/teacher promotions stay disabled. Human corrections are handled separately.
    func addTeacherLearned(_ promotion: EnhancementLearningPipeline.Promotion,
                          permit: EnhancementLearningPermit, epoch: UInt64) async -> LexiconStore.AddResult? {
        _ = AutomaticPromotionPolicy.permitPersist { RuntimeTrace.record($0) }
        return nil
    }
    func addAutomaticallyLearned(_ promotion: EnhancementLearningPipeline.Promotion,
                                 permit: EnhancementLearningPermit, epoch: UInt64) async -> Bool {
        return AutomaticPromotionPolicy.permitPersist { RuntimeTrace.record($0) }
    }

    /// The strict candidate actor has already persisted teacher evidence and reserved quota.
    /// Only the existing LexiconStore atomic commit may create a live automatic term.
    func addStrictAutomatic(
        _ promotion: StrictLearningLedger.Promotion, at date: Date,
        permit: EnhancementLearningPermit, epoch: UInt64
    ) async -> LexiconStore.AddResult? {
        guard availability == .ready, strictAutomaticReady else { return nil }
        do {
            let added = try await store.addStrictAutomaticallyLearned(
                promotion.pair, sightings: promotion.sightings, at: date,
                permit: permit, epoch: epoch
            )
            if added != nil {
                snapshot = await store.snapshot()
                terms = await store.allTerms()
            }
            return added
        } catch { return nil }
    }

    func addHumanCorrection(canonical: String, variant: String, hotwordOnly: Bool,
                            permit: EnhancementLearningPermit, epoch: UInt64) async -> LexiconStore.HumanCorrectionResult {
        guard availability == .ready else { return .skipped("lexiconUnavailable") }
        do {
            let result = try await store.addHumanCorrection(canonical: canonical, variant: variant,
                hotwordOnly: hotwordOnly, permit: permit, epoch: epoch)
            snapshot = await store.snapshot(); terms = await store.allTerms()
            return result
        } catch { return .skipped("storeFailed") }
    }

    func undoHumanCorrection(termID: UUID, canonical: String, variant: String?) async -> Bool {
        guard availability == .ready else { return false }
        do {
            let removed = try await store.undoHumanCorrection(termID: termID, canonical: canonical, variant: variant)
            snapshot = await store.snapshot(); terms = await store.allTerms()
            return removed
        } catch { return false }
    }

    @discardableResult
    func setEnabled(id: UUID, _ enabled: Bool) async -> Result<Void, LexiconStore.StoreError> {
        await change({ try await store.setEnabled(id: id, enabled) }, applyLocal: { _ in
            if let index = self.terms.firstIndex(where: { $0.id == id }) {
                self.terms[index].isEnabled = enabled
            }
        })
    }

    @discardableResult
    func remove(id: UUID) async -> Result<Void, LexiconStore.StoreError> {
        await change({
            try await store.remove(id: id)
            RuntimeTrace.record("lexicon remove")
        }, applyLocal: { _ in
            if let index = self.terms.firstIndex(where: { $0.id == id }) {
                self.terms.remove(at: index)
            }
        })
    }

    @discardableResult
    func removeAll() async -> Result<Void, LexiconStore.StoreError> {
        await change {
            try await store.removeAll()
            RuntimeTrace.record("lexicon removeAll")
        }
    }

    func clearRecent() { recent = [] }

    // T12: No reload/decoding of a user file during cleanup, and no late hit flush recreates it.
    func discardForDataRemoval() async {
        await store.discardForDataRemoval()
        terms = []; recent = []; snapshot = .empty; availability = .ready
    }
    func finishDataRemoval() async throws { try await store.finishDataRemoval(); availability = .ready }

    #if SETTINGS_REVIEW_HOST
    /// Native screenshot fixture state is memory-only; it never asks the isolated store to load or save data.
    func installSettingsReviewFixture(termCount: Int) {
        let count = min(max(0, termCount), LexiconLimits.maxTerms)
        let fixtureDate = Date(timeIntervalSince1970: 1_791_000_000)
        terms = (0..<count).map { index in
            LexiconTerm(
                canonical: "合成词条\(index + 1)",
                variants: ["合成误写\(index + 1)"],
                createdAt: fixtureDate
            )
        }
        recent = []
        snapshot = .empty
        availability = .ready
    }
    #endif

    /// What the page shows: a list that sat untouched overnight ages out here, not only when the next
    /// dictation prunes it.
    var freshRecent: [DictationRecord] {
        let cutoff = Date().addingTimeInterval(-Self.recentLifetime)
        return recent.filter { $0.date >= cutoff }
    }

    func pruneRecent() {
        let cutoff = Date().addingTimeInterval(-Self.recentLifetime)
        if recent.contains(where: { $0.date < cutoff }) { recent.removeAll { $0.date < cutoff } }
    }

    private func change<T>(
        _ operation: () async throws -> T,
        applyLocal: ((T) -> Void)? = nil
    ) async -> Result<T, LexiconStore.StoreError> {
        do {
            let value = try await operation()
            snapshot = await store.snapshot()
            if let applyLocal {
                applyLocal(value)
            } else {
                terms = await store.allTerms()
            }
            return .success(value)
        } catch let error as LexiconStore.StoreError {
            if error == .changedOnDisk {
                // The file was edited outside the app: nothing was written; read what is there now.
                RuntimeTrace.record("lexicon file changed on disk; reloading")
                await reload()
            }
            return .failure(error)
        } catch {
            return .failure(.unavailable("unknown"))
        }
    }
}
