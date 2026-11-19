import Foundation
import Darwin
@_spi(Testing) import VoicePointerCore

/// The personal lexicon: matcher rules, the correction diff, the dictation corrector and the store on disk.
/// Offline: temporary folders only, never the app's own data.
enum LexiconChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        failures += normalizationChecks()
        failures += matcherChecks()
        failures += correctorChecks()
        failures += diffChecks()
        failures += fuzzChecks()
        failures += await storeChecks()
        failures += await LegacyAutoMigrationR66Checks.run()
        return failures
    }

    // MARK: - Helpers

    private static func term(_ canonical: String, _ variants: [String], enabled: Bool = true) -> LexiconTerm {
        LexiconTerm(canonical: canonical, variants: variants, isEnabled: enabled)
    }

    private static func apply(_ terms: [LexiconTerm], _ text: String) -> String? {
        LexiconSnapshot(revision: 1, terms: terms).apply(to: text)?.text
    }

    // MARK: - Spelling rules

    private static func normalizationChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { if !condition { failures.append("normalize: \(label)") } }
        func problem(_ canonical: String, _ variants: [String]) -> LexiconValidationError? {
            do { _ = try LexiconText.normalize(canonical: canonical, variants: variants); return nil }
            catch let error as LexiconValidationError { return error }
            catch { return .termNotFound }
        }

        let cleaned = try? LexiconText.normalize(
            canonical: "  OpenAI ", variants: ["open ai", " Open AI ", "OpenAI", "   ", "欧朋爱"]
        )
        expect(cleaned?.canonical == "OpenAI", "the canonical spelling is trimmed")
        expect(cleaned?.variants == ["open ai", "欧朋爱"],
               "variants are trimmed, blanks and the canonical itself dropped, ASCII-case repeats merged")

        expect(problem("", ["ab"]) == .emptyCanonical, "an empty canonical spelling is refused")
        expect(problem("   ", ["ab"]) == .emptyCanonical, "a blank canonical spelling is refused")
        expect(problem("OpenAI", ["a"]) == .variantTooShort("a"), "a one-character wrong spelling is refused")
        expect(problem("OpenAI", ["，，"]) == .variantHasNoLetters("，，"), "a wrong spelling without letters or digits is refused")
        expect(problem("OpenAI", ["，在"]) == .variantTooShort("，在"), "punctuation does not count toward the two-character minimum")
        expect(problem("OpenAI", ["a."]) == .variantTooShort("a."), "one letter and a dot is still one character")
        expect(problem("OpenAI", [" 在 "]) == .variantTooShort("在"), "spaces around a single character do not make it two")
        expect(problem("OpenAI", ["a1"]) == nil, "two letters or digits are enough")
        expect(problem("OpenAI", ["v 2"]) == nil, "a space between real characters is fine")
        expect(problem("OpenAI", (0..<13).map { "wrong\($0)x" }) == .tooManyVariants, "more than 12 variants are refused")
        let long = String(repeating: "a", count: 65)
        expect(problem(long, ["ab"]) == .tooLong(long), "a canonical spelling over 64 characters is refused")
        expect(problem("OpenAI", [long]) == .tooLong(long), "a wrong spelling over 64 characters is refused")
        expect(problem("a\nb", ["ab"]) == .unsafeCharacters("a\nb"), "a line break inside a spelling is refused")
        expect(problem("a\u{200B}b", ["ab"]) == .unsafeCharacters("a\u{200B}b"), "an invisible format character is refused")
        expect(problem(String(repeating: "字", count: 400), ["ab"]) != nil, "an absurdly long spelling is refused without diffing it")
        expect(LexiconText.foldKey("OpenAI 欧AI") == "openai 欧ai", "only ASCII letters change case when folded")
        return failures
    }

    // MARK: - Matcher

    private static func matcherChecks() -> [String] {
        var failures: [String] = []
        func expect(_ actual: String?, _ expected: String, _ label: String) {
            if actual != expected {
                failures.append("matcher: \(label): got \(String(describing: actual)), want \(expected)")
            }
        }
        func check(_ condition: Bool, _ label: String) { if !condition { failures.append("matcher: \(label)") } }

        let openAI = term("OpenAI", ["open ai", "欧朋爱"])
        expect(apply([openAI], "我在用 open ai 写代码"), "我在用 OpenAI 写代码", "replaces an ASCII wrong spelling")
        expect(apply([openAI], "OPEN AI 很好"), "OpenAI 很好", "ASCII spellings ignore case")
        expect(apply([openAI], "用欧朋爱试试"), "用OpenAI试试", "replaces a Chinese wrong spelling")
        expect(apply([openAI], "reopen aidan"), "reopen aidan", "does not fire inside ASCII words")
        expect(apply([openAI], "open aid"), "open aid", "the end of a match must be a word edge too")
        expect(apply([openAI], "(open ai)"), "(OpenAI)", "punctuation is a word edge")
        expect(apply([openAI], "没有相关内容"), "没有相关内容", "text without a match is untouched")
        expect(apply([openAI], ""), "", "empty text stays empty")

        // Leftmost, longest; no overlaps.
        let longer = term("深圳市南山区", ["深圳南山"])
        let shorter = term("深圳市", ["深圳"])
        expect(apply([shorter, longer], "去深圳南山吃饭"), "去深圳市南山区吃饭", "the longest wrong spelling at a position wins")
        expect(apply([shorter, longer], "去深圳玩"), "去深圳市玩", "the shorter one still applies where the longer does not")
        // Already the right spelling around the match: leave it (idempotent, no "深圳市市").
        expect(apply([shorter], "去深圳市玩"), "去深圳市玩", "text that already reads as the canonical spelling is left alone")
        expect(apply([shorter], "深圳和深圳市"), "深圳市和深圳市", "only the bare occurrence changes")

        // Corrections never chain: they are computed from the recognizer's text, not from each other.
        expect(apply([term("bb", ["aa"]), term("cc", ["bb"])], "aa"), "bb", "entries do not chain")
        // First entry keeps a spelling that two entries claim.
        expect(apply([term("A1", ["xyz"]), term("B1", ["xyz"])], "xyz"), "A1", "an earlier entry keeps a duplicated spelling")

        // Mixed scripts and digits.
        let chatGPT = term("ChatGPT", ["chat gpt"])
        expect(apply([chatGPT], "我喜欢chat gpt和别的"), "我喜欢ChatGPT和别的", "an ASCII spelling next to Chinese text matches")
        let gpt4 = term("GPT-4", ["gpt 4"])
        expect(apply([gpt4], "gpt 45"), "gpt 45", "a digit after the match is not a word edge")
        expect(apply([gpt4], "gpt 4."), "GPT-4.", "punctuation after the match is a word edge")
        let gitHub = term("GitHub", ["github"])
        expect(apply([gitHub], "GITHUB 和 github"), "GitHub 和 GitHub", "case-only corrections apply")
        let untouched = LexiconSnapshot(revision: 1, terms: [gitHub]).apply(to: "GitHub")
        check(untouched?.text == "GitHub" && untouched?.hits.isEmpty == true, "already-correct casing is not a hit")
        expect(apply([shorter], "😀深圳😀"), "😀深圳市😀", "emoji around a match are kept")

        // "Already the right spelling around the match" ignores ASCII case, except when the two spellings
        // only differ by case (that is the fix itself).
        let copilot = term("GitHub Copilot", ["copilot"])
        expect(apply([copilot], "use copilot today"), "use GitHub Copilot today", "a short wrong spelling expands to the long one")
        expect(apply([copilot], "GitHub copilot"), "GitHub copilot", "the right spelling in another case is not doubled")
        expect(apply([copilot], "github COPILOT"), "github COPILOT", "the context test ignores ASCII case throughout")
        expect(apply([copilot], "GitHub Copilot"), "GitHub Copilot", "the right spelling is left alone")
        check(LexiconSnapshot(revision: 1, terms: [term("X1", ["，在"])]).ruleCount == 0,
              "a wrong spelling with one letter makes no rule even when nothing checked it before")

        // Switches and hot words.
        let off = LexiconSnapshot(revision: 1, terms: [term("OpenAI", ["open ai"], enabled: false)])
        check(off.isEmpty && off.apply(to: "open ai")?.text == "open ai", "a disabled entry does nothing")
        let hot = LexiconSnapshot(revision: 1, terms: [term("OpenAI", [])])
        check(hot.isEmpty && hot.ruleCount == 0, "a hot word without wrong spellings has no rules")
        check(LexiconSnapshot.empty.revision == 0 && LexiconSnapshot.empty.isEmpty, "the empty snapshot is revision 0")
        check(LexiconSnapshot(revision: 7, terms: [openAI]).revision == 7, "a snapshot keeps its revision")

        // Hits.
        let hits = LexiconSnapshot(revision: 1, terms: [openAI]).apply(to: "open ai 和 欧朋爱")
        check(hits?.hits.count == 2, "each replacement is one hit")
        check(hits?.hits.first?.termID == openAI.id && hits?.hits.first?.matched == "open ai"
              && hits?.hits.first?.canonical == "OpenAI", "a hit names its entry, the matched text and the replacement")

        // Limits: too long, and over budget, both mean "keep the recognizer's text".
        let big = LexiconSnapshot(revision: 1, terms: [openAI])
        check(big.apply(to: String(repeating: "a", count: LexiconSnapshot.maximumTextUTF8 + 1)) == nil,
              "text over the size limit is skipped")
        check(big.apply(to: String(repeating: "好", count: 5_000), budgetNanoseconds: 0) == nil,
              "work over the time budget is skipped")
        check(big.apply(to: String(repeating: "好", count: 5_000), budgetNanoseconds: 5_000_000_000) != nil,
              "a long dictation is corrected when the budget allows")
        return failures
    }

    // MARK: - Dictation corrector

    private static func correctorChecks() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) { if !condition { failures.append("corrector: \(label)") } }
        let openAI = term("OpenAI", ["open ai"])
        let corrector = DictationCorrector(lexicon: LexiconSnapshot(revision: 3, terms: [openAI]))
        let sessionID = UUID()
        let partial = SpeechInputEvent(
            sessionID: sessionID, sequence: 4, observedMilliseconds: 12.5, kind: .partial, text: "我在用 open ai"
        )
        let corrected = corrector.correct(partial, mode: .voiceNative)
        check(corrected.event.text == "我在用 OpenAI" && corrected.hits.count == 1, "a recognizer partial is corrected")
        check(corrected.event.sessionID == sessionID && corrected.event.sequence == 4
              && corrected.event.kind == .partial && corrected.event.observedMilliseconds == 12.5,
              "only the text of an event changes")

        let untouched = corrector.correct(partial, mode: .doubao)
        check(untouched.event == partial && untouched.hits.isEmpty, "the Doubao route is never corrected")

        let ready = SpeechInputEvent(sessionID: sessionID, sequence: 0, observedMilliseconds: 0, kind: .ready)
        check(corrector.correct(ready, mode: .voiceNative).event == ready, "an event without text passes through")

        check(!DictationCorrector.none.isActive && DictationCorrector.none.correct(partial, mode: .voiceNative).event == partial,
              "no lexicon means no correction")
        check(!DictationCorrector(lexicon: nil).isActive, "a nil lexicon is inactive")
        let text = corrector.correct("open ai 和 open ai", mode: .voiceNative)
        check(text.text == "OpenAI 和 OpenAI" && text.hits.count == 2, "plain text is corrected with its hits")
        return failures
    }

    // MARK: - Correction diff

    private static func diffChecks() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) { if !condition { failures.append("diff: \(label)") } }
        func rule(_ before: String, _ after: String) -> [String]? {
            if case .success(let suggestion) = CorrectionDiff.derive(before: before, after: after) {
                return [suggestion.variant, suggestion.canonical]
            }
            return nil
        }
        func refusal(_ before: String, _ after: String) -> CorrectionDiff.Rejection? {
            if case .failure(let rejection) = CorrectionDiff.derive(before: before, after: after) { return rejection }
            return nil
        }

        check(rule("今天去北京", "今天去上海") == ["北京", "上海"], "a replaced phrase becomes a rule")
        check(rule("我在深圳工作", "我在深圳市工作") == ["深圳", "深圳市"],
              "an insertion is widened to a wrong spelling of two characters")
        check(rule("我们想吃苹果派", "我们想吃苹果派对") == ["果派", "果派对"], "an insertion at the end widens to the left")
        check(rule("我我们去吧", "我们去吧") == ["我我", "我"], "a deletion is widened until it is a spelling")
        check(rule("use github today", "use GitHub today") == ["github", "GitHub"],
              "a change inside an ASCII word widens to the whole word")
        check(rule("chat gbt", "chat gpt") == ["gbt", "gpt"], "only the wrong word is taken, not its neighbours")
        check(rule("try chat gpt now", "try ChatGPT now") == ["chat gpt", "ChatGPT"], "two words fused into one product name")
        check(rule("Python 3", "Python 2") == ["Python 3", "Python 2"], "a digit is widened over the space to the word before it")
        check(rule("好的，在见", "好的，再见") == ["在见", "再见"], "context grows toward the letter, not across the comma")
        check(rule("买 3 个", "买 4 个") == ["买 3", "买 4"], "a spelling never begins or ends with a space")
        check(rule("Git Hub", "GitHub") == ["Git Hub", "GitHub"], "a space removed inside an English word is a spelling")
        check(rule("use Git Hub now", "use GitHub now") == ["Git Hub", "GitHub"], "a joined word is taken whole, not its neighbours")
        check(rule("GitHub", "Git Hub") == ["GitHub", "Git Hub"], "a space added inside an English word is a spelling")
        check(refusal("Hello  world", "Hello world") == .notASpelling, "a doubled space collapsed is formatting")
        check(refusal("你好，世界", "你好世界") == .notASpelling, "a comma removed between Chinese words is formatting")
        check(refusal("一样", "一样") == .unchanged, "no change is refused")
        check(refusal("你好", "你好。") == .notASpelling, "adding punctuation is refused")
        check(refusal("你好世界", "你好 世界") == .notASpelling, "adding a space is refused")
        check(refusal("好", "行") == .notASpelling, "a whole one-character text cannot become a rule")
        check(refusal("好的", "") == .notASpelling, "deleting everything is refused")
        check(refusal(String(repeating: "甲", count: 20), String(repeating: "乙", count: 20)) == .tooLarge,
              "a rewrite of a whole sentence is refused")

        // From a recent dictation: the wrong spelling must be in the recognizer's own text.
        let openAI = term("OpenAI", ["open ai"])
        let application = LexiconSnapshot(revision: 1, terms: [openAI]).apply(to: "今天用open ai写代码")
        let record = DictationRecord(
            rawText: "今天用open ai写代码", text: application?.text ?? "", hits: application?.hits ?? [],
            routeID: "qwen17-rolling"
        )
        check(record.text == "今天用OpenAI写代码" && record.hits.count == 1, "the fixture is a corrected dictation")
        if case .success(let suggestion) = record.suggestion(afterEditingTo: "今天用OpenAI写程序") {
            check(suggestion.variant == "代码" && suggestion.canonical == "程序", "a fix elsewhere in the sentence becomes a rule")
        } else {
            failures.append("diff: a fix outside the corrected part must be accepted")
        }
        if case .failure(let rejection) = record.suggestion(afterEditingTo: "今天用OpenAI2写代码") {
            check(rejection == .alreadyCorrected, "editing a part the lexicon already corrected is reported as such")
        } else {
            failures.append("diff: editing text the lexicon produced must not become a rule on the recognizer's text")
        }
        // A rule that occurs in the recognizer's text but could never fire there is refused, not saved.
        let glued = DictationRecord(rawText: "reopen ai", text: "re open ai", hits: [], routeID: "qwen17-rolling")
        if case .failure(let rejection) = glued.suggestion(afterEditingTo: "re OpenAI") {
            check(rejection == .wouldNotMatch, "a rule that word edges would stop is reported")
        } else {
            failures.append("diff: a rule that cannot fire on the recognizer's text must be refused")
        }
        let plain = DictationRecord(rawText: "wait I said hi", text: "wait I said hi", hits: [], routeID: "qwen17-rolling")
        if case .success(let suggestion) = plain.suggestion(afterEditingTo: "wait I sad hi") {
            check(suggestion.variant == "said" && suggestion.canonical == "sad", "a rule that fires is accepted")
        } else {
            failures.append("diff: a rule that fires on the recognizer's text must be accepted")
        }
        return failures
    }

    // MARK: - Fuzz (seeded, so a failure reproduces)

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(bound, 1))) }
    }

    private static let pieces = [
        "a", "B", "c", "g", "p", "t", "open", " ", "  ", "1", "-", "，", "。", "深", "圳", "市", "我", "们", "好",
        "😀", "é", "e\u{0301}", "\r\n", "\n", "\t", "GitHub", "gpt", "OpenAI", "ai", "AI", "\u{200B}", "、",
    ]

    private static func randomText(_ random: inout SplitMix64, maxPieces: Int = 12) -> String {
        (0..<random.below(maxPieces + 1)).map { _ in pieces[random.below(pieces.count)] }.joined()
    }

    private static func mutate(_ text: String, _ random: inout SplitMix64) -> String {
        var characters = Array(text)
        switch random.below(3) {
        case 0:
            characters.insert(contentsOf: Array(pieces[random.below(pieces.count)]), at: random.below(characters.count + 1))
        case 1:
            if !characters.isEmpty {
                let start = random.below(characters.count)
                characters.removeSubrange(start..<min(characters.count, start + 1 + random.below(4)))
            }
        default:
            if !characters.isEmpty {
                let start = random.below(characters.count)
                let end = min(characters.count, start + 1 + random.below(4))
                characters.replaceSubrange(start..<end, with: Array(pieces[random.below(pieces.count)]))
            }
        }
        return String(characters)
    }

    private static func fuzzChecks() -> [String] {
        var failures: [String] = []
        var random = SplitMix64(state: 0x5EED_1E71_C0DE)

        // The correction diff: never traps, and whatever it returns is a rule that fits both texts.
        var accepted = 0
        for round in 0..<20_000 {
            let before = randomText(&random)
            let after = round % 5 == 0 ? randomText(&random) : mutate(before, &random)
            guard case .success(let suggestion) = CorrectionDiff.derive(before: before, after: after) else { continue }
            accepted += 1
            let shapeOK = suggestion.variant.count >= LexiconLimits.minVariantCharacters
                && suggestion.variant.count <= CorrectionDiff.maxSpan
                && !suggestion.canonical.isEmpty && suggestion.canonical.count <= CorrectionDiff.maxSpan
                && suggestion.variant != suggestion.canonical
            let fitsTexts = LexiconText.foldKey(before).contains(LexiconText.foldKey(suggestion.variant))
                && after.contains(suggestion.canonical)
            if !shapeOK || !fitsTexts {
                failures.append("fuzz diff: bad rule \(suggestion.variant.debugDescription) → \(suggestion.canonical.debugDescription) for \(before.debugDescription) → \(after.debugDescription)")
                break
            }
        }
        if accepted < 1_000 { failures.append("fuzz diff: only \(accepted) of 20000 random edits produced a rule; the generator is broken") }

        // The matcher: never traps; a result with no hits is the input; every hit's canonical is in the output.
        var applied = 0
        for _ in 0..<3_000 {
            var terms: [LexiconTerm] = []
            for _ in 0..<(1 + random.below(4)) {
                let canonical = randomText(&random, maxPieces: 4)
                let variants = (0..<(1 + random.below(3))).map { _ in randomText(&random, maxPieces: 3) }
                guard let cleaned = try? LexiconText.normalize(canonical: canonical, variants: variants) else { continue }
                terms.append(LexiconTerm(canonical: cleaned.canonical, variants: cleaned.variants))
            }
            let snapshot = LexiconSnapshot(revision: 1, terms: terms)
            let text = randomText(&random, maxPieces: 20)
            guard let result = snapshot.apply(to: text, budgetNanoseconds: 5_000_000_000) else {
                failures.append("fuzz matcher: a short text was skipped")
                break
            }
            if result.hits.isEmpty {
                if result.text != text { failures.append("fuzz matcher: text changed without a hit for \(text.debugDescription)"); break }
            } else {
                applied += 1
                if result.hits.contains(where: { !result.text.contains($0.canonical) }) {
                    failures.append("fuzz matcher: a hit's canonical spelling is missing from \(result.text.debugDescription)")
                    break
                }
            }
        }
        if applied < 20 { failures.append("fuzz matcher: only \(applied) random texts matched; the generator is broken") }
        return failures
    }

    // MARK: - Store

    private static func storeChecks() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { if !condition { failures.append("store: \(label)") } }
        let fm = FileManager.default
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true
        ).appendingPathComponent("LexiconChecks-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch {
            return ["store: cannot create the temporary folder \(root.path): \(error.localizedDescription)"]
        }
        defer { try? fm.removeItem(at: root) }

        var scenario = 0
        func freshDirectory() -> URL {
            scenario += 1
            return root.appendingPathComponent("s\(scenario)/Lexicon", isDirectory: true)
        }
        func permissions(_ url: URL) -> Int? {
            (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        }
        func names(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        }
        func addError(_ store: LexiconStore, _ canonical: String, _ variants: [String]) async -> LexiconStore.StoreError? {
            do { _ = try await store.add(canonical: canonical, variants: variants); return nil }
            catch let error as LexiconStore.StoreError { return error }
            catch { return .unavailable("other") }
        }
        func loadError(_ store: LexiconStore) async -> LexiconStore.StoreError? {
            do { _ = try await store.load(); return nil }
            catch let error as LexiconStore.StoreError { return error }
            catch { return .unavailable("other") }
        }
        func writeFile(_ text: String, to url: URL, mode: Int = 0o600) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            try? Data(text.utf8).write(to: url)
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        func isUnavailable(_ error: LexiconStore.StoreError?) -> Bool {
            if case .unavailable? = error { return true }
            return false
        }

        // A missing folder is an empty lexicon, and nothing is created for it. Nothing can be written before load.
        let dir1 = freshDirectory()
        let store = LexiconStore(directory: dir1, hitFlushDelay: 0.05)
        expect(await addError(store, "OpenAI", ["open ai"]) == .notLoaded, "changes are refused before load")
        let first = try? await store.load()
        expect(first?.isEmpty == true && (first?.revision ?? 0) >= 1, "a missing folder loads as an empty lexicon")
        expect(!fm.fileExists(atPath: dir1.path), "loading must not create the folder")

        // The first change creates a private folder and file, and leaves no temporary file behind.
        let added = try? await store.add(canonical: "OpenAI", variants: ["open ai", "欧朋爱"])
        expect(added?.kind == .created && added?.term.variants == ["open ai", "欧朋爱"], "a new entry is created")
        expect(permissions(dir1) == 0o700, "the folder is private (0700)")
        expect(permissions(store.fileURL) == 0o600, "the file is private (0600)")
        expect(names(dir1) == ["lexicon.json"], "no temporary file is left behind")
        let object = (try? Data(contentsOf: store.fileURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        expect(object?["version"] as? Int == 1, "the file carries its version")

        // A second instance reads what the first wrote.
        let reader = LexiconStore(directory: dir1)
        let readerSnapshot = try? await reader.load()
        let readTerms = await reader.allTerms()
        expect(readTerms.count == 1 && readTerms.first?.id == added?.term.id && readTerms.first?.canonical == "OpenAI"
               && readTerms.first?.variants == ["open ai", "欧朋爱"], "the entry survives a reload")
        expect(readerSnapshot?.apply(to: "用 open ai")?.text == "用 OpenAI", "the reloaded matcher works")

        // Same canonical spelling: the new variants are merged, ASCII-case repeats are not added twice.
        let merged = try? await store.add(canonical: "OpenAI", variants: ["open a i", "OPEN AI"])
        expect(merged?.kind == .mergedIntoExisting && merged?.term.variants == ["open ai", "欧朋爱", "open a i"],
               "the same canonical spelling merges its wrong spellings")
        expect(await store.allTerms().count == 1, "merging does not create a second entry")

        // A wrong spelling belongs to one entry: the newest instruction wins and says who lost it.
        let moved = try? await store.add(canonical: "Open AI Inc", variants: ["open ai"])
        expect(moved?.takenFrom == ["OpenAI"], "taking a spelling from another entry is reported")
        let afterMove = await store.snapshot()
        expect(afterMove.apply(to: "open ai")?.text == "Open AI Inc", "the spelling now belongs to the newer entry")
        let revisionBefore = afterMove.revision

        // Hit counters: in memory at once, on disk later, and they never change the matcher's revision.
        if let target = added?.term.id {
            await store.recordHits([target: 2, UUID(): 5])
            let counted = await store.allTerms().first(where: { $0.id == target })
            expect(counted?.hitCount == 2 && counted?.lastHitAt != nil, "hits are counted in memory")
            expect(await store.snapshot().revision == revisionBefore, "counting hits does not change the revision")
            try? await Task.sleep(for: .milliseconds(400))
            let hitReader = LexiconStore(directory: dir1)
            _ = try? await hitReader.load()
            expect(await hitReader.allTerms().first(where: { $0.id == target })?.hitCount == 2,
                   "the hit counter is flushed after its delay")
        } else {
            failures.append("store: fixture entry missing")
        }

        // Updating, switching, removing.
        if let target = added?.term.id {
            let updated = try? await store.update(id: target, canonical: "OpenAI Inc.", variants: ["openai inc"], isEnabled: true)
            expect(updated?.term.canonical == "OpenAI Inc." && updated?.term.variants == ["openai inc"], "an entry can be edited")
            let duplicate = try? await store.update(id: target, canonical: "Open AI Inc", variants: ["zz zz"], isEnabled: true)
            expect(duplicate == nil, "editing to another entry's canonical spelling is refused")
            do {
                _ = try await store.update(id: UUID(), canonical: "X", variants: ["xx"], isEnabled: true)
                failures.append("store: editing an unknown entry must throw")
            } catch let error as LexiconStore.StoreError {
                expect(error == .validation(.termNotFound), "editing an unknown entry says so")
            } catch {
                failures.append("store: unexpected error type")
            }
            try? await store.setEnabled(id: target, false)
            expect(await store.snapshot().apply(to: "openai inc")?.text == "openai inc", "a disabled entry stops matching")
            try? await store.setEnabled(id: target, true)
            expect(await store.snapshot().apply(to: "openai inc")?.text == "OpenAI Inc.", "an enabled entry matches again")
            try? await store.remove(id: target)
            expect(await store.allTerms().count == 1, "an entry can be removed")
        }
        try? await store.removeAll()
        let clearedTerms = await store.allTerms()
        let clearedSnapshot = await store.snapshot()
        expect(clearedTerms.isEmpty && clearedSnapshot.isEmpty, "the lexicon can be cleared")

        // Validation surfaces through the store.
        let validating = LexiconStore(directory: freshDirectory())
        _ = try? await validating.load()
        expect(await addError(validating, "", ["ab"]) == .validation(.emptyCanonical), "empty canonical spelling")
        expect(await addError(validating, "OpenAI", ["a"]) == .validation(.variantTooShort("a")), "one-character wrong spelling")
        expect(await addError(validating, "OpenAI", (0..<13).map { "wrong\($0)x" }) == .validation(.tooManyVariants), "13 variants")
        expect(await addError(validating, "a\nb", ["ab"]) == .validation(.unsafeCharacters("a\nb")), "line break")
        expect(await validating.allTerms().isEmpty, "a refused change leaves the list alone")

        // A file over the entry limit keeps the first 2000 and backs up the original; then the list is full.
        let dirMax = freshDirectory()
        var many = "{\"version\":1,\"terms\":["
        many += (0..<2_001).map { "{\"id\":\"\(UUID().uuidString)\",\"canonical\":\"词\($0)\",\"variants\":[\"错写\($0)\"]}" }
            .joined(separator: ",")
        many += "]}"
        writeFile(many, to: dirMax.appendingPathComponent("lexicon.json"))
        let maxStore = LexiconStore(directory: dirMax)
        _ = try? await maxStore.load()
        expect(await maxStore.allTerms().count == LexiconLimits.maxTerms, "only 2000 entries are kept")
        expect(names(dirMax).contains(where: { $0.hasPrefix("lexicon.json.dropped-") }), "the original file is backed up before entries are dropped")
        expect(await addError(maxStore, "一个新词", ["新的错写"]) == .validation(.tooManyTerms), "a full lexicon refuses a new entry")

        // A broken entry loses only itself; the original is kept as a backup.
        let dirLenient = freshDirectory()
        writeFile("{\"version\":1,\"terms\":[{\"canonical\":\"OpenAI\",\"variants\":[\"open ai\"]},{\"variants\":[\"xx\"]},{\"canonical\":\"Bad\",\"variants\":[\"a\"]}]}",
                  to: dirLenient.appendingPathComponent("lexicon.json"))
        let lenient = LexiconStore(directory: dirLenient)
        _ = try? await lenient.load()
        expect(await lenient.allTerms().map(\.canonical) == ["OpenAI"], "entries that cannot be read are dropped, the rest stay")
        expect(names(dirLenient).contains(where: { $0.hasPrefix("lexicon.json.dropped-") }), "dropping an entry keeps a backup of the file")

        // The backup of dropped entries is named after its content: loading the same file again adds nothing.
        let droppedBackups = { names(dirLenient).filter { $0.hasPrefix("lexicon.json.dropped-") }.count }
        expect(droppedBackups() == 1, "one file with dropped entries leaves one backup")
        _ = try? await lenient.load()
        _ = try? await LexiconStore(directory: dirLenient).load()
        expect(droppedBackups() == 1, "loading the same file again does not write another backup")

        // If that backup cannot be written the lexicon is not loaded at all: saving would destroy the only copy.
        if geteuid() != 0 {
            let dirNoBackup = freshDirectory()
            writeFile("{\"version\":1,\"terms\":[{\"canonical\":\"OpenAI\",\"variants\":[\"open ai\"]},{\"canonical\":\"Bad\",\"variants\":[\"a\"]}]}",
                      to: dirNoBackup.appendingPathComponent("lexicon.json"))
            _ = chmod(dirNoBackup.path, 0o500)
            let noBackup = LexiconStore(directory: dirNoBackup)
            let refusedLoad = await loadError(noBackup)
            _ = chmod(dirNoBackup.path, 0o700)
            expect(isUnavailable(refusedLoad), "a file whose dropped entries cannot be backed up is not loaded")
            expect(await addError(noBackup, "新词", ["错写词"]) == .notLoaded, "nothing is written while it is not loaded")
        }

        // Bookkeeping fields are read leniently: a bad counter costs the counter, not the entry.
        let dirCounters = freshDirectory()
        writeFile("{\"version\":1,\"terms\":[{\"canonical\":\"OpenAI\",\"variants\":[\"open ai\"],\"hits\":1e30,\"enabled\":\"yes\",\"createdAt\":\"long ago\"},"
                  + "{\"canonical\":\"Deep\",\"variants\":[\"deep seek\"],\"hits\":9223372036854775807},"
                  + "{\"canonical\":\"Neg\",\"variants\":[\"neg ative\"],\"hits\":-5}]}",
                  to: dirCounters.appendingPathComponent("lexicon.json"))
        let counters = LexiconStore(directory: dirCounters)
        _ = try? await counters.load()
        let counted = await counters.allTerms()
        expect(counted.map(\.canonical) == ["OpenAI", "Deep", "Neg"], "entries with bad bookkeeping stay")
        expect(counted.map(\.hitCount) == [0, LexiconLimits.maxHitCount, 0], "counters are clamped to 0...limit, a bad one reads as 0")
        expect(counted.first?.isEnabled == true, "a bad switch reads as on")
        expect(!names(dirCounters).contains(where: { $0.hasPrefix("lexicon.json.dropped-") }), "nothing is dropped for a bad counter")

        // One call cannot fill the counter, and the counter stops at its limit.
        let dirHits = freshDirectory()
        let hitStore = LexiconStore(directory: dirHits, hitFlushDelay: 30)
        _ = try? await hitStore.load()
        let hitTerm = try? await hitStore.add(canonical: "OpenAI", variants: ["open ai"])
        if let target = hitTerm?.term.id {
            await hitStore.recordHits([target: 5_000_000])
            expect(await hitStore.allTerms().first?.hitCount == 10_000, "one call adds at most 10,000 hits")
            for _ in 0..<200 { await hitStore.recordHits([target: 10_000]) }
            expect(await hitStore.allTerms().first?.hitCount == LexiconLimits.maxHitCount, "the counter stops at its limit")
        } else {
            failures.append("store: hit fixture entry missing")
        }

        // A file changed outside the app is never overwritten: the write is refused and a reload sees the edit.
        let outsideEdit = "{\"version\":1,\"terms\":[{\"canonical\":\"DeepSeek\",\"variants\":[\"deep seek\"]}]}"
        let dirOutside = freshDirectory()
        let outside = LexiconStore(directory: dirOutside)
        _ = try? await outside.load()
        _ = try? await outside.add(canonical: "OpenAI", variants: ["open ai"])
        writeFile(outsideEdit, to: outside.fileURL)
        expect(await addError(outside, "新词", ["错写词"]) == .changedOnDisk, "a change made outside the app is not overwritten")
        expect((try? String(contentsOf: outside.fileURL, encoding: .utf8)) == outsideEdit, "the outside edit is still what is on disk")
        expect(await outside.allTerms().map(\.canonical) == ["OpenAI"], "memory still shows what the app knew until it reloads")
        _ = try? await outside.load()
        expect(await outside.allTerms().map(\.canonical) == ["DeepSeek"], "a reload picks up the outside edit")
        expect(await addError(outside, "新词", ["错写词"]) == nil, "changes work again after the reload")
        // A hit flush is refused the same way; the person's file is not rewritten for a counter.
        let dirFlush = freshDirectory()
        let flusher = LexiconStore(directory: dirFlush, hitFlushDelay: 30)
        _ = try? await flusher.load()
        let flushTerm = try? await flusher.add(canonical: "OpenAI", variants: ["open ai"])
        if let target = flushTerm?.term.id {
            await flusher.recordHits([target: 1])
            writeFile(outsideEdit, to: flusher.fileURL)
            do {
                try await flusher.flush()
                failures.append("store: a flush over an outside edit must throw")
            } catch let error as LexiconStore.StoreError {
                expect(error == .changedOnDisk, "a flush over an outside edit says the file changed")
            } catch {
                failures.append("store: unexpected error type from flush")
            }
            expect((try? String(contentsOf: flusher.fileURL, encoding: .utf8)) == outsideEdit, "a flush leaves an outside edit alone")
        } else {
            failures.append("store: flush fixture entry missing")
        }
        // The file being deleted from outside counts as a change too.
        let dirGone = freshDirectory()
        let gone = LexiconStore(directory: dirGone)
        _ = try? await gone.load()
        _ = try? await gone.add(canonical: "OpenAI", variants: ["open ai"])
        try? fm.removeItem(at: gone.fileURL)
        expect(await addError(gone, "新词", ["错写词"]) == .changedOnDisk, "a file deleted outside the app is noticed")

        // An unreadable file is never overwritten; recovery moves it aside byte for byte, on request only.
        let dirBad = freshDirectory()
        let badBytes = "this is not json {"
        writeFile(badBytes, to: dirBad.appendingPathComponent("lexicon.json"))
        let bad = LexiconStore(directory: dirBad)
        expect(await loadError(bad) == .malformed, "a file that is not a lexicon is reported as malformed")
        expect(await addError(bad, "OpenAI", ["open ai"]) == .notLoaded, "nothing is written while the file is unreadable")
        expect((try? String(contentsOf: bad.fileURL, encoding: .utf8)) == badBytes, "the unreadable file is left untouched")
        let backup = try? await bad.recoverMalformed()
        expect(backup.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == badBytes, "recovery keeps the old bytes in a backup")
        expect(!fm.fileExists(atPath: bad.fileURL.path), "recovery moves the unreadable file away")
        expect(await addError(bad, "OpenAI", ["open ai"]) == nil, "after recovery the lexicon accepts entries")
        expect(await (try? bad.recoverMalformed()) == nil, "recovery refuses a file that reads fine")

        // Version 0 or below is a damaged file, not a newer one.
        let dirZero = freshDirectory()
        writeFile("{\"version\":0,\"terms\":[]}", to: dirZero.appendingPathComponent("lexicon.json"))
        expect(await loadError(LexiconStore(directory: dirZero)) == .malformed, "version 0 reads as malformed")
        let dirNegative = freshDirectory()
        writeFile("{\"version\":-3,\"terms\":[]}", to: dirNegative.appendingPathComponent("lexicon.json"))
        expect(await loadError(LexiconStore(directory: dirNegative)) == .malformed, "a negative version reads as malformed")

        // A newer file format is refused, not misread or overwritten.
        let dirNew = freshDirectory()
        writeFile("{\"version\":99,\"terms\":[]}", to: dirNew.appendingPathComponent("lexicon.json"))
        expect(await loadError(LexiconStore(directory: dirNew)) == .unsupportedVersion(99), "a newer file version is refused")

        // Symlinks are never followed: neither the file nor the folder.
        let dirLink = freshDirectory()
        let realTarget = root.appendingPathComponent("target.json")
        writeFile("{\"version\":1,\"terms\":[]}", to: realTarget)
        try? fm.createDirectory(at: dirLink, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createSymbolicLink(at: dirLink.appendingPathComponent("lexicon.json"), withDestinationURL: realTarget)
        expect(isUnavailable(await loadError(LexiconStore(directory: dirLink))), "a symlinked lexicon file is refused")
        expect((try? String(contentsOf: realTarget, encoding: .utf8)) == "{\"version\":1,\"terms\":[]}", "the symlink target is untouched")
        let realFolder = root.appendingPathComponent("real-folder", isDirectory: true)
        try? fm.createDirectory(at: realFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let linkFolder = root.appendingPathComponent("link-folder", isDirectory: true)
        try? fm.createSymbolicLink(at: linkFolder, withDestinationURL: realFolder)
        expect(isUnavailable(await loadError(LexiconStore(directory: linkFolder))), "a symlinked lexicon folder is refused")

        // Looser permissions on a folder and file we own are tightened.
        let dirLoose = freshDirectory()
        writeFile("{\"version\":1,\"terms\":[]}", to: dirLoose.appendingPathComponent("lexicon.json"), mode: 0o644)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dirLoose.path)
        _ = try? await LexiconStore(directory: dirLoose).load()
        expect(permissions(dirLoose) == 0o700 && permissions(dirLoose.appendingPathComponent("lexicon.json")) == 0o600,
               "a too-open folder and file are tightened to owner-only")

        // A write that fails changes nothing (skipped when running as root, which ignores the mode).
        if geteuid() != 0 {
            let dirRO = freshDirectory()
            let readOnly = LexiconStore(directory: dirRO)
            _ = try? await readOnly.load()
            _ = try? await readOnly.add(canonical: "OpenAI", variants: ["open ai"])
            _ = chmod(dirRO.path, 0o500)
            let refused = await addError(readOnly, "新词", ["错写词"])
            _ = chmod(dirRO.path, 0o700)
            expect(isUnavailable(refused), "a failed write is reported")
            expect(await readOnly.allTerms().map(\.canonical) == ["OpenAI"], "a failed write leaves the list as it was")
            expect(await addError(readOnly, "新词", ["错写词"]) == nil, "the store recovers once writing works again")
        }

        // Many callers at once: every entry lands and the file stays valid.
        let dirBusy = freshDirectory()
        let busy = LexiconStore(directory: dirBusy)
        _ = try? await busy.load()
        let landed = await withTaskGroup(of: Bool.self) { group -> Int in
            for index in 0..<20 {
                group.addTask { (try? await busy.add(canonical: "词\(index)", variants: ["错写\(index)"])) != nil }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }
        expect(landed == 20, "concurrent additions all succeed")
        let busyReader = LexiconStore(directory: dirBusy)
        _ = try? await busyReader.load()
        expect(await busyReader.allTerms().count == 20, "the file holds every concurrent addition")
        expect(!names(dirBusy).contains(where: { $0.contains(".tmp.") }), "no temporary files after concurrent writes")
        return failures
    }
}
