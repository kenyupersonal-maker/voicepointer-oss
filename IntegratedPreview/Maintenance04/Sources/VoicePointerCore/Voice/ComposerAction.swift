import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum VoiceReleaseAction: String, Sendable, Equatable {
    case stop
    case send
    /// Legacy wire name retained for HUD compatibility; performs native Undo once.
    case cancel
}

fileprivate final class ComposerSnapshotMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    func mark() { lock.withLock { active = true } }
    var isActive: Bool { lock.withLock { active } }
}

public struct ComposerActionSession: Sendable, Equatable {
    public let applicationBundleID: String?
    /// Hidden text is write-only: never use it as a correction/learning/history source.
    public let isSecureField: Bool
    fileprivate let identifier: UInt64
    fileprivate let cancellationToken: OperationCancellationToken
    fileprivate let draftCancellationToken: OperationCancellationToken
    fileprivate let targetWatch: ComposerTargetWatch?
    fileprivate let releaseTiming: ComposerReleaseTiming
    fileprivate let snapshotMarker: ComposerSnapshotMarker

    fileprivate init(identifier: UInt64, cancellationToken: OperationCancellationToken, targetWatch: ComposerTargetWatch? = nil, releaseTiming: ComposerReleaseTiming = .init(), applicationBundleID: String? = nil, snapshotMarker: ComposerSnapshotMarker = .init(), isSecureField: Bool = false) {
        self.applicationBundleID = applicationBundleID
        self.isSecureField = isSecureField
        self.identifier = identifier
        self.cancellationToken = cancellationToken
        self.draftCancellationToken = OperationCancellationToken(parent: cancellationToken)
        self.targetWatch = targetWatch
        self.releaseTiming = releaseTiming
        self.snapshotMarker = snapshotMarker
    }

    public var isCancelled: Bool { cancellationToken.isCancelled }
    public var areDraftUpdatesCancelled: Bool { draftCancellationToken.isCancelled }
    /// T13: Revokes queued/in-flight partial writers without revoking the original target-bound Undo/reference token.
    public func cancelDraftUpdates() { draftCancellationToken.cancel() }
    /// Record before backend teardown so the timing includes finalization, not just AX polling.
    public func noteRelease() { releaseTiming.noteRelease() }
    public func beginExternalSend() { releaseTiming.beginExternalSend() }
    public func requestExpeditedSend() -> Bool {
        !isCancelled && releaseTiming.requestExpeditedSend()
    }
    public func finishExternalSend() { releaseTiming.finishExternalSend() }

    @_spi(Testing)
    public init(testIdentifier: UInt64 = 1, cancellationToken: OperationCancellationToken = .init(), isSecureField: Bool = false) {
        self.applicationBundleID = nil
        self.isSecureField = isSecureField
        self.identifier = testIdentifier
        self.cancellationToken = cancellationToken
        self.draftCancellationToken = OperationCancellationToken(parent: cancellationToken)
        self.targetWatch = nil
        self.releaseTiming = ComposerReleaseTiming()
        self.snapshotMarker = ComposerSnapshotMarker()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identifier == rhs.identifier }
}

/// Finite acquisition failures; none contain editor text or application data.
public enum ComposerSessionStartFailureReason: String, CaseIterable, Sendable {
    case accessibilityUnavailable, noFrontmostApplication, wrongProcess, noFocusedElement, notEditable
    case secureInput, frozenTargetMismatch, noTargetWindow, targetWatchUnavailable, targetChangedDuringAcquire
}

/// Captured on the acquisition worker. Retains no AX object, editor content or retry target.
public struct ComposerNoInputFieldContext: Sendable, Equatable {
    public let reason: ComposerSessionStartFailureReason
    public let applicationBundleID: String
    public let focusedRole: String
    public let focusedSubrole: String

    public init(reason: ComposerSessionStartFailureReason, applicationBundleID: String? = nil,
                focusedRole: String? = nil, focusedSubrole: String? = nil) {
        self.reason = reason
        self.applicationBundleID = applicationBundleID.flatMap { InlineWritePolicy.safeBundle($0) ? $0 : nil } ?? "unknown"
        switch reason {
        case .noFocusedElement:
            self.focusedRole = "none"
            self.focusedSubrole = "none"
        case .notEditable:
            self.focusedRole = Self.safeControlType(focusedRole)
            self.focusedSubrole = Self.safeControlType(focusedSubrole)
        default:
            self.focusedRole = "unknown"
            self.focusedSubrole = "unknown"
        }
    }

    private static func safeControlType(_ value: String?) -> String {
        // AX type attributes are host-provided strings too; never log an arbitrary value.
        let types: Set<String> = [
            "AXApplication", "AXWindow", "AXStandardWindow", "AXDialog", "AXSystemDialog",
            "AXSheet", "AXGroup", "AXWebArea", "AXScrollArea", "AXSplitGroup", "AXToolbar",
            "AXButton", "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
            "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXRadioGroup",
            "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXStaticText",
            "AXImage", "AXLink", "AXList", "AXContentList", "AXTable", "AXOutline", "AXRow",
            "AXColumn", "AXCell", "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem",
            "AXSlider", "AXScrollBar", "AXTabGroup", "AXValueIndicator", "AXProgressIndicator", "AXUnknown"
        ]
        return value.flatMap { types.contains($0) ? $0 : nil } ?? "unknown"
    }
}

public enum ComposerSessionStartResult: Sendable, Equatable {
    case ready(ComposerActionSession)
    case noInputField(ComposerNoInputFieldContext)
    case secureFieldUnavailable
    case unavailable
    case cancelled
    case timedOut

    public static func forFailure(_ reason: ComposerSessionStartFailureReason, applicationBundleID: String? = nil,
                                  focusedRole: String? = nil, focusedSubrole: String? = nil) -> Self {
        switch reason {
        case .noFrontmostApplication, .wrongProcess, .noFocusedElement, .notEditable:
            return .noInputField(.init(reason: reason, applicationBundleID: applicationBundleID,
                                      focusedRole: focusedRole, focusedSubrole: focusedSubrole))
        case .secureInput: return .secureFieldUnavailable
        case .accessibilityUnavailable, .frozenTargetMismatch,
             .noTargetWindow, .targetWatchUnavailable, .targetChangedDuringAcquire:
            return .unavailable
        }
    }
}

public enum ComposerActionOutcome: String, Sendable, Equatable {
    case undoSubmitted
    case deliveryFailed
    case deliveryUnconfirmed
    case finalCopiedToClipboard
    case kept
    /// Text events were posted to a hidden field. No readback or learning receipt is claimed.
    case inputSubmitted
    case sent
    case nothingToSend
    case removedCurrentDictation
    case clearedCurrentInput
    case clearArmed
    case nothingToCancel
    case targetChanged
    /// Focus left the original composer before Return. No key was posted.
    case sendTargetChangedBeforeReturn
    case unsafeToCancel
    case eventPostFailed
    /// Return was submitted, but the available AX observations did not
    /// establish the result. This is deliberately distinct from a rejected
    /// event so callers never claim that the message was not sent.
    case sendUnconfirmed
    /// Return was posted and the same target still exposes the dictation text
    /// after the observation window. This is actionable but not proof that
    /// the target did not submit: some editors keep their text after Send.
    case sendStillPresent
    case sendPreempted
    /// A text replacement or Delete was submitted, but the expected text
    /// could not be confirmed afterwards.
    case cancelUnconfirmed
    /// Dictation text never became readable and stable within the bounded
    /// settle window. No send/cancel side effect was attempted.
    case dictationNotSettled
    /// External Doubao Send never received new text by the four-second release deadline.
    /// Return was NOT posted.
    case doubaoTextTimeout

    /// The outer AX deadline can expire after an irreversible submission.
    /// Without the worker's result, it cannot be labeled as a focus failure.
    @_spi(Testing)
    public static func unresolvedOperation(_ action: VoiceReleaseAction) -> Self {
        switch action {
        case .send: return .sendUnconfirmed
        case .cancel: return .cancelUnconfirmed
        case .stop: return .kept
        }
    }
}

private enum DictationSettleResult {
    case settled(String?, requireDoubaoText: Bool)
    case noTextLanded
    case notSettled
    case targetInvalid
    case cancelled
}

/// Synthetic dependencies for replaying the production executor without external I/O.
@_spi(Testing)
public protocol ComposerReplayIO: AnyObject, Sendable {
    var bundleIdentifier: String { get }
    var chromium: Bool { get }
    var clipboard: ClipboardTransfer { get }
    var runtime: InlineWriteRuntime { get }
    func read(_ attribute: String) -> CFTypeRef?
    func select(_ range: NSRange) -> Bool
    func write(_ attribute: String, value: String) -> ComposerAXWriteResult
    func key(_ code: UInt16, flags: UInt64) -> Bool
    func typeSecureText(_ text: String) -> Bool
}

@_spi(Testing)
public extension ComposerReplayIO {
    func typeSecureText(_ text: String) -> Bool { false }
}

/// Finite, content-free observation after a single Return. These states do
/// not authorize another key press; they only distinguish a confirmed clear
/// from an editor that retained text or exposed no trustworthy AX value.
private enum SubmissionSignal: String {
    case confirmed
    case unchanged
    case changedNonempty
    case textStillPresent
    case unreadable
    case focusChanged
    case editorReplaced, windowChanged, applicationSwitched
    case sessionInactive
    case emptyBeforeReturn
    case clearUnstable
}

/// The AX write phase is intentionally abstract so its safety classification
/// can be tested without constructing AXUIElement instances.
@_spi(Testing)
public enum ComposerAXWriteEvent: String, Sendable, Equatable {
    case cancelledBeforeCall
    case settableUnsupported
    case settableQueryFailed
    case notSettable
    case axSetSuccess
    case axSetCannotComplete
    case axSetFailed
}

@_spi(Testing)
public enum ComposerAXWriteResult: String, Sendable, Equatable {
    case beforeWriteRejected
    case unavailable
    case submitted
    case submittedButUnconfirmed

    public static func classify(_ event: ComposerAXWriteEvent) -> Self {
        switch event {
        case .cancelledBeforeCall, .settableQueryFailed:
            return .beforeWriteRejected
        case .settableUnsupported, .notSettable:
            return .unavailable
        case .axSetSuccess:
            return .submitted
        case .axSetCannotComplete, .axSetFailed:
            // AXSetAttributeValue was attempted. The target may have applied
            // the write even when AX did not return success.
            return .submittedButUnconfirmed
        }
    }
}

public protocol ComposerActionExecuting: Sendable {
    func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult
    func beginSession(cancellationToken: OperationCancellationToken, target: FrozenInputTarget?) async -> ComposerSessionStartResult
    func beginSession(cancellationToken: OperationCancellationToken, target: FrozenInputTarget?, onTargetInvalidated: @escaping @Sendable () -> Void) async -> ComposerSessionStartResult
    func perform(_ action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome
    func hasCancelContent(session: ComposerActionSession?) async -> Bool
    func cancel(session: ComposerActionSession?)
    func waitForPendingOperations() async
}

public extension ComposerActionExecuting {
    func hasCancelContent(session: ComposerActionSession?) async -> Bool { false }
    func waitForPendingOperations() async {}
    func beginSession(cancellationToken: OperationCancellationToken, target: FrozenInputTarget?, onTargetInvalidated: @escaping @Sendable () -> Void) async -> ComposerSessionStartResult {
        await beginSession(cancellationToken: cancellationToken, target: target)
    }
    /// Default targeted entry point. Fake executors without AX cannot claim to
    /// be bound to a frozen physical target, so a non-nil target is
    /// unavailable; nil targets forward to the legacy implementation.
    func beginSession(cancellationToken: OperationCancellationToken, target: FrozenInputTarget?) async -> ComposerSessionStartResult {
        guard target == nil else { return .unavailable }
        return await beginSession(cancellationToken: cancellationToken)
    }
}

public struct NoopComposerActionExecutor: ComposerActionExecuting {
    public init() {}
    public func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
        cancellationToken.isCancelled ? .cancelled : .unavailable
    }
    public func perform(
        _ action: VoiceReleaseAction,
        session: ComposerActionSession?
    ) async -> ComposerActionOutcome { .kept }
    public func cancel(session: ComposerActionSession?) {}
}

public enum DictationRollbackPlanner {
    /// Returns the UTF-16 range occupied by text inserted at the original
    /// caret or in place of the original selection. The caller can replace
    /// this range with the selected fragment from `originalText` to reconstruct
    /// the exact pre-dictation snapshot without touching unrelated text.
    public static func insertedRange(
        originalText: String,
        originalSelection: NSRange,
        currentText: String
    ) -> NSRange? {
        let original = originalText as NSString
        let current = currentText as NSString
        guard originalSelection.location != NSNotFound,
              originalSelection.location >= 0,
              originalSelection.length >= 0,
              NSMaxRange(originalSelection) <= original.length,
              isUTF16Boundary(originalSelection.location, in: originalText),
              isUTF16Boundary(NSMaxRange(originalSelection), in: originalText) else { return nil }

        let prefix = original.substring(to: originalSelection.location)
        let suffix = original.substring(from: NSMaxRange(originalSelection))
        guard currentText.hasPrefix(prefix), currentText.hasSuffix(suffix) else { return nil }

        let insertedLength = current.length - (prefix as NSString).length - (suffix as NSString).length
        guard insertedLength >= 0,
              isUTF16Boundary(originalSelection.location, in: currentText),
              isUTF16Boundary(originalSelection.location + insertedLength, in: currentText) else { return nil }
        return NSRange(location: originalSelection.location, length: insertedLength)
    }

    /// Recovers a single contiguous insertion when an editor reports a stale
    /// caret. Electron/WebView composers can expose a selection that is one
    /// character behind (or even outside an empty AXValue) while an IME owns
    /// the composition. The returned range is accepted only when deleting it
    /// reconstructs the exact pre-dictation snapshot.
    public static func recoverableInsertionRange(
        originalText: String,
        currentText: String
    ) -> NSRange? {
        let originalUnits = Array(originalText.utf16)
        let currentUnits = Array(currentText.utf16)
        let insertedLength = currentUnits.count - originalUnits.count
        guard insertedLength > 0 else { return nil }

        var location = 0
        while location < originalUnits.count,
              originalUnits[location] == currentUnits[location] {
            location += 1
        }
        guard originalUnits[location...] == currentUnits[(location + insertedLength)...],
              isUTF16Boundary(location, in: originalText),
              isUTF16Boundary(location, in: currentText),
              isUTF16Boundary(location + insertedLength, in: currentText) else { return nil }
        return NSRange(location: location, length: insertedLength)
    }

    private static func isUTF16Boundary(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0, offset <= text.utf16.count else { return false }
        let index = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        return index.samePosition(in: text) != nil
    }
}

/// Normalizes the inconsistent text attributes exposed by WebKit/Electron
/// editors. Some empty composers return their placeholder through AXValue;
/// contradictory metadata is deliberately rejected so Cancel stays fail-closed.
@_spi(Testing)
public enum ComposerTextNormalizer {
    public static func logicalText(
        value: String?,
        placeholder: String?,
        accessibilityDescription: String? = nil,
        characterCount: Int?
    ) -> String? {
        guard let value else { return nil }

        // ChatGPT/Codex WebViews currently expose their visual empty-state hint
        // as AXValue with a leading newline, omit AXPlaceholderValue, and repeat
        // the hint in AXDescription. Treat only the whitespace-wrapped duplicate
        // as chrome; exact user text equal to the description remains real text.
        if let accessibilityDescription {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDescription = accessibilityDescription.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if value != accessibilityDescription,
               !trimmedDescription.isEmpty,
               trimmedValue == trimmedDescription {
                return ""
            }
        }

        if let characterCount {
            guard characterCount >= 0 else { return nil }
            if characterCount == 0 {
                guard value.isEmpty || value == placeholder else { return nil }
                return ""
            }
            guard !value.isEmpty else { return nil }
            return value
        }

        if let placeholder, value == placeholder { return nil }
        return value
    }
}

public final class MacOSComposerActionExecutor: @unchecked Sendable, ComposerActionExecuting, TranscriptDelivering, KeptDeliveryReporting, DoubaoLearningReferenceProviding {
    public func waitForPendingOperations() async { await axWorker.drain() }
    /// Read only the frozen editor, before cancellation/Undo begins. Never infer
    /// landed text from microphone activity or from an uncommitted transcript.
    public func hasCancelContent(session token: ComposerActionSession?) async -> Bool {
        guard let token, !token.isCancelled else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds + 150_000_000
        return await axWorker.runBounded(nanoseconds: 150_000_000) { [self] in
            operationToken = token.cancellationToken
            operationDeadline = deadline
            defer { operationToken = nil; operationDeadline = .max }
            guard let s = session(matching: token), !s.isSecureField, isSessionActive(s), validate(s),
                  let document = sessionDocument(s), operationMayProceed else { return false }
            return !isEffectivelyEmpty(document, processIdentifier: s.processIdentifier)
        } ?? false
    }
    private struct Session {
        let identifier: UInt64
        let cancellationToken: OperationCancellationToken
        var deadline: UInt64
        let element: AXUIElement
        let window: AXUIElement
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let isSecureField: Bool
        let originalText: String?
        let originalSelection: NSRange?
        let targetWatch: ComposerTargetWatch
        let editingGeneration: UInt64
        var caretMovementGeneration: UInt64 = 0
        var releaseTiming = ComposerReleaseTiming()
        /// The field's empty state is chrome that goes away when text arrives: an empty Chromium composer
        /// exposing only a phantom line break, or the hint a composer is known to show (`EmptyHintMemory`).
        var phantomEmpty: Bool
        var inlineDraft: InlineDraftTransaction?
        var inlineAttempted = false
        var inlineFinalOnly = false
        var inlineUnconfirmedPlan: InlineDraftTransaction.Plan?
        var inlineSubmittedAny = false
        var inlineAvoidPaste = false
        var chromium = false
        var inlineClipboardLease: UUID?
        var inlineClipboardPasteConfirmed = true
        var snapshotDraft: SnapshotDraftPlanner?
        let snapshotMarker = ComposerSnapshotMarker()
        var snapshotSelectedOriginal: String?
    }

