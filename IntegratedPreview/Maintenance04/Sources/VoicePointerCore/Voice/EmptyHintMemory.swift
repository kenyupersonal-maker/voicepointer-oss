import Foundation

/// The empty-state hint of composers that show it through AXValue.
///
/// ChatGPT for Mac reports "Message ChatGPT" (15 UTF-16 units, caret at 0:0) as the value of an empty
/// composer. The hint disappears the moment text arrives and comes back once the field is empty again.
/// Read literally, that looks like a write that lost the field's original text and like a send that
/// changed the field into something else: a dictation is reported as unconfirmed, the rest of a
/// realtime draft is never written and the send sound stays silent.
///
/// The memory recognizes such a hint from what actually happened, not from a list of apps, and keeps it
/// per process for as long as VoicePointer runs (memory only, nothing is written to disk):
///  - a *candidate* is a caret-0 value that vanished when our text landed in front of it;
///  - a *known* hint is a candidate that showed up again (after a send, or as the value of an empty field
///    at the start of a later dictation), or a hint learned from a confirmed clear or send.
/// A short seed table covers the hint of apps that have been seen, so the first dictation after a launch
/// needs no learning. A seed only ever matches exactly, at caret 0:0, so a wrong entry matches nothing.
@_spi(Testing)
public struct EmptyHintMemory: Sendable {
    /// A hint is a short interface string; anything longer is somebody's text.
    public static let maximumHintUTF16 = 200
    /// Processes remembered at once; the memory is dropped and relearned beyond this.
    public static let maximumProcesses = 64
    private static let seeds: [String: Set<String>] = [
        "com.openai.chat": ["Message ChatGPT"],
    ]

    private var known: [pid_t: String] = [:]
    private var candidates: [pid_t: String] = [:]

    public init() {}

    /// True when `text` is the hint this process's composer is known to show.
    public func isKnown(_ text: String, processIdentifier: pid_t) -> Bool {
        known[processIdentifier] == text
    }

    /// The hint this process's composer is known to show, if any.
    public func knownHint(for processIdentifier: pid_t) -> String? {
        known[processIdentifier]
    }

    /// Records a hint that a confirmed clear or send showed.
    public mutating func learn(_ hint: String, processIdentifier: pid_t) {
        guard Self.plausible(hint) else { return }
        if known.count >= Self.maximumProcesses, known[processIdentifier] == nil { known.removeAll() }
        known[processIdentifier] = hint
        if candidates[processIdentifier] == hint { candidates[processIdentifier] = nil }
    }

    /// A value that could be a hint: something visible, short, with the caret at the very start and
    /// nothing selected. Real drafts can look like this too, which is why a hint is only accepted once
    /// it has been seen vanishing and coming back.
    public static func mayShowHint(original: String?, selection: NSRange?) -> Bool {
        guard let original, let selection, selection.location >= 0, selection.location <= 1, selection.length == 0 else { return false }
        return plausible(original)
    }

    /// The field's value at the start of a dictation is this app's empty-state hint.
    public mutating func recognizesAtStart(
        value: String?, selection: NSRange?, processIdentifier: pid_t, bundleIdentifier: String?
    ) -> Bool {
        guard let value, Self.mayShowHint(original: value, selection: selection) else { return false }
        return matches(value, processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier)
    }

    /// After a send, the field shows this app's hint again: it is empty, the message went out. Text that
    /// was sent and is still there (or that contains the hint) never qualifies.
    public mutating func recognizesAfterSend(
        current: String, valueBeforeReturn: String, processIdentifier: pid_t, bundleIdentifier: String?
    ) -> Bool {
        guard Self.plausible(current), current != valueBeforeReturn,
              !valueBeforeReturn.contains(current) else { return false }
        return matches(current, processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier)
    }

    /// Our text was inserted in front of a caret-0 value and the field now holds exactly that text: the
    /// value that stood there is gone. It is remembered as a candidate hint. Refused when the value
    /// stayed (a real draft), when anything else changed, or when the value could not be a hint.
    @discardableResult
    public mutating func noteVanished(
        original: String?, selection: NSRange?, expectedDocument: String, observed: String,
        processIdentifier: pid_t
    ) -> Bool {
        guard let original, Self.mayShowHint(original: original, selection: selection),
              !ComposerTextNormalizer.isBlank(observed) else { return false }
        guard let selection, Range(selection, in: original) != nil,
              expectedDocument.utf16.elementsEqual((original as NSString).replacingCharacters(in: selection, with: observed).utf16)
        else { return false }
        if candidates.count >= Self.maximumProcesses, candidates[processIdentifier] == nil { candidates.removeAll() }
        candidates[processIdentifier] = original
        return true
    }

    private mutating func matches(_ text: String, processIdentifier: pid_t, bundleIdentifier: String?) -> Bool {
        if known[processIdentifier] == text { return true }
        let seeded = bundleIdentifier.flatMap { Self.seeds[$0] }?.contains(text) ?? false
        if candidates[processIdentifier] == text || seeded {
            learn(text, processIdentifier: processIdentifier)
            return true
        }
        return false
    }

    private static func plausible(_ text: String) -> Bool {
        text.utf16.count <= maximumHintUTF16 && !ComposerTextNormalizer.isBlank(text)
    }
}
