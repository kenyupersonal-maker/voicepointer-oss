import Foundation
@_spi(Testing) import VoicePointerCore

/// Pure mapping checks; no AX, keyboard, permissions, or business input is touched.
public enum ComposerFeedbackChecks {
    public static func run() -> [String] {
        var failures = checkAXWriteClassification()
        failures += checkDeliveryObservation()
        failures += checkFocusEventGate()
        failures += checkDownSwipePolicy()
        for (action, expected) in [
            (VoiceReleaseAction.send, ComposerActionOutcome.sendUnconfirmed),
            (.cancel, .cancelUnconfirmed), (.stop, .kept),
        ] where ComposerActionOutcome.unresolvedOperation(action) != expected {
            failures.append("outer AX deadline must preserve uncertainty: \(action.rawValue)")
        }
        let expected: [(ComposerActionOutcome, String, ComposerActionFeedback.Kind, Bool)] = [
            (.kept, "", .info, false),
            (.sent, "", .success, false),
            (.nothingToSend, "", .info, false),
            (.removedCurrentDictation, "", .success, false),
            (.clearedCurrentInput, "", .success, false),
            (.clearArmed, "再下滑清空", .info, true),
            (.nothingToCancel, "", .info, false),
            (.targetChanged, "", .warning, false),
            (.unsafeToCancel, "没删掉，请手动删一下", .warning, true),
            (.deliveryFailed, "文字写入失败，请重新点选输入框", .warning, true),
            (.eventPostFailed, "操作未能完成，请重试", .warning, true),
            (.dictationNotSettled, VoiceIssuePresentationPolicy.dictationNotSettledMessage, .warning, true),
            (.sendUnconfirmed, "", .warning, false),
            (.sendStillPresent, "没发出去，文字还在", .warning, true),
            (.cancelUnconfirmed, "", .warning, false),
            (.deliveryUnconfirmed, "", .warning, false),
        ]
        for (outcome, message, kind, shouldPresent) in expected {
            let feedback = ComposerActionFeedback(outcome: outcome)
            if feedback.message != message || feedback.kind != kind || feedback.shouldPresent != shouldPresent {
                failures.append("feedback mapping mismatch: \(outcome.rawValue)")
            }
            if feedback.message.contains("已保留文字") {
                failures.append("feedback must not claim retained text: \(outcome.rawValue)")
            }
        }
        for outcome in [ComposerActionOutcome.sendUnconfirmed, .sendStillPresent, .cancelUnconfirmed]
            where ComposerActionFeedback(outcome: outcome).kind == .success {
            failures.append("unconfirmed outcome cannot be success: \(outcome.rawValue)")
        }
        // A composer left with only a newline / zero-width mark after Return is cleared.
        if !ComposerTextNormalizer.isBlank("\n") || !ComposerTextNormalizer.isBlank("\u{200B}")
            || !ComposerTextNormalizer.isBlank(" \n\u{FEFF}") || ComposerTextNormalizer.isBlank("a")
            || ComposerTextNormalizer.isBlank(" 好 ") {
            failures.append("blank composer detection mismatch")
        }
        // Only a lone invisible line break / zero-width mark with the caret at 0 is a phantom-empty
        // Chromium composer; spaces, two line breaks, other carets and real text are real content.
        let origin = NSRange(location: 0, length: 0)
        if !ComposerTextNormalizer.isPhantomEmpty("\n", selection: origin)
            || !ComposerTextNormalizer.isPhantomEmpty("\u{200B}", selection: origin)
            || ComposerTextNormalizer.isPhantomEmpty("\n", selection: NSRange(location: 1, length: 0))
            || ComposerTextNormalizer.isPhantomEmpty("\n", selection: NSRange(location: 0, length: 1))
            || ComposerTextNormalizer.isPhantomEmpty(" ", selection: origin)
            || ComposerTextNormalizer.isPhantomEmpty("\t", selection: origin)
            || ComposerTextNormalizer.isPhantomEmpty("\n\n", selection: origin)
            || ComposerTextNormalizer.isPhantomEmpty("a", selection: origin)
            || ComposerTextNormalizer.isPhantomEmpty("", selection: origin)
            || ComposerTextNormalizer.isPhantomEmpty(nil, selection: origin)
            || ComposerTextNormalizer.isPhantomEmpty("\n", selection: nil) {
            failures.append("phantom-empty composer detection mismatch")
        }
        // A composer that shows its empty-state hint through AXValue (ChatGPT for Mac) is back to
        // that hint after a send. Only a caret-0 hint that vanished with the dictated text counts;
        // draft text that stays next to the dictation, other carets, selections, an unchanged or
        // different value, blank pieces and a missing original are never mistaken for it.
        let hint = "Message ChatGPT"
        let hintCases: [(original: String?, selection: NSRange?, before: String, current: String, expected: Bool)] = [
            (hint, origin, "你好世界", hint, true),
            (hint, origin, "hello", hint, true),
            ("草稿", origin, "你好草稿", "草稿", false),
            (hint, NSRange(location: 15, length: 0), "你好", hint, false),
            (hint, NSRange(location: 0, length: 15), "你好", hint, false),
            (hint, origin, "你好", "别的", false),
            (hint, origin, hint, hint, false),
            ("\n", origin, "你好", "\n", false),
            (hint, origin, " ", hint, false),
            (nil, origin, "你好", hint, false),
            (hint, nil, "你好", hint, false),
            (hint, origin, "说 Message ChatGPT 吧", hint, false),
        ]
        for (index, item) in hintCases.enumerated()
        where ComposerTextNormalizer.returnedToEmptyHint(
            original: item.original, originalSelection: item.selection,
            valueBeforeReturn: item.before, current: item.current) != item.expected {
            failures.append("empty-hint composer return case \(index) mismatch")
        }
        // R67: return retry is gated by an entire unchanged observation window,
        // not by a target's bundle identity.
        if !SwallowedReturnPolicy.allowsRetry(bundleIdentifier: "com.anthropic.claudefordesktop")
            || !SwallowedReturnPolicy.allowsRetry(bundleIdentifier: "com.tencent.xinWeChat")
            || !SwallowedReturnPolicy.allowsRetry(bundleIdentifier: "com.apple.Safari")
            || !SwallowedReturnPolicy.allowsRetry(bundleIdentifier: "com.apple.TextEdit")
            || !SwallowedReturnPolicy.allowsRetry(bundleIdentifier: nil) {
            failures.append("swallowed-Return retry must not use a bundle allowlist")
        }
        return failures
    }

