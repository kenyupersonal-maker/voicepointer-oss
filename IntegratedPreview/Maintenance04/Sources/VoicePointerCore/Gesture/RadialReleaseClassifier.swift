import CoreGraphics

public enum RadialReleaseClassifier {
    /// Relative finger travel from gesture start is the only Send/Cancel qualification.
    /// Screen-edge panel clamping and hit zones never raise the threshold. Scaled HUDs scale both limits.
    public static let defaultMinimumDirectionalTravel: CGFloat = 40
    public static let defaultNeutralTravel: CGFloat = 30

    /// CGEvent/Quartz global screen coordinates start at the upper-left of the
    /// main display, so moving upward decreases Y and moving downward increases Y.
    public static func classify(
        hitAction: VoiceReleaseAction,
        anchor: CGPoint?,
        current: CGPoint,
        previousAction: VoiceReleaseAction = .stop,
        minimumDirectionalTravel: CGFloat = RadialReleaseClassifier.defaultMinimumDirectionalTravel,
        neutralTravel: CGFloat = RadialReleaseClassifier.defaultNeutralTravel
    ) -> VoiceReleaseAction {
        guard let anchor else { return .stop }
        let verticalTravel = current.y - anchor.y
        // Keep hitAction for source compatibility with HUD callers, but do not use
        // it for direction eligibility: a clamped panel moves its hit-zone anchor.
        _ = hitAction
        if verticalTravel <= -minimumDirectionalTravel { return .send }
        if verticalTravel >= minimumDirectionalTravel { return .cancel }

        // Keep an armed direction while the pointer continues travelling in
        // that half-plane. This makes vertical overshoot harmless, while a
        // deliberate return to the center dead zone still cancels the action.
        switch previousAction {
        case .send where verticalTravel <= -neutralTravel:
            return .send
        case .cancel where verticalTravel >= neutralTravel:
            return .cancel
        default:
            return .stop
        }
    }
}
