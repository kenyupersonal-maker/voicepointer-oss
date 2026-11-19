// I06A v4 — ScopedCorrector: pure, conservative exact-Latin-term correction foundation.
// No I/O, no learning, no globals, no models. Unsupported cases reject rather than guess.
// Chinese term/token/learning support and Qwen3 term validation arrive in later cards.

import Foundation

public struct CorrectionRule: Codable, Sendable, Equatable {
    public let id: UUID
    public let revision: Int
    public let observedText: String
    public let canonicalText: String
    public let positivePrefixes: [String]
    public let positiveSuffixes: [String]
    public let negativeContexts: [String]
    public let enabled: Bool
    public let explicitGlobal: Bool

    public init(id: UUID, revision: Int, observedText: String, canonicalText: String,
                positivePrefixes: [String], positiveSuffixes: [String],
                negativeContexts: [String], enabled: Bool, explicitGlobal: Bool) {
        self.id = id
        self.revision = revision
        self.observedText = observedText
        self.canonicalText = canonicalText
        self.positivePrefixes = positivePrefixes
        self.positiveSuffixes = positiveSuffixes
        self.negativeContexts = negativeContexts
        self.enabled = enabled
        self.explicitGlobal = explicitGlobal
    }
}

public struct CorrectionEdit: Codable, Sendable, Equatable {
    public let ruleID: UUID
    public let ruleRevision: Int
    public let rangeUTF16Location: Int
    public let rangeUTF16Length: Int
    public let originalText: String
    public let replacementText: String
    public let reason: String  // "explicit_global" | "matched_phrase"

    public init(ruleID: UUID, ruleRevision: Int, rangeUTF16Location: Int,
                rangeUTF16Length: Int, originalText: String,
                replacementText: String, reason: String) {
        self.ruleID = ruleID
        self.ruleRevision = ruleRevision
        self.rangeUTF16Location = rangeUTF16Location
        self.rangeUTF16Length = rangeUTF16Length
        self.originalText = originalText
        self.replacementText = replacementText
        self.reason = reason
    }
}

public struct CorrectedTranscript: Codable, Sendable, Equatable {
    public let rawText: String
    public let text: String
    public let edits: [CorrectionEdit]
    public let lexiconRevision: Int

    public init(rawText: String, text: String, edits: [CorrectionEdit], lexiconRevision: Int) {
        self.rawText = rawText
        self.text = text
        self.edits = edits
        self.lexiconRevision = lexiconRevision
    }
}

public enum ScopedCorrectionError: Error, Sendable, Equatable {
    case invalidRule
    case conflictingRules
    case invalidInput
    case capacityExceeded
}

/// Pure corrector. Idempotence note: a replacement can alter local context such that a
/// second `correct` pass would fire another rule (e.g. A→B where B is another rule's
/// observed text). Rather than recurse or rewrite, we apply a runtime fixed-point guard:
/// after building the proposed output, we scan that output for any applicable candidate;
/// if any exists, the whole transform is refused (original returned, zero edits).
/// Consequently `correct(correct(x).text).text == correct(x).text` always holds — that is,
/// idempotence is guaranteed on the produced `.text` only, NOT on the whole
/// `CorrectedTranscript` value (whose `rawText` would differ between calls). The tool
/// favors safe refusal over chained rewriting. Dynamic context-induced chains are caught
/// at runtime even when static chain checks pass.
public struct ScopedCorrector: Sendable {
    public static let maxRules = 1000
    public static let maxGraphemes = 50_000
    public static let maxUTF8Bytes = 1 << 20
    public static let maxCandidates = 10_000

    public let lexiconRevision: Int
    private let rules: [CorrectionRule]

    public init(rules: [CorrectionRule], lexiconRevision: Int) throws {
        guard lexiconRevision >= 0 else { throw ScopedCorrectionError.invalidInput }
        guard rules.count <= Self.maxRules else { throw ScopedCorrectionError.capacityExceeded }
        var seen = Set<UUID>()
        for r in rules {
            guard !seen.contains(r.id) else { throw ScopedCorrectionError.invalidRule }
            seen.insert(r.id)
            try Self.validate(r)  // ALL rules validate, even disabled
        }
        let enabled = rules.filter { $0.enabled }
        try Self.checkNoDuplicates(enabled)
        try Self.checkNoChains(enabled)
        self.rules = rules
        self.lexiconRevision = lexiconRevision
    }

