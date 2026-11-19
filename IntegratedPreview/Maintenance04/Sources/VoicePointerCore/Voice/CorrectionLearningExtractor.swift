import Foundation

// MARK: - Data model

public enum LearningEditOrigin: String, Codable, Sendable {
    case verifiedOwnEditor
    case asrRevision
    case externalUnknown
    case referenceText
    case automaticCorrectionUndo
}

public struct LearningEditEvidence: Sendable {
    public let originalText: String
    public let editedText: String
    public let origin: LearningEditOrigin
    public let compositionCommitted: Bool
    public let stableMilliseconds: Double
    public let explicitSubmit: Bool
    public let deliveryConfirmed: Bool
    public let wasAutomaticallyCorrected: Bool

    public init(
        originalText: String,
        editedText: String,
        origin: LearningEditOrigin,
        compositionCommitted: Bool,
        stableMilliseconds: Double,
        explicitSubmit: Bool,
        deliveryConfirmed: Bool,
        wasAutomaticallyCorrected: Bool
    ) {
        self.originalText = originalText
        self.editedText = editedText
        self.origin = origin
        self.compositionCommitted = compositionCommitted
        self.stableMilliseconds = stableMilliseconds
        self.explicitSubmit = explicitSubmit
        self.deliveryConfirmed = deliveryConfirmed
        self.wasAutomaticallyCorrected = wasAutomaticallyCorrected
    }
}

public struct LearnedTermCandidate: Sendable, Equatable {
    public let canonicalText: String
    public let observedText: String
    public let positivePrefix: String
    public let positiveSuffix: String
    public let rangeUTF16Location: Int
    public let rangeUTF16Length: Int

    public init(
        canonicalText: String,
        observedText: String,
        positivePrefix: String,
        positiveSuffix: String,
        rangeUTF16Location: Int,
        rangeUTF16Length: Int
    ) {
        self.canonicalText = canonicalText
        self.observedText = observedText
        self.positivePrefix = positivePrefix
        self.positiveSuffix = positiveSuffix
        self.rangeUTF16Location = rangeUTF16Location
        self.rangeUTF16Length = rangeUTF16Length
    }
}

// MARK: - Pure conservative extractor (no storage / UI / ASR / AX side effects)

public enum CorrectionLearningExtractor {

    private static let dangerousTokens: Set<String> = [
        "not", "no", "yes", "allow", "deny", "true", "false", "none", "all",
        "never", "always", "enable", "disable", "delete", "remove"
    ]

