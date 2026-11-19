import Foundation

/// An immutable, ready-to-match copy of the enabled lexicon entries.
///
/// Matching rules, all of them chosen so a correction is predictable to read in the settings page:
/// - A wrong spelling matches exactly, except that ASCII letters ignore case.
/// - At each position the longest matching spelling wins; matches never overlap.
/// - A spelling that starts or ends with an ASCII letter or digit only matches at a word edge, so "ai" never
///   fires inside "said". Chinese has no word edges to check; the minimum of two letters or digits in a
///   variant is what keeps it from firing inside ordinary words.
/// - Corrections are computed from the recognizer's own text only, never from an earlier correction, so
///   entries cannot chain ("a→b" and "b→c" never turn a into c).
/// - Text that already reads as the canonical spelling around a match is left alone, so the entry
///   "深圳 → 深圳市" does not turn "深圳市" into "深圳市市". Ignoring ASCII case, unless the two spellings are
///   the same length (a pure case fix such as "iphone → iPhone" must still fire): "copilot → GitHub Copilot"
///   leaves "GitHub copilot" as it is instead of making "GitHub GitHub Copilot".
public struct LexiconSnapshot: Sendable {
    public static let empty = LexiconSnapshot(revision: 0, terms: [])
    /// Wall-clock budget of one `apply`; a correction that would take longer is skipped, not delayed.
    public static let defaultBudgetNanoseconds: UInt64 = 15_000_000
    /// Longer text is left alone: no dictation is that long, and the matcher's cost grows with it.
    public static let maximumTextUTF8 = 60_000

    public struct Hit: Sendable, Equatable {
        public let termID: UUID
        /// The text as the recognizer wrote it.
        public let matched: String
        public let canonical: String
    }

    public struct Application: Sendable, Equatable {
        public let text: String
        public let hits: [Hit]
        public var changed: Bool { !hits.isEmpty }
    }

    private struct Rule: Sendable {
        let termID: UUID
        let automaticallyLearned: Bool
        let folded: [Character]
        let canonical: [Character]
        let foldedCanonical: [Character]
        let canonicalText: String
        let needsWordEdgeBefore: Bool
        let needsWordEdgeAfter: Bool
        /// Offsets inside the canonical spelling where this wrong spelling also occurs.
        let containedAt: [Int]
        /// The wrong spelling is the right one apart from ASCII case: the fix is the case itself.
        let caseFixOnly: Bool
    }

    public let revision: Int
    public let ruleCount: Int
    public var isEmpty: Bool { ruleCount == 0 }
    private let buckets: [Character: [Rule]]

    /// Builds the matcher from `terms` (disabled entries and plain hot words contribute nothing). When two
    /// entries claim the same spelling the earlier one in `terms` keeps it.
    public init(revision: Int, terms: [LexiconTerm]) {
        var seen = Set<String>()
        var buckets: [Character: [Rule]] = [:]
        var count = 0
        // Preserve human ownership of overlapping spellings regardless of storage order.
        let ordered = terms.filter { $0.isEnabled && $0.source != .automaticallyLearned }
            + terms.filter { $0.isEnabled && $0.source == .automaticallyLearned }
        for term in ordered {
            let canonical = Array(term.canonical)
            guard !canonical.isEmpty else { continue }
            for variant in term.variants where variant != term.canonical {
                let folded = variant.map(LexiconText.fold)
                let strictSingleHan = term.source == .automaticallyLearned
                    && folded.count == 1 && folded.allSatisfy(LexiconText.isHan)
                guard (LexiconText.significantCount(folded) >= LexiconLimits.minVariantCharacters || strictSingleHan),
                      seen.insert(String(folded)).inserted else { continue }
                let rule = Rule(
                    termID: term.id,
                    automaticallyLearned: term.source == .automaticallyLearned,
                    folded: folded,
                    canonical: canonical,
                    foldedCanonical: canonical.map(LexiconText.fold),
                    canonicalText: term.canonical,
                    needsWordEdgeBefore: LexiconText.isASCIIWordCharacter(folded[0]),
                    needsWordEdgeAfter: LexiconText.isASCIIWordCharacter(folded[folded.count - 1]),
                    containedAt: Self.offsets(of: folded, in: canonical),
                    caseFixOnly: folded.count == canonical.count
                )
                buckets[folded[0], default: []].append(rule)
                count += 1
            }
        }
        for key in Array(buckets.keys) {
            buckets[key]?.sort {
                if $0.automaticallyLearned != $1.automaticallyLearned {
                    return !$0.automaticallyLearned
                }
                return $0.folded.count > $1.folded.count
            }
        }
        self.revision = revision
        self.ruleCount = count
        self.buckets = buckets
    }

