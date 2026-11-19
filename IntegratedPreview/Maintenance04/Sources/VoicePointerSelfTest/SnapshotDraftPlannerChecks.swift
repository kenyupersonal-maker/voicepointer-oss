import Foundation
@_spi(Testing) import VoicePointerCore

/// D1's one synthetic, bounded planner check; no AX, clipboard, keys, microphone or network.
enum SnapshotDraftPlannerChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("D1 " + label) } }
        guard var tail = SnapshotDraftPlanner(original: "prefix\n\n\u{fffc}", selection: NSRange(location: 6, length: 0)) else {
            return ["D1 snapshot fixture"]
        }
        expect(tail.locate(document: "prefixhello\n", caret: NSRange(location: 11, length: 0)) == nil, "unsubmitted text is never owned")
        tail.noteSubmitted("hello", sequence: 1)
        let owned = tail.locate(document: "prefix hello \n\u{fffc}\n", caret: NSRange(location: 14, length: 0))
        expect(owned?.range == NSRange(location: 6, length: 5), "trim equality and structural tail caret")
        expect(owned?.valueRange == NSRange(location: 7, length: 5), "trimmed value span differs from AX span")
        let revised = tail.plan(text: "hallo", document: "prefixhello\n", caret: NSRange(location: 12, length: 0))
        expect(revised?.range == NSRange(location: 7, length: 1) && revised?.replacement == "a", "changed subrange preserves own prefix and suffix")
        expect(tail.locate(document: "changedhello\n", caret: NSRange(location: 12, length: 0)) == nil, "outside anchor change rejects ownership")
        expect(tail.locate(document: "prefixhello\n", caret: NSRange(location: 8, length: 0)) == nil, "caret inside draft rejects confirmation")
        expect(tail.locate(document: "prefixhello" + String(repeating: "\n", count: 65), caret: NSRange(location: 11, length: 0)) == nil, "structural tail bounded")
        if var inside = SnapshotDraftPlanner(original: "base\n\n\u{fffc}", selection: NSRange(location: 6, length: 0)) {
            inside.noteSubmitted("hello", sequence: 1)
            expect(inside.locate(document: "base\n\nhello\u{fffc}\n", caret: NSRange(location: 13, length: 0))?.range == NSRange(location: 6, length: 5),
                   "caret within original structure tail preserves frozen prefix")
            expect(inside.locate(document: "baze\nhello\u{fffc}\n", caret: NSRange(location: 12, length: 0)) == nil,
                   "meaningful original prefix cannot change")
        } else { failures.append("D1 tail-inside fixture") }
        if var selection = SnapshotDraftPlanner(original: "aaOLDzz\n\n", selection: NSRange(location: 2, length: 3), selectedOriginal: "OLD") {
            selection.noteSubmitted("new", sequence: 1)
            expect(selection.locate(document: "aanewzz\n", caret: NSRange(location: 5, length: 0))?.range == NSRange(location: 2, length: 3),
                   "original selection excluded from both anchors")
            expect(selection.locate(document: "newaanewzz\n", caret: NSRange(location: 8, length: 0)) == nil,
                   "repeated text is not searched or adopted elsewhere")
        }
        let original = "prefix\n\n\u{fffc}"
        let originCaret = NSRange(location: 6, length: 0)
        expect(tail.finalDecision(document: original, caret: originCaret, originalConfirmedTwice: true) == .original(originCaret),
               "submitted but original twice unchanged permits one final release replacement")
        expect(tail.finalDecision(document: original, caret: originCaret, originalConfirmedTwice: false) == .clipboard,
               "single unchanged read cannot repeat an unknown write")
        if let owned {
            expect(tail.finalDecision(document: "prefix hello \n\u{fffc}\n", caret: owned.caret, originalConfirmedTwice: false) == .owned(owned),
                   "known submitted version permits final owned replacement")
        }
        let paragraphs = String(repeating: "a", count: 445)
        if var coordinates = SnapshotDraftPlanner(original: paragraphs + "\n\n", selection: NSRange(location: 444, length: 0)) {
            coordinates.noteSubmitted("alpha", sequence: 1)
            let first = coordinates.locate(document: paragraphs + "\nalpha", caret: NSRange(location: 449, length: 0))
            expect(first?.range == NSRange(location: 444, length: 5) && first?.valueRange == NSRange(location: 446, length: 5),
                   "real 447/444 fixture separates AX and value coordinates")
            let append = coordinates.plan(text: "alpha bravo", document: paragraphs + "\nalpha", caret: NSRange(location: 449, length: 0))
            expect(append?.range == NSRange(location: 449, length: 0) && append?.insertionEnd == 455,
                   "following draft diff uses frozen AX coordinate")
            if let first { coordinates.noteLocated(first) }
            coordinates.noteSubmitted("", sequence: 2)
            expect(coordinates.locate(document: paragraphs + "\n\n", caret: NSRange(location: 444, length: 0))?.valueRange == NSRange(location: 446, length: 0),
                   "deleted value point in structural tail accepts exact restored original")
        } else { failures.append("D1 coordinate fixture") }
        if var repeated = SnapshotDraftPlanner(original: "abc", selection: NSRange(location: 0, length: 0)) {
            repeated.noteSubmitted("abc", sequence: 1)
            expect(repeated.locate(document: "abcabc", caret: NSRange(location: 3, length: 0)) == nil,
                   "repeated middle cannot be uniquely assigned")
        }
        let sharedSuffix = String(repeating: "q", count: 54)
        if var versions = SnapshotDraftPlanner(original: "base" + sharedSuffix + "X", selection: NSRange(location: 58, length: 0)) {
            versions.noteSubmitted("first" + sharedSuffix, sequence: 1)
            versions.noteSubmitted("second" + sharedSuffix, sequence: 2)
            expect(versions.locate(document: "base" + sharedSuffix + "second" + sharedSuffix + "X", caret: NSRange(location: 118, length: 0), requireCaret: false)?.draft == "second" + sharedSuffix,
                   "bounded nonmatching earlier versions cannot exhaust one version search budget")
        }
        expect(tail.finalDecision(document: "prefixunknown\n", caret: NSRange(location: 13, length: 0), originalConfirmedTwice: false) == .clipboard,
               "unlocated release keeps final transcript on clipboard")
        let feedback = ComposerActionFeedback(outcome: .finalCopiedToClipboard)
        expect(feedback.shouldPresent && feedback.kind == .warning && feedback.presentation?.code == .finalCopiedToClipboard,
               "clipboard-only outcome is visible and never kept")
        return failures
    }
}
