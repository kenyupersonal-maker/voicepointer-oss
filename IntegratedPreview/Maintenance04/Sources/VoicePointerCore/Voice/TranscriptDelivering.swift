import Foundation

/// Delivers a finalized transcript into the focused composer using the native
/// paste/undo transaction defined by the I04E card.
public protocol TranscriptDelivering: Sendable {
    func deliver(
        text: String,
        action: VoiceReleaseAction,
        session: ComposerActionSession?
    ) async -> ComposerActionOutcome
}

