import AppKit
import Foundation
@_spi(Testing) import VoicePointerCore

/// L1's single integration check. Uses a disposable named pasteboard and an in-memory editor;
/// the real draft pump, changed-range transaction, and clipboard lease run without AX or key events.
@MainActor
enum InlineDraftClipboardChecks {
    @MainActor
    private final class Editor: InlineTranscriptDelivering, Sendable {
        let transfer: ClipboardTransfer
        let lease: UUID
        var draft: InlineDraftTransaction
        var document = "prefix|suffix"
        var selection = NSRange(location: 7, length: 0)
        var sequences: [UInt64] = []
        var times: [TimeInterval] = []
        var plans: [InlineDraftTransaction.Plan] = []
        var clipboardLost = false

        init(transfer: ClipboardTransfer, lease: UUID) {
            self.transfer = transfer
            self.lease = lease
            draft = InlineDraftTransaction(originalText: document, selection: selection)!
        }

        func updateDraft(text: String, sequence: UInt64, session: ComposerActionSession?) async -> InlineDraftUpdateOutcome {
            sequences.append(sequence)
            times.append(ProcessInfo.processInfo.systemUptime)
            guard !clipboardLost, transfer.owns(id: lease) else { clipboardLost = true; return .unsupported }
            switch draft.prepare(text: text, sequence: sequence, currentDocument: document,
                                 currentSelection: selection, replacingOnlyChanges: true) {
            case .unchanged, .stale: return .unchanged
            case .replace(let plan):
                do {
                    if !plan.text.isEmpty { try transfer.updateDraft(text: plan.text, id: lease) }
                } catch { clipboardLost = true; return .unsupported }
                plans.append(plan)
                document = (document as NSString).replacingCharacters(in: plan.replaceRange, with: plan.text)
                selection = plan.expectedSelection
                return draft.confirm(planID: plan.id, observedDocument: document, observedSelection: selection) ? .updated : .unconfirmed
            case .abandoned, .busy: return .abandoned
            }
        }

        func deliver(text: String, action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
            guard !clipboardLost, transfer.owns(id: lease) else {
                transfer.abandon(id: lease)
                return .deliveryFailed
            }
            let outcome = await updateDraft(text: text, sequence: UInt64.max, session: session)
            guard outcome == .updated || outcome == .unchanged else { transfer.abandon(id: lease); return .deliveryUnconfirmed }
            return transfer.restore(id: lease) ? .kept : .deliveryFailed
        }
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= end { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("L1 " + label) } }
        let board = NSPasteboard(name: .init("VoicePointerL1Fixture." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let transfer = ClipboardTransfer(pasteboard: board)
        func copy(_ text: String) {
            _ = board.clearContents()
            expect(board.setString(text, forType: .string), "fixture clipboard write")
        }
        func event(_ seq: UInt64, _ text: String, _ speech: UUID) -> SpeechInputEvent {
            .init(sessionID: speech, sequence: seq, observedMilliseconds: 0, kind: .partial, text: text)
        }
        do {
            copy("original synthetic clipboard")
            let start = board.changeCount
            let lease = try transfer.reserveDraft(expectedChangeCount: start)
            expect(board.changeCount == start && board.string(forType: .string) == "original synthetic clipboard",
                   "sentence-start borrow does not write")
            do { _ = try transfer.reserveDraft(expectedChangeCount: start); failures.append("L1 sentence borrowed twice") }
            catch { /* The same sentence keeps its first snapshot. */ }
            let editor = Editor(transfer: transfer, lease: lease)
            let speech = UUID()
            let token = ComposerActionSession(testIdentifier: 1)
            let pump = InlineDraftPump(deliverer: editor, session: token, speechSessionID: speech)
            pump.enqueue(event(1, "red fox tail", speech))
            guard await waitUntil({ !pump.isUpdating && editor.plans.count == 1 }) else { return failures + ["L1 first draft timeout"] }
            for seq in 2...10 { pump.enqueue(event(UInt64(seq), seq == 10 ? "blue fox tail" : "intermediate", speech)) }
            guard await waitUntil({ !pump.isUpdating }) else { return failures + ["L1 merged draft timeout"] }
            expect(editor.sequences == [1, 10], "coalesces latest draft")
            expect(editor.times.count == 2 && editor.times[1] - editor.times[0] >= 0.250, "at least 250ms between drafts")
            expect(editor.plans.last?.replaceRange == NSRange(location: 7, length: 3) && editor.plans.last?.text == "blue",
                   "only changed segment replaces common prefix and suffix")
            expect(editor.draft.writtenRange == NSRange(location: 7, length: 13) && editor.selection.location == 20,
                   "changed segment retains entire draft ownership and end caret")
            let ownedCount = board.changeCount
            pump.enqueue(event(11, "blue fox tail", speech))
            guard await waitUntil({ !pump.isUpdating }) else { return failures + ["L1 identical draft timeout"] }
            expect(editor.sequences == [1, 10] && board.changeCount == ownedCount, "identical draft does not write")
            let types = board.pasteboardItems?.first?.types ?? []
            expect(types.contains(.init("org.nspasteboard.TransientType")) && types.contains(.init("org.nspasteboard.ConcealedType")),
                   "private clipboard markers")
            await pump.finish()
            let final = await editor.deliver(text: "blue fox tail!", action: .stop, session: token)
            expect(final == .kept && board.string(forType: .string) == "original synthetic clipboard" && !transfer.owns(id: lease),
                   "one sentence restores original after final")

            // A copy after sentence-start reservation but before its first draft is also external.
            let beforeFirst = try transfer.reserveDraft(expectedChangeCount: board.changeCount)
            copy("user copy before first draft")
            let copiedBefore = board.changeCount
            do { try transfer.updateDraft(text: "must not paste", id: beforeFirst); failures.append("L1 copied start accepted") }
            catch { }
            expect(!transfer.restore(id: beforeFirst) && board.changeCount == copiedBefore &&
                   board.string(forType: .string) == "user copy before first draft", "pre-draft copy survives without restore")

            let nextLease = try transfer.reserveDraft(expectedChangeCount: board.changeCount)
            let nextEditor = Editor(transfer: transfer, lease: nextLease)
            let nextSpeech = UUID()
            let nextToken = ComposerActionSession(testIdentifier: 2)
            let nextPump = InlineDraftPump(deliverer: nextEditor, session: nextToken, speechSessionID: nextSpeech)
            nextPump.enqueue(event(1, "confirmed draft", nextSpeech))
            guard await waitUntil({ !nextPump.isUpdating && nextEditor.plans.count == 1 }) else { return failures + ["L1 next draft timeout"] }
            copy("user copy midway")
            let copiedCount = board.changeCount
            nextPump.enqueue(event(2, "new draft", nextSpeech))
            guard await waitUntil({ !nextPump.isUpdating }) else { return failures + ["L1 copy detection timeout"] }
            nextPump.enqueue(event(3, "must stay final-only", nextSpeech))
            await nextPump.finish()
            let failedFinal = await nextEditor.deliver(text: "must not overwrite user copy", action: .stop, session: nextToken)
            expect(nextEditor.sequences == [1, 2] && nextEditor.draft.lastDraft == "confirmed draft" && failedFinal == .deliveryFailed,
                   "copy switches remaining drafts to final-only and visible failure")
            expect(board.changeCount == copiedCount && board.string(forType: .string) == "user copy midway" &&
                   !transfer.restore(id: nextLease), "midway copy survives without restoration or another borrow")
        } catch { failures.append("L1 fixture lease unavailable") }
        return failures
    }
}
