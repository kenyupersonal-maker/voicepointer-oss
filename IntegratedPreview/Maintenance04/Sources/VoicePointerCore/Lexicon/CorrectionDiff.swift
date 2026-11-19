import Foundation

/// Turns "what was written" and "what the person changed it to" into one lexicon rule: the wrong spelling
/// (`variant`) and the right one (`canonical`). Used by the one-tap fix on a recent dictation and, later, by
/// learning from edits the person makes in the target field.
///
/// The changed region is what differs after trimming the common prefix and suffix. It is then widened only as
/// far as needed to make a rule that is safe to keep: to whole ASCII words ("gith" → "github"), and by
/// neighbouring characters until the wrong spelling has at least `LexiconLimits.minVariantCharacters` letters
/// or digits (punctuation and spaces do not count) and neither side of the change begins or ends with a space.
/// A change that is large, or is only spaces and punctuation, is refused: it is a rewrite, not a correction.
/// The one exception is a space added or removed inside an ASCII word ("Git Hub" → "GitHub"): a recognizer
/// splitting or joining a word is a spelling mistake.
public enum CorrectionDiff {
    public struct Suggestion: Equatable, Sendable {
        public let variant: String
        public let canonical: String
    }

    public enum Rejection: Error, Equatable, Sendable {
        case unchanged
        /// Too short to be a safe rule, only spaces or punctuation, or nothing left of the right spelling.
        case notASpelling
        /// More than `maxSpan` characters changed on one side.
        case tooLarge
        /// The changed text is (part of) something the lexicon already corrected in this dictation, so the
        /// recognizer's own text does not contain it.
        case alreadyCorrected
        /// The rule would not fire on the recognizer's own text (it sits inside a longer English word, or the
        /// right spelling already stands around it), so saving it would change nothing.
        case wouldNotMatch

        public var message: String {
            switch self {
            case .unchanged: return "和原来一样，没有改动。"
            case .notASpelling: return "改动太短，或只是空格和标点，没法当作纠错规则。多改动一点上下文再试。"
            case .tooLarge: return "改动太大，更像是重写整句，没法当作纠错规则。"
            case .alreadyCorrected: return "改的这一处已经是词库纠正过的结果，请在「我的词条」里直接编辑对应的词条。"
            case .wouldNotMatch: return "按这个改法生成的规则，在识别出来的原文里匹配不上，存了也不会起作用。可以在「我的词条」里手动写一条。"
            }
        }
    }

    /// Characters on either side of the change above which it counts as a rewrite.
    public static let maxSpan = 16

    /// The changed region: `a[lo..<aEnd]` became `b[lo..<bEnd]`; everything before `lo` and after the ends is
    /// the same text in both.
    private struct Span {
        var lo: Int
        var aEnd: Int
        var bEnd: Int
    }

    public static func derive(before: String, after: String) -> Result<Suggestion, Rejection> {
        let a = Array(before)
        let b = Array(after)
        if a == b { return .failure(.unchanged) }
        // Nothing this long is a dictated sentence; refuse instead of diffing it.
        guard a.count <= 4_000, b.count <= 4_000 else { return .failure(.tooLarge) }

        let common = min(a.count, b.count)
        var prefix = 0
        while prefix < common, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < common - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var span = Span(lo: prefix, aEnd: a.count - suffix, bEnd: b.count - suffix)

        // Only spaces or punctuation changed: formatting, not a wrong spelling, unless the change is a space
        // between two ASCII letters or digits (a word that was split or joined).
        let changesLetters = a[span.lo..<span.aEnd].contains(where: LexiconText.isSignificant)
            || b[span.lo..<span.bEnd].contains(where: LexiconText.isSignificant)
        if !changesLetters {
            guard splitsOrJoinsASCIIWord(a, b, span) else { return .failure(.notASpelling) }
            span.lo -= 1
            span.aEnd += 1
            span.bEnd += 1
        }

        // Widening to whole words can make the spelling long enough, and growing by context can land inside
        // another word: alternate until the span is a safe rule or cannot grow.
        for _ in 0..<12 {
            widenToASCIIWords(a, b, &span)
            if span.aEnd - span.lo > maxSpan || span.bEnd - span.lo > maxSpan { return .failure(.tooLarge) }
            if !needsContext(a, b, span) { break }
            guard growContext(a, b, &span) else { return .failure(.notASpelling) }
        }
        widenToASCIIWords(a, b, &span)
        if needsContext(a, b, span) { return .failure(.notASpelling) }
        guard span.aEnd - span.lo <= maxSpan, span.bEnd - span.lo <= maxSpan else { return .failure(.tooLarge) }

        let variant = String(a[span.lo..<span.aEnd])
        let canonical = String(b[span.lo..<span.bEnd])
        guard let cleaned = try? LexiconText.normalize(canonical: canonical, variants: [variant]),
              cleaned.variants.count == 1 else {
            return .failure(.notASpelling)
        }
        return .success(Suggestion(variant: cleaned.variants[0], canonical: cleaned.canonical))
    }

