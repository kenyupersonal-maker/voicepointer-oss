import AppKit
import ApplicationServices
import Foundation
@_spi(Testing) import VoicePointerCore

/// R0: the production executor with synthetic I/O, never a rewritten route decision.
@MainActor
enum ComposerReplayChecks {
    struct Row { let number: Int; let passed: Bool; let caret: Int; let writes: Int }
    private final class Editor: ComposerReplayIO, @unchecked Sendable {
        var bundleIdentifier: String
        let chromium: Bool
        let clipboard: ClipboardTransfer
        let runtime: InlineWriteRuntime
        let board: NSPasteboard
        let defaults: UserDefaults
        let domain: String
        var content: String
        var tail: String
        var selection: NSRange
        var pastes = 0, values = 0, probes = 0, deletes = 0, undos = 0, returns = 0
        var shortSelectAllBy = 0 // Synthetic partial Cmd-A for the clear fail-closed replay.
        var returnPostedAt: TimeInterval?
        var firstReturnPostedAt: TimeInterval?
        var replayFocusMoved = false // Synthetic AX focus change, never a user window.
        var systemSecureInput = false
        var secureField = false, secureReads = 0, secureWrites = 0
        var postReturnFocus: String?
        var nilValueReadOnce = false, nilValueReadCount = 0 // One fake AX nil read, not a real target.
        var swallowNextReturn = false
        var appendLineBreakOnReturn = false
        var replayHasFocusedElement = true, replayEditable = true
        var replayRole: String? = "AXTextArea"
        var replaySubrole: String?
        var keyEvents = 0, selectionWrites = 0
        @MainActor init(_ content: String, selection: NSRange? = nil, native: Bool = false, phantom: Bool = false,
                        bundleIdentifierOverride: String? = nil) {
            self.content = content; tail = native ? "" : (phantom ? "\n" : "\n\n\u{fffc}")
            self.selection = selection ?? NSRange(location: content.utf16.count, length: 0)
            chromium = !native; bundleIdentifier = bundleIdentifierOverride ??
                (native ? "com.tencent.xinWeChat" : "com.anthropic.claudefordesktop")
            domain = "VoicePointerReplay." + UUID().uuidString
            board = NSPasteboard(name: .init(domain)); defaults = UserDefaults(suiteName: domain)!
            clipboard = ClipboardTransfer(pasteboard: board); runtime = InlineWriteRuntime(defaults: defaults)
            _ = board.clearContents(); _ = board.setString("synthetic original clipboard", forType: .string)
        }
        @MainActor func dispose() { board.releaseGlobally(); defaults.removePersistentDomain(forName: domain) }
        var writes: Int { pastes + values + probes + deletes + secureWrites }
        var value: String { content + tail }
        func read(_ attribute: String) -> CFTypeRef? {
            if secureField, [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute,
                             "AXNumberOfCharacters"].contains(attribute) {
                secureReads += 1
                return nil
            }
            switch attribute {
            case "ReplayNoFocusedElement": return NSNumber(value: !replayHasFocusedElement)
            case "ReplayRoleUnreadable": return NSNumber(value: replayRole == nil)
            case kAXRoleAttribute: return replayRole.map { $0 as CFString }
            case kAXSubroleAttribute:
                return secureField ? "AXSecureTextField" as CFString : replaySubrole.map { $0 as CFString }
            case "AXEditable": return NSNumber(value: replayEditable)
            case "ReplayFocusMovedBeforeReturn": return NSNumber(value: replayFocusMoved)
            case "ReplaySystemSecureInput": return NSNumber(value: systemSecureInput)
            case "ReplayPostReturnFocus": return postReturnFocus.map { $0 as CFString }
            case kAXValueAttribute:
                if nilValueReadOnce { nilValueReadOnce = false; nilValueReadCount += 1; return nil }
                return value as CFString
            case "AXNumberOfCharacters": return NSNumber(value: value.utf16.count)
            case "AXValueSettable": return NSNumber(value: !chromium)
            case kAXSelectedTextAttribute:
                guard NSMaxRange(selection) <= content.utf16.count else { return nil }
                return (content as NSString).substring(with: selection) as CFString
            case kAXSelectedTextRangeAttribute:
                var range = CFRange(location: selection.location, length: selection.length)
                return AXValueCreate(.cfRange, &range)
            default: return nil
            }
        }
        func select(_ range: NSRange) -> Bool {
            selectionWrites += 1
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= content.utf16.count else { return false }
            selection = range; return true
        }
        func typeSecureText(_ text: String) -> Bool {
            guard secureField, NSMaxRange(selection) <= content.utf16.count else { return false }
            content = (content as NSString).replacingCharacters(in: selection, with: text)
            selection = NSRange(location: selection.location + text.utf16.count, length: 0)
            secureWrites += 1
            return true
        }
        func write(_ attribute: String, value: String) -> ComposerAXWriteResult {
            if attribute == kAXSelectedTextAttribute { probes += 1; return .submitted } // Known no-op AX setter.
            guard attribute == kAXValueAttribute, !chromium else { return .unavailable }
            content = value; values += 1; return .submitted
        }
        func key(_ code: UInt16, flags: UInt64) -> Bool {
            keyEvents += 1
            if code == 36 {
                returnPostedAt = ProcessInfo.processInfo.systemUptime
                if firstReturnPostedAt == nil { firstReturnPostedAt = returnPostedAt }
                returns += 1
                if swallowNextReturn { swallowNextReturn = false; return true }
                if appendLineBreakOnReturn {
                    content += "\n"
                    selection = NSRange(location: content.utf16.count, length: 0)
                    return true
                }
                content = ""; tail = chromium ? "\n" : ""
                selection = NSRange(location: 0, length: 0)
                return true
            }
            if code == 6, flags & CGEventFlags.maskCommand.rawValue != 0 { undos += 1; return true }
            if code == 0, flags & CGEventFlags.maskCommand.rawValue != 0 {
                selection = NSRange(location: 0, length: max(0, content.utf16.count - shortSelectAllBy))
                return true
            }
            var range = selection, replacement = ""
            if code == 9, flags & CGEventFlags.maskCommand.rawValue != 0 {
                // This is the real ClipboardTransfer payload on a disposable named board.
                replacement = board.string(forType: .string) ?? ""; pastes += 1
            } else if code == 51 {
                deletes += 1
                if range.length == 0, range.location > 0 { range = NSRange(location: range.location - 1, length: 1) }
            } else { return false }
            guard NSMaxRange(range) <= content.utf16.count else { return false }
            content = (content as NSString).replacingCharacters(in: range, with: replacement)
            selection = NSRange(location: range.location + replacement.utf16.count, length: 0)
            return true
        }
    }
    private final class Focus: FocusProviding, @unchecked Sendable {
        func snapshot(at: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? { nil }
        func setFocused(candidateIdentifier: String) -> Bool { false }
        func isFocused(candidateIdentifier: String) -> Bool { false }
        func synthesizeClick(candidateIdentifier: String) -> Bool { false }
    }
    private final class Backend: SpeechInputBackend, SpeechCaptureActivityProviding, HybridSessionControlling {
        let capabilities = SpeechInputCapabilities(deliveryKind: .transcriptStream, supportsPartialText: true, supportsHints: false)
        var isQuiescent = true
        var hasAcceptedCaptureAudio = true
        var startCount = 0, finishCount = 0
        var holdFinish = false, finishing = false
        private var finishWaiter: CheckedContinuation<Void, Never>?
        private var snapshot: VoiceInputSnapshot?
        private var receiver: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
        private var sequence: UInt64 = 0
        var hotwordCount: Int { snapshot?.localHotwords.count ?? 0 }
        func start(snapshot: VoiceInputSnapshot, onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void) async throws {
            startCount += 1
            self.snapshot = snapshot; receiver = onEvent; isQuiescent = false; emit(.ready)
        }
        func emit(_ kind: SpeechInputEvent.Kind, text: String = "") {
            guard let snapshot else { return }; sequence += 1
            receiver?(.init(sessionID: snapshot.sessionID, sequence: sequence, observedMilliseconds: Double(sequence), kind: kind,
                            text: text, transcriptSource: .local))
        }
        func finish() async {
            finishCount += 1; finishing = true
            if holdFinish { await withCheckedContinuation { finishWaiter = $0 } }
            emit(.final); isQuiescent = true
        }
        func unblockFinish() {
            holdFinish = false
            let waiter = finishWaiter; finishWaiter = nil; waiter?.resume()
        }
        func cancel() async { isQuiescent = true }
        func noteReleaseAction(_ action: VoiceReleaseAction) {}
        func revokeCloud(reason: HybridFinalSelector.CloudEnd) {}
    }
    // 0.5.65 A: deterministic policy adapter, no CoreAudio properties or real output writes.
    @MainActor private final class DuckClock: OutputDuckingScheduling {
        struct Job {
            let at: TimeInterval
            let order: Int
            let action: @MainActor () -> Void
        }
        var now: TimeInterval = 0
        var wallTime: TimeInterval { 1_700_000_000 + now }
        private var jobs: [Job] = []
        private var ordinal = 0
        func after(seconds: TimeInterval, perform: @escaping @MainActor () -> Void) {
            ordinal += 1
            jobs.append(.init(at: now + max(0, seconds), order: ordinal, action: perform))
        }
        func advance(_ seconds: TimeInterval) {
            let until = now + max(0, seconds)
            while true {
                jobs.sort { $0.at == $1.at ? $0.order < $1.order : $0.at < $1.at }
                guard let job = jobs.first, job.at <= until else { break }
                jobs.removeFirst()
                now = job.at
                job.action()
            }
            now = until
        }
    }
    @MainActor private final class DuckDevice: OutputDuckingDevice {
        let uid: String
        let transport: OutputDuckingTransport
        let control: OutputDuckingControl
        let canMute: Bool
        var isConnected = true
        var state: OutputDuckingReading
        var writes = 0
        var reads = 0
        var effective = true
        var acceptsWrite = true
        init(_ uid: String, levels: [Double] = [0.5], muted: Bool = false,
             transport: OutputDuckingTransport = .builtin,
             control: OutputDuckingControl = .virtualMain, canMute: Bool = true) {
            self.uid = uid; self.transport = transport; self.control = control; self.canMute = canMute
            state = .init(levels: control == .mute || control == .none ? [] : levels, muted: muted)
        }
        func read() -> OutputDuckingReading? {
            reads += 1
            return isConnected ? state : nil
        }
        func write(_ newValue: OutputDuckingReading) -> Bool {
            writes += 1
            guard isConnected, acceptsWrite else { return false }
            if effective { state = newValue }
            return true
        }
    }
    @MainActor private final class DuckEvidence {
        var logs: [String] = []
        var recovery: OutputDuckingRecoveryRecord?
        var notices = 0
    }
    private static func duckPolicy(_ clock: DuckClock, _ evidence: DuckEvidence) -> OutputDuckingPolicy {
        OutputDuckingPolicy(scheduler: clock, trace: { evidence.logs.append($0) },
                            persist: { evidence.recovery = $0 }, unsupported: { evidence.notices += 1 })
    }
    private static func duckNear(_ actual: Double, _ target: Double) -> Bool {
        abs(actual - target) <= 0.021
    }

