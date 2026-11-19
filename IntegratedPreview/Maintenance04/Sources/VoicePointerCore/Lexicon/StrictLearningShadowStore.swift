import Foundation

/// Durable R5 observation-only results, next to lexicon.json. No teacher sentence, audio,
/// clipboard, app name, identifier or authorization token may enter this document.
public actor StrictLearningShadowStore {
    public enum Failure: Error, Sendable {
        case malformed
        case changedOnDisk
        case unavailable
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let variant: String
        public let canonical: String
        public let sightings: Int
        public let dates: [String]
        public let wouldPromoteAt: Date

        public var pair: StrictLearningFilter.Pair {
            StrictLearningFilter.Pair(variant: variant, canonical: canonical)
        }
    }

    private struct Document: Codable {
        let version: Int
        let entries: [Entry]
    }

    public nonisolated let directory: URL
    private var entries: [Entry] = []
    private var fingerprint: LexiconFileIO.Fingerprint?
    private var opened = false
    private static let maximumBytes = 2 * 1024 * 1024
    private static let maximumEntries = 500

    public init(directory: URL = LexiconStore.defaultDirectory) {
        self.directory = directory
    }

    public nonisolated var fileURL: URL {
        directory.appendingPathComponent("strict-learning-shadow.json")
    }

    private func open() throws {
        guard !opened else { return }
        if let file = try LexiconFileIO.readFileWithFingerprint(fileURL, maxBytes: Self.maximumBytes) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let document = try? decoder.decode(Document.self, from: file.data),
                  document.version == 1,
                  document.entries.count <= Self.maximumEntries,
                  document.entries.allSatisfy({
                      !$0.variant.isEmpty && !$0.canonical.isEmpty &&
                      $0.sightings >= 3 && Set($0.dates).count >= 2 &&
                      $0.dates.count <= 366 && $0.variant.utf8.count <= 1_024 &&
                      $0.canonical.utf8.count <= 1_024
                  }),
                  Set(document.entries.map {
                      LexiconText.foldKey($0.variant) + "\u{1F}" + LexiconText.foldKey($0.canonical)
                  }).count == document.entries.count else {
                throw Failure.malformed
            }
            entries = document.entries
            fingerprint = file.fingerprint
        }
        opened = true
    }

    private func save(_ replacement: [Entry]) throws {
        guard replacement.count <= Self.maximumEntries else { throw Failure.unavailable }
        guard try LexiconFileIO.fingerprint(of: fileURL) == fingerprint else {
            throw Failure.changedOnDisk
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Document(version: 1, entries: replacement))
        guard bytes.count <= Self.maximumBytes else { throw Failure.unavailable }
        try LexiconFileIO.writeAtomically(bytes, to: fileURL)
        fingerprint = try LexiconFileIO.fingerprint(of: fileURL)
        entries = replacement
    }

    /// A would-promote reservation came from the ledger's 3 sightings / 2 dates gate.
    /// Permission is held continuously through the final atomic shadow-file write.
    @discardableResult
    public func record(
        _ promotion: StrictLearningLedger.Promotion, at date: Date,
        permit: EnhancementLearningPermit, epoch: UInt64
    ) throws -> Bool {
        try permit.withAuthorization(epoch) {
            try open()
            guard promotion.sightings >= 3, Set(promotion.dates).count >= 2,
                  !promotion.pair.variant.isEmpty, !promotion.pair.canonical.isEmpty else {
                return false
            }
            if entries.contains(where: { $0.pair == promotion.pair }) { return true }
            let entry = Entry(variant: promotion.pair.variant,
                              canonical: promotion.pair.canonical,
                              sightings: promotion.sightings, dates: promotion.dates,
                              wouldPromoteAt: date)
            try save(entries + [entry])
            return true
        } ?? false
    }

    /// A revoked authorization cannot read candidates for live import either.
    public func pending(
        permit: EnhancementLearningPermit, epoch: UInt64
    ) throws -> [Entry]? {
        try permit.withAuthorization(epoch) {
            try open()
            return entries.sorted { $0.wouldPromoteAt < $1.wouldPromoteAt }
        }
    }

    /// Remove only after a successful *real* lexicon commit. A failed removal
    /// conservatively leaves the shadow row; live-term conflicts block a second import.
    @discardableResult
    public func remove(
        _ pair: StrictLearningFilter.Pair, permit: EnhancementLearningPermit, epoch: UInt64
    ) throws -> Bool {
        try permit.withAuthorization(epoch) {
            try open()
            let retained = entries.filter { $0.pair != pair }
            if retained.count != entries.count { try save(retained) }
            return true
        } ?? false
    }
}