    private var nextIdentifier: UInt64 = 0
    private let axQueue = DispatchQueue(label: "com.voicepointer.ax.composer", qos: .userInitiated)
    private let axQueueKey = DispatchSpecificKey<Bool>()
    private var axQueueTestFixture: AXQueueTestFixture?
    @MainActor private var clipboardTransfer: ClipboardTransfer { axQueueTestFixture?.replay?.clipboard ?? ClipboardTransfer.shared }
    private var writeRuntime: InlineWriteRuntime { axQueueTestFixture?.replay?.runtime ?? InlineWriteRuntime.shared }
    private var activeSession: Session?
    /// A clear receipt belongs to the exact AX field and window that armed it. Retained on the
    /// serial AX worker so a new session at the same target can reuse it without trusting PID/text alone.
    private struct TargetBoundClearArm {
        let receipt: ClearArmRecord
        let element: AXUIElement
        let window: AXUIElement
    }
    private enum ClearArmMatch: String {
        case none, expired, targetMismatch, textMismatch, matched
    }
    private var clearArm: TargetBoundClearArm?
    /// One explicit follow-up send may consume an empty-speech timeout. Kept only
    /// on the AX worker, bound to the exact field/window and readable snapshot.
    private struct EmptySpeechSendRetry {
        let nextSessionIdentifier: UInt64
        let processIdentifier: pid_t
        let element: AXUIElement
        let window: AXUIElement
        let value: String
        let editingGeneration: UInt64
        let expiresAt: UInt64
    }
    private var emptySpeechSendRetry: EmptySpeechSendRetry?
    private var extraQuietHistory = ComposerExtraQuietHistory() // AX-worker confined.
    private var sendLastChangeMilliseconds = -1
    private var sendUsedExtraQuiet = false
    /// Empty-state hints of hint-as-value composers (ChatGPT for Mac), per process; see `EmptyHintMemory`.
    /// AX-worker confined, like `activeSession`.
    private var hintMemory = EmptyHintMemory()
    private var chromiumCache: [String: Bool] = [:]
    private var diagnosedChromium: Set<String> = []
    /// Last confirmed write per input field, RAM only and AX-worker confined.
    private struct CaretReceipt {
        let pid: pid_t
        let element: AXUIElement
        let document: String
        let removedDocument: String
        let expected: Int
        let removedExpected: Int
        let movementGeneration: UInt64
    }
    private var caretReceipts: [CaretReceipt] = []
    /// Learning from the person's own corrections (`KeptDeliveryReporting`). The two mailboxes are filled on
    /// the AX worker and emptied from the coordinator, so they sit behind `learningLock`; each holds one
    /// receipt for one session. `lastKeptField` (which field the last kept dictation went to, no text) is
    /// AX-worker confined, like `activeSession`.
    private let learningLock = NSLock()
    private var keptBaselineMailbox: (session: UInt64, baseline: KeptDictationBaseline)?
    private var revisitMailbox: (session: UInt64, sample: FieldRevisitSample)?
    private var lastKeptField: (processIdentifier: pid_t, element: AXUIElement, baselineID: UUID, at: UInt64)?
    private let axWorker = AXSerialWorker()
    private var operationToken: OperationCancellationToken?
    private var operationDeadline: UInt64 = .max
    private let requiredTargetPID: pid_t?
    private let editingIntentClock = EditingIntentClock.shared
    public init() {
        requiredTargetPID = nil
        axQueue.setSpecific(key: axQueueKey, value: true)
    }

    /// Pins integration probes to their disposable editor, even if the user
    /// switches applications while a session is being acquired.
    @_spi(Testing)
    public init(testTargetPID: pid_t) {
        precondition(testTargetPID > 0 && testTargetPID != getpid())
        requiredTargetPID = testTargetPID
        axQueue.setSpecific(key: axQueueKey, value: true)
    }

    @_spi(Testing)
    public convenience init(testReplayIO: any ComposerReplayIO) {
        self.init()
        axQueueTestFixture = AXQueueTestFixture(replay: testReplayIO)
    }

