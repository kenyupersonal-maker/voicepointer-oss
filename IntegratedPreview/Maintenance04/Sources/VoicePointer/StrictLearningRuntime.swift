import Foundation
import VoicePointerCore

/// Production-only strict teacher comparison path. Never asks a recognizer for a second
/// pass, never stores teacher sentences or captures audio, and never touches draft text.
@MainActor
final class StrictLearningRuntime {
    private let ledger: StrictLearningLedger
    private let shadow: StrictLearningShadowStore
    private let lexicon: LexiconRuntime
    private let ordinaryEnglish: @MainActor (String) -> Bool
    private let strictLearningLive: Bool
    private var importingShadow = false
    private var onlineAuthorized = false
    private var doubaoAuthorized = false
    private var generation: UInt64 = 0
    private let permit = EnhancementLearningPermit()
    private var permitEpoch: UInt64 = 0

    init(
        lexicon: LexiconRuntime,
        ledger: StrictLearningLedger = StrictLearningLedger(),
        shadow: StrictLearningShadowStore = StrictLearningShadowStore(),
        strictLearningLive: Bool? = nil,
        ordinaryEnglish: @escaping @MainActor (String) -> Bool
    ) {
        self.lexicon = lexicon
        self.ledger = ledger
        self.shadow = shadow
        // Read at construction, never enable learning or mutate user settings.
        // If the key does not exist, UserDefaults.bool returns false.
        self.strictLearningLive = strictLearningLive
            ?? UserDefaults.standard.bool(forKey: "strictLearningLive")
        self.ordinaryEnglish = ordinaryEnglish
    }

    func authorize(online: Bool, doubao: Bool) {
        guard online != onlineAuthorized || doubao != doubaoAuthorized else {
            if strictLearningLive { scheduleShadowImport() }
            return
        }
        onlineAuthorized = online
        doubaoAuthorized = doubao
        generation &+= 1
        // Always rotate the epoch on ANY route permission change, even if the
        // other route stays enabled; an old queued write must never inherit consent.
        _ = permit.update(enabled: false)
        permitEpoch = permit.update(enabled: online || doubao)
        if strictLearningLive { scheduleShadowImport() }
    }

