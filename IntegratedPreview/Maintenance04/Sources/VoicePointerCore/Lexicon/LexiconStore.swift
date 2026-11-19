import CryptoKit
import Foundation

/// The personal lexicon on disk: one small JSON file in a private folder, changed only through this actor.
///
/// - Every change is validated, written atomically and only then made visible; a failed write leaves both
///   the file and the in-memory list as they were.
/// - A file that cannot be read as a lexicon is never overwritten. `load()` reports it, mutations refuse to
///   run until the person chooses `recoverMalformed()`, which moves the file aside byte for byte.
/// - Entries that fail validation on load (a hand edit, an older limit) are dropped from memory, but the
///   original bytes are first copied to a backup (named after their content, so one file is saved once) so
///   nothing is lost silently; when that copy cannot be written the lexicon stays unloaded.
/// - The file is checked before every write: if it is no longer the one this actor read or wrote (edited
///   by hand while the app runs, replaced by a sync tool), the write is refused with `.changedOnDisk` and
///   the caller reloads, instead of overwriting the outside change.
/// - Hit counters are flushed lazily (a dictation should not cost a disk write); everything else is
///   written at once.
public actor LexiconStore {
    public enum StoreError: Error, Equatable, Sendable {
        /// `load()` has not succeeded yet, so writing could overwrite what is on disk.
        case notLoaded
        /// The folder or file cannot be used: a symlink, another owner, an I/O error.
        case unavailable(String)
        /// The file is there but is not a lexicon. It is left untouched.
        case malformed
        /// Written by a newer version of the app.
        case unsupportedVersion(Int)
        case validation(LexiconValidationError)
        /// The file was changed by something other than this actor since it was read. Nothing was written;
        /// `load()` reads the new state.
        case changedOnDisk
    }

    public struct AddResult: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case created, mergedIntoExisting }
        public let term: LexiconTerm
        public let kind: Kind
        /// Canonical spellings of the entries that lost a wrong spelling because this one now owns it.
        public let takenFrom: [String]
    }

    public static let currentVersion = 1
    public static let fileName = "lexicon.json"
    static let maxFileBytes = 64 * 1024 * 1024

    /// `Application Support/<app>/Lexicon`.
    public static var defaultDirectory: URL {
        IntegratedRuntimePaths.dataRoot.appendingPathComponent("Lexicon", isDirectory: true)
    }

    private struct Document: Codable {
        var version: Int
        var terms: [LexiconTerm]
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    /// One entry that may not decode: a hand-edited file with a broken entry loses that entry, not the list.
    private struct LenientTerm: Decodable {
        let term: LexiconTerm?
        init(from decoder: Decoder) throws { term = try? LexiconTerm(from: decoder) }
    }

    private struct LenientDocument: Decodable {
        let version: Int
        let terms: [LenientTerm]
    }

    public nonisolated let directory: URL
    public nonisolated var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private var terms: [LexiconTerm] = []
    private var revision = 0
    private var isLoaded = false
    /// The file as this actor last read or wrote it; nil when there was none.
    private var knownFingerprint: LexiconFileIO.Fingerprint?
    private var hitsDirty = false
    private var flushTask: Task<Void, Never>?
    private let hitFlushDelayNanoseconds: UInt64
    private var automaticAdditions: [Date] = []
    private var automaticPausedUntil: Date?

    public init(directory: URL = LexiconStore.defaultDirectory, hitFlushDelay: TimeInterval = 20) {
        self.directory = directory
        self.hitFlushDelayNanoseconds = UInt64(max(0.001, hitFlushDelay) * 1_000_000_000)
    }

    // MARK: - Reading

    /// Reads the lexicon. A missing folder or file is an empty lexicon (nothing is created until the first
    /// change). Throws `.malformed`, `.unsupportedVersion` or `.unavailable` and stays unloaded.
    @discardableResult
    public func load() throws -> LexiconSnapshot {
        isLoaded = false
        terms = []
        flushTask?.cancel()
        flushTask = nil
        hitsDirty = false
        knownFingerprint = nil
        guard try LexiconFileIO.prepareDirectory(directory, create: false),
              let file = try LexiconFileIO.readFileWithFingerprint(fileURL, maxBytes: Self.maxFileBytes) else {
            isLoaded = true
            revision += 1
            return snapshot()
        }
        let data = file.data
        let decoder = Self.makeDecoder()
        guard let header = try? decoder.decode(VersionHeader.self, from: data) else { throw StoreError.malformed }
        // Version 0 or below never existed: that is a damaged file, not a newer one.
        guard header.version >= 1 else { throw StoreError.malformed }
        guard header.version <= Self.currentVersion else { throw StoreError.unsupportedVersion(header.version) }
        guard let document = try? decoder.decode(LenientDocument.self, from: data) else { throw StoreError.malformed }

        var kept: [LexiconTerm] = []
        var boundedCount = 0
        var dropped = 0
        for lenient in document.terms {
            guard var term = lenient.term,
                  term.source == .learned || term.source == .automaticallyLearned || boundedCount < LexiconLimits.maxTerms,
                  let cleaned = try? LexiconText.normalize(canonical: term.canonical, variants: term.variants,
                    allowSingleHanVariant: term.source == .automaticallyLearned) else {
                dropped += 1
                continue
            }
            term.canonical = cleaned.canonical
            term.variants = cleaned.variants
            kept.append(term)
            if term.source != .learned && term.source != .automaticallyLearned { boundedCount += 1 }
        }
        if dropped > 0 {
            try backUpBeforeDropping(data)
            RuntimeTrace.record("lexicon load dropped=\(dropped) kept=\(kept.count)")
        }
        terms = kept
        knownFingerprint = file.fingerprint
        isLoaded = true
        revision += 1
        // Keep pre-existing automatic entries intact; their use and new promotion are disabled.
        let now=Date()
        automaticAdditions=terms.filter { $0.source == .automaticallyLearned && now.timeIntervalSince($0.createdAt)>=0 && now.timeIntervalSince($0.createdAt)<3600 }.map(\.createdAt)
        if automaticAdditions.count>30,let last=automaticAdditions.max() { automaticPausedUntil=last.addingTimeInterval(3600) }
        return snapshot()
    }

    public func allTerms() -> [LexiconTerm] { terms }

    public struct LegacyAutoArchiveResult: Sendable {
        public let moved: Int
        public let kept: Int
    }

    /// Archive old automatic entries before removing them from the live lexicon. This
    /// operates only on this actor's loaded file; it never reads the user's defaults.
    /// A failed backup, archive, or commit leaves the original lexicon bytes unchanged.
    public func archiveLegacyAutomaticTerms(now: Date = Date()) throws -> LegacyAutoArchiveResult {
        try archiveLegacyAutomaticTerms(now: now, fileWriter: LexiconFileIO.writeAtomically)
    }

    /// Deterministic synthetic write-failure probe, unavailable to ordinary callers.
    @_spi(Testing) public func archiveLegacyAutoFailingCommitForTest(now: Date = Date()) throws -> LegacyAutoArchiveResult {
        try archiveLegacyAutomaticTerms(now: now, fileWriter: { _, _ in
            throw StoreError.unavailable("synthetic main-file write failure")
        })
    }

    private func archiveLegacyAutomaticTerms(
        now: Date, fileWriter: (Data, URL) throws -> Void
    ) throws -> LegacyAutoArchiveResult {
        try requireLoaded()
        let oldAuto = terms.filter { $0.source == .automaticallyLearned }
        let retained = terms.filter { $0.source != .automaticallyLearned }
        let result = LegacyAutoArchiveResult(moved: oldAuto.count, kept: retained.count)
        guard !oldAuto.isEmpty else { return result }

        try verifyUnchanged()
        guard let original = try LexiconFileIO.readFileWithFingerprint(fileURL, maxBytes: Self.maxFileBytes),
              original.fingerprint == knownFingerprint else {
            throw StoreError.changedOnDisk
        }

        // The original bytes, not a JSON re-encoding, are the reversible backup.
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let backupURL = directory.appendingPathComponent("backup-before-0.5.66-\(stamp).json")
        if let existing = try LexiconFileIO.readFile(backupURL, maxBytes: Self.maxFileBytes) {
            guard existing == original.data else { throw StoreError.unavailable("backup collision") }
        } else {
            try LexiconFileIO.writeAtomically(original.data, to: backupURL)
        }
        guard try LexiconFileIO.readFile(backupURL, maxBytes: Self.maxFileBytes) == original.data else {
            throw StoreError.unavailable("backup verification failed")
        }

        // Do not overwrite a previous archive: merge by stable entry ID. A corrupted
        // or incompatible archive blocks migration rather than losing older content.
        let archiveURL = directory.appendingPathComponent("auto-learned-archive.json")
        var archiveTerms: [LexiconTerm] = []
        if let previous = try LexiconFileIO.readFile(archiveURL, maxBytes: Self.maxFileBytes) {
            guard let decoded = try? Self.makeDecoder().decode(Document.self, from: previous),
                  decoded.version == Self.currentVersion else {
                throw StoreError.unavailable("existing archive unreadable")
            }
            archiveTerms = decoded.terms
        }
        var archivedIDs = Set(archiveTerms.map(\.id))
        for entry in oldAuto {
            if archivedIDs.contains(entry.id) {
                guard archiveTerms.first(where: { $0.id == entry.id }) == entry else {
                    throw StoreError.unavailable("archive entry conflict")
                }
            } else {
                archiveTerms.append(entry)
                archivedIDs.insert(entry.id)
            }
        }
        let encodedArchive = try Self.encode(archiveTerms)
        try LexiconFileIO.writeAtomically(encodedArchive, to: archiveURL)
        guard try LexiconFileIO.readFile(archiveURL, maxBytes: Self.maxFileBytes) == encodedArchive else {
            throw StoreError.unavailable("archive verification failed")
        }

        // commit() rechecks the source fingerprint and replaces it atomically.
        // On any error no migration-success marker can be written by the caller.
        try commit(retained, fileWriter: fileWriter)
        return result
    }

    public func snapshot() -> LexiconSnapshot { LexiconSnapshot(revision: revision, terms: terms) }

    /// Automatic entries stop after 30 days without an actual final-text replacement.
    /// Every expired entry is atomically merged into the durable archive BEFORE the live commit.
    /// If any archive read/write/verification or live commit fails, the live entry is retained.
    public func expireAutomaticTerms(now: Date = Date()) throws {
        try requireLoaded()
        let expired = terms.filter { term in
            guard term.source == .automaticallyLearned else { return false }
            let age = now.timeIntervalSince(term.lastHitAt ?? term.createdAt)
            return age.isFinite && age >= 30 * 86_400
        }
        guard !expired.isEmpty else { return }
        try verifyUnchanged()
        let archiveURL = directory.appendingPathComponent("auto-learned-archive.json")
        var entries: [LexiconTerm] = []
        if let old = try LexiconFileIO.readFile(archiveURL, maxBytes: Self.maxFileBytes) {
            guard let document = try? Self.makeDecoder().decode(Document.self, from: old),
                  document.version == Self.currentVersion else {
                throw StoreError.unavailable("archive unreadable")
            }
            entries = document.terms
        }
        var ids = Set(entries.map(\.id))
        for term in expired {
            if ids.contains(term.id) {
                guard entries.first(where: { $0.id == term.id }) == term else {
                    throw StoreError.unavailable("archive conflict")
                }
            } else {
                entries.append(term)
                ids.insert(term.id)
            }
        }
        let archived = try Self.encode(entries)
        try LexiconFileIO.writeAtomically(archived, to: archiveURL)
        guard try LexiconFileIO.readFile(archiveURL, maxBytes: Self.maxFileBytes) == archived else {
            throw StoreError.unavailable("archive verification")
        }
        let gone = Set(expired.map(\.id))
        try commit(terms.filter { !gone.contains($0.id) })
        RuntimeTrace.record("learn expire count=\(expired.count)")
    }

    // MARK: - Changing

    /// Adds an entry, or, when an entry with the same right spelling exists, adds the new wrong spellings
    /// to it. A wrong spelling belongs to exactly one entry: if another entry had it, it is moved here (the
    /// newest instruction wins) and `takenFrom` says from whom.
    @discardableResult
    public func add(
        canonical: String,
        variants: [String],
        source: LexiconSource = .manual,
        now: Date = Date(),
        learningSightings: Int = 0
    ) throws -> AddResult {
        try requireLoaded()
        let cleaned = try Self.validated(canonical: canonical, variants: variants)
        var next = terms
        let kind: AddResult.Kind
        let index: Int
        if let existing = next.firstIndex(where: { $0.canonical == cleaned.canonical }) {
            var merged = next[existing].variants
            var known = Set(merged.map(LexiconText.foldKey))
            for variant in cleaned.variants where known.insert(LexiconText.foldKey(variant)).inserted {
                merged.append(variant)
            }
            guard merged.count <= LexiconLimits.maxVariantsPerTerm else {
                throw StoreError.validation(.tooManyVariants)
            }
            next[existing].variants = merged
            next[existing].isEnabled = true
            if source == .learned, next[existing].source == .automaticallyLearned {
                next[existing].source = .learned
            }
            index = existing
            kind = .mergedIntoExisting
        } else {
            guard source == .learned || source == .automaticallyLearned || next.filter({ $0.source != .learned && $0.source != .automaticallyLearned }).count < LexiconLimits.maxTerms else {
                throw StoreError.validation(.tooManyTerms)
            }
            next.append(LexiconTerm(
                canonical: cleaned.canonical, variants: cleaned.variants, source: source, createdAt: now,
                learningSightings: learningSightings
            ))
            index = next.count - 1
            kind = .created
        }
        let takenFrom = Self.release(cleaned.variants, from: &next, except: index)
        let result = AddResult(term: next[index], kind: kind, takenFrom: takenFrom)
        guard next != terms else { return result }
        try commit(next)
        return result
    }

    /// Strict automatic promotions are ONLY accepted after the durable teacher index and
    /// candidate quota reservation. Never merge into or steal a variant from a human entry.
    /// This actor repeats the final 100-active and spelling-conflict checks at commit time.
    public func addStrictAutomaticallyLearned(
        _ pair: StrictLearningFilter.Pair, sightings: Int, at date: Date = Date(),
        permit: EnhancementLearningPermit, epoch: UInt64
    ) throws -> AddResult? {
        try requireLoaded()
        guard sightings >= 3,
              terms.filter({ $0.source == .automaticallyLearned }).count < 100 else { return nil }
        let cleaned = try Self.validated(canonical: pair.canonical, variants: [pair.variant],
                                        allowSingleHanVariant: true)
        guard cleaned.variants.count == 1,
              LexiconText.foldKey(cleaned.canonical) != LexiconText.foldKey(cleaned.variants[0]) else { return nil }
        let wrong = LexiconText.foldKey(cleaned.variants[0])
        let right = LexiconText.foldKey(cleaned.canonical)
        guard !terms.contains(where: {
            let canonical = LexiconText.foldKey($0.canonical)
            return canonical == right || canonical == wrong
                || $0.variants.contains(where: {
                    let spelling = LexiconText.foldKey($0)
                    return spelling == wrong || spelling == right
                })
        }) else { return nil }
        // The ordinary store's validated single-file atomic commit remains the only writer.
        let term = LexiconTerm(canonical: cleaned.canonical, variants: cleaned.variants,
            source: .automaticallyLearned, createdAt: date, learningSightings: sightings)
        // The permit is checked under its lock for the final file commit itself.
        // Revocation before this queued actor method reaches the commit means zero writes.
        return try permit.withAuthorization(epoch) {
            try commit(terms + [term])
            return AddResult(term: term, kind: .created, takenFrom: [])
        }
    }

    /// Legacy permissive promoter remains isolated from production by the closed app gate.
    /// It cannot merge into, enable, or take spellings from an existing/confirmed entry.
    public func addAutomaticallyLearned(_ promotion: EnhancementLearningPipeline.Promotion,
                                        permit: EnhancementLearningPermit, epoch: UInt64,
                                        now: Date = Date()) throws -> AddResult? {
        try requireLoaded()
        guard promotion.verified || promotion.sightings >= 2,
              !EnhancementLearningPipeline.conflicts(promotion.difference, terms: terms, confirmed: []),
              !TeacherLearningPolicy.isSensitive(promotion.difference.variant),
              !TeacherLearningPolicy.isSensitive(promotion.difference.canonical) else { return nil }
        automaticAdditions.removeAll { now.timeIntervalSince($0)<0 || now.timeIntervalSince($0)>=3600 }
        if let until=automaticPausedUntil,now<until { return nil }
        return try permit.withAuthorization(epoch) {
            let added = try add(canonical: promotion.difference.canonical, variants: promotion.hotwordOnly ? [] : [promotion.difference.variant],
                    source: .automaticallyLearned, now: now, learningSightings: promotion.sightings)
            automaticAdditions.append(now)
            if automaticAdditions.count>30 { automaticPausedUntil=now.addingTimeInterval(3600);RuntimeTrace.record("learn safety state=paused seconds=3600") }
            return added
        }
    }

    public enum HumanCorrectionResult: Sendable {
        case added(AddResult)
        case skipped(String)
    }

    /// Conflict check and variant transfer are one actor operation and one atomic file write.
    public func addHumanCorrection(canonical: String, variant: String, hotwordOnly: Bool,
                                   permit: EnhancementLearningPermit, epoch: UInt64) throws -> HumanCorrectionResult {
        try requireLoaded()
        if let reason = CorrectionLearner.conflict(variant: variant, canonical: canonical,
                                                  terms: terms, hotwordOnly: hotwordOnly) {
            return .skipped(reason)
        }
        if hotwordOnly, terms.contains(where: { LexiconText.foldKey($0.canonical) == LexiconText.foldKey(canonical) }) {
            return .skipped("alreadyPresent")
        }
        return try permit.withAuthorization(epoch) {
            .added(try add(canonical: canonical, variants: hotwordOnly ? [] : [variant], source: .learned))
        } ?? .skipped("disabled")
    }

    /// Undo removes only the learned variant. Other variants and unrelated terms are kept.
    public func undoHumanCorrection(termID: UUID, canonical: String, variant: String?) throws -> Bool {
        try requireLoaded()
        guard let index = terms.firstIndex(where: { $0.id == termID && $0.canonical == canonical }) else { return false }
        var next = terms
        if let variant {
            guard next[index].variants.contains(variant) else { return false }
            next[index].variants.removeAll { $0 == variant }
            if next[index].variants.isEmpty { next.remove(at: index) }
        } else {
            guard next[index].source == .learned || next[index].source == .automaticallyLearned,
                  next[index].variants.isEmpty else { return false }
            next.remove(at: index)
        }
        try commit(next)
        return true
    }

    /// Replaces an entry's right spelling, wrong spellings and switch.
    @discardableResult
    public func update(id: UUID, canonical: String, variants: [String], isEnabled: Bool) throws -> AddResult {
        try requireLoaded()
        guard let index = terms.firstIndex(where: { $0.id == id }) else {
            throw StoreError.validation(.termNotFound)
        }
        let cleaned = try Self.validated(canonical: canonical, variants: variants)
        if terms.contains(where: { $0.id != id && $0.canonical == cleaned.canonical }) {
            throw StoreError.validation(.duplicateCanonical(cleaned.canonical))
        }
        var next = terms
        next[index].canonical = cleaned.canonical
        next[index].variants = cleaned.variants
        next[index].isEnabled = isEnabled
        if next[index].source == .automaticallyLearned { next[index].source = .manual;next[index].learningSightings=0 }
        let takenFrom = Self.release(cleaned.variants, from: &next, except: index)
        let result = AddResult(term: next[index], kind: .mergedIntoExisting, takenFrom: takenFrom)
        guard next != terms else { return result }
        try commit(next)
        return result
    }

    public func setEnabled(id: UUID, _ enabled: Bool) throws {
        try requireLoaded()
        guard let index = terms.firstIndex(where: { $0.id == id }) else {
            throw StoreError.validation(.termNotFound)
        }
        guard terms[index].isEnabled != enabled else { return }
        var next = terms
        next[index].isEnabled = enabled
        try commit(next)
    }

    public func remove(id: UUID) throws {
        try requireLoaded()
        guard terms.contains(where: { $0.id == id }) else { throw StoreError.validation(.termNotFound) }
        try commit(terms.filter { $0.id != id })
    }

    public func removeAll() throws {
        try requireLoaded()
        guard !terms.isEmpty else { return }
        try commit([])
    }

    /// T12: Stop delayed writes and forget private state before the opaque directory moves to Trash.
    public func discardForDataRemoval() {
        flushTask?.cancel(); flushTask = nil; hitsDirty = false
        terms = []; isLoaded = false; knownFingerprint = nil; revision += 1
    }
    public func finishDataRemoval() throws {
        guard try LexiconFileIO.fingerprint(of: fileURL) == nil else { throw StoreError.changedOnDisk }
        isLoaded = true
    }

    /// Counts corrections the lexicon made. In memory at once, on disk after a short delay (or `flush()`);
    /// never changes what matches, so the revision stays.
    public func recordHits(_ counts: [UUID: Int], at date: Date = Date()) {
        guard isLoaded else { return }
        var changed = false
        for (id, count) in counts where count > 0 {
            guard let index = terms.firstIndex(where: { $0.id == id }) else { continue }
            // One dictation cannot correct thousands of times: a bad caller must not fill the counter at once.
            terms[index].hitCount = min(terms[index].hitCount + min(count, 10_000), LexiconLimits.maxHitCount)
            terms[index].lastHitAt = date
            changed = true
        }
        guard changed else { return }
        hitsDirty = true
        guard flushTask == nil else { return }
        let delay = hitFlushDelayNanoseconds
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await self?.flushAfterDelay()
        }
    }

    /// Writes pending hit counters now (settings closing, app quitting).
    public func flush() throws {
        flushTask?.cancel()
        flushTask = nil
        guard isLoaded, hitsDirty else { return }
        try verifyUnchanged()
        try LexiconFileIO.writeAtomically(try Self.encode(terms), to: fileURL)
        rememberFile()
        hitsDirty = false
    }

    // MARK: - Recovery

    /// For the person's explicit choice after `load()` reported `.malformed`: moves the unreadable file aside
    /// (byte for byte) and starts an empty lexicon. Refuses when the file reads fine, and never touches a
    /// symlink or a file that is not ours.
    @discardableResult
    public func recoverMalformed() throws -> URL {
        var readable = false
        do {
            guard let data = try LexiconFileIO.readFile(fileURL, maxBytes: Self.maxFileBytes) else {
                throw StoreError.unavailable("nothing to recover")
            }
            let decoder = Self.makeDecoder()
            if let header = try? decoder.decode(VersionHeader.self, from: data),
               header.version >= 1, header.version <= Self.currentVersion,
               (try? decoder.decode(LenientDocument.self, from: data)) != nil {
                readable = true
            }
        } catch StoreError.malformed {
            // Larger than any lexicon can be: certainly not one.
        }
        guard !readable else { throw StoreError.unavailable("the lexicon file is readable; recovery refused") }
        let name = "\(Self.fileName).broken-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let backup = try LexiconFileIO.moveAside(fileURL, as: name)
        flushTask?.cancel()
        flushTask = nil
        hitsDirty = false
        terms = []
        knownFingerprint = nil
        isLoaded = true
        revision += 1
        return backup
    }

    // MARK: - Internals

    private func flushAfterDelay() {
        flushTask = nil
        guard isLoaded, hitsDirty else { return }
        do {
            try verifyUnchanged()
            try LexiconFileIO.writeAtomically(try Self.encode(terms), to: fileURL)
            rememberFile()
            hitsDirty = false
        } catch StoreError.changedOnDisk {
            RuntimeTrace.record("lexicon hit flush skipped: file changed on disk")
        } catch {
            RuntimeTrace.record("lexicon hit flush failed")
        }
    }

    private func requireLoaded() throws {
        guard isLoaded else { throw StoreError.notLoaded }
    }

    /// Refuses to write over a file somebody else changed since this actor read or wrote it.
    private func verifyUnchanged() throws {
        guard try LexiconFileIO.fingerprint(of: fileURL) == knownFingerprint else { throw StoreError.changedOnDisk }
    }

    /// Notes the file as it is now, right after this actor wrote it. If it cannot be looked at, forgetting it
    /// makes the next write reload first, which is the safe direction.
    private func rememberFile() {
        knownFingerprint = try? LexiconFileIO.fingerprint(of: fileURL)
    }

    /// Keeps the file as it was before entries were dropped from memory. The copy is named after the file's
    /// content, so loading the same file again never writes a second one. If it cannot be written, the
    /// lexicon is not loaded at all (read-only): saving would replace the only copy of those entries.
    private func backUpBeforeDropping(_ data: Data) throws {
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent("\(Self.fileName).dropped-\(digest)")
        if try LexiconFileIO.lstatIfExists(target.path) != nil { return }
        do {
            try LexiconFileIO.writeAtomically(data, to: target)
        } catch {
            throw StoreError.unavailable("cannot back up the entries that would be dropped")
        }
    }

    /// Writes `next`, then makes it the current list.
    private func commit(
        _ next: [LexiconTerm],
        fileWriter: (Data, URL) throws -> Void = LexiconFileIO.writeAtomically
    ) throws {
        try verifyUnchanged()
        try fileWriter(try Self.encode(next), fileURL)
        rememberFile()
        terms = next
        hitsDirty = false
        revision += 1
    }

    private static func validated(
        canonical: String, variants: [String], allowSingleHanVariant: Bool = false
    ) throws -> (canonical: String, variants: [String]) {
        do {
            return try LexiconText.normalize(canonical: canonical, variants: variants,
                                             allowSingleHanVariant: allowSingleHanVariant)
        } catch let error as LexiconValidationError {
            throw StoreError.validation(error)
        }
    }

    /// Removes `variants` from every entry other than `except`. Returns the canonical spellings of the entries
    /// that lost one.
    private static func release(_ variants: [String], from terms: inout [LexiconTerm], except index: Int) -> [String] {
        let claimed = Set(variants.map(LexiconText.foldKey))
        guard !claimed.isEmpty else { return [] }
        var takenFrom: [String] = []
        for other in terms.indices where other != index {
            let remaining = terms[other].variants.filter { !claimed.contains(LexiconText.foldKey($0)) }
            if remaining.count != terms[other].variants.count {
                terms[other].variants = remaining
                takenFrom.append(terms[other].canonical)
            }
        }
        return takenFrom
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encode(_ terms: [LexiconTerm]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(Document(version: currentVersion, terms: terms))
        } catch {
            throw StoreError.unavailable("encode: \(error.localizedDescription)")
        }
    }
}
