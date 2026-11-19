import Foundation

/// Splits what the person changed in one dictation into separate fixes.
///
/// `CorrectionDiff.derive` finds one changed region (everything between the common start and the common end),
/// so two fixes in one dictation ("cloud code" and "open ai" in the same sentence) would come out as one
/// enormous, meaningless rule. Here the two are pulled apart at the longest text that both versions still
/// share between them, as long as that text is a real word or phrase (two letters or digits, or a Han
/// character) and does not cut through an ASCII word. Neighbouring words stay together:
/// "cloud code → Claude Code" is one fix, never "cloud → Claude" and "code → Code".
///
/// Two fixes is the most that is taken as corrections. Three or more, a very long text, or a change of
/// nearly everything is a rewrite, and nothing is learned from a rewrite.
public enum CorrectionHunks {
    public struct Fix: Equatable, Sendable {
        /// The dictation as delivered with only this fix applied: what a rule is derived from.
        public let editedText: String
    }

    public enum Split: Equatable, Sendable {
        case unchanged
        /// Text was only added to, or taken from, the very start or end of the dictation: not a correction.
        case edgeOnly
        /// One or two fixes.
        case fixes([Fix])
        case rewrite
    }

    /// Longer texts are not dictated sentences; they are left alone instead of compared.
    public static let maximumCharacters = 1_500

    private struct Anchor {
        let aStart: Int
        let bStart: Int
        let length: Int
    }

    public static func split(delivered: String, edited: String) -> Split {
        let a = Array(delivered)
        let b = Array(edited)
        if a == b { return .unchanged }
        guard a.count <= maximumCharacters, b.count <= maximumCharacters else { return .rewrite }

        let common = min(a.count, b.count)
        var prefix = 0
        while prefix < common, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < common - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let aEnd = a.count - suffix
        let bEnd = b.count - suffix

        if (prefix == aEnd || prefix == bEnd), prefix == 0 || suffix == 0 { return .edgeOnly }

        // One changed region. When it reaches the start or the end of the dictation and gains a word, a Han
        // character or a sentence mark, the person may have gone on typing right next to the dictation (the caret
        // stands at its end after a paste): that is not part of a fix, so nothing is learned.
        func oneRegion() -> Split {
            if prefix == 0 || suffix == 0, tokens(b[prefix..<bEnd]) > tokens(a[prefix..<aEnd]) { return .rewrite }
            return .fixes([Fix(editedText: edited)])
        }
        guard let anchor = longestAnchor(a, prefix..<aEnd, b, prefix..<bEnd) else { return oneRegion() }
        let firstA = prefix..<anchor.aStart
        let firstB = prefix..<anchor.bStart
        let secondA = (anchor.aStart + anchor.length)..<aEnd
        let secondB = (anchor.bStart + anchor.length)..<bEnd
        // Another shared phrase in either half: three or more separate changes.
        if longestAnchor(a, firstA, b, firstB) != nil || longestAnchor(a, secondA, b, secondB) != nil {
            return .rewrite
        }
        // One Han character between two changes is more often a single mishearing that kept a syllable (微软雅黑 →
        // 薇软亚黑) than two fixes with a word between them, unless each side has a real change of its own.
        if anchor.length == 1, LexiconText.isHan(a[anchor.aStart]),
           max(LexiconText.significantCount(a[firstA]), LexiconText.significantCount(b[firstB])) < 2
            || max(LexiconText.significantCount(a[secondA]), LexiconText.significantCount(b[secondB])) < 2 {
            return oneRegion()
        }
        var firstChanged = Array(a[firstA]) != Array(b[firstB])
        var secondChanged = Array(a[secondA]) != Array(b[secondB])
        // Text only added in front of the dictation or after it is the person typing next to it, not a fix.
        if firstA.isEmpty, prefix == 0 { firstChanged = false }
        if secondA.isEmpty, suffix == 0 { secondChanged = false }
        guard firstChanged || secondChanged else { return .edgeOnly }
        if firstChanged, prefix == 0, tokens(b[firstB]) > tokens(a[firstA]) { return .rewrite }
        if secondChanged, suffix == 0, tokens(b[secondB]) > tokens(a[secondA]) { return .rewrite }

        let head = Array(a[0..<prefix])
        let middle = Array(a[anchor.aStart..<(anchor.aStart + anchor.length)])
        let tail = Array(a[aEnd...])
        let onlyFirst = head + Array(b[firstB]) + middle + Array(a[secondA]) + tail
        let onlySecond = head + Array(a[firstA]) + middle + Array(b[secondB]) + tail
        guard firstChanged, secondChanged else {
            return .fixes([Fix(editedText: String(firstChanged ? onlyFirst : onlySecond))])
        }
        return .fixes([Fix(editedText: String(onlyFirst)), Fix(editedText: String(onlySecond))])
    }

