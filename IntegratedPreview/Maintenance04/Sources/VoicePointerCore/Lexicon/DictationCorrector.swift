import Foundation

/// The personal lexicon as the dictation path uses it: one per dictation, made from the matcher that was
/// current when the dictation began, so every partial and the final text of that dictation are corrected by
/// the same rules.
///
/// Only recognizers that hand the app their text are corrected (`VoiceInputMode.voiceNative`). The Doubao
/// keyboard route inserts its text itself and the app never sees it, so there is nothing to rewrite.
public struct DictationCorrector: Sendable {
    public static let none = DictationCorrector(lexicon: nil)

    public let lexicon: LexiconSnapshot

    public init(lexicon: LexiconSnapshot?) {
        self.lexicon = lexicon ?? .empty
    }

    /// True when correcting can change anything.
    public var isActive: Bool { !lexicon.isEmpty }

    /// Match the untouched recognizer final once, with human rules first. A second scan
    /// of human-corrected text could wrongly reinterpret a person's canonical spelling.
    public func finalApplication(
        raw: String, mode: VoiceInputMode, source: SpeechTranscriptSource?
    ) -> LexiconSnapshot.Application? {
        guard mode == .voiceNative, isActive,
              let applied = lexicon.apply(to: raw) else { return nil }
        if source == .cloudEnhancement, raw != applied.text,
           case .rejected = HybridProjectionGuard.check(raw: raw, projected: applied.text) {
            return LexiconSnapshot.Application(text: raw, hits: [])
        }
        return applied
    }

    /// `text` with the lexicon applied, or unchanged (and no hits) when the route is not corrected, the
    /// lexicon is empty or the work would exceed its time budget.
    public func correct(
        _ text: String, mode: VoiceInputMode, includeAutomatic: Bool = true
    ) -> (text: String, hits: [LexiconSnapshot.Hit]) {
        guard mode == .voiceNative, isActive else { return (text, []) }
        guard let application = lexicon.apply(to: text, includeAutomatic: includeAutomatic) else {
            RuntimeTrace.record("lexicon skipped reason=budget")
            return (text, [])
        }
        return (application.text, application.hits)
    }

    /// The same, for a recognizer event: only its text changes; session, sequence, timing and kind stay.
    public func correct(
        _ event: SpeechInputEvent, mode: VoiceInputMode, afterRelease: Bool = false
    ) -> (event: SpeechInputEvent, hits: [LexiconSnapshot.Hit]) {
        guard let text = event.text else { return (event, []) }
        let isFinal: Bool
        switch event.kind {
        case .final: isFinal = true
        default: isFinal = false
        }
        // A recognizer can emit .final before the user lets go. Only the actual
        // release state grants the machine-learned replacements a chance to run.
        let corrected = correct(text, mode: mode, includeAutomatic: isFinal && afterRelease)
        guard corrected.text != text else { return (event, corrected.hits) }
        return (event.replacingText(corrected.text), corrected.hits)
    }
}