    /// Passive AX readers can be reached from an axQueue callback (the Doubao
    /// reference reader). Dispatching synchronously to that same queue traps.
    private func onAXQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: axQueueKey) == true { return operation() }
        return axQueue.sync(execute: operation)
    }

    /// Synthetic proxies and attribute replies only: no AX messaging, editor,
    /// workspace lookup, clipboard, or keyboard event is used by this check.
    @_spi(Testing)
    public static func testAXQueueReentrancy() async -> Bool {
        let executor = MacOSComposerActionExecutor()
        let fixture = AXQueueTestFixture()
        let token = OperationCancellationToken()
        executor.axQueueTestFixture = fixture
        executor.operationToken = token
        let offQueueRead = executor.copyAttribute(fixture.element, kAXRoleAttribute as CFString) as? String
        return await withCheckedContinuation { continuation in
            executor.axQueue.async {
                let onQueueRead = executor.copyAttribute(fixture.element, kAXRoleAttribute as CFString) as? String
                let validated = executor.validate(element: fixture.element, window: fixture.window,
                                                  processIdentifier: fixture.processIdentifier)
                token.cancel()
                let cancelledRead = executor.copyAttribute(fixture.element, kAXRoleAttribute as CFString)
                continuation.resume(returning: offQueueRead == kAXTextAreaRole && onQueueRead == kAXTextAreaRole &&
                    validated && fixture.reads > 2 && fixture.allReadsOnQueue && cancelledRead == nil)
            }
        }
    }

    private final class AXQueueTestFixture: @unchecked Sendable {
        let replay: (any ComposerReplayIO)?
        init(replay: (any ComposerReplayIO)? = nil) { self.replay = replay }
        // AXUIElementCreateApplication constructs local proxies; every read
        // below is answered in memory before any AX messaging call.
        let processIdentifier: pid_t = 999_999
        let application = AXUIElementCreateApplication(999_999)
        let element = AXUIElementCreateApplication(999_998)
        let window = AXUIElementCreateApplication(999_997)
        var reads = 0
        var allReadsOnQueue = true

        func copyAttribute(_ source: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
            if CFEqual(source, application), attribute == kAXFocusedUIElementAttribute as CFString {
                if replay?.read("ReplayNoFocusedElement") as? Bool == true { return nil }
                return element
            }
            guard CFEqual(source, element) else { return nil }
            if attribute == kAXRoleAttribute as CFString,
               replay?.read("ReplayRoleUnreadable") as? Bool == true { return nil }
            if let result = replay?.read(attribute as String) { return result }
            switch attribute as String {
            case kAXWindowAttribute: return window
            case kAXRoleAttribute: return kAXTextAreaRole as CFString
            case "AXEditable", kAXEnabledAttribute: return kCFBooleanTrue
            default: return nil
            }
        }
    }

    public func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
        await beginSession(cancellationToken: cancellationToken, target: nil)
    }

    public func beginSession(cancellationToken: OperationCancellationToken, target: FrozenInputTarget?) async -> ComposerSessionStartResult {
        await beginSession(cancellationToken: cancellationToken, target: target, onTargetInvalidated: {})
    }

    public func beginSession(cancellationToken: OperationCancellationToken, target: FrozenInputTarget?, onTargetInvalidated: @escaping @Sendable () -> Void) async -> ComposerSessionStartResult {
        guard !cancellationToken.isCancelled else { return .cancelled }
        let deadline = DispatchTime.now().uptimeNanoseconds + 600_000_000
        let result = await axWorker.runBounded(nanoseconds: 600_000_000) { [self] in
            await beginSessionOnWorker(cancellationToken: cancellationToken, target: target, deadline: deadline, onTargetInvalidated: onTargetInvalidated)
        }
        guard let result else { cancellationToken.cancel(); return .timedOut }
        return result
    }

    private func beginSessionOnWorker(cancellationToken: OperationCancellationToken, target: FrozenInputTarget?, deadline: UInt64, onTargetInvalidated: @escaping @Sendable () -> Void) async -> ComposerSessionStartResult {
        operationToken = cancellationToken
        operationDeadline = deadline
        defer { operationToken = nil; operationDeadline = .max }
        guard !cancellationToken.isCancelled else { return .cancelled }
        if let previous = activeSession { await releaseInlineClipboard(previous) }
        let clipboardStartCount = await clipboardTransfer.changeCount
        let result = beginSessionSync(cancellationToken: cancellationToken, target: target, deadline: deadline, onTargetInvalidated: onTargetInvalidated)
        if case .ready(let token) = result, var current = session(matching: token),
           current.chromium, !current.inlineFinalOnly {
            do {
                current.inlineClipboardLease = try await clipboardTransfer.reserveDraft(expectedChangeCount: clipboardStartCount)
                current.snapshotMarker.mark() // Frozen route survives a later lost clipboard lease.
            } catch {
                current.inlineFinalOnly = true
                RuntimeTrace.record("composer draft clipboard reason=clipboardUnavailable finalOnly=true")
            }
            storeInline(current)
        }
        if cancellationToken.isCancelled {
            if case .ready(let session) = result { cancel(session: session) }
            return .cancelled
        }
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            if case .ready(let session) = result { cancel(session: session) }
            return .timedOut
        }
        return result
    }

    private func beginSessionSync(
        cancellationToken: OperationCancellationToken,
        target: FrozenInputTarget?,
        deadline: UInt64,
        onTargetInvalidated: @escaping @Sendable () -> Void
    ) -> ComposerSessionStartResult {
        let editingGeneration = editingIntentClock.snapshot()
        let caretMovementGeneration = CaretMovementIntentClock.shared.snapshot()
        guard !cancellationToken.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline else { return .timedOut }
        guard axQueueTestFixture?.replay != nil || AccessibilityPermission.isTrusted else {
            RuntimeTrace.record("composer session rejected reason=accessibilityUnavailable")
            return .forFailure(.accessibilityUnavailable)
        }
        let application = axQueueTestFixture?.replay == nil ? NSWorkspace.shared.frontmostApplication : nil
        guard application != nil || axQueueTestFixture?.replay != nil else {
            RuntimeTrace.record("composer session rejected reason=noFrontmostApplication")
            return .forFailure(.noFrontmostApplication)
        }
        let processIdentifier = axQueueTestFixture?.processIdentifier ?? application!.processIdentifier
        let acquisitionBundleID = axQueueTestFixture?.replay?.bundleIdentifier ?? application?.bundleIdentifier
        // In-process AX invokes AppKit directly on this background worker.
        // VoicePointer is never its own editing target; reject it before any
        // AX traversal rather than risking TextKit locks against the main UI.
        guard processIdentifier != getpid(),
              requiredTargetPID == nil || requiredTargetPID == processIdentifier else {
            RuntimeTrace.record("composer session rejected reason=wrongProcess")
            return .forFailure(.wrongProcess, applicationBundleID: acquisitionBundleID)
        }
        let appElement = applicationElement(processIdentifier)
        guard let focused = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString) else {
            RuntimeTrace.record("composer session rejected reason=noFocusedElement pid=\(processIdentifier)")
            return .forFailure(.noFocusedElement, applicationBundleID: acquisitionBundleID)
        }
        let secureField = isSecure(focused)
        guard isEditable(focused) else {
            RuntimeTrace.record("composer session rejected reason=notEditable pid=\(processIdentifier)")
            return .forFailure(.notEditable, applicationBundleID: acquisitionBundleID,
                               focusedRole: stringAttribute(focused, kAXRoleAttribute as CFString),
                               focusedSubrole: stringAttribute(focused, kAXSubroleAttribute as CFString))
        }
        // The physical target was frozen at focus resolution. If it no longer
        // matches the currently focused editor, fail without refocusing and
        // without falling back to any other element.
        if let target, !CFEqual(target.element, focused) {
            RuntimeTrace.record("composer session rejected reason=frozenTargetMismatch pid=\(processIdentifier)")
            return .forFailure(.frozenTargetMismatch)
        }
        // Freeze the enclosing window element; required to be non-null so the
        // session can later verify the target did not move between windows.
        guard let window = elementAttribute(focused, kAXWindowAttribute as CFString) else {
            RuntimeTrace.record("composer session rejected reason=noTargetWindow pid=\(processIdentifier)")
            return .forFailure(.noTargetWindow)
        }

        // AXValue is not guaranteed to be the editor contents: WebKit/Electron
        // controls may expose their placeholder there while the field is empty.
        // Keep the snapshot semantic (real text) so Cancel can never restore UI
        // chrome as user content.
        let value = secureField ? nil : composerText(focused)
        let selection = secureField ? nil : rangeAttribute(focused, kAXSelectedTextRangeAttribute as CFString)
        guard operationMayProceed else { return cancellationToken.isCancelled ? .cancelled : .timedOut }
        nextIdentifier &+= 1
        let identifier = nextIdentifier
        let watch = axQueueTestFixture?.replay != nil ? ComposerTargetWatch.replayOnly() : ComposerTargetWatch.start(
            processIdentifier: processIdentifier,
            targetElement: focused,
            targetWindow: window,
            cancellationToken: cancellationToken,
            onInvalidated: onTargetInvalidated
        )
        guard let targetWatch = watch else {
            RuntimeTrace.record("composer session rejected reason=targetWatchUnavailable pid=\(processIdentifier)")
            return .forFailure(.targetWatchUnavailable)
        }
        // A composer whose empty state is a hint in AXValue (ChatGPT for Mac) drops the hint when text
        // arrives. Once that hint is recognized the field counts as empty, like a phantom line break.
        let bundleIdentifier = axQueueTestFixture?.replay?.bundleIdentifier ?? application?.bundleIdentifier
        let emptyHint = hintMemory.recognizesAtStart(
            value: value, selection: selection, processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier)
        var candidate = Session(
            identifier: identifier,
            cancellationToken: cancellationToken,
            deadline: .max,
            element: focused,
            window: window,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            isSecureField: secureField,
            originalText: value,
            originalSelection: selection,
            targetWatch: targetWatch,
            editingGeneration: editingGeneration,
            phantomEmpty: ComposerTextNormalizer.isPhantomEmpty(value, selection: selection) || emptyHint
        )
        candidate.caretMovementGeneration = caretMovementGeneration
        candidate.chromium = axQueueTestFixture?.replay?.chromium ?? isChromium(application: application!, element: focused)
        candidate.inlineFinalOnly = !InlineWritePolicy.allows(bundle: bundleIdentifier, chromium: candidate.chromium,
            automaticallyDenied: writeRuntime.isDenied(bundleIdentifier))
        if secureField || systemSecureInputEnabled {
            candidate.inlineFinalOnly = true
            RuntimeTrace.record("composer input security field=\(secureField ? "secure" : "ordinary") systemSecure=\(systemSecureInputEnabled ? 1 : 0) delivery=finalOnly")
        }
        if candidate.chromium, !candidate.inlineFinalOnly, let selection, selection.length > 0 {
            candidate.snapshotSelectedOriginal = copyAttribute(candidate.element, kAXSelectedTextAttribute as CFString) as? String
        }
        guard !cancellationToken.isCancelled, validate(candidate), operationMayProceed else {
            targetWatch.stop()
            RuntimeTrace.record("composer session rejected reason=targetChangedDuringAcquire pid=\(processIdentifier)")
            return .forFailure(.targetChangedDuringAcquire)
        }
        if !secureField { recordCaretDrift(candidate, document: candidate.phantomEmpty ? "" : value, selection: selection) }
        activeSession?.targetWatch.stop()
        activeSession = candidate
        if !secureField, candidate.chromium, let bundleIdentifier, !diagnosedChromium.contains(bundleIdentifier) {
            if diagnosedChromium.count >= 64 { diagnosedChromium.removeAll() }
            diagnosedChromium.insert(bundleIdentifier)
            recordEditorDiagnostics(candidate)
        }
        if !secureField { fileRevisit(for: candidate, value: value) }
        let selectionDescription = selection.map { "\($0.location):\($0.length)" } ?? "nil"
        RuntimeTrace.record(
            "composer session began pid=\(processIdentifier) bundle=\(bundleIdentifier ?? "nil") " +
            "valueReadable=\(value != nil) originalUTF16=\((value as NSString?)?.length ?? -1) " +
            "selection=\(selectionDescription) phantomEmpty=\(candidate.phantomEmpty) emptyHint=\(emptyHint)"
        )
        return .ready(ComposerActionSession(identifier: identifier, cancellationToken: cancellationToken, targetWatch: targetWatch, releaseTiming: candidate.releaseTiming, applicationBundleID: bundleIdentifier, snapshotMarker: candidate.snapshotMarker, isSecureField: secureField))
    }

    public func perform(
        _ action: VoiceReleaseAction,
        session token: ComposerActionSession?
    ) async -> ComposerActionOutcome {
        guard let token else { return .targetChanged }
        token.noteRelease()
        if action == .send { token.beginExternalSend() }
        // Send: settle (≤4s) + one observation (1.2s) + at most one swallowed-Return retry (≈1.4s).
        // Cancel: settle (≤1.65s) + one native Undo, or (second swipe) select-all + Delete + one observation (≈0.8s).
        let actionBudget: UInt64 = action == .send ? 7_000_000_000 : 4_000_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + actionBudget
        let result = await axWorker.runBounded(nanoseconds: actionBudget) { [self] in
            await performOnWorker(action, session: token, deadline: deadline)
        }
        guard let result else {
            cancel(session: token)
            RuntimeTrace.record("composer action unresolved action=\(action.rawValue) retry=none")
            return .unresolvedOperation(action)
        }
        return result
    }

    private func performOnWorker(
        _ action: VoiceReleaseAction,
        session token: ComposerActionSession?,
        deadline: UInt64
    ) async -> ComposerActionOutcome {
        operationToken = token?.cancellationToken
        operationDeadline = deadline
        defer { operationToken = nil; operationDeadline = .max }
        guard operationMayProceed else { emptySpeechSendRetry = nil; return .targetChanged }
        guard action != .stop else {
            emptySpeechSendRetry = nil
            cancel(session: token)
            return .kept
        }
        guard let token, let storedSession = session(matching: token) else {
            return .targetChanged
        }
        var session = storedSession
        session.deadline = deadline
        activeSession = session
        defer { if action == .send { session.releaseTiming.finishExternalSend() } }
        defer {
            if action == .send {
                RuntimeTrace.record(DoubaoDoneSignalObservation.summary(
                    clock: session.releaseTiming, lastChangeMilliseconds: sendLastChangeMilliseconds))
            }
        }
        guard !session.cancellationToken.isCancelled else { return .targetChanged }
        RuntimeTrace.record(
            "composer external action begin action=\(action.rawValue) pid=\(session.processIdentifier)"
        )
        if session.isSecureField {
            // External IME owns its text. Do not read a password to decide whether
            // the user's explicit Return/Undo is allowed, and never retry it.
            let outcome = secureAction(action, session: session)
            await finish(session)
            return outcome
        }
        // A gesture the meter heard nothing in leaves the IME nothing to commit late, so Cancel need not
        // wait out the usual 800 ms (the second swipe of a clear is otherwise slow for no reason).
        let heard = GestureSpeechActivity.shared.heard()
        if let retry = takeEmptySpeechSendRetry(session, action: action, heard: heard) {
            sendLastChangeMilliseconds = -1
            sendUsedExtraQuiet = false
            RuntimeTrace.record("composer send expedited reason=emptySpeechRetry")
            let outcome = await sendCurrentInput(from: session, settledText: retry.value,
                expectedEditingGeneration: retry.editingGeneration, requireDoubaoText: false)
            await finish(session)
            return outcome
        }
        let minimumSettleMilliseconds = SilentSendPolicy.externalSettleMilliseconds(action: action, heard: heard)
        let settleResult = await waitForDictationToSettle(
            session,
            minimumMilliseconds: minimumSettleMilliseconds,
            adaptiveSend: action == .send,
            requiresFirstTextChange: action == .send && heard != .silence,
            heard: action == .send ? heard : nil
        )
        let settledText: String?
        var requireDoubaoText = false
        switch settleResult {
        case .settled(let value, let needsSpeechText):
            requireDoubaoText = needsSpeechText
            RuntimeTrace.record(
                "composer external settle outcome=settled action=\(action.rawValue) " +
                "valueReadable=\(value != nil) utf16=\(value.map { ($0 as NSString).length } ?? -1)"
            )
            settledText = value
        case .noTextLanded:
            if action == .send, heard == .speech,
               session.releaseTiming.elapsedMilliseconds() >= 3_000,
               isSessionActive(session), validate(session), !focusMovedBeforeReturn(session),
               let original = session.originalText,
               session.phantomEmpty || isEffectivelyEmpty(original, processIdentifier: session.processIdentifier),
               let value = composerText(session.element),
               isEffectivelyEmpty(value, processIdentifier: session.processIdentifier),
               editingIntentClock.snapshot() == session.editingGeneration, operationMayProceed {
                emptySpeechSendRetry = EmptySpeechSendRetry(nextSessionIdentifier: nextIdentifier &+ 1,
                    processIdentifier: session.processIdentifier,
                    element: session.element, window: session.window, value: value,
                    editingGeneration: session.editingGeneration,
                    expiresAt: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
            }
            cancel(session: token)
            await finish(session)
            return .doubaoTextTimeout
        case .notSettled:
            if action == .send,
               session.originalText == nil,
               validate(session),
               composerText(session.element) == nil {
                // Some attachment-only editors expose no AXValue at all.
                // After the bounded settle window, honor the explicit Send
                // gesture if the exact original target still owns focus.
                let outcome = await sendCurrentInput(from: session, settledText: nil)
                await finish(session)
                return outcome
            }
            cancel(session: token)
            await finish(session)
            RuntimeTrace.record("composer settle timeout action=\(action.rawValue) submitted=false")
            return .dictationNotSettled
        case .targetInvalid, .cancelled:
            let result = action == .send ? beforeReturnInvalidOutcome(session) : .targetChanged
            RuntimeTrace.record(
                "composer external settle outcome=targetInvalidOrCancelled action=\(action.rawValue)"
            )
            cancel(session: token)
            await finish(session)
            return result
        }

        let outcome: ComposerActionOutcome
        switch action {
        case .stop:
            outcome = .kept
        case .send:
            guard validate(session) else {
                let result = beforeReturnInvalidOutcome(session)
                await finish(session)
                return result
            }
            outcome = await sendCurrentInput(from: session, settledText: settledText,
                                            retryIfSwallowed: true, requireDoubaoText: requireDoubaoText)
        case .cancel:
            guard let settledText else {
                cancel(session: token)
                await finish(session)
                return .dictationNotSettled
            }
            outcome = await cancelOrClear(from: session, settledText: settledText)
        }
        if !session.isSecureField, outcome == .sendStillPresent {
            writeRuntime.noteFailure(bundle: session.bundleIdentifier, reason: .sendStillPresent)
            if session.chromium { recordEditorDiagnostics(session) }
        }
        if [.sendUnconfirmed, .cancelUnconfirmed].contains(outcome), session.chromium { recordEditorDiagnostics(session) }
        await finish(session)
        return outcome
    }

    // MARK: - TranscriptDelivering (I04E native transcript delivery transaction)

    public func deliver(
        text: String,
        action: VoiceReleaseAction,
        session: ComposerActionSession?
    ) async -> ComposerActionOutcome {
        guard let matching = session else { return .deliveryFailed }
        matching.noteRelease()
        // One paste confirmation, an 800ms landing wait and one guarded Return retry.
        let deliveryBudget: UInt64 = action == .send ? 5_000_000_000 : 3_000_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + deliveryBudget
        let outcome = await axWorker.runBounded(nanoseconds: deliveryBudget) { [self] in
            await deliveryOnWorker(text: text, action: action, session: matching, deadline: deadline)
        }
        guard let outcome else {
            cancel(session: matching)
            return matching.snapshotMarker.isActive ? .deliveryFailed : .deliveryUnconfirmed
        }
        return outcome
    }

    private func deliveryOnWorker(
        text: String,
        action: VoiceReleaseAction,
        session matching: ComposerActionSession,
        deadline: UInt64
    ) async -> ComposerActionOutcome {
        operationToken = matching.cancellationToken
        operationDeadline = deadline
        sendLastChangeMilliseconds = -1 // Native delivery has no settle observer.
        sendUsedExtraQuiet = false
        defer {
            operationToken = nil
            operationDeadline = .max
        }
        guard var session = self.session(matching: matching) else { return .deliveryFailed }
        session.deadline = deadline
        activeSession = session
        let outcome: ComposerActionOutcome
        if session.isSecureField {
            outcome = deliverSecure(text: text, action: action, session: session)
        } else if session.inlineAttempted || usesSnapshotPaste(session) {
            outcome = await finishInlineOnWorker(text: text, action: action, session: matching)
        } else {
            outcome = await pasteAndAct(text: text, action: action, session: session)
        }
        if outcome == .sendStillPresent {
            writeRuntime.noteFailure(bundle: session.bundleIdentifier, reason: .sendStillPresent)
        } else if !session.isSecureField, outcome == .deliveryUnconfirmed {
            writeRuntime.noteFailure(bundle: session.bundleIdentifier, reason: .deliveryUnconfirmed,
                hintRelated: session.phantomEmpty)
        }
        if !session.isSecureField, session.chromium && [.deliveryUnconfirmed, .sendUnconfirmed, .sendStillPresent, .cancelUnconfirmed].contains(outcome) {
            recordEditorDiagnostics(session)
        }
        await finish(session)
        return outcome
    }

    /// Hidden controls accept ordinary keyboard text but cannot provide the
    /// document snapshot used by our normal editors. Type once at the current
    /// caret, without selecting/deleting old content, a clipboard, or a readback.
    private func deliverSecure(text: String, action: VoiceReleaseAction, session: Session) -> ComposerActionOutcome {
        if action == .cancel { return .nothingToCancel }
        guard isSessionActive(session), validate(session) else { return .targetChanged }
        // A control character must never turn a Stop into Return/Tab/another
        // action. Password controls are single-line; reject before any event.
        guard text.utf16.count <= 50_000,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return .deliveryFailed }
        if !text.isEmpty {
            guard typeSecureText(text, session: session) else { return .deliveryUnconfirmed }
            RuntimeTrace.record("composer secure input result=submitted")
        }
        return action == .send ? secureAction(.send, session: session) : .inputSubmitted
    }

    private func secureAction(_ action: VoiceReleaseAction, session: Session) -> ComposerActionOutcome {
        guard isSessionActive(session), validate(session) else { return .targetChanged }
        switch action {
        case .stop: return .inputSubmitted
        case .cancel:
            // No visible span proves which edit belongs to an external IME.
            // Do not undo a pre-existing password or a newer manual edit.
            return .unsafeToCancel
        case .send:
            guard !focusMovedBeforeReturn(session),
                  postKey(36, to: session.processIdentifier, token: session.cancellationToken, onPosted: {
                      session.releaseTiming.noteReturnPosted(at: DispatchTime.now().uptimeNanoseconds)
                      session.targetWatch.noteReturnPosted()
                  }) else { return beforeReturnInvalidOutcome(session) }
            RuntimeTrace.record("composer send returnPosted secure=1 retry=0")
            return .sendUnconfirmed
        }
    }

    private func typeSecureText(_ text: String, session: Session) -> Bool {
        if let replay = axQueueTestFixture?.replay {
            guard operationMayProceed, validate(session) else { return false }
            return session.cancellationToken.commitIfValid { replay.typeSecureText(text) } ?? false
        }
        guard EventAccessPermission.canPost else { return false }
        // Quartz event text is bounded; split on scalar boundaries, never in a
        // UTF-16 surrogate pair. Each posted pair carries its own text payload.
        var chunks: [[UniChar]] = [], chunk: [UniChar] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 { chunks.append(chunk); chunk.removeAll(keepingCapacity: true) }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        for units in chunks {
            guard operationMayProceed, isSessionActive(session), validate(session),
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            for event in [down, up] {
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.setIntegerValueField(.eventSourceUserData, value: voicePointerSyntheticEventUserData)
            }
            guard session.cancellationToken.commitIfValid({
                guard DispatchTime.now().uptimeNanoseconds < operationDeadline else { return false }
                down.postToPid(session.processIdentifier); up.postToPid(session.processIdentifier)
                return true
            }) == true else { return false }
        }
        return true
    }

    private func pasteAndAct(
        text: String,
        action: VoiceReleaseAction,
        session: Session
    ) async -> ComposerActionOutcome {
        // A down-swipe never writes: nothing has reached the field yet, so what the recognizer heard is
        // dropped instead of being pasted and undone again.
        if action == .cancel { return await cancelWithoutDelivery(text: text, session: session) }
        // Recognizer noise from a gesture nobody spoke in is not pasted (`SilentTranscriptPolicy`).
        var text = text
        if SilentTranscriptPolicy.shouldDrop(
            transcriptUTF16: text.utf16.count, peakLevel: GestureSpeechActivity.shared.loudestPeak()
        ) {
            RuntimeTrace.record("composer delivery dropped silentTranscript utf16=\(text.utf16.count)")
            text = ""
        }
        // Preflight: session alive, target valid, text/selection match capture.
        guard isSessionActive(session), validate(session) else { return .targetChanged }
        let currentText = composerText(session.element)
        guard currentText == session.originalText else { return .deliveryFailed }
        // An empty voice result still carries the user's explicit Send
        // gesture. The editor may contain an image that AXValue cannot read;
        // Return belongs to the original focused editor even if it exposes
        // no text selection.
        if text.isEmpty {
            guard validate(session) else { return .targetChanged }
            switch action {
            case .stop: return .kept
            case .send: return await sendCurrentInput(from: session, settledText: currentText)
            case .cancel: return .nothingToCancel // handled above: a cancel never delivers
            }
        }
        guard let originalText = session.originalText,
              let originalSelection = session.originalSelection,
              let currentRange = rangeAttribute(session.element, kAXSelectedTextRangeAttribute as CFString),
              currentRange == originalSelection,
              Range(originalSelection, in: originalText) != nil,
              text.utf16.count <= 50_000
        else { return .deliveryFailed }
        // Guard target again after all AX reads.
        guard validate(session) else { return .targetChanged }

        let expected = (originalText as NSString).replacingCharacters(
            in: originalSelection,
            with: text
        )

        if expected == originalText {
            // No paste; only the single native action runs; the one edit is not claimed.
            switch action {
            case .stop:
                return .kept
            case .send:
                return await sendCurrentInput(from: session, settledText: originalText)
            case .cancel:
                return .nothingToCancel // handled above: a cancel never delivers
            }
        }

        let lease: UUID
        do {
            lease = try await clipboardTransfer.begin(text: text)
        } catch {
            return .deliveryFailed
        }

        // Recheck all preflight after awaiting clipboard begin.
        guard isSessionActive(session),
              validate(session),
              session.originalText != nil,
              session.originalSelection != nil,
              composerText(session.element) == originalText,
              rangeAttribute(session.element, kAXSelectedTextRangeAttribute as CFString) == originalSelection
        else {
            _ = await clipboardTransfer.restore(id: lease)
            return .targetChanged
        }
        // Recheck target immediately before posting the paste keystroke.
        guard validate(session) else {
            _ = await clipboardTransfer.restore(id: lease)
            return .targetChanged
        }

        guard postKey(9, to: session.processIdentifier, token: session.cancellationToken, flags: .maskCommand) else {
            _ = await clipboardTransfer.restore(id: lease)
            return .eventPostFailed
        }

        // After the paste keystroke the editor's AXValue can transiently
        // read nil or a stale pre-paste value. A temporary unreadable or
        // mismatched observation must not abort the wait: only cancellation,
        // session/target invalidation, or the bounded 1 s deadline stops it.
        // Confirmation requires two consecutive observations exactly equal
        // to the expected text; no fuzzy, trimmed, or substring matching.
        RuntimeTrace.record(
            "composer delivery pastePosted originalUTF16=\(originalText.utf16.count) " +
            "expectedUTF16=\(expected.utf16.count)"
        )
        let pollDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        // An empty Chromium composer drops its phantom line break when the paste
        // lands, so exactly `text` is the one other exact proof of delivery.
        // The first time a hint-as-value composer is met, "exactly the dictated text and nothing else"
        // is the same proof: it dropped its hint when the paste landed (`EmptyHintMemory`).
        let hintSuspect = !session.phantomEmpty
            && EmptyHintMemory.mayShowHint(original: originalText, selection: originalSelection)
        var observation = ComposerDeliveryObservation(
            expected: expected, alternate: (session.phantomEmpty || hintSuspect) ? text : nil,
            original: originalSelection.length == 0 ? originalText : nil, inserted: text,
            expectedInsertionLocation: originalSelection.location)
        var lastObserved: String?
        var sampleIndex = 0
        var confirmed = false
        var stoppedForCancellation = false
        var stoppedForSessionInvalid = false
        var stoppedForTargetInvalid = false
        while DispatchTime.now().uptimeNanoseconds < pollDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            sampleIndex += 1
            if Task.isCancelled || session.cancellationToken.isCancelled {
                stoppedForCancellation = true
                break
            }
            guard isSessionActive(session) else {
                stoppedForSessionInvalid = true
                break
            }
            guard validate(session) else {
                stoppedForTargetInvalid = true
                break
            }
            let current = composerText(session.element)
            // Recheck target after the AX read before counting a sample.
            guard validate(session) else {
                stoppedForTargetInvalid = true
                break
            }
            lastObserved = current
            if observation.observe(current) {
                confirmed = true
                break
            }
            // Still original, nil, or another value: keep waiting until the
            // bounded deadline; never retry the paste and never act on a
            // single exact observation.
        }

        // Counts-only termination diagnostics: no text, hash, selection,
        // clipboard, or key content is ever logged.
        let equalExpected = lastObserved == expected
        let equalOriginal = lastObserved == originalText
        if confirmed, let actual = observation.matchedInsertionLocation {
            RuntimeTrace.record("composer delivery confirm=positionShifted shift=\(actual - originalSelection.location)")
        } else if !confirmed, let lastObserved {
            RuntimeTrace.record("composer delivery difference " + ComposerDeliveryObservation.mismatchCounts(
                expected: expected, observed: lastObserved, insertionLocation: originalSelection.location))
        }
        let terminationReason: String
        if confirmed {
            terminationReason = "confirmed"
        } else if stoppedForCancellation {
            terminationReason = "cancelled"
        } else if stoppedForSessionInvalid {
            terminationReason = "sessionInvalid"
        } else if stoppedForTargetInvalid {
            terminationReason = "targetInvalid"
        } else if lastObserved == nil {
            terminationReason = "unreadableTimeout"
        } else if equalOriginal {
            terminationReason = "unchangedTimeout"
        } else {
            terminationReason = "mismatchTimeout"
        }
        RuntimeTrace.record(
            "composer delivery termination reason=\(terminationReason) sample=\(sampleIndex) " +
            "originalUTF16=\(originalText.utf16.count) expectedUTF16=\(expected.utf16.count) " +
            "observedUTF16=\(lastObserved.map { $0.utf16.count } ?? -1) " +
            "equalExpected=\(equalExpected) equalOriginal=\(equalOriginal) " +
            "phantomEmpty=\(session.phantomEmpty) matchedPhantom=\(confirmed && observation.matchedAlternate) " +
            "tokenCancelled=\(session.cancellationToken.isCancelled)"
        )

        if confirmed, hintSuspect, observation.matchedAlternate,
           hintMemory.noteVanished(
               original: originalText, selection: originalSelection, expectedDocument: expected,
               observed: text, processIdentifier: session.processIdentifier) {
            RuntimeTrace.record("composer delivery hint=vanished")
        }
        if confirmed { writeRuntime.notePasteConfirmed(bundle: session.bundleIdentifier) }
        else if !(hintSuspect && lastObserved == text), equalOriginal && !stoppedForCancellation && !stoppedForTargetInvalid && !stoppedForSessionInvalid {
            writeRuntime.noteFailure(bundle: session.bundleIdentifier, reason: .unchangedPaste)
        }

        if let settledText = lastObserved, confirmed {
            // Restore clipboard; restore() itself refuses to overwrite if the
            // user copied new content (returns false, ignored here).
            _ = await clipboardTransfer.restore(id: lease)
            if action != .cancel {
                let actual = observation.matchedAlternate ? 0 : (observation.matchedInsertionLocation ?? originalSelection.location)
                let end = NSRange(location: actual + text.utf16.count, length: 0)
                let repaired = settleInsertedCaret(session, document: settledText, expectedSelection: end)
                RuntimeTrace.record("composer delivery confirmed caretSettled=\(repaired) action=\(action.rawValue)")
                guard ComposerConfirmedDeliveryPolicy.permitsAction(documentConfirmed: confirmed, caretConfirmed: repaired) else {
                    return .deliveryUnconfirmed
                }
            }
            switch action {
            case .stop:
                recordKept(
                    session, path: "paste", document: settledText,
                    spanLocation: observation.matchedAlternate ? 0 : (observation.matchedInsertionLocation ?? originalSelection.location), delivered: text,
                    revertTexts: Self.replacedText(in: originalText, selection: originalSelection).map { [$0] } ?? [],
                    firstSeenHint: observation.matchedAlternate ? originalText : nil)
                return .kept
            case .send:
                return await sendCurrentInput(from: session, settledText: settledText, retryIfSwallowed: true)
            case .cancel:
                return .nothingToCancel // handled above: a cancel never delivers
            }
        }

        // Cancellation, target change, unexpected text, or timeout after the
        // paste: abandon the lease (clipboard keeps the transcript available)
        // and never send, undo, or retry.
        await clipboardTransfer.abandon(id: lease)
        if action != .cancel, let observed = lastObserved,
           observed.utf16.elementsEqual(text.utf16),
           editingIntentClock.snapshot() == session.editingGeneration {
            // Some Electron editors replace a phantom AXValue when pasting.
            // The visible result is exactly our transcript, although the
            // original snapshot cannot be reconciled. Only restore the caret;
            // never treat this as confirmed delivery or post Return.
            let end = NSRange(location: text.utf16.count, length: 0)
            let repaired = settleInsertedCaret(session, document: observed, expectedSelection: end)
            RuntimeTrace.record("composer delivery mismatch caretRepair=\(repaired) retry=none")
        }
        return .deliveryUnconfirmed
    }

    /// A value write or paste can leave Electron's caret at the old offset.
    /// Never move a caret after physical editing intent, target change, or a
    /// document mismatch. AX success alone is insufficient: read the range
    /// and document back for caret repair. A caret failure is not evidence
    /// that a separately confirmed paste failed; Send revalidates the document.
    private func settleInsertedCaret(
        _ session: Session, document: String, expectedSelection: NSRange
    ) -> Bool {
        guard editingIntentClock.snapshot() == session.editingGeneration,
              isSessionActive(session), validate(session),
              let currentDocument = sessionDocument(session),
              currentDocument.utf16.elementsEqual(document.utf16),
              let currentSelection = rangeAttribute(session.element, kAXSelectedTextRangeAttribute as CFString) else {
            return false
        }
        if currentSelection != expectedSelection {
            guard setRangeAttribute(session.element, kAXSelectedTextRangeAttribute as CFString,
                                    range: expectedSelection) else { return false }
        }
        guard editingIntentClock.snapshot() == session.editingGeneration,
              validate(session),
              let verifiedDocument = sessionDocument(session),
              verifiedDocument.utf16.elementsEqual(document.utf16),
              rangeAttribute(session.element, kAXSelectedTextRangeAttribute as CFString) == expectedSelection else {
            return false
        }
        return true
    }

    // MARK: - Down-swipe: remove the dictation, or clear the field on the second swipe

    /// Down-swipe after an external (Doubao-style) dictation: the text is already in the field.
    private func cancelOrClear(from session: Session, settledText: String) async -> ComposerActionOutcome {
        // An unreadable original cannot show that nothing landed, so it counts as landed.
        let landed = session.originalText.map { $0 != settledText } ?? true
        return await downSwipe(session, text: settledText, landed: landed, transcriptUTF16: nil) {
            if session.chromium { return await self.removeExternalChromiumDictation(session, document: settledText) }
            return await self.undoAndConfirm(from: session, settledText: settledText)
        }
    }

    /// Down-swipe when nothing was written into the field before release (paste-final delivery, or an
    /// inline session that never wrote). What the recognizer heard is dropped: it is never pasted just
    /// to be undone again, which flickered, churned the clipboard and left a stray Undo entry behind.
    private func cancelWithoutDelivery(text: String, session: Session) async -> ComposerActionOutcome {
        guard isSessionActive(session), validate(session) else {
            RuntimeTrace.record("composer downSwipe failedTarget=invalid")
            return .targetChanged
        }
        guard let current = composerText(session.element) else { return .nothingToCancel }
        // The person typed while the disc was up: their edit stays untouched.
        guard current == session.originalText else {
            RuntimeTrace.record("composer downSwipe failedTarget=fieldChanged")
            return .targetChanged
        }
        return await downSwipe(
            session, text: current, landed: false, transcriptUTF16: text.utf16.count, undo: nil)
    }

    /// The one place every delivery path decides what a down-swipe does. The decision itself is the
    /// pure `ClearSwipePolicy`; this gathers its facts and performs the plan.
    private func downSwipe(
        _ session: Session,
        text: String,
        landed: Bool,
        transcriptUTF16: Int?,
        undo: (() async -> ComposerActionOutcome)?
    ) async -> ComposerActionOutcome {
        let pid = session.processIdentifier
        let heard = GestureSpeechActivity.shared.heard()
        let evidence = ClearSwipePolicy.evidence(
            fieldChanged: landed, heard: heard, transcriptUTF16: transcriptUTF16)
        let armMatch = clearArmMatch(session, text: text, now: DispatchTime.now().uptimeNanoseconds)
        let armed = armMatch == .matched
        let empty = isEffectivelyEmpty(text, processIdentifier: pid)
        let plan = ClearSwipePolicy.plan(evidence: evidence, armed: armed, fieldIsEmpty: empty)
        RuntimeTrace.record(
            "composer downSwipe plan=\(plan) evidence=\(evidence) heard=\(heard) armed=\(armed) " +
            "armMatch=\(armMatch.rawValue) fieldEmpty=\(empty) utf16=\((text as NSString).length)"
        )
        switch plan {
        case .removeDictation:
            guard let undo else { return .nothingToCancel }
            return await undo()
        case .discardDictation:
            armClear(session, text: text)
            return .removedCurrentDictation
        case .armOnly:
            armClear(session, text: text)
            return .clearArmed
        case .nothingToClear:
            clearArm = nil
            return .nothingToCancel
        case .clearField:
            clearArm = nil
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            let role = stringAttribute(session.element, kAXRoleAttribute as CFString)
            guard ClearSwipePolicy.allowsClear(
                bundleIdentifier: bundle, role: role, valueLength: (text as NSString).length) else {
                RuntimeTrace.record("composer clear skipped reason=notAChatField role=\(role ?? "nil")")
                return .nothingToCancel
            }
            return await clearInput(from: session, previousText: text)
        }
    }

    /// Uses only the captured AX references; the current target has already been validated.
    /// This is independent of validation of the new session: the previous arm must match too.
    private func clearArmMatch(_ session: Session, text: String, now: UInt64) -> ClearArmMatch {
        guard let arm = clearArm else { return .none }
        guard now < arm.receipt.expiresAt else { return .expired }
        guard arm.receipt.processIdentifier == session.processIdentifier,
              CFEqual(arm.element, session.element), CFEqual(arm.window, session.window) else {
            return .targetMismatch
        }
        return ClearSwipePolicy.isArmed(
            arm.receipt, processIdentifier: session.processIdentifier, text: text, now: now)
            ? .matched : .textMismatch
    }

    private func armClear(_ session: Session, text: String, alternate: String? = nil) {
        let receipt = ClearArmRecord(
            processIdentifier: session.processIdentifier, text: text, alternateText: alternate,
            expiresAt: DispatchTime.now().uptimeNanoseconds + ClearSwipePolicy.armWindowNanoseconds)
        clearArm = TargetBoundClearArm(receipt: receipt, element: session.element, window: session.window)
    }

    /// True when the text is only the field's empty state: nothing visible, or the hint this
    /// process's composer showed after a confirmed send or clear.
    private func isEffectivelyEmpty(_ text: String, processIdentifier: pid_t) -> Bool {
        ComposerTextNormalizer.isBlank(text) || hintMemory.isKnown(text, processIdentifier: processIdentifier)
    }

    /// One native Undo, then a look at the field so the result can be told apart: restored to how the
    /// field was before the dictation (a success worth a sound), changed some other way, or not
    /// changed at all. Either way the swipe arms the next one; the receipt accepts the pre-dictation
    /// text too, so an Undo that lands late does not cost the second swipe.
    private func undoAndConfirm(from session: Session, settledText: String) async -> ComposerActionOutcome {
        let submitted = await undoOnce(from: session)
        guard submitted == .undoSubmitted else { return submitted }
        var observed = settledText
        var restored = false
        for _ in 0..<8 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            guard isSessionActive(session) else { break }
            guard let text = composerText(session.element) else { continue }
            if text != settledText {
                observed = text
                restored = text == session.originalText
                break
            }
        }
        armClear(session, text: observed, alternate: session.originalText)
        RuntimeTrace.record(
            "composer undo observation=\(restored ? "restored" : (observed == settledText ? "unchanged" : "changed"))"
        )
        return restored ? .removedCurrentDictation : .undoSubmitted
    }

    /// Select All then Delete through the target's own editing, so its Undo brings the text back.
    /// Delete is sent only after the field itself reports everything selected; without that, a
    /// terminal-like target would lose one character instead of the text.
    private func clearInput(from session: Session, previousText: String) async -> ComposerActionOutcome {
        guard isSessionActive(session), validate(session) else { return .targetChanged }
        let length = (previousText as NSString).length
        guard postKey(0, to: session.processIdentifier, token: session.cancellationToken, flags: .maskCommand) else {
            return session.cancellationToken.isCancelled ? .targetChanged : .eventPostFailed
        }
        var selectedAll = false
        for _ in 0..<6 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return .targetChanged }
            guard isSessionActive(session), validate(session),
                  editingIntentClock.snapshot() == session.editingGeneration else { return .targetChanged }
            if let range = rangeAttribute(session.element, kAXSelectedTextRangeAttribute as CFString),
               range.location == 0 {
                let ordinaryFullSelection = range.length >= max(1, length - 1)
                // Some Chromium AXValues append two layout newlines and an object-replacement
                // marker. Command-A selects the actual text but not this synthetic tail.
                // Require an exact tail, exact prefix selection AND unchanged full AXValue;
                // never infer a complete selection from a shorter arbitrary range.
                let structuralTail = session.chromium
                    && previousText.hasSuffix("\n\n\u{FFFC}")
                    && length >= 4 && range.length == length - 3
                    && composerText(session.element) == previousText
                    && stringAttribute(session.element, kAXSelectedTextAttribute as CFString)
                        == (previousText as NSString).substring(to: range.length)
                if ordinaryFullSelection || structuralTail {
                    selectedAll = true
                    break
                }
            }
        }
        guard selectedAll else {
            RuntimeTrace.record("composer clear skipped reason=selectAllNotReflected")
            return .cancelUnconfirmed
        }
        guard postKey(51, to: session.processIdentifier, token: session.cancellationToken) else {
            return session.cancellationToken.isCancelled ? .targetChanged : .eventPostFailed
        }
        for _ in 0..<16 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return .targetChanged }
            guard isSessionActive(session) else { return .targetChanged }
            guard let text = composerText(session.element) else { continue }
            if isEffectivelyEmpty(text, processIdentifier: session.processIdentifier) {
                RuntimeTrace.record("composer clear confirmed clearedUTF16=\(length)")
                return .clearedCurrentInput
            }
            // A hint-as-value composer shows its empty-state hint once emptied. Everything was
            // selected before Delete, so a changed text with the caret back at 0:0 is that hint.
            if text != previousText, text.utf16.count < 200,
               let caret = rangeAttribute(session.element, kAXSelectedTextRangeAttribute as CFString),
               caret.location == 0, caret.length == 0 {
                hintMemory.learn(text, processIdentifier: session.processIdentifier)
                RuntimeTrace.record("composer clear confirmed clearedUTF16=\(length) hint=learned")
                return .clearedCurrentInput
            }
        }
        RuntimeTrace.record("composer clear unconfirmed")
        return .cancelUnconfirmed
    }

    private func undoOnce(from session: Session) async -> ComposerActionOutcome {
        // Chromium cancellation never touches its editor-wide undo stack.
        guard !session.chromium else { return .cancelUnconfirmed }
        guard isSessionActive(session), validate(session),
              composerText(session.element) != nil else {
            return .targetChanged
        }
        let posted = postKey(
            6,
            to: session.processIdentifier,
            token: session.cancellationToken,
            flags: .maskCommand
        )
        if posted {
            return .undoSubmitted
        }
        return session.cancellationToken.isCancelled ? .targetChanged : .eventPostFailed
    }

    public func cancel(session token: ComposerActionSession?) {
        guard let token else { return }
        token.finishExternalSend()
        // Invalidate before touching executor state. This is deliberately a
        // short, non-blocking operation so a queued AX request cannot delay
        // cancellation observed by the coordinator.
        token.cancellationToken.cancel()
        token.targetWatch?.stop()
        // A start that is not going to be used must not leave the look it took at the field behind.
        learningLock.withLock { revisitMailbox = nil }
        // The serial owner must finish any pending paste before deciding restore vs abandon.
        Task { [self] in
            await axWorker.run { [self] in
                if let current = session(matching: token) { await finish(current) }
            }
        }
    }

    private func waitForDictationToSettle(
        _ session: Session,
        minimumMilliseconds: Int,
        adaptiveSend: Bool = false,
        requiresFirstTextChange: Bool = false,
        heard: SpeechHeard? = nil
    ) async -> DictationSettleResult {
        guard isSessionActive(session), validate(session) else {
            return session.cancellationToken.isCancelled ? .cancelled : .targetInvalid
        }
        let settleStartedAt = session.releaseTiming.nowNanoseconds
        var settlePolicy = ComposerSettlePolicy(
            minimumMilliseconds: minimumMilliseconds, extendChangingSend: adaptiveSend,
            requiresFirstTextChange: requiresFirstTextChange, initialText: session.originalText
        )
        var timing = ComposerSettleTiming(clock: session.releaseTiming)
        var firstLandingLogged = false
        var firstSampleDecision: DoubaoExternalSendPolicy.FirstSampleDecision?
        var waitedForSpeechText = false
        if adaptiveSend { sendLastChangeMilliseconds = -1; sendUsedExtraQuiet = false }
        var sample = 0
        while sample < settlePolicy.maximumSamples && !settlePolicy.isFinished {
            defer { sample += 1 }
            // Keep the ordinary settle cadence unchanged. Only the last 100ms
            // of the stable nonempty fast path need finer polling to hit 600ms
            // without an extra 50ms rounding delay.
            let nearUnchangedDeadline = adaptiveSend &&
                (firstSampleDecision == .unchangedNonempty || firstSampleDecision == .emptyUnchanged) &&
                session.releaseTiming.elapsedMilliseconds() >= 500
            do { try await Task.sleep(for: .milliseconds(nearUnchangedDeadline ? 10 : 50)) }
            catch { return .cancelled }
            guard isSessionActive(session) else {
                return session.cancellationToken.isCancelled ? .cancelled : .notSettled
            }
            guard validate(session) else { return .targetInvalid }
            let currentValue = composerText(session.element)
            let observedChange = timing.observe(value: currentValue)
            if adaptiveSend {
                sendLastChangeMilliseconds = timing.lastChangeMilliseconds
                if observedChange && !sendUsedExtraQuiet && extraQuietHistory.shouldExtend(
                    processIdentifier: session.processIdentifier,
                    lastChangeMilliseconds: timing.lastChangeMilliseconds
                ) {
                    settlePolicy.extendQuietWindow()
                    sendUsedExtraQuiet = true
                    RuntimeTrace.record("composer settle extraQuiet=1")
                }
            }
            // Do not mistake the short gap between releasing the dictation
            // shortcut and the IME's final commit for a settled value. Real
            // hardware traces show that a short stable-looking gap can still
            // be too early. Send and range-sensitive Cancel both require the
            // explicit bounded settle policy before any side effect.
            // A nil AXValue is still an active/ambiguous composition state.
            // Do not let the elapsed minimum delay alone authorize Return;
            // require a readable value and consecutive stable observations.
            let observedAt = session.releaseTiming.nowNanoseconds
            let releaseElapsed = session.releaseTiming.elapsedMilliseconds(at: observedAt)
            if adaptiveSend && (releaseElapsed < 0 || releaseElapsed > 4_000) { break }
            let settleElapsed = adaptiveSend ? releaseElapsed
                : (observedAt >= settleStartedAt ? Int((observedAt - settleStartedAt) / 1_000_000) : -1)
            // V1 is the FIRST reliable sample at or after release+270ms. Until then
            // nothing can use a quiet baseline to authorize Return.
            if adaptiveSend, let heard {
                if session.releaseTiming.takeExpeditedSend() {
                    RuntimeTrace.record(
                        "composer send expedited reason=secondSwipe waitedMs=\(max(0, releaseElapsed))"
                    )
                    // A second upward gesture requests one immediate Return even
                    // when the frozen editor's readable value is empty or nil.
                    // Retain all target/session/focus identity checks.
                    guard isSessionActive(session), validate(session),
                          !focusMovedBeforeReturn(session) else {
                        return .targetInvalid
                    }
                    return .settled(currentValue, requireDoubaoText: false)
                }
                if firstSampleDecision == nil &&
                    releaseElapsed >= DoubaoExternalSendPolicy.firstSampleMilliseconds {
                    let originalEmpty = session.phantomEmpty || (session.originalText.map {
                        isEffectivelyEmpty($0, processIdentifier: session.processIdentifier)
                    } ?? true)
                    let firstEmpty = currentValue.map {
                        isEffectivelyEmpty($0, processIdentifier: session.processIdentifier)
                    } ?? true
                    let selected = DoubaoExternalSendPolicy.decide(
                        original: session.originalText, firstAfterRelease: currentValue,
                        originalWasEmpty: originalEmpty, firstIsEmpty: firstEmpty, heard: heard
                    )
                    firstSampleDecision = selected
                    waitedForSpeechText = selected == .waitForSpeechText
                    let decisionName: String
                    switch selected {
                    case .useOriginalSettle: decisionName = "useOriginalSettle"
                    case .unchangedNonempty: decisionName = "unchangedNonempty"
                    case .emptyUnchanged: decisionName = "emptyUnchanged"
                    case .waitForSpeechText: decisionName = "waitForSpeechText"
                    }
                    let heardName: String
                    switch heard {
                    case .speech: heardName = "speech"
                    case .silence: heardName = "silence"
                    case .unknown: heardName = "unknown"
                    }
                    RuntimeTrace.record(
                        "doubao send decision=\(decisionName) originalEmpty=\(originalEmpty ? 1 : 0) " +
                        "firstEmpty=\(firstEmpty ? 1 : 0) heard=\(heardName)"
                    )
                }
                switch firstSampleDecision {
                case .unchangedNonempty, .emptyUnchanged:
                    let stillUnchanged = firstSampleDecision == .emptyUnchanged
                        ? (currentValue.map {
                            isEffectivelyEmpty($0, processIdentifier: session.processIdentifier)
                        } ?? true)
                        : currentValue == session.originalText
                    if stillUnchanged {
                        if let decision = firstSampleDecision, let currentValue,
                           DoubaoExternalSendPolicy.maySendUnchanged(
                               decision: decision, elapsedMilliseconds: releaseElapsed,
                               stillUnchanged: true
                           ) {
                            return .settled(currentValue, requireDoubaoText: false)
                        }
                        continue
                    }
                    // A new commit (including one at +450ms) stays on the
                    // original conservative settle policy, with no shorter wait.
                    firstSampleDecision = .useOriginalSettle
                case .waitForSpeechText:
                    let landed = currentValue.map {
                        !isEffectivelyEmpty($0, processIdentifier: session.processIdentifier)
                    } ?? false
                    // Never accept the first observed landing after release+3000ms,
                    // even if that first readable sample happens to contain text.
                    if DoubaoExternalSendPolicy.isEmptySpeechTimeout(
                        decision: .waitForSpeechText, elapsedMilliseconds: releaseElapsed,
                        textLanded: false
                    ) {
                        RuntimeTrace.record("composer send waitForText ms=3000 result=timeout")
                        return .noTextLanded
                    }
                    if landed { firstSampleDecision = .useOriginalSettle }
                    else { continue }
                case .none:
                    continue
                case .useOriginalSettle:
                    break
                }
            }
            let settled = settlePolicy.observe(sample: sample, value: currentValue,
                                               elapsedMilliseconds: adaptiveSend ? settleElapsed : nil)
            if requiresFirstTextChange && settlePolicy.firstTextChangeSeen && !firstLandingLogged {
                firstLandingLogged = true
                RuntimeTrace.record("composer send waitForText ms=\(releaseElapsed) result=landed")
            }
            if settled, let currentValue {
                if settlePolicy.usedExtraQuietFallback {
                    RuntimeTrace.record("composer settle extraQuietFallback=1")
                }
                RuntimeTrace.record(timing.traceMessage)
                return .settled(currentValue, requireDoubaoText: waitedForSpeechText)
            }
        }
        RuntimeTrace.record(timing.traceMessage)
        if requiresFirstTextChange && !settlePolicy.firstTextChangeSeen {
            let elapsed = session.releaseTiming.elapsedMilliseconds()
            if elapsed >= 0 {
                let maximum = session.originalText.map {
                    isEffectivelyEmpty($0, processIdentifier: session.processIdentifier)
                } == true ? 3_000 : 4_000
                RuntimeTrace.record("composer send waitForText ms=\(min(elapsed, maximum)) result=timeout")
                return .noTextLanded
            }
        }
        return .notSettled
    }

    /// An ambiguous submission must never be retried: the first Return may
    /// already have sent while the editor's AX snapshot still looks unchanged.
    private func sendCurrentInput(
        from session: Session, settledText: String?,
        expectedEditingGeneration: UInt64? = nil,
        retryIfSwallowed: Bool = false,
        requireDoubaoText: Bool = false
    ) async -> ComposerActionOutcome {
        var firstReturnAt: UInt64?
        var confirmedAt: UInt64?
        var retriedReturn = false
        var swallowed = false
        var observedNonemptySend = false
        let lastChange = sendLastChangeMilliseconds
        let usedExtraQuiet = sendUsedExtraQuiet
        defer {
            if let firstReturnAt {
                let releaseToReturn = session.releaseTiming.elapsedMilliseconds(at: firstReturnAt)
                let returnToConfirm = confirmedAt.map { Int(($0 - firstReturnAt) / 1_000_000) } ?? -1
                RuntimeTrace.record(
                    "composer send timing releaseToReturnMs=\(releaseToReturn) returnToConfirmMs=\(returnToConfirm) " +
                    "retry=\(retriedReturn ? 1 : 0) late=\(ComposerSettleTiming.lateFlag(lastChangeMilliseconds: lastChange))"
                )
                // Only observed nonempty sends in the still-current context advance history.
                // Recheck session/token after the potentially blocking target validation.
                let targetIsValid = observedNonemptySend && validate(session)
                extraQuietHistory.record(processIdentifier: session.processIdentifier,
                                         swallowed: swallowed, usedExtraQuiet: usedExtraQuiet,
                                         lastChangeMilliseconds: lastChange,
                                         eligibility: .init(
                                             sessionIsCurrent: isSessionActive(session),
                                             tokenIsCurrent: operationToken === session.cancellationToken &&
                                                 activeSession?.cancellationToken === session.cancellationToken,
                                             isCancelled: Task.isCancelled || session.cancellationToken.isCancelled,
                                             targetIsValid: targetIsValid, observedNonemptySend: observedNonemptySend))
            }
        }
        guard isSessionActive(session), validate(session) else { return beforeReturnInvalidOutcome(session) }
        if focusMovedBeforeReturn(session) { return .sendTargetChangedBeforeReturn }
        var valueBeforeReturn = composerText(session.element)
        let landingStart = DispatchTime.now().uptimeNanoseconds
        while ComposerSendLandingPolicy.decide(expected: settledText, original: session.originalText,
            current: valueBeforeReturn, elapsedMilliseconds: Int((DispatchTime.now().uptimeNanoseconds - landingStart) / 1_000_000)) == .wait {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return .targetChanged }
            guard isSessionActive(session), validate(session), operationMayProceed else {
                return beforeReturnInvalidOutcome(session)
            }
            if focusMovedBeforeReturn(session) { return .sendTargetChangedBeforeReturn }
            valueBeforeReturn = composerText(session.element)
        }
        if requireDoubaoText && (valueBeforeReturn.map {
            isEffectivelyEmpty($0, processIdentifier: session.processIdentifier)
        } ?? true) {
            RuntimeTrace.record("composer send phase=emptyBeforeReturn submitted=false")
            return .doubaoTextTimeout
        }
        guard valueBeforeReturn == settledText else {
            RuntimeTrace.record("composer send blocked reason=textChangedAfterSettle submitted=false")
            return .dictationNotSettled
        }
        // Reading AXValue may itself wait on the other application. Recheck
        // target identity after that read, immediately before the key pair.
        guard isSessionActive(session), validate(session) else { return beforeReturnInvalidOutcome(session) }
        if focusMovedBeforeReturn(session) { return .sendTargetChangedBeforeReturn }
        let observedNonemptyInput = valueBeforeReturn.map {
            !isEffectivelyEmpty($0, processIdentifier: session.processIdentifier)
        } ?? false
        let blankBeforeReturn = valueBeforeReturn.map {
            ComposerTextNormalizer.isBlank($0) ? "true" : "false"
        } ?? "unknown"
        RuntimeTrace.record(
            "composer send phase=returnAttempt pid=\(session.processIdentifier) " +
            "valueReadable=\(valueBeforeReturn != nil) " +
            "empty=\(valueBeforeReturn?.isEmpty ?? false) " +
            "blank=\(blankBeforeReturn)"
        )
        let posted: Bool
        let returnAttemptAt = session.releaseTiming.nowNanoseconds
        let notePosted = {
            session.releaseTiming.noteReturnPosted(at: returnAttemptAt)
            session.targetWatch.noteReturnPosted()
        }
        session.releaseTiming.finishExternalSend()
        if let expectedEditingGeneration {
            posted = editingIntentClock.performIfUnchanged(expectedEditingGeneration) {
                postKey(CGKeyCode(36), to: session.processIdentifier, token: session.cancellationToken, onPosted: notePosted)
            } ?? false
        } else {
            posted = postKey(CGKeyCode(36), to: session.processIdentifier, token: session.cancellationToken, onPosted: notePosted)
        }
        guard posted else {
            RuntimeTrace.record("composer send phase=returnPostFailed submitted=false")
            return .eventPostFailed
        }
        firstReturnAt = returnAttemptAt
        RuntimeTrace.record("composer send phase=returnPosted submitted=true retry=none")
        if let kind = axQueueTestFixture?.replay?.read("ReplayPostReturnFocus") as? String,
           ["focusElement", "focusWindow", "workspace"].contains(kind) {
            session.targetWatch.replayInvalidate(kind: kind, token: session.cancellationToken)
        }
        var onlyUnchanged = true
        let submissionSignal = await waitForSubmissionConfirmation(
            session,
            valueBeforeReturn: valueBeforeReturn,
            timeoutMilliseconds: 1_200,
            onlyUnchanged: &onlyUnchanged
        )
        switch submissionSignal {
        case .confirmed, .unchanged, .changedNonempty, .textStillPresent, .clearUnstable:
            observedNonemptySend = observedNonemptyInput
        case .unreadable, .focusChanged, .sessionInactive, .emptyBeforeReturn,
             .editorReplaced, .windowChanged, .applicationSwitched:
            break // Interrupted/empty/unknown observations cannot age send history.
        }
        if submissionSignal == .confirmed {
            confirmedAt = session.releaseTiming.nowNanoseconds
            RuntimeTrace.record("composer send confirmed attempt=pid")
            return .sent
        }
        swallowed = observedNonemptyInput && onlyUnchanged && submissionSignal == .unchanged && SwallowedReturnPolicy.allowsRetry(
               bundleIdentifier: NSRunningApplication(processIdentifier: session.processIdentifier)?.bundleIdentifier
           )
        if retryIfSwallowed, swallowed {
            observedNonemptySend = false // A retry may be interrupted even after a valid first observation.
            if let retried = await retrySwallowedReturn(
                session,
                valueBeforeReturn: valueBeforeReturn,
                expectedEditingGeneration: expectedEditingGeneration
            ) {
                observedNonemptySend = observedNonemptyInput && (retried == .sent || retried == .sendStillPresent)
                retriedReturn = true
                if retried == .sent { confirmedAt = session.releaseTiming.nowNanoseconds }
                return retried
            }
        }

        RuntimeTrace.record("composer send unconfirmed observation=\(submissionSignal.rawValue) retry=none")
        if session.targetWatch.postReturnInvalidation == nil {
            recordUnconfirmedDetail(session, valueBeforeReturn: valueBeforeReturn)
        }
        if submissionSignal == .unchanged || submissionSignal == .textStillPresent {
            return .sendStillPresent
        }
        return .sendUnconfirmed
    }

    /// Lengths and attribute presence only, never text: what an unfamiliar composer's empty
    /// state looks like, so the next "unconfirmed" from it can be explained from the log alone.
    private func recordUnconfirmedDetail(_ session: Session, valueBeforeReturn: String?) {
        let current = stringAttribute(session.element, kAXValueAttribute as CFString)
        func length(_ text: String?) -> String {
            text.map { String(($0 as NSString).length) } ?? "nil"
        }
        let placeholder = stringAttribute(session.element, "AXPlaceholderValue" as CFString)
        let description = stringAttribute(session.element, kAXDescriptionAttribute as CFString)
        let characterCount = numberAttribute(session.element, "AXNumberOfCharacters" as CFString)
        let role = safeEditorRole(stringAttribute(session.element, kAXRoleAttribute as CFString))
        let equalsOriginal = current != nil && current == session.originalText
        let leadingBreak = current?.unicodeScalars.first.map { CharacterSet.newlines.contains($0) } ?? false
        RuntimeTrace.record(
            "composer send unconfirmed detail role=\(role) bundle=\(session.bundleIdentifier ?? "nil") " +
            "beforeUTF16=\(length(valueBeforeReturn)) " +
            "currentUTF16=\(length(current)) originalUTF16=\(length(session.originalText)) " +
            "equalsOriginal=\(equalsOriginal) leadingBreak=\(leadingBreak) " +
            "placeholderUTF16=\(length(placeholder)) descriptionUTF16=\(length(description)) " +
            "charCount=\(characterCount.map(String.init) ?? "nil")"
        )
    }

    /// The first Return can be consumed before it reaches the editor: the input method
    /// (Doubao) may still be committing its last composition, or the app was briefly busy.
    /// In a chat composer a sent message always clears the field, so when every sample
    /// after Return still shows exactly the same text in the same focused composer, the
    /// Return did not send. Press it once more, never more than once (2026-09-29, Claude).
    private func retrySwallowedReturn(
        _ session: Session,
        valueBeforeReturn: String?,
        expectedEditingGeneration: UInt64?
    ) async -> ComposerActionOutcome? {
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return nil }
        guard isSessionActive(session), validate(session),
              let valueBeforeReturn,
              composerText(session.element) == valueBeforeReturn else { return nil }
        let posted: Bool
        if let expectedEditingGeneration {
            posted = editingIntentClock.performIfUnchanged(expectedEditingGeneration) {
                postKey(CGKeyCode(36), to: session.processIdentifier, token: session.cancellationToken)
            } ?? false
        } else {
            posted = postKey(CGKeyCode(36), to: session.processIdentifier, token: session.cancellationToken)
        }
        guard posted else { return nil }
        RuntimeTrace.record("composer send phase=returnRetry reason=swallowed submitted=true")
        var onlyUnchanged = true
        let signal = await waitForSubmissionConfirmation(
            session,
            valueBeforeReturn: valueBeforeReturn,
            timeoutMilliseconds: 1_200,
            onlyUnchanged: &onlyUnchanged
        )
        if signal == .confirmed {
            RuntimeTrace.record("composer send confirmed attempt=retry")
            return .sent
        }
        RuntimeTrace.record("composer send unconfirmed observation=\(signal.rawValue) retry=done")
        if signal == .unchanged || signal == .textStillPresent { return .sendStillPresent }
        return .sendUnconfirmed
    }

    private func waitForSubmissionConfirmation(
        _ session: Session,
        valueBeforeReturn: String?,
        timeoutMilliseconds: Int,
        onlyUnchanged: inout Bool
    ) async -> SubmissionSignal {
        let sampleCount = max(1, timeoutMilliseconds / 100)
        let deadline = DispatchTime.now().uptimeNanoseconds +
            UInt64(timeoutMilliseconds) * 1_000_000
        var confirmedSamples = 0
        var lastSignal: SubmissionSignal = .unreadable
        for _ in 0..<sampleCount {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return .sessionInactive }
            guard DispatchTime.now().uptimeNanoseconds <= deadline else { break }
            if let change = session.targetWatch.postReturnInvalidation {
                onlyUnchanged = false
                // The old target is no longer a trustworthy delivery witness.
                // Do not read the new field or infer successful delivery from
                // replacement alone. In particular, never retry this Return.
                switch change {
                case "focusElement": return .editorReplaced
                case "focusWindow": return .windowChanged
                case "workspace": return .applicationSwitched
                default: return .focusChanged
                }
            }
            guard isSessionActive(session) else { return .sessionInactive }
            lastSignal = submissionTransitionObserved(session, valueBeforeReturn: valueBeforeReturn)
            if lastSignal != .unchanged { onlyUnchanged = false }
            if lastSignal == .confirmed {
                confirmedSamples += 1
                if confirmedSamples >= 2 { return .confirmed }
            } else {
                confirmedSamples = 0
            }
        }
        // A single empty snapshot at the deadline is not the two-sample
        // receipt required above. Keep it uncertain.
        return lastSignal == .confirmed ? .clearUnstable : lastSignal
    }

    private func submissionTransitionObserved(
        _ session: Session,
        valueBeforeReturn: String?
    ) -> SubmissionSignal {
        guard (axQueueTestFixture?.processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier) == session.processIdentifier else {
            return .focusChanged
        }

        // A post-Return focus change removes the target identity needed to
        // attribute an empty value to this action. It is therefore
        // unconfirmed, even when the old element has disappeared.
        let appElement = applicationElement(session.processIdentifier)
        guard let focused = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString),
              CFEqual(focused, session.element) else { return .focusChanged }

        // Read AXValue first. Only when it changes to a nonempty value do we
        // spend additional bounded AX reads to distinguish a cleared field's
        // placeholder from real content. Ambiguous metadata stays uncertain.
        let currentValue = stringAttribute(session.element, kAXValueAttribute as CFString)
        if let valueBeforeReturn {
            guard !valueBeforeReturn.isEmpty,
                  !hintMemory.isKnown(valueBeforeReturn, processIdentifier: session.processIdentifier)
            else { return .emptyBeforeReturn }
            if currentValue?.isEmpty == true { return .confirmed }
            // Electron composers often keep a lone newline or zero-width space after
            // sending (Claude leaves one UTF-16 unit). The text is gone either way.
            if let currentValue, ComposerTextNormalizer.isBlank(currentValue),
               !ComposerTextNormalizer.isBlank(valueBeforeReturn) {
                return .confirmed
            }
            // A hint-as-value composer (ChatGPT for Mac) goes back to the hint it showed
            // before dictation; see `returnedToEmptyHint`.
            if let currentValue,
               ComposerTextNormalizer.returnedToEmptyHint(
                   original: session.originalText,
                   originalSelection: session.originalSelection,
                   valueBeforeReturn: valueBeforeReturn,
                   current: currentValue
               ) {
                RuntimeTrace.record("composer send observation=returnedToEmptyHint")
                hintMemory.learn(currentValue, processIdentifier: session.processIdentifier)
                return .confirmed
            }
            // The hint this app's composer is known to show, or one that vanished when an earlier
            // dictation landed and is back now (Ken dictates in one gesture and sends in the next).
            if let currentValue,
               hintMemory.recognizesAfterSend(
                   current: currentValue, valueBeforeReturn: valueBeforeReturn,
                   processIdentifier: session.processIdentifier, bundleIdentifier: session.bundleIdentifier
               ) {
                RuntimeTrace.record("composer send observation=rememberedEmptyHint")
                return .confirmed
            }
            if let currentValue {
                if currentValue == valueBeforeReturn { return .unchanged }
                // Some Electron editors replace a cleared composer with its
                // visible placeholder in AXValue. Apply the same guarded
                // normalization used before delivery, but only after a raw
                // change: two consecutive normalized-empty samples are still
                // required by the caller before treating it as a clear.
                let logicalValue = ComposerTextNormalizer.logicalText(
                    value: currentValue,
                    placeholder: stringAttribute(session.element, "AXPlaceholderValue" as CFString),
                    accessibilityDescription: stringAttribute(session.element, kAXDescriptionAttribute as CFString),
                    characterCount: numberAttribute(session.element, "AXNumberOfCharacters" as CFString)
                )
                if logicalValue?.isEmpty == true {
                    RuntimeTrace.record("composer send observation=normalizedPlaceholderClear")
                    return .confirmed
                }
                // An inserted newline or late IME commit can change AXValue
                // without sending. If the entire pre-Return text remains,
                // leave an actionable observation instead of claiming success.
                return currentValue.contains(valueBeforeReturn)
                    ? .textStillPresent : .changedNonempty
            }
        }

        // AXValue-less editors cannot be verified by content. Focus identity
        // alone is not a submission receipt.
        return .unreadable
    }

    // MARK: - Learning from the person's own corrections

    /// T8: One delayed, passive read through the existing target reader. Normal Stop cancels its delivery
    /// token; learning has its own cancellation token and never writes, refocuses, sends or retries.
    public func observeDoubaoReference(for token: ComposerActionSession?) async -> DoubaoLearningReference? {
        guard let token, !token.isSecureField else { return nil }
        let cancelled = OperationCancellationToken()
        return await withTaskCancellationHandler {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
            guard !Task.isCancelled else { return nil }
            return await axWorker.run { [self] in
                await withCheckedContinuation { continuation in
                    axQueue.async { [self] in
                        operationToken = cancelled
                        operationDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
                        defer { operationToken = nil; operationDeadline = .max }
                        guard !cancelled.isCancelled, let session = session(matching: token),
                              validate(session), editingIntentClock.snapshot() == session.editingGeneration,
                              let after = composerText(session.element) else { continuation.resume(returning: nil); return }
                        let before = session.phantomEmpty ? "" : session.originalText
                        let selection = session.phantomEmpty ? NSRange(location: 0, length: 0) : session.originalSelection
                        guard let span = DoubaoReferenceDifference.span(before: before, selection: selection, after: after) else {
                            continuation.resume(returning: nil); return
                        }
                        guard operationMayProceed, activeSession?.identifier == session.identifier,
                              editingIntentClock.snapshot() == session.editingGeneration else {
                            continuation.resume(returning: nil); return
                        }
                        recordKept(session, path: "doubao", document: after, spanLocation: span.location,
                                   delivered: span.text, revertTexts: [])
                        let baseline = takeKeptBaseline(for: token)
                        continuation.resume(returning: baseline.map { DoubaoLearningReference(baseline: $0, observedAt: Date()) })
                    }
                }
            }
        } onCancel: { cancelled.cancel() }
    }

    /// How long after a kept dictation the next gesture still counts as another look at the same field.
    private static let revisitWindowNanoseconds: UInt64 = 600_000_000_000

    /// The dictation has settled in the field (`.kept`). Leaves the coordinator the receipt that learning from
    /// the person's own corrections needs, and remembers which field it was (no text) so that the next gesture
    /// there can be told from a gesture anywhere else. Reads nothing and writes nothing in the field.
    private func recordKept(
        _ session: Session, path: String, document: String, spanLocation: Int, delivered: String,
        revertTexts: [String], firstSeenHint: String? = nil,
        expectedAXInsertion: Int? = nil, expectedDraftUTF16: Int? = nil
    ) {
        guard !session.isSecureField, !delivered.isEmpty else { return }
        // A position-independent paste receipt can include structural AX characters.
        // Learning still owns that proven span, but drift compares the caret we left
        // at this sentence's frozen insertion start plus its delivered length.
        let caretStart = expectedAXInsertion ?? (path == "paste"
            ? (session.phantomEmpty ? 0 : session.originalSelection?.location) : nil)
        rememberCaret(session, document: document,
            writtenRange: NSRange(location: spanLocation, length: delivered.utf16.count),
            expectedInsertionLocation: caretStart, expectedDraftUTF16Length: expectedDraftUTF16)
        var emptyStates: [String] = []
        if session.phantomEmpty, let original = session.originalText, !original.isEmpty { emptyStates.append(original) }
        if let hint = hintMemory.knownHint(for: session.processIdentifier), !emptyStates.contains(hint) {
            emptyStates.append(hint)
        }
        // A hint seen for the first time, which vanished as the text arrived, is this field's empty state too.
        if let hint = firstSeenHint, !hint.isEmpty, !emptyStates.contains(hint) { emptyStates.append(hint) }
        let baseline = KeptDictationBaseline(
            id: UUID(), processIdentifier: session.processIdentifier, document: document,
            spanLocation: spanLocation, spanLength: delivered.utf16.count, delivered: delivered,
            emptyStateValues: emptyStates, editingGeneration: session.editingGeneration, path: path,
            revertTexts: revertTexts)
        learningLock.withLock { keptBaselineMailbox = (session.identifier, baseline) }
        lastKeptField = (session.processIdentifier, session.element, baseline.id, DispatchTime.now().uptimeNanoseconds)
        RuntimeTrace.record(
            "learn baseline path=\(path) docUTF16=\(document.utf16.count) spanUTF16=\(baseline.spanLength)")
    }

    /// The text a selection stood on before something replaced it (nil for a caret).
    private static func replacedText(in text: String?, selection: NSRange?) -> String? {
        guard let text, let selection, selection.length > 0, selection.location >= 0 else { return nil }
        let nsText = text as NSString
        guard NSMaxRange(selection) <= nsText.length else { return nil }
        return nsText.substring(with: selection)
    }

    /// A gesture began a session: when it is in the very field the last kept dictation went to, the text the
    /// session has just read is a look at that field, for free.
    private func fileRevisit(for session: Session, value: String?) {
        learningLock.withLock { revisitMailbox = nil }
        guard let last = lastKeptField else { return }
        lastKeptField = nil
        guard DispatchTime.now().uptimeNanoseconds &- last.at <= Self.revisitWindowNanoseconds else {
            RuntimeTrace.record("learn revisit match=expired")
            return
        }
        guard last.processIdentifier == session.processIdentifier, CFEqual(last.element, session.element) else {
            RuntimeTrace.record("learn revisit match=none sameProcess=\(last.processIdentifier == session.processIdentifier)")
            return
        }
        // The field's own empty state reads as no text at all.
        let sample = FieldRevisitSample(
            baselineID: last.baselineID, document: session.phantomEmpty ? "" : value,
            editingGeneration: session.editingGeneration,
            caretAtEnd: session.originalSelection.map { $0.length == 0 && $0.location == value?.utf16.count } ?? false)
        learningLock.withLock { revisitMailbox = (session.identifier, sample) }
        RuntimeTrace.record("learn revisit match=element readable=\(value != nil) utf16=\(value?.utf16.count ?? -1)")
    }

    public func takeKeptBaseline(for session: ComposerActionSession?) -> KeptDictationBaseline? {
        guard let session else { return nil }
        return learningLock.withLock { () -> KeptDictationBaseline? in
            let box = keptBaselineMailbox
            keptBaselineMailbox = nil
            return box?.session == session.identifier ? box?.baseline : nil
        }
    }

    public func takeRevisit(for session: ComposerActionSession?) -> FieldRevisitSample? {
        guard let session else { return nil }
        return learningLock.withLock { () -> FieldRevisitSample? in
            let box = revisitMailbox
            revisitMailbox = nil
            return box?.session == session.identifier ? box?.sample : nil
        }
    }

    private func session(matching token: ComposerActionSession) -> Session? {
        guard activeSession?.identifier == token.identifier else { return nil }
        return activeSession
    }

    private func takeEmptySpeechSendRetry(
        _ session: Session, action: VoiceReleaseAction, heard: SpeechHeard
    ) -> EmptySpeechSendRetry? {
        guard let retry = emptySpeechSendRetry else { return nil }
        // Consume before any further validation or await; a rejected receipt is
        // never restored, and a new spoken/unknown gesture keeps ordinary settle.
        emptySpeechSendRetry = nil
        guard action == .send, heard == .silence,
              session.identifier == retry.nextSessionIdentifier,
              DispatchTime.now().uptimeNanoseconds < retry.expiresAt,
              retry.processIdentifier == session.processIdentifier,
              CFEqual(retry.element, session.element), CFEqual(retry.window, session.window),
              axQueueTestFixture != nil || NSRunningApplication(processIdentifier: retry.processIdentifier)?.isTerminated == false,
              session.originalText == retry.value,
              isSessionActive(session), validate(session), !focusMovedBeforeReturn(session),
              let current = composerText(session.element), current == retry.value,
              editingIntentClock.snapshot() == retry.editingGeneration,
              session.editingGeneration == retry.editingGeneration,
              operationMayProceed else { return nil }
        return retry
    }

    private func isSessionActive(_ session: Session) -> Bool {
        activeSession?.identifier == session.identifier &&
            !session.cancellationToken.isCancelled &&
            DispatchTime.now().uptimeNanoseconds < session.deadline
    }

    private func releaseInlineClipboard(_ session: Session) async {
        guard activeSession?.identifier == session.identifier,
              var current = activeSession, let lease = current.inlineClipboardLease else { return }
        current.inlineClipboardLease = nil
        storeInline(current)
        if current.inlineClipboardPasteConfirmed && current.inlineUnconfirmedPlan == nil {
            _ = await clipboardTransfer.releaseDraft(id: lease)
        } else {
            await clipboardTransfer.abandon(id: lease)
        }
    }

    private func finish(_ session: Session) async {
        guard activeSession?.identifier == session.identifier else { return }
        await releaseInlineClipboard(session)
        session.targetWatch.stop()
        activeSession = nil
    }

    /// Only an observed move away from the original target earns a definite pre-Return warning.
    /// Expired/cancelled sessions, unknown AX focus and post-Return focus changes never do.
    private func focusMovedBeforeReturn(_ session: Session) -> Bool {
        guard isSessionActive(session) else { return false }
        if let flagged = axQueueTestFixture?.replay?.read("ReplayFocusMovedBeforeReturn") as? NSNumber,
           flagged.boolValue { return true } // Synthetic R0 only; no device/AX access.
        let foreground = axQueueTestFixture?.processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let foreground else { return false }
        if foreground != session.processIdentifier { return true }
        let appElement = applicationElement(session.processIdentifier)
        guard let focused = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString) else { return false }
        return !CFEqual(focused, session.element)
    }

    private func beforeReturnInvalidOutcome(_ session: Session) -> ComposerActionOutcome {
        focusMovedBeforeReturn(session) ? .sendTargetChangedBeforeReturn : .targetChanged
    }

    private func validate(_ session: Session) -> Bool {
        validate(element: session.element, window: session.window, processIdentifier: session.processIdentifier,
                 secureField: session.isSecureField)
    }

    private func validate(element: AXUIElement, window: AXUIElement, processIdentifier: pid_t, secureField: Bool = false) -> Bool {
        guard (axQueueTestFixture?.processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier) == processIdentifier else {
            return false
        }
        let appElement = applicationElement(processIdentifier)
        guard let focused = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString),
              let focusedWindow = elementAttribute(focused, kAXWindowAttribute as CFString) else {
            return false
        }
        return CFEqual(focused, element) && CFEqual(focusedWindow, window)
            && isEditable(focused) && isSecure(focused) == secureField
    }

    private var operationMayProceed: Bool {
        guard let operationToken else { return false }
        return !operationToken.isCancelled &&
            DispatchTime.now().uptimeNanoseconds < operationDeadline
    }

    /// Secure Event Input belongs to the system, not to the focused field.
    /// It can hide user key events from our intent clock. Ordinary editors
    /// remain usable, but partial writers defer to the final exact-snapshot
    /// checks while it is enabled. Never disable another process's secure mode.
    private var systemSecureInputEnabled: Bool {
        if let fixture = axQueueTestFixture {
            return (fixture.replay?.read("ReplaySystemSecureInput") as? NSNumber)?.boolValue ?? false
        }
        return SecureInputGuard.isEnabled
    }

    private func postKey(
        _ keyCode: CGKeyCode,
        to processIdentifier: pid_t,
        token: OperationCancellationToken,
        flags: CGEventFlags = [],
        onPosted: (() -> Void)? = nil
    ) -> Bool {
        if let replay = axQueueTestFixture?.replay {
            guard operationMayProceed else { return false }
            return token.commitIfValid {
                let posted = replay.key(keyCode, flags: flags.rawValue)
                if posted { onPosted?() }
                return posted
            } ?? false
        }
        guard operationMayProceed, EventAccessPermission.canPost,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: voicePointerSyntheticEventUserData)
        up.setIntegerValueField(.eventSourceUserData, value: voicePointerSyntheticEventUserData)
        // Submit the balanced pair in one short commit; cancellation cannot
        // split an accepted down from its matching up.
        return token.commitIfValid {
            guard DispatchTime.now().uptimeNanoseconds < operationDeadline else { return false }
            down.postToPid(processIdentifier)
            up.postToPid(processIdentifier)
            onPosted?()
            return true
        } ?? false
    }

    private func applicationElement(_ pid: pid_t) -> AXUIElement {
        if let axQueueTestFixture { return axQueueTestFixture.application }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }

    private func isChromium(application: NSRunningApplication, element: AXUIElement) -> Bool {
        if copyAttribute(element, "AXDOMClassList" as CFString) != nil ||
           copyAttribute(element, "AXDOMIdentifier" as CFString) != nil { return true }
        guard let bundle = application.bundleIdentifier else { return false }
        if InlineWritePolicy.knownChromium.contains(bundle) { return true }
        if let cached = chromiumCache[bundle] { return cached }
        let names: Set<String> = ["Electron Framework.framework", "Chromium Embedded Framework.framework", "Google Chrome Framework.framework"]
        let frameworks = application.bundleURL?.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let found = frameworks.flatMap { try? FileManager.default.contentsOfDirectory(at: $0,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }?.contains { names.contains($0.lastPathComponent) } ?? false
        if chromiumCache.count >= 64 { chromiumCache.removeAll() }
        chromiumCache[bundle] = found
        return found
    }

    private func safeEditorRole(_ value: String?) -> String {
        let roles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea", "AXGroup",
            "AXUnknown", "AXStandardWindow", "AXContentList", "AXSecureTextField"]
        return value.flatMap { roles.contains($0) ? $0 : nil } ?? "unknown"
    }

    private func recordEditorDiagnostics(_ session: Session) {
        let element = session.element
        let role = safeEditorRole(stringAttribute(element, kAXRoleAttribute as CFString))
        let subrole = safeEditorRole(stringAttribute(element, kAXSubroleAttribute as CFString))
        let classes = InlineWritePolicy.diagnosticClasses(copyAttribute(element, "AXDOMClassList" as CFString) as? [String] ?? [])
        let hasIdentifier = copyAttribute(element, "AXDOMIdentifier" as CFString) != nil
        let count = numberAttribute(element, "AXNumberOfCharacters" as CFString).flatMap { $0 >= 0 && $0 <= 10_000_000 ? $0 : nil } ?? -1
        let settable: Bool = onAXQueue {
            guard operationMayProceed else { return false }
            if let replay = axQueueTestFixture?.replay { return replay.read("AXValueSettable") as? Bool ?? false }
            AXUIElementSetMessagingTimeout(element, 0.15)
            var value = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &value) == .success && value.boolValue
        }
        let bundle = session.bundleIdentifier.flatMap { InlineWritePolicy.safeBundle($0) ? $0 : nil } ?? "unknown"
        RuntimeTrace.record("composer editor bundle=\(bundle) role=\(role) subrole=\(subrole) valueWritable=\(settable) classes=[\(classes.joined(separator: ","))] hasDOMIdentifier=\(hasIdentifier) charCount=\(count)")
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as CFString)?.lowercased() ?? ""
        let roleLooksEditable = role.contains("textfield") ||
            role.contains("textarea") ||
            role.contains("combobox")
        return boolAttribute(element, "AXEditable" as CFString, default: roleLooksEditable) &&
            boolAttribute(element, kAXEnabledAttribute as CFString, default: true)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as CFString)?.lowercased() ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)?.lowercased() ?? ""
        return role.contains("secure") || subrole.contains("secure")
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        copyAttribute(element, attribute) as? String
    }

    /// Reads actual composer text, treating AX placeholder text as empty.
    /// AXNumberOfCharacters is authoritative when available: a non-zero count
    /// preserves real text even when it happens to equal the placeholder.
    /// If the control cannot disambiguate an equal value, fail closed.
    private func composerText(_ element: AXUIElement) -> String? {
        ComposerTextNormalizer.logicalText(
            value: stringAttribute(element, kAXValueAttribute as CFString),
            placeholder: stringAttribute(element, "AXPlaceholderValue" as CFString),
            accessibilityDescription: stringAttribute(element, kAXDescriptionAttribute as CFString),
            characterCount: numberAttribute(element, "AXNumberOfCharacters" as CFString)
        )
    }

    private func numberAttribute(_ element: AXUIElement, _ attribute: CFString) -> Int? {
        guard let raw = copyAttribute(element, attribute) else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }

    private func rangeAttribute(_ element: AXUIElement, _ attribute: CFString) -> NSRange? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func setRangeAttribute(
        _ element: AXUIElement,
        _ attribute: CFString,
        range: NSRange
    ) -> Bool {
        onAXQueue {
            guard operationMayProceed else { return false }
            if let replay = axQueueTestFixture?.replay { return replay.select(range) }
            AXUIElementSetMessagingTimeout(element, 0.15)
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
            return AXUIElementSetAttributeValue(element, attribute, value) == .success
        }
    }

    private func setStringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString,
        value: String
    ) -> ComposerAXWriteResult {
        onAXQueue {
            guard operationMayProceed else {
                return ComposerAXWriteResult.classify(.cancelledBeforeCall)
            }
            if let replay = axQueueTestFixture?.replay { return replay.write(attribute as String, value: value) }
            AXUIElementSetMessagingTimeout(element, 0.15)
            var settable = DarwinBoolean(false)
            let check = AXUIElementIsAttributeSettable(element, attribute, &settable)
            if check == .attributeUnsupported {
                return ComposerAXWriteResult.classify(.settableUnsupported)
            }
            guard check == .success else {
                return ComposerAXWriteResult.classify(.settableQueryFailed)
            }
            guard settable.boolValue else {
                return ComposerAXWriteResult.classify(.notSettable)
            }
            guard operationMayProceed else {
                return ComposerAXWriteResult.classify(.cancelledBeforeCall)
            }
            let result = AXUIElementSetAttributeValue(element, attribute, value as CFString)
            return ComposerAXWriteResult.classify(
                result == .success ? .axSetSuccess :
                    result == .cannotComplete ? .axSetCannotComplete : .axSetFailed
            )
        }
    }

    private func boolAttribute(
        _ element: AXUIElement,
        _ attribute: CFString,
        default fallback: Bool
    ) -> Bool {
        guard let raw = copyAttribute(element, attribute) else { return fallback }
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.boolValue }
        return fallback
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        // AX messaging timeout is per element and must be set before every
        // request. 0.15s bounds one IPC; callers retain their own monotonic
        // operation deadline and cancellation checks.
        onAXQueue {
            guard operationMayProceed else { return nil }
            if let axQueueTestFixture {
                axQueueTestFixture.reads += 1
                axQueueTestFixture.allReadsOnQueue = axQueueTestFixture.allReadsOnQueue &&
                    DispatchQueue.getSpecific(key: axQueueKey) == true
                return axQueueTestFixture.copyAttribute(element, attribute)
            }
            AXUIElementSetMessagingTimeout(element, 0.15)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
            return value
        }
    }
}