    /// The down-swipe decision is pure, so every branch is checked here rather than on a device:
    /// what counts as speech, which gestures are a first or a second swipe, when a receipt is good,
    /// and where clearing a field is refused.
    private static func checkDownSwipePolicy() -> [String] {
        var failures: [String] = []

        // Speech reading: no reading or only zero buffers is unknown, never silence.
        let heardCases: [(Float?, SpeechHeard)] = [
            (nil, .unknown), (0, .unknown), (0.005, .silence), (0.0177, .silence),
            (0.0249, .silence), (0.025, .speech), (0.036, .speech), (0.4, .speech),
        ]
        for (index, item) in heardCases.enumerated()
        where ClearSwipePolicy.heard(peakLevel: item.0) != item.1 {
            failures.append("speech reading case \(index) mismatch")
        }

        // Evidence: text that landed always wins; a meter reading beats the recognizer; only with no
        // reading does a couple of characters of recognizer noise count as silence.
        let evidenceCases: [(Bool, SpeechHeard, Int?, SwipeDownEvidence)] = [
            (true, .silence, nil, .dictationLanded), (true, .speech, 9, .dictationLanded),
            (false, .speech, 2, .spokeNothingLanded), (false, .speech, nil, .spokeNothingLanded),
            (false, .silence, 2, .silent), (false, .silence, 40, .silent),
            (false, .unknown, 2, .silent), (false, .unknown, 0, .silent),
            (false, .unknown, 3, .spokeNothingLanded), (false, .unknown, nil, .silent),
        ]
        for (index, item) in evidenceCases.enumerated()
        where ClearSwipePolicy.evidence(fieldChanged: item.0, heard: item.1, transcriptUTF16: item.2) != item.3 {
            failures.append("swipe evidence case \(index) mismatch")
        }

        // Plan: landed dictation always gets Undo. A valid arm on a nonempty field clears even
        // when speech was heard but no new dictation landed; unarmed speech is discarded.
        let planCases: [(SwipeDownEvidence, Bool, Bool, SwipeDownPlan)] = [
            (.dictationLanded, false, false, .removeDictation), (.dictationLanded, true, false, .removeDictation),
            (.spokeNothingLanded, false, false, .discardDictation), (.spokeNothingLanded, true, false, .clearField),
            (.spokeNothingLanded, true, true, .discardDictation),
            (.silent, false, false, .armOnly), (.silent, true, false, .clearField),
            (.silent, false, true, .nothingToClear), (.silent, true, true, .nothingToClear),
        ]
        for (index, item) in planCases.enumerated()
        where ClearSwipePolicy.plan(evidence: item.0, armed: item.1, fieldIsEmpty: item.2) != item.3 {
            failures.append("swipe plan case \(index) mismatch")
        }

        // Receipt: same app, same text (or the text an Undo returns to), inside the window. A stray
        // click changes nothing here, an edit or another app or an old receipt does.
        let second: UInt64 = 1_000_000_000
        let arm = ClearArmRecord(processIdentifier: 42, text: "abc", alternateText: "ab", expiresAt: 30 * second)
        let armCases: [(ClearArmRecord?, pid_t, String, UInt64, Bool)] = [
            (arm, 42, "abc", 5 * second, true), (arm, 42, "ab", 5 * second, true),
            (arm, 42, "abcd", 5 * second, false), (arm, 43, "abc", 5 * second, false),
            (arm, 42, "abc", 30 * second, false), (arm, 42, "abc", 31 * second, false),
            (nil, 42, "abc", 0, false),
            (ClearArmRecord(processIdentifier: 42, text: "abc", expiresAt: 30 * second), 42, "ab", second, false),
        ]
        for (index, item) in armCases.enumerated()
        where ClearSwipePolicy.isArmed(item.0, processIdentifier: item.1, text: item.2, now: item.3) != item.4 {
            failures.append("clear receipt case \(index) mismatch")
        }

        // Where a clear is allowed: chat apps always, terminals never, other apps for single-line
        // fields or short text.
        let clearCases: [(String?, String?, Int, Bool)] = [
            ("com.tencent.xinWeChat", "AXTextArea", 5_000, true),
            ("com.anthropic.claudefordesktop", nil, 10_000, true),
            ("com.apple.Terminal", "AXTextArea", 10, false),
            ("com.googlecode.iterm2", "AXTextField", 10, false),
            ("com.google.Chrome", "AXTextField", 5_000, true),
            ("com.google.Chrome", "AXTextArea", 500, true),
            ("com.google.Chrome", "AXTextArea", 5_000, false),
            (nil, nil, 1_999, true), (nil, nil, 2_001, false),
        ]
        for (index, item) in clearCases.enumerated()
        where ClearSwipePolicy.allowsClear(bundleIdentifier: item.0, role: item.1, valueLength: item.2) != item.3 {
            failures.append("clear allowance case \(index) mismatch")
        }

        // Noise from a gesture that only heard the room is dropped; anything else, and any unreliable
        // reading, is delivered.
        let silentCases: [(Int, Float?, Bool)] = [
            (2, 0.008, true), (1, 0.0177, true), (2, 0.0199, true),
            (2, 0.02, false), (2, 0.0249, false), (2, 0.036, false), (2, 0.4, false),
            (3, 0.008, false), (40, 0.008, false), (0, 0.008, false),
            (2, nil, false), (2, 0, false), (2, -0.1, false),
        ]
        for (index, item) in silentCases.enumerated()
        where SilentTranscriptPolicy.shouldDrop(transcriptUTF16: item.0, peakLevel: item.1) != item.2 {
            failures.append("silent transcript case \(index) mismatch")
        }
        if SilentTranscriptPolicy.noiseCeiling >= ClearSwipePolicy.speechLevelThreshold {
            failures.append("the noise ceiling must sit below the speech threshold")
        }

        // The shared meter reading: a new gesture forgets the last one, the loudest capture wins.
        let activity = GestureSpeechActivity()
        if activity.heard() != .unknown { failures.append("fresh meter reading must be unknown") }
        activity.recordCapture(peakLevel: 0.01)
        activity.recordCapture(peakLevel: 0.06)
        activity.recordCapture(peakLevel: 0.02)
        if activity.heard() != .speech { failures.append("loudest capture must decide the reading") }
        if activity.loudestPeak() != 0.06 { failures.append("loudest peak must be readable") }
        activity.beginGesture()
        if activity.heard() != .unknown { failures.append("a new gesture must forget the last reading") }
        if activity.loudestPeak() != nil { failures.append("a new gesture must forget the peak too") }
        return failures
    }

