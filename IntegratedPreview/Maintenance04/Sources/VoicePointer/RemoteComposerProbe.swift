import AppKit
import ApplicationServices
@_spi(Testing) import VoicePointerCore

private struct EditorCommand: Encodable, Sendable {
    var id = 0
    let op: String
    var value: String?
    var delayMs: Int?
}

private struct EditorReply: Decodable, Sendable {
    let id: Int
    let ok: Bool
    let value: String
    let returnCount: Int
    let submittedCount: Int
    let ledger: [String]
    let focusedPrimary: Bool
    let axSetterCount: Int
    let axReadCount: Int
    let pid: Int
    let isFrontmost: Bool
    let secureFocused: Bool
    let secureMatches: Bool
    let secureCount: Int
}

/// Only this private serial I/O queue touches the pipe protocol. AppKit and
/// the AX executor remain responsive while the remote editor answers.
private final class EditorClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "com.voicepointer.probe.editor-io")
    private var nextID = 0
    var pid: pid_t { process.processIdentifier }

    init(executable: String) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
    }

    func ready() async -> EditorReply? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readReply()) }
        }
    }

    func call(_ op: String, value: String? = nil, delayMs: Int? = nil) async -> EditorReply? {
        let command = EditorCommand(op: op, value: value, delayMs: delayMs)
        return await withCheckedContinuation { continuation in
            queue.async {
                self.nextID += 1
                var request = command
                request.id = self.nextID
                do {
                    var bytes = try JSONEncoder().encode(request)
                    bytes.append(10)
                    try self.input.fileHandleForWriting.write(contentsOf: bytes)
                    let reply = self.readReply()
                    continuation.resume(returning: reply?.id == request.id ? reply : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func readReply() -> EditorReply? {
        var data = Data()
        while data.count < 64_000 {
            guard let byte = try? output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { return nil }
            if byte.first == 10 { return try? JSONDecoder().decode(EditorReply.self, from: data) }
            data.append(byte)
        }
        return nil
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

@MainActor
enum RemoteComposerProbe {
    /// Only a disposable NSSecureTextField owned by our synthetic helper is touched.
    /// Its content never leaves the helper: the pipe returns equality and counts only.
    static func runSecure(editorExecutable: String) async -> String {
        guard AccessibilityPermission.isTrusted, EventAccessPermission.canPost else {
            return "RemoteComposerProbe: FAIL secure permissions"
        }
        let client: EditorClient
        do { client = try EditorClient(executable: editorExecutable) }
        catch { return "RemoteComposerProbe: FAIL secure helper launch" }
        defer { client.stop() }
        guard await client.ready()?.ok == true,
              await client.call("secureFocus", value: "fixture-")?.ok == true,
              await client.call("secureExpect", value: "fixture-")?.ok == true else {
            return "RemoteComposerProbe: FAIL secure fixture"
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == client.pid else {
            return "RemoteComposerProbe: FAIL secure focus"
        }
        let app = AXUIElementCreateApplication(client.pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return "RemoteComposerProbe: FAIL secure AX focus"
        }
        let field = unsafeDowncast(focused, to: AXUIElement.self)
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &role)
        let secureRole = (role as? String) == "AXSecureTextField"
        let executor = MacOSComposerActionExecutor(testTargetPID: client.pid)
        let clipboardCount = NSPasteboard.general.changeCount // Metadata only, never clipboard contents.
        guard case .ready(let session) = await executor.beginSession(cancellationToken: .init()), session.isSecureField else {
            return "RemoteComposerProbe: FAIL secure acquisition"
        }
        let partial = await executor.updateDraft(text: "discarded", sequence: 1, session: session)
        let afterPartial = await client.call("get")
        let partialOK = partial == .unsupported && afterPartial?.secureMatches == true
        let sample = String(repeating: "Ab中文🙂42", count: 6) // Cross several event chunks, including surrogate pairs.
        _ = await client.call("secureExpect", value: "fixture-" + sample)
        let typed = await executor.deliver(text: sample, action: .stop, session: session)
        try? await Task.sleep(for: .milliseconds(250))
        let final = await client.call("get")
        let finalOK = typed == .inputSubmitted && final?.secureMatches == true && final?.returnCount == 0

        _ = await client.call("secureFocus", value: "replace-this-fixture")
        _ = await client.call("secureSelectAll")
        _ = await client.call("secureExpect", value: sample)
        guard case .ready(let replacement) = await executor.beginSession(cancellationToken: .init()) else {
            return "RemoteComposerProbe: FAIL secure replacement acquisition"
        }
        _ = await executor.deliver(text: sample, action: .stop, session: replacement)
        try? await Task.sleep(for: .milliseconds(200))
        let replacementOK = await client.call("get")?.secureMatches == true

        guard case .ready(let send) = await executor.beginSession(cancellationToken: .init()) else {
            return "RemoteComposerProbe: FAIL secure send acquisition"
        }
        let sent = await executor.perform(.send, session: send)
        _ = await executor.perform(.send, session: send)
        try? await Task.sleep(for: .milliseconds(200))
        let sendState = await client.call("get")
        let sendOK = sent == .sendUnconfirmed && sendState?.returnCount == 1

        _ = await client.call("secureFocus", value: "kept-fixture")
        _ = await client.call("secureExpect", value: "kept-fixture")
        guard case .ready(let cancelled) = await executor.beginSession(cancellationToken: .init()) else {
            return "RemoteComposerProbe: FAIL secure cancel acquisition"
        }
        let cancel = await executor.deliver(text: "discarded", action: .cancel, session: cancelled)
        let cancelState = await client.call("get")
        let cancelOK = cancel == .nothingToCancel && cancelState?.secureMatches == true

        guard case .ready(let moved) = await executor.beginSession(cancellationToken: .init()) else {
            return "RemoteComposerProbe: FAIL secure movement acquisition"
        }
        _ = await client.call("focus")
        let refused = await executor.deliver(text: "must-not-land", action: .stop, session: moved)
        let afterMove = await client.call("get")
        let moveOK = refused != .inputSubmitted && afterMove?.secureMatches == true && afterMove?.value.isEmpty == true
        let clipboardOK = NSPasteboard.general.changeCount == clipboardCount
        let success = secureRole && partialOK && finalOK && replacementOK && sendOK && cancelOK && moveOK && clipboardOK
        return "RemoteComposerProbe: \(success ? "PASS" : "FAIL") secureRole=\(secureRole ? 1 : 0) partialSuppressed=\(partialOK ? 1 : 0) finalExact=\(finalOK ? 1 : 0) selectionExact=\(replacementOK ? 1 : 0) returnOnce=\(sendOK ? 1 : 0) cancelPreserved=\(cancelOK ? 1 : 0) focusProtected=\(moveOK ? 1 : 0) clipboardUnchanged=\(clipboardOK ? 1 : 0)"
    }

    static func run(editorExecutable: String) async -> String {
        guard AccessibilityPermission.isTrusted, EventAccessPermission.canPost else {
            return "RemoteComposerProbe: FAIL permissions missing"
        }
        let client: EditorClient
        do { client = try EditorClient(executable: editorExecutable) }
        catch { return "RemoteComposerProbe: FAIL editor launch \(error.localizedDescription)" }
        defer { client.stop() }
        guard let ready = await client.ready(), ready.ok, ready.id == 0, ready.pid == Int(client.pid) else {
            return "RemoteComposerProbe: FAIL editor handshake"
        }
        let executor = MacOSComposerActionExecutor(testTargetPID: client.pid)
        _ = await client.call("focus")
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == client.pid { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == client.pid else {
            return "RemoteComposerProbe: FAIL editor focus"
        }

        let original = "原文🙂 手打"
        guard await client.call("set", value: original)?.ok == true,
              case .ready(let rollbackSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "RemoteComposerProbe: FAIL begin rollback"
        }
        guard await client.call("insert", value: " 本次语音", delayMs: 450)?.ok == true else {
            return "RemoteComposerProbe: FAIL delayed insertion"
        }
        let rollback = await executor.perform(.cancel, session: rollbackSession)
        let afterRollback = await waitForValue(original, client: client)
        let rollbackOK = [.undoSubmitted, .removedCurrentDictation].contains(rollback)
            && afterRollback?.value == original && afterRollback?.returnCount == 0

        guard await client.call("set", value: "")?.ok == true,
              case .ready(let emptySession) = await executor.beginSession(cancellationToken: .init()) else {
            return "RemoteComposerProbe: FAIL begin empty (rollback=\(rollback.rawValue))"
        }
        let empty = await executor.perform(.send, session: emptySession)
        let repeatedEmpty = await executor.perform(.send, session: emptySession)
        let afterEmpty = await client.call("get")
        let emptyOK = empty == .sendUnconfirmed && repeatedEmpty != .sent && afterEmpty?.returnCount == 1

        guard await client.call("set", value: "仅本地测试")?.ok == true,
              case .ready(let sendSession) = await executor.beginSession(cancellationToken: .init()) else {
            return "RemoteComposerProbe: FAIL begin send"
        }
        let sent = await executor.perform(.send, session: sendSession)
        // Idempotence guard: a second invocation on the same completed
        // session is not a retry and must not post another Return.
        let repeated = await executor.perform(.send, session: sendSession)
        let afterSend = await client.call("get")
        let sendOK = sent == .sent && repeated != .sent && afterSend?.value == "" && afterSend?.returnCount == 1

        let keep = await runSendFixture(
            client: client, executor: executor, text: "已记录但仍保留", behavior: "keep"
        )
        let late = await runSendFixture(
            client: client, executor: executor, text: "延迟清空消息", behavior: "delayClear", delayMs: 1_100
        )
        let newline = await runSendFixture(
            client: client, executor: executor, text: "换行未提交", behavior: "newline"
        )
        let focusReplace = await runSendFixture(
            client: client, executor: executor, text: "焦点替换但未提交", behavior: "replaceFocus"
        )
        let placeholderClear = await runSendFixture(
            client: client, executor: executor, text: "清空后占位", behavior: "clear", axStream: "placeholder"
        )
        let toastFixturesOK = keep.ok && late.ok && newline.ok && focusReplace.ok && placeholderClear.ok

        let cancelLag = await runCancelAXLagFixture(client: client, executor: executor)
        let unsettledSend = await runUnsettledFixture(client: client, executor: executor, action: .send, stream: "changing")
        let unreadableSend = await runUnsettledFixture(client: client, executor: executor, action: .send, stream: "unreadable")
        let unsettledCancel = await runUnsettledFixture(client: client, executor: executor, action: .cancel, stream: "changing")
        let lateDictation = await runLateDictationFixture(client: client, executor: executor)

        let token = OperationCancellationToken()
        guard await client.call("focus")?.ok == true,
              await client.call("set", value: "取消后保持")?.ok == true,
              case .ready(let cancelledSession) = await executor.beginSession(cancellationToken: token) else {
            return "RemoteComposerProbe: FAIL begin cancellation"
        }
        let beforeCancelled = await client.call("get")?.returnCount ?? -1
        token.cancel()
        let cancelled = await executor.perform(.send, session: cancelledSession)
        let afterCancelled = await client.call("get")
        let cancellationOK = cancelled == .targetChanged && afterCancelled?.value == "取消后保持" &&
            afterCancelled?.returnCount == beforeCancelled
        let passed = rollbackOK && emptyOK && sendOK && cancellationOK && toastFixturesOK && cancelLag.ok &&
            unsettledSend && unreadableSend && unsettledCancel && lateDictation
        _ = await client.call("quit")
        return "RemoteComposerProbe: \(passed ? "PASS" : "FAIL") rollback=\(rollbackOK)(\(rollback.rawValue)) empty=\(emptyOK) sendExactlyOnce=\(sendOK)(\(sent.rawValue)) cancelledSendBlocked=\(cancellationOK) " +
            "toastFixtures=\(toastFixturesOK ? "PASS" : "FAIL") " +
            "keep=\(keep.ok)(\(keep.outcome.rawValue),ledger=\(keep.ledgerCount),returns=\(keep.returnDelta)) " +
            "lateClear=\(late.ok)(\(late.outcome.rawValue),ledger=\(late.ledgerCount),returns=\(late.returnDelta)) " +
            "newline=\(newline.ok)(\(newline.outcome.rawValue),ledger=\(newline.ledgerCount),returns=\(newline.returnDelta)) " +
            "focusReplace=\(focusReplace.ok)(\(focusReplace.outcome.rawValue),ledger=\(focusReplace.ledgerCount),returns=\(focusReplace.returnDelta)) " +
            "placeholderClear=\(placeholderClear.ok)(\(placeholderClear.outcome.rawValue),ledger=\(placeholderClear.ledgerCount),returns=\(placeholderClear.returnDelta)) " +
            "cancelAXLag=\(cancelLag.ok)(\(cancelLag.outcome.rawValue),setter=\(cancelLag.axSetterCount),reads=\(cancelLag.axReadCount)) " +
            "unsettledSendBlocked=\(unsettledSend) unreadableSendBlocked=\(unreadableSend) unsettledCancelBlocked=\(unsettledCancel) lateDictationComplete=\(lateDictation) " +
            "unsupported=cancelDelayedAXWrite,humanMessageObservation"
    }

    private static func runUnsettledFixture(
        client: EditorClient,
        executor: MacOSComposerActionExecutor,
        action: VoiceReleaseAction,
        stream: String
    ) async -> Bool {
        let original = "不稳定时不得操作的测试文本"
        guard await client.call("reset")?.ok == true,
              await client.call("behavior", value: "clear")?.ok == true,
              await client.call("set", value: original)?.ok == true,
              await client.call("focus")?.ok == true,
              case .ready(let session) = await executor.beginSession(cancellationToken: .init()),
              await client.call("axStream", value: stream)?.ok == true else { return false }
        let outcome = await executor.perform(action, session: session)
        _ = await client.call("axStream", value: "stable")
        let after = await client.call("get")
        return outcome == .dictationNotSettled && after?.returnCount == 0 &&
            after?.submittedCount == 0 && after?.axSetterCount == 0 && after?.value == original
    }

    private static func runLateDictationFixture(
        client: EditorClient,
        executor: MacOSComposerActionExecutor
    ) async -> Bool {
        let prefix = "先到的文本"
        let suffix = "，以及稍后才提交的听写"
        guard await client.call("reset")?.ok == true,
              await client.call("behavior", value: "clear")?.ok == true,
              await client.call("set", value: prefix)?.ok == true,
              await client.call("focus")?.ok == true,
              case .ready(let session) = await executor.beginSession(cancellationToken: .init()),
              await client.call("insert", value: suffix, delayMs: 950)?.ok == true else { return false }
        let outcome = await executor.perform(.send, session: session)
        let after = await client.call("get")
        return outcome == .sent && after?.returnCount == 1 && after?.submittedCount == 1 &&
            after?.ledger == [prefix + suffix] && after?.value == ""
    }

    private struct SendFixtureResult {
        let outcome: ComposerActionOutcome
        let ok: Bool
        let ledgerCount: Int
        let returnDelta: Int
    }

    private struct CancelLagResult {
        let outcome: ComposerActionOutcome
        let ok: Bool
        let axSetterCount: Int
        let axReadCount: Int
    }

    private static func runCancelAXLagFixture(
        client: EditorClient,
        executor: MacOSComposerActionExecutor
    ) async -> CancelLagResult {
        let original = "撤回原文"
        guard await client.call("reset")?.ok == true,
              await client.call("axLag", value: "on")?.ok == true,
              await client.call("set", value: original)?.ok == true,
              await client.call("focus")?.ok == true,
              case .ready(let session) = await executor.beginSession(cancellationToken: .init()),
              await client.call("insert", value: " 语音")?.ok == true else {
            return CancelLagResult(outcome: .targetChanged, ok: false, axSetterCount: -1, axReadCount: -1)
        }
        try? await Task.sleep(for: .milliseconds(150))
        let outcome = await executor.perform(.cancel, session: session)
        let after = await waitForValue(original, client: client)
        // The current product contract is one native Undo. AX write lag in
        // the editor must not make Cancel mutate its document through AX.
        let ok = [.undoSubmitted, .removedCurrentDictation].contains(outcome) && after?.value == original &&
            after?.submittedCount == 0 && after?.axSetterCount == 0 &&
            (after?.axReadCount ?? 0) > 0
        return CancelLagResult(
            outcome: outcome,
            ok: ok,
            axSetterCount: after?.axSetterCount ?? -1,
            axReadCount: after?.axReadCount ?? -1
        )
    }

    private static func waitForValue(_ expected: String, client: EditorClient) async -> EditorReply? {
        var last: EditorReply?
        for _ in 0..<20 {
            last = await client.call("get")
            if last?.value == expected { return last }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return last
    }

    private static func runSendFixture(
        client: EditorClient,
        executor: MacOSComposerActionExecutor,
        text: String,
        behavior: String,
        delayMs: Int? = nil,
        axStream: String = "stable"
    ) async -> SendFixtureResult {
        guard await client.call("reset")?.ok == true,
              await client.call("behavior", value: behavior, delayMs: delayMs)?.ok == true,
              await client.call("axStream", value: axStream)?.ok == true,
              await client.call("set", value: text)?.ok == true,
              await client.call("focus")?.ok == true,
              case .ready(let session) = await executor.beginSession(cancellationToken: .init()) else {
            return SendFixtureResult(outcome: .targetChanged, ok: false, ledgerCount: 0, returnDelta: 0)
        }
        let before = await client.call("get")
        let outcome = await executor.perform(.send, session: session)
        try? await Task.sleep(for: .milliseconds(delayMs.map { $0 + 250 } ?? 1_000))
        let after = await client.call("get")
        let ledgerCount = after?.submittedCount ?? -1
        let returnDelta = (after?.returnCount ?? 0) - (before?.returnCount ?? 0)
        let textAfter = after?.value ?? "<unreadable>"
        let expectedLedger = (behavior == "clear" || behavior == "keep" || behavior == "delayClear") ? [text] : []
        let ledgerMatches = after?.ledger == expectedLedger
        let ok: Bool
        switch behavior {
        case "clear":
            ok = ledgerMatches && ledgerCount == 1 && returnDelta == 1 && textAfter.isEmpty && outcome == .sent
        case "keep":
            // A retained value merits a check prompt, but the independent
            // editor ledger proves why it cannot be called definite failure.
            ok = ledgerMatches && ledgerCount == 1 && returnDelta == 1 && textAfter == text && outcome == .sendStillPresent
        case "delayClear":
            // A late target clear can follow the bounded observation window.
            // The snapshot is not a reliable message receipt either way.
            ok = ledgerMatches && ledgerCount == 1 && returnDelta == 1 && textAfter.isEmpty &&
                (outcome == .sent || outcome == .sendUnconfirmed || outcome == .sendStillPresent)
        case "newline":
            ok = ledgerMatches && ledgerCount == 0 && returnDelta == 1 && textAfter.contains("\n") && outcome == .sendStillPresent
        case "replaceFocus":
            // With readable original AX text, focus replacement alone is not
            // the nil-value transition proof. It must not become .sent.
            ok = ledgerMatches && ledgerCount == 0 && returnDelta == 1 && textAfter == text &&
                after?.focusedPrimary == false && outcome == .sendUnconfirmed
        default:
            ok = false
        }
        return SendFixtureResult(outcome: outcome, ok: ok, ledgerCount: ledgerCount, returnDelta: returnDelta)
    }
}