    /// With the feature explicitly switched live before application start, safely
    /// import previous observations using the ledger's original evidence and fresh
    /// daily/total caps. Every operation is independently guarded by the same epoch.
    private func scheduleShadowImport() {
        guard strictLearningLive, !importingShadow,
              onlineAuthorized || doubaoAuthorized,
              lexicon.availability == .ready else { return }
        let epoch = permitEpoch
        let generation = self.generation
        guard permit.allows(epoch) else { return }
        importingShadow = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.importingShadow = false }
            guard self.generation == generation, self.permit.allows(epoch) else { return }
            do {
                guard let candidates = try await self.shadow.pending(
                    permit: self.permit, epoch: epoch
                ) else { return }
                for entry in candidates {
                    guard self.generation == generation, self.permit.allows(epoch) else { return }
                    let date = Date()
                    guard let reserved = try await self.ledger.reserveShadowImport(
                        entry, at: date, activeTerms: self.lexicon.terms,
                        permit: self.permit, epoch: epoch
                    ) else { continue }
                    let saved = await self.lexicon.addStrictAutomatic(
                        reserved, at: date, permit: self.permit, epoch: epoch
                    )
                    guard self.generation == generation, self.permit.allows(epoch) else {
                        // A withdrawn write leaves a fail-closed reservation.
                        return
                    }
                    let finished = try await self.ledger.finishShadowImport(
                        reserved.pair, success: saved != nil, at: date,
                        permit: self.permit, epoch: epoch
                    )
                    if finished && saved != nil {
                        _ = try await self.shadow.remove(
                            reserved.pair, permit: self.permit, epoch: epoch
                        )
                    }
                }
            } catch {
                RuntimeTrace.record("learn shadow state=storeUnavailable")
            }
        }
    }

    func isAuthorized(_ source: EnhancementComparison.Source) -> Bool {
        switch source {
        case .onlineAPI: return onlineAuthorized
        case .doubao: return doubaoAuthorized
        }
    }

    private func qualified(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 1_500 && !TeacherLearningPolicy.isSensitive(text)
    }

    /// Independent of whether local recognition succeeded or the sentence contains candidates.
    /// A write failure leaves the indexed coverage incomplete and blocks future promotion.
    func observeTeacherFinal(_ text: String, roundID: UUID, source: EnhancementComparison.Source) {
        guard isAuthorized(source), qualified(text) else { return }
        let epoch = self.generation
        let writeEpoch = self.permitEpoch
        Task { [weak self] in
            guard let self, self.generation == epoch, self.isAuthorized(source) else { return }
            do {
                _ = try await self.ledger.observeTeacherAuthorized(
                    reference: text, roundID: roundID, at: Date(),
                    permit: self.permit, epoch: writeEpoch
                )
            } catch {
                // Only enumerated numeric/category events. Never print paths or the text.
                RuntimeTrace.record("learn promote result=contradicted")
            }
        }
    }

    /// Hybrid: teacher cloud final versus local final. Doubao: delivered editor text
    /// versus an independently decoded copy of that session's RAM audio.
    func receive(_ input: EnhancementComparison) {
        // Existing PCM is used at most once by DoubaoLearningRuntime; there is NO hotword recheck.
        input.audio?.clear()
        guard isAuthorized(input.source), qualified(input.referenceText) else { return }
        if strictLearningLive { scheduleShadowImport() }
        let source = input.source
        let reference = input.referenceText
        let roundID = input.roundID
        let date = input.referenceAt
        let epoch = generation
        let writeEpoch = permitEpoch

        // All accepted/rejected pairs are independently derived from the actual FINAL pair.
        let decisions = StrictLearningFilter.analyze(
            local: input.localText, reference: reference,
            commonChinese: { _ in false },
            ordinaryEnglish: ordinaryEnglish
        )
        for decision in decisions {
            if let reason = decision.rejection {
                RuntimeTrace.record("learn candidate result=rejected reason=\(reason.rawValue)")
            } else {
                RuntimeTrace.record("learn candidate result=accepted")
            }
        }
        Task { [weak self] in
            guard let self, self.generation == epoch, self.isAuthorized(source) else { return }
            do {
                // The ledger commits ALL teacher-fragment observations before pool or quota updates.
                // It rejects corruption/writes before handing out any promotion reservation.
                guard let result = try await self.ledger.ingestAuthorized(
                    decisions: decisions, reference: reference, roundID: roundID, at: date,
                    activeTerms: self.lexicon.terms, permit: self.permit, epoch: writeEpoch
                ) else { return }
                for reason in result.promotionReasons where reason != .ok {
                    RuntimeTrace.record("learn promote result=\(reason.rawValue)")
                }
                for promotion in result.promotions {
                    guard self.generation == epoch, self.isAuthorized(source) else {
                        // A revoked reservation remains pending and cannot promote again.
                        continue
                    }
                    do {
                        if !self.strictLearningLive {
                            let recorded = try await self.shadow.record(
                                promotion, at: date, permit: self.permit, epoch: writeEpoch
                            )
                            let finished = try await self.ledger.finishPromotionAuthorized(
                                promotion.pair, success: recorded,
                                permit: self.permit, epoch: writeEpoch
                            )
                            if recorded && finished {
                                RuntimeTrace.record("learn promote result=wouldPromote")
                            }
                        } else {
                            let saved = await self.lexicon.addStrictAutomatic(
                                promotion, at: date, permit: self.permit, epoch: writeEpoch
                            )
                            // If confirmation fails, leave the durable reservation fail-closed
                            // so an asynchronous restart cannot replay the live write.
                            _ = try await self.ledger.finishPromotionAuthorized(
                                promotion.pair, success: saved != nil,
                                permit: self.permit, epoch: writeEpoch
                            )
                        }
                    } catch {
                        RuntimeTrace.record("learn shadow state=storeUnavailable")
                    }
                }
            } catch {
                RuntimeTrace.record("learn promote result=contradicted")
            }
        }
    }

    /// All automatic undo/delete paths must write the permanent ban BEFORE removing the term.
    /// A broken ban store leaves the live term untouched rather than allowing it to relearn.
    func undoAutomaticallyLearned(_ term: LexiconTerm) async -> Bool {
        guard term.source == .automaticallyLearned, !term.variants.isEmpty else { return false }
        do {
            // An edited automatic row may carry several wrong spellings. Ban ALL its pairs
            // before deleting the live term; never let an unbanned variant relearn.
            for variant in term.variants {
                try await ledger.permanentlyForbid(
                    StrictLearningFilter.Pair(variant: variant, canonical: term.canonical)
                )
            }
        } catch {
            return false
        }
        if case .success = await lexicon.remove(id: term.id) { return true }
        return false
    }
}