    /// Pure checks of the shared focus-event gate semantics: repeated
    /// matching notifications stay silent, the first real mismatch
    /// invalidates exactly once, invalidation is irreversible, and unknown
    /// notifications are treated as non-matching. The booleans mirror what
    /// the production Context derives from real CFEqual identity checks —
    /// verifying those against live AX notifications still requires real
    /// on-device verification and is not claimed here.
    private static func checkFocusEventGate() -> [String] {
        var failures: [String] = []

        // Repeated same-element focus notifications: never invalidates.
        let repeatGate = ComposerFocusEventGate()
        for _ in 0..<12 {
            if repeatGate.shouldInvalidate(matchesFrozenIdentity: true) {
                failures.append("gate must not invalidate matching focus notifications")
                break
            }
        }
        if repeatGate.isInvalidated {
            failures.append("gate must remain uninvalidated for matching notifications")
        }

        // Same-window focus notifications: never invalidates.
        let windowGate = ComposerFocusEventGate()
        for _ in 0..<12 {
            if windowGate.shouldInvalidate(matchesFrozenIdentity: true) {
                failures.append("gate must not invalidate same-window notifications")
                break
            }
        }

        // A -> B -> A: first mismatch invalidates, switching back cannot
        // revive (no second invalidation, state stays invalidated).
        let switchGate = ComposerFocusEventGate()
        if !switchGate.shouldInvalidate(matchesFrozenIdentity: false) {
            failures.append("gate must invalidate on first identity mismatch")
        }
        if switchGate.shouldInvalidate(matchesFrozenIdentity: true) {
            failures.append("gate must not invalidate again after switching back")
        }
        if switchGate.shouldInvalidate(matchesFrozenIdentity: false) {
            failures.append("gate must not invalidate twice")
        }
        if !switchGate.isInvalidated {
            failures.append("gate must stay invalidated irreversibly")
        }

        // Workspace equivalence: same frozen pid re-activation is matching;
        // a different pid invalidates once; unknown app (false) invalidates.
        let wsGate = ComposerFocusEventGate()
        if wsGate.shouldInvalidate(matchesFrozenIdentity: true) {
            failures.append("workspace same-pid activation must not invalidate")
        }
        if !wsGate.shouldInvalidate(matchesFrozenIdentity: false) {
            failures.append("workspace different-pid activation must invalidate")
        }
        if wsGate.shouldInvalidate(matchesFrozenIdentity: false) {
            failures.append("workspace must not invalidate twice")
        }

        // Unknown notification kinds map to non-matching (false).
        let unknownGate = ComposerFocusEventGate()
        if !unknownGate.shouldInvalidate(matchesFrozenIdentity: false) {
            failures.append("unknown notifications must be treated as non-matching")
        }

        // Concurrent false evaluations: exactly one true among 100.
        let concurrentGate = ComposerFocusEventGate()
        let counter = ManagedAtomicLike()
        let group = DispatchGroup()
        for _ in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                if concurrentGate.shouldInvalidate(matchesFrozenIdentity: false) {
                    counter.increment()
                }
                group.leave()
            }
        }
        group.wait()
        if counter.value != 1 {
            failures.append("concurrent invalidation must happen exactly once, got \(counter.value)")
        }
        if !concurrentGate.isInvalidated {
            failures.append("concurrent gate must end invalidated")
        }

        // An old gate's invalidation must not affect a fresh gate.
        let oldGate = ComposerFocusEventGate()
        _ = oldGate.shouldInvalidate(matchesFrozenIdentity: false)
        let newGate = ComposerFocusEventGate()
        if newGate.isInvalidated {
            failures.append("new gate must be independent of old gate invalidation")
        }
        if newGate.shouldInvalidate(matchesFrozenIdentity: true) {
            failures.append("new gate must respect matching notifications")
        }

        return failures
    }

    /// Minimal thread-safe counter for the concurrency check (Swift 6:
    /// no captured mutable vars across concurrent closures).
    private final class ManagedAtomicLike: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private static func checkAXWriteClassification() -> [String] {
        let cases: [(ComposerAXWriteEvent, ComposerAXWriteResult)] = [
            (.cancelledBeforeCall, .beforeWriteRejected),
            (.settableQueryFailed, .beforeWriteRejected),
            (.settableUnsupported, .unavailable),
            (.notSettable, .unavailable),
            (.axSetSuccess, .submitted),
            (.axSetCannotComplete, .submittedButUnconfirmed),
            (.axSetFailed, .submittedButUnconfirmed),
        ]
        return cases.compactMap { event, expected in
            ComposerAXWriteResult.classify(event) == expected
                ? nil
                : "AX write classification mismatch: \(event.rawValue)"
        }
    }

    private static func checkDeliveryObservation() -> [String] {
        var failures: [String] = []

        func confirms(expected: String, sequence: [String?]) -> Bool {
            var observation = ComposerDeliveryObservation(expected: expected)
            var result = false
            for value in sequence {
                if observation.observe(value) { result = true }
            }
            return result
        }

        let expected = "你好，世界🙂"
        if !confirms(expected: expected, sequence: [expected, expected]) {
            failures.append("delivery observation must confirm two consecutive exact observations")
        }
        if !confirms(expected: expected, sequence: [nil, expected, expected]) {
            failures.append("delivery observation must confirm after a transient nil")
        }
        if !confirms(expected: expected, sequence: ["部分文字", expected, expected]) {
            failures.append("delivery observation must confirm after a transient partial value")
        }
        if confirms(expected: expected, sequence: Array(repeating: "你好世界", count: 6)) {
            failures.append("delivery observation must never confirm mismatching text")
        }
        if confirms(expected: expected, sequence: [expected, nil, expected]) {
            failures.append("delivery observation must not confirm across an interrupting nil")
        }
        if confirms(expected: expected, sequence: [expected, "你好，世界", expected]) {
            failures.append("delivery observation must not confirm across an interrupting mismatch")
        }
        if confirms(expected: "你好。", sequence: ["你好，", "你好、", "你好。"]) {
            failures.append("delivery observation must not confirm punctuation differences")
        }
        if confirms(expected: " 你好", sequence: ["你好", "你好", "你好 "]) {
            failures.append("delivery observation must not confirm whitespace differences")
        }
        if !confirms(expected: "🙂👍", sequence: ["🙂👍", "🙂👍"]) {
            failures.append("delivery observation must confirm emoji text")
        }
        if confirms(expected: "🙂", sequence: ["👍", "🙂🏽", "🙂"]) {
            failures.append("delivery observation must not confirm different emoji")
        }
        // String == uses standard codepoint-equivalent semantics.
        let decomposed = "e\u{301}"
        if !confirms(expected: decomposed, sequence: ["\u{00E9}", "\u{00E9}"]) {
            failures.append("delivery observation must use codepoint-equivalent String semantics")
        }
        if confirms(expected: "abc", sequence: ["ab", "abcd", "abcd"]) {
            failures.append("delivery observation must not confirm substring or superstring text")
        }
        // Empty Chromium composer: the paste replaces the phantom line break, so the bare
        // transcript is the one other exact proof. A primary and an alternate never pair up.
        var phantom = ComposerDeliveryObservation(expected: "你好\n", alternate: "你好")
        let phantomFirst = phantom.observe("你好")
        let phantomSecond = phantom.observe("你好")
        if phantomFirst || !phantomSecond || !phantom.matchedAlternate {
            failures.append("delivery observation must confirm two exact phantom-empty alternates")
        }
        var mixed = ComposerDeliveryObservation(expected: "你好\n", alternate: "你好")
        let mixedFirst = mixed.observe("你好\n")
        let mixedSecond = mixed.observe("你好")
        if mixedFirst || mixedSecond {
            failures.append("delivery observation must not pair a primary and an alternate observation")
        }
        var primary = ComposerDeliveryObservation(expected: "你好\n", alternate: "你好")
        let primaryFirst = primary.observe("你好\n")
        let primarySecond = primary.observe("你好\n")
        if primaryFirst || !primarySecond || primary.matchedAlternate {
            failures.append("delivery observation with an alternate must still confirm the primary")
        }
        var plain = ComposerDeliveryObservation(expected: "你好\n")
        let plainFirst = plain.observe("你好")
        let plainSecond = plain.observe("你好")
        if plainFirst || plainSecond {
            failures.append("delivery observation without an alternate must stay exact")
        }
        var fuzzy = ComposerDeliveryObservation(expected: "你好\n", alternate: "你好")
        if fuzzy.observe("你好 ") || fuzzy.observe("你好 ") || fuzzy.observe("你") || fuzzy.observe("你") {
            failures.append("phantom-empty alternate must not confirm near matches")
        }
        let failed = ComposerActionFeedback(outcome: .deliveryFailed)
        if failed.message != "文字写入失败，请重新点选输入框" || failed.message.contains("预览") {
            failures.append("deliveryFailed message must tell the user to reselect the input field")
        }
        return failures
    }
}
