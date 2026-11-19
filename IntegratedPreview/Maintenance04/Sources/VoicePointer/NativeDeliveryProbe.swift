// R15E 生产输入桥回归探针：受控编辑器输入验证，不代表物理手势/麦克风通过。
import AppKit
import CoreGraphics
import Foundation
import Darwin
@_spi(Testing) import VoicePointerCore

@MainActor
enum NativeDeliveryProbe {

    private struct CaseResult { let name: String; let pass: Bool; let detail: String }

    static func run(editorExecutable: String) async -> String {
        guard AccessibilityPermission.isTrusted else {
            return "NativeDeliveryProbe: FAIL stage=permissions(ax-not-trusted)"
        }
        guard EventAccessPermission.canPost else {
            return "NativeDeliveryProbe: FAIL stage=permissions(event-post-denied)"
        }
        let client: EditorClient
        do {
            client = try EditorClient(executable: editorExecutable)
        } catch {
            return "NativeDeliveryProbe: FAIL stage=launch(\(error))"
        }
        defer { client.shutdown() }
        do {
            let ready = try await client.readReady()
            guard ready.ok, ready.pid == client.pid else {
                return "NativeDeliveryProbe: FAIL stage=ready pid=\(ready.pid) expected=\(client.pid)"
            }
        } catch {
            return "NativeDeliveryProbe: FAIL stage=ready(\(error))"
        }
        let executor = MacOSComposerActionExecutor(testTargetPID: client.pid)
        var results: [CaseResult] = []
        results.append(await caseA(client, executor))
        results.append(await caseB(client))
        results.append(await caseC(client, executor))
        results.append(await caseD(client, executor))
        results.append(await caseE(client, executor))
        let pass = results.allSatisfy(\.pass)
        let summary = results.map { "\($0.name)=\($0.pass ? "PASS" : "FAIL")" }.joined(separator: " ")
        let detail = results.map { "\($0.name):\($0.pass ? "PASS" : "FAIL") \($0.detail)" }.joined(separator: " | ")
        return "NativeDeliveryProbe: \(pass ? "PASS" : "FAIL") \(summary) :: \(detail) :: scope=controlled-editor-input-only"
    }

    private static func begin(_ client: EditorClient,
                              _ executor: MacOSComposerActionExecutor,
                              seed: String) async throws -> (ComposerActionSession, OperationCancellationToken) {
        _ = try await client.command(op: "reset", value: seed)
        _ = try await client.command(op: "focus", value: nil)
        try await waitFrontmost(client)
        let token = OperationCancellationToken()
        let start = await executor.beginSession(cancellationToken: token)
        guard case .ready(let session) = start else {
            throw ProbeError.begin(String(describing: start))
        }
        return (session, token)
    }

