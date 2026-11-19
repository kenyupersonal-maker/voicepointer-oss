import Foundation

/// User-facing result metadata shared by Coordinator and HUD.
public struct ComposerActionFeedback: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case success
        case info
        case warning
    }

    public let message: String
    public let kind: Kind
    /// Whether this result needs a second, textual HUD announcement.
    /// Existing successful/empty states already have an observable outcome
    /// (or are already represented by the idle state), so they stay silent.
    public let shouldPresent: Bool
    public let presentation: VoiceIssuePresentation?

    /// Toast outcomes are announced by the Coordinator status callback.
    /// Gesture hints stay with the completion callback.
    public var statusChannelOwnsToast: Bool {
        shouldPresent && presentation?.disposition == .toast
    }

    public init(message: String, kind: Kind, shouldPresent: Bool = true) {
        self.message = message
        self.kind = kind
        self.shouldPresent = shouldPresent
        self.presentation = nil
    }

    private init(presentation: VoiceIssuePresentation, shouldPresent: Bool? = nil) {
        self.message = presentation.message
        switch presentation.tone {
        case .success: self.kind = .success
        case .info: self.kind = .info
        case .warning: self.kind = .warning
        }
        self.shouldPresent = shouldPresent ?? presentation.shouldPresent
        self.presentation = presentation
    }

    public func withPresentationAllowed(_ allowed: Bool) -> Self {
        guard let presentation else {
            return Self(message: message, kind: kind, shouldPresent: shouldPresent && allowed)
        }
        return Self(presentation: presentation, shouldPresent: shouldPresent && allowed)
    }

    public init(outcome: ComposerActionOutcome, action: VoiceReleaseAction = .stop) {
        self = Self.forOutcome(outcome, action: action)
    }

    public static func forOutcome(
        _ outcome: ComposerActionOutcome,
        action: VoiceReleaseAction = .stop
    ) -> Self {
        Self(presentation: VoiceIssuePresentationPolicy.forComposerOutcome(outcome, action: action))
    }
}
