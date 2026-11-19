import Foundation

/// Ali failures carry the F1/F4 enum unchanged. New provider-specific failures are finite too.
public struct OnlineAPIProblem: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        case connection(CloudConnectionCheck.Failure)
        case unrecognized, keyWhitespace, invalidEndpoint, noModels, insufficientQuota, cancelled
    }
    public let provider: OnlineAPIProvider?
    public let cause: Cause
    public let automatic: Bool
    public init(provider: OnlineAPIProvider?, cause: Cause, automatic: Bool = false) {
        self.provider = provider; self.cause = cause; self.automatic = automatic
    }
    /// The exact shared F1 diagnostic, for the HUD integration in E.
    public var aliCode: SpeechFailureDiagnostics.AliCode? {
        guard provider?.isAliyun == true, case .connection(let failure) = cause else { return nil }
        return SpeechFailureDiagnostics.aliDiagnostic(for: failure).code
    }
    public enum Action: Equatable, Sendable {
        case guide, keyPage(OnlineAPIProvider), modelGallery(OnlineAPIProvider), retry, billing(OnlineAPIProvider)
    }
    public var action: Action? {
        switch cause {
        case .connection(.rejectedKey):
            if automatic && provider?.isAliyun == true { return .guide }
            return provider.map(Action.keyPage)
        case .connection(.network), .connection(.timeout), .connection(.serviceUnavailable), .connection(.worker), .connection(.notClosed):
            return .retry
        case .noModels: return provider?.isAliyun == true ? provider.map(Action.modelGallery) : nil
        case .insufficientQuota: return provider.map(Action.billing)
        default: return nil
        }
    }
}

public struct OnlineAPIValidatedModels: Equatable, Sendable {
    public let provider: OnlineAPIProvider
    public let availableModelIDs: [String]
    public let recommendedModelID: String
    public let endpointOverride: String?
    public let credentialRevision: String
    public let recommendationChanged: Bool

    /// Only models in the known priority list may reach the UI.
    public init?(provider: OnlineAPIProvider, availableModelIDs: [String], endpointOverride: String? = nil,
                 credentialRevision: String, recommendationChanged: Bool = false) {
        let ordered = provider.modelIDs.filter(Set(availableModelIDs).contains)
        guard let first = ordered.first else { return nil }
        self.provider = provider; self.availableModelIDs = ordered; self.recommendedModelID = first
        self.endpointOverride = endpointOverride; self.credentialRevision = credentialRevision
        self.recommendationChanged = recommendationChanged
    }
}

public enum OnlineAPIValidationResult: Equatable, Sendable {
    case success(OnlineAPIValidatedModels), failure(OnlineAPIProblem)
}

/// UI can use a closure-backed fake. Validation never saves a draft or changes a route.
public protocol OnlineAPIValidating: Sendable {
    func validate(draft: OnlineAPIDraftKey, providerOverride: OnlineAPIProvider?,
                  endpointOverride: String?) async -> OnlineAPIValidationResult
}

public struct OnlineAPIProbeRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case aliyunHandshake(modelID: String), models }
    public let provider: OnlineAPIProvider
    public let endpoint: URL
    public let kind: Kind
    public init(provider: OnlineAPIProvider, endpoint: URL, kind: Kind) {
        self.provider = provider; self.endpoint = endpoint; self.kind = kind
    }
}

public enum OnlineAPIProbeResult: Equatable, Sendable {
    case ready, models([String]), failed(OnlineAPIProblem.Cause)
}

