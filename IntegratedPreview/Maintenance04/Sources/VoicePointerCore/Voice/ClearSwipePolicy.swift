import Foundation

/// What a down-swipe should do, decided only from facts the executor has already established.
///
/// The first down-swipe removes what was just dictated (the target's own Undo, or nothing to
/// remove when the text never reached the field). A second down-swipe at the same field, with the
/// field's text unchanged in between, clears the whole field. Nothing here touches Accessibility:
/// the executor gathers the facts and performs the plan, so every branch is unit-testable.
///
/// Why "unchanged text" and not a click counter, a timer or element identity: between two swipes a
/// stray pass-through click, a re-created accessibility element or a slow second gesture must not
/// cost the person their second swipe. Only an edit of the text itself does.
public enum SwipeDownEvidence: Equatable, Sendable {
    /// The field differs from how it looked when the gesture began: dictation landed in it.
    case dictationLanded
    /// Nothing landed in the field, but the person spoke: a dictation to discard.
    case spokeNothingLanded
    /// Nothing landed and nobody spoke: a plain flick of the disc.
    case silent
}

public enum SwipeDownPlan: Equatable, Sendable {
    /// Undo what landed (path-specific), then arm a second swipe.
    case removeDictation
    /// Nothing landed, so there is nothing to remove; keep the field as it is and arm.
    case discardDictation
    /// The second swipe: clear the whole field.
    case clearField
    /// A first plain flick with nothing to undo: remember it so a second one clears.
    case armOnly
    /// A plain flick on an empty field.
    case nothingToClear
}

/// What the microphone meter heard during the gesture.
public enum SpeechHeard: Equatable, Sendable {
    case speech
    case silence
    /// No usable reading: the meter never started, or delivered only zero buffers (Bluetooth
    /// headsets do this while switching profile). Never read as silence.
    case unknown
}

/// The receipt of a down-swipe that armed the next one.
public struct ClearArmRecord: Equatable, Sendable {
    public let processIdentifier: pid_t
    /// The field's text once the swipe's own edit (if any) had landed.
    public let text: String
    /// The text the field returns to if a slow Undo lands after the receipt was written.
    public let alternateText: String?
    public let expiresAt: UInt64

    public init(processIdentifier: pid_t, text: String, alternateText: String? = nil, expiresAt: UInt64) {
        self.processIdentifier = processIdentifier
        self.text = text
        self.alternateText = alternateText
        self.expiresAt = expiresAt
    }
}