// MARK: - Session-owned live transcript

extension MacOSComposerActionExecutor: InlineTranscriptDelivering {
    public func updateDraft(text: String, sequence: UInt64, session: ComposerActionSession?) async -> InlineDraftUpdateOutcome {
        guard let session, sequence != UInt64.max else { return .unsupported }
        guard !session.areDraftUpdatesCancelled else { return .abandoned }
        guard !session.isSecureField else { return .unsupported }
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
        let result = await axWorker.runBounded(nanoseconds: 1_500_000_000) { [self] in
            operationToken = session.draftCancellationToken
            operationDeadline = deadline
            defer { operationToken = nil; operationDeadline = .max }
            return await reviseInline(text: text, sequence: sequence, session: session, deadline: deadline, isFinal: false)
        }
        // The worker may still be completing an AX call. Final delivery will
        // reconcile exact old/new document states before making another edit.
        return result ?? (session.snapshotMarker.isActive ? .pending : .unconfirmed)
    }

    private func reviseInline(
        text: String, sequence: UInt64, session token: ComposerActionSession,
        deadline: UInt64, isFinal: Bool
    ) async -> InlineDraftUpdateOutcome {
        guard var s = session(matching: token) else { return .abandoned }
        s.deadline = deadline
        if !isFinal && systemSecureInputEnabled {
            s.inlineFinalOnly = true
            storeInline(s)
            RuntimeTrace.record("composer input security field=ordinary systemSecure=1 delivery=finalOnly")
            return .unsupported
        }
        if s.chromium {
            guard usesSnapshotPaste(s) else { return .unsupported }
            return await reviseSnapshotPaste(text: text, sequence: sequence, session: &s, deadline: deadline)
        }
        if !isFinal && s.inlineFinalOnly {
            storeInline(s)
            return .unsupported
        }
        s.inlineAttempted = true
        activeSession = s
        guard inlineGuards(s, deadline: deadline), isFinal || !s.inlineFinalOnly else {
            s.inlineFinalOnly = true
            storeInline(s)
            return .abandoned
        }
        if s.inlineDraft == nil {
            guard let base = inlineBase(s),
                  let draft = InlineDraftTransaction(originalText: base.text, selection: base.selection) else {
                s.inlineFinalOnly = true
                storeInline(s)
                return .unsupported
            }
            s.inlineDraft = draft
        }
        guard s.inlineUnconfirmedPlan == nil,
              let document = sessionDocument(s),
              let caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
              inlineGuards(s, deadline: deadline),
              var draft = s.inlineDraft else {
            s.inlineFinalOnly = true
            storeInline(s)
            return .unconfirmed
        }
        let decision = draft.prepare(
            text: text, sequence: sequence, currentDocument: document, currentSelection: caret)
        s.inlineDraft = draft
        switch decision {
        case .unchanged, .stale:
            storeInline(s)
            return .unchanged
        case .abandoned, .busy:
            s.inlineFinalOnly = true
            storeInline(s)
            return .abandoned
        case .replace(let plan):
            s.inlineUnconfirmedPlan = plan
            storeInline(s)
            return await applyInline(plan, session: &s, draft: &draft, deadline: deadline)
        }
    }

