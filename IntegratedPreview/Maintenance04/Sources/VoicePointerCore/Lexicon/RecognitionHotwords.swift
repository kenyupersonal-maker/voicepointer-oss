import Foundation

/// Which words of the personal lexicon are worth telling a speech recognizer, and the one line they travel in.
///
/// A recognizer that takes a vocabulary hint (the local Qwen models take a line of text as context) hears the
/// words on the list more readily, and each word on it also pulls the recognizer a little toward that word
/// where a different one was said. So the list is short, and it is filled by two kinds of entry taking turns:
/// entries with a wrong spelling on record (the recognizer has been caught getting them wrong; the ones that
/// corrected the most dictations first) and plain words the person added as common words (newest first).
/// Taking turns keeps a lexicon full of one kind from shutting the other out. What does not fit is left out
/// of the list; the lexicon itself is never touched. Entries of every source qualify: the words go only to a
/// recognizer on this Mac.
///
/// Pure: no clock, no files. Nothing here sends anything anywhere; whatever carries the line decides that.
public enum RecognitionHotwords {
    public static func isEcho(text: String, words: [String], durationSeconds: Double) -> Bool {
        let count = echoedWordCount(in: text, words: words)
        return count >= 3 && durationSeconds.isFinite && durationSeconds >= 0 && durationSeconds < Double(count) * 0.5
    }
    /// A short list is what a hint can carry before it starts to crowd out the words actually said.
    public static let maximumTerms = 32
    /// UTF-8 bytes of the joined line. The local worker accepts 1024; a hint this size stays far below that.
    public static let maximumBytes = 400
    /// A single character is no word to listen for, and a lone letter would pull on every sentence.
    public static let minimumCharacters = 2

    /// The canonical spellings of the enabled entries worth offering, best first, within the limits.
    public static func select(from terms: [LexiconTerm]) -> [String] {
        let enabled = terms.enumerated().filter { $0.element.isEnabled && $0.element.source != .automaticallyLearned }
        let corrected = enabled.filter { !$0.element.variants.isEmpty }.sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.hitCount != b.hitCount { return a.hitCount > b.hitCount }
            let (aHit, bHit) = (a.lastHitAt ?? .distantPast, b.lastHitAt ?? .distantPast)
            if aHit != bHit { return aHit > bHit }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return lhs.offset < rhs.offset
        }
        let plain = enabled.filter { $0.element.variants.isEmpty }.sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt { return lhs.element.createdAt > rhs.element.createdAt }
            return lhs.offset < rhs.offset
        }
        var ordered: [String] = []
        for index in 0..<max(corrected.count, plain.count) {
            if index < corrected.count { ordered.append(corrected[index].element.canonical) }
            if index < plain.count { ordered.append(plain[index].element.canonical) }
        }
        // The original four human-owned sources keep their existing ordering and all capacity
        // priority. Machine-learned entries cannot enter the actual hint list until three genuine
        // final-text replacements have been recorded by LexiconStore.
        var selected = clean(ordered)
        let automatic = terms.filter {
            $0.isEnabled && $0.source == .automaticallyLearned && $0.hitCount >= 3
                && !$0.variants.isEmpty
        }.sorted { left, right in
            if left.hitCount != right.hitCount { return left.hitCount > right.hitCount }
            return left.createdAt > right.createdAt
        }
        let manualCount = selected.count
        // For an actual final list, auto <= floor(total / 4), equivalent to auto <= manual / 3.
        let automaticAllowance = min(maximumTerms / 4, manualCount / 3)
        for term in automatic.prefix(automaticAllowance) {
            let next = clean(selected + [term.canonical])
            if next.count > selected.count { selected = next }
        }
        return selected
    }

    /// Whether the local recognizer behind `routeID` takes hot words (the Qwen models do; the others ignore them).
    public static func localRouteAccepts(_ routeID: String) -> Bool {
        BetaRecognitionContext.supports(profileID: routeID)
    }

    /// The words as a recognizer may take them: trimmed, free of control characters, one of each (case
    /// ignored), long enough, and at most `maximumTerms` words and `maximumBytes` in the joined line. A word
    /// that does not fit is skipped, and a shorter one after it may still fit. The order is kept.
    public static func clean(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        var bytes = 0
        for raw in words {
            if kept.count >= maximumTerms { break }
            let word = trimmed(raw)
            let key = word.lowercased()
            guard word.count >= minimumCharacters,
                  !word.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
                  !seen.contains(key) else { continue }
            let cost = word.utf8.count + (kept.isEmpty ? 0 : 2)
            guard bytes + cost <= maximumBytes else { continue }
            seen.insert(key)
            kept.append(word)
            bytes += cost
        }
        return kept
    }

    /// The words joined into the single line a local recognizer takes as context, or nil when none is left.
    public static func line(for words: [String]) -> String? {
        let kept = clean(words)
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }

    /// How many distinct hot words `text` is made of when it is nothing but hot words and the separators between
    /// them (which is how an echo of the hint would look); 0 for any other text. Case is ignored. For
    /// observation only: a dictation that really is just a hot word looks the same, so nothing is dropped.
    public static func echoedWordCount(in text: String, words: [String]) -> Int {
        let kept = clean(words)
        guard !kept.isEmpty else { return 0 }
        var rest = text.lowercased()
        var found = 0
        // Longer words first, so that a word which contains another is not taken apart.
        for word in kept.sorted(by: { $0.count > $1.count }) {
            let needle = word.lowercased()
            if rest.contains(needle) {
                found += 1
                rest = rest.replacingOccurrences(of: needle, with: " ")
            }
        }
        guard found > 0, !rest.contains(where: { $0.isLetter || $0.isNumber }) else { return 0 }
        return found
    }

    /// Unicode white space off both ends (the recognizer's own check for a padded line is as wide as this).
    private static func trimmed(_ text: String) -> String {
        var scalars = text.unicodeScalars
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }
}