    public static func extract(_ evidence: LearningEditEvidence) -> LearnedTermCandidate? {
        guard evidence.origin == .verifiedOwnEditor,
              evidence.deliveryConfirmed,
              !evidence.wasAutomaticallyCorrected,
              evidence.compositionCommitted else { return nil }
        let stable = evidence.stableMilliseconds
        guard stable.isFinite, stable >= 0, stable >= 800 || evidence.explicitSubmit else { return nil }

        let source = evidence.originalText
        let edited = evidence.editedText
        guard !source.isEmpty, !edited.isEmpty, source != edited else { return nil }
        guard source.count <= 50_000, edited.count <= 50_000,
              source.utf8.count <= 1_048_576, edited.utf8.count <= 1_048_576 else { return nil }

        let s = Array(source)
        let t = Array(edited)

        // Longest common prefix / suffix without overlap.
        var pl = 0
        while pl < s.count && pl < t.count && s[pl] == t[pl] { pl += 1 }
        var sl = 0
        while sl < s.count - pl && sl < t.count - pl
              && s[s.count - 1 - sl] == t[t.count - 1 - sl] { sl += 1 }

        var ol = pl, orr = s.count - sl   // changed span in source
        var nl = pl, nr = t.count - sl    // changed span in edited
        // A letter inserted/deleted inside a term can be a spelling fix
        // (OpenI -> OpenAI). Whole-word additions/deletions remain excluded.
        if ol == orr {
            guard t[nl..<nr].allSatisfy(isASCIILetter),
                  (ol > 0 && isASCIILetter(s[ol - 1])) ||
                    (orr < s.count && isASCIILetter(s[orr])) else { return nil }
        }
        if nl == nr {
            guard s[ol..<orr].allSatisfy(isASCIILetter),
                  (nl > 0 && isASCIILetter(t[nl - 1])) ||
                    (nr < t.count && isASCIILetter(t[nr])) else { return nil }
        }

        // Expand outward to whole ASCII-letter word boundaries, independently.
        while ol > 0 && isASCIILetter(s[ol - 1]) { ol -= 1 }
        while orr < s.count && isASCIILetter(s[orr]) { orr += 1 }
        while nl > 0 && isASCIILetter(t[nl - 1]) { nl -= 1 }
        while nr < t.count && isASCIILetter(t[nr]) { nr += 1 }

        // Alignment anchors must remain untouched and equal; left indices must match.
        guard ol == nl,
              Array(s[0..<ol]) == Array(t[0..<nl]),
              Array(s[orr...]) == Array(t[nr...]) else { return nil }

        // Skip code / URL / identifier-looking lines (original and corresponding edited line).
        if lineIsSkippable(s, at: ol) || lineIsSkippable(t, at: nl) { return nil }

        let observed = String(s[ol..<orr])
        let canonical = String(t[nl..<nr])

        guard isValidTerm(canonical), isValidTerm(observed) else { return nil }
        guard canonical != observed else { return nil }
        let strip = { (x: String) in x.replacingOccurrences(of: " ", with: "") }
        guard strip(canonical) != strip(observed) else { return nil } // space-only

        // Underscore or ASCII digit adjacent to expanded span => identifier risk.
        for (a, l, r) in [(s, ol, orr), (t, nl, nr)] {
            for idx in [l - 1, r] {
                guard idx >= 0 && idx < a.count else { continue }
                let c = a[idx]
                if c == "_" || (c.isASCII && c.isNumber) { return nil }
            }
        }

        // Ambiguity: observed term as whole ASCII-token phrase more than once in original.
        if wholeTokenOccurrences(of: observed, in: source) > 1 { return nil }

        // Same-sentence context, at most 24 graphemes each, untrimmed anchors.
        var leftChars: [Character] = []
        var i = ol - 1
        while i >= 0 && leftChars.count < 24 {
            let c = s[i]
            if isSentenceBoundary(c) { break }
            leftChars.append(c)
            i -= 1
        }
        var rightChars: [Character] = []
        var j = orr
        while j < s.count && rightChars.count < 24 {
            let c = s[j]
            if isSentenceBoundary(c) { break }
            rightChars.append(c)
            j += 1
        }
        let prefix = String(leftChars.reversed())
        let suffix = String(rightChars)

        guard !hasControlCharacter(prefix), !hasControlCharacter(suffix) else { return nil }
        let isBlank = { (x: String) in x.allSatisfy { $0.isWhitespace } }
        guard !(isBlank(prefix) && isBlank(suffix)) else { return nil }

        let location = String(s[0..<ol]).utf16.count
        let length = observed.utf16.count
        return LearnedTermCandidate(
            canonicalText: canonical,
            observedText: observed,
            positivePrefix: prefix,
            positiveSuffix: suffix,
            rangeUTF16Location: location,
            rangeUTF16Length: length
        )
    }

    // MARK: Helpers

    private static func isASCIILetter(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    private static func isSentenceBoundary(_ c: Character) -> Bool {
        c.isNewline || "。！？!?.".contains(c)
    }

    private static func hasControlCharacter(_ x: String) -> Bool {
        x.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isValidTerm(_ term: String) -> Bool {
        let chars = Array(term)
        guard (1...32).contains(chars.count) else { return false }
        for c in chars where !(c == " " || isASCIILetter(c)) { return false }
        let words = term.split(separator: " ", omittingEmptySubsequences: false)
        guard !words.contains("") else { return false } // leading/trailing/double space
        guard words.count <= 4 else { return false }
        for w in words where dangerousTokens.contains(w.lowercased()) { return false }
        return true
    }

    private static func lineIsSkippable(_ a: [Character], at idx: Int) -> Bool {
        var lo = idx
        while lo > 0 && !a[lo - 1].isNewline { lo -= 1 }
        var hi = idx
        while hi < a.count && !a[hi].isNewline { hi += 1 }
        let line = String(a[lo..<hi])
        return line.contains("`") || line.contains("://") || line.contains("www.")
            || line.contains("/") || line.contains("\\") || line.contains("=")
            || line.contains("{") || line.contains("}")
            || line.hasPrefix("    ")
    }

    private static func wholeTokenOccurrences(of phrase: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let r = text.range(of: phrase, range: range) {
            let beforeOK = r.lowerBound == text.startIndex
                || !isASCIILetter(text[text.index(before: r.lowerBound)])
            let afterOK = r.upperBound == text.endIndex
                || !isASCIILetter(text[r.upperBound])
            if beforeOK && afterOK { count += 1 }
            if r.upperBound == text.endIndex { break }
            range = r.upperBound..<text.endIndex
        }
        return count
    }
}