    private func applyInline(
        _ plan: InlineDraftTransaction.Plan, session s: inout Session,
        draft: inout InlineDraftTransaction, deadline: UInt64
    ) async -> InlineDraftUpdateOutcome {
        guard inlineGuards(s, deadline: deadline),
              let document = sessionDocument(s),
              let caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
              document.utf16.elementsEqual(draft.lastDocument.utf16),
              caret == draft.expectedSelection else {
            s.inlineFinalOnly = true
            storeInline(s)
            return .unconfirmed
        }

        // First attempt: write the exact whole value through AX. No clipboard
        // or visible selection is involved. The prior document is checked
        // immediately before the call, and every observation remains exact.
        let result = setStringAttribute(s.element, kAXValueAttribute as CFString, value: plan.expectedDocument)
        switch result {
        case .submitted, .submittedButUnconfirmed:
            writeRuntime.noteWrite(bundle: s.bundleIdentifier)
            RuntimeTrace.record("composer inline write path=axValue submitted=true")
            // Preserve the native editor's expected insertion point in the same write burst.
            _ = setRangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString, range: plan.expectedSelection)
            s.inlineSubmittedAny = true
            storeInline(s)
            return await confirmInline(plan, session: &s, draft: &draft, deadline: deadline)
        case .unavailable:
            RuntimeTrace.record("composer inline write path=axValue unavailable=true")
            if s.inlineAvoidPaste {
                draft.discardUnsubmitted(planID: plan.id)
                s.inlineDraft = draft
                s.inlineUnconfirmedPlan = nil
                storeInline(s)
                return .unsupported
            }
            return await pasteInline(plan, session: &s, draft: &draft, deadline: deadline)
        case .beforeWriteRejected:
            draft.discardUnsubmitted(planID: plan.id)
            s.inlineDraft = draft
            s.inlineUnconfirmedPlan = nil
            s.inlineFinalOnly = true
            storeInline(s)
            return .unsupported
        }
    }

    private func removeExternalChromiumDictation(_ s: Session, document: String) async -> ComposerActionOutcome {
        guard let base = inlineBase(s),
              var transaction = InlineDraftTransaction(originalText: base.text, selection: base.selection) else {
            return .cancelUnconfirmed
        }
        let insertedLength = document.utf16.count - (base.text.utf16.count - base.selection.length)
        guard insertedLength >= 0, base.selection.location <= document.utf16.count,
              insertedLength <= document.utf16.count - base.selection.location else { return .cancelUnconfirmed }
        let range = NSRange(location: base.selection.location, length: insertedLength)
        let inserted = (document as NSString).substring(with: range)
        guard case .replace(let plan) = transaction.prepare(text: inserted, sequence: 1,
            currentDocument: base.text, currentSelection: base.selection),
              plan.expectedDocument.utf16.elementsEqual(document.utf16) else { return .cancelUnconfirmed }
        // The exact unchanged prefix/suffix anchor the external dictation to its original insertion point.
        return await removeChromiumRange(s, document: document, range: range, selection: plan.expectedSelection)
    }

    private func removeChromiumRange(_ s: Session, document: String, range: NSRange,
        selection: NSRange) async -> ComposerActionOutcome {
        guard range.location >= 0, range.length >= 0, range.location <= document.utf16.count,
              range.length <= document.utf16.count - range.location,
              InlineDraftTransaction(originalText: document, selection: range) != nil else {
            return .cancelUnconfirmed
        }
        let plan = InlineDraftTransaction.Plan(id: UUID(), replaceRange: range, text: "",
            expectedDocument: (document as NSString).replacingCharacters(in: range, with: ""),
            expectedSelection: NSRange(location: range.location, length: 0))
        var selectionCleanupHandled = false
        defer {
            if !selectionCleanupHandled {
                collapseOwnedSelection(s, range: range, oldDocument: document, oldSelection: selection,
                    newDocument: plan.expectedDocument, newSelection: plan.expectedSelection)
            }
        }
        guard inlineGuards(s, deadline: operationDeadline),
              let before = sessionDocument(s), before.utf16.elementsEqual(document.utf16),
              rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) == selection else {
            return .cancelUnconfirmed
        }
        if range.length == 0 {
            armClear(s, text: document)
            return .removedCurrentDictation
        }
        guard await selectOwnedRange(s, range: range, document: document,
                                    previousSelection: selection, deadline: operationDeadline) else {
            await collapsePendingOwnedSelection(s, range: range, document: document,
                                                previousSelection: selection, deadline: operationDeadline)
            selectionCleanupHandled = true
            return .cancelUnconfirmed
        }
        guard inlineGuards(s, deadline: operationDeadline),
              rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) == range,
              let unchanged = sessionDocument(s), unchanged.utf16.elementsEqual(document.utf16),
              editingIntentClock.performIfUnchanged(s.editingGeneration, {
                  postKey(51, to: s.processIdentifier, token: s.cancellationToken)
              }) == true else { return .cancelUnconfirmed }
        RuntimeTrace.record("composer range remove pid=\(s.processIdentifier) selectedText=0")
        for _ in 0..<4 {
            guard inlineGuards(s, deadline: operationDeadline) else { return .targetChanged }
            if let after = sessionDocument(s), after.utf16.elementsEqual(plan.expectedDocument.utf16),
               rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) == plan.expectedSelection {
                armClear(s, text: plan.expectedDocument)
                return .removedCurrentDictation
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return .targetChanged }
        }
        return .cancelUnconfirmed
    }

    private func collapseOwnedSelection(_ s: Session, range: NSRange, oldDocument: String,
        oldSelection: NSRange, newDocument: String, newSelection: NSRange) {
        guard inlineGuards(s, deadline: operationDeadline),
              rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) == range,
              let current = sessionDocument(s) else { return }
        if current.utf16.elementsEqual(oldDocument.utf16) {
            _ = setRangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString, range: oldSelection)
        } else if current.utf16.elementsEqual(newDocument.utf16) {
            _ = setRangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString, range: newSelection)
        }
    }

    /// Chromium can acknowledge AXSetSelectedTextRange before its readback catches up.
    /// Submit that selection once, then only observe the exact old document and old/new range.
    private func selectOwnedRange(_ s: Session, range: NSRange, document: String,
        previousSelection: NSRange, deadline: UInt64) async -> Bool {
        var reads = 0
        var verified = false
        defer {
            RuntimeTrace.record("composer range selection pid=\(s.processIdentifier) verified=\(verified ? 1 : 0) reads=\(reads)")
        }
        guard inlineGuards(s, deadline: deadline),
              let before = sessionDocument(s), before.utf16.elementsEqual(document.utf16),
              rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) == previousSelection,
              setRangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString, range: range) else { return false }
        for attempt in 0..<4 {
            guard inlineGuards(s, deadline: deadline),
                  let unchanged = sessionDocument(s), unchanged.utf16.elementsEqual(document.utf16),
                  let observed = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
                  observed == previousSelection || observed == range else { return false }
            reads += 1
            if observed == range {
                verified = inlineGuards(s, deadline: deadline)
                return verified
            }
            if attempt < 3 {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
            }
        }
        return false
    }

    /// An unsuccessful selection request may land late. Allow at most three 40 ms pauses
    /// plus passive reads, within the original deadline, and restore only that exact own range.
    private func collapsePendingOwnedSelection(_ s: Session, range: NSRange, document: String,
        previousSelection: NSRange, deadline: UInt64) async {
        for attempt in 0..<4 {
            guard inlineGuards(s, deadline: deadline),
                  let unchanged = sessionDocument(s), unchanged.utf16.elementsEqual(document.utf16),
                  let observed = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
                  observed == previousSelection || observed == range else { return }
            if observed == range {
                collapseOwnedSelection(s, range: range, oldDocument: document,
                    oldSelection: previousSelection, newDocument: document, newSelection: previousSelection)
                return
            }
            if attempt < 3 {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
        }
    }

    private func loseDraftClipboard(_ s: inout Session, reason: String) async {
        if let lease = s.inlineClipboardLease { await clipboardTransfer.abandon(id: lease) }
        s.inlineClipboardLease = nil
        s.inlineFinalOnly = true
        storeInline(s)
        RuntimeTrace.record("composer draft clipboard reason=\(reason) finalOnly=true")
    }

    private func usesSnapshotPaste(_ s: Session) -> Bool {
        s.snapshotMarker.isActive
    }

    private func snapshotLease(_ s: inout Session) async -> UUID? {
        guard let lease = s.inlineClipboardLease,
              await clipboardTransfer.owns(id: lease) else {
            await loseDraftClipboard(&s, reason: "clipboardChanged")
            return nil
        }
        return lease
    }

    private func reviseSnapshotPaste(text: String, sequence: UInt64, session s: inout Session,
        deadline: UInt64) async -> InlineDraftUpdateOutcome {
        guard !s.inlineFinalOnly, inlineGuards(s, deadline: deadline),
              SnapshotDraftPlanner.validDraft(text) else { storeInline(s); return .abandoned }
        guard await snapshotLease(&s) != nil else { return .unsupported }
        if s.snapshotDraft == nil, let base = inlineBase(s) {
            s.snapshotDraft = SnapshotDraftPlanner(original: base.text, selection: base.selection, selectedOriginal: s.snapshotSelectedOriginal)
        }
        guard let planner = s.snapshotDraft, let document = sessionDocument(s),
              let caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) else {
            s.inlineFinalOnly = true; storeInline(s); return .unsupported
        }
        if let last = planner.lastSequence, sequence <= last { storeInline(s); return .unchanged }
        if let own = planner.locate(document: document, caret: caret),
           SnapshotDraftPlanner.equivalentDraft(own.draft, text) {
            s.inlineClipboardPasteConfirmed = true; storeInline(s); return .unchanged
        }
        guard let plan = planner.plan(text: text, document: document, caret: caret) else {
            s.inlineFinalOnly = true; storeInline(s)
            RuntimeTrace.record("composer draft snapshot result=unlocated finalOnly=1")
            let lengths = planner.comparisonLengths(document)
            RuntimeTrace.record("composer draft unlocated original=\(lengths.original) current=\(lengths.current) prefix=\(lengths.prefix) suffix=\(lengths.suffix) selected=\(caret.location):\(caret.length) draftLen=\(text.utf16.count)")
            return .unsupported
        }
        storeInline(s)
        return await writeSnapshotPaste(plan, sequence: sequence, session: &s, document: document,
                                        caret: caret, deadline: deadline)
    }

    private func writeSnapshotPaste(_ plan: SnapshotDraftPlanner.Plan, sequence: UInt64, session s: inout Session,
        document: String, caret: NSRange, deadline: UInt64) async -> InlineDraftUpdateOutcome {
        var plan = plan, caret = caret
        guard !plan.replacement.isEmpty || plan.range.length > 0 else { return .unchanged }
        guard inlineGuards(s, deadline: deadline), let planner = s.snapshotDraft,
              planner.permits(plan.range, document: document, caret: caret, initial: plan.initialInsertion) else {
            s.inlineFinalOnly = true; storeInline(s)
            RuntimeTrace.record("composer draft snapshot result=rangeRejected")
            return .unsupported
        }
        var selectionCleanupHandled = false
        defer {
            if !selectionCleanupHandled {
                collapseOwnedSelection(s, range: plan.range, oldDocument: document,
                    oldSelection: caret, newDocument: document, newSelection: caret)
            }
        }
        guard let lease = await snapshotLease(&s) else { return .unsupported }
        guard await selectOwnedRange(s, range: plan.range, document: document,
                                    previousSelection: caret, deadline: deadline) else {
            await collapsePendingOwnedSelection(s, range: plan.range, document: document,
                                                previousSelection: caret, deadline: deadline)
            selectionCleanupHandled = true
            s.inlineFinalOnly = true; storeInline(s)
            return .unsupported
        }
        if plan.range.length > 0 {
            let selected = copyAttribute(s.element, kAXSelectedTextAttribute as CFString) as? String
            if plan.selectedText.map({ expected in selected.map { SnapshotDraftPlanner.equal($0, expected) } == true }) != true {
                // An untrustworthy initial selected-text witness cannot authorize replacement.
                // Keep the original characters and reuse this same paste path at the selection end.
                let end = NSRange(location: NSMaxRange(plan.range), length: 0)
                guard plan.initialInsertion, !s.inlineSubmittedAny,
                      await selectOwnedRange(s, range: end, document: document, previousSelection: plan.range, deadline: deadline),
                      let insertion = SnapshotDraftPlanner(original: document, selection: end),
                      let insertPlan = insertion.plan(text: plan.draft, document: document, caret: end) else {
                    s.inlineFinalOnly = true; storeInline(s)
                    RuntimeTrace.record("composer draft snapshot result=selectionMismatch")
                    return .unsupported
                }
                s.snapshotDraft = insertion; s.snapshotSelectedOriginal = nil
                plan = insertPlan; caret = end; storeInline(s)
            }
        }
        if !plan.replacement.isEmpty {
            do { try await clipboardTransfer.updateDraft(text: plan.replacement, id: lease) }
            catch {
                await loseDraftClipboard(&s, reason: "clipboardChanged")
                return .unsupported
            }
        }
        guard inlineGuards(s, deadline: deadline),
              rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) == plan.range,
              let unchanged = sessionDocument(s), SnapshotDraftPlanner.equal(unchanged, document) else {
            s.inlineFinalOnly = true; storeInline(s)
            return .unsupported
        }
        guard await clipboardTransfer.owns(id: lease) else {
            await loseDraftClipboard(&s, reason: "clipboardChanged")
            return .unsupported
        }
        let posted = editingIntentClock.performIfUnchanged(s.editingGeneration) {
            postKey(plan.replacement.isEmpty ? 51 : 9, to: s.processIdentifier, token: s.cancellationToken,
                    flags: plan.replacement.isEmpty ? [] : .maskCommand)
        } ?? false
        guard posted else {
            s.inlineFinalOnly = true; storeInline(s)
            return .unsupported
        }
        // Only counts and offsets, never editor text or clipboard contents.
        let fromEnd = max(0, document.utf16.count - NSMaxRange(plan.range))
        RuntimeTrace.record("composer draft change fromEnd=\(fromEnd) removed=\(plan.range.length) inserted=\(plan.replacement.utf16.count)")
        s.inlineClipboardPasteConfirmed = false
        s.snapshotDraft?.noteSubmitted(plan.draft, sequence: sequence)
        s.inlineSubmittedAny = true
        writeRuntime.noteWrite(bundle: s.bundleIdentifier)
        storeInline(s)
        RuntimeTrace.record("composer inline write path=paste submitted=true draft=1 mode=range")
        return await confirmSnapshotPaste(plan, session: &s, deadline: deadline)
    }

    private func confirmSnapshotPaste(_ plan: SnapshotDraftPlanner.Plan, session s: inout Session,
        deadline: UInt64) async -> InlineDraftUpdateOutcome {
        let pollEnd = min(deadline, DispatchTime.now().uptimeNanoseconds + 700_000_000)
        var matches = 0
        var movedOwnCaret = false
        while DispatchTime.now().uptimeNanoseconds < pollEnd {
            try? await Task.sleep(for: .milliseconds(20))
            guard inlineGuards(s, deadline: deadline) else { break }
            guard let document = sessionDocument(s),
                  let caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
                  let planner = s.snapshotDraft,
                  let body = planner.locate(document: document, caret: caret, requireCaret: false),
                  SnapshotDraftPlanner.equivalentDraft(body.draft, plan.draft) else { matches = 0; continue }
            // A middle correction preserves the old suffix. Move only the caret produced by
            // this exact changed-span paste, once, after the complete owned middle is proven.
            if !movedOwnCaret, caret.location == plan.insertionEnd, caret.location != NSMaxRange(body.range),
               inlineGuards(s, deadline: deadline),
               sessionDocument(s).map({ SnapshotDraftPlanner.equal($0, document) }) == true {
                movedOwnCaret = true
                _ = setRangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString,
                                      range: NSRange(location: NSMaxRange(body.range), length: 0))
                matches = 0; continue
            }
            guard let currentCaret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
                  let owned = planner.locate(document: document, caret: currentCaret),
                  SnapshotDraftPlanner.equivalentDraft(owned.draft, plan.draft) else { matches = 0; continue }
            matches += 1
            if matches >= 2, inlineGuards(s, deadline: deadline) {
                s.inlineClipboardPasteConfirmed = true; s.inlineFinalOnly = false
                s.snapshotDraft?.noteLocated(owned); storeInline(s)
                rememberCaret(s, document: document, writtenRange: owned.valueRange,
                              expectedInsertionLocation: owned.range.location, expectedDraftUTF16Length: owned.draft.utf16.count)
                RuntimeTrace.record("composer draft snapshot result=confirmed spanUTF16=\(owned.range.length) caret=\(currentCaret.location)")
                return .updated
            }
        }
        storeInline(s)
        RuntimeTrace.record("composer draft snapshot result=pending")
        return .pending
    }

    private func pasteInline(
        _ plan: InlineDraftTransaction.Plan, session s: inout Session,
        draft: inout InlineDraftTransaction, deadline: UInt64
    ) async -> InlineDraftUpdateOutcome {
        var lease: UUID?
        if !plan.text.isEmpty {
            do { lease = try await clipboardTransfer.begin(text: plan.text) }
            catch {
                draft.discardUnsubmitted(planID: plan.id)
                s.inlineDraft = draft
                s.inlineUnconfirmedPlan = nil
                s.inlineFinalOnly = true
                storeInline(s)
                return .unsupported
            }
        }
        defer {
            // Only our own temporary selection may be collapsed. If the user
            // moved the caret, leave their new selection alone.
            let previousDeadline = operationDeadline
            operationDeadline = max(previousDeadline, DispatchTime.now().uptimeNanoseconds + 500_000_000)
            defer { operationDeadline = previousDeadline }
            if editingIntentClock.snapshot() == s.editingGeneration,
               validate(s),
               let current = sessionDocument(s) {
                let desired = current.utf16.elementsEqual(plan.expectedDocument.utf16)
                    ? plan.expectedSelection : draft.expectedSelection
                _ = setRangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString, range: desired)
            }
        }
        guard inlineGuards(s, deadline: deadline),
              let document = sessionDocument(s),
              let caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
              document.utf16.elementsEqual(draft.lastDocument.utf16),
              caret == draft.expectedSelection else {
            if let lease { _ = await clipboardTransfer.restore(id: lease) }
            s.inlineFinalOnly = true
            storeInline(s)
            return .unconfirmed
        }
        if caret != plan.replaceRange {
            guard setRangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString, range: plan.replaceRange) else {
                if let lease { _ = await clipboardTransfer.restore(id: lease) }
                draft.discardUnsubmitted(planID: plan.id)
                s.inlineDraft = draft
                s.inlineUnconfirmedPlan = nil
                s.inlineFinalOnly = true
                storeInline(s)
                return .unsupported
            }
        }
        guard inlineGuards(s, deadline: deadline),
              let selected = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
              selected == plan.replaceRange,
              let unchanged = composerText(s.element),
              unchanged.utf16.elementsEqual(draft.lastDocument.utf16) else {
            if let lease { _ = await clipboardTransfer.restore(id: lease) }
            s.inlineFinalOnly = true
            storeInline(s)
            return .unconfirmed
        }
        let posted = editingIntentClock.performIfUnchanged(s.editingGeneration) {
            postKey(plan.text.isEmpty ? 51 : 9,
                    to: s.processIdentifier, token: s.cancellationToken,
                    flags: plan.text.isEmpty ? [] : .maskCommand)
        } ?? false
        guard posted else {
            if let lease { _ = await clipboardTransfer.restore(id: lease) }
            draft.discardUnsubmitted(planID: plan.id)
            s.inlineDraft = draft
            s.inlineUnconfirmedPlan = nil
            s.inlineFinalOnly = true
            storeInline(s)
            return .unsupported
        }
        s.inlineSubmittedAny = true
        RuntimeTrace.record("composer inline write path=paste submitted=true")
        writeRuntime.noteWrite(bundle: s.bundleIdentifier)
        storeInline(s)
        let outcome = await confirmInline(plan, session: &s, draft: &draft, deadline: deadline)
        if let lease { _ = await clipboardTransfer.restore(id: lease) }
        return outcome
    }

    private func confirmInline(
        _ plan: InlineDraftTransaction.Plan, session s: inout Session,
        draft: inout InlineDraftTransaction, deadline: UInt64
    ) async -> InlineDraftUpdateOutcome {
        let pollEnd = min(deadline, DispatchTime.now().uptimeNanoseconds + 700_000_000)
        var matches = 0
        while DispatchTime.now().uptimeNanoseconds < pollEnd {
            try? await Task.sleep(for: .milliseconds(20))
            guard inlineGuards(s, deadline: deadline) else { break }
            guard let document = sessionDocument(s),
                  document.utf16.elementsEqual(plan.expectedDocument.utf16) else {
                matches = 0
                continue
            }
            if let caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
               caret != plan.expectedSelection {
                _ = setRangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString, range: plan.expectedSelection)
            }
            guard let caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
                  caret == plan.expectedSelection else {
                matches = 0
                continue
            }
            matches += 1
            if matches >= 2 {
                // Electron can briefly acknowledge the AX selection before
                // a composition/layout update moves the visible caret back.
                // Verify after that update; never chase a user's own edit.
                try? await Task.sleep(for: .milliseconds(80))
                guard inlineGuards(s, deadline: deadline),
                      settleInsertedCaret(s, document: plan.expectedDocument,
                                          expectedSelection: plan.expectedSelection) else {
                    break
                }
                guard draft.confirm(
                    planID: plan.id, observedDocument: plan.expectedDocument,
                    observedSelection: plan.expectedSelection) else { break }
                s.inlineDraft = draft
                s.inlineUnconfirmedPlan = nil
                storeInline(s)
                RuntimeTrace.record("composer inline confirm result=updated caretAtEnd=true")
                if let range = draft.writtenRange {
                    rememberCaret(s, document: draft.lastDocument, writtenRange: range)
                }
                return .updated
            }
        }
        if let rescued = rescueVanishedHint(plan, session: &s, draft: &draft, deadline: deadline) {
            return rescued
        }
        s.inlineFinalOnly = true
        s.inlineDraft = draft
        storeInline(s)
        if editingIntentClock.snapshot() == s.editingGeneration,
           let observed = sessionDocument(s),
           observed.utf16.elementsEqual(plan.expectedDocument.utf16),
           rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) != plan.expectedSelection {
            RuntimeTrace.record("composer inline session finalOnly=true reason=caretUnconfirmed")
        }
        RuntimeTrace.record("composer inline confirm result=unconfirmed caretAtEnd=unknown")
        return .unconfirmed
    }

    /// The first write of a session landed, but the exact document `hint + text` never appeared: the
    /// field's empty-state hint (ChatGPT for Mac shows one as its AXValue) vanished with it. When what
    /// stands there is exactly the text, the write is good; carry on from that document as if the field
    /// had been empty, so the rest of the dictation is written too. Otherwise the session stays unconfirmed.
    private func rescueVanishedHint(
        _ plan: InlineDraftTransaction.Plan, session s: inout Session,
        draft: inout InlineDraftTransaction, deadline: UInt64
    ) -> InlineDraftUpdateOutcome? {
        guard !s.phantomEmpty, !draft.hasWritten,
              inlineGuards(s, deadline: deadline),
              let observed = sessionDocument(s),
              hintMemory.noteVanished(
                  original: s.originalText, selection: s.originalSelection,
                  expectedDocument: plan.expectedDocument, observed: observed,
                  processIdentifier: s.processIdentifier),
              settleInsertedCaret(s, document: observed, expectedSelection: plan.expectedSelection),
              draft.acceptVanishedOriginal(
                  planID: plan.id, observedDocument: observed, observedSelection: plan.expectedSelection)
        else { return nil }
        s.phantomEmpty = true
        s.inlineDraft = draft
        s.inlineUnconfirmedPlan = nil
        storeInline(s)
        RuntimeTrace.record("composer inline confirm result=updated hint=vanished")
        if let range = draft.writtenRange {
            rememberCaret(s, document: draft.lastDocument, writtenRange: range)
        }
        return .updated
    }

    private func finishInlineOnWorker(
        text: String, action: VoiceReleaseAction, session token: ComposerActionSession
    ) async -> ComposerActionOutcome {
        guard var s = session(matching: token),
              inlineGuards(s, deadline: operationDeadline) else { return .targetChanged }
        let deadline = operationDeadline
        s.deadline = deadline
        activeSession = s
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !s.inlineSubmittedAny, action != .cancel {
            // An empty sentence posts no replacement/Delete. Send uses the existing Return path.
            return await pasteAndAct(text: "", action: action, session: s)
        }
        if usesSnapshotPaste(s) {
            return await finishSnapshotPaste(text: text, action: action, session: &s, deadline: deadline)
        }
        if let plan = s.inlineUnconfirmedPlan {
            guard var draft = s.inlineDraft,
                  let document = sessionDocument(s),
                  let selection = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) else {
                return .deliveryUnconfirmed
            }
            let expectedDocument = document.utf16.elementsEqual(plan.expectedDocument.utf16)
                ? plan.expectedDocument : draft.lastDocument
            let target = document.utf16.elementsEqual(plan.expectedDocument.utf16)
                ? plan.expectedSelection : draft.expectedSelection
            if selection != target {
                guard settleInsertedCaret(s, document: expectedDocument, expectedSelection: target) else {
                    return .deliveryUnconfirmed
                }
                RuntimeTrace.record("composer inline reconciliation caretRepair=true")
            }
            guard let repairedSelection = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) else {
                return .deliveryUnconfirmed
            }
            let reconciliation = draft.reconcile(document: document, selection: repairedSelection)
            guard reconciliation != .unknown else {
                return .deliveryUnconfirmed
            }
            if reconciliation == .notApplied, s.inlineSubmittedAny { s.inlineAvoidPaste = true }
            if reconciliation == .applied { s.inlineClipboardPasteConfirmed = true }
            s.inlineDraft = draft
            s.inlineUnconfirmedPlan = nil
            storeInline(s)
        }
        guard let draft = s.inlineDraft else { return .deliveryUnconfirmed }
        if !draft.hasWritten && !s.inlineAvoidPaste {
            // No partial was committed. The unchanged original editor can use
            // the existing single final paste path without duplicate text.
            return await pasteAndAct(text: text, action: action, session: s)
        }
        if !draft.hasWritten && action == .cancel {
            return await cancelWithoutDelivery(text: text, session: s)
        }
        if action == .cancel {
            guard let document = sessionDocument(s),
                  document.utf16.elementsEqual(draft.lastDocument.utf16),
                  let caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
                  caret == draft.expectedSelection,
                  let base = inlineBase(s),
                  setStringAttribute(s.element, kAXValueAttribute as CFString, value: base.text) == .submitted
            else { return .cancelUnconfirmed }
            let restored = sessionDocument(s)
            RuntimeTrace.record("composer inline cancel rereads=0 restored=\(restored?.utf16.elementsEqual(base.text.utf16) == true)")
            guard inlineGuards(s, deadline: deadline) else { return .targetChanged }
            guard let restored else { return .cancelUnconfirmed }
            guard restored.utf16.elementsEqual(base.text.utf16) else {
                // A readable, still nonempty editor is a visible failure;
                // unreadable AX results remain unconfirmed, not asserted failures.
                return isEffectivelyEmpty(restored, processIdentifier: s.processIdentifier) ? .cancelUnconfirmed : .unsafeToCancel
            }
            _ = setRangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString, range: base.selection)
            armClear(s, text: base.text)
            return .removedCurrentDictation
        }
        let revision = await reviseInline(
            text: text, sequence: UInt64.max, session: token,
            deadline: deadline, isFinal: true)
        guard revision == .updated || revision == .unchanged,
              let settled = session(matching: token),
              let settledDraft = settled.inlineDraft,
              let document = sessionDocument(settled),
              document.utf16.elementsEqual(settledDraft.lastDocument.utf16),
              inlineGuards(settled, deadline: deadline) else { return .deliveryUnconfirmed }
        let caretSettled = settleInsertedCaret(settled, document: document, expectedSelection: settledDraft.expectedSelection)
        RuntimeTrace.record("composer inline final confirmed caretSettled=\(caretSettled) action=\(action.rawValue)")
        switch action {
        case .stop:
            if let written = settledDraft.writtenRange {
                var revert = settledDraft.earlierDrafts
                if let base = inlineBase(settled),
                   let replaced = Self.replacedText(in: base.text, selection: base.selection) {
                    revert.append(replaced)
                }
                recordKept(
                    settled, path: "inline", document: document, spanLocation: written.location,
                    delivered: settledDraft.lastDraft, revertTexts: revert)
            }
            return .kept
        case .send:
            return await sendCurrentInput(
                from: settled, settledText: document,
                expectedEditingGeneration: settled.editingGeneration, retryIfSwallowed: true)
        case .cancel: return .cancelUnconfirmed
        }
    }

    private func finishSnapshotPaste(text: String, action: VoiceReleaseAction, session s: inout Session,
        deadline: UInt64) async -> ComposerActionOutcome {
        guard inlineGuards(s, deadline: deadline), SnapshotDraftPlanner.validDraft(text) else {
            return action == .cancel ? .targetChanged : .deliveryFailed
        }
        guard await snapshotLease(&s) != nil else { return .deliveryFailed }
        if s.snapshotDraft == nil, let base = inlineBase(s) {
            s.snapshotDraft = SnapshotDraftPlanner(original: base.text, selection: base.selection, selectedOriginal: s.snapshotSelectedOriginal)
            storeInline(s)
        }
        guard let planner = s.snapshotDraft else {
            return action == .cancel ? .cancelUnconfirmed : await copySnapshotFinal(text, session: &s, deadline: deadline)
        }
        guard var document = sessionDocument(s),
              var caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) else {
            return action == .cancel ? .cancelUnconfirmed : await copySnapshotFinal(text, session: &s, deadline: deadline)
        }
        if action == .cancel {
            if let own = planner.locate(document: document, caret: caret) {
                guard own.range.length > 0 else { return .nothingToCancel }
                // Replace the complete owned middle with the originally selected characters.
                s.snapshotDraft?.noteLocated(own); storeInline(s)
                let replaced = s.snapshotSelectedOriginal ?? ""
                let removal = SnapshotDraftPlanner.Plan(range: own.range, replacement: replaced, draft: replaced,
                    insertionEnd: own.range.location + replaced.utf16.count, selectedText: own.draft)
                let result = await writeSnapshotPaste(removal, sequence: UInt64.max, session: &s,
                                                      document: document, caret: caret, deadline: deadline)
                if result == .updated, let after = sessionDocument(s) {
                    armClear(s, text: after); return .removedCurrentDictation
                }
                return .cancelUnconfirmed
            }
            if SnapshotDraftPlanner.equal(document, planner.original) {
                return await cancelWithoutDelivery(text: text, session: s)
            }
            return .cancelUnconfirmed
        }
        var originalTwice = false
        if SnapshotDraftPlanner.equal(document, planner.original), caret == planner.selection {
            // The previous serial writer has ended. This explicit release fallback may submit
            // once on the original only after two exact reads with unchanged target/intent/lease.
            try? await Task.sleep(for: .milliseconds(40))
            guard inlineGuards(s, deadline: deadline), await snapshotLease(&s) != nil else { return .deliveryFailed }
            if let reread = sessionDocument(s), let range = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
               SnapshotDraftPlanner.equal(reread, planner.original), range == planner.selection {
                document = reread; caret = range; originalTwice = true
            } else if let reread = sessionDocument(s), let range = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString) {
                document = reread; caret = range
            } else {
                return await copySnapshotFinal(text, session: &s, deadline: deadline)
            }
        }
        let decision = planner.finalDecision(document: document, caret: caret, originalConfirmedTwice: originalTwice)
        if case .owned(let own) = decision, SnapshotDraftPlanner.equivalentDraft(own.draft, text) {
            s.inlineClipboardPasteConfirmed = true; storeInline(s)
            return await completeSnapshotFinal(text: text, action: action, session: &s, deadline: deadline)
        }
        let allowOriginal: Bool
        switch decision {
        case .owned: allowOriginal = false
        case .original: allowOriginal = true
        case .clipboard: return await copySnapshotFinal(text, session: &s, deadline: deadline)
        }
        guard let plan = planner.plan(text: text, document: document, caret: caret, allowOriginal: allowOriginal) else {
            return await copySnapshotFinal(text, session: &s, deadline: deadline)
        }
        RuntimeTrace.record("composer draft final decision=\(allowOriginal ? "original" : "owned") attempt=1")
        let result = await writeSnapshotPaste(plan, sequence: UInt64.max, session: &s,
                                              document: document, caret: caret, deadline: deadline)
        if result == .updated { return await completeSnapshotFinal(text: text, action: action, session: &s, deadline: deadline) }
        // No loop or second final event after submission. The transcript remains available to the user.
        return await copySnapshotFinal(text, session: &s, deadline: deadline)
    }

    private func completeSnapshotFinal(text: String, action: VoiceReleaseAction, session s: inout Session, deadline: UInt64) async -> ComposerActionOutcome {
        guard inlineGuards(s, deadline: deadline) else { return .deliveryFailed }
        guard let document = sessionDocument(s),
              let caret = rangeAttribute(s.element, kAXSelectedTextRangeAttribute as CFString),
              let planner = s.snapshotDraft, let owned = planner.locate(document: document, caret: caret),
              SnapshotDraftPlanner.equivalentDraft(owned.draft, text) else {
            return await copySnapshotFinal(text, session: &s, deadline: deadline)
        }
        switch action {
        case .stop:
            let actual = (document as NSString).substring(with: owned.valueRange)
            var reverts = planner.submitted.filter { !SnapshotDraftPlanner.equivalentDraft($0, owned.draft) }
            if let replaced = s.snapshotSelectedOriginal, !replaced.isEmpty { reverts.append(replaced) }
            recordKept(s, path: "inline", document: document, spanLocation: owned.valueRange.location, delivered: actual, revertTexts: reverts,
                       expectedAXInsertion: owned.range.location, expectedDraftUTF16: owned.draft.utf16.count)
            return .kept
        case .send:
            return await sendCurrentInput(from: s, settledText: document, expectedEditingGeneration: s.editingGeneration, retryIfSwallowed: true)
        case .cancel: return .cancelUnconfirmed
        }
    }

    private func copySnapshotFinal(_ text: String, session s: inout Session, deadline: UInt64) async -> ComposerActionOutcome {
        guard inlineGuards(s, deadline: deadline) else { return .deliveryFailed }
        guard let lease = await snapshotLease(&s) else { return .deliveryFailed }
        guard inlineGuards(s, deadline: deadline) else { return .deliveryFailed }
        do { try await clipboardTransfer.updateDraft(text: text, id: lease) }
        catch { await loseDraftClipboard(&s, reason: "clipboardChanged"); return .deliveryFailed }
        // Keep this private payload. Do not restore the old board or pretend an editor delivery occurred.
        await clipboardTransfer.abandon(id: lease)
        s.inlineClipboardLease = nil; s.inlineFinalOnly = true; storeInline(s)
        RuntimeTrace.record("composer draft final decision=clipboard outcome=finalCopiedToClipboard")
        return .finalCopiedToClipboard
    }

    /// Where the inline transaction starts. A phantom-empty composer counts as an empty
    /// document with the caret at 0; any other field starts from its real snapshot.
    private func inlineBase(_ s: Session) -> (text: String, selection: NSRange)? {
        if s.phantomEmpty { return ("", NSRange(location: 0, length: 0)) }
        guard let original = s.originalText, let selection = s.originalSelection else { return nil }
        return (original, selection)
    }

    /// The composer document as this session reasons about it. In a phantom-empty session an
    /// exact re-read of the original phantom value is the empty document (Chromium shows the
    /// phantom again whenever the field is emptied); every other read is verbatim.
    private func sessionDocument(_ s: Session) -> String? {
        guard !s.isSecureField, let document = composerText(s.element) else { return nil }
        if s.phantomEmpty, let original = s.originalText, document.utf16.elementsEqual(original.utf16) {
            return ""
        }
        return document
    }

    private func inlineGuards(_ s: Session, deadline: UInt64) -> Bool {
        isSessionActive(s) && operationMayProceed &&
            DispatchTime.now().uptimeNanoseconds < deadline &&
            editingIntentClock.snapshot() == s.editingGeneration && validate(s)
    }

    private func storeInline(_ s: Session) {
        if activeSession?.identifier == s.identifier { activeSession = s }
    }

    private func rememberCaret(_ s: Session, document: String, writtenRange: NSRange,
                               expectedInsertionLocation: Int? = nil, expectedDraftUTF16Length: Int? = nil) {
        guard document.utf16.count <= 131_072, writtenRange.location >= 0,
              writtenRange.length >= 0, writtenRange.location <= document.utf16.count,
              writtenRange.length <= document.utf16.count - writtenRange.location else { return }
        let insertionStart = expectedInsertionLocation ?? writtenRange.location
        let insertionLength = expectedDraftUTF16Length ?? writtenRange.length
        guard insertionStart >= 0, insertionLength >= 0,
              insertionStart <= 250_064, insertionLength <= 250_064 - insertionStart else { return }
        if expectedDraftUTF16Length == nil {
            guard insertionStart <= document.utf16.count,
                  insertionLength <= document.utf16.count - insertionStart else { return }
        }
        caretReceipts.removeAll { $0.pid == s.processIdentifier && CFEqual($0.element, s.element) }
        if caretReceipts.count >= 32 { caretReceipts.removeFirst() }
        caretReceipts.append(CaretReceipt(pid: s.processIdentifier, element: s.element, document: document,
            removedDocument: (document as NSString).replacingCharacters(in: writtenRange, with: ""),
            expected: insertionStart + insertionLength, removedExpected: insertionStart,
            movementGeneration: s.caretMovementGeneration))
    }

    private func recordCaretDrift(_ s: Session, document: String?, selection: NSRange?) {
        guard let document, let selection, selection.length == 0,
              let previous = caretReceipts.last(where: {
                  $0.pid == s.processIdentifier && CFEqual($0.element, s.element)
              }),
              previous.movementGeneration == CaretMovementIntentClock.shared.snapshot() else { return }
        let expected: Int
        if document.utf16.elementsEqual(previous.document.utf16) { expected = previous.expected }
        else if document.utf16.elementsEqual(previous.removedDocument.utf16) { expected = previous.removedExpected }
        else { return }
        let atStructuralEnd = expected == document.utf16.count && expected > 0
            && selection.location == expected - 1
        guard selection.location >= 0, selection.location != expected, !atStructuralEnd else { return }
        RuntimeTrace.record("composer caret drift expected=\(expected) actual=\(selection.location)")
    }
}

