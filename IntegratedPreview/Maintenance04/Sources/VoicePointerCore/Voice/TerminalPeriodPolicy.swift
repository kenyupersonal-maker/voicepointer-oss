import Foundation

public enum TerminalPeriodPolicy {
    /// A previous sentence's punctuation is restored only when this sentence has words.
    public static func sentence(_ text: String, prefix: String, enabled: Bool = true) -> (text: String, removed: String?) {
        let formatted = format(text, enabled: enabled)
        return (formatted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : prefix + formatted.text, formatted.removed)
    }
    public static func format(_ text: String, enabled: Bool = true) -> (text: String, removed: String?) {
        guard enabled else { return (text, nil) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, last == "。" || last == "." else { return (trimmed, nil) }
        guard !trimmed.hasSuffix("。。"), !trimmed.hasSuffix("..."), !trimmed.hasSuffix("……") else { return (trimmed, nil) }
        if last == "." {
            let word = trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? trimmed
            if word.dropLast().contains(".") { return (trimmed, nil) }
        }
        return (String(trimmed.dropLast()), String(last))
    }
    public static func event(_ event: SpeechInputEvent, text: String) -> SpeechInputEvent {
        .init(sessionID: event.sessionID, sequence: event.sequence, observedMilliseconds: event.observedMilliseconds,
              kind: event.kind, text: text, errorCode: event.errorCode, transcriptSource: event.transcriptSource,
              modelConfidence: event.modelConfidence, confidenceEvidence: event.confidenceEvidence)
    }
}
