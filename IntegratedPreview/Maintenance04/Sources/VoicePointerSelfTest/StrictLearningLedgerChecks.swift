import Foundation
import Darwin
@_spi(Testing) import VoicePointerCore

/// Only synthetic text, UUIDs and an isolated throwaway directory. Not executed during source authoring.
enum StrictLearningLedgerChecks {
    // Report only finite synthetic failure categories; never serialize a pair, path or sentence.
    private static func failureCategory(_ error: Error) -> String {
        if let reason = error as? StrictLearningLedger.Failure {
            switch reason {
            case .damaged: return "ledger.damaged"
            case .changedOnDisk: return "ledger.changedOnDisk"
            case .unavailable: return "ledger.unavailable"
            }
        }
        if let reason = error as? LexiconStore.StoreError {
            switch reason {
            case .notLoaded: return "store.notLoaded"
            case .unavailable(let detail):
                // Only the source category, NEVER the error string, path or user text.
                if detail.hasPrefix("mkdir:") { return "store.unavailable.mkdir" }
                if detail.hasPrefix("lstat:") { return "store.unavailable.lstat" }
                if detail.hasPrefix("open temporary:") { return "store.unavailable.openTemporary" }
                if detail.hasPrefix("open:") { return "store.unavailable.open" }
                if detail.hasPrefix("rename:") { return "store.unavailable.rename" }
                if detail == "owner" { return "store.unavailable.owner" }
                if detail == "not a directory" { return "store.unavailable.notDirectory" }
                if detail == "symlink" { return "store.unavailable.symlink" }
                if detail.hasPrefix("fstat:") { return "store.unavailable.fstat" }
                if detail.hasPrefix("read:") { return "store.unavailable.read" }
                return "store.unavailable.other"
            case .malformed: return "store.malformed"
            case .unsupportedVersion: return "store.unsupportedVersion"
            case .validation: return "store.validation"
            case .changedOnDisk: return "store.changedOnDisk"
            }
        }
        return "system.code_\((error as NSError).code)"
    }