public enum ClearSwipePolicy {
    /// How long a down-swipe keeps the next one armed. Content decides validity; the time only
    /// keeps an old receipt from surprising the person minutes later.
    public static let armWindowNanoseconds: UInt64 = 30_000_000_000
    /// Peak of the meter's level (0...1) above which the gesture counts as speech. Room noise on
    /// the built-in microphone peaks near 0.018; the quietest real dictation seen peaked at 0.036.
    public static let speechLevelThreshold: Float = 0.025
    /// A recognizer that heard nothing still returns a couple of characters of noise. Up to this
    /// many UTF-16 units of final text does not by itself prove the person spoke.
    public static let trivialTranscriptUTF16 = 2
    /// Above this many UTF-16 units a multi-line field is treated as a document, not a message.
    public static let maximumMessageLength = 2_000
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
        "co.zeit.hyper", "org.tabby",
    ]

    /// Reads the meter's peak level for the gesture.
    public static func heard(peakLevel: Float?) -> SpeechHeard {
        guard let peakLevel, peakLevel > 0 else { return .unknown }
        return peakLevel >= speechLevelThreshold ? .speech : .silence
    }

    public static func evidence(
        fieldChanged: Bool,
        heard: SpeechHeard,
        transcriptUTF16: Int?
    ) -> SwipeDownEvidence {
        if fieldChanged { return .dictationLanded }
        switch heard {
        case .speech:
            return .spokeNothingLanded
        case .silence:
            return .silent
        case .unknown:
            if let transcriptUTF16, transcriptUTF16 > trivialTranscriptUTF16 { return .spokeNothingLanded }
            return .silent
        }
    }

    public static func plan(evidence: SwipeDownEvidence, armed: Bool, fieldIsEmpty: Bool) -> SwipeDownPlan {
        switch evidence {
        case .dictationLanded: return .removeDictation
        case .spokeNothingLanded:
            if armed && !fieldIsEmpty { return .clearField }
            return .discardDictation
        case .silent:
            if fieldIsEmpty { return .nothingToClear }
            return armed ? .clearField : .armOnly
        }
    }

    /// The receipt is good for this field when the same app shows the same text, in time.
    public static func isArmed(
        _ arm: ClearArmRecord?,
        processIdentifier: pid_t,
        text: String,
        now: UInt64
    ) -> Bool {
        guard let arm, arm.processIdentifier == processIdentifier, now < arm.expiresAt else { return false }
        return text == arm.text || text == arm.alternateText
    }

    /// Chat apps always; other apps only for a single-line field or a short text, never for a
    /// terminal, where Select All would not select the input line.
    public static func allowsClear(bundleIdentifier: String?, role: String?, valueLength: Int) -> Bool {
        if let bundleIdentifier {
            if terminalBundleIDs.contains(bundleIdentifier) { return false }
            if SwallowedReturnPolicy.chatComposerBundleIDs.contains(bundleIdentifier) {
                return !SwallowedReturnPolicy.boundedClearBundleIDs.contains(bundleIdentifier) || valueLength <= maximumMessageLength
            }
        }
        if let role, ["AXTextField", "AXSearchField", "AXComboBox"].contains(role) { return true }
        return valueLength <= maximumMessageLength
    }
}

/// A gesture the microphone heard nothing in can still make a recognizer return a syllable of noise
/// (a 0.4 s tap on a quiet MacBook microphone returned two characters that were then pasted into the
/// field). Such a result is dropped; the gesture's own meaning (Send) still applies. Only a reading that
/// is plainly room noise counts: no reading, a reading of exact zeros (a Bluetooth headset switching
/// profile) or one anywhere near speech never drops anything, and neither does a longer transcript.
public enum SilentTranscriptPolicy {
    /// Peak (meter scale) below which the microphone heard only the room. The built-in microphone's noise
    /// peaks near 0.018 and the quietest real dictation seen peaked at 0.036, so this sits well below
    /// `ClearSwipePolicy.speechLevelThreshold` and a whispered word is never mistaken for noise.
    public static let noiseCeiling: Float = 0.02

    public static func shouldDrop(transcriptUTF16: Int, peakLevel: Float?) -> Bool {
        guard let peakLevel, peakLevel > 0, peakLevel < noiseCeiling else { return false }
        return transcriptUTF16 > 0 && transcriptUTF16 <= ClearSwipePolicy.trivialTranscriptUTF16
    }
}

/// The meter's reading for the gesture in progress or just ended, shared between the level
/// monitor (which measures) and the composer executor (which decides what a down-swipe means).
public final class GestureSpeechActivity: @unchecked Sendable {
    public static let shared = GestureSpeechActivity()
    private let lock = NSLock()
    private var peakLevel: Float?

    public init() {}

    /// A new gesture starts: forget the previous reading.
    public func beginGesture() {
        lock.withLock { peakLevel = nil }
    }

    /// The meter finished a capture whose loudest reading was `peak`.
    public func recordCapture(peakLevel peak: Float) {
        lock.withLock { peakLevel = max(peakLevel ?? 0, peak) }
    }

    public func heard() -> SpeechHeard {
        ClearSwipePolicy.heard(peakLevel: lock.withLock { peakLevel })
    }

    /// The loudest reading of this gesture so far, nil before the meter delivered one.
    public func loudestPeak() -> Float? { lock.withLock { peakLevel } }
}