    private static func waitFrontmost(_ client: EditorClient) async throws {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let r = try await client.command(op: "get", value: nil)
            if r.frontmost, r.focusedPrimary { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ProbeError.timeout("frontmost")
    }

    private static func postKey(_ code: CGKeyCode, to pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw ProbeError.keyEvent
        }
        down.flags = []
        up.flags = []
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private static func checkFocus(_ client: EditorClient) async throws {
        let st = try await client.command(op: "get", value: nil)
        guard st.frontmost, st.focusedPrimary,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == client.pid else {
            throw ProbeError.timeout("focus")
        }
    }

    private static func caseA(_ client: EditorClient,
                              _ executor: MacOSComposerActionExecutor) async -> CaseResult {
        do {
            let (session, token) = try await begin(client, executor, seed: "seed ")
            _ = try await client.command(op: "notifySame", value: nil)
            try await Task.sleep(nanoseconds: 50_000_000)
            let notifyCancelled = token.isCancelled
            let outcome = await executor.deliver(text: "abc", action: .stop, session: session)
            let st = try await client.command(op: "get", value: nil)
            let pass = !notifyCancelled && outcome == .kept && st.text == "seed abc"
            return CaseResult(name: "A", pass: pass,
                              detail: "outcome=\(outcome) len=\(st.text.count) notifyCancelled=\(notifyCancelled) note=legacy-impl-expected-fail-here")
        } catch {
            return CaseResult(name: "A", pass: false, detail: "stage=\(error)")
        }
    }

    private static func caseB(_ client: EditorClient) async -> CaseResult {
        do {
            let pre = try await client.command(op: "get", value: nil)
            guard pre.frontmost, pre.focusedPrimary, pre.text == "seed abc" else {
                throw ProbeError.timeout("caseA-state")
            }
            try await checkFocus(client)
            try postKey(51, to: client.pid)
            try await Task.sleep(nanoseconds: 100_000_000)
            var st = try await client.command(op: "get", value: nil)
            guard st.text == "seed ab" else {
                return CaseResult(name: "B", pass: false, detail: "afterBackspaceLen=\(st.text.count)")
            }
            try await checkFocus(client)
            try postKey(7, to: client.pid)
            try await Task.sleep(nanoseconds: 100_000_000)
            st = try await client.command(op: "get", value: nil)
            let pass = st.text == "seed abx"
            return CaseResult(name: "B", pass: pass,
                              detail: "len=\(st.text.count) note=same-path-edit-after-paste-not-full-physical-keyboard")
        } catch {
            return CaseResult(name: "B", pass: false, detail: "stage=\(error)")
        }
    }

    private static func caseC(_ client: EditorClient,
                              _ executor: MacOSComposerActionExecutor) async -> CaseResult {
        do {
            let (session, _) = try await begin(client, executor, seed: "base ")
            let outcome = await executor.deliver(text: "tail", action: .cancel, session: session)
            try await Task.sleep(nanoseconds: 150_000_000)
            let st = try await client.command(op: "get", value: nil)
            // A down-swipe never writes: nothing is pasted, so there is nothing to undo either.
            let pass = outcome == .removedCurrentDictation && st.text == "base " && st.undoCount == 0
            return CaseResult(name: "C", pass: pass,
                              detail: "outcome=\(outcome) len=\(st.text.count) undoCount=\(st.undoCount)")
        } catch {
            return CaseResult(name: "C", pass: false, detail: "stage=\(error)")
        }
    }

    private static func caseD(_ client: EditorClient,
                              _ executor: MacOSComposerActionExecutor) async -> CaseResult {
        do {
            let (session, _) = try await begin(client, executor, seed: "send ")
            let first = await executor.deliver(text: "once", action: .send, session: session)
            var st = try await client.command(op: "get", value: nil)
            let firstOk = first == .sent && st.returnCount == 1 && st.text.isEmpty
            _ = await executor.deliver(text: "once", action: .send, session: session)
            st = try await client.command(op: "get", value: nil)
            let pass = firstOk && st.returnCount == 1
            return CaseResult(name: "D", pass: pass,
                              detail: "outcome=\(first) returnCount=\(st.returnCount) len=\(st.text.count)")
        } catch {
            return CaseResult(name: "D", pass: false, detail: "stage=\(error)")
        }
    }

    private static func caseE(_ client: EditorClient,
                              _ executor: MacOSComposerActionExecutor) async -> CaseResult {
        do {
            let (session, token) = try await begin(client, executor, seed: "safe ")
            _ = try await client.command(op: "otherFocus", value: nil)
            _ = try await client.command(op: "focus", value: nil)
            try await waitFrontmost(client)
            try await Task.sleep(nanoseconds: 50_000_000)
            let cancelled = token.isCancelled
            let outcome = await executor.deliver(text: "x", action: .stop, session: session)
            let st = try await client.command(op: "get", value: nil)
            let pass = cancelled && st.text == "safe " && st.otherText.isEmpty && st.frontmost
            return CaseResult(name: "E", pass: pass,
                              detail: "cancelled=\(cancelled) outcome=\(outcome) mainLen=\(st.text.count) otherLen=\(st.otherText.count) frontmost=\(st.frontmost)")
        } catch {
            return CaseResult(name: "E", pass: false, detail: "stage=\(error)")
        }
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case begin(String)
    case timeout(String)
    case editorDead
    case keyEvent
    case protocolErr(String)

    var description: String {
        switch self {
        case .begin(let s): return "begin(\(s))"
        case .timeout(let s): return "timeout(\(s))"
        case .editorDead: return "editor-dead"
        case .keyEvent: return "key-event"
        case .protocolErr(let s): return "protocol(\(s))"
        }
    }
}

// 子进程 JSON 客户端：串行队列仅负责读写 JSON；@unchecked Sendable，状态由队列保护。
private final class EditorClient: @unchecked Sendable {
    struct R: Codable, Sendable {
        let id: Int
        let ok: Bool
        let pid: Int
        let text: String
        let otherText: String
        let returnCount: Int
        let undoCount: Int
        let frontmost: Bool
        let focusedPrimary: Bool
    }
    private struct Cmd: Codable { let id: Int; let op: String; let value: String? }

    let process = Process()
    let pid: pid_t
    private let io = DispatchQueue(label: "r15.editor.io")
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var buffer = Data()
    private var nextId = 1
    private var alive = true

    init(executable: String) throws {
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        pid = process.processIdentifier
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
    }

    // async 版本：读写仍在串行 io 队列上按序执行，但用 continuation 挂起 MainActor，
    // 不再用 io.sync 阻塞 MainActor（否则会卡住 AX 通知与 timer）。
    func readReady() async throws -> R {
        let io = self.io
        return try await withCheckedThrowingContinuation { cont in
            io.async {
                do {
                    let line = try self.readLineLocked()
                    guard let r = try? JSONDecoder().decode(R.self, from: line), r.id == 0 else {
                        throw ProbeError.protocolErr("ready")
                    }
                    cont.resume(returning: r)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func command(op: String, value: String?) async throws -> R {
        let io = self.io
        return try await withCheckedThrowingContinuation { cont in
            io.async {
                do {
                    guard self.alive else { throw ProbeError.editorDead }
                    let id = self.nextId
                    self.nextId += 1
                    let data = try JSONEncoder().encode(Cmd(id: id, op: op, value: value)) + Data("\n".utf8)
                    try self.stdin.write(contentsOf: data)
                    let line = try self.readLineLocked()
                    guard let r = try? JSONDecoder().decode(R.self, from: line),
                          r.id == id, r.pid == Int(self.pid), r.ok else {
                        throw ProbeError.protocolErr("reply")
                    }
                    cont.resume(returning: r)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func shutdown() {
        io.async {
            self.alive = false
            try? self.stdin.close()
            if self.process.isRunning { self.process.terminate() }
        }
    }

    private func readLineLocked() throws -> Data {
        while true {
            if let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<idx])
                buffer.removeSubrange(buffer.startIndex...idx)
                return line
            }
            guard buffer.count <= 65536 else {
                throw ProbeError.editorDead
            }
            buffer.append(try readChunkLocked())
        }
    }

    private func readChunkLocked() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = try chunk.withUnsafeMutableBytes { raw -> Int in
            while true {
                let bytesRead = Darwin.read(stdout.fileDescriptor, raw.baseAddress, 65536)
                if bytesRead >= 0 { return bytesRead }
                if errno == EINTR { continue }
                throw ProbeError.editorDead
            }
        }
        guard n > 0 else { throw ProbeError.editorDead }
        return Data(chunk[0..<n])
    }
}
