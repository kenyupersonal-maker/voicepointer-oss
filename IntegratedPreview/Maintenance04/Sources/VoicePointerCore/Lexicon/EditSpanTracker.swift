import Foundation

/// Follows one dictation inside the text field it was delivered to, sample after sample of the field's text.
///
/// The field is the person's, and they type in it: before the dictation, after it, in the middle. To learn
/// from a fix the person made to the dictated words, the tracker has to know exactly which part of the field
/// is still the dictation. It does not search for the dictation by its words (repeated text would mislead it)
/// and does not diff whole fields (the person's own typing would look like dictation). It keeps the span and
/// classifies every change by where it fell: before the span (the span shifts), after it (nothing changes),
/// inside it (the dictation was edited) or across a border (ambiguous: stop, learn nothing more).
///
/// When the same result could come from an edit inside the dictation or one just outside it (typing an "f"
/// in front of "foo" reads the same either way), the outside reading wins, so nothing is learned from it.
///
/// Pure: no Accessibility, no clock. Texts are compared by characters, so an emoji or an accented letter is
/// never cut in two.
public struct EditSpanTracker: Sendable {
    public enum Event: Equatable, Sendable {
        /// The same text as before.
        case unchanged
        /// The text changed before or after the dictation only; the dictation itself is as it was.
        case outsideEdit
        /// The dictation's own text changed.
        case dictationEdited
        /// The field is blank or shows its empty-state text again: the message was sent or removed.
        case cleared
        /// A change crossed the border of the dictation, so which part is which cannot be told.
        case ambiguous
        /// The words that stood there before the dictation (a replaced selection, an earlier draft) are back:
        /// Undo took the dictation away, which is not a correction the person made.
        case undone
        /// The field is longer than anything worth reading.
        case tooLarge
        /// The text differs but no key or mouse press happened since the baseline: the app or the recognizer
        /// changed it, not the person.
        case noHumanInput
    }

    /// Fields longer than this (in UTF-16 units) are not followed.
    public static let maximumDocumentUTF16 = 20_000

    private enum Placement {
        case before, after, inside, crossing
    }

    private var characters: [Character]
    private var start: Int
    private var end: Int
    private let emptyStateValues: [String]
    private let revertTexts: [String]
    /// `EditingIntentClock`'s count at the baseline; a sample with the same count saw no key or mouse press.
    public let baselineGeneration: UInt64
    /// Set once the tracker has reached an event it cannot go on from; it then repeats that event.
    public private(set) var closedBy: Event?

    /// `spanLocation`/`spanLength` are UTF-16 units in `document`. Nil when the span is empty or out of range,
    /// starts or ends inside a character, the field is too long, or the span's text is not `delivered`.
    /// `revertTexts` are texts that stood in the field's place before, or that the dictation itself once
    /// was (the selection it replaced, its earlier drafts): the dictation reading exactly like one of them
    /// later means Undo, not a correction.
    public init?(
        document: String,
        spanLocation: Int,
        spanLength: Int,
        delivered: String,
        emptyStateValues: [String],
        editingGeneration: UInt64,
        revertTexts: [String] = []
    ) {
        guard spanLocation >= 0, spanLength > 0, document.utf16.count <= Self.maximumDocumentUTF16 else { return nil }
        let raw = Array(document)
        var unitOffset = 0
        var startIndex: Int?
        var endIndex: Int?
        for (index, character) in raw.enumerated() {
            if unitOffset == spanLocation { startIndex = index }
            if unitOffset == spanLocation + spanLength { endIndex = index }
            unitOffset += character.unicodeScalars.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
        }
        if unitOffset == spanLocation + spanLength { endIndex = raw.count }
        var characters = Self.comparable(raw)
        guard let startIndex, let endIndex, startIndex < endIndex,
              String(characters[startIndex..<endIndex]) == String(Self.comparable(Array(delivered))),
              !characters[endIndex - 1].isNewline else { return nil }
        // A line break after the dictation is the editor's or the person's, and comes and goes between reads.
        while characters.count > endIndex, let last = characters.last, last.isNewline { characters.removeLast() }
        self.characters = characters
        self.start = startIndex
        self.end = endIndex
        self.emptyStateValues = emptyStateValues
        self.revertTexts = revertTexts.map { String(Self.comparable(Array($0))) }
        self.baselineGeneration = editingGeneration
    }

    /// Characters as they are compared. Web editors put a non-breaking space where a space was typed at the
    /// end of a line or next to another space; here it reads as a space (one character for one character, so
    /// every position holds).
    private static func comparable(_ characters: [Character]) -> [Character] {
        characters.map { $0 == "\u{00A0}" || $0 == "\u{202F}" ? Character(" ") : $0 }
    }

    /// The dictation as it stands in the last accepted sample.
    public var dictation: String { String(characters[start..<end]) }

    /// The whole field as of the last accepted sample.
    public var document: String { String(characters) }

    /// One sample of the field's text (`nil`: it could not be read; nothing is learned from that).
    /// `editingGeneration` is `EditingIntentClock`'s count at the time of the sample.
    public mutating func observe(document sample: String?, editingGeneration: UInt64) -> Event {
        if let closedBy { return closedBy }
        guard let sample else { return .unchanged }
        guard sample.utf16.count <= Self.maximumDocumentUTF16 else { return close(.tooLarge) }
        var new = Self.comparable(Array(sample))
        while let last = new.last, last.isNewline { new.removeLast() }
        if new == characters { return .unchanged }
        if sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || emptyStateValues.contains(sample) {
            return close(.cleared)
        }
        if editingGeneration == baselineGeneration { return .noHumanInput }

        let byPrefix = Self.placement(old: characters, new: new, start: start, end: end, prefixFirst: true)
        let bySuffix = Self.placement(old: characters, new: new, start: start, end: end, prefixFirst: false)
        var placement = byPrefix
        if byPrefix != bySuffix {
            if byPrefix == .crossing || bySuffix == .crossing {
                placement = .crossing
            } else if byPrefix == .before || bySuffix == .before {
                placement = byPrefix == .after || bySuffix == .after ? .crossing : .before
            } else {
                placement = .after
            }
        }

        let delta = new.count - characters.count
        switch placement {
        case .before:
            start += delta
            end += delta
            characters = new
            return .outsideEdit
        case .after:
            characters = new
            return .outsideEdit
        case .inside:
            end += delta
            characters = new
            if end <= start { return close(.cleared) }
            if revertTexts.contains(dictation) { return close(.undone) }
            return .dictationEdited
        case .crossing:
            return close(.ambiguous)
        }
    }

    private mutating func close(_ event: Event) -> Event {
        closedBy = event
        return event
    }

    /// Where the changed region between `old` and `new` falls relative to the span. The region is what is left
    /// once the common start and the common end are taken away; which of the two is taken first decides where
    /// an insertion of repeated text is placed, so both are asked.
    private static func placement(
        old: [Character], new: [Character], start: Int, end: Int, prefixFirst: Bool
    ) -> Placement {
        let common = min(old.count, new.count)
        var prefix = 0
        var suffix = 0
        if prefixFirst {
            while prefix < common, old[prefix] == new[prefix] { prefix += 1 }
            while suffix < common - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        } else {
            while suffix < common, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            while prefix < common - suffix, old[prefix] == new[prefix] { prefix += 1 }
        }
        let regionEnd = old.count - suffix
        if regionEnd <= start { return .before }
        if prefix >= end { return .after }
        if prefix >= start, regionEnd <= end { return .inside }
        return .crossing
    }
}
