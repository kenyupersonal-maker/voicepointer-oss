import CryptoKit
import Foundation

/// Durable, fail-closed evidence for strict teacher learning. This actor never reads a user's
/// recognition logs, saved speech or clipboard. Only the two spelling fragments in the bounded
/// candidate pool can contain text; teacher sentences are indexed as salted SHA-256 digests.
public actor StrictLearningLedger {
    public enum Failure: Error, Sendable {
        case damaged
        case changedOnDisk
        case unavailable
    }

    public enum PromotionDecision: String, Sendable {
        case ok
        case threshold
        case dailyCap
        case totalCap
        case contradicted
    }

    public struct Promotion: Sendable {
        public let pair: StrictLearningFilter.Pair
        public let sightings: Int
        public let dates: [String]
    }

    public struct Outcome: Sendable {
        public let candidateReasons: [StrictLearningFilter.Rejection?]
        public let promotionReasons: [PromotionDecision]
        public let promotions: [Promotion]
    }

    public struct Coverage: Sendable {
        public let indexedSince: Date
        public let candidateCount: Int
        public let forbiddenCount: Int
        public let observedRounds: Int
    }

    private struct Evidence: Codable {
        var variant: String
        var canonical: String
        var rounds: [UUID]
        var days: [String]
        /// Up to two different teacher-sentence fingerprints; never a teacher sentence.
        var witnesses: [String]
        var firstAt: Date
        var lastAt: Date
        var pending: Bool
        var promoted: Bool
    }

    private struct Pool: Codable {
        var version = 1
        var entries: [Evidence] = []
        var dailyPromotions: [String: Int] = [:]
        /// Complete comparisons are consumed once even after their candidates are evicted.
        /// Teacher observations have a separate identity list because they arrive before comparisons.
        var consumedRounds: [UUID] = []
    }

    private struct Index: Codable {
        var version = 1
        let salt: String
        let indexedSince: Date
        var observedRounds: [UUID] = []
        /// Normalized fragment digest -> at most two different sentence fingerprints.
        var fragments: [String: [String]] = [:]
    }

    private struct Forbidden: Codable {
        var version = 1
        /// Salted, normalized pair digests survive candidate eviction.
        var pairDigests: [String] = []
    }

    public nonisolated let directory: URL
    private var pool = Pool()
    private var index: Index?
    private var forbidden = Forbidden()
    private var opened = false
    /// Any partial/failed evidence write poisons this process: no following utterance may
    /// promote using an incomplete or uncertain teacher history.
    private var integrityLost = false
    private var poolFingerprint: LexiconFileIO.Fingerprint?
    private var indexFingerprint: LexiconFileIO.Fingerprint?
    private var forbiddenFingerprint: LexiconFileIO.Fingerprint?

    private var poolURL: URL { directory.appendingPathComponent("strict-learning-candidates.json") }
    private var indexURL: URL { directory.appendingPathComponent("strict-learning-teacher-index.json") }
    private var forbiddenURL: URL { directory.appendingPathComponent("strict-learning-forbidden.json") }
    private static let maximumJSONBytes = 24 * 1024 * 1024
    private static let candidateLimit = 500
    private static let dayLimit = 3
    private static let activityLimit = 100

    public init(directory: URL = LexiconStore.defaultDirectory) {
        self.directory = directory
    }

    /// Missing all three files means *the first activation*, not recovered historical coverage.
    /// One or two missing/corrupt files, including a deleted index, stop automatic learning.
    private func open() throws {
        guard !integrityLost else { throw Failure.unavailable }
        guard !opened else { return }
        let p = try LexiconFileIO.readFileWithFingerprint(poolURL, maxBytes: Self.maximumJSONBytes)
        let i = try LexiconFileIO.readFileWithFingerprint(indexURL, maxBytes: Self.maximumJSONBytes)
        let b = try LexiconFileIO.readFileWithFingerprint(forbiddenURL, maxBytes: Self.maximumJSONBytes)
        if p == nil && i == nil && b == nil {
            _ = try LexiconFileIO.prepareDirectory(directory, create: true)
            let fresh = Index(salt: UUID().uuidString + UUID().uuidString, indexedSince: Date())
            // Index first. A partial first launch must fail closed on the next launch.
            try write(fresh, to: indexURL, prior: nil)
            try write(Forbidden(), to: forbiddenURL, prior: nil)
            try write(Pool(), to: poolURL, prior: nil)
            index = fresh
            opened = true
            return
        }
        guard let p, let i, let b else { throw Failure.damaged }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loadedPool = try? decoder.decode(Pool.self, from: p.data),
              let loadedIndex = try? decoder.decode(Index.self, from: i.data),
              let loadedForbidden = try? decoder.decode(Forbidden.self, from: b.data),
              loadedPool.version == 1, loadedIndex.version == 1, loadedForbidden.version == 1,
              !loadedIndex.salt.isEmpty,
              loadedPool.entries.count <= Self.candidateLimit,
              loadedPool.entries.allSatisfy({ !$0.variant.isEmpty && !$0.canonical.isEmpty }),
              loadedIndex.fragments.values.allSatisfy({ $0.count <= 2 }),
              loadedPool.dailyPromotions.values.allSatisfy({ $0 >= 0 }),
              !loadedPool.entries.contains(where: { $0.pending && $0.promoted }) else {
            throw Failure.damaged
        }
        pool = loadedPool
        index = loadedIndex
        forbidden = loadedForbidden
        poolFingerprint = p.fingerprint
        indexFingerprint = i.fingerprint
        forbiddenFingerprint = b.fingerprint
        opened = true
    }

    private func write<T: Encodable>(
        _ value: T,
        to url: URL,
        prior: LexiconFileIO.Fingerprint?
    ) throws {
        guard !integrityLost else { throw Failure.unavailable }
        do {
            guard try LexiconFileIO.fingerprint(of: url) == prior else {
                throw Failure.changedOnDisk
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value), data.count <= Self.maximumJSONBytes else {
                throw Failure.unavailable
            }
            try LexiconFileIO.writeAtomically(data, to: url)
            let written = try LexiconFileIO.fingerprint(of: url)
            if url == poolURL { poolFingerprint = written }
            if url == indexURL { indexFingerprint = written }
            if url == forbiddenURL { forbiddenFingerprint = written }
        } catch {
            integrityLost = true
            throw error
        }
    }

    private func savePool(_ value: Pool) throws {
        try write(value, to: poolURL, prior: poolFingerprint)
        pool = value
    }

    private func saveIndex(_ value: Index) throws {
        try write(value, to: indexURL, prior: indexFingerprint)
        index = value
    }

    private func saveForbidden(_ value: Forbidden) throws {
        try write(value, to: forbiddenURL, prior: forbiddenFingerprint)
        forbidden = value
    }

    public func coverage() throws -> Coverage {
        try open()
        guard let index else { throw Failure.damaged }
        return Coverage(indexedSince: index.indexedSince, candidateCount: pool.entries.count,
                        forbiddenCount: forbidden.pairDigests.count,
                        observedRounds: index.observedRounds.count)
    }

    private static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func hash(_ payload: String, salt: String) -> String {
        let bytes = Data((salt + "\u{1F}" + payload).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func components(_ sentence: String) -> [String] {
        var result: [String] = []
        var english = ""
        func flush() {
            if !english.isEmpty {
                result.append(LexiconText.foldKey(english))
                english.removeAll(keepingCapacity: true)
            }
        }
        for char in sentence {
            if let ascii = char.asciiValue,
               (65...90).contains(ascii) || (97...122).contains(ascii) {
                english.append(char)
            } else {
                flush()
                if LexiconText.isHan(char) { result.append(String(char)) }
            }
        }
        flush()
        return result
    }

    private static func sentences(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var pending = ""
        for char in text {
            if "。！？.!?；;\n\r".contains(char) {
                let units = components(pending)
                if !units.isEmpty { result.append(units) }
                pending = ""
            } else { pending.append(char) }
        }
        let last = components(pending)
        if !last.isEmpty { result.append(last) }
        return result
    }

    private static func fragment(_ words: [String]) -> String {
        words.joined(separator: "\u{1F}")
    }

    private static func fragmentDigest(_ text: String, salt: String) -> String {
        hash("fragment|" + fragment(components(text)), salt: salt)
    }

    private static func teacherSentenceDigest(_ words: [String], salt: String) -> String {
        hash("sentence|" + fragment(words), salt: salt)
    }

    private static func pairDigest(_ pair: StrictLearningFilter.Pair, salt: String) -> String {
        hash("pair|" + fragment(components(pair.variant)) + "|" + fragment(components(pair.canonical)), salt: salt)
    }

    private static func containsUnits(_ haystack: [String], needle: [String]) -> Bool {
        guard !needle.isEmpty && haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    private static func fragmentKeys(in sentence: [String], salt: String) -> Set<String> {
        var result: Set<String> = []
        for start in sentence.indices {
            var han = 0
            var latin = 0
            for end in start..<min(sentence.count, start + 11) {
                if sentence[end].allSatisfy(LexiconText.isHan) { han += 1 }
                else { latin += 1 }
                if han > 8 || latin > 3 { break }
                let fragment = Array(sentence[start...end])
                result.insert(hash("fragment|" + Self.fragment(fragment), salt: salt))
            }
        }
        return result
    }

    /// Called for EVERY qualified teacher final, even when there is no local comparison or
    /// eligible candidate. Only salted fragment/sentence digests are persisted, never sentences.
    /// The index write happens before any candidate update or automatic promotion.
    public func observeTeacher(reference: String, roundID: UUID, at date: Date) throws {
        try open()
        guard let current = index else { throw Failure.damaged }
        guard reference.count <= 1_500 else { throw Failure.unavailable }
        if current.observedRounds.contains(roundID) { return }
        let allSentences = Self.sentences(reference)
        guard !allSentences.isEmpty else { return }
        var updated = current
        updated.observedRounds.append(roundID)
        var newKeys: [(key: String, fingerprint: String)] = []
        for sentence in allSentences {
            let fingerprint = Self.teacherSentenceDigest(sentence, salt: current.salt)
            for key in Self.fragmentKeys(in: sentence, salt: current.salt) {
                newKeys.append((key, fingerprint))
                var values = updated.fragments[key] ?? []
                if !values.contains(fingerprint), values.count < 2 { values.append(fingerprint) }
                updated.fragments[key] = values
            }
        }
        try saveIndex(updated)

        // A later teacher final containing a local wrong spelling in another sentence
        // is a permanent counterexample, even if the fragment index already holds two.
        var bans = forbidden
        // A shadow would-promote has not become a live term; later counterexamples
        // must still permanently disqualify it before a future live import.
        for evidence in pool.entries {
            let pair = StrictLearningFilter.Pair(variant: evidence.variant, canonical: evidence.canonical)
            let fragment = Self.fragmentDigest(evidence.variant, salt: current.salt)
            if newKeys.contains(where: { $0.key == fragment && !evidence.witnesses.contains($0.fingerprint) }) {
                let digest = Self.pairDigest(pair, salt: current.salt)
                if !bans.pairDigests.contains(digest) { bans.pairDigests.append(digest) }
            }
        }
        if bans.pairDigests != forbidden.pairDigests { try saveForbidden(bans) }
        _ = date // Explicitly avoid inferring/recording observations before index activation.
    }

    private func teacherWitness(for canonical: String, in reference: String, salt: String) -> String? {
        let needle = Self.components(canonical)
        let matching = Self.sentences(reference)
            .filter { Self.containsUnits($0, needle: needle) }
            .map { Self.teacherSentenceDigest($0, salt: salt) }
        let distinct = Set(matching)
        return distinct.count == 1 ? distinct.first : nil
    }

    /// Each decision comes from StrictLearningFilter's pure comparison on the caller's main actor.
    /// An accepted pair counts once per UUID; candidate documents never contain a full sentence.
    /// A pending reservation consumes quota before the lexicon actor is allowed to write.
    public func ingest(
        decisions: [StrictLearningFilter.Decision],
        reference: String,
        roundID: UUID,
        at date: Date,
        activeTerms: [LexiconTerm]
    ) throws -> Outcome {
        try observeTeacher(reference: reference, roundID: roundID, at: date)
        guard let index else { throw Failure.damaged }
        guard !pool.consumedRounds.contains(roundID) else {
            return Outcome(candidateReasons: [], promotionReasons: [.threshold], promotions: [])
        }
        var next = pool
        next.consumedRounds.append(roundID)
        var candidateReasons: [StrictLearningFilter.Rejection?] = []
        var promotionReasons: [PromotionDecision] = []
        var promotions: [Promotion] = []
        let today = Self.dateKey(date)
        for decision in decisions {
            candidateReasons.append(decision.rejection)
            guard decision.isAccepted else { continue }
            let pair = decision.pair
            let key = Self.pairDigest(pair, salt: index.salt)
            if forbidden.pairDigests.contains(key) {
                promotionReasons.append(.contradicted)
                continue
            }
            guard let witness = teacherWitness(for: pair.canonical, in: reference, salt: index.salt) else {
                promotionReasons.append(.contradicted)
                continue
            }
            var entry: Evidence
            let position = next.entries.firstIndex {
                Self.pairDigest(.init(variant: $0.variant, canonical: $0.canonical), salt: index.salt) == key
            }
            if let position {
                entry = next.entries[position]
            } else {
                entry = Evidence(variant: pair.variant, canonical: pair.canonical,
                                 rounds: [], days: [], witnesses: [], firstAt: date,
                                 lastAt: date, pending: false, promoted: false)
            }
            if entry.promoted || entry.pending {
                promotionReasons.append(.threshold)
                continue
            }
            if !entry.rounds.contains(roundID) {
                entry.rounds.append(roundID)
                if !entry.days.contains(today) { entry.days.append(today) }
                if !entry.witnesses.contains(witness), entry.witnesses.count < 2 {
                    entry.witnesses.append(witness)
                }
                entry.lastAt = date
            }

            if let position { next.entries[position] = entry }
            else { next.entries.append(entry) }
            while next.entries.count > Self.candidateLimit {
                let oldest = next.entries.indices.min {
                    let lhs = next.entries[$0]
                    let rhs = next.entries[$1]
                    return lhs.firstAt == rhs.firstAt
                        ? lhs.variant + lhs.canonical < rhs.variant + rhs.canonical
                        : lhs.firstAt < rhs.firstAt
                }
                guard let oldest else { break }
                // Never discard a reserved promotion while an asynchronous lexicon write is pending.
                if next.entries[oldest].pending { throw Failure.unavailable }
                next.entries.remove(at: oldest)
            }
            let fragment = Self.fragmentDigest(pair.variant, salt: index.salt)
            if index.fragments[fragment, default: []].contains(where: { !entry.witnesses.contains($0) }) {
                var bans = forbidden
                if !bans.pairDigests.contains(key) {
                    bans.pairDigests.append(key)
                    // Forbidden evidence outlives candidate eviction and is written before promotion.
                    try saveForbidden(bans)
                }
                promotionReasons.append(.contradicted)
                continue
            }
            guard entry.rounds.count >= 3 && entry.days.count >= 2 else {
                promotionReasons.append(.threshold)
                continue
            }
            if activeTerms.contains(where: {
                let sameVariant = $0.variants.contains { LexiconText.foldKey($0) == LexiconText.foldKey(pair.variant) }
                let sameCanonical = LexiconText.foldKey($0.canonical) == LexiconText.foldKey(pair.canonical)
                return sameVariant || sameCanonical || LexiconText.foldKey($0.canonical) == LexiconText.foldKey(pair.variant)
            }) {
                promotionReasons.append(.contradicted)
                continue
            }
            let activeCount = activeTerms.filter { $0.source == .automaticallyLearned }.count
                + promotions.count
            guard activeCount < Self.activityLimit else {
                promotionReasons.append(.totalCap)
                continue
            }
            guard next.dailyPromotions[today, default: 0] < Self.dayLimit else {
                promotionReasons.append(.dailyCap)
                continue
            }
            guard let savedIndex = next.entries.firstIndex(where: {
                Self.pairDigest(.init(variant: $0.variant, canonical: $0.canonical), salt: index.salt) == key
            }) else { throw Failure.damaged }
            next.entries[savedIndex].pending = true
            next.dailyPromotions[today, default: 0] += 1
            promotions.append(Promotion(pair: pair, sightings: entry.rounds.count,
                                        dates: entry.days))
            promotionReasons.append(.ok)
        }
        // A failed pool write cannot yield even a single promotion.
        try savePool(next)
        return Outcome(candidateReasons: candidateReasons, promotionReasons: promotionReasons,
                       promotions: promotions)
    }

    public func finishPromotion(_ pair: StrictLearningFilter.Pair, success: Bool) throws {
        try open()
        guard let index else { throw Failure.damaged }
        let key = Self.pairDigest(pair, salt: index.salt)
        guard let at = pool.entries.firstIndex(where: {
            Self.pairDigest(.init(variant: $0.variant, canonical: $0.canonical), salt: index.salt) == key
        }), pool.entries[at].pending else { return }
        var next = pool
        next.entries[at].pending = false
        next.entries[at].promoted = success
        if !success {
            let day = Self.dateKey(next.entries[at].lastAt)
            next.dailyPromotions[day] = max(0, next.dailyPromotions[day, default: 0] - 1)
        }
        try savePool(next)
    }

    /// Undo always commits the permanent digest before the live term may be removed.
    /// The ban never shares the pool's 500-pair eviction lifecycle.
    public func permanentlyForbid(_ pair: StrictLearningFilter.Pair) throws {
        try open()
        guard let index else { throw Failure.damaged }
        let digest = Self.pairDigest(pair, salt: index.salt)
        guard !forbidden.pairDigests.contains(digest) else { return }
        var next = forbidden
        next.pairDigests.append(digest)
        try saveForbidden(next)
    }

    /// Production uses these lock-held wrappers so permission withdrawal cannot race
    /// either teacher observation or the durable candidate/quota write.
    public func observeTeacherAuthorized(
        reference: String, roundID: UUID, at date: Date,
        permit: EnhancementLearningPermit, epoch: UInt64
    ) throws -> Bool {
        try permit.withAuthorization(epoch) {
            try observeTeacher(reference: reference, roundID: roundID, at: date)
            return true
        } ?? false
    }

    public func ingestAuthorized(
        decisions: [StrictLearningFilter.Decision], reference: String,
        roundID: UUID, at date: Date, activeTerms: [LexiconTerm],
        permit: EnhancementLearningPermit, epoch: UInt64
    ) throws -> Outcome? {
        try permit.withAuthorization(epoch) {
            try ingest(decisions: decisions, reference: reference,
                       roundID: roundID, at: date, activeTerms: activeTerms)
        }
    }

    public func finishPromotionAuthorized(
        _ pair: StrictLearningFilter.Pair, success: Bool,
        permit: EnhancementLearningPermit, epoch: UInt64
    ) throws -> Bool {
        try permit.withAuthorization(epoch) {
            try finishPromotion(pair, success: success)
            return true
        } ?? false
    }

    /// A previous observation is NOT sufficient for live import by itself.
    /// Re-check the durable original 3 sightings / 2 dates evidence, permanent bans,
    /// teacher counterexamples, human ownership, live capacity and today's quota.
    public func reserveShadowImport(
        _ observed: StrictLearningShadowStore.Entry, at date: Date,
        activeTerms: [LexiconTerm],
        permit: EnhancementLearningPermit, epoch: UInt64
    ) throws -> Promotion? {
        let candidate: Promotion?? = try permit.withAuthorization(epoch) { () -> Promotion? in
            try open()
            guard let index else { throw Failure.damaged }
            let pair = observed.pair
            let digest = Self.pairDigest(pair, salt: index.salt)
            guard !forbidden.pairDigests.contains(digest),
                  let position = pool.entries.firstIndex(where: {
                      Self.pairDigest(
                          .init(variant: $0.variant, canonical: $0.canonical),
                          salt: index.salt
                      ) == digest
                  }) else { return nil }
            let entry = pool.entries[position]
            guard entry.promoted && !entry.pending,
                  entry.variant == pair.variant, entry.canonical == pair.canonical,
                  entry.rounds.count >= 3, entry.days.count >= 2,
                  observed.sightings >= 3, observed.sightings <= entry.rounds.count,
                  Set(observed.dates).count >= 2,
                  Set(observed.dates).isSubset(of: Set(entry.days)) else { return nil }
            let fragment = Self.fragmentDigest(pair.variant, salt: index.salt)
            guard !index.fragments[fragment, default: []].contains(where: {
                !entry.witnesses.contains($0)
            }) else { return nil }
            guard !activeTerms.contains(where: {
                let key = LexiconText.foldKey($0.canonical)
                return key == LexiconText.foldKey(pair.canonical)
                    || key == LexiconText.foldKey(pair.variant)
                    || $0.variants.contains(where: {
                        LexiconText.foldKey($0) == LexiconText.foldKey(pair.variant)
                            || LexiconText.foldKey($0) == LexiconText.foldKey(pair.canonical)
                    })
            }) else { return nil }
            guard activeTerms.filter({ $0.source == .automaticallyLearned }).count
                    < Self.activityLimit else { return nil }
            let today = Self.dateKey(date)
            guard pool.dailyPromotions[today, default: 0] < Self.dayLimit else { return nil }
            var next = pool
            next.entries[position].pending = true
            next.dailyPromotions[today, default: 0] += 1
            try savePool(next)
            return Promotion(pair: pair, sightings: entry.rounds.count, dates: entry.days)
        }
        return candidate ?? nil
    }

    /// A rejected/failed live import restores its current-day reservation while
    /// keeping the original shadow achievement eligible for a future authorized day.
    @discardableResult
    public func finishShadowImport(
        _ pair: StrictLearningFilter.Pair, success: Bool, at date: Date,
        permit: EnhancementLearningPermit, epoch: UInt64
    ) throws -> Bool {
        try permit.withAuthorization(epoch) {
            try open()
            guard let index else { throw Failure.damaged }
            let digest = Self.pairDigest(pair, salt: index.salt)
            guard let position = pool.entries.firstIndex(where: {
                Self.pairDigest(.init(variant: $0.variant, canonical: $0.canonical),
                                salt: index.salt) == digest
            }), pool.entries[position].pending else { return false }
            var next = pool
            next.entries[position].pending = false
            next.entries[position].promoted = true
            if !success {
                let today = Self.dateKey(date)
                next.dailyPromotions[today] = max(0, next.dailyPromotions[today, default: 0] - 1)
            }
            try savePool(next)
            return true
        } ?? false
    }

    public func wasForbidden(_ pair: StrictLearningFilter.Pair) throws -> Bool {
        try open()
        guard let index else { throw Failure.damaged }
        return forbidden.pairDigests.contains(Self.pairDigest(pair, salt: index.salt))
    }
}
