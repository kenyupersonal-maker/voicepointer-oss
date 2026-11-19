// T7 2026-10-02: Existing paired finals + existing edit receipts, without I/O or extra recognition.
import Foundation

@MainActor
public final class EnhancementLearningRuntime: DictationEditObserving {
    public typealias Pipeline = EnhancementLearningPipeline
    public typealias Writer = @MainActor (Pipeline.Promotion, EnhancementLearningPermit, UInt64) async -> Bool
    private struct Observation {
        let comparison: EnhancementComparison
        let baselineID: UUID
        var tracker: EditSpanTracker
        let startedAt: Date
    }
    public private(set) var configuration: EnhancementLearningConfiguration
    public private(set) var decision: Pipeline.Decision = .disabled
    public private(set) var promotionCount = 0
    public var candidateCount: Int { pool.count }
    public var hasObservation: Bool { observation != nil || comparison != nil }
    private var pool = Pipeline.CandidatePool()
    private var comparison: EnhancementComparison?
    private var observation: Observation?
    private var expiry: Task<Void, Never>?
    private var writes: [Task<Void, Never>] = []
    private let permit = EnhancementLearningPermit()
    private var epoch: UInt64 = 0
    private var enabled = false
    private var onlineAuthorized = false, doubaoAuthorized = false
    public var isOnlineAuthorized: Bool { onlineAuthorized }
    private let terms: @MainActor () -> [LexiconTerm]
    private let confirmed: @MainActor () -> [Pipeline.Difference]
    private let persist: Writer
    private let now: @MainActor () -> Date
    private let trace: @MainActor (String) -> Void

    public init(configuration: EnhancementLearningConfiguration = .init(),
                terms: @escaping @MainActor () -> [LexiconTerm],
                confirmed: @escaping @MainActor () -> [Pipeline.Difference] = { [] },
                now: @escaping @MainActor () -> Date = { Date() },
                trace: @escaping @MainActor (String) -> Void = { _ in }, persist: @escaping Writer) {
        self.configuration = configuration; self.terms = terms; self.confirmed = confirmed
        self.now = now; self.trace = trace; self.persist = persist
    }

    /// Online learning follows effective enhancement; Doubao still needs its separate user opt-in.
    public func authorize(onlineEnabled: Bool, learningEnabled: Bool, doubaoEnabled: Bool = false) {
        let online = onlineEnabled, doubao = doubaoEnabled && learningEnabled
        guard online != onlineAuthorized || doubao != doubaoAuthorized else { return }
        onlineAuthorized = online; doubaoAuthorized = doubao
        let line = Pipeline.authorizationLog(online: online, learning: learningEnabled, doubao: doubao)
        precondition(Pipeline.isSafeLog(line)); trace(line)
        let next = online || doubao
        // Changing source authorization also revokes old handlers/writes even when one source stays enabled.
        _ = permit.update(enabled: false)
        enabled = next; epoch = permit.update(enabled: next)
        discard(); pool.removeAll(); writes.forEach { $0.cancel() }; writes.removeAll()
        record(next ? .unobserved : .disabled)
    }
    public func configure(_ value: EnhancementLearningConfiguration) {
        guard value != configuration else { return }
        // Revoke old handlers/writers even if both switches remain on.
        _ = permit.update(enabled: false); epoch = permit.update(enabled: enabled)
        configuration = value; discard(); pool.removeAll(); writes.forEach { $0.cancel() }; writes.removeAll()
    }