    /// Words, Han characters and sentence marks in `text`: what a change adds when it "gains" something.
    private static func tokens(_ text: ArraySlice<Character>) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if LexiconText.isASCIIWordCharacter(character) {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
                if LexiconText.isHan(character) || ",.?!;:，。？！；：、".contains(character) { count += 1 }
            }
        }
        return count
    }

    /// The longest text both ranges contain that can stand between two fixes. A shared run that begins or ends
    /// inside an ASCII word in either text is cut back to the word edge first ("ud" inside cloud / Claude is
    /// not a phrase), and what is left must still be a phrase.
    private static func longestAnchor(
        _ a: [Character], _ aRange: Range<Int>, _ b: [Character], _ bRange: Range<Int>
    ) -> Anchor? {
        guard !aRange.isEmpty, !bRange.isEmpty else { return nil }
        var best: Anchor?
        var previous = [Int](repeating: 0, count: bRange.count + 1)
        var current = [Int](repeating: 0, count: bRange.count + 1)
        for i in aRange {
            for j in bRange {
                let column = j - bRange.lowerBound + 1
                guard a[i] == b[j] else {
                    current[column] = 0
                    continue
                }
                current[column] = previous[column - 1] + 1
                // Only a run that stops here is a candidate; its shorter tails are covered by it.
                let stops = i + 1 >= aRange.upperBound || j + 1 >= bRange.upperBound || a[i + 1] != b[j + 1]
                guard stops,
                      let anchor = trimmedAnchor(a, b, aEnd: i + 1, bEnd: j + 1, length: current[column]),
                      anchor.length > (best?.length ?? 0) else { continue }
                best = anchor
            }
            swap(&previous, &current)
        }
        return best
    }

    private static func trimmedAnchor(
        _ a: [Character], _ b: [Character], aEnd: Int, bEnd: Int, length: Int
    ) -> Anchor? {
        var aStart = aEnd - length
        var bStart = bEnd - length
        var remaining = length
        if LexiconText.isASCIIWordCharacter(a[aStart]),
           (aStart > 0 && LexiconText.isASCIIWordCharacter(a[aStart - 1]))
            || (bStart > 0 && LexiconText.isASCIIWordCharacter(b[bStart - 1])) {
            while remaining > 0, LexiconText.isASCIIWordCharacter(a[aStart]) {
                aStart += 1
                bStart += 1
                remaining -= 1
            }
        }
        guard remaining > 0 else { return nil }
        let last = aStart + remaining - 1
        if LexiconText.isASCIIWordCharacter(a[last]),
           (last + 1 < a.count && LexiconText.isASCIIWordCharacter(a[last + 1]))
            || (bStart + remaining < b.count && LexiconText.isASCIIWordCharacter(b[bStart + remaining])) {
            while remaining > 0, LexiconText.isASCIIWordCharacter(a[aStart + remaining - 1]) {
                remaining -= 1
            }
        }
        guard remaining > 0 else { return nil }
        let run = a[aStart..<(aStart + remaining)]
        guard run.contains(where: LexiconText.isHan) || LexiconText.significantCount(run) >= 2 else { return nil }
        return Anchor(aStart: aStart, bStart: bStart, length: remaining)
    }
}
