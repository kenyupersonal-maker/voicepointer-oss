import AppKit
@_spi(Testing) import VoicePointerCore

@MainActor
private final class ToastProbeTextView: NSTextView {
    enum ReturnBehavior {
        case recordAndKeepText
        case recordAndClear
        case recordAndClearAfter(milliseconds: Int)
        case insertNewline
        case replaceFocus(NSWindow, NSTextView)
    }

    var returnBehavior: ReturnBehavior = .recordAndClear
    private(set) var submittedMessages: [String] = []
    private(set) var receivedReturnCount = 0

    func resetLedger() {
        submittedMessages.removeAll(keepingCapacity: true)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 36, !modifiers.contains(.shift) else {
            super.keyDown(with: event)
            return
        }

        receivedReturnCount += 1
        let message = string
        switch returnBehavior {
        case .recordAndKeepText:
            submittedMessages.append(message)
        case .recordAndClear:
            submittedMessages.append(message)
            string = ""
            setSelectedRange(NSRange(location: 0, length: 0))
        case .recordAndClearAfter(let milliseconds):
            submittedMessages.append(message)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(milliseconds))
                guard let self else { return }
                self.string = ""
                self.setSelectedRange(NSRange(location: 0, length: 0))
            }
        case .insertNewline:
            insertText("\n", replacementRange: selectedRange())
        case .replaceFocus(let window, let replacement):
            window.makeFirstResponder(replacement)
        }
    }
}