    // MARK: - Validation

    private static func isASCIILetterOrSpace(_ s: String) -> Bool {
        // Validate Unicode scalar values directly: ASCII A-Z (65...90), a-z (97...122),
        // and space (32). Character lexical ordering must not be used — accented
        // Characters can compare between ASCII letters.
        !s.isEmpty && s.allSatisfy { c in
            c.unicodeScalars.allSatisfy { sc in
                (sc.value >= 65 && sc.value <= 90)
                    || (sc.value >= 97 && sc.value <= 122)
                    || sc.value == 32
            }
        }
    }

    private static func validateTerm(_ s: String) -> Bool {
        guard s.count >= 1, s.count <= 32, isASCIILetterOrSpace(s) else { return false }
        guard !s.hasPrefix(" "), !s.hasSuffix(" "), !s.contains("  ") else { return false }
        return s.split(separator: " ").count <= 4
    }

    private static func validateContext(_ s: String) -> Bool {
        guard s.count >= 1, s.count <= 48 else { return false }
        return !s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }
    }

    private static func validate(_ r: CorrectionRule) throws {
        guard r.revision >= 0 else { throw ScopedCorrectionError.invalidRule }
        guard validateTerm(r.observedText), validateTerm(r.canonicalText),
              r.observedText != r.canonicalText else { throw ScopedCorrectionError.invalidRule }
        guard r.positivePrefixes.count <= 8, r.positiveSuffixes.count <= 8,
              r.negativeContexts.count <= 8,
              r.positivePrefixes.allSatisfy(validateContext),
              r.positiveSuffixes.allSatisfy(validateContext),
              r.negativeContexts.allSatisfy(validateContext)
        else { throw ScopedCorrectionError.invalidRule }
        // Automatic (scoped) rules must carry at least one positive anchor.
        if !r.explicitGlobal, r.positivePrefixes.isEmpty && r.positiveSuffixes.isEmpty {
            throw ScopedCorrectionError.invalidRule
        }
    }

    /// Duplicate observedText with identical scope contexts is ambiguous — reject.
    private static func checkNoDuplicates(_ enabled: [CorrectionRule]) throws {
        var seen = Set<String>()
        for r in enabled {
            let key = "\(r.observedText)\u{1}|\(r.positivePrefixes)|\(r.positiveSuffixes)|\(r.negativeContexts)|\(r.explicitGlobal)"
            guard !seen.contains(key) else { throw ScopedCorrectionError.conflictingRules }
            seen.insert(key)
        }
    }

    /// Static chain guard: if any enabled rule's canonical text contains another
    /// enabled rule's observed text as a whole (space-delimited) phrase token — including
    /// itself — the output of one rule could feed another; reject conservatively.
    private static func checkNoChains(_ enabled: [CorrectionRule]) throws {
        let phrases = enabled.map { $0.observedText.split(separator: " ").map(String.init) }
        for a in enabled {
            let words = a.canonicalText.split(separator: " ").map(String.init)
            for p in phrases {
                // Self (p derived from a) is included deliberately.
                guard p.count <= words.count else { continue }
                var k = 0
                while k + p.count <= words.count {
                    if words[k..<(k + p.count)] == p[...] { throw ScopedCorrectionError.conflictingRules }
                    k += 1
                }
            }
        }
    }

    // MARK: - Correction

    public func correct(_ rawText: String) throws -> CorrectedTranscript {
        guard rawText.count <= Self.maxGraphemes, rawText.utf8.count <= Self.maxUTF8Bytes
        else { throw ScopedCorrectionError.capacityExceeded }
        let selected = try Self.selectCandidates(in: rawText, rules: rules)
        guard !selected.isEmpty else {
            return CorrectedTranscript(rawText: rawText, text: rawText, edits: [], lexiconRevision: lexiconRevision)
        }
        // Build proposed output from original UTF16 ranges, left to right.
        let total = rawText.utf16.count
        var out = ""
        var last = 0
        for c in selected {
            guard let mid = Self.utf16Slice(rawText, last, c.location) else { throw ScopedCorrectionError.invalidInput }
            out += mid + c.replacementText
            last = c.location + c.length
        }
        guard let tail = Self.utf16Slice(rawText, last, total) else { throw ScopedCorrectionError.invalidInput }
        out += tail
        // Overflow guard: the proposed output must itself satisfy the same bounds before
        // the second scan; if it overflows, refuse (original returned, zero edits) so any
        // returned text passes the bounds on the next call.
        guard out.count <= Self.maxGraphemes, out.utf8.count <= Self.maxUTF8Bytes else {
            return CorrectedTranscript(rawText: rawText, text: rawText, edits: [], lexiconRevision: lexiconRevision)
        }
        // Runtime fixed-point guard: refuse the whole transform if the proposed text
        // would itself trigger any candidate (context-induced chains included).
        if !(try Self.selectCandidates(in: out, rules: rules)).isEmpty {
            return CorrectedTranscript(rawText: rawText, text: rawText, edits: [], lexiconRevision: lexiconRevision)
        }
        let edits = selected.map {
            CorrectionEdit(ruleID: $0.rule.id, ruleRevision: $0.rule.revision,
                           rangeUTF16Location: $0.location, rangeUTF16Length: $0.length,
                           originalText: $0.rule.observedText, replacementText: $0.rule.canonicalText,
                           reason: $0.rule.explicitGlobal ? "explicit_global" : "matched_phrase")
        }
        return CorrectedTranscript(rawText: rawText, text: out, edits: edits, lexiconRevision: lexiconRevision)
    }

    // MARK: - Candidate selection (pure; works on any text)

    private struct Candidate {
        let rule: CorrectionRule
        let location: Int  // UTF16
        let length: Int
        var replacementText: String { rule.canonicalText }
    }

    private static func isWordChar(_ c: Character?) -> Bool {
        // Word chars are exactly ASCII letters, digits, underscore. Chinese and other
        // non-ASCII neighbors are allowed (e.g. "我用 Coder改界面"); "decoder" is not.
        guard let c = c, let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (s.value >= 97 && s.value <= 122) || (s.value >= 65 && s.value <= 90)
            || (s.value >= 48 && s.value <= 57) || s.value == 95
    }

    private static func utf16Offsets(_ r: Range<String.Index>, in s: String) -> (Int, Int)? {
        guard let a = r.lowerBound.samePosition(in: s.utf16),
              let b = r.upperBound.samePosition(in: s.utf16) else { return nil }
        return (s.utf16.distance(from: s.utf16.startIndex, to: a),
                s.utf16.distance(from: s.utf16.startIndex, to: b))
    }

    private static func utf16Slice(_ s: String, _ from: Int, _ to: Int) -> String? {
        let u = s.utf16
        guard from >= 0, from <= to, to <= u.count else { return nil }
        let i = u.index(u.startIndex, offsetBy: from)
        let j = u.index(u.startIndex, offsetBy: to)
        guard let a = i.samePosition(in: s), let b = j.samePosition(in: s) else { return nil }
        return String(s[a..<b])
    }

    /// Conservative per-line protection: skip any line that looks like code, a URL,
    /// a path, or an indented code block. Whole logical line is protected.
    private static func lineIsProtected(_ line: String) -> Bool {
        if line.hasPrefix("    ") { return true }
        for marker in ["`", "://", "www.", "/", "\\", "=", "{", "}"] {
            if line.contains(marker) { return true }
        }
        return false
    }

    /// A single logical line break at `scan`: CRLF (one Swift Character) counts as one
    /// break; other Unicode newline forms are treated conservatively as breaks too.
    private static func isLineBreak(_ c: Character) -> Bool {
        if c == "\r\n" { return true }
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return false }
        switch s.value {
        case 0x0A /* LF */, 0x0B /* VT */, 0x0C /* FF */, 0x0D /* CR */,
             0x85 /* NEL */, 0x2028 /* LS */, 0x2029 /* PS */:
            return true
        default:
            return false
        }
    }

    private static func selectCandidates(in text: String, rules: [CorrectionRule]) throws -> [Candidate] {
        var candidates: [Candidate] = []
        // Precompute protected line ranges (UTF16) once.
        var protected: [(Int, Int)] = []
        var lineStart = text.startIndex
        var scan = text.startIndex
        while scan < text.endIndex {
            let ch = text[scan]
            if isLineBreak(ch) {
                // Line content is lineStart..<scan (break excluded); original newlines
                // stay in the output untouched — protection only marks ranges.
                let line = String(text[lineStart..<scan])
                if lineIsProtected(line), let a = utf16Offsets(lineStart..<scan, in: text) {
                    protected.append(a)
                }
                // Advance past the break exactly once, then start the next line.
                let next = text.index(after: scan)
                lineStart = next
                scan = next
                continue
            }
            scan = text.index(after: scan)
        }
        // Final line (no trailing break).
        if lineStart < text.endIndex {
            let line = String(text[lineStart..<text.endIndex])
            if lineIsProtected(line), let a = utf16Offsets(lineStart..<text.endIndex, in: text) {
                protected.append(a)
            }
        }
        func inProtected(_ loc: Int, _ len: Int) -> Bool {
            protected.contains { loc >= $0.0 && loc + len <= $0.1 }
        }
        for rule in rules where rule.enabled {
            var search = text.startIndex
            while let r = text.range(of: rule.observedText, range: search..<text.endIndex) {
                search = r.upperBound
                guard let (loc, end) = utf16Offsets(r, in: text) else { continue }
                // Latin token boundaries.
                let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : nil
                let after = r.upperBound < text.endIndex ? text[r.upperBound] : nil
                if isWordChar(before) || isWordChar(after) { continue }
                if inProtected(loc, end - loc) { continue }
                // Sentence-local context (both sides of the candidate, split at 。！？!?\n and '.')
                let (left, right) = sentenceContext(text, around: r)
                if !contextAllows(rule, left: left, right: right) { continue }
                candidates.append(Candidate(rule: rule, location: loc, length: end - loc))
                if candidates.count > Self.maxCandidates {
                    throw ScopedCorrectionError.capacityExceeded
                }
            }
        }
        // Overlap resolution: global first, then earlier location, longer phrase, stable UUID.
        let ordered = candidates.sorted { a, b in
            if a.rule.explicitGlobal != b.rule.explicitGlobal { return a.rule.explicitGlobal }
            if a.location != b.location { return a.location < b.location }
            if a.length != b.length { return a.length > b.length }
            return a.rule.id.uuidString < b.rule.id.uuidString
        }
        var chosen: [Candidate] = []
        var taken: [(Int, Int)] = []
        for c in ordered {
            let r2 = (c.location, c.location + c.length)
            if taken.contains(where: { $0.1 > r2.0 && r2.1 > $0.0 }) { continue }
            taken.append(r2)
            chosen.append(c)
        }
        return chosen.sorted { $0.location < $1.location }
    }

    private static func sentenceContext(_ text: String, around r: Range<String.Index>) -> (String, String) {
        let breaks: Set<Character> = ["。", "！", "？", "!", "?", "\n", "\r", "."]
        // Bounded scan: at most 48 Characters per side, stopping at breaks.
        var ls = r.lowerBound
        var leftCount = 0
        while ls > text.startIndex, leftCount < 48 {
            let p = text.index(before: ls)
            if breaks.contains(text[p]) || isLineBreak(text[p]) { break }
            ls = p
            leftCount += 1
        }
        var re = r.upperBound
        var rightCount = 0
        while re < text.endIndex, rightCount < 48 {
            if breaks.contains(text[re]) || isLineBreak(text[re]) { break }
            re = text.index(after: re)
            rightCount += 1
        }
        let left = String(text[ls..<r.lowerBound])
        let right = String(text[r.upperBound..<re])
        return (left, right)
    }

    private static func contextAllows(_ rule: CorrectionRule, left: String, right: String) -> Bool {
        // Positives: if both arrays non-empty, require one match from EACH array.
        var okP = rule.positivePrefixes.isEmpty
        if !rule.positivePrefixes.isEmpty {
            okP = rule.positivePrefixes.contains { left.hasSuffix($0) }
        }
        var okS = rule.positiveSuffixes.isEmpty
        if !rule.positiveSuffixes.isEmpty {
            okS = rule.positiveSuffixes.contains { right.hasPrefix($0) }
        }
        if !rule.explicitGlobal, !(okP && okS) { return false }
        // Global rules skip positives but still honor negatives (and protection/token checks above).
        // Negatives: any occurrence within the local sentence context including the candidate.
        let surrounding = left + rule.observedText + right
        if rule.negativeContexts.contains(where: { surrounding.contains($0) }) { return false }
        return true
    }
}