    private static func begin(_ executor: MacOSComposerActionExecutor) async -> ComposerActionSession? {
        if case .ready(let session) = await executor.beginSession(cancellationToken: .init()) { return session }
        return nil
    }
    private static func sentence(_ executor: MacOSComposerActionExecutor, editor: Editor, number: Int,
                                 count: Int = 8, action: VoiceReleaseAction = .stop) async -> (Bool, ComposerActionOutcome) {
        guard let session = await begin(executor) else { return (false, .deliveryFailed) }
        let before = editor.content
        var ok = true, latest = ""
        for index in 1...count {
            latest = " " + (index >= 5 ? "blue" : "red") + " " + String(repeating: "word ", count: index) + "end\(number)"
            let update = await executor.updateDraft(text: latest, sequence: UInt64(index), session: session)
            ok = ok && update == .updated
        }
        let outcome = await executor.deliver(text: latest, action: action, session: session)
        return (ok && (action != .stop || editor.content == before + latest), outcome)
    }
    /// Only the four A measurements, used after a narrow 1ms timing miss.
    private static func r67FastRows() async -> [Row] {
        var result: [Row] = []
        let peaks: [Float?] = [0.003, 0.05, 0.39, nil]
        for (index, peak) in peaks.enumerated() {
            let editor = Editor("R67 existing fixture", native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            if let peak { GestureSpeechActivity.shared.recordCapture(peakLevel: peak) }
            let token = await begin(executor)
            let start = ProcessInfo.processInfo.systemUptime
            let outcome = await executor.perform(.send, session: token)
            let ms = editor.returnPostedAt.map { Int(($0 - start) * 1000) } ?? -1
            let feedback = ComposerActionFeedback(outcome: outcome, action: .send)
            result.append(.init(
                number: 26 + index,
                passed: outcome == .sent && editor.returns == 1 &&
                    ms >= 500 && ms <= 650 && !feedback.shouldPresent,
                caret: editor.selection.location, writes: editor.writes
            ))
            print("REPLAY_R67_A case=\(index) elapsedMs=\(ms) returns=\(editor.returns)")
        }
        return result
    }

    static func runR67FastOnly() async -> [String] {
        let rows = await r67FastRows()
        let failed = rows.filter { !$0.passed }
        print("R67_FAST_ONLY passed=\(rows.count - failed.count) total=\(rows.count) failed=\(failed.map(\.number)) synthetic=1")
        return failed.map { "replay case \($0.number)" }
    }

    private static func r67EmptyRows() async -> [Row] {
        var result: [Row] = []
        for (index, landingMs) in [2_200 as Int?, nil].enumerated() {
            let editor = Editor("", native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.06)
            let token = await begin(executor), start = ProcessInfo.processInfo.systemUptime
            let landing: Task<Void, Never>? = landingMs.map { delay in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(delay))
                    editor.content += " R67 synthetic committed"
                }
            }
            let outcome = await executor.perform(.send, session: token)
            if let landing { _ = await landing.value }
            let ms = editor.returnPostedAt.map { Int(($0 - start) * 1000) } ?? -1
            let feedback = ComposerActionFeedback(outcome: outcome, action: .send)
            let ok = index == 0
                ? outcome == .sent && editor.returns == 1 && ms >= 2_350 && ms <= 3_800
                : outcome == .doubaoTextTimeout && editor.returns == 0 && feedback.shouldPresent
            result.append(.init(number: 31 + index, passed: ok,
                                caret: editor.selection.location, writes: editor.writes))
            print("REPLAY_R67_C case=\(index) elapsedMs=\(ms) returns=\(editor.returns)")
        }
        return result
    }


    /// R673: five synthetic branches; all Return actions are intercepted by Editor.
    private static func r673EmptyRows() async -> [Row] {
        var rows: [Row] = []
        let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cache/tmp", isDirectory: true)
            .appendingPathComponent("ComposerReplay-R673-\(UUID().uuidString).log")
        RuntimeTrace.configureForTesting(fileURL: logURL)
        func loggedDecision(_ payload: String) -> Bool {
            RuntimeTrace.flush()
            guard let log = try? String(contentsOf: logURL, encoding: .utf8),
                  let line = log.split(separator: "\n").last(where: { $0.contains("doubao send decision=") }),
                  let range = line.range(of: "doubao send decision=") else { return false }
            return line[range.lowerBound...] == "doubao send decision=" + payload
        }
        func record(_ number: Int, _ ok: Bool, _ editor: Editor, _ ms: Int) {
            rows.append(.init(number: number, passed: ok, caret: editor.selection.location, writes: editor.writes))
            print("REPLAY_R673 number=\(number) pass=\(ok ? 1 : 0) returnMs=\(ms) returns=\(editor.returns) nilReads=\(editor.nilValueReadCount)")
        }
        // 39/40: actual 600ms decision for Codex empty AXValue and Claude phantom newline.
        for (number, phantom) in [(39, false), (40, true)] {
            let editor = Editor("", phantom: phantom,
                bundleIdentifierOverride: phantom ? "com.anthropic.claudefordesktop" : "com.openai.codex")
            if !phantom { editor.tail = "" }
            defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.003)
            let selected = DoubaoExternalSendPolicy.decide(
                original: editor.value, firstAfterRelease: editor.value,
                originalWasEmpty: true, firstIsEmpty: true, heard: .silence
            )
            let session = await begin(executor)
            let start = ProcessInfo.processInfo.systemUptime
            let outcome = await executor.perform(.send, session: session)
            let ms = editor.firstReturnPostedAt.map { Int(($0 - start) * 1_000) } ?? -1
            let ok = selected == .emptyUnchanged &&
                loggedDecision("emptyUnchanged originalEmpty=1 firstEmpty=1 heard=silence") && editor.returns == 1 &&
                ms >= 500 && ms <= 850 && outcome != .nothingToSend &&
                outcome != .doubaoTextTimeout && outcome != .dictationNotSettled
            record(number, ok, editor, ms)
        }
        // 41: finish the real timeout, then begin a new gesture on the same target.
        // Its silent release consumes the one-shot receipt; new speech still waits.
        do {
            let editor = Editor("", native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.08)
            let selected = DoubaoExternalSendPolicy.decide(
                original: "", firstAfterRelease: "",
                originalWasEmpty: true, firstIsEmpty: true, heard: .speech
            )
            let firstStarted = ProcessInfo.processInfo.systemUptime
            let outcome = await executor.perform(.send, session: await begin(executor))
            let timeoutMs = Int((ProcessInfo.processInfo.systemUptime - firstStarted) * 1_000)
            let feedback = ComposerActionFeedback(outcome: outcome, action: .send)
            let timedOut = selected == .waitForSpeechText &&
                outcome == .doubaoTextTimeout && editor.returns == 0 &&
                timeoutMs >= 2_950 && timeoutMs <= 3_600 &&
                loggedDecision("waitForSpeechText originalEmpty=1 firstEmpty=1 heard=speech") &&
                feedback.message == "豆包没出字，没发送，再推一下直接发" && feedback.shouldPresent

            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.003)
            let secondToken = await begin(executor)
            let started = ProcessInfo.processInfo.systemUptime
            let secondOutcome = await executor.perform(.send, session: secondToken)
            let ms = editor.firstReturnPostedAt.map { Int(($0 - started) * 1_000) } ?? -1
            let expedited = editor.returns == 1 && ms >= 0 && ms <= 200 &&
                secondToken?.requestExpeditedSend() == false && secondOutcome != .doubaoTextTimeout &&
                secondOutcome != .nothingToSend

