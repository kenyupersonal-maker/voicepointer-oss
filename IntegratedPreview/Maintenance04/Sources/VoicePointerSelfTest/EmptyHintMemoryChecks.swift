import Foundation
@_spi(Testing) import VoicePointerCore

/// Composers that show their empty-state hint through AXValue (ChatGPT for Mac): what the memory
/// recognizes, what it refuses, and how a first dictation into such a field is carried on.
/// Pure logic; no AX, keyboard or clipboard is touched.
enum EmptyHintMemoryChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { if !condition { failures.append("empty hint: \(label)") } }
        let origin = NSRange(location: 0, length: 0)
        let hint = "Message ChatGPT"
        let chat = "com.openai.chat"

        // A seeded app is recognized at once, exactly and only at caret 0:0; the process then remembers it.
        do {
            var memory = EmptyHintMemory()
            expect(!memory.recognizesAtStart(value: hint, selection: origin, processIdentifier: 10, bundleIdentifier: nil),
                   "unknown app must not match on text alone")
            expect(!memory.recognizesAtStart(value: hint, selection: origin, processIdentifier: 10, bundleIdentifier: "com.apple.TextEdit"),
                   "other bundle must not match")
            expect(!memory.recognizesAtStart(value: hint + " ", selection: origin, processIdentifier: 10, bundleIdentifier: chat),
                   "seed is an exact match")
            expect(!memory.recognizesAtStart(value: hint, selection: NSRange(location: 15, length: 0), processIdentifier: 10, bundleIdentifier: chat),
                   "caret elsewhere is a draft")
            expect(!memory.recognizesAtStart(value: hint, selection: NSRange(location: 0, length: 15), processIdentifier: 10, bundleIdentifier: chat),
                   "a selection is a draft")
            expect(!memory.recognizesAtStart(value: nil, selection: origin, processIdentifier: 10, bundleIdentifier: chat), "no value")
            expect(!memory.recognizesAtStart(value: hint, selection: nil, processIdentifier: 10, bundleIdentifier: chat), "no selection")
            expect(memory.recognizesAtStart(value: hint, selection: origin, processIdentifier: 10, bundleIdentifier: chat),
                   "seeded hint at caret 0")
            expect(memory.isKnown(hint, processIdentifier: 10), "seeded hint becomes known")
            expect(memory.recognizesAtStart(value: hint, selection: origin, processIdentifier: 10, bundleIdentifier: nil),
                   "known hint needs no bundle")
            expect(!memory.isKnown(hint, processIdentifier: 11), "known per process")
            expect(!memory.recognizesAtStart(value: hint, selection: origin, processIdentifier: 11, bundleIdentifier: nil),
                   "another process has not learned it")
        }

        // The observed case: dictation lands in front of the hint, the hint vanishes, a later send shows it again.
        do {
            var memory = EmptyHintMemory()
            let localizedHint = "给 ChatGPT 发消息"
            expect(memory.noteVanished(original: localizedHint, selection: origin, expectedDocument: "你好" + localizedHint,
                                       observed: "你好", processIdentifier: 20), "vanished hint is a candidate")
            expect(!memory.isKnown(localizedHint, processIdentifier: 20), "a candidate is not known yet")
            expect(!memory.recognizesAfterSend(current: localizedHint, valueBeforeReturn: "你好", processIdentifier: 21, bundleIdentifier: nil),
                   "candidates are per process")
            expect(memory.recognizesAfterSend(current: localizedHint, valueBeforeReturn: "你好", processIdentifier: 20, bundleIdentifier: nil),
                   "candidate seen again after a send")
            expect(memory.isKnown(localizedHint, processIdentifier: 20), "promoted to known")
            expect(memory.recognizesAtStart(value: localizedHint, selection: origin, processIdentifier: 20, bundleIdentifier: nil),
                   "known hint recognized at the start of the next dictation")
        }
        do {
            var memory = EmptyHintMemory()
            memory.noteVanished(original: hint, selection: origin, expectedDocument: "ok" + hint, observed: "ok", processIdentifier: 22)
            expect(memory.recognizesAtStart(value: hint, selection: origin, processIdentifier: 22, bundleIdentifier: nil),
                   "candidate seen again at the start of a dictation")
            expect(memory.isKnown(hint, processIdentifier: 22), "…and promoted")
        }

        // A candidate needs exactly "the text landed and the value that stood at caret 0 is gone".
        let vanishCases: [(label: String, original: String?, selection: NSRange?, expected: String, observed: String)] = [
            ("real draft stays next to the text", hint, origin, "你好" + hint, "你好" + hint),
            ("no original", nil, origin, "你好" + hint, "你好"),
            ("no selection", hint, nil, "你好" + hint, "你好"),
            ("caret not at 0", hint, NSRange(location: 3, length: 0), "你好" + hint, "你好"),
            ("something selected", hint, NSRange(location: 0, length: 4), "你好" + hint, "你好"),
            ("blank original", "\n", origin, "你好\n", "你好"),
            ("empty observation", hint, origin, "你好" + hint, ""),
            ("blank observation", hint, origin, "你好" + hint, "  "),
            ("observation is not the text in front", hint, origin, "你好" + hint, "别的"),
            ("expected lacks the original at its end", hint, origin, "你好，别的", "你好"),
            ("length does not add up", hint, origin, "你好" + hint, "你好啊"),
            ("original too long to be a hint", String(repeating: "长", count: 201), origin,
             "你好" + String(repeating: "长", count: 201), "你好"),
        ]
        for item in vanishCases {
            var memory = EmptyHintMemory()
            let accepted = memory.noteVanished(
                original: item.original, selection: item.selection, expectedDocument: item.expected,
                observed: item.observed, processIdentifier: 30)
            expect(!accepted, "vanish must be refused: \(item.label)")
            if let original = item.original {
                expect(!memory.recognizesAfterSend(current: original, valueBeforeReturn: "你好", processIdentifier: 30, bundleIdentifier: nil),
                       "a refused vanish leaves nothing behind: \(item.label)")
            }
        }

        // After a send only a genuinely returned hint counts.
        do {
            var memory = EmptyHintMemory()
            memory.learn(hint, processIdentifier: 40)
            let sendCases: [(label: String, current: String, before: String, expected: Bool)] = [
                ("hint is back", hint, "你好", true),
                ("field unchanged", "你好", "你好", false),
                ("sent text still there", "你好世界", "你好", false),
                ("sent text mentions the hint", hint, "请对 " + hint + " 说", false),
                ("blank field", "\n", "你好", false),
                ("other text", "别的", "你好", false),
                ("the hint itself was the text", hint, hint, false),
            ]
            for item in sendCases {
                let got = memory.recognizesAfterSend(current: item.current, valueBeforeReturn: item.before,
                                                     processIdentifier: 40, bundleIdentifier: nil)
                expect(got == item.expected, "after-send case \(item.label)")
            }
        }

        // Learning refuses what cannot be a hint, and never forgets a fresh hint for the same process.
        do {
            var memory = EmptyHintMemory()
            memory.learn("\n", processIdentifier: 50)
            memory.learn(String(repeating: "x", count: 201), processIdentifier: 50)
            expect(!memory.isKnown("\n", processIdentifier: 50), "blank is never a hint")
            expect(!memory.isKnown(String(repeating: "x", count: 201), processIdentifier: 50), "long text is never a hint")
            memory.learn("First", processIdentifier: 50)
            memory.learn("Second", processIdentifier: 50)
            expect(!memory.isKnown("First", processIdentifier: 50) && memory.isKnown("Second", processIdentifier: 50),
                   "a process keeps its latest hint")
            for pid in 100..<(100 + Int32(EmptyHintMemory.maximumProcesses) + 8) { memory.learn("Hint \(pid)", processIdentifier: pid) }
            expect(memory.isKnown("Hint 171", processIdentifier: 171), "the newest process is remembered after the cap")
        }

        // The inline draft carries on from a document whose hint vanished with the first write.
        failures += checkTransaction()
        return failures
    }

    private static func checkTransaction() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { if !condition { failures.append("empty hint transaction: \(label)") } }
        let origin = NSRange(location: 0, length: 0)
        let hint = "Message ChatGPT"

        func firstPlan(_ text: String, original: String = hint, selection: NSRange = NSRange(location: 0, length: 0))
            -> (InlineDraftTransaction, InlineDraftTransaction.Plan)? {
            guard var transaction = InlineDraftTransaction(originalText: original, selection: selection),
                  case .replace(let plan) = transaction.prepare(
                      text: text, sequence: 1, currentDocument: original, currentSelection: selection)
            else { return nil }
            return (transaction, plan)
        }

        // The first write goes in front of the hint; the field keeps only the text; later partials replace it.
        guard let first = firstPlan("你好") else { return ["empty hint transaction: setup failed"] }
        var transaction = first.0
        let plan = first.1
        expect(plan.expectedDocument == "你好" + hint, "the plan expects the text in front of the hint")
        expect(transaction.acceptVanishedOriginal(planID: plan.id, observedDocument: "你好",
                                                  observedSelection: NSRange(location: 2, length: 0)),
               "the vanished hint is accepted")
        expect(transaction.hasWritten && transaction.lastDraft == "你好" && transaction.lastDocument == "你好",
               "state after accepting")
        if case .replace(let next) = transaction.prepare(
            text: "你好吗", sequence: 2, currentDocument: "你好", currentSelection: NSRange(location: 2, length: 0)) {
            expect(next.replaceRange == NSRange(location: 0, length: 2), "the next partial replaces exactly the first draft")
            expect(next.expectedDocument == "你好吗", "the next document is the new draft alone")
            expect(transaction.confirm(planID: next.id, observedDocument: "你好吗",
                                       observedSelection: NSRange(location: 3, length: 0)), "the next partial confirms normally")
        } else {
            failures.append("empty hint transaction: the next partial must be a replacement")
        }

        // Refusals leave the pending plan alone so it can still be reconciled.
        let refusals: [(label: String, prepare: () -> (InlineDraftTransaction, InlineDraftTransaction.Plan)?, observed: String, selection: NSRange, useWrongID: Bool)] = [
            ("the hint stayed", { firstPlan("你好") }, "你好" + hint, NSRange(location: 2, length: 0), false),
            ("the text changed", { firstPlan("你好") }, "别的", NSRange(location: 2, length: 0), false),
            ("the caret is elsewhere", { firstPlan("你好") }, "你好", NSRange(location: 0, length: 0), false),
            ("a real draft with the caret elsewhere", { firstPlan("你好", original: "草稿", selection: NSRange(location: 2, length: 0)) },
             "你好", NSRange(location: 2, length: 0), false),
            ("an unknown plan", { firstPlan("你好") }, "你好", NSRange(location: 2, length: 0), true),
        ]
        for item in refusals {
            guard let pair = item.prepare() else {
                failures.append("empty hint transaction: setup failed for \(item.label)")
                continue
            }
            var t = pair.0
            let p = pair.1
            let id = item.useWrongID ? UUID() : p.id
            expect(!t.acceptVanishedOriginal(planID: id, observedDocument: item.observed, observedSelection: item.selection),
                   "refused: \(item.label)")
            expect(!t.hasWritten, "nothing recorded when refused: \(item.label)")
            if !item.useWrongID {
                expect(t.reconcile(document: hint, selection: origin) != .applied, "still reconcilable: \(item.label)")
            }
        }
        // A second acceptance of the same plan is refused (it is no longer pending).
        if let pair = firstPlan("你好") {
            var t = pair.0
            let p = pair.1
            _ = t.acceptVanishedOriginal(planID: p.id, observedDocument: "你好", observedSelection: NSRange(location: 2, length: 0))
            expect(!t.acceptVanishedOriginal(planID: p.id, observedDocument: "你好", observedSelection: NSRange(location: 2, length: 0)),
                   "accepting twice is refused")
        }
        return failures
    }
}
