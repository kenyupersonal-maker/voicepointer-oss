import Foundation

/// What to make of the way the person changed one dictation: the lexicon rules it may stand for, and the
/// entries they changed back.
///
/// Pure. It never touches the field or the lexicon; it is given the dictation as it was delivered
/// (`DictationRecord`), the dictation as it reads now, the whole field as it reads now and the lexicon's
/// entries, and answers with candidates. A change becomes a candidate only when every step agrees:
/// - it is one of at most two separate fixes (`CorrectionHunks`);
/// - a rule can be derived from it, the wrong spelling is in the recognizer's own text and the rule would fire
///   there (`DictationRecord.suggestion`);
/// - the pair sounds alike and is not a change of meaning (`CorrectionPlausibility`);
/// - the lexicon has nothing to say about it: the wrong spelling is not already an entry's (switched off or
///   not), not an entry's right spelling, and the new right spelling is not another entry's wrong one;
/// - the person did not keep the wrong spelling somewhere else in the field.
public enum CorrectionLearner {
    public struct Candidate: Equatable, Sendable {
        public let variant: String
        public let canonical: String
        public let confidence: CorrectionPlausibility.Confidence

        public init(variant: String, canonical: String, confidence: CorrectionPlausibility.Confidence) {
            self.variant = variant
            self.canonical = canonical
            self.confidence = confidence
        }
    }

    public enum Kind: String, Sendable, Equatable {
        case unchanged
        case edgeOnly
        case rewrite
        case evaluated
    }

    public struct Outcome: Equatable, Sendable {
        public var kind: Kind = .unchanged
        public var candidates: [Candidate] = []
        /// Lexicon entries whose correction the person changed back by hand.
        public var revertedTermIDs: [UUID] = []
        /// Why fixes were not kept, by reason. Counts only: this is what the log gets.
        public var rejections: [String: Int] = [:]

        public init() {}

        /// `reason:count,reason:count` in a stable order, for the log.
        public var rejectionSummary: String {
            rejections.keys.sorted().map { "\($0):\(rejections[$0] ?? 0)" }.joined(separator: ",")
        }

        fileprivate mutating func reject(_ reason: String) {
            rejections[reason, default: 0] += 1
        }
    }

    /// Time allowed for checking the rule against the whole field.
    public static let fieldCheckBudgetNanoseconds: UInt64 = 50_000_000

    public static func evaluate(
        record: DictationRecord,
        editedDictation: String,
        finalDocument: String,
        terms: [LexiconTerm],
        ordinaryEnglishWords: Set<String> = []
    ) -> Outcome {
        var outcome = Outcome()
        switch CorrectionHunks.split(delivered: record.text, edited: editedDictation) {
        case .unchanged:
            outcome.kind = .unchanged
        case .edgeOnly:
            outcome.kind = .edgeOnly
        case .rewrite:
            outcome.kind = .rewrite
        case .fixes(let fixes):
            outcome.kind = .evaluated
            for fix in fixes {
                consider(fix, record: record, finalDocument: finalDocument, terms: terms,
                         ordinaryEnglishWords: ordinaryEnglishWords, into: &outcome)
            }
        }
        return outcome
    }

