import Foundation

/// The corrections the person has been seen making, waiting for a decision. Memory only: what the person
/// changed in their own messages is not written to disk before they say they want a rule out of it.
///
/// One entry per pair (wrong spelling with ASCII case folded, right spelling exactly). A dictation counts once
/// however many times the same pair turns up in it. The list is short, the least recently seen entry goes
/// first when it is full, and entries not seen for a week go by themselves.
public struct CorrectionLedger: Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let variant: String
        public let canonical: String
        /// The best the pair has been rated so far.
        public fileprivate(set) var confidence: CorrectionPlausibility.Confidence
        /// In how many different dictations the pair was seen.
        public fileprivate(set) var sightings: Int
        public let firstSeen: Date
        public fileprivate(set) var lastSeen: Date
        fileprivate var dictationIDs: Set<UUID>

        fileprivate init(
            variant: String,
            canonical: String,
            confidence: CorrectionPlausibility.Confidence,
            dictationID: UUID,
            now: Date
        ) {
            self.id = UUID()
            self.variant = variant
            self.canonical = canonical
            self.confidence = confidence
            self.sightings = 1
            self.firstSeen = now
            self.lastSeen = now
            self.dictationIDs = [dictationID]
        }
    }

    public static let maximumEntries = 30
    public static let lifetime: TimeInterval = 7 * 24 * 3_600

    /// Most recently seen first.
    public private(set) var entries: [Entry] = []
    private var dismissed: Set<String> = []

    public init() {}

    private static func key(variant: String, canonical: String) -> String {
        LexiconText.foldKey(variant) + "\u{1F}" + canonical
    }

    /// Records the pairs one dictation's edit stood for. Returns how many entries were created or seen in a
    /// new dictation; pairs the person dismissed are ignored.
    @discardableResult
    public mutating func note(_ candidates: [CorrectionLearner.Candidate], dictationID: UUID, now: Date) -> Int {
        prune(now: now)
        var touched = 0
        for candidate in candidates {
            let key = Self.key(variant: candidate.variant, canonical: candidate.canonical)
            if dismissed.contains(key) { continue }
            if let index = entries.firstIndex(where: { Self.key(variant: $0.variant, canonical: $0.canonical) == key }) {
                var entry = entries.remove(at: index)
                if entry.dictationIDs.insert(dictationID).inserted {
                    entry.sightings += 1
                    touched += 1
                }
                if candidate.confidence == .strong { entry.confidence = .strong }
                entry.lastSeen = now
                entries.insert(entry, at: 0)
            } else {
                entries.insert(
                    Entry(
                        variant: candidate.variant,
                        canonical: candidate.canonical,
                        confidence: candidate.confidence,
                        dictationID: dictationID,
                        now: now
                    ),
                    at: 0
                )
                touched += 1
            }
        }
        if entries.count > Self.maximumEntries { entries.removeLast(entries.count - Self.maximumEntries) }
        return touched
    }

    /// The person does not want this pair suggested again (until the app is quit).
    public mutating func dismiss(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        dismissed.insert(Self.key(variant: entries[index].variant, canonical: entries[index].canonical))
        entries.remove(at: index)
    }

    /// The pair became a lexicon entry, or is gone for another reason; it is not remembered as dismissed.
    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Forgets everything: the person turned learning off.
    public mutating func removeAll() {
        entries = []
        dismissed = []
    }

    public mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.lastSeen) > Self.lifetime }
    }
}
