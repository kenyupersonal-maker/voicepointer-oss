import Foundation
@_spi(Testing) import VoicePointerCore

/// Learning from the person's own corrections: the sound-alike filter, the split of one edit into fixes, the
/// span tracker, the learner end to end and the ledger. Pure logic; no Accessibility, clipboard or disk.
enum LearningChecks {
    static func run() -> [String] {
        var failures: [String] = []
        failures += plausibilityChecks()
        failures += hunkChecks()
        failures += trackerChecks()
        failures += learnerChecks()
        failures += ledgerChecks()
        return failures
    }

    // MARK: - Sound-alike filter

    private static func plausibilityChecks() -> [String] {
        var failures: [String] = []
        func expect(_ variant: String, _ canonical: String, _ expected: CorrectionPlausibility.Verdict) {
            let actual = CorrectionPlausibility.judge(variant: variant, canonical: canonical)
            if actual != expected {
                failures.append("plausibility: \(variant) → \(canonical): expected \(expected), got \(actual)")
            }
        }
        func expectRejected(_ variant: String, _ canonical: String) {
            if case .accept(let confidence) = CorrectionPlausibility.judge(variant: variant, canonical: canonical) {
                failures.append("plausibility: \(variant) → \(canonical): must be rejected, was accepted as \(confidence)")
            }
        }

        // Distinctive names, phrases and brands: the same fix seen twice may be taken as the person's wish.
        let strong = CorrectionPlausibility.Verdict.accept(.strong)
        for (variant, canonical) in [
            ("open ai", "OpenAI"), ("cloud code", "Claude Code"), ("chat gbt", "ChatGPT"), ("Git Hub", "GitHub"),
            ("github", "GitHub"), ("iphone", "iPhone"), ("Worker Body", "WorkBuddy"), ("gpt 4", "GPT-4"),
            ("吉特哈布", "GitHub"), ("欧朋爱", "OpenAI"), ("克劳德扣的", "Claude Code"), ("特斯拉", "Tesla"),
            ("克劳德", "Claude"), ("微软雅黑", "薇软亚黑"),
        ] {
            expect(variant, canonical, strong)
        }

        // Real words, one-word spellings and short spellings: worth showing, never added on their own.
        let weak = CorrectionPlausibility.Verdict.accept(.weak)
        for (variant, canonical) in [
            ("cloud", "Claude"), ("gbt", "gpt"), ("Antropic", "Anthropic"), ("Coder", "qoder"), ("python", "Python"),
            ("Tuesday", "Thursday"), ("北京", "背景"), ("项目经里", "项目经理"), ("api", "API"),
            ("stop", "STOP"), ("json", "JSON"), ("please note", "PLEASE NOTE"), ("hello", "Hello"),
            ("cloud code", "kelaode"),
        ] {
            expect(variant, canonical, weak)
        }

        // A change of meaning, of a number or of a small word depends on the sentence.
        expect("Python 3", "Python 2", .reject(.digits))
        expect("版本三", "版本四", .reject(.digits))
        expect("允许", "不允许", .reject(.insertionOrDeletion))
        expect("那个我们", "我们", .reject(.insertionOrDeletion))
        expect("to", "two", .reject(.functionWord))
        expect("their", "there", .reject(.functionWord))
        expect("not working", "now working", .reject(.functionWord))
        expect("跑的", "跑得", .reject(.functionWord))
        expect("他说", "她说", .reject(.functionWord))
        expect("在见", "再见", .reject(.functionWord))
        // Pinyin still standing in the field is an input method composing, not a spelling.
        expect("在见", "zai见", .reject(.composition))
        expect("克劳德", "ke'lao'de", .reject(.composition))
        expect("你好", "你好。", .reject(.nothingLeft))
        expect("こんにちは", "hello", .reject(.script))
        // Small words in capitals are grammar; whole English words added or dropped are a change of wording.
        expect("it", "IT", .reject(.functionWord))
        expect("never", "NEVER", .reject(.functionWord))
        expect("the", "The", .reject(.functionWord))
        expect("final report", "report", .reject(.insertionOrDeletion))
        expect("report", "final report", .reject(.insertionOrDeletion))
        expect("quick review", "review", .reject(.insertionOrDeletion))
        expect("code", "Claude code", .reject(.insertionOrDeletion))
        expect("公式", "公司的", .reject(.insertionOrDeletion))
        // Pinyin typed with the usual blurring (sh/s, ng/n) is an input method composing too.
        expect("私人", "shiren", .reject(.composition))
        expect("经里", "jinli", .reject(.composition))
        expectRejected("北京", "上海")
        expectRejected("tomorrow", "today")
        expectRejected("脸书", "Facebook")
        expectRejected("苹果", "Apple")
        expectRejected("cloud", "cloud")
        return failures
    }