    /// Applies every matching entry to `text`. Returns nil when the text is too long or the work would exceed
    /// `budgetNanoseconds`; the caller then keeps the recognizer's text, which is always a safe answer.
    public func apply(
        to text: String,
        budgetNanoseconds: UInt64 = LexiconSnapshot.defaultBudgetNanoseconds,
        includeAutomatic: Bool = true,
        includeHuman: Bool = true
    ) -> Application? {
        guard ruleCount > 0, !text.isEmpty else { return Application(text: text, hits: []) }
        guard text.utf8.count <= Self.maximumTextUTF8 else { return nil }
        let characters = Array(text)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ budgetNanoseconds
        var output = ""
        output.reserveCapacity(text.utf8.count + 16)
        var hits: [Hit] = []
        var index = 0
        var copied = 0
        var steps = 0
        while index < characters.count {
            steps &+= 1
            if steps & 0xFF == 0, DispatchTime.now().uptimeNanoseconds > deadline { return nil }
            guard let candidates = buckets[LexiconText.fold(characters[index])] else {
                index += 1
                continue
            }
            var matched: Rule?
            for rule in candidates where (includeAutomatic || !rule.automaticallyLearned)
                && (includeHuman || rule.automaticallyLearned)
                && Self.matches(rule, in: characters, at: index) {
                matched = rule
                break
            }
            guard let rule = matched else {
                index += 1
                continue
            }
            output.append(contentsOf: characters[copied..<index])
            output.append(rule.canonicalText)
            hits.append(Hit(
                termID: rule.termID,
                matched: String(characters[index..<(index + rule.folded.count)]),
                canonical: rule.canonicalText
            ))
            index += rule.folded.count
            copied = index
        }
        guard !hits.isEmpty else { return Application(text: text, hits: []) }
        output.append(contentsOf: characters[copied...])
        return Application(text: output, hits: hits)
    }

    private static func matches(_ rule: Rule, in characters: [Character], at index: Int) -> Bool {
        let length = rule.folded.count
        guard index + length <= characters.count else { return false }
        var offset = 0
        while offset < length {
            if LexiconText.fold(characters[index + offset]) != rule.folded[offset] { return false }
            offset += 1
        }
        if rule.needsWordEdgeBefore, index > 0, LexiconText.isASCIIWordCharacter(characters[index - 1]) {
            return false
        }
        if rule.needsWordEdgeAfter, index + length < characters.count,
           LexiconText.isASCIIWordCharacter(characters[index + length]) {
            return false
        }
        // Already reads as the canonical spelling around this match: leave it. A case fix compares exactly
        // (the wrong spelling only differs in case, so a looser test would never let it fire); a wrong
        // spelling that is part of a longer right one also counts when only the case of the rest differs.
        for contained in rule.containedAt {
            let start = index - contained
            let end = start + rule.canonical.count
            guard start >= 0, end <= characters.count else { continue }
            if rule.caseFixOnly {
                if characters[start..<end].elementsEqual(rule.canonical) { return false }
            } else {
                var offset = 0
                while offset < rule.canonical.count,
                      LexiconText.fold(characters[start + offset]) == rule.foldedCanonical[offset] {
                    offset += 1
                }
                if offset == rule.canonical.count { return false }
            }
        }
        return true
    }

    private static func offsets(of folded: [Character], in canonical: [Character]) -> [Int] {
        guard folded.count <= canonical.count else { return [] }
        var result: [Int] = []
        for start in 0...(canonical.count - folded.count) {
            var equal = true
            for offset in 0..<folded.count where LexiconText.fold(canonical[start + offset]) != folded[offset] {
                equal = false
                break
            }
            if equal { result.append(start) }
        }
        return result
    }
}
