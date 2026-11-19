import AppKit
import Foundation
@_spi(Testing) import VoicePointerCore

/// E1–E4 share one bounded check; editor delivery is never exercised on a real window.
@MainActor
enum ComposerContinuityChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) { if !condition { failures.append("E " + name) } }
        expect(TerminalPeriodPolicy.sentence("", prefix: "。").text.isEmpty &&
               TerminalPeriodPolicy.sentence("。", prefix: "。").text.isEmpty &&
               TerminalPeriodPolicy.sentence(" \n", prefix: ". ").text.isEmpty,
               "empty final and draft never become previous punctuation")
        expect(SilentSendPolicy.qualifies(partials: 0, peak: nil), "empty sentence retains silent-send admission")
        expect(TerminalPeriodPolicy.sentence("next。", prefix: "。").text == "。next", "nonempty sentence restores previous punctuation")
        let board = NSPasteboard(name: .init("VoicePointerContinuityFixture." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let transfer = ClipboardTransfer(pasteboard: board)
        do {
            _ = board.clearContents(); _ = board.setString("original synthetic clipboard", forType: .string)
            let first = try transfer.reserveDraft(expectedChangeCount: board.changeCount)
            try transfer.updateDraft(text: "first sentence", id: first)
            let release = Task { await transfer.releaseDraft(id: first) }
            for _ in 0..<16 where !transfer.pendingDraftRestore(id: first) { await Task.yield() }
            expect(transfer.pendingDraftRestore(id: first), "first release enters real bounded handoff state")
            let second = try transfer.reserveDraft(expectedChangeCount: board.changeCount)
            expect(second != first && transfer.owns(id: second), "second sentence rotates token and inherits original snapshot")
            try transfer.updateDraft(text: "second sentence", id: second)
            expect(!(await release.value) && !transfer.restore(id: first) && transfer.owns(id: second),
                   "expired first release cannot restore successor payload")
            let beforeReturn = board.changeCount
            expect(await transfer.releaseDraft(id: second), "last sentence restores original")
            expect(board.string(forType: .string) == "original synthetic clipboard", "two sentences return the first original snapshot")
            let restored = try transfer.reserveDraft(expectedChangeCount: beforeReturn)
            expect(transfer.restore(id: restored), "bounded self-write chain recognizes completed restoration")
            let third = try transfer.reserveDraft(expectedChangeCount: board.changeCount)
            try transfer.updateDraft(text: "third sentence", id: third)
            let beforeCopy = board.changeCount
            _ = board.clearContents(); _ = board.setString("user synthetic copy", forType: .string)
            let copied = board.changeCount
            expect(!(await transfer.releaseDraft(id: third)) && board.changeCount == copied &&
                   board.string(forType: .string) == "user synthetic copy", "external copy cannot be normalized or restored")
            do { _ = try transfer.reserveDraft(expectedChangeCount: beforeCopy); failures.append("E external count gap accepted") }
            catch { }
        } catch { failures.append("E clipboard continuity API failed") }
        expect(!InlineWritePolicy.acceptsPartial(" \n") && !InlineWritePolicy.acceptsPartial("hint", hotwordEcho: true),
               "empty and identified hotword partials cannot enter delivery")
        if let selected = SnapshotDraftPlanner(original: "old text", selection: NSRange(location: 0, length: 3), selectedOriginal: "old") {
            let range = NSRange(location: 0, length: 3)
            expect(selected.plan(text: "new", document: "old text", caret: range)?.range == range &&
                   selected.finalDecision(document: "old text", caret: range, originalConfirmedTwice: true) == .original(range),
                   "initial original selection can be replaced after its selected-text witness is checked")
        }
        if var owned = SnapshotDraftPlanner(original: "prefix", selection: NSRange(location: 6, length: 0)) {
            owned.noteSubmitted("alpha", sequence: 1)
            let caret = NSRange(location: 11, length: 0)
            expect(owned.permits(NSRange(location: 7, length: 2), document: "prefixalpha", caret: caret, initial: false) &&
                   !owned.permits(NSRange(location: 5, length: 2), document: "prefixalpha", caret: caret, initial: false),
                   "changed selection must stay entirely inside the proven sentence")
        }
        return failures
    }
}