    /// The change is only spaces added or removed between two ASCII letters or digits.
    private static func splitsOrJoinsASCIIWord(_ a: [Character], _ b: [Character], _ span: Span) -> Bool {
        guard span.lo > 0, span.aEnd < a.count, span.bEnd < b.count,
              LexiconText.isASCIIWordCharacter(a[span.lo - 1]),
              LexiconText.isASCIIWordCharacter(a[span.aEnd]) else { return false }
        return a[span.lo..<span.aEnd].allSatisfy { $0 == " " } && b[span.lo..<span.bEnd].allSatisfy { $0 == " " }
    }

    /// A change that starts or ends inside an ASCII word takes the whole word on that side.
    private static func widenToASCIIWords(_ a: [Character], _ b: [Character], _ span: inout Span) {
        while span.lo > 0, LexiconText.isASCIIWordCharacter(a[span.lo - 1]),
              (span.lo < span.aEnd && LexiconText.isASCIIWordCharacter(a[span.lo]))
                || (span.lo < span.bEnd && LexiconText.isASCIIWordCharacter(b[span.lo])) {
            span.lo -= 1
        }
        while span.aEnd < a.count, span.bEnd < b.count, LexiconText.isASCIIWordCharacter(a[span.aEnd]),
              (span.aEnd > span.lo && LexiconText.isASCIIWordCharacter(a[span.aEnd - 1]))
                || (span.bEnd > span.lo && LexiconText.isASCIIWordCharacter(b[span.bEnd - 1])) {
            span.aEnd += 1
            span.bEnd += 1
        }
    }

    /// The wrong spelling has fewer than the minimum letters or digits, the right spelling is empty, or
    /// either side of the change begins or ends with a space.
    private static func needsContext(_ a: [Character], _ b: [Character], _ span: Span) -> Bool {
        let variant = a[span.lo..<span.aEnd]
        let canonical = b[span.lo..<span.bEnd]
        if canonical.isEmpty || LexiconText.significantCount(variant) < LexiconLimits.minVariantCharacters { return true }
        guard let first = variant.first, let last = variant.last,
              let canonicalFirst = canonical.first, let canonicalLast = canonical.last else { return true }
        return first.isWhitespace || last.isWhitespace || canonicalFirst.isWhitespace || canonicalLast.isWhitespace
    }

    /// Adds one neighbouring character to the span. A space at an edge can only be cured from that side;
    /// otherwise the side that has a letter or digit next to it wins, so the span does not spend its growth on
    /// punctuation while real text is one step away; with nothing to choose from, the left side goes first.
    /// Returns false when there is nothing left to add.
    private static func growContext(_ a: [Character], _ b: [Character], _ span: inout Span) -> Bool {
        let canGrowLeft = span.lo > 0
        let canGrowRight = span.aEnd < a.count && span.bEnd < b.count
        guard canGrowLeft || canGrowRight else { return false }
        let leftEdges: [Character?] = [
            span.lo < span.aEnd ? a[span.lo] : nil, span.lo < span.bEnd ? b[span.lo] : nil,
        ]
        let rightEdges: [Character?] = [
            span.lo < span.aEnd ? a[span.aEnd - 1] : nil, span.lo < span.bEnd ? b[span.bEnd - 1] : nil,
        ]
        let looseLeft = leftEdges.contains { $0?.isWhitespace == true }
        let looseRight = rightEdges.contains { $0?.isWhitespace == true }
        let goLeft: Bool
        if looseLeft && canGrowLeft {
            goLeft = true
        } else if looseRight && canGrowRight {
            goLeft = false
        } else {
            let letterOnLeft = canGrowLeft && LexiconText.isSignificant(a[span.lo - 1])
            let letterOnRight = canGrowRight && LexiconText.isSignificant(a[span.aEnd])
            goLeft = letterOnLeft != letterOnRight ? letterOnLeft : canGrowLeft
        }
        if goLeft {
            span.lo -= 1
        } else {
            span.aEnd += 1
            span.bEnd += 1
        }
        return true
    }
}
