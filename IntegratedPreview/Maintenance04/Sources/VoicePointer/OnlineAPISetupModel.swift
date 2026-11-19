import AppKit
import Combine
import Foundation
import VoicePointerCore

/// The only clipboard read is in explicit paste actions. No live validator or store is constructed here.
@MainActor final class OnlineAPISetupModel: ObservableObject {
    typealias Completion = @MainActor (OnlineAPIConfiguration, OnlineAPIDraftKey, OnlineAPISetupPurpose, Bool) async throws -> OnlineAPIConfiguration
    @Published private(set) var state = OnlineAPISetupState()
    @Published private(set) var keyInput = ""
    @Published private(set) var endpointInput = ""
    @Published private(set) var providerOverride: OnlineAPIProvider?
    @Published var page: OnlineAPISetupPage
    @Published var guideProvider: OnlineAPIProvider
    @Published private(set) var guidePasteMessage = ""
    @Published private(set) var completionMessage = ""
    @Published private(set) var completing = false
    let purpose: OnlineAPISetupPurpose
    let market: MarketRegion
    private let validator: any OnlineAPIValidating
    private let clipboard: @MainActor () -> String?
    private let completion: Completion?
    private let finished: @MainActor (OnlineAPIConfiguration) -> Void
    private var draft: OnlineAPIDraftKey?
    private var validationTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?

    init(purpose: OnlineAPISetupPurpose, start: OnlineAPISetupPage, market: MarketRegion = .current,
         validator: any OnlineAPIValidating = OnlineAPIUnavailableValidator(),
         clipboard: @escaping @MainActor () -> String? = { NSPasteboard.general.string(forType: .string) },
         completion: Completion? = nil, finished: @escaping @MainActor (OnlineAPIConfiguration) -> Void) {
        self.purpose = purpose; page = start; self.market = market; self.validator = validator
        guideProvider = market.guideProviders[0]
        self.clipboard = clipboard; self.completion = completion; self.finished = finished
    }
    var maskedKey: String { draft?.masked ?? (keyInput.isEmpty ? "" : "••••") }
    var models: OnlineAPIValidatedModels? {
        if case .success(let models) = state.phase { return models }; return nil
    }
    var displayProvider: OnlineAPIProvider? {
        if let models { return models.provider }
        if let providerOverride { return providerOverride }
        if case .failure(let problem) = state.phase { return problem.provider }
        return draft?.classification.candidates.first
    }
    var finishEnabled: Bool { !completing && (state.phase == .checking || state.canFinish(purpose: purpose)) }
    var awaitingValidation: Bool { state.phase == .checking && state.finishRequested }
    var unsupportedEnhance: Bool { purpose == .enhanceLocal && displayProvider?.supportsEnhanceLocal == false }

    func editKey(_ input: String, immediate: Bool = false) {
        guard !completing else { return }
        invalidate(); keyInput = input
        scheduleValidation(immediate: immediate)
    }
    func pasteKey() { guard !completing else { return }; editKey(clipboard() ?? "", immediate: true) }
    func pasteFromGuide() {
        guard !completing else { return }
        let input = clipboard() ?? ""
        guard OnlineAPIKeyClassifier.guidePasteLooksLikeKey(input) else {
            guidePasteMessage = OnlineAPIStrings.clipboardNoKey; return
        }
        guidePasteMessage = ""; page = .form; editKey(input, immediate: true)
    }
    func changeProvider(_ provider: OnlineAPIProvider) {
        guard !completing else { return }
        invalidate(); providerOverride = provider; endpointInput = ""; scheduleValidation(immediate: true)
    }
    func editEndpoint(_ value: String) {
        guard !completing else { return }
        let currentProvider = models?.provider ?? providerOverride
        invalidate(); providerOverride = currentProvider; endpointInput = value; scheduleValidation(immediate: false)
    }
    func retry() { guard !completing else { return }; invalidate(); scheduleValidation(immediate: true) }
    func selectModel(_ id: String) { guard !completing else { return }; state.selectModel(id) }
    func confirmQuota(_ value: Bool) { guard !completing else { return }; state.confirmQuotaOnly(value) }
    func requestFinish() {
        guard !completing else { return }
        if state.requestFinish(purpose: purpose) { finish() }
    }
    func close() {
        completionTask?.cancel(); completionTask = nil; completing = false
        invalidate(); keyInput = ""; endpointInput = ""; guidePasteMessage = ""
    }
    private func invalidate() {
        validationTask?.cancel(); validationTask = nil; draft?.clear(); draft = nil
        state.reset(); completionMessage = ""
    }
    private func scheduleValidation(immediate: Bool) {
        let cleaned: String
        do { cleaned = try OnlineAPIKeyClassifier.clean(keyInput) }
        catch OnlineAPIKeyInputError.empty { keyInput = ""; return }
        catch {
            let generation = state.beginValidation()
            state.receive(.failure(.init(provider: providerOverride,
                cause: (error as? OnlineAPIKeyInputError) == .whitespace ? .keyWhitespace : .unrecognized)), generation: generation)
            return
        }
        guard !cleaned.isEmpty else { return }
        keyInput = cleaned
        guard let next = try? OnlineAPIDraftKey(cleaned) else { return }
        draft = next
        let generation = state.beginValidation()
        let provider = providerOverride
        let endpoint = endpointInput.isEmpty ? nil : endpointInput
        if let provider = provider ?? next.classification.candidates.first {
            guard (try? OnlineAPIEndpoint.resolve(provider: provider, override: endpoint)) != nil else {
                state.receive(.failure(.init(provider: provider, cause: .invalidEndpoint)), generation: generation)
                return
            }
        }
        validationTask = Task { [weak self, validator] in
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let result = await validator.validate(draft: next, providerOverride: provider, endpointOverride: endpoint)
            guard let self, !Task.isCancelled, self.state.receive(result, generation: generation) else { return }
            self.validationTask = nil
            if self.state.finishRequested && self.state.canFinish(purpose: self.purpose) { self.finish() }
        }
    }
    private func finish() {
        guard let configuration = state.configuration(purpose: purpose), let draft else { return }
        guard let completion else { completionMessage = OnlineAPIStrings.completionUnavailable; return }
        let generation = state.generation
        completing = true
        completionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await completion(configuration, draft, self.purpose, self.state.quotaOnlyConfirmed)
                guard !Task.isCancelled, self.state.generation == generation else { return }
                guard saved.credentialRevision != configuration.credentialRevision else { throw OnlineAPICompletionError.invalid }
                self.completing = false; self.close(); self.finished(saved)
            } catch {
                guard !Task.isCancelled, self.state.generation == generation else { return }
                self.completing = false; self.completionMessage = OnlineAPIStrings.completionFailed
            }
        }
    }
}

/// Safe by default until E explicitly injects the live service.
struct OnlineAPIUnavailableValidator: OnlineAPIValidating {
    func validate(draft: OnlineAPIDraftKey, providerOverride: OnlineAPIProvider?, endpointOverride: String?) async -> OnlineAPIValidationResult {
        .failure(.init(provider: providerOverride, cause: .connection(.worker)))
    }
}