    // MARK: - One edit into fixes

    private static func hunkChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { if !condition { failures.append("hunks: \(label)") } }
        func fixes(_ delivered: String, _ edited: String) -> [String]? {
            if case .fixes(let list) = CorrectionHunks.split(delivered: delivered, edited: edited) {
                return list.map(\.editedText)
            }
            return nil
        }

        expect(CorrectionHunks.split(delivered: "你好", edited: "你好") == .unchanged, "same text is unchanged")
        expect(fixes("我用cloud code写代码", "我用Claude Code写代码") == ["我用Claude Code写代码"],
               "neighbouring words are one fix")
        expect(fixes("cloud code和open ai都不错", "Claude Code和OpenAI都不错")
               == ["Claude Code和open ai都不错", "cloud code和OpenAI都不错"],
               "two separate fixes come apart, each with the other left as delivered")
        expect(CorrectionHunks.split(
            delivered: "cloud code和open ai和chat gbt都好", edited: "Claude Code和OpenAI和ChatGPT都好"
        ) == .rewrite, "three fixes are a rewrite")
        expect(CorrectionHunks.split(delivered: "你好", edited: "你好，你觉得呢") == .edgeOnly, "an addition at the end is not a fix")
        expect(CorrectionHunks.split(delivered: "那个你好", edited: "你好") == .edgeOnly, "a deletion at the start is not a fix")
        expect(fixes("我想去玩", "我想去北京玩") == ["我想去北京玩"], "an insertion in the middle is one fix")
        expect(fixes("cloud code和cloud code", "Claude Code和cloud code") == ["Claude Code和cloud code"],
               "only the first of two equal words fixed is one fix")
        expect(CorrectionHunks.split(delivered: String(repeating: "字", count: 1_600), edited: "x") == .rewrite,
               "a very long text is left alone")
        // Typing on right after a fix (the caret stands at the end of the dictation) is not part of the fix.
        expect(CorrectionHunks.split(delivered: "we use cloud code", edited: "we use Claude Code now") == .rewrite,
               "words typed after a fix at the end")
        expect(CorrectionHunks.split(delivered: "cloud code rocks", edited: "Yes Claude Code rocks") == .rewrite,
               "words typed before a fix at the start")
        expect(CorrectionHunks.split(delivered: "try open ai", edited: "try OpenAI ok?") == .rewrite,
               "a word and a mark typed after a fix")
        expect(fixes("我用cloud code写代码", "我用Claude Code写代码，你觉得呢") == ["我用Claude Code写代码"],
               "a sentence typed after the dictation, apart from the fix, is left out")
        expect(fixes("cloud code works well", "Claude Code works well today") == ["Claude Code works well"],
               "typing after the dictation, apart from the fix, is left out")
        expect(fixes("cloud code", "Claude Code") == ["Claude Code"], "a bare fix")
        expect(fixes("我在用克劳德扣的", "我在用Claude Code") == ["我在用Claude Code"], "a Han name written as Latin at the end")
        expect(fixes("we use gpt 4", "we use GPT-4") == ["we use GPT-4"], "a fix at the end that keeps its word count")
        // One Han character between two changes: one mishearing that kept a syllable, not two fixes.
        expect(fixes("我喜欢微软雅黑字体", "我喜欢薇软亚黑字体") == ["我喜欢薇软亚黑字体"], "a single-character anchor")
        return failures
    }

    // MARK: - Following the dictation inside the field

    private static func trackerChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { if !condition { failures.append("tracker: \(label)") } }
        func make(
            _ document: String, at location: Int, length: Int, delivered: String, empty: [String] = []
        ) -> EditSpanTracker? {
            EditSpanTracker(
                document: document, spanLocation: location, spanLength: length, delivered: delivered,
                emptyStateValues: empty, editingGeneration: 5
            )
        }
        let dictated = "我用cloud code写代码"
        let fixed = "我用Claude Code写代码"
        let count = dictated.utf16.count

        // The dictation is the whole field.
        if var tracker = make(dictated, at: 0, length: count, delivered: dictated) {
            expect(tracker.observe(document: dictated, editingGeneration: 6) == .unchanged, "same text")
            expect(tracker.observe(document: nil, editingGeneration: 6) == .unchanged, "an unreadable sample")
            expect(tracker.observe(document: fixed, editingGeneration: 6) == .dictationEdited, "fix in the whole field")
            expect(tracker.dictation == fixed && tracker.document == fixed, "the fixed dictation")
        } else {
            expect(false, "whole-field tracker is created")
        }

        // The dictation sits between the person's own text.
        let framed = "你好，" + dictated + "谢谢"
        if var tracker = make(framed, at: "你好，".utf16.count, length: count, delivered: dictated) {
            expect(tracker.observe(document: "你好，" + fixed + "谢谢", editingGeneration: 6) == .dictationEdited,
                   "fix between other text")
            expect(tracker.dictation == fixed, "only the dictation is the dictation")
        } else {
            expect(false, "framed tracker is created")
        }

        // Typing after the dictation, then fixing it.
        if var tracker = make(dictated, at: 0, length: count, delivered: dictated) {
            expect(tracker.observe(document: dictated + "，你觉得呢", editingGeneration: 6) == .outsideEdit, "append")
            expect(tracker.dictation == dictated, "an append is not the dictation")
            expect(tracker.observe(document: fixed + "，你觉得呢", editingGeneration: 7) == .dictationEdited, "fix after append")
            expect(tracker.dictation == fixed && tracker.document == fixed + "，你觉得呢", "dictation after append and fix")
        } else {
            expect(false, "append tracker is created")
        }

        // An edit in front of the dictation moves the span.
        if var tracker = make("你好，" + dictated, at: "你好，".utf16.count, length: count, delivered: dictated) {
            expect(tracker.observe(document: "大家好，" + dictated, editingGeneration: 6) == .outsideEdit, "edit in front")
            expect(tracker.dictation == dictated, "span moved with the text")
            expect(tracker.observe(document: "大家好，" + fixed, editingGeneration: 7) == .dictationEdited, "fix after a shift")
            expect(tracker.dictation == fixed, "fixed dictation after a shift")
        } else {
            expect(false, "shift tracker is created")
        }

        // A change across the border cannot be told apart from a rewrite.
        if var tracker = make("你好，" + dictated, at: "你好，".utf16.count, length: count, delivered: dictated) {
            expect(tracker.observe(document: "你用Claude Code写代码", editingGeneration: 6) == .ambiguous, "edit across the border")
            expect(tracker.closedBy == .ambiguous, "the tracker is closed")
            expect(tracker.observe(document: dictated, editingGeneration: 7) == .ambiguous, "and stays closed")
        } else {
            expect(false, "border tracker is created")
        }

        // Emptied or sent: blank, or the composer's own empty-state text.
        for (sample, label) in [("", "empty"), ("  \n", "blank"), ("Message ChatGPT", "hint")] {
            if var tracker = make(dictated, at: 0, length: count, delivered: dictated, empty: ["Message ChatGPT"]) {
                expect(tracker.observe(document: sample, editingGeneration: 5) == .cleared, "cleared by \(label)")
            } else {
                expect(false, "cleared tracker is created")
            }
        }
        if var tracker = make("你好，" + dictated, at: "你好，".utf16.count, length: count, delivered: dictated) {
            expect(tracker.observe(document: "你好，", editingGeneration: 6) == .cleared, "the dictation deleted")
        } else {
            expect(false, "deleted tracker is created")
        }

        // Characters made of several UTF-16 units are never cut.
        let smiling = "好😀" + dictated
        expect(make(smiling, at: "好😀".utf16.count, length: count, delivered: dictated) != nil, "span after an emoji")
        expect(make(smiling, at: 2, length: count, delivered: dictated) == nil, "span starting inside an emoji")
        expect(make("e\u{301}" + dictated, at: 1, length: count + 1, delivered: "\u{301}" + dictated) == nil,
               "span starting inside a combined character")

        // A text that is not what was delivered is not followed.
        expect(make(dictated, at: 0, length: count, delivered: fixed) == nil, "span text must be the delivered text")
        expect(make(dictated, at: 0, length: 0, delivered: "") == nil, "empty span")
        expect(make(dictated, at: 3, length: count, delivered: dictated) == nil, "span beyond the text")

        // Size.
        let big = String(repeating: "a", count: EditSpanTracker.maximumDocumentUTF16 + 1)
        expect(make(big, at: 0, length: 3, delivered: "aaa") == nil, "a field over the size limit")
        if var tracker = make(dictated, at: 0, length: count, delivered: dictated) {
            expect(tracker.observe(document: big, editingGeneration: 6) == .tooLarge, "a sample over the size limit")
        } else {
            expect(false, "size tracker is created")
        }

        // No key or mouse press since the baseline: the app or the recognizer changed the text, not the person.
        if var tracker = make(dictated, at: 0, length: count, delivered: dictated) {
            expect(tracker.observe(document: fixed, editingGeneration: 5) == .noHumanInput, "no human input")
            expect(tracker.dictation == dictated, "the sample was not accepted")
            expect(tracker.observe(document: fixed, editingGeneration: 6) == .dictationEdited, "the same text after a key press")
        } else {
            expect(false, "human-input tracker is created")
        }

        // Web editors turn a typed space into a non-breaking one; a line break at the end comes and goes.
        if var tracker = make(dictated, at: 0, length: count, delivered: dictated) {
            expect(tracker.observe(document: "我用Claude\u{00A0}Code写代码", editingGeneration: 6) == .dictationEdited,
                   "a non-breaking space in the fix")
            expect(tracker.dictation == fixed, "the non-breaking space reads as a space")
            expect(tracker.observe(document: fixed + "\n", editingGeneration: 7) == .unchanged, "a line break after the text")
        } else {
            expect(false, "space tracker is created")
        }
        if var tracker = make("hi\u{00A0}there " + dictated + "\n", at: "hi there ".utf16.count, length: count, delivered: dictated) {
            expect(tracker.observe(document: "hi there " + fixed, editingGeneration: 6) == .dictationEdited,
                   "non-breaking spaces and a line break outside the dictation do not matter")
        } else {
            expect(false, "outside-space tracker is created")
        }
        expect(make(dictated + "\n", at: 0, length: count + 1, delivered: dictated + "\n") == nil, "a dictation ending in a line break")
        // Undo: the words the dictation replaced, or an earlier draft of it, are back.
        if var tracker = EditSpanTracker(
            document: "我用Claude Code写代码", spanLocation: 2, spanLength: "Claude Code".utf16.count,
            delivered: "Claude Code", emptyStateValues: [], editingGeneration: 5, revertTexts: ["cloud code"]
        ) {
            expect(tracker.observe(document: "我用cloud code写代码", editingGeneration: 6) == .undone, "undo of a replaced selection")
            expect(tracker.observe(document: "我用Claude Code写代码", editingGeneration: 7) == .undone, "and stays closed")
        } else {
            expect(false, "undo tracker is created")
        }
        if var tracker = EditSpanTracker(
            document: "我用Claude Code写代码", spanLocation: 2, spanLength: "Claude Code".utf16.count,
            delivered: "Claude Code", emptyStateValues: [], editingGeneration: 5, revertTexts: ["cloud code"]
        ) {
            expect(tracker.observe(document: "我用Claude Cade写代码", editingGeneration: 6) == .dictationEdited, "another edit is not undo")
        } else {
            expect(false, "undo control tracker is created")
        }
        // Typing "f" in front of "foo" reads the same as typing it after the first "f": outside wins.
        if var tracker = make("hi foo", at: 3, length: 3, delivered: "foo") {
            expect(tracker.observe(document: "hi ffoo", editingGeneration: 6) == .outsideEdit, "ambiguous repeat")
            expect(tracker.dictation == "foo", "the dictation is not the edited text")
        } else {
            expect(false, "repeat tracker is created")
        }
        return failures
    }

    // MARK: - The learner

    private static func record(_ raw: String, terms: [LexiconTerm] = []) -> DictationRecord {
        let applied = LexiconSnapshot(revision: 1, terms: terms).apply(to: raw)
        return DictationRecord(rawText: raw, text: applied?.text ?? raw, hits: applied?.hits ?? [], routeID: "test")
    }

    private static func learnerChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { if !condition { failures.append("learner: \(label)") } }
        func pairs(_ outcome: CorrectionLearner.Outcome) -> [String] {
            outcome.candidates.map { "\($0.variant)→\($0.canonical):\($0.confidence.rawValue)" }
        }

        let simple = record("我用cloud code写代码")
        let learned = CorrectionLearner.evaluate(
            record: simple, editedDictation: "我用Claude Code写代码", finalDocument: "我用Claude Code写代码", terms: []
        )
        expect(learned.kind == .evaluated && pairs(learned) == ["cloud code→Claude Code:strong"],
               "one fix becomes one candidate: \(pairs(learned)) \(learned.rejectionSummary)")

        let two = record("cloud code和open ai都不错")
        let twoLearned = CorrectionLearner.evaluate(
            record: two, editedDictation: "Claude Code和OpenAI都不错", finalDocument: "Claude Code和OpenAI都不错", terms: []
        )
        expect(pairs(twoLearned) == ["cloud code→Claude Code:strong", "open ai→OpenAI:strong"],
               "two fixes become two candidates: \(pairs(twoLearned)) \(twoLearned.rejectionSummary)")

        let hanFix = record("他是项目经里")
        let hanLearned = CorrectionLearner.evaluate(
            record: hanFix, editedDictation: "他是项目经理", finalDocument: "他是项目经理", terms: []
        )
        expect(pairs(hanLearned) == ["经里→经理:weak"], "a homophone fix is weak: \(pairs(hanLearned)) \(hanLearned.rejectionSummary)")

        // The wrong spelling stays somewhere in the field: the person did not mean it as a mistake.
        let repeated = record("cloud code和cloud code")
        let kept = CorrectionLearner.evaluate(
            record: repeated, editedDictation: "Claude Code和cloud code", finalDocument: "Claude Code和cloud code", terms: []
        )
        expect(kept.candidates.isEmpty && kept.rejections["field.keptElsewhere"] == 1,
               "the wrong spelling kept elsewhere: \(kept.rejectionSummary)")

        // The same, in text the person typed themselves.
        let typedElsewhere = CorrectionLearner.evaluate(
            record: simple, editedDictation: "我用Claude Code写代码",
            finalDocument: "the cloud code doc\n我用Claude Code写代码", terms: []
        )
        expect(typedElsewhere.candidates.isEmpty && typedElsewhere.rejections["field.keptElsewhere"] == 1,
               "the wrong spelling typed elsewhere: \(typedElsewhere.rejectionSummary)")

        // A number is never learned.
        let number = CorrectionLearner.evaluate(
            record: record("版本3发布"), editedDictation: "版本4发布", finalDocument: "版本4发布", terms: []
        )
        expect(number.candidates.isEmpty && number.rejections["judge.digits"] == 1, "a number: \(number.rejectionSummary)")

        // The lexicon already has an opinion.
        let off = LexiconTerm(canonical: "Claude Code", variants: ["cloud code"], isEnabled: false)
        let owned = CorrectionLearner.evaluate(
            record: record("cloud code", terms: [off]), editedDictation: "Claude Code", finalDocument: "Claude Code", terms: [off]
        )
        expect(owned.candidates.isEmpty && owned.rejections["lexicon.variantOwned"] == 1,
               "a wrong spelling of a switched-off entry: \(owned.rejectionSummary)")
        let taken = LexiconTerm(canonical: "cloud", variants: ["Claude Code"])
        let clash = CorrectionLearner.evaluate(
            record: record("cloud code", terms: [taken]), editedDictation: "Claude Code", finalDocument: "Claude Code", terms: [taken]
        )
        expect(clash.candidates.isEmpty && clash.rejections["lexicon.canonicalIsVariant"] == 1,
               "a right spelling that is another entry's wrong one: \(clash.rejectionSummary)")
        let asCanonical = LexiconTerm(canonical: "cloud code", variants: [])
        let sameWords = CorrectionLearner.evaluate(
            record: record("cloud code", terms: [asCanonical]), editedDictation: "Claude Code", finalDocument: "Claude Code",
            terms: [asCanonical]
        )
        expect(sameWords.candidates.isEmpty && sameWords.rejections["lexicon.variantIsCanonical"] == 1,
               "a wrong spelling that is another entry's right one: \(sameWords.rejectionSummary)")

        // The person changed a lexicon correction back.
        let entry = LexiconTerm(canonical: "Claude Code", variants: ["cloud code"])
        let corrected = record("我用cloud code写代码", terms: [entry])
        expect(corrected.text == "我用Claude Code写代码" && corrected.hits.count == 1, "the lexicon corrected the dictation")
        let reverted = CorrectionLearner.evaluate(
            record: corrected, editedDictation: "我用cloud code写代码", finalDocument: "我用cloud code写代码", terms: [entry]
        )
        expect(reverted.candidates.isEmpty && reverted.revertedTermIDs == [entry.id],
               "an entry the person undid by hand: \(reverted.rejectionSummary)")

        // Typing on after a fix, adding or dropping English words, capitals for emphasis: nothing to suggest.
        for (delivered, edited) in [
            ("we use cloud code", "we use Claude Code now"),
            ("send it to cloud code", "send it to Claude Code then"),
            ("try open ai", "try OpenAI ok?"),
            ("cloud code rocks", "Yes Claude Code rocks"),
            ("please send the final report", "please send the report"),
            ("send the report", "send the final report"),
            ("我用code写代码", "我用Claude code写代码"),
            ("we need a quick review", "we need a review"),
            ("never do that", "NEVER do that"),
        ] {
            let result = CorrectionLearner.evaluate(
                record: record(delivered), editedDictation: edited, finalDocument: edited, terms: []
            )
            expect(result.candidates.isEmpty,
                   "not a suggestion: \(delivered) → \(edited): \(pairs(result)) \(result.rejectionSummary)")
        }
        // Letters of an input method still composing may be listed, never as a strong pair.
        let composing = CorrectionLearner.evaluate(
            record: record("我用cloud code写代码"), editedDictation: "我用kelaode写代码",
            finalDocument: "我用kelaode写代码", terms: []
        )
        expect(!composing.candidates.contains(where: { $0.confidence == .strong }),
               "composing letters are not strong: \(pairs(composing))")
        let afterTyping = CorrectionLearner.evaluate(
            record: record("cloud code works well"), editedDictation: "Claude Code works well",
            finalDocument: "Claude Code works well today", terms: []
        )
        expect(pairs(afterTyping) == ["cloud code→Claude Code:strong"], "a fix, then typing after the dictation: \(pairs(afterTyping))")
        let atEnd = CorrectionLearner.evaluate(
            record: record("我在用github"), editedDictation: "我在用GitHub", finalDocument: "我在用GitHub", terms: []
        )
        expect(pairs(atEnd) == ["github→GitHub:strong"], "a case fix: \(pairs(atEnd)) \(atEnd.rejectionSummary)")
        let switchedOff = LexiconTerm(canonical: "Claude Code", variants: [], isEnabled: false)
        expect(CorrectionLearner.conflict(variant: "cloud code", canonical: "Claude Code", terms: [switchedOff]) == "canonicalSwitchedOff",
               "an entry the person switched off is not touched")
        expect(CorrectionLearner.conflict(variant: "cloud code", canonical: "Claude Code", terms: [LexiconTerm(canonical: "Claude Code", variants: [])]) == nil,
               "an enabled entry with the same right spelling may take another wrong spelling")

        // Nothing to learn.
        expect(CorrectionLearner.evaluate(record: simple, editedDictation: simple.text, finalDocument: simple.text, terms: []).kind == .unchanged,
               "no change")
        expect(CorrectionLearner.evaluate(record: simple, editedDictation: simple.text + "，你觉得呢", finalDocument: "", terms: []).kind == .edgeOnly,
               "an addition at the end")
        let rewrite = CorrectionLearner.evaluate(
            record: record("cloud code和open ai和chat gbt都好"), editedDictation: "Claude Code和OpenAI和ChatGPT都好",
            finalDocument: "", terms: []
        )
        expect(rewrite.kind == .rewrite && rewrite.candidates.isEmpty, "three fixes")
        let unrelated = CorrectionLearner.evaluate(
            record: record("今天天气不错"), editedDictation: "明天开会讨论", finalDocument: "明天开会讨论", terms: []
        )
        expect(unrelated.candidates.isEmpty, "a different sentence is not a fix")
        return failures
    }

    // MARK: - The ledger

    private static func ledgerChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { if !condition { failures.append("ledger: \(label)") } }
        func candidate(_ variant: String, _ canonical: String, _ confidence: CorrectionPlausibility.Confidence = .weak)
            -> CorrectionLearner.Candidate {
            CorrectionLearner.Candidate(variant: variant, canonical: canonical, confidence: confidence)
        }
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = UUID()
        let second = UUID()

        var ledger = CorrectionLedger()
        expect(ledger.note([candidate("cloud", "Claude")], dictationID: first, now: start) == 1, "a new pair")
        expect(ledger.entries.count == 1 && ledger.entries[0].sightings == 1, "one sighting")
        expect(ledger.note([candidate("Cloud", "Claude")], dictationID: first, now: start) == 0, "the same dictation counts once")
        expect(ledger.entries.count == 1 && ledger.entries[0].sightings == 1, "still one sighting, case folded")
        ledger.note([candidate("open ai", "OpenAI", .strong)], dictationID: second, now: start)
        expect(ledger.entries.map(\.canonical) == ["OpenAI", "Claude"], "most recent first")
        expect(ledger.note([candidate("cloud", "Claude", .strong)], dictationID: second, now: start) == 1, "a second dictation")
        expect(ledger.entries[0].canonical == "Claude" && ledger.entries[0].sightings == 2, "two sightings, moved to the front")
        expect(ledger.entries[0].confidence == .strong, "the best rating is kept")

        // Dismissed pairs stay away; removed ones may come back.
        let dismissedID = ledger.entries[0].id
        ledger.dismiss(dismissedID)
        expect(ledger.entries.map(\.canonical) == ["OpenAI"], "dismissed pair is gone")
        expect(ledger.note([candidate("cloud", "Claude")], dictationID: UUID(), now: start) == 0, "and is not suggested again")
        ledger.remove(ledger.entries[0].id)
        expect(ledger.entries.isEmpty, "removed pair is gone")
        expect(ledger.note([candidate("open ai", "OpenAI")], dictationID: UUID(), now: start) == 1, "a removed pair may return")

        // The list stays short: the least recently seen goes first.
        var crowded = CorrectionLedger()
        for index in 0..<(CorrectionLedger.maximumEntries + 5) {
            crowded.note([candidate("wrong \(index)", "right \(index)")], dictationID: UUID(), now: start)
        }
        expect(crowded.entries.count == CorrectionLedger.maximumEntries, "capped")
        expect(crowded.entries[0].variant == "wrong \(CorrectionLedger.maximumEntries + 4)", "newest first")
        expect(!crowded.entries.contains(where: { $0.variant == "wrong 0" }), "oldest dropped")

        // Old entries age out; turning learning off forgets everything, dismissals included.
        var aging = CorrectionLedger()
        aging.note([candidate("cloud", "Claude")], dictationID: UUID(), now: start)
        aging.prune(now: start.addingTimeInterval(CorrectionLedger.lifetime - 1))
        expect(aging.entries.count == 1, "still fresh")
        aging.prune(now: start.addingTimeInterval(CorrectionLedger.lifetime + 1))
        expect(aging.entries.isEmpty, "a week old")
        aging.note([candidate("cloud", "Claude")], dictationID: UUID(), now: start)
        aging.dismiss(aging.entries[0].id)
        aging.removeAll()
        expect(aging.note([candidate("cloud", "Claude")], dictationID: UUID(), now: start) == 1, "nothing is remembered after removeAll")
        return failures
    }
}