            // Re-arm through the real timeout; a fresh spoken gesture must not
            // consume that receipt or skip the original first-landing/quiet wait.
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.08)
            let rearmed = await executor.perform(.send, session: await begin(executor))
            let returnsBeforeSpeech = editor.returns
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.08)
            let spokenToken = await begin(executor), spokenStart = ProcessInfo.processInfo.systemUptime
            let landing = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1_000))
                editor.content = "synthetic new speech"
                editor.selection = NSRange(location: editor.content.utf16.count, length: 0)
            }
            let spokenOutcome = await executor.perform(.send, session: spokenToken)
            _ = await landing.value
            let spokenMs = editor.returnPostedAt.map { Int(($0 - spokenStart) * 1_000) } ?? -1
            let speechProtected = rearmed == .doubaoTextTimeout && returnsBeforeSpeech == 1 &&
                spokenOutcome == .sent && editor.returns == 2 && spokenMs >= 1_200 && spokenMs <= 2_300
            print("REPLAY_R673_RETRY timeoutMs=\(timeoutMs) retryMs=\(ms) retryReturns=\(expedited ? 1 : 0) newSpeechMs=\(spokenMs) newSpeechProtected=\(speechProtected ? 1 : 0)")
            record(41, timedOut && expedited && speechProtected, editor, ms)
        }
        // 42: speech text arrives after 1.0s, keeps the original conservative settle timing.
        do {
            let editor = Editor("", native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.08)
            let decision = DoubaoExternalSendPolicy.decide(
                original: "", firstAfterRelease: "",
                originalWasEmpty: true, firstIsEmpty: true, heard: .speech
            )
            let session = await begin(executor), start = ProcessInfo.processInfo.systemUptime
            let landing = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1_000))
                editor.content += " synthetic R673 landed"
                editor.selection = NSRange(location: editor.content.utf16.count, length: 0)
            }
            let outcome = await executor.perform(.send, session: session)
            _ = await landing.value
            let ms = editor.firstReturnPostedAt.map { Int(($0 - start) * 1_000) } ?? -1
            record(42, decision == .waitForSpeechText &&
                   loggedDecision("waitForSpeechText originalEmpty=1 firstEmpty=1 heard=speech") && outcome == .sent &&
                   editor.returns == 1 && ms >= 1_200 && ms <= 2_300, editor, ms)
        }
        // 43: the fake AX reader returns nil once after V1; it is not a changed editor.
        do {
            let editor = Editor("", native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture() // Unknown activity: no fake audio captured.
            let decision = DoubaoExternalSendPolicy.decide(
                original: "", firstAfterRelease: "",
                originalWasEmpty: true, firstIsEmpty: true, heard: .unknown
            )
            let session = await begin(executor), start = ProcessInfo.processInfo.systemUptime
            let nilSample = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                editor.nilValueReadOnce = true
            }
            let outcome = await executor.perform(.send, session: session)
            _ = await nilSample.value
            let ms = editor.firstReturnPostedAt.map { Int(($0 - start) * 1_000) } ?? -1
            record(43, decision == .emptyUnchanged &&
                   loggedDecision("emptyUnchanged originalEmpty=1 firstEmpty=1 heard=unknown") && editor.nilValueReadCount == 1 &&
                   editor.returns == 1 && ms >= 500 && ms <= 850 &&
                   outcome != .nothingToSend && outcome != .doubaoTextTimeout &&
                   outcome != .dictationNotSettled, editor, ms)
        }
        return rows
    }

    /// F5 exercises the real acquisition worker, coordinator and presentation gate.
    /// The frontmost app, AX attributes and all possible key writes are synthetic.
    private static func noTargetHintRows() async -> [Row] {
        var rows: [Row] = []
        let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cache/tmp", isDirectory: true)
            .appendingPathComponent("ComposerReplay-F5-\(UUID().uuidString).log")
        RuntimeTrace.configureForTesting(fileURL: logURL)
        let selection = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "zh")
        let activation = GestureActivation(location: .init(x: 20, y: 20), button: .left,
            match: .init(deviceToken: 1, deviceKind: .magicMouse, touchCount: 2,
                         newestTouchAgeSeconds: 0.01, maximumMovement: 0.001))
        let expected = VoiceIssuePresentationPolicy.resolve(code: .sendNoTarget, stage: .send, safeAction: .refocusInput)
        @MainActor func loggedHints() -> [String] {
            RuntimeTrace.flush()
            guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
            return log.split(separator: "\n").compactMap { line in
                guard let range = line.range(of: "composer send noTarget ") else { return nil }
                return String(line[range.lowerBound...])
            }
        }
        @MainActor func wait(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<300 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return condition()
        }
        @MainActor func start(_ coordinator: VoicePointerCoordinator) async -> Bool {
            guard coordinator.gestureBegan(activation, settings: VoicePointerSettings(), selection: selection) else { return false }
            return await wait { coordinator.status == .listening }
        }
        @MainActor func record(_ number: Int, _ passed: Bool, _ editor: Editor) {
            let untouched = editor.writes == 0 && editor.keyEvents == 0 && editor.selectionWrites == 0
            rows.append(.init(number: number, passed: passed && untouched, caret: editor.selection.location, writes: editor.writes))
            print("REPLAY_F5 number=\(number) pass=\(passed && untouched ? 1 : 0) keys=\(editor.keyEvents) writes=\(editor.writes)")
        }
        // 44: an explicit send gets exactly the shared hint, without entering an editor action.
        do {
            let editor = Editor("", native: true, bundleIdentifierOverride: "com.example.F5A")
            defer { editor.dispose() }
            editor.replayEditable = false; editor.replayRole = "AXButton"
            let backend = Backend(), executor = MacOSComposerActionExecutor(testReplayIO: editor)
            var hints = 0, outcomes = 0, records = 0
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: executor,
                outcomeHandler: { _, _, _ in outcomes += 1 },
                statusHandler: { status, _ in if status == .failed(expected.message) { hints += 1 } },
                dictationHandler: { _ in records += 1 })
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            let began = await start(coordinator), before = loggedHints().count
            await coordinator.gestureEnded(action: .send)
            record(56, began && expected.message == "没找到输入框" && hints == 1 && outcomes == 0 && records == 0 && backend.finishCount == 1 && backend.isQuiescent &&
                   coordinator.lastIssuePresentation == expected && loggedHints().count == before + 1 &&
                   loggedHints().last == "composer send noTarget reason=notEditable app=com.example.F5A focusedRole=AXButton focusedSubrole=unknown hint=shown", editor)
            await coordinator.applicationWillTerminate()
        }
        // 45: stopping or swiping down still has no hint, outcome, delivery or key event.
        do {
            let editor = Editor("", native: true); defer { editor.dispose() }
            editor.replayEditable = false
            var ok = true
            for action in [VoiceReleaseAction.stop, .cancel] {
                let backend = Backend(), executor = MacOSComposerActionExecutor(testReplayIO: editor)
                var outcomes = 0, records = 0
                let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: executor,
                    outcomeHandler: { _, _, _ in outcomes += 1 }, dictationHandler: { _ in records += 1 })
                coordinator.setSpeechBackendFactoryForTesting { _ in backend }
                let began = await start(coordinator), before = loggedHints().count
                await coordinator.gestureEnded(action: action)
                ok = ok && began && coordinator.status == .idle && coordinator.lastIssuePresentation == nil &&
                    outcomes == 0 && records == 0 && backend.finishCount == 1 && backend.isQuiescent && loggedHints().count == before
                await coordinator.applicationWillTerminate()
            }
            record(57, ok, editor)
        }
        // 46: capture in A, then switch the synthetic frontmost app to B before releasing.
        // The first hint belongs to A; B can show immediately on its own next gesture.
        do {
            let editor = Editor("", native: true, bundleIdentifierOverride: "com.example.F5A")
            defer { editor.dispose() }
            editor.replayEditable = false
            let backend = Backend(), executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: executor)
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            let first = await start(coordinator), before = loggedHints().count
            editor.bundleIdentifier = "com.example.F5B"
            await coordinator.gestureEnded(action: .send)
            let firstLog = loggedHints().last ?? ""
            let second = await start(coordinator)
            await coordinator.gestureEnded(action: .send)
            let secondLog = loggedHints().last ?? ""
            record(58, first && second && loggedHints().count == before + 2 &&
                   firstLog.contains(" app=com.example.F5A ") && firstLog.hasSuffix("hint=shown") &&
                   secondLog.contains(" app=com.example.F5B ") && secondLog.hasSuffix("hint=shown") &&
                   backend.startCount == 2 && backend.finishCount == 2, editor)
            await coordinator.applicationWillTerminate()
        }
        // 47: read only role/subrole on the same focused proxy; nil and non-type strings are unknown.
        do {
            let editor = Editor("", native: true); defer { editor.dispose() }
            editor.replayEditable = false
            let cases: [(Bool, String?, String?, String, String)] = [
                (true, "AXGroup", "AXContentList", "AXGroup", "AXContentList"),
                (false, "AXGroup", nil, "none", "none"),
                (true, nil, nil, "unknown", "unknown"),
                (true, "synthetic_non_type", "synthetic_non_type", "unknown", "unknown")
            ]
            var ok = true
            for (hasFocus, role, subrole, expectedRole, expectedSubrole) in cases {
                editor.replayHasFocusedElement = hasFocus; editor.replayRole = role; editor.replaySubrole = subrole
                let backend = Backend(), executor = MacOSComposerActionExecutor(testReplayIO: editor)
                let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: executor)
                coordinator.setSpeechBackendFactoryForTesting { _ in backend }
                let began = await start(coordinator), before = loggedHints().count
                await coordinator.gestureEnded(action: .send)
                let line = loggedHints().last ?? ""
                ok = ok && began && loggedHints().count == before + 1 &&
                    line.contains("reason=\(hasFocus ? "notEditable" : "noFocusedElement") ") &&
                    line.contains("focusedRole=\(expectedRole) focusedSubrole=\(expectedSubrole) hint=shown") &&
                    !line.contains("synthetic_non_type")
                await coordinator.applicationWillTerminate()
            }
            record(59, ok, editor)
        }
        // 48: an old blocked finish resumes only after a new, editable session is listening.
        do {
            let editor = Editor("", native: true); defer { editor.dispose() }
            editor.replayEditable = false
            let old = Backend(), next = Backend(), executor = MacOSComposerActionExecutor(testReplayIO: editor)
            old.holdFinish = true
            var builds = 0, hints = 0
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: executor,
                statusHandler: { status, _ in if status == .failed(expected.message) { hints += 1 } })
            coordinator.setSpeechBackendFactoryForTesting { _ in builds += 1; return builds == 1 ? old : next }
            let first = await start(coordinator), before = loggedHints().count
            let pending = Task { @MainActor in await coordinator.gestureEnded(action: .send) }
            let held = await wait { old.finishing }
            await coordinator.cancel()
            editor.replayEditable = true
            let second = await start(coordinator), newSession = coordinator.currentSessionID
            old.unblockFinish(); await pending.value
            record(60, first && held && second && newSession != nil && coordinator.currentSessionID == newSession &&
                   coordinator.status == .listening && coordinator.lastIssuePresentation == nil && hints == 0 &&
                   loggedHints().count == before && next.startCount == 1, editor)
            await coordinator.applicationWillTerminate()
        }
        // 49: throttling is per acquisition app and only changes presentation; every gesture finishes.
        do {
            let editor = Editor("", native: true, bundleIdentifierOverride: "com.example.F5A")
            defer { editor.dispose() }
            editor.replayEditable = false
            let backend = Backend(), executor = MacOSComposerActionExecutor(testReplayIO: editor)
            var hints = 0
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: executor,
                statusHandler: { status, _ in if status == .failed(expected.message) { hints += 1 } })
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            let first = await start(coordinator), before = loggedHints().count
            await coordinator.gestureEnded(action: .send)
            let second = await start(coordinator)
            await coordinator.gestureEnded(action: .send)
            let quietSecond = coordinator.status == .idle && hints == 1 && backend.finishCount == 2 && backend.isQuiescent
            let secondLog = loggedHints().last ?? ""
            editor.bundleIdentifier = "com.example.F5B"
            let third = await start(coordinator)
            await coordinator.gestureEnded(action: .send)
            let lines = Array(loggedHints().dropFirst(before))
            var gate = VoiceIssuePresentationGate()
            let initial = gate.shouldPresent(expected, sessionID: UUID(), monotonicTime: 100)
            let blocked = !gate.shouldPresent(expected, sessionID: UUID(), monotonicTime: 109.9)
            let expired = gate.shouldPresent(expected, sessionID: UUID(), monotonicTime: 110)
            record(61, first && second && third && quietSecond && hints == 2 &&
                   backend.startCount == 3 && backend.finishCount == 3 && lines.count == 3 &&
                   lines.first?.hasSuffix("hint=shown") == true && secondLog.hasSuffix("hint=throttled") &&
                   lines.last?.contains("app=com.example.F5B ") == true && lines.last?.hasSuffix("hint=shown") == true &&
                   initial && blocked && expired, editor)
            await coordinator.applicationWillTerminate()
        }
        return rows
    }

    static func runR67EmptyOnly() async -> [String] {
        let rows = await r67EmptyRows()
        let failed = rows.filter { !$0.passed }
        print("R67_EMPTY_ONLY passed=\(rows.count - failed.count) total=\(rows.count) failed=\(failed.map(\.number)) synthetic=1")
        return failed.map { "replay case \($0.number)" }
    }

    /// Isolated synthetic editor replay: no real AX target, microphone or user clipboard.
    static func runClearSwipeOnly() async -> [String] {
        var failures: [String] = []
        for (caseNumber, native) in [(1, true), (2, false)] {
            let editor = Editor("R67 synthetic existing text", native: native)
            defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.008)
            let first = await executor.perform(.cancel, session: await begin(executor))
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.008)
            let second = await executor.perform(.cancel, session: await begin(executor))
            let passed = first == .clearArmed && second == .clearedCurrentInput
                && editor.content.isEmpty && editor.deletes == 1 && editor.undos == 0
            print("CLEAR_SWIPE_REPLAY case=\(caseNumber) first=\(first.rawValue) second=\(second.rawValue) deleted=\(editor.deletes) empty=\(editor.content.isEmpty ? 1 : 0) pass=\(passed ? 1 : 0)")
            if !passed { failures.append("clear_synthetic_\(caseNumber)") }
        }
        do {
            let editor = Editor("R67 synthetic unchanged", native: true)
            defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.008)
            let first = await executor.perform(.cancel, session: await begin(executor))
            editor.content += " user edit"
            editor.selection = NSRange(location: editor.content.utf16.count, length: 0)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.008)
            let second = await executor.perform(.cancel, session: await begin(executor))
            let passed = first == .clearArmed && second == .clearArmed
                && editor.deletes == 0 && editor.content.hasSuffix(" user edit")
            print("CLEAR_SWIPE_REPLAY case=3 first=\(first.rawValue) second=\(second.rawValue) deleted=\(editor.deletes) preserved=\(editor.deletes == 0 ? 1 : 0) pass=\(passed ? 1 : 0)")
            if !passed { failures.append("clear_synthetic_3") }
        }
        do {
            let editor = Editor("R67 synthetic native delivery", native: true)
            defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.008)
            let first = await executor.deliver(text: "", action: .cancel, session: await begin(executor))
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.008)
            let second = await executor.deliver(text: "", action: .cancel, session: await begin(executor))
            let passed = first == .clearArmed && second == .clearedCurrentInput
                && editor.deletes == 1 && editor.content.isEmpty
            print("CLEAR_SWIPE_REPLAY case=4 first=\(first.rawValue) second=\(second.rawValue) deleted=\(editor.deletes) pass=\(passed ? 1 : 0)")
            if !passed { failures.append("clear_synthetic_4") }
        }
        for (caseNumber, native) in [(5, true), (6, false)] {
            let editor = Editor("R67 synthetic partial selection", native: native)
            defer { editor.dispose() }
            editor.shortSelectAllBy = 2
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.008)
            let first = await executor.perform(.cancel, session: await begin(executor))
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.008)
            let second = await executor.perform(.cancel, session: await begin(executor))
            let passed = first == .clearArmed && second == .cancelUnconfirmed
                && editor.deletes == 0 && !editor.content.isEmpty
            print("CLEAR_SWIPE_REPLAY case=\(caseNumber) first=\(first.rawValue) second=\(second.rawValue) deleted=\(editor.deletes) pass=\(passed ? 1 : 0)")
            if !passed { failures.append("clear_synthetic_\(caseNumber)") }
        }
        print("CLEAR_SWIPE_REPLAY_RESULT total=6 failed=\(failures.count) synthetic=1")
        return failures
    }

    static func run(baseline: Bool = false) async -> [String] {
        var rows: [Row] = []
        func record(_ number: Int, _ passed: Bool, _ editor: Editor) {
            rows.append(.init(number: number, passed: passed, caret: editor.selection.location, writes: editor.writes))
        }
        let original = "first fixed paragraph\nsecond fixed paragraph\nthird fixed paragraph"
        do {
            let editor = Editor(original); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            var ok = editor.selection.location == editor.value.utf16.count - 3
            for number in 1...5 {
                let result = await sentence(executor, editor: editor, number: number)
                ok = ok && result.0 && result.1 == .kept && editor.selection.location == editor.content.utf16.count
            }
            record(1, ok && editor.probes == 0 && editor.undos == 0, editor)
        }
        for (number, length, start, selected) in [(2, 137, 135, 2), (3, 31, 20, 11)] {
            let text = String(repeating: "a", count: length - selected) + String(repeating: "z", count: selected)
            let editor = Editor(text, selection: NSRange(location: start, length: selected)); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            var ok = false
            if let token = await begin(executor) {
                _ = await executor.updateDraft(text: "replacement", sequence: 1, session: token)
                let outcome = await executor.deliver(text: "replacement", action: .stop, session: token)
                ok = outcome == .kept && editor.content == (text as NSString).replacingCharacters(in: NSRange(location: start, length: selected), with: "replacement")
            }
            if number == 2 {
                editor.content = text; editor.selection = NSRange(location: start, length: selected)
                if let token = await begin(executor) {
                    _ = await executor.updateDraft(text: "replacement", sequence: 1, session: token)
                    let outcome = await executor.deliver(text: "replacement", action: .cancel, session: token)
                    ok = ok && outcome == .removedCurrentDictation && editor.content == text &&
                        editor.selection == NSRange(location: start + selected, length: 0)
                } else { ok = false }
            }
            record(number, ok, editor)
        }
        do {
            let editor = Editor(original); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let text = TerminalPeriodPolicy.sentence("", prefix: "。").text
            let token = await begin(executor)
            let outcome = await executor.deliver(text: text, action: .send, session: token)
            record(4, text.isEmpty && outcome == .sent && editor.pastes == 0 && editor.deletes == 0 && editor.returns == 1, editor)
        }
        do {
            let editor = Editor(original); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let first = await sentence(executor, editor: editor, number: 1, count: 2)
            let nextAt = ProcessInfo.processInfo.systemUptime
            let second = await sentence(executor, editor: editor, number: 2, count: 2)
            var ok = first.1 == .kept && second.1 == .kept && ProcessInfo.processInfo.systemUptime - nextAt < 1
            if let token = await begin(executor) {
                _ = await executor.updateDraft(text: "own draft", sequence: 1, session: token)
                _ = editor.board.clearContents(); _ = editor.board.setString("synthetic user copy", forType: .string)
                let count = editor.board.changeCount
                let content = editor.content, pastes = editor.pastes, deletes = editor.deletes
                _ = await executor.updateDraft(text: "later draft", sequence: 2, session: token)
                let outcome = await executor.deliver(text: "final draft", action: .stop, session: token)
                ok = ok && outcome != .kept && outcome != .sent && editor.content == content &&
                    editor.pastes == pastes && editor.deletes == deletes && editor.board.changeCount == count &&
                    editor.board.string(forType: .string) == "synthetic user copy"
            } else { ok = false }
            record(5, ok, editor)
        }
        do {
            let editor = Editor(original); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let result = await sentence(executor, editor: editor, number: 1, count: 1)
            record(6, result.0 && result.1 == .kept && editor.probes == 0 && editor.pastes > 0, editor)
        }
        do {
            let editor = Editor("", phantom: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let result = await sentence(executor, editor: editor, number: 1, count: 1)
            record(7, result.0 && result.1 == .kept && editor.selection.location == editor.content.utf16.count, editor)
        }
        do {
            let editor = Editor(original); defer { editor.dispose() }
            editor.runtime.noteWrite(bundle: editor.bundleIdentifier)
            _ = editor.runtime.noteFailure(bundle: editor.bundleIdentifier, reason: .sendStillPresent)
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let denied = editor.runtime.isDenied(editor.bundleIdentifier)
            let token = await begin(executor)
            _ = await executor.updateDraft(text: "first partial", sequence: 1, session: token)
            let outcome = await executor.deliver(text: "final only sentence", action: .stop, session: token)
            record(8, denied && outcome == .kept && editor.pastes == 1 && editor.content == original + "final only sentence", editor)
        }
        do {
            let editor = Editor(original); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let backend = Backend()
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: executor)
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            let activation = GestureActivation(location: .init(x: 20, y: 20), button: .left,
                match: .init(deviceToken: 1, deviceKind: .magicMouse, touchCount: 2, newestTouchAgeSeconds: 0.01, maximumMovement: 0.001))
            let selection = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "zh")
            _ = coordinator.gestureBegan(activation, settings: VoicePointerSettings(), selection: selection, localHotwords: ["Qwen"])
            for _ in 0..<100 where coordinator.status != .listening { try? await Task.sleep(for: .milliseconds(5)) }
            let listening = coordinator.status == .listening
            let initialWrites = editor.writes
            backend.emit(.partial, text: ""); backend.emit(.partial, text: "Qwen")
            try? await Task.sleep(for: .milliseconds(350))
            print("REPLAY_FILTER listening=\(listening ? 1 : 0) hotwords=\(backend.hotwordCount) before=\(initialWrites) after=\(editor.writes)")
            record(9, listening && backend.hotwordCount == 1 && editor.writes == initialWrites && editor.content == original, editor)
            await coordinator.applicationWillTerminate()
        }
        do {
            let editor = Editor(original); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let result = await sentence(executor, editor: editor, number: 1, count: 2, action: .cancel)
            record(10, result.1 == .removedCurrentDictation && editor.content == original &&
                editor.selection == NSRange(location: original.utf16.count, length: 0) && editor.deletes == 1 && editor.undos == 0, editor)
        }
        do {
            let editor = Editor(original, native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            var ok = true
            for number in 1...3 {
                let result = await sentence(executor, editor: editor, number: number, count: 2)
                ok = ok && result.0 && result.1 == .kept
            }
            let token = await begin(executor)
            let outcome = await executor.deliver(text: "", action: .send, session: token)
            print("REPLAY_NATIVE axValue=\(editor.values) paste=\(editor.pastes) undo=\(editor.undos) send=\(editor.returns)")
            record(11, ok && outcome == .sent && editor.values == 6 && editor.pastes == 0 && editor.undos == 0 && editor.returns == 1, editor)
        }
        // R66 S1-12: strict auto stays out of drafts and pre-release finals; it applies at release,
        // while recognizer hints remain closed until three real replacement hits.
        do {
            let editor = Editor("甲丙"); defer { editor.dispose() }
            let automatic = LexiconTerm(canonical: "甲乙", variants: ["甲丙"], source: .automaticallyLearned)
            let frozen = LexiconSnapshot(revision: 1, terms: [automatic])
            let draft = frozen.apply(to: "甲丙", includeAutomatic: false)
            let final = frozen.apply(to: "甲丙")
            let hints = RecognitionHotwords.select(from: [automatic])
            record(12, frozen.ruleCount == 1 && draft?.text == "甲丙" && final?.text == "甲乙" &&
                draft?.hits.isEmpty == true && final?.hits.count == 1 && hints.isEmpty, editor)
        }
        // S1-13: manually curated entries keep both correction and recognizer hints.
        do {
            let editor = Editor("甲丙"); defer { editor.dispose() }
            let manual = LexiconTerm(canonical: "甲乙", variants: ["甲丙"], source: .manual)
            let frozen = LexiconSnapshot(revision: 2, terms: [manual])
            let corrected = frozen.apply(to: "甲丙")
            let hints = RecognitionHotwords.select(from: [manual])
            record(13, frozen.ruleCount == 1 && corrected?.text == "甲乙" &&
                corrected?.hits.count == 1 && hints == ["甲乙"], editor)
        }
        // S1-14: the production persist gate leaves the synthetic lexicon unchanged and reports suppression.
        do {
            let editor = Editor("synthetic"); defer { editor.dispose() }
            var entries = [LexiconTerm(canonical: "手动", source: .manual)]
            let before = entries.count
            var traces: [String] = []
            let allow = AutomaticPromotionPolicy.permitPersist { traces.append($0) }
            if allow { entries.append(LexiconTerm(canonical: "甲乙", variants: ["甲丙"], source: .automaticallyLearned)) }
            record(14, !allow && entries.count == before && traces == ["learn promotion suppressed=1"], editor)
        }
        // A1: 50% * 20% = 10%; 0.8s grace + 0.2s restore; ratio=0 mutes then restores.
        do {
            let editor = Editor("A1 synthetic"); defer { editor.dispose() }
            let clock = DuckClock(), evidence = DuckEvidence(), device = DuckDevice("A1")
            let policy = duckPolicy(clock, evidence)
            let started = policy.begin(device: device, enabled: true, ratio: 0.2)
            clock.advance(0.11)
            let low = duckNear(device.state.levels[0], 0.10)
            policy.release()
            clock.advance(0.79)
            let grace = duckNear(device.state.levels[0], 0.10)
            clock.advance(0.23)
            let restored = duckNear(device.state.levels[0], 0.50) && evidence.recovery == nil
            let muteDevice = DuckDevice("A1mute")
            let mutePolicy = duckPolicy(DuckClock(), DuckEvidence())
            let muteStart = mutePolicy.begin(device: muteDevice, enabled: true, ratio: 0)
            let muted = muteDevice.state.muted
            mutePolicy.restoreForCue()
            let muteRestore = !muteDevice.state.muted && duckNear(muteDevice.state.levels[0], 0.50)
            record(15, started && low && grace && restored && muteStart && muted && muteRestore, editor)
        }
        // A2: muted, almost-zero and disabled sessions do not write any device properties.
        do {
            let editor = Editor("A2 synthetic"); defer { editor.dispose() }
            let off = DuckDevice("A2off"), zero = DuckDevice("A2zero", levels: [0]),
                muted = DuckDevice("A2muted", muted: true)
            let policy = duckPolicy(DuckClock(), DuckEvidence())
            let disabled = !policy.begin(device: off, enabled: false, ratio: 0.2) &&
                off.reads == 0 && off.writes == 0
            let zeroSkipped = !policy.begin(device: zero, enabled: true, ratio: 0.2) && zero.writes == 0
            let mutedSkipped = !policy.begin(device: muted, enabled: true, ratio: 0.2) && muted.writes == 0
            let volumeOnly = DuckDevice("A2volumeZero", canMute: false)
            let zeroVolumePolicy = duckPolicy(DuckClock(), DuckEvidence())
            let zeroVolume = zeroVolumePolicy.begin(device: volumeOnly, enabled: true, ratio: 0) &&
                duckNear(volumeOnly.state.levels[0], 0.40)
            zeroVolumePolicy.restoreForCue()
            record(16, disabled && zeroSkipped && mutedSkipped && zeroVolume &&
                duckNear(volumeOnly.state.levels[0], 0.50), editor)
        }
        // A3: mute-only fallback, independent channels, unsupported prompt once and not-effective fuse.
        do {
            let editor = Editor("A3 synthetic"); defer { editor.dispose() }
            let mute = DuckDevice("A3mute", control: .mute)
            let mutePolicy = duckPolicy(DuckClock(), DuckEvidence())
            let muted = mutePolicy.begin(device: mute, enabled: true, ratio: 0.2) && mute.state.muted
            mutePolicy.forceRestore()
            let unmuted = !mute.state.muted
            let channels = DuckDevice("A3channels", levels: [0.5, 0.7], control: .channels, canMute: false)
            let cc = DuckClock(), channelPolicy = duckPolicy(cc, DuckEvidence())
            let channelStart = channelPolicy.begin(device: channels, enabled: true, ratio: 0.2)
            cc.advance(0.11)
            let channelDucked = duckNear(channels.state.levels[0], 0.1) &&
                duckNear(channels.state.levels[1], 0.14)
            channelPolicy.forceRestore()
            let channelRestored = duckNear(channels.state.levels[0], 0.5) &&
                duckNear(channels.state.levels[1], 0.7)
            let noControl = DuckDevice("A3none", control: .none, canMute: false)
            let evidence = DuckEvidence(), unsupportedPolicy = duckPolicy(DuckClock(), evidence)
            _ = unsupportedPolicy.begin(device: noControl, enabled: true, ratio: 0.2)
            _ = unsupportedPolicy.begin(device: noControl, enabled: true, ratio: 0.2)
            let onlyOneNotice = evidence.notices == 1 && noControl.writes == 0
            let failedDevice = DuckDevice("A3ineffective")
            failedDevice.effective = false
            let failedEvidence = DuckEvidence(), failedPolicy = duckPolicy(DuckClock(), failedEvidence)
            let first = failedPolicy.begin(device: failedDevice, enabled: true, ratio: 0.2)
            let before = failedDevice.writes
            let second = failedPolicy.begin(device: failedDevice, enabled: true, ratio: 0.2)
            let fused = !first && !second && failedDevice.writes == before &&
                failedEvidence.logs.contains(where: { $0.contains("result=notEffective") })
            record(17, muted && unmuted && channelStart && channelDucked && channelRestored &&
                onlyOneNotice && fused, editor)
        }
        // A4: a user's volume key owns the new level; switching output restores only the old device.
        do {
            let editor = Editor("A4 synthetic"); defer { editor.dispose() }
            let clock = DuckClock(), evidence = DuckEvidence(), device = DuckDevice("A4old")
            let policy = duckPolicy(clock, evidence)
            _ = policy.begin(device: device, enabled: true, ratio: 0.2)
            clock.advance(0.11)
            device.state = .init(levels: [0.35], muted: false) // Synthetic volume-key adjustment.
            policy.userChanged()
            policy.forceRestore()
            let userOwns = duckNear(device.state.levels[0], 0.35) && evidence.recovery == nil &&
                evidence.logs.contains(where: { $0.contains("result=userChanged") })
            let clock2 = DuckClock(), old = DuckDevice("A4switchOld"), replacement = DuckDevice("A4new")
            let another = duckPolicy(clock2, DuckEvidence())
            _ = another.begin(device: old, enabled: true, ratio: 0.2)
            clock2.advance(0.11)
            let startedNew = another.begin(device: replacement, enabled: true, ratio: 0.2)
            record(18, userOwns && !startedNew && duckNear(old.state.levels[0], 0.5) &&
                replacement.writes == 0, editor)
        }
        // A5: startup/reconnect restore only the recorded ducked state; stale records expire.
        do {
            let editor = Editor("A5 synthetic"); defer { editor.dispose() }
            let clock = DuckClock(), evidence = DuckEvidence(), device = DuckDevice("A5")
            let originalPolicy = duckPolicy(clock, evidence)
            _ = originalPolicy.begin(device: device, enabled: true, ratio: 0.2)
            clock.advance(0.11)
            var recovered = false, staleDropped = false, userChangePreserved = false
            if let record = evidence.recovery {
                let next = DuckEvidence(); next.recovery = record
                let freshProcess = duckPolicy(clock, next)
                recovered = freshProcess.recover(record, on: device) &&
                    duckNear(device.state.levels[0], 0.5) && next.recovery == nil
                let staleClock = DuckClock(); staleClock.advance(601)
                let staleEvidence = DuckEvidence(); staleEvidence.recovery = record
                let stalePolicy = duckPolicy(staleClock, staleEvidence)
                let staleDevice = DuckDevice("A5", levels: [0.1])
                staleDropped = !stalePolicy.recover(record, on: staleDevice) &&
                    staleEvidence.recovery == nil && duckNear(staleDevice.state.levels[0], 0.1)
                let changedEvidence = DuckEvidence(); changedEvidence.recovery = record
                let changedPolicy = duckPolicy(DuckClock(), changedEvidence)
                let changed = DuckDevice("A5", levels: [0.32])
                userChangePreserved = !changedPolicy.recover(record, on: changed) &&
                    changedEvidence.recovery == nil && duckNear(changed.state.levels[0], 0.32)
            }
            record(19, recovered && staleDropped && userChangePreserved, editor)
        }
        // A6: consecutive dictations preserve earliest original, cue restores first, Bluetooth recheck once.
        do {
            let editor = Editor("A6 synthetic"); defer { editor.dispose() }
            let clock = DuckClock(), evidence = DuckEvidence(), device = DuckDevice("A6")
            let policy = duckPolicy(clock, evidence)
            _ = policy.begin(device: device, enabled: true, ratio: 0.2)
            clock.advance(0.11)
            let writes = device.writes
            policy.release()
            clock.advance(0.5)
            let reused = policy.begin(device: device, enabled: true, ratio: 0.2)
            let held = duckNear(device.state.levels[0], 0.1) && device.writes == writes
            policy.release()
            policy.restoreForCue()
            let cueBeforeSound = duckNear(device.state.levels[0], 0.5) && evidence.recovery == nil
            let bluetooth = DuckDevice("A6bt", transport: .bluetooth)
            let btClock = DuckClock(), btPolicy = duckPolicy(btClock, DuckEvidence())
            _ = btPolicy.begin(device: bluetooth, enabled: true, ratio: 0.2)
            btClock.advance(0.11)
            btPolicy.restoreForCue()
            bluetooth.state = .init(levels: [0.1], muted: false) // Simulated delayed Bluetooth reset.
            let before = bluetooth.writes
            btClock.advance(1.01)
            let repaired = duckNear(bluetooth.state.levels[0], 0.5) && bluetooth.writes == before + 1
            btClock.advance(2)
            record(20, reused && held && cueBeforeSound && repaired && bluetooth.writes == before + 1, editor)
        }
        // B1: clamping the HUD upward by 80pt never changes the finger-relative 40pt threshold.
        do {
            let editor = Editor("B1 synthetic"); defer { editor.dispose() }
            let origin = CGPoint(x: 400, y: 500)
            let clampedPanelAnchor = CGPoint(x: 400, y: 420) // HUD moves up 80, touch start does not.
            let up60 = CGPoint(x: 400, y: 440)
            let highlight = RadialReleaseClassifier.classify(
                hitAction: .stop, anchor: origin, current: up60,
                minimumDirectionalTravel: 40, neutralTravel: 30)
            let release = RadialReleaseClassifier.classify(
                hitAction: .stop, anchor: origin, current: up60, previousAction: highlight,
                minimumDirectionalTravel: 40, neutralTravel: 30)
            let normalPanel = RadialReleaseClassifier.classify(
                hitAction: .send, anchor: origin, current: up60)
            let cancel = RadialReleaseClassifier.classify(
                hitAction: .stop, anchor: origin, current: CGPoint(x: 400, y: 560))
            let deadZone = RadialReleaseClassifier.classify(
                hitAction: .stop, anchor: origin, current: CGPoint(x: 400, y: 475),
                previousAction: .send)
            let hysteresis = RadialReleaseClassifier.classify(
                hitAction: .stop, anchor: origin, current: CGPoint(x: 400, y: 469),
                previousAction: .send)
            record(21, clampedPanelAnchor.y == origin.y - 80 && highlight == .send &&
                release == highlight && normalPanel == .send && cancel == .cancel &&
                deadZone == .stop && hysteresis == .send, editor)
        }
        // B2a/B2b/B2c: the EMPTY V0 speech path still waits for a late IME commit.
        // These original 3 arrival/no-arrival assertions stay intact. A nonempty V0
        // now has its distinct R67 600ms path and must not re-enter old 4s waits.
        // The real Return endpoint is intercepted by Editor; no OS keyboard event is posted.
        let doubaoCases: [(Int, Int?)] = [(22, 2_200), (23, nil), (24, 1_000)]
        for (number, landingMilliseconds) in doubaoCases {
            let editor = Editor("", native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.08) // Synthetic speech, no microphone.
            guard let session = await begin(executor) else {
                record(number, false, editor)
                continue
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let landingTask: Task<Void, Never>? = landingMilliseconds.map { delay in
                Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                    editor.content += " synthetic committed words"
                    editor.selection = NSRange(location: editor.content.utf16.count, length: 0)
                }
            }
            let outcome = await executor.perform(.send, session: session)
            if let landingTask { _ = await landingTask.value }
            let returnMs = editor.returnPostedAt.map { Int(($0 - startedAt) * 1_000) } ?? -1
            let passed: Bool
            if number == 23 {
                let feedback = ComposerActionFeedback(outcome: outcome, action: .send)
                passed = outcome == .doubaoTextTimeout && editor.returns == 0 &&
                    editor.content.isEmpty &&
                    feedback.message == "豆包没出字，没发送，再推一下直接发" &&
                    feedback.kind == .warning && feedback.shouldPresent
            } else {
                let earliest = number == 22 ? 2_400 : 1_200
                let latest = number == 22 ? 3_400 : 2_300
                passed = outcome == .sent && editor.returns == 1 &&
                    returnMs >= earliest && returnMs <= latest
            }
            print("REPLAY_B2 number=\(number) releaseToReturnMs=\(returnMs) returns=\(editor.returns) outcome=\(outcome.rawValue)")
            record(number, passed, editor)
        }
        // B3: 0.8s after release, synthetic focus leaves the editor before Return.
        // The real executor must refuse the key and provide the explicit, safe failure message.
        do {
            let editor = Editor("B3 synthetic baseline"); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.08)
            let token = await begin(executor)
            let landing = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                editor.content += " synthetic committed text"
                editor.selection = NSRange(location: editor.content.utf16.count, length: 0)
            }
            let changeFocus = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                editor.replayFocusMoved = true
            }
            let outcome = await executor.perform(.send, session: token)
            _ = await landing.value
            _ = await changeFocus.value
            let feedback = ComposerActionFeedback(outcome: outcome, action: .send)
            let uncertain = ComposerActionFeedback(outcome: .sendUnconfirmed, action: .send)
            let stillPresent = ComposerActionFeedback(outcome: .sendStillPresent, action: .send)
            let ok = outcome == .sendTargetChangedBeforeReturn && editor.returns == 0 &&
                editor.replayFocusMoved && editor.content.contains("synthetic committed text") &&
                feedback.message == "没发出去：发送前点了别处，字还在原来的输入框里" &&
                feedback.shouldPresent && feedback.kind == .warning &&
                !uncertain.shouldPresent && stillPresent.message == "没发出去，文字还在"
            print("REPLAY_B3 focusChanged=\(editor.replayFocusMoved ? 1 : 0) returns=\(editor.returns) result=\(outcome.rawValue) warning=\(feedback.shouldPresent ? 1 : 0)")
            record(25, ok, editor)
        }
        // R67 A: measured through the same executor; no duplicate simulation.
        rows.append(contentsOf: await r67FastRows())
        // R67 B: a commit at release+450ms is never allowed through the new fast path.
        do {
            let editor = Editor("R67 stable existing", native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.05)
            let token = await begin(executor), start = ProcessInfo.processInfo.systemUptime
            let changing = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                editor.content += " R67 later commit"
            }
            let outcome = await executor.perform(.send, session: token)
            _ = await changing.value
            let ms = editor.returnPostedAt.map { Int(($0 - start) * 1000) } ?? -1
            record(30, outcome == .sent && editor.returns == 1 && ms >= 950 && ms <= 2_500, editor)
            print("REPLAY_R67_B elapsedMs=\(ms) returns=\(editor.returns)")
        }
        // R67 C: one bounded first-landing deadline from the original release clock.
        rows.append(contentsOf: await r67EmptyRows())
        // R67 D: same original two empty V0 cases now must post Return after ~600ms.
        for (index, peak) in [0.003 as Float?, nil].enumerated() {
            let editor = Editor("", native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            if let peak { GestureSpeechActivity.shared.recordCapture(peakLevel: peak) }
            let session = await begin(executor), start = ProcessInfo.processInfo.systemUptime
            let outcome = await executor.perform(.send, session: session)
            let ms = editor.firstReturnPostedAt.map { Int(($0 - start) * 1_000) } ?? -1
            record(33 + index, editor.returns == 1 &&
                ms >= 500 && ms <= 850 && outcome != .nothingToSend &&
                outcome != .doubaoTextTimeout && outcome != .dictationNotSettled, editor)
        }
        // R67 E: one second upward request consumes the original session's pending send.
        for (index, empty) in [false, true].enumerated() {
            let editor = Editor(empty ? "" : "R67 existing", native: true); defer { editor.dispose() }
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.05)
            let token = await begin(executor)
            let send = Task { @MainActor in await executor.perform(.send, session: token) }
            try? await Task.sleep(for: .milliseconds(400))
            let requested = token?.requestExpeditedSend() == true
            let duplicateDenied = token?.requestExpeditedSend() == false
            let outcome = await send.value
            let expected = empty
                ? editor.returns == 1 &&
                    outcome != .doubaoTextTimeout && outcome != .nothingToSend
                : outcome == .sent && editor.returns == 1
            record(35 + index, requested && duplicateDenied && expected, editor)
            print("REPLAY_R67_E case=\(index) returns=\(editor.returns) sameSession=1")
        }
        // R67 F: Chrome unchanged after Return retries once, new line never retries.
        for (index, addLineBreak) in [false, true].enumerated() {
            let editor = Editor("R67 Chrome fixture", bundleIdentifierOverride: "com.google.Chrome")
            defer { editor.dispose() }
            editor.swallowNextReturn = !addLineBreak
            editor.appendLineBreakOnReturn = addLineBreak
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            GestureSpeechActivity.shared.beginGesture()
            GestureSpeechActivity.shared.recordCapture(peakLevel: 0.05)
            let outcome = await executor.perform(.send, session: await begin(executor))
            let countOK = addLineBreak ? editor.returns == 1 : editor.returns == 2
            record(37 + index, countOK && (outcome == .sent || outcome == .sendUnconfirmed), editor)
            print("REPLAY_R67_F case=\(index) returns=\(editor.returns)")
        }
        rows.append(contentsOf: await r673EmptyRows())
        // R68: another process's secure-input flag does not label an ordinary
        // field as a password. Final-only delivery still checks exact snapshots.
        for (index, native) in [true, false].enumerated() {
            let editor = Editor("R68 original ", native: native); defer { editor.dispose() }
            editor.systemSecureInput = true
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let token = await begin(executor)
            _ = await executor.updateDraft(text: "partial", sequence: 1, session: token)
            let noPartial = editor.writes == 0
            let outcome = await executor.deliver(text: "final", action: .stop, session: token)
            record(44 + index, token != nil && noPartial && outcome == .kept &&
                editor.content == "R68 original final" && editor.pastes == 1, editor)
        }
        do {
            let editor = Editor("R68 original ", native: true); defer { editor.dispose() }
            editor.systemSecureInput = true
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let token = await begin(executor)
            // Key events can be invisible while secure input is enabled.
            // Deliberately leave EditingIntentClock unchanged.
            editor.content = "R68 human edit"
            editor.selection = NSRange(location: editor.content.utf16.count, length: 0)
            let outcome = await executor.deliver(text: "final", action: .stop, session: token)
            record(46, outcome != .kept && editor.writes == 0 && editor.content == "R68 human edit", editor)
        }
        for (index, kind) in ["focusElement", "focusWindow", "workspace"].enumerated() {
            let editor = Editor("R68 send", native: true); defer { editor.dispose() }
            editor.postReturnFocus = kind
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let outcome = await executor.deliver(text: "", action: .send, session: await begin(executor))
            record(47 + index, outcome == .sendUnconfirmed && editor.returns == 1, editor)
        }
        do {
            let editor = Editor("R68 gate", native: true); defer { editor.dispose() }
            let before = ComposerFocusEventGate()
            let beforeOK = before.shouldInvalidate(matchesFrozenIdentity: false, kind: "workspace") &&
                before.postReturnInvalidation == nil && before.isInvalidated
            let after = ComposerFocusEventGate()
            after.noteReturnPosted()
            let afterOK = after.shouldInvalidate(matchesFrozenIdentity: false, kind: "focusElement") &&
                after.postReturnInvalidation == "focusElement" &&
                !after.shouldInvalidate(matchesFrozenIdentity: false, kind: "workspace")
            record(50, beforeOK && afterOK, editor)
        }
        // R68.1: real secure roles are usable without content reads, clipboard,
        // partial writes, learning receipts, or repeated Return.
        for (index, native) in [true, false].enumerated() {
            let editor = Editor("fixture-old", selection: NSRange(location: 8, length: 3), native: native)
            defer { editor.dispose() }
            editor.secureField = true; editor.systemSecureInput = true
            let clipboardCount = editor.board.changeCount
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let token = await begin(executor)
            let partial = await executor.updateDraft(text: "partial", sequence: 1, session: token)
            let outcome = await executor.deliver(text: "中文🙂42", action: .stop, session: token)
            record(51 + index, token?.isSecureField == true && partial == .unsupported &&
                outcome == .inputSubmitted && editor.content == "fixture-中文🙂42" && editor.secureWrites == 1 &&
                editor.secureReads == 0 && editor.pastes == 0 && editor.values == 0 &&
                editor.board.changeCount == clipboardCount && executor.takeKeptBaseline(for: token) == nil, editor)
        }
        do {
            let editor = Editor("fixture-hidden", native: true); defer { editor.dispose() }
            editor.secureField = true
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let token = await begin(executor)
            token?.cancelDraftUpdates()
            let cancel = await executor.deliver(text: "discarded", action: .cancel, session: token)
            let cancelOK = cancel == .nothingToCancel && editor.content == "fixture-hidden" && editor.writes == 0
            let next = await begin(executor)
            let sent = await executor.perform(.send, session: next)
            _ = await executor.perform(.send, session: next)
            record(53, cancelOK && sent == .sendUnconfirmed && editor.returns == 1 && editor.secureReads == 0, editor)
        }
        do {
            let editor = Editor("fixture-kept", native: true); defer { editor.dispose() }
            editor.secureField = true
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let cancellation = OperationCancellationToken()
            let result = await executor.beginSession(cancellationToken: cancellation)
            if case .ready(let token) = result {
                cancellation.cancel()
                let outcome = await executor.deliver(text: "forbidden", action: .stop, session: token)
                record(54, outcome != .inputSubmitted && editor.writes == 0 && editor.content == "fixture-kept", editor)
            } else { record(54, false, editor) }
        }
        do {
            let editor = Editor("fixture-no-submit", native: true); defer { editor.dispose() }
            editor.secureField = true
            let executor = MacOSComposerActionExecutor(testReplayIO: editor)
            let outcome = await executor.deliver(text: "unexpected\n", action: .stop, session: await begin(executor))
            record(55, outcome == .deliveryFailed && editor.writes == 0 && editor.returns == 0 &&
                   editor.content == "fixture-no-submit", editor)
        }
        rows.append(contentsOf: await noTargetHintRows())
        for row in rows { print("REPLAY number=\(row.number) result=\(row.passed ? "pass" : "fail") caret=\(row.caret) writes=\(row.writes)") }
        let failed = rows.filter { !$0.passed }.map(\.number)
        print("REPLAY_SUMMARY baseline=\(baseline ? 1 : 0) passed=\(rows.count - failed.count) total=\(rows.count) failed=\(failed.map(String.init).joined(separator: ",")) ax=synthetic clipboard=named keys=memory network=0")
        return failed.map { "replay case \($0)" }
    }
}
