import Foundation

public enum InlineDraftUpdateOutcome: Sendable, Equatable {
    case updated, unchanged, unsupported, abandoned, unconfirmed
    /// Paste was submitted; a later update may proceed only after locating a submitted sentence version.
    case pending
}

public protocol InlineTranscriptDelivering: TranscriptDelivering {
    func updateDraft(text: String, sequence: UInt64, session: ComposerActionSession?) async -> InlineDraftUpdateOutcome
}