/// All targets may receive one consumed-Return retry, but ONLY when every
/// post-Return sample stayed exactly unchanged and the 150ms final recheck agrees.
/// No bundle identifier is used to decide retry eligibility.
@_spi(Testing)
public enum SwallowedReturnPolicy {
    // WorkBuddy also contains non-chat editors. Its new retry membership must
    // not authorize clearing a long document through the shared chat list.
    public static let boundedClearBundleIDs: Set<String> = ["com.tencent.workbuddy.mac"]
    public static let chatComposerBundleIDs: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.openai.chat",
        "com.openai.codex",
        "com.tencent.workbuddy.mac",
        "com.tencent.xinWeChat",
        "com.tinyspeck.slackmacgap",
        "ru.keepcoder.Telegram",
        "com.tdesktop.Telegram",
        "com.hnc.Discord",
        "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp",
        "com.tencent.qq",
    ]

    public static func allowsRetry(bundleIdentifier: String?) -> Bool {
        _ = bundleIdentifier // The strict unchanged-AX-value rule replaces the bundle allowlist.
        return true
    }
}

extension ComposerTextNormalizer {
    /// Chromium rich-text composers (ProseMirror in the Claude app, among others) expose an
    /// empty field as one invisible line break or zero-width mark with the caret at 0. A paste
    /// or AXValue write replaces that phantom instead of keeping it, so the usual
    /// `original + text` document never appears. Spaces and tabs never qualify: a person can
    /// type those, and a paste keeps them.
    @_spi(Testing)
    public static func isPhantomEmpty(_ value: String?, selection: NSRange?) -> Bool {
        guard let value, let selection, selection.location == 0, selection.length == 0,
              value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else { return false }
        return [0x0A, 0x0D, 0x2028, 0x2029, 0x200B, 0xFEFF].contains(scalar.value)
    }

