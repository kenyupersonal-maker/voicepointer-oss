import Foundation
@_spi(Testing) import VoicePointerCore

/// Synthetic-only table checks for the strict filter. This suite never reads a disk lexicon,
/// microphone, teacher transcript, clipboard, network or private archive.
enum StrictLearningChecks {
    @MainActor
    static func run() -> [String] {
        typealias Filter = StrictLearningFilter
        var failures: [String] = []
        let notOrdinary: (String) -> Bool = { _ in false }
        let common: (String) -> Bool = { $0 == "苹果" }

        // R5: every rejection has one synthetic example; dictionary predicates are ignored.
        let rejected: [(name: String, wrong: String, right: String, reason: Filter.Rejection)] = [
            ("empty", "，", "。", .empty),
            ("insertDelete", "", "图像", .insertDelete),
            ("prefix", "Figma", "Figman", .prefix),
            ("length", "甲乙丙丁戊己庚辛壬", "新的系统设计", .length),
            ("filler", "啊", "好", .filler),
            ("span", "查", "茶", .span),
            ("pinyin", "开发", "设计", .pinyin),
            ("latin", "Alpha", "Different", .latin)
        ]
        for row in rejected {
            let actual = Filter.validatePair(
                variant: row.wrong, canonical: row.right,
                commonChinese: common, ordinaryEnglish: notOrdinary
            )
            if actual != row.reason { failures.append("strict filter: rejected cause \(row.name)") }
        }

        let atSentenceStart = Filter.analyze(
            local: "菲格玛已经成功上线",
            reference: "Figma已经成功上线",
            commonChinese: common, ordinaryEnglish: notOrdinary
        )
        if atSentenceStart.count != 1 || !atSentenceStart[0].isAccepted {
            failures.append("strict filter: R5 boundary replacement")
        }

        // The same two-plus matching Han characters flank each pair, including the English words.
        // No dictionary of exceptions exists in the implementation.
        let positivePairs: [(String, String)] = [
            ("菲格玛", "Figma"),
            ("Betagate", "Bitget"),
            ("Corder", "Qoder"),
            ("自带里", "子代理")
        ]
        for (index, pair) in positivePairs.enumerated() {
            let before = "我们今天确认"
            let after = "这个功能确实正常"
            let decisions = Filter.analyze(
                local: before + pair.0 + after,
                reference: before + pair.1 + after,
                commonChinese: common, ordinaryEnglish: notOrdinary
            )
            if decisions.count != 1 || !decisions[0].isAccepted ||
                decisions[0].pair != Filter.Pair(variant: pair.0, canonical: pair.1) {
                failures.append("strict filter: positive \(index + 1)")
            }
            let production = Filter.validatePair(
                variant: pair.0, canonical: pair.1,
                commonChinese: { _ in true }, ordinaryEnglish: { _ in true }
            )
            if production != nil { failures.append("strict filter: production positive \(index + 1)") }
        }

        let human = LexiconTerm(canonical: "人工正确", variants: ["原始错写"], source: .manual)
        let machine = LexiconTerm(canonical: "自动正确", variants: ["人工正确", "机器错写"],
                                  source: .automaticallyLearned, hitCount: 2)
        let corrector = DictationCorrector(lexicon: LexiconSnapshot(revision: 1, terms: [machine, human]))
        let final = corrector.finalApplication(raw: "原始错写机器错写", mode: .voiceNative, source: .local)
        if final?.text != "人工正确自动正确" || final?.hits.map(\.termID) != [human.id, machine.id] {
            failures.append("strict application: human ownership and no cascade")
        }
        let beforeRelease = SpeechInputEvent(sessionID: UUID(), sequence: 1, observedMilliseconds: 0,
                                            kind: .final, text: "机器错写")
        if corrector.correct(beforeRelease, mode: .voiceNative).event.text != "机器错写"
            || corrector.correct(beforeRelease, mode: .voiceNative).hits.count != 0 {
            failures.append("strict application: no automatic before release")
        }
        let humans = (0..<3).map { LexiconTerm(canonical: "人工\($0)", source: .manual) }
        if RecognitionHotwords.select(from: humans + [machine]).count != 3 {
            failures.append("strict hotwords: real replacement threshold")
        }
        var hitMachine = machine
        hitMachine.hitCount = 3
        let hints = RecognitionHotwords.select(from: humans + [hitMachine])
        if hints.count != 4 || hints.filter({ $0 == machine.canonical }).count != 1 {
            failures.append("strict hotwords: one quarter")
        }

        // Two separated edit hunks must both survive. No per-utterance candidate cap.
        let multiple = Filter.analyze(
            local: "我们今天用菲格玛开始设计然后交给自带里继续处理",
            reference: "我们今天用Figma开始设计然后交给子代理继续处理",
            commonChinese: common, ordinaryEnglish: notOrdinary
        )
        if multiple.count != 2 || !multiple.allSatisfy(\.isAccepted) {
            failures.append("strict filter: two separate replacements")
        }
        if !Filter.analyze(local: "我们已经处理完成", reference: "我们已经处理完成",
                           commonChinese: common, ordinaryEnglish: notOrdinary).isEmpty {
            failures.append("strict filter: identical transcripts")
        }
        return failures
    }
}