    /// Frozen when the existing hybrid branch is constructed. Re-enabling cannot revive its old result.
    public func enhancementReceiver() -> (@MainActor @Sendable (EnhancementComparison) -> Void)? {
        receiver(source: .onlineAPI)
    }
    public func doubaoEnhancementReceiver() -> (@MainActor @Sendable (EnhancementComparison) -> Void)? {
        receiver(source: .doubao)
    }
    private func receiver(source: EnhancementComparison.Source) -> (@MainActor @Sendable (EnhancementComparison) -> Void)? {
        guard source == .onlineAPI ? onlineAuthorized : doubaoAuthorized else { return nil }
        let generation = epoch
        return { [weak self] input in
            guard input.source == source else { return }
            self?.receive(input, generation: generation)
        }
    }
    private func receive(_ input: EnhancementComparison, generation: UInt64) {
        guard enabled, permit.allows(generation), generation == epoch else { return }
        guard configuration.isValid else { record(.invalidConfiguration); return }
        // No sentence is retained for a signal which cannot ever be promoted.
        guard let confidence = input.localConfidence, confidence.isFinite, (0...1).contains(confidence) else {
            record(.unknownConfidence); return
        }
        guard confidence >= configuration.minimumLocalConfidence else { record(.lowConfidence); return }
        guard max(input.localText.count, input.referenceText.count) <= configuration.maximumTextCharacters else {
            record(.lengthRatio); return
        }
        discard(); comparison = input
        scheduleExpiry()
    }

    public func dictationKept(_ dictation: DictationRecord, baseline: KeptDictationBaseline) {
        guard enabled, let input = comparison else { return }
        comparison = nil
        guard baseline.delivered == dictation.text,
              dictation.rawText == input.localText || dictation.rawText == input.referenceText,
              let tracker = EditSpanTracker(document: baseline.document, spanLocation: baseline.spanLocation,
                  spanLength: baseline.spanLength, delivered: dictation.text, emptyStateValues: baseline.emptyStateValues,
                  editingGeneration: baseline.editingGeneration, revertTexts: baseline.revertTexts) else {
            discard(); record(.unobserved); return
        }
        observation = Observation(comparison: input, baselineID: baseline.id, tracker: tracker, startedAt: now())
        scheduleExpiry()
    }

    public func sessionBegan(revisit: FieldRevisitSample?) {
        guard enabled, var current = observation else { discard(); return }
        discard()
        guard now().timeIntervalSince(current.startedAt) >= 0,
              now().timeIntervalSince(current.startedAt) <= configuration.observationLifetime else { record(.expired); return }
        guard let revisit, revisit.baselineID == current.baselineID, revisit.document != nil else { record(.unobserved); return }
        let edit = current.tracker.observe(document: revisit.document, editingGeneration: revisit.editingGeneration)
        guard edit == .unchanged || edit == .outsideEdit else { record(.edited); return }
        let evaluation = Pipeline.evaluate(current.comparison, userEdited: false, configuration: configuration,
                                           terms: terms(), confirmed: confirmed())
        let (result, promotions) = pool.ingest(evaluation, roundID: current.comparison.roundID, now: now(),
                                              configuration: configuration, terms: terms(), confirmed: confirmed())
        record(result, promotions: promotions.count)
        let generation = epoch
        if !promotions.isEmpty {
            writes.removeAll { $0.isCancelled }
            let task = Task { [weak self] in
                guard let self else { return }
                for promotion in promotions {
                    guard !Task.isCancelled, self.enabled, self.permit.allows(generation),
                          !Pipeline.conflicts(promotion.difference, terms: self.terms(), confirmed: self.confirmed()) else { return }
                    let saved = await self.persist(promotion, self.permit, generation)
                    guard !Task.isCancelled, self.permit.allows(generation) else { return }
                    if saved { self.promotionCount += 1 } else { self.record(.persistenceFailed) }
                }
            }
            writes.append(task)
        }
    }
    public func waitForPendingWrites() async { for task in writes { await task.value }; writes.removeAll() }
    private func discard() { comparison = nil; observation = nil; expiry?.cancel(); expiry = nil }
    private func scheduleExpiry() {
        expiry?.cancel()
        let generation = epoch, lifetime = configuration.observationLifetime
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled, let self, self.epoch == generation else { return }
            self.discard(); self.record(.expired)
        }
    }
    private func record(_ decision: Pipeline.Decision, promotions: Int = 0) {
        self.decision = decision
        let line = Pipeline.log(decision: decision, candidates: pool.count, promotions: promotions)
        precondition(Pipeline.isSafeLog(line)); trace(line)
    }
}
