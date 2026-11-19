import Foundation

/// One finished dictation on a recognizer route that hands the app the text (never the Doubao keyboard
/// route, where the app does not see the text). Held in memory only, so the person can turn "it heard this,
/// I meant that" into a lexicon entry; nothing here is written to disk.
public struct DictationRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    /// As the recognizer wrote it.
    public let rawText: String
    /// As it went to the target field: the personal lexicon applied.
    public let text: String
    public let hits: [LexiconSnapshot.Hit]
    public let routeID: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        rawText: String,
        text: String,
        hits: [LexiconSnapshot.Hit],
        routeID: String
    ) {
        self.id = id
        self.date = date
        self.rawText = rawText
        self.text = text
        self.hits = hits
        self.routeID = routeID
    }
}

extension DictationRecord {
    /// The lexicon rule the person's edit of this dictation stands for. The wrong spelling must occur in the
    /// recognizer's own text, because that is what the lexicon matches on; text the lexicon already corrected
    /// is not there. And the rule must actually fire on that text: a one-entry lexicon is applied to it, so a
    /// rule that word edges or an already-correct spelling around it would stop never reaches the person.
    public func suggestion(
        afterEditingTo edited: String
    ) -> Result<CorrectionDiff.Suggestion, CorrectionDiff.Rejection> {
        switch CorrectionDiff.derive(before: text, after: edited) {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let suggestion):
            guard LexiconText.foldKey(rawText).contains(LexiconText.foldKey(suggestion.variant)) else {
                return .failure(.alreadyCorrected)
            }
            let probe = LexiconSnapshot(
                revision: 0,
                terms: [LexiconTerm(canonical: suggestion.canonical, variants: [suggestion.variant])]
            )
            guard let applied = probe.apply(to: rawText, budgetNanoseconds: 1_000_000_000), applied.changed else {
                return .failure(.wouldNotMatch)
            }
            return .success(suggestion)
        }
    }
}

extension SpeechInputEvent {
    /// The same event with other text: the recognizer's words after the personal lexicon has been applied.
    /// The source stays: which recognizer heard the words does not change when the lexicon rewrites them.
    func replacingText(_ text: String?) -> SpeechInputEvent {
        SpeechInputEvent(
            sessionID: sessionID, sequence: sequence, observedMilliseconds: observedMilliseconds,
            kind: kind, text: text, errorCode: errorCode, transcriptSource: transcriptSource
        )
    }
}
