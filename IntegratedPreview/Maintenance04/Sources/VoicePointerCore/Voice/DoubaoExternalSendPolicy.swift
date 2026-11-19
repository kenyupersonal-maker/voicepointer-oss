import Foundation

/// Conservative Doubao external-IME Send decision. The two snapshots are editor values,
/// never microphone amplitudes. Deadlines are measured from the original gesture release.
public enum DoubaoExternalSendPolicy {
    public static let firstSampleMilliseconds = 270
    public static let unchangedSendMilliseconds = 600
    public static let emptySpeechTimeoutMilliseconds = 3_000

    public enum FirstSampleDecision: Equatable, Sendable {
        case unchangedNonempty
        case waitForSpeechText
        case emptyUnchanged
        case useOriginalSettle
    }

    public static func decide(
        original: String?, firstAfterRelease: String?,
        originalWasEmpty: Bool, firstIsEmpty: Bool,
        heard: SpeechHeard
    ) -> FirstSampleDecision {
        guard let original, let firstAfterRelease else { return .useOriginalSettle }
        // Different AX representations of an empty editor do not count as landed text.
        if originalWasEmpty && firstIsEmpty {
            return heard == .speech ? .waitForSpeechText : .emptyUnchanged
        }
        guard firstAfterRelease == original else { return .useOriginalSettle }
        if !originalWasEmpty && !firstIsEmpty { return .unchangedNonempty }
        return heard == .speech ? .waitForSpeechText : .emptyUnchanged
    }

    public static func maySendUnchanged(
        decision: FirstSampleDecision, elapsedMilliseconds: Int,
        stillUnchanged: Bool
    ) -> Bool {
        (decision == .unchangedNonempty || decision == .emptyUnchanged) && elapsedMilliseconds >= unchangedSendMilliseconds
            && stillUnchanged
    }

    public static func isEmptySpeechTimeout(
        decision: FirstSampleDecision, elapsedMilliseconds: Int,
        textLanded: Bool
    ) -> Bool {
        decision == .waitForSpeechText && !textLanded
            && elapsedMilliseconds >= emptySpeechTimeoutMilliseconds
    }
}