    private static func consider(
        _ fix: CorrectionHunks.Fix,
        record: DictationRecord,
        finalDocument: String,
        terms: [LexiconTerm],
        ordinaryEnglishWords: Set<String>,
        into outcome: inout Outcome
    ) {
        let suggestion: CorrectionDiff.Suggestion
        switch record.suggestion(afterEditingTo: fix.editedText) {
        case .failure(let rejection):
            outcome.reject("diff.\(label(rejection))")
            if rejection == .alreadyCorrected {
                for id in revertedTerms(fix, record: record) where !outcome.revertedTermIDs.contains(id) {
                    outcome.revertedTermIDs.append(id)
                }
            }
            return
        case .success(let derived):
            suggestion = derived
        }

        let confidence: CorrectionPlausibility.Confidence
        switch CorrectionPlausibility.judge(variant: suggestion.variant, canonical: suggestion.canonical) {
        case .reject(let reason):
            outcome.reject("judge.\(reason.rawValue)")
            return
        case .accept(let judged):
            confidence = judged
        }

        let hotwordOnly = ordinaryEnglishWords.contains(suggestion.variant.lowercased())
        if let conflict = conflict(variant: suggestion.variant, canonical: suggestion.canonical,
                                   terms: terms, hotwordOnly: hotwordOnly) {
            outcome.reject("lexicon.\(conflict)")
            return
        }

        // A one-rule matcher must leave the field as it is: if it would change something, the person kept the
        // wrong spelling somewhere (the other occurrence they did not fix, a word they typed themselves).
        let probe = LexiconSnapshot(
            revision: 0,
            terms: [LexiconTerm(canonical: suggestion.canonical, variants: hotwordOnly ? [] : [suggestion.variant])]
        )
        guard let applied = probe.apply(to: finalDocument, budgetNanoseconds: fieldCheckBudgetNanoseconds) else {
            outcome.reject("field.unchecked")
            return
        }
        if applied.changed {
            outcome.reject("field.keptElsewhere")
            return
        }

        let key = LexiconText.foldKey(suggestion.variant)
        guard !outcome.candidates.contains(where: {
            LexiconText.foldKey($0.variant) == key && $0.canonical == suggestion.canonical
        }) else { return }
        outcome.candidates.append(
            Candidate(variant: suggestion.variant, canonical: suggestion.canonical, confidence: confidence)
        )
    }

    /// The lexicon already has an opinion on this wrong spelling or right spelling (a short label; nil when
    /// it has none). Also asked when the person accepts a suggestion, because the lexicon may have changed
    /// since it was made. An entry the person switched off counts: their choice is not undone from here.
    public static func conflict(variant: String, canonical: String, terms: [LexiconTerm],
                                hotwordOnly: Bool = false) -> String? {
        let variantKey = LexiconText.foldKey(variant)
        let canonicalKey = LexiconText.foldKey(canonical)
        for term in terms {
            // A person's correction may take a spelling back from recognizer-only learning.
            if !hotwordOnly, term.source != .automaticallyLearned,
               term.variants.contains(where: { LexiconText.foldKey($0) == variantKey }) { return "variantOwned" }
            if !hotwordOnly, LexiconText.foldKey(term.canonical) == variantKey { return "variantIsCanonical" }
            if term.variants.contains(where: { LexiconText.foldKey($0) == canonicalKey }) { return "canonicalIsVariant" }
            if !term.isEnabled, LexiconText.foldKey(term.canonical) == canonicalKey { return "canonicalSwitchedOff" }
        }
        return nil
    }

    /// The person put back what the recognizer wrote where the lexicon had corrected it: the fix's before-side
    /// holds a hit's right spelling and its after-side holds the hit's wrong one.
    private static func revertedTerms(_ fix: CorrectionHunks.Fix, record: DictationRecord) -> [UUID] {
        guard !record.hits.isEmpty,
              case .success(let derived) = CorrectionDiff.derive(before: record.text, after: fix.editedText) else {
            return []
        }
        let before = LexiconText.foldKey(derived.variant)
        let after = LexiconText.foldKey(derived.canonical)
        return record.hits.filter { hit in
            before.contains(LexiconText.foldKey(hit.canonical)) && after.contains(LexiconText.foldKey(hit.matched))
        }.map(\.termID)
    }

    private static func label(_ rejection: CorrectionDiff.Rejection) -> String {
        switch rejection {
        case .unchanged: return "unchanged"
        case .notASpelling: return "notASpelling"
        case .tooLarge: return "tooLarge"
        case .alreadyCorrected: return "alreadyCorrected"
        case .wouldNotMatch: return "wouldNotMatch"
        }
    }
}