    /// True when the value has no visible characters (whitespace, newlines, zero-width marks).
    @_spi(Testing)
    public static func isBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar.value == 0x200B || scalar.value == 0x200C
                || scalar.value == 0x200D || scalar.value == 0xFEFF
        }
    }

    /// Some composers show their empty-state hint through AXValue, drop it the moment text
    /// arrives, and show it again after a send (ChatGPT for Mac: a 15-unit hint with the caret
    /// at 0:0). That hint is neither blank nor the sent text, so the usual "the field became
    /// empty" receipt never appears and every real send is reported as unconfirmed. The hint
    /// is recognized only from what this session itself saw: a non-blank value with the caret
    /// at 0:0 before dictation, absent from the text that was sent, and identical again after
    /// Return. Real draft text stays in the field next to dictated text, so it never matches.
    @_spi(Testing)
    public static func returnedToEmptyHint(
        original: String?,
        originalSelection: NSRange?,
        valueBeforeReturn: String,
        current: String
    ) -> Bool {
        guard let original, let originalSelection,
              originalSelection.location == 0, originalSelection.length == 0,
              !isBlank(original), !isBlank(valueBeforeReturn),
              current == original,
              valueBeforeReturn != original,
              !valueBeforeReturn.contains(original) else { return false }
        return true
    }
}