public struct OnlineAPIValidationService: OnlineAPIValidating {
    public typealias Probe = @Sendable (OnlineAPIProbeRequest, OnlineAPIDraftKey) async -> OnlineAPIProbeResult
    public static let stepTimeout: TimeInterval = 8
    private let probe: Probe
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = stepTimeout, probe: @escaping Probe) {
        self.timeout = min(Self.stepTimeout, max(0.001, timeout)); self.probe = probe
    }

    public func validate(draft: OnlineAPIDraftKey, providerOverride: OnlineAPIProvider? = nil,
                         endpointOverride: String? = nil) async -> OnlineAPIValidationResult {
        let candidates = providerOverride.map { [$0] } ?? draft.classification.candidates
        guard !draft.isEmpty, !candidates.isEmpty else {
            return .failure(OnlineAPIProblem(provider: providerOverride, cause: .unrecognized))
        }
        for provider in candidates {
            if Task.isCancelled { return failed(provider, .cancelled, providerOverride == nil) }
            let endpoint: URL
            do { endpoint = try OnlineAPIEndpoint.resolve(provider: provider, override: endpointOverride) }
            catch { return failed(provider, .invalidEndpoint, providerOverride == nil) }
            let firstKind: OnlineAPIProbeRequest.Kind = provider.isAliyun
                ? .aliyunHandshake(modelID: provider.modelIDs[0]) : .models
            let first = await timedProbe(.init(provider: provider, endpoint: endpoint, kind: firstKind), draft)
            if case .failed(.connection(.rejectedKey)) = first {
                if providerOverride == nil { continue }
                return failed(provider, .connection(.rejectedKey), false)
            }
            if provider.isAliyun {
                // Only evidence of valid credentials in this station admits the model sweep.
                switch first {
                case .ready, .failed(.connection(.noAccess)), .failed(.connection(.modelUnavailable)),
                     .failed(.connection(.freeQuotaExhausted)), .failed(.connection(.balanceDue)),
                     .failed(.connection(.rateLimited)):
                    break
                case .failed(let cause): return failed(provider, cause, providerOverride == nil)
                case .models: return failed(provider, .connection(.unknown), providerOverride == nil)
                }
                if Task.isCancelled { return failed(provider, .cancelled, providerOverride == nil) }
                // The first call identifies the station. The three model checks are separate,
                // concurrent, zero-audio handshakes, as required by the task card.
                let results = await withTaskGroup(of: (String, OnlineAPIProbeResult).self) { group in
                    for id in provider.modelIDs {
                        group.addTask {
                            (id, await timedProbe(.init(provider: provider, endpoint: endpoint,
                                                      kind: .aliyunHandshake(modelID: id)), draft))
                        }
                    }
                    var collected: [String: OnlineAPIProbeResult] = [:]
                    for await (id, result) in group { collected[id] = result }
                    return collected
                }
                if Task.isCancelled { return failed(provider, .cancelled, providerOverride == nil) }
                // Network/cleanup failures stop the attempt; partial lists must not conceal them.
                for id in provider.modelIDs {
                    if case .failed(let cause) = results[id], isInfrastructureFailure(cause) {
                        return failed(provider, cause, providerOverride == nil)
                    }
                }
                let available = provider.modelIDs.filter { results[$0] == .ready }
                if let models = OnlineAPIValidatedModels(provider: provider, availableModelIDs: available,
                    endpointOverride: endpointOverride, credentialRevision: draft.revision,
                    recommendationChanged: results[provider.modelIDs[0]] == .failed(.connection(.noAccess))
                        || results[provider.modelIDs[0]] == .failed(.connection(.modelUnavailable))) {
                    return .success(models)
                }
                for reason in [CloudConnectionCheck.Failure.freeQuotaExhausted, .balanceDue, .rejectedKey, .rateLimited] {
                    if results.values.contains(.failed(.connection(reason))) {
                        return failed(provider, .connection(reason), providerOverride == nil)
                    }
                }
                return failed(provider, .noModels, providerOverride == nil)
            }
            switch first {
            case .models(let ids):
                guard let models = OnlineAPIValidatedModels(provider: provider, availableModelIDs: ids,
                    endpointOverride: endpointOverride, credentialRevision: draft.revision) else {
                    return failed(provider, .noModels, providerOverride == nil)
                }
                return .success(models)
            case .failed(let cause): return failed(provider, cause, providerOverride == nil)
            case .ready: return failed(provider, .connection(.unknown), providerOverride == nil)
            }
        }
        return failed(candidates.last, .connection(.rejectedKey), providerOverride == nil)
    }

    public func checkSelectedModel(configuration: OnlineAPIConfiguration, draft: OnlineAPIDraftKey) async -> OnlineAPIProbeResult {
        guard let endpoint = try? configuration.validatedEndpoint() else { return .failed(.invalidEndpoint) }
        let kind: OnlineAPIProbeRequest.Kind = configuration.provider.isAliyun ? .aliyunHandshake(modelID: configuration.modelID) : .models
        let result = await timedProbe(.init(provider: configuration.provider, endpoint: endpoint, kind: kind), draft)
        if case .models(let ids) = result { return ids.contains(configuration.modelID) ? .ready : .failed(.noModels) }
        return result
    }
    private func failed(_ provider: OnlineAPIProvider?, _ cause: OnlineAPIProblem.Cause,
                        _ automatic: Bool) -> OnlineAPIValidationResult {
        .failure(.init(provider: provider, cause: cause, automatic: automatic))
    }
    private func isInfrastructureFailure(_ cause: OnlineAPIProblem.Cause) -> Bool {
        switch cause {
        case .connection(.network), .connection(.timeout), .connection(.worker), .connection(.notClosed),
             .connection(.serviceUnavailable), .connection(.unknown), .connection(.taskStartFailed), .cancelled:
            true
        default: false
        }
    }
    private func timedProbe(_ request: OnlineAPIProbeRequest, _ draft: OnlineAPIDraftKey) async -> OnlineAPIProbeResult {
        let race = OnlineAPIProbeRace()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard race.begin(continuation) else { return }
                let work = Task {
                    guard !Task.isCancelled, race.isActive else { return }
                    race.finish(await probe(request, draft), cancelWork: false)
                }
                let timer = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    race.finish(.failed(.connection(.timeout)), cancelWork: true)
                }
                race.attach(work: work, timer: timer)
            }
        }, onCancel: { race.finish(.failed(.cancelled), cancelWork: true) })
    }
}

/// A timer/cancel can finish promptly even when a foreign injected probe does not cooperate.
/// Live probes still own cleanup and never publish a late result.
private final class OnlineAPIProbeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OnlineAPIProbeResult, Never>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var settled = false
    private var cancelledBeforeBegin = false
    var isActive: Bool { lock.withLock { !settled && !cancelledBeforeBegin } }
    func begin(_ continuation: CheckedContinuation<OnlineAPIProbeResult, Never>) -> Bool {
        let cancelled = lock.withLock { self.continuation = continuation; return cancelledBeforeBegin }
        if cancelled { finish(.failed(.cancelled), cancelWork: true) }
        return !cancelled
    }
    func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let done = lock.withLock { () -> Bool in
            if settled { return true }
            self.work = work; self.timer = timer; return false
        }
        if done { work.cancel(); timer.cancel() }
    }
    func finish(_ result: OnlineAPIProbeResult, cancelWork: Bool) {
        let taken = lock.withLock { () -> (CheckedContinuation<OnlineAPIProbeResult, Never>, Task<Void, Never>?, Task<Void, Never>?)? in
            guard !settled else { return nil }
            guard let continuation else { if cancelWork { cancelledBeforeBegin = true }; return nil }
            settled = true
            let handles = (continuation, work, timer)
            self.continuation = nil; work = nil; timer = nil
            return handles
        }
        guard let (continuation, work, timer) = taken else { return }
        timer?.cancel(); if cancelWork { work?.cancel() }
        continuation.resume(returning: result)
    }
}
