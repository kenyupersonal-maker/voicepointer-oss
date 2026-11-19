// T5 2026-10-02: The native page consumes this policy; offline checks cover actual panel/empty-action choices.
import Foundation

public struct RecognitionSettingsPresentation: Sendable {
    public let method: RecognitionMethod
    public let showsGuide: Bool
    public let emptyAction: HealthNextAction?
    public var showsLocalControls: Bool { method == .local }
    public var showsOnlineControls: Bool { method == .online }
    public var showsDoubaoControls: Bool { method == .doubao }
    /// An empty guide owns the only prominent action; the status row's same next step is secondary.
    public var statusActionIsPrimary: Bool { !showsGuide }
    public init(method: RecognitionMethod, installed: Bool, enabledInSystem: Bool?, models: [LocalModelItem], keySaved: Bool) {
        self.method = method
        switch method {
        case .doubao:
            showsGuide = !installed || enabledInSystem != true
            emptyAction = !installed ? .installDoubao : enabledInSystem != true ? .enableSystemInput : nil
        case .local:
            showsGuide = !models.contains { if case .ready = $0.state { return true }
                if case .needsVerification = $0.state { return true }
                if $0.state.isInstalling { return true }; return false }
            emptyAction = showsGuide ? .downloadRecommendedModel : nil
        case .online:
            showsGuide = !keySaved; emptyAction = keySaved ? nil : .configureAPI
        }
    }
}
