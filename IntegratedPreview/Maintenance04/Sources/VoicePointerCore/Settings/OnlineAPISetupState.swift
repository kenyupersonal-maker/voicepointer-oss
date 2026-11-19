import Foundation

/// Credential-free reducer. The UI owns a Draft and a cancellable Task; generation fences late results.
public struct OnlineAPISetupState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case empty, checking, success(OnlineAPIValidatedModels), failure(OnlineAPIProblem) }
    public private(set) var phase: Phase = .empty
    public private(set) var generation: UInt64 = 0
    public private(set) var selectedModelID: String?
    public private(set) var quotaOnlyConfirmed = false
    public private(set) var finishRequested = false
    public init() {}
    @discardableResult public mutating func beginValidation() -> UInt64 {
        generation &+= 1; phase = .checking; selectedModelID = nil
        quotaOnlyConfirmed = false; finishRequested = false
        return generation
    }
    public mutating func reset() {
        generation &+= 1; phase = .empty; selectedModelID = nil
        quotaOnlyConfirmed = false; finishRequested = false
    }
    /// false means stale: the UI must ignore it, including any attempt to finish.
    @discardableResult public mutating func receive(_ result: OnlineAPIValidationResult, generation expected: UInt64) -> Bool {
        guard generation == expected, phase == .checking else { return false }
        switch result {
        case .success(let models): phase = .success(models); selectedModelID = models.recommendedModelID
        case .failure(let problem): phase = .failure(problem); selectedModelID = nil; finishRequested = false
        }
        return true
    }
    public mutating func selectModel(_ id: String) {
        guard case .success(let models) = phase, models.availableModelIDs.contains(id), selectedModelID != id else { return }
        selectedModelID = id; quotaOnlyConfirmed = false; finishRequested = false
    }
    public mutating func confirmQuotaOnly(_ value: Bool) { quotaOnlyConfirmed = value }
    public func canFinish(purpose: OnlineAPISetupPurpose) -> Bool {
        guard case .success(let models) = phase, let selectedModelID,
              models.availableModelIDs.contains(selectedModelID),
              purpose != .enhanceLocal || models.provider.supportsEnhanceLocal else { return false }
        return true
    }
    /// Checking is clickable and remembers intent. Success still enforces the Ali checkbox and purpose.
    @discardableResult public mutating func requestFinish(purpose: OnlineAPISetupPurpose) -> Bool {
        if phase == .checking { finishRequested = true; return false }
        return canFinish(purpose: purpose)
    }
    public func configuration(purpose: OnlineAPISetupPurpose) -> OnlineAPIConfiguration? {
        guard canFinish(purpose: purpose), case .success(let models) = phase, let selectedModelID else { return nil }
        return .init(provider: models.provider, modelID: selectedModelID, endpointOverride: models.endpointOverride,
                     credentialRevision: models.credentialRevision)
    }
}
