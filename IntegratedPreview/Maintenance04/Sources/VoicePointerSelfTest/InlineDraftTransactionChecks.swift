import Foundation
import VoicePointerCore

enum InlineDraftTransactionChecks {

    static func run() -> [String] {
        checkAHelloWorld()
            + checkBTable()
            + checkCCancelAndSequence()
            + checkDEraseDraft()
            + checkEManualEditAbandons()
            + checkFInvalidInit()
            + checkGBusyAndStale()
            + checkHUnconfirmedPreserved()
            + checkIEmptyFirstDraft()
            + checkJControlAndLengthLimits()
            + checkKWrongConfirmAbandons()
            + checkLUnicodeNormalization()
            + checkMUncertainWriteReconciliation()
    }

    private static func checkAHelloWorld() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        guard var t = InlineDraftTransaction(
            originalText: "Hello world",
            selection: NSRange(location: 6, length: 5)) else { return ["A: init failed"] }
        let d1 = t.prepare(text: "there", sequence: 0, currentDocument: "Hello world", currentSelection: NSRange(location: 6, length: 5))
        guard case .replace(let p1) = d1 else { return ["A: first prepare not replace"] }
        expect(p1.replaceRange == NSRange(location: 6, length: 5), "A: replaceRange1")
        expect(p1.expectedDocument == "Hello there", "A: expectedDocument1")
        expect(p1.expectedSelection == NSRange(location: 11, length: 0), "A: caret1")
        expect(t.confirm(planID: p1.id, observedDocument: "Hello there", observedSelection: NSRange(location: 11, length: 0)), "A: confirm1")
        expect(t.lastDraft == "there" && t.lastDocument == "Hello there", "A: state1")
        let d2 = t.prepare(text: "friend", sequence: 1, currentDocument: "Hello there", currentSelection: NSRange(location: 11, length: 0))
        guard case .replace(let p2) = d2 else { return ["A: second prepare not replace"] }
        expect(p2.expectedDocument == "Hello friend", "A: expectedDocument2")
        expect(p2.expectedSelection == NSRange(location: 12, length: 0), "A: caret2")
        expect(t.confirm(planID: p2.id, observedDocument: "Hello friend", observedSelection: NSRange(location: 12, length: 0)), "A: confirm2")
        let d3 = t.prepare(text: "friend", sequence: 2, currentDocument: "Hello friend", currentSelection: NSRange(location: 12, length: 0))
        if case .unchanged = d3 {} else { f.append("A: identical final draft should be unchanged") }
        return f
    }

    private static func checkBTable() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        let cases: [(String, NSRange, String, String, Int)] = [
            ("abcdef", NSRange(location: 4, length: 0), "XY", "abcdXYef", 6),
            ("aaaaabbbb", NSRange(location: 0, length: 5), "CC", "CCbbbb", 2),
            ("a\u{1F601}中b", NSRange(location: 1, length: 3), "\u{1F44D}!", "a\u{1F44D}!b", 4),
        ]
        for (i, c) in cases.enumerated() {
            guard var t = InlineDraftTransaction(originalText: c.0, selection: c.1) else {
                f.append("B\(i): init failed"); continue
            }
            let d = t.prepare(text: c.2, sequence: 0, currentDocument: c.0, currentSelection: c.1)
            guard case .replace(let p) = d else { f.append("B\(i): not replace"); continue }
            expect(p.expectedDocument == c.3, "B\(i): expectedDocument")
            expect(p.expectedSelection == NSRange(location: c.4, length: 0), "B\(i): caret")
            expect(t.confirm(planID: p.id, observedDocument: c.3, observedSelection: NSRange(location: c.4, length: 0)), "B\(i): confirm")
            expect(t.lastDraft == c.2 && t.lastDocument == c.3, "B\(i): state")
        }
        return f
    }

    private static func checkCCancelAndSequence() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        guard var t = InlineDraftTransaction(originalText: "ab", selection: NSRange(location: 0, length: 0)) else { return ["C: init failed"] }
        guard case .replace(let p1) = t.prepare(text: "X", sequence: 0, currentDocument: "ab", currentSelection: NSRange(location: 0, length: 0)) else { return ["C: prepare1 not replace"] }
        expect(t.confirm(planID: p1.id, observedDocument: "Xab", observedSelection: NSRange(location: 1, length: 0)), "C: confirm1")
        guard case .replace(let p2) = t.prepare(text: "Y", sequence: 1, currentDocument: "Xab", currentSelection: NSRange(location: 1, length: 0)) else { return ["C: prepare2 not replace"] }
        expect(p2.expectedDocument == "Yab", "C: expectedDocument2")
        expect(!t.confirm(planID: p1.id, observedDocument: "Yab", observedSelection: NSRange(location: 1, length: 0)), "C: old plan id must fail")
        expect(t.confirm(planID: p2.id, observedDocument: "Yab", observedSelection: NSRange(location: 1, length: 0)), "C: confirm2 after failed old id")
        expect(t.lastDraft == "Y" && t.lastDocument == "Yab", "C: state")
        return f
    }

    private static func checkDEraseDraft() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        guard var t = InlineDraftTransaction(originalText: "aabbcc", selection: NSRange(location: 2, length: 2)) else { return ["D: init failed"] }
        guard case .replace(let p1) = t.prepare(text: "XY", sequence: 0, currentDocument: "aabbcc", currentSelection: NSRange(location: 2, length: 2)) else { return ["D: prepare1 not replace"] }
        expect(t.confirm(planID: p1.id, observedDocument: "aaXYcc", observedSelection: NSRange(location: 4, length: 0)), "D: confirm1")
        guard case .replace(let p2) = t.prepare(text: "", sequence: 1, currentDocument: "aaXYcc", currentSelection: NSRange(location: 4, length: 0)) else { return ["D: empty draft not replace"] }
        expect(p2.expectedDocument == "aacc", "D: expectedDocument2")
        expect(p2.expectedSelection == NSRange(location: 2, length: 0), "D: caret2")
        expect(t.confirm(planID: p2.id, observedDocument: "aacc", observedSelection: NSRange(location: 2, length: 0)), "D: confirm2")
        expect(t.lastDraft == "" && t.lastDocument == "aacc", "D: state")
        return f
    }

    private static func checkEManualEditAbandons() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        guard var t = InlineDraftTransaction(originalText: "abc", selection: NSRange(location: 0, length: 0)) else { return ["E: init failed"] }
        guard case .replace(let p1) = t.prepare(text: "X", sequence: 0, currentDocument: "abc", currentSelection: NSRange(location: 0, length: 0)) else { return ["E: prepare1 not replace"] }
        if case .busy = t.prepare(text: "Z", sequence: 1, currentDocument: "abc", currentSelection: NSRange(location: 0, length: 0)) {} else { f.append("E: pending prepare should be busy") }
        expect(t.confirm(planID: p1.id, observedDocument: "Xabc", observedSelection: NSRange(location: 1, length: 0)), "E: confirm1")
        let d = t.prepare(text: "Y", sequence: 1, currentDocument: "Xabzc", currentSelection: NSRange(location: 1, length: 0))
        if case .abandoned = d {} else { f.append("E: manual edit must abandon") }
        expect(t.isAbandoned, "E: isAbandoned")
        if case .abandoned = t.prepare(text: "Y", sequence: 2, currentDocument: "Xabzc", currentSelection: NSRange(location: 1, length: 0)) {} else { f.append("E: prepare after abandon") }
        return f
    }

    private static func checkFInvalidInit() -> [String] {
        var f: [String] = []
        if InlineDraftTransaction(originalText: "\u{1F600}", selection: NSRange(location: 1, length: 0)) != nil { f.append("F: surrogate split accepted") }
        if InlineDraftTransaction(originalText: "ab", selection: NSRange(location: NSNotFound, length: 0)) != nil { f.append("F: NSNotFound location accepted") }
        if InlineDraftTransaction(originalText: "ab", selection: NSRange(location: 0, length: NSNotFound)) != nil { f.append("F: NSNotFound length accepted") }
        if InlineDraftTransaction(originalText: "ab", selection: NSRange(location: 0, length: -1)) != nil { f.append("F: negative length accepted") }
        if InlineDraftTransaction(originalText: "ab", selection: NSRange(location: 3, length: 0)) != nil { f.append("F: overflow location accepted") }
        return f
    }

    private static func checkGBusyAndStale() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        guard var t = InlineDraftTransaction(originalText: "hello", selection: NSRange(location: 0, length: 0)) else { return ["G: init failed"] }
        guard case .replace(let p0) = t.prepare(text: "a", sequence: 0, currentDocument: "hello", currentSelection: NSRange(location: 0, length: 0)) else { return ["G: seq0 not replace"] }
        if case .busy = t.prepare(text: "b", sequence: 6, currentDocument: "hello", currentSelection: NSRange(location: 0, length: 0)) {} else { f.append("G: pending prepare should be busy") }
        expect(t.confirm(planID: p0.id, observedDocument: "ahello", observedSelection: NSRange(location: 1, length: 0)), "G: confirm0")
        if case .stale = t.prepare(text: "a", sequence: 0, currentDocument: "ahello", currentSelection: NSRange(location: 1, length: 0)) {} else { f.append("G: reused seq0 should be stale") }
        if case .replace = t.prepare(text: "c", sequence: 1, currentDocument: "ahello", currentSelection: NSRange(location: 1, length: 0)) {} else { f.append("G: seq1 should replace") }
        return f
    }

    private static func checkHUnconfirmedPreserved() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        guard var t = InlineDraftTransaction(originalText: "abc", selection: NSRange(location: 0, length: 0)) else { return ["H: init failed"] }
        guard case .replace(let p) = t.prepare(text: "X", sequence: 0, currentDocument: "abc", currentSelection: NSRange(location: 0, length: 0)) else { return ["H: prepare not replace"] }
        expect(t.lastDocument == "abc", "H: lastDocument before confirm")
        t.abandon()
        expect(!t.confirm(planID: p.id, observedDocument: "Xabc", observedSelection: NSRange(location: 1, length: 0)), "H: confirm after abandon")
        expect(t.lastDocument == "abc" && t.lastDraft == "" && t.expectedSelection == NSRange(location: 0, length: 0), "H: state preserved")
        return f
    }

    private static func checkIEmptyFirstDraft() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        guard var t = InlineDraftTransaction(originalText: "hello", selection: NSRange(location: 0, length: 5)) else { return ["I: init failed"] }
        let d = t.prepare(text: "", sequence: 0, currentDocument: "hello", currentSelection: NSRange(location: 0, length: 5))
        if case .unchanged = d {} else { f.append("I: empty first draft should be unchanged") }
        expect(!t.hasWritten && t.lastDocument == "hello", "I: original selection not deleted")
        return f
    }

    private static func checkJControlAndLengthLimits() -> [String] {
        var f: [String] = []
        let sel = NSRange(location: 0, length: 0)
        for (i, bad) in ["a\u{7F}b", "a\u{0000}b", String(repeating: "x", count: 50_001)].enumerated() {
            guard var t = InlineDraftTransaction(originalText: "abc", selection: sel) else { f.append("J\(i): init failed"); continue }
            let d = t.prepare(text: bad, sequence: 0, currentDocument: "abc", currentSelection: sel)
            if case .abandoned = d {} else { f.append("J\(i): forbidden draft accepted") }
            expect2(&f, t.isAbandoned, "J\(i): not abandoned")
        }
        guard var t = InlineDraftTransaction(originalText: "abc", selection: sel) else { return f + ["J: init failed for LF/TAB"] }
        if case .replace = t.prepare(text: "a\n\tb", sequence: 0, currentDocument: "abc", currentSelection: sel) {} else { f.append("J: LF/TAB should be allowed") }
        return f
    }

    private static func expect2(_ f: inout [String], _ c: Bool, _ l: String) {
        if !c { f.append(l) }
    }

    private static func checkKWrongConfirmAbandons() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        guard var t1 = InlineDraftTransaction(originalText: "ab", selection: NSRange(location: 0, length: 0)) else { return ["K: init1 failed"] }
        guard case .replace(let p1) = t1.prepare(text: "X", sequence: 0, currentDocument: "ab", currentSelection: NSRange(location: 0, length: 0)) else { return ["K: prepare1 not replace"] }
        expect(!t1.confirm(planID: p1.id, observedDocument: "Xab", observedSelection: NSRange(location: 2, length: 0)), "K: wrong caret accepted")
        expect(t1.isAbandoned, "K: wrong caret must abandon")
        guard var t2 = InlineDraftTransaction(originalText: "ab", selection: NSRange(location: 0, length: 0)) else { return ["K: init2 failed"] }
        guard case .replace(let p2) = t2.prepare(text: "X", sequence: 0, currentDocument: "ab", currentSelection: NSRange(location: 0, length: 0)) else { return ["K: prepare2 not replace"] }
        expect(!t2.confirm(planID: p2.id, observedDocument: "XbZ", observedSelection: NSRange(location: 1, length: 0)), "K: wrong document accepted")
        expect(t2.isAbandoned, "K: wrong document must abandon")
        return f
    }

    private static func checkLUnicodeNormalization() -> [String] {
        var f: [String] = []
        func expect(_ c: Bool, _ l: String) { if !c { f.append(l) } }
        let precomposed = "\u{00E9}" // 1 UTF16 unit
        let decomposed = "e\u{0301}" // 2 UTF16 units
        guard var t = InlineDraftTransaction(originalText: precomposed, selection: NSRange(location: 0, length: 0)) else { return ["L: init failed"] }
        let d = t.prepare(text: "X", sequence: 0, currentDocument: decomposed, currentSelection: NSRange(location: 0, length: 0))
        if case .abandoned = d {} else { f.append("L: decomposed document must not match precomposed") }
        expect(t.isAbandoned, "L: prepare abandon flag")
        guard var t2 = InlineDraftTransaction(originalText: precomposed, selection: NSRange(location: 0, length: 0)) else { return f + ["L: init2 failed"] }
        guard case .replace(let p) = t2.prepare(text: "X", sequence: 0, currentDocument: precomposed, currentSelection: NSRange(location: 0, length: 0)) else { return f + ["L: prepare2 not replace"] }
        expect(!t2.confirm(planID: p.id, observedDocument: "X" + decomposed, observedSelection: NSRange(location: 1, length: 0)), "L: decomposed confirm must fail")
        expect(t2.isAbandoned, "L: confirm abandon flag")
        return f
    }

    private static func checkMUncertainWriteReconciliation() -> [String] {
        var failures: [String] = []
        let caret = NSRange(location: 2, length: 0)
        for applied in [false, true] {
            guard var draft = InlineDraftTransaction(originalText: "ab", selection: caret),
                  case .replace(let plan) = draft.prepare(
                    text: "X", sequence: 1, currentDocument: "ab", currentSelection: caret)
            else { return ["M: prepare failed"] }
            let outcome = draft.reconcile(
                document: applied ? plan.expectedDocument : "ab",
                selection: applied ? plan.expectedSelection : caret)
            if outcome != (applied ? .applied : .notApplied) {
                failures.append("M: incorrect reconciliation for applied=\(applied)")
            }
            guard case .replace(let finalPlan) = draft.prepare(
                text: "final", sequence: UInt64.max,
                currentDocument: draft.lastDocument,
                currentSelection: draft.expectedSelection)
            else { failures.append("M: final revision blocked after reconciliation"); continue }
            if finalPlan.expectedDocument != "abfinal" {
                failures.append("M: final revision duplicated the draft")
            }
        }
        return failures
    }
}