@MainActor
enum ComposerActionIntegrationProbe {
    static func run(textView: ComposerProbeTextView) async -> String {
        guard AccessibilityPermission.isTrusted else { return "ComposerActionProbe: FAIL accessibility=missing" }
        let executor = MacOSComposerActionExecutor()
        textView.allowsUndo = true
        func moveCaretToEnd() {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
        func focusProbe() async -> Bool {
            guard let window = textView.window else { return false }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            NSApplication.shared.activate(ignoringOtherApps: true)
            for _ in 0..<10 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
                   window.firstResponder === textView {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            return false
        }

        textView.string = "原文🙂 手打"
        textView.undoManager?.removeAllActions()
        // Model the stale AX caret observed with IME-backed Electron editors:
        // the session reports the beginning even though Doubao commits at end.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        guard await focusProbe() else {
            return "ComposerActionProbe: FAIL focus(cancel)"
        }
        guard case .ready(let cancelSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(cancel)"
        }
        let delayedCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            let dictationRange = NSRange(location: (textView.string as NSString).length, length: 0)
            textView.insertText(" 本次语音", replacementRange: dictationRange)
            textView.breakUndoCoalescing()
        }
        let cancelOutcome = await executor.perform(.cancel, session: cancelSession)
        await delayedCommit.value
        let rollbackOK = cancelOutcome == .removedCurrentDictation &&
            textView.string == "原文🙂 手打"

        // This lands after the legacy 800 ms settle window and models the
        // intermittent Doubao commit that previously became nothingToCancel.
        textView.string = "晚提交原文"
        moveCaretToEnd()
        guard await focusProbe() else {
            return "ComposerActionProbe: FAIL focus(lateCancel)"
        }
        guard case .ready(let lateCancelSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(lateCancel)"
        }
        let lateCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_150))
            let dictationRange = NSRange(location: (textView.string as NSString).length, length: 0)
            textView.insertText(" 晚提交语音", replacementRange: dictationRange)
            textView.breakUndoCoalescing()
        }
        let lateCancelOutcome = await executor.perform(.cancel, session: lateCancelSession)
        await lateCommit.value
        let lateRollbackOK = lateCancelOutcome == .removedCurrentDictation &&
            textView.string == "晚提交原文"

        // Returning to the neutral action between the two Cancels must not
        // discard the content-bound clear receipt.
        guard case .ready(let neutralSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(neutralBetweenCancels)"
        }
        let neutralOutcome = await executor.perform(.stop, session: neutralSession)

        // The follow-up empty Cancel is content-bound, not time-bound.
        try? await Task.sleep(for: .milliseconds(3_150))
        guard await focusProbe() else {
            return "ComposerActionProbe: FAIL focus(stagedClear)"
        }
        guard case .ready(let stagedClearSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(stagedClear)"
        }
        let stagedClearStartedAt = Date()
        let stagedClearOutcome = await executor.perform(.cancel, session: stagedClearSession)
        let stagedClearElapsed = Date().timeIntervalSince(stagedClearStartedAt)
        let stagedClearOK = stagedClearOutcome == .clearedCurrentInput &&
            textView.string.isEmpty && stagedClearElapsed < 0.8

        // Dictation may replace an existing selection. Restore only that
        // selected fragment, without writing an unrelated whole-editor undo.
        textView.string = "保留的手打内容"
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        guard await focusProbe() else {
            return "ComposerActionProbe: FAIL focus(snapshotRestore)"
        }
        guard case .ready(let snapshotSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(snapshotRestore)"
        }
        textView.string = "豆包改写后的整段内容"
        moveCaretToEnd()
        let snapshotOutcome = await executor.perform(.cancel, session: snapshotSession)
        let selectionRollbackOK = snapshotOutcome == .removedCurrentDictation &&
            textView.string == "保留的手打内容"
        guard case .ready(let discardReceiptSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(discardReceipt)"
        }
        _ = await executor.perform(.send, session: discardReceiptSession)

        // A non-contiguous edit still has no safe local rollback and must stay
        // untouched instead of restoring a whole AXValue snapshot.
        textView.string = "保留的手打内容"
        moveCaretToEnd()
        guard await focusProbe(), case .ready(let unsafeSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(unsafeRollback)"
        }
        textView.string = "前保留的手打内容后"
        moveCaretToEnd()
        let unsafeOutcome = await executor.perform(.cancel, session: unsafeSession)
        let unsafeRollbackOK = unsafeOutcome == .clearArmed &&
            textView.string == "前保留的手打内容后"
        guard case .ready(let unsafeClearSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(unsafeClear)"
        }
        let unsafeClearOutcome = await executor.perform(.cancel, session: unsafeClearSession)
        let unsafeFallbackClearOK = unsafeClearOutcome == .clearedCurrentInput && textView.string.isEmpty

        // Leave a native undo entry behind, then verify Cancel on an already
        // empty composer cannot resurrect it.
        textView.insertText("历史草稿", replacementRange: textView.selectedRange())
        textView.selectAll(nil)
        textView.deleteBackward(nil)
        textView.breakUndoCoalescing()
        let editorHadUndo = textView.undoManager?.canUndo == true
        guard await focusProbe() else {
            return "ComposerActionProbe: FAIL focus(emptyCancel)"
        }
        guard case .ready(let emptyCancelSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(emptyCancel)"
        }
        let emptyCancel = await executor.perform(.cancel, session: emptyCancelSession)
        let emptyCancelOK = emptyCancel == .nothingToCancel && textView.string.isEmpty

        let returnCountBeforeEmptySend = textView.receivedReturnCount
        guard await focusProbe() else {
            return "ComposerActionProbe: FAIL focus(emptySend)"
        }
        guard case .ready(let emptySendSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(emptySend)"
        }
        let emptySend = await executor.perform(.send, session: emptySendSession)
        let emptySendOK = emptySend == .sendUnconfirmed &&
            textView.string.isEmpty &&
            textView.receivedReturnCount == returnCountBeforeEmptySend + 1

        let sendOriginal = "发送测试"
        textView.string = sendOriginal
        moveCaretToEnd()
        guard await focusProbe() else {
            return "ComposerActionProbe: FAIL focus(send)"
        }
        guard case .ready(let sendSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "ComposerActionProbe: FAIL beginSession(send)"
        }
        textView.insertText(" 内容", replacementRange: textView.selectedRange())
        let sendOutcome = await executor.perform(.send, session: sendSession)
        try? await Task.sleep(for: .milliseconds(150))
        let sendOK = sendOutcome == .sent && textView.string.isEmpty

        // These fixtures are deliberately separate from ComposerProbeTextView:
        // they model the editor-side ledger independently of AX text. Each
        // perform(.send) is one fresh session and can post at most one Return.
        let toastFixtures = await runToastSendFixtures()
        let toastFixturesOK = toastFixtures.contains("toastFixtures=PASS")
        let passed = rollbackOK && lateRollbackOK && neutralOutcome == .kept && stagedClearOK &&
            selectionRollbackOK && unsafeRollbackOK &&
            unsafeFallbackClearOK &&
            emptyCancelOK && emptySendOK && sendOK && toastFixturesOK
        return "ComposerActionProbe: \(passed ? "PASS" : "FAIL") " +
            "cancel=\(cancelOutcome.rawValue) staged=\(stagedClearOutcome.rawValue) " +
            "lateCancel=\(lateCancelOutcome.rawValue) " +
            "empty=\(emptyCancel.rawValue) " +
            "emptySend=\(emptySend.rawValue) " +
            "send=\(sendOutcome.rawValue) " +
            "rollbackOnly=\(rollbackOK ? "PASS" : "FAIL") " +
            "lateRollback=\(lateRollbackOK ? "PASS" : "FAIL") " +
            "stagedClear=\(stagedClearOK ? "PASS" : "FAIL") " +
            "selectionRollback=\(selectionRollbackOK ? "PASS" : "FAIL") " +
            "unsafeRollback=\(unsafeRollbackOK ? "PASS" : "FAIL") " +
            "unsafeFallbackClear=\(unsafeFallbackClearOK ? "PASS" : "FAIL") " +
            "stagedClearMs=\(Int(stagedClearElapsed * 1_000)) " +
            "emptyStaysEmpty=\(emptyCancelOK ? "PASS" : "FAIL") " +
            "emptySendNoReturn=\(emptySendOK ? "PASS" : "FAIL") " +
            "sendCheck=\(sendOK ? "PASS" : "FAIL") " +
            "editorHadUndo=\(editorHadUndo) " +
            toastFixtures
    }

    private static func runToastSendFixtures() async -> String {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 520, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let fixture = ToastProbeTextView(frame: NSRect(x: 20, y: 70, width: 480, height: 70))
        let replacement = NSTextView(frame: NSRect(x: 20, y: 10, width: 480, height: 40))
        replacement.isEditable = true
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.addSubview(fixture)
        content.addSubview(replacement)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        func focusFixture() async -> Bool {
            window.makeKeyAndOrderFront(nil)
            guard window.makeFirstResponder(fixture) else { return false }
            NSApplication.shared.activate(ignoringOtherApps: true)
            for _ in 0..<12 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
                   window.firstResponder === fixture {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return false
        }

        func send(
            text: String,
            behavior: ToastProbeTextView.ReturnBehavior,
            settleMilliseconds: Int = 1_300
        ) async -> (ComposerActionOutcome, String, Int, Int) {
            fixture.returnBehavior = behavior
            fixture.string = text
            fixture.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            fixture.resetLedger()
            let beforeReturn = fixture.receivedReturnCount
            let executor = MacOSComposerActionExecutor()
            guard await focusFixture(),
                  case .ready(let session) = await executor.beginSession(cancellationToken: .init()) else {
                return (.targetChanged, fixture.string, 0, fixture.receivedReturnCount - beforeReturn)
            }
            let outcome = await executor.perform(.send, session: session)
            try? await Task.sleep(for: .milliseconds(settleMilliseconds))
            return (outcome, fixture.string, fixture.submittedMessages.count,
                    fixture.receivedReturnCount - beforeReturn)
        }

        // P1-01: Return is recorded by the editor, while AX text remains.
        // The prompt must ask the user to check, never assert no submission.
        let keep = await send(text: "已记录但仍保留", behavior: .recordAndKeepText)
        let keepOK = keep.2 == 1 && keep.3 == 1 && keep.1 == "已记录但仍保留" &&
            keep.0 == .sendStillPresent

        // P1-02: editor commits asynchronously after the 850ms AX window.
        let late = await send(
            text: "延迟清空消息",
            behavior: .recordAndClearAfter(milliseconds: 1_100),
            settleMilliseconds: 1_250
        )
        let lateOK = late.2 == 1 && late.3 == 1 && late.1.isEmpty &&
            (late.0 == .sent || late.0 == .sendUnconfirmed)

        // P1-04: Return becomes a newline; no message ledger entry exists.
        let newline = await send(text: "换行未提交", behavior: .insertNewline)
        let newlineOK = newline.2 == 0 && newline.3 == 1 && newline.1.contains("\n") &&
            newline.0 == .sendStillPresent

        // P1-03: focus replacement alone is not a message submission proof.
        let replaced = await send(
            text: "焦点替换但未提交",
            behavior: .replaceFocus(window, replacement)
        )
        let replacementOK = replaced.2 == 0 && replaced.3 == 1 && replaced.1 == "焦点替换但未提交" &&
            replaced.0 != .sent

        window.orderOut(nil)
        let passed = keepOK && lateOK && newlineOK && replacementOK
        return "toastFixtures=\(passed ? "PASS" : "FAIL") " +
            "keepLedger=\(keepOK ? "PASS" : "FAIL") " +
            "lateClear=\(lateOK ? "PASS" : "FAIL") " +
            "newline=\(newlineOK ? "PASS" : "FAIL") " +
            "focusReplace=\(replacementOK ? "PASS" : "FAIL") " +
            "returnDelta=\(keep.3),\(late.3),\(newline.3),\(replaced.3) " +
            "unsupported=cancelDelayedAXWrite,humanMessageObservation"
    }
}
