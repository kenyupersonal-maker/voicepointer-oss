import Foundation
import CoreFoundation

/// Pure, conservative final-transcript comparison. No IO, teacher reruns, log text or user data storage.
/// The reference is the independently observed teacher result; the local side is the wrong spelling.
public enum StrictLearningFilter {
    public enum Rejection: String, Codable, Sendable, Hashable, CaseIterable {
        case empty
        case insertDelete
        case prefix
        case length
        case filler
        case span
        case pinyin
        case latin
    }

    public struct Pair: Sendable, Equatable, Hashable {
        public let variant: String
        public let canonical: String

        public init(variant: String, canonical: String) {
            self.variant = variant
            self.canonical = canonical
        }
    }

    public struct Decision: Sendable, Equatable {
        public let pair: Pair
        public let rejection: Rejection?

        public var isAccepted: Bool { rejection == nil }

        public init(pair: Pair, rejection: Rejection?) {
            self.pair = pair
            self.rejection = rejection
        }
    }

    private struct Token {
        let text: String
        let sentence: Int
        let latinWord: Bool

        var anchorLength: Int { text.count }
        var key: String { LexiconText.foldKey(text) }
    }

    private enum Operation {
        case equal(Int, Int)
        case substitute(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// The legacy predicate parameters remain source-compatible but are deliberately ignored:
    /// the R5 rule has neither a common-Chinese-list nor a spell-checker admission gate.
    /// Returned text remains in process memory and must never enter logs.
    public static func analyze(
        local: String,
        reference: String,
        commonChinese: (String) -> Bool,
        ordinaryEnglish: (String) -> Bool
    ) -> [Decision] {
        _ = commonChinese
        _ = ordinaryEnglish
        let a = tokens(in: local)
        let b = tokens(in: reference)
        if a.isEmpty && b.isEmpty {
            return [Decision(pair: Pair(variant: "", canonical: ""), rejection: .empty)]
        }
        if a.isEmpty || b.isEmpty {
            return [Decision(pair: Pair(variant: render(a[...]), canonical: render(b[...])), rejection: .insertDelete)]
        }
        // A long or ambiguous utterance must never make a quadratic learning pass block dictation.
        guard a.count <= 1_024, b.count <= 1_024,
              a.count * b.count <= 350_000 else {
            return [Decision(pair: Pair(variant: "", canonical: ""), rejection: .length)]
        }

        let width = b.count + 1
        func position(_ i: Int, _ j: Int) -> Int { i * width + j }
        var distance = Array(repeating: 0, count: (a.count + 1) * width)
        for i in 0...a.count { distance[position(i, 0)] = i }
        for j in 0...b.count { distance[position(0, j)] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let substitution = a[i - 1].key == b[j - 1].key ? 0 : 1
                distance[position(i, j)] = min(
                    distance[position(i - 1, j - 1)] + substitution,
                    min(distance[position(i - 1, j)] + 1, distance[position(i, j - 1)] + 1)
                )
            }
        }
        if distance[position(a.count, b.count)] == 0 { return [] }

        // Deterministic backtrace: identical units first, then substitution, deletion, insertion.
        // An entire ASCII word is one unit. No internal letters can act as alignment anchors.
        var operations: [Operation] = []
        var i = a.count
        var j = b.count
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i - 1].key == b[j - 1].key
                && distance[position(i, j)] == distance[position(i - 1, j - 1)] {
                operations.append(.equal(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0 && j > 0
                && distance[position(i, j)] == distance[position(i - 1, j - 1)] + 1 {
                operations.append(.substitute(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0 && distance[position(i, j)] == distance[position(i - 1, j)] + 1 {
                operations.append(.delete(i - 1)); i -= 1
            } else {
                operations.append(.insert(j - 1)); j -= 1
            }
        }
        operations.reverse()

        var result: [Decision] = []
        var cursor = 0
        while cursor < operations.count {
            if case .equal = operations[cursor] {
                cursor += 1
                continue
            }
            var localIndices: [Int] = []
            var referenceIndices: [Int] = []
            while cursor < operations.count {
                switch operations[cursor] {
                case .equal:
                    break
                case let .substitute(l, r):
                    localIndices.append(l); referenceIndices.append(r)
                case let .delete(l):
                    localIndices.append(l)
                case let .insert(r):
                    referenceIndices.append(r)
                }
                if case .equal = operations[cursor] { break }
                cursor += 1
            }
            let localSpan = localIndices.map { a[$0] }
            let referenceSpan = referenceIndices.map { b[$0] }
            let pair = Pair(variant: render(localSpan[...]), canonical: render(referenceSpan[...]))
            if localSpan.isEmpty || referenceSpan.isEmpty {
                result.append(Decision(pair: pair, rejection: .insertDelete))
                continue
            }
            // R5 admits boundary replacements; only crossing sentence boundaries remains unsafe.
            let localSentences = Set(localSpan.map(\.sentence))
            let referenceSentences = Set(referenceSpan.map(\.sentence))
            guard localSentences.count == 1, referenceSentences.count == 1,
                  localSentences.first == referenceSentences.first else {
                result.append(Decision(pair: pair, rejection: .span))
                continue
            }
            result.append(Decision(
                pair: pair,
                rejection: validatePair(variant: pair.variant, canonical: pair.canonical,
                                        commonChinese: commonChinese, ordinaryEnglish: ordinaryEnglish)
            ))
        }
        return result
    }

    /// The archive's context-free numeric exam calls this for EVERY pair.
    /// Condition (b) is intentionally not applied when the original sentence is unavailable.
    public static func validatePair(
        variant: String,
        canonical: String,
        commonChinese: (String) -> Bool,
        ordinaryEnglish: (String) -> Bool
    ) -> Rejection? {
        _ = commonChinese
        _ = ordinaryEnglish
        let wrong = tokens(in: variant)
        let right = tokens(in: canonical)
        if wrong.isEmpty && right.isEmpty { return .empty }
        if wrong.isEmpty || right.isEmpty { return .insertDelete }

        // R5 compares ONLY the differing span. Han characters and complete ASCII words are
        // the alignment units; punctuation and whitespace were removed by tokens(in:).
        var first = 0
        while first < wrong.count && first < right.count &&
              wrong[first].key == right[first].key { first += 1 }
        var lastWrong = wrong.count
        var lastRight = right.count
        while lastWrong > first && lastRight > first &&
              wrong[lastWrong - 1].key == right[lastRight - 1].key {
            lastWrong -= 1
            lastRight -= 1
        }
        if first == lastWrong && first == lastRight { return .empty }
        if first == lastWrong || first == lastRight { return .insertDelete }
        let left = Array(wrong[first..<lastWrong])
        let corrected = Array(right[first..<lastRight])
        guard wellFormed(left), wellFormed(corrected) else { return .length }
        let observed = render(left[...])
        let intended = render(corrected[...])
        if isFiller(observed) || isFiller(intended) { return .filler }
        let wrongKey = left.map(\.key).joined()
        let rightKey = corrected.map(\.key).joined()
        if wrongKey == rightKey { return .empty }
        if wrongKey.hasPrefix(rightKey) || rightKey.hasPrefix(wrongKey)
            || wrongKey.hasSuffix(rightKey) || rightKey.hasSuffix(wrongKey) {
            return .prefix
        }

        let wrongHan = observed.filter(LexiconText.isHan).count
        let rightHan = intended.filter(LexiconText.isHan).count
        let wrongIsHan = left.allSatisfy { $0.text.allSatisfy(LexiconText.isHan) }
        let rightIsHan = corrected.allSatisfy { $0.text.allSatisfy(LexiconText.isHan) }
        let wrongIsEnglish = left.allSatisfy(\.latinWord)
        let rightIsEnglish = corrected.allSatisfy(\.latinWord)
        guard wrongHan >= 2 || rightHan >= 2 || (wrongIsEnglish && rightIsEnglish) else {
            return .span
        }
        if wrongIsHan && rightIsHan {
            guard let lhs = tonelessMandarin(observed), let rhs = tonelessMandarin(intended),
                  lhs == rhs else { return .pinyin }
            return nil
        }
        if corrected.contains(where: \.latinWord) {
            if wrongIsHan && wrongHan <= 4 { return nil }
            if wrongIsEnglish && rightIsEnglish && editDistanceAtMostFour(observed, intended) {
                return nil
            }
            return .latin
        }
        return .latin
    }

    private static func tonelessMandarin(_ text: String) -> String? {
        let buffer = NSMutableString(string: text)
        guard CFStringTransform(buffer, nil, kCFStringTransformMandarinLatin, false),
              CFStringTransform(buffer, nil, kCFStringTransformStripDiacritics, false) else {
            return nil
        }
        return (buffer as String).lowercased().filter { !$0.isWhitespace }
    }

    private static func editDistanceAtMostFour(_ a: String, _ b: String) -> Bool {
        let left = Array(a.lowercased())
        let right = Array(b.lowercased())
        guard abs(left.count - right.count) <= 4 else { return false }
        var previous = Array(0...right.count)
        for i in left.indices {
            var row = Array(repeating: 5, count: right.count + 1)
            row[0] = i + 1
            let begin = max(1, i + 1 - 4)
            let end = min(right.count, i + 1 + 4)
            if begin > end { return false }
            for j in begin...end {
                row[j] = min(previous[j] + 1,
                             min(row[j - 1] + 1, previous[j - 1] + (left[i] == right[j - 1] ? 0 : 1)))
            }
            if row.min()! > 4 { return false }
            previous = row
        }
        return previous[right.count] <= 4
    }

    private static func wellFormed(_ input: [Token]) -> Bool {
        let hanCount = input.reduce(0) { count, token in
            count + token.text.filter(LexiconText.isHan).count
        }
        let englishCount = input.filter(\.latinWord).count
        guard hanCount + englishCount > 0, hanCount <= 8, englishCount <= 3 else { return false }
        // Reject digits, identifiers and unknown alphabets, rather than learning part of a token.
        return input.allSatisfy { token in
            token.latinWord || (token.text.count == 1 && token.text.allSatisfy(LexiconText.isHan))
        }
    }

    private static func isFiller(_ text: String) -> Bool {
        let chars = Array(text.filter { $0.isLetter })
        guard !chars.isEmpty else { return false }
        if chars.count >= 2 && chars.allSatisfy({ $0 == chars[0] }) { return true }
        let filler = Set("呃嗯啊哎呀呢吧哈哦嘛儿")
        return chars.allSatisfy { filler.contains($0) }
    }

    private static func tokens(in text: String) -> [Token] {
        var output: [Token] = []
        var word = ""
        var sentence = 0
        func flushWord() {
            if !word.isEmpty {
                output.append(Token(text: word, sentence: sentence, latinWord: true))
                word = ""
            }
        }
        for character in text {
            if isASCIILetter(character) {
                word.append(character)
                continue
            }
            flushWord()
            if LexiconText.isHan(character) {
                output.append(Token(text: String(character), sentence: sentence, latinWord: false))
            } else if character.isNumber {
                // Numbers are neither punctuation nor Chinese/English words. Retain them as
                // rejecting units instead of silently learning part of a numeric identifier.
                output.append(Token(text: String(character), sentence: sentence, latinWord: false))
            } else if "。！？.!?；;\n\r".contains(character) {
                sentence += 1
            } else if character.isLetter {
                // Other scripts are not safe automatic-learning candidates. Keep a rejecting token.
                output.append(Token(text: String(character), sentence: sentence, latinWord: false))
            }
        }
        flushWord()
        return output
    }

    private static func isASCIILetter(_ c: Character) -> Bool {
        guard let n = c.asciiValue else { return false }
        return (65...90).contains(n) || (97...122).contains(n)
    }

    private static func render(_ tokens: ArraySlice<Token>) -> String {
        var result = ""
        var previousLatin = false
        for token in tokens {
            if previousLatin && token.latinWord { result.append(" ") }
            result.append(token.text)
            previousLatin = token.latinWord
        }
        return result
    }

}