    /// Synthetic fixture injection only. This intentionally does NOT call LexiconFileIO
    /// because tests must be able to persist deliberately invalid JSON bytes.
    private static func replaceSyntheticBytes(_ data: Data, at target: URL) throws {
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".r67-fixture-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var opened = true
        defer {
            if opened { _ = Darwin.close(fd) }
            // Only our unique newly-created temporary file can be removed.
            _ = Darwin.unlink(temporary.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if n > 0 { offset += n }
                else if n < 0 && errno == EINTR { continue }
                else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        }
        while Darwin.fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let result = Darwin.close(fd)
        opened = false
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func run(only groups: Set<String>? = nil) async -> [String] {

        var failures: [String] = []
        let before = "我们今天确认"
        let after = "这个功能确实正常"
        let local = before + "菲格玛" + after
        let reference = before + "Figma" + after
        let decisions = StrictLearningFilter.analyze(
            local: local, reference: reference,
            commonChinese: { _ in false }, ordinaryEnglish: { _ in false }
        )
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let enabledPermit = EnhancementLearningPermit()
        let enabledEpoch = enabledPermit.update(enabled: true)
        func tempDirectory() -> URL {
            // scripts/run-isolated.sh permits writes only below this worktree.
            // Do not depend on Foundation's process-wide temporary-directory choice.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".cache/tmp", isDirectory: true)
                .appendingPathComponent("vp-strict-synthetic-" + UUID().uuidString, isDirectory: true)
        }
        func check(_ result: StrictLearningLedger.Outcome, promoted: Bool, context: String) {
            if (result.promotions.count == 1) != promoted {
                failures.append("strict ledger: " + context)
            }
        }

        if groups == nil || groups!.contains("basic") {
        let first = tempDirectory()
        defer { try? FileManager.default.removeItem(at: first) }
        let ledger = StrictLearningLedger(directory: first)
        let round = UUID()
        do {
            let once = try await ledger.ingest(
                decisions: decisions, reference: reference, roundID: round, at: at, activeTerms: []
            )
            check(once, promoted: false, context: "one sighting")
            let repeated = try await ledger.ingest(
                decisions: decisions, reference: reference, roundID: round, at: at, activeTerms: []
            )
            check(repeated, promoted: false, context: "repeat callback")
            let twice = try await ledger.ingest(
                decisions: decisions, reference: reference, roundID: UUID(), at: at.addingTimeInterval(30),
                activeTerms: []
            )
            check(twice, promoted: false, context: "two rounds")
            let thriceSameDay = try await ledger.ingest(
                decisions: decisions, reference: reference, roundID: UUID(), at: at.addingTimeInterval(60),
                activeTerms: []
            )
            check(thriceSameDay, promoted: false, context: "three rounds same day")
            let fourthNextDay = try await ledger.ingest(
                decisions: decisions, reference: reference, roundID: UUID(), at: at.addingTimeInterval(86_400),
                activeTerms: []
            )
            check(fourthNextDay, promoted: true, context: "three-plus across dates")
            if let promotion = fourthNextDay.promotions.first {
                try await ledger.finishPromotion(promotion.pair, success: true)
                try await ledger.permanentlyForbid(promotion.pair)
                if !(try await ledger.wasForbidden(promotion.pair)) {
                    failures.append("strict ledger: permanent undo")
                }
            }
            let coverage = try await ledger.coverage()
            if coverage.candidateCount != 1 || coverage.observedRounds != 4 {
                failures.append("strict ledger: callback dedupe")
            }
            let json = try String(contentsOf: first.appendingPathComponent("strict-learning-teacher-index.json"),
                                  encoding: .utf8)
            if json.contains(reference) || json.contains(local) {
                failures.append("strict ledger: teacher sentence stored")
            }
            // Simulate candidate eviction in this synthetic pool; the complete comparison identity
            // remains durable, so replaying that old UUID after restart cannot contribute again.
            let poolURL = first.appendingPathComponent("strict-learning-candidates.json")
            var pool = try JSONSerialization.jsonObject(with: Data(contentsOf: poolURL)) as! [String: Any]
            pool["entries"] = []
            try Self.replaceSyntheticBytes(try JSONSerialization.data(withJSONObject: pool), at: poolURL)
            let restarted = StrictLearningLedger(directory: first)
            _ = try await restarted.ingest(decisions: decisions, reference: reference, roundID: round,
                                           at: at.addingTimeInterval(172_800), activeTerms: [])
            if try await restarted.coverage().candidateCount != 0 {
                failures.append("strict ledger: eviction restart callback dedupe")
            }
            if !(try await restarted.wasForbidden(decisions[0].pair)) {
                failures.append("strict ledger: undo survives eviction restart")
            }
        } catch {
            failures.append("strict ledger: basic storage flow [\(Self.failureCategory(error))]")
        }

        }
        let cross = tempDirectory()
        defer { try? FileManager.default.removeItem(at: cross) }
        let crossLedger = StrictLearningLedger(directory: cross)
        do {
            // Independent teacher observation of local spelling must contradict the later pair,
            // even though it was not a learning candidate when the teacher wrote it.
            try await crossLedger.observeTeacher(
                reference: "我们今天用了菲格玛设计界面", roundID: UUID(), at: at
            )
            var last: StrictLearningLedger.Outcome?
            for i in 0..<3 {
                last = try await crossLedger.ingest(
                    decisions: decisions, reference: reference, roundID: UUID(),
                    at: at.addingTimeInterval(Double(i) * 86_400), activeTerms: []
                )
            }
            if !(last?.promotions.isEmpty ?? false)
                || last?.promotionReasons.last != .contradicted {
                failures.append("strict ledger: independent teacher contradiction")
            }
        } catch {
            failures.append("strict ledger: contradiction storage [\(Self.failureCategory(error))]")
        }

        let dates = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dates) }
        let twoDates = StrictLearningLedger(directory: dates)
        do {
            let times = [at, at.addingTimeInterval(15), at.addingTimeInterval(86_400)]
            for i in times.indices {
                let value = try await twoDates.ingest(
                    decisions: decisions, reference: reference, roundID: UUID(), at: times[i], activeTerms: []
                )
                check(value, promoted: i == 2, context: "third across two dates")
            }
        } catch {
            failures.append("strict ledger: two-date threshold [\(Self.failureCategory(error))]")
        }

        if groups == nil || groups!.contains("caps") {
        let caps = tempDirectory()
        defer { try? FileManager.default.removeItem(at: caps) }
        let limited = StrictLearningLedger(directory: caps)
        do {
            for i in 0..<4 {
                let wrong = ["菲格玛", "Betagate", "Corder", "自带里"][i]
                let right = ["Figma", "Bitget", "Qoder", "子代理"][i]
                let teacher = before + right + after
                let candidate = StrictLearningFilter.analyze(local: before + wrong + after,
                    reference: teacher, commonChinese: { _ in false }, ordinaryEnglish: { _ in false })
                var last: StrictLearningLedger.Outcome?
                for j in 0..<3 {
                    last = try await limited.ingest(decisions: candidate, reference: teacher, roundID: UUID(),
                        at: at.addingTimeInterval(j == 2 ? 86_400 : Double(j)), activeTerms: [])
                }
                if i < 3 {
                    if last?.promotions.count != 1 { failures.append("strict ledger: daily slots") }
                    try await limited.finishPromotion(candidate[0].pair, success: true)
                } else if last?.promotionReasons.last != .dailyCap || last?.promotions.isEmpty != true {
                    failures.append("strict ledger: daily cap")
                }
            }
            let hundred = (0..<100).map {
                LexiconTerm(canonical: "已学\($0)", variants: ["旧错\($0)"], source: .automaticallyLearned)
            }
            let capped = try await limited.ingest(decisions: StrictLearningFilter.analyze(
                local: before + "自带里" + after, reference: before + "子代理" + after,
                commonChinese: { _ in false }, ordinaryEnglish: { _ in false }),
                reference: before + "子代理" + after, roundID: UUID(),
                at: at.addingTimeInterval(172_800), activeTerms: hundred)
            if capped.promotionReasons.last != .totalCap || !capped.promotions.isEmpty {
                failures.append("strict ledger: activity cap")
            }
            // The fourth pair denied by today's 3-slot cap remains eligible tomorrow.
            // A total-cap check above must not poison its original 3 sightings/2 dates.
            let nextDayReference = before + "子代理" + after
            let nextDayDecision = StrictLearningFilter.analyze(
                local: before + "自带里" + after, reference: nextDayReference,
                commonChinese: { _ in false }, ordinaryEnglish: { _ in false }
            )
            let rollover = try await limited.ingest(
                decisions: nextDayDecision, reference: nextDayReference, roundID: UUID(),
                at: at.addingTimeInterval(172_800 + 60), activeTerms: []
            )
            if rollover.promotions.count != 1 || rollover.promotionReasons.last != .ok {
                failures.append("strict ledger: fourth slot next-day rollover")
            }
            // A concurrent file change blocks further evidence; no promotion leaves a failed write.
            let poolURL = caps.appendingPathComponent("strict-learning-candidates.json")
            let originalPool = try Data(contentsOf: poolURL)
            let indexURL = caps.appendingPathComponent("strict-learning-teacher-index.json")
            let damagedIndex = Data("{}".utf8)
            try Self.replaceSyntheticBytes(damagedIndex, at: indexURL)
            guard try Data(contentsOf: indexURL) == damagedIndex else {
                throw NSError(domain: "R67SyntheticFixture", code: 2)
            }
            do {
                _ = try await limited.ingest(decisions: decisions, reference: reference,
                    roundID: UUID(), at: at.addingTimeInterval(259_200), activeTerms: [])
                failures.append("strict ledger: changed disk must fail closed")
            } catch { }
            if try Data(contentsOf: poolURL) != originalPool {
                failures.append("strict ledger: failed index preserves pool")
            }
        } catch {
            failures.append("strict ledger: caps and failure safety [\(Self.failureCategory(error))]")
        }
        }
        let single = tempDirectory()
        defer { try? FileManager.default.removeItem(at: single) }
        do {
            let store = LexiconStore(directory: single)
            _ = try await store.load()
            let added = try await store.addStrictAutomaticallyLearned(
                .init(variant: "讹", canonical: "正"), sightings: 3, at: at,
                permit: enabledPermit, epoch: enabledEpoch)
            let reloaded = LexiconStore(directory: single)
            let snapshot = try await reloaded.load()
            if added == nil || snapshot.apply(to: "今日讹字处理")?.text != "今日正字处理" {
                failures.append("strict store: single Han load and match")
            }
            do {
                _ = try await store.add(canonical: "人工", variants: ["错"], source: .manual)
                failures.append("strict store: human minimum must remain two")
            } catch { }
        } catch {
            failures.append("strict store: single Han admission [\(Self.failureCategory(error))]")
        }
        if groups == nil || groups!.contains("expire") {
        let expiration = tempDirectory()
        defer { try? FileManager.default.removeItem(at: expiration) }
        do {
            let store = LexiconStore(directory: expiration)
            _ = try await store.load()
            _ = try await store.addStrictAutomaticallyLearned(
                .init(variant: "旧错写", canonical: "正确词"), sightings: 3, at: at,
                permit: enabledPermit, epoch: enabledEpoch)
            let liveURL = expiration.appendingPathComponent(LexiconStore.fileName)
            let archiveURL = expiration.appendingPathComponent("auto-learned-archive.json")
            let original = try Data(contentsOf: liveURL)
            let damagedArchive = Data("{}".utf8)
            try Self.replaceSyntheticBytes(damagedArchive, at: archiveURL)
            guard try Data(contentsOf: archiveURL) == damagedArchive else {
                throw NSError(domain: "R67SyntheticFixture", code: 3)
            }
            do {
                try await store.expireAutomaticTerms(now: at.addingTimeInterval(31 * 86_400))
                failures.append("strict expire: unreadable archive must retain activity")
            } catch { }
            let retained = await store.allTerms()
            if try Data(contentsOf: liveURL) != original || retained.count != 1 {
                failures.append("strict expire: failure must preserve live bytes")
            }
            // Replace only the synthetic damaged archive with an empty valid document.
            let repairedArchive = Data("{\"version\":1,\"terms\":[]}".utf8)
            try Self.replaceSyntheticBytes(repairedArchive, at: archiveURL)
            guard try Data(contentsOf: archiveURL) == repairedArchive else {
                throw NSError(domain: "R67SyntheticFixture", code: 4)
            }
            try await store.expireAutomaticTerms(now: at.addingTimeInterval(31 * 86_400))
            let archived = try JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any]
            if !(await store.allTerms()).isEmpty || (archived?["terms"] as? [Any])?.count != 1 {
                failures.append("strict expire: archive before removal")
            }
        } catch {
            failures.append("strict expire: storage flow [\(Self.failureCategory(error))]")
        }
        }
        // Revoked before actor admission: even an otherwise valid queued store add
        // must neither append a term nor create lexicon.json.
        let revokedDirectory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: revokedDirectory) }
        do {
            let store = LexiconStore(directory: revokedDirectory)
            _ = try await store.load()
            let revokedPermit = EnhancementLearningPermit()
            let revokedEpoch = revokedPermit.update(enabled: true)
            _ = revokedPermit.update(enabled: false)
            let attempted = try await store.addStrictAutomaticallyLearned(
                .init(variant: "讹", canonical: "正"), sightings: 3, at: at,
                permit: revokedPermit, epoch: revokedEpoch
            )
            let terms = await store.allTerms()
            if attempted != nil || !terms.isEmpty ||
                FileManager.default.fileExists(atPath: revokedDirectory.appendingPathComponent(LexiconStore.fileName).path) {
                failures.append("strict permit: revoked epoch wrote to disk")
            }
        } catch {
            failures.append("strict permit: revoked write flow [\(Self.failureCategory(error))]")
        }
        return failures
    }
}
