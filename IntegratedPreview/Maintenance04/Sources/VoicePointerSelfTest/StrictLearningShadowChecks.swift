import Foundation
@_spi(Testing) import VoicePointerCore

/// Explicit synthetic-only observation/live check. Never accesses the user's lexicon,
/// defaults, clipboard, dictation contents, microphone or network.
enum StrictLearningShadowChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".cache/tmp", isDirectory: true)
            .appendingPathComponent("r67-shadow-synthetic-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let ledger = StrictLearningLedger(directory: base)
        let shadow = StrictLearningShadowStore(directory: base)
        let lexicon = LexiconStore(directory: base)
        let permit = EnhancementLearningPermit()
        let epoch = permit.update(enabled: true)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let lead = "我们现在使用"
        let tail = "继续完成设计"
        let reference = lead + "Figma" + tail
        let decisions = StrictLearningFilter.analyze(
            local: lead + "菲格玛" + tail, reference: reference,
            commonChinese: { _ in false }, ordinaryEnglish: { _ in false }
        )
        guard decisions.count == 1, decisions[0].isAccepted else {
            return ["strict shadow: synthetic candidate"]
        }
        do {
            _ = try await lexicon.load()
            let dates = [at, at.addingTimeInterval(20), at.addingTimeInterval(86_400)]
            for (i, date) in dates.enumerated() {
                guard let result = try await ledger.ingestAuthorized(
                    decisions: decisions, reference: reference, roundID: UUID(), at: date,
                    activeTerms: await lexicon.allTerms(), permit: permit, epoch: epoch
                ) else {
                    failures.append("strict shadow: authorized observation rejected")
                    return failures
                }
                if i < 2 && !result.promotions.isEmpty {
                    failures.append("strict shadow: premature promotion")
                }
                if i == 2 {
                    guard result.promotions.count == 1 else {
                        failures.append("strict shadow: missing two-date promotion")
                        return failures
                    }
                    let accepted = try await shadow.record(
                        result.promotions[0], at: date, permit: permit, epoch: epoch
                    )
                    let finished = try await ledger.finishPromotionAuthorized(
                        result.promotions[0].pair, success: accepted,
                        permit: permit, epoch: epoch
                    )
                    if !accepted || !finished {
                        failures.append("strict shadow: commit observation")
                    }
                }
            }
            let afterObservation = await lexicon.allTerms()
            guard let recorded = try await shadow.pending(permit: permit, epoch: epoch),
                  recorded.count == 1, afterObservation.isEmpty else {
                failures.append("strict shadow: default mode wrote lexicon")
                return failures
            }
            let document = try JSONSerialization.jsonObject(
                with: Data(contentsOf: shadow.fileURL)
            ) as? [String: Any]
            let records = document?["entries"] as? [[String: Any]]
            let keys = records?.first.map { Set($0.keys) } ?? []
            if records?.count != 1 ||
                keys != Set(["variant", "canonical", "sightings", "dates", "wouldPromoteAt"]) {
                failures.append("strict shadow: restricted fields")
            }
            // Simulate the next explicitly enabled launch. Original evidence is
            // rechecked, today's live quota reserved, then the real lexicon is written.
            let importedAt = at.addingTimeInterval(172_800)
            guard let reservation = try await ledger.reserveShadowImport(
                recorded[0], at: importedAt, activeTerms: afterObservation,
                permit: permit, epoch: epoch
            ) else {
                failures.append("strict shadow: eligible live replay")
                return failures
            }
            let added = try await lexicon.addStrictAutomaticallyLearned(
                reservation.pair, sightings: reservation.sightings, at: importedAt,
                permit: permit, epoch: epoch
            )
            let completed = try await ledger.finishShadowImport(
                reservation.pair, success: added != nil, at: importedAt,
                permit: permit, epoch: epoch
            )
            let removed = try await shadow.remove(reservation.pair, permit: permit, epoch: epoch)
            let liveTerms = await lexicon.allTerms()
            let remaining = try await shadow.pending(permit: permit, epoch: epoch)
            if added == nil || !completed || !removed ||
                liveTerms.count != 1 || remaining?.count != 0 {
                failures.append("strict shadow: live replay persistence")
            }
        } catch {
            // Explicitly suppress error detail: it may contain a private filesystem path.
            failures.append("strict shadow: synthetic store category")
        }
        return failures
    }
}
