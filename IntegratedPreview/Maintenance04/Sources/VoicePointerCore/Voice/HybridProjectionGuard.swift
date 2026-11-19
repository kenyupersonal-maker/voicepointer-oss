import Foundation

/// The check between the personal lexicon and a cloud final (K05 rule 4): the lexicon may fix how a word is
/// spelled, but it must not change a number, drop or add a negation, or touch code. When it would, the
/// dictation keeps the cloud's own raw text (never the local draft: the fallback is "that candidate's raw").
///
/// Three kinds of protected tokens are read from the raw text and from the projected text, each kind as a
/// sequence in text order; any kind whose sequences differ rejects the projection. The rules are
/// deliberately blunt: a projection that is only suspected of touching a protected token is rejected, since a
/// rejection costs one uncorrected spelling while a wrong number or a lost "not" changes what was said. Known
/// cost: a correction that itself spells a numeral or a negation character (未来 → 蔚来) is refused.
///
/// Only cloud finals go through here; the local path is unchanged. Pure: the verdict carries a finite reason
/// and never the text.
@_spi(Testing) public enum HybridProjectionGuard {
    public enum Reason: String, Sendable {
        case digits, negation, code
    }

    public enum Verdict: Sendable, Equatable {
        case accepted
        case rejected(Reason)
    }

    /// Checked in this order; the first kind that differs is the reason.
    public static func check(raw: String, projected: String) -> Verdict {
        if raw.unicodeScalars.elementsEqual(projected.unicodeScalars) { return .accepted }
        if digitTokens(raw) != digitTokens(projected) { return .rejected(.digits) }
        if negationTokens(raw) != negationTokens(projected) { return .rejected(.negation) }
        if codeTokens(raw) != codeTokens(projected) { return .rejected(.code) }
        return .accepted
    }

    // MARK: - Numbers

    /// Chinese numerals, their traditional and financial forms included.
    private static let chineseNumerals: Set<Unicode.Scalar> = Set(
        "零〇一二两兩三四五六七八九十百千万萬亿億壹贰貳叁參肆伍陆陸柒捌玖拾佰仟".unicodeScalars)

    private static func isNumeral(_ scalar: Unicode.Scalar) -> Bool {
        // Any decimal digit (ASCII, full-width, other scripts) or a Chinese numeral.
        scalar.properties.numericType == .decimal || chineseNumerals.contains(scalar)
    }

    /// Maximal runs of numeral characters, compared exactly (a full-width 3 turned into an ASCII 3 is a
    /// change too).
    static func digitTokens(_ text: String) -> [String] {
        runs(of: text, where: isNumeral)
    }

    // MARK: - Negation

    private static let chineseNegations: Set<Unicode.Scalar> = Set("不没沒无無非未别別莫勿否".unicodeScalars)
    private static let englishNegations: Set<String> = [
        "not", "no", "never", "none", "cannot", "nobody", "nothing", "nowhere", "neither", "nor",
    ]

    /// Every Chinese negation character, and every English negation word (case ignored, any word ending in
    /// n't with either apostrophe), in text order.
    static func negationTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = String.UnicodeScalarView()
        func closeWord() {
            guard !word.isEmpty else { return }
            let lowered = String(word).lowercased()
            word.removeAll()
            let bare = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}"))
            if englishNegations.contains(bare) || bare.hasSuffix("n't") || bare.hasSuffix("n\u{2019}t") {
                tokens.append(bare.replacingOccurrences(of: "\u{2019}", with: "'"))
            }
        }
        for scalar in text.unicodeScalars {
            if isEnglishWordScalar(scalar) {
                word.append(scalar)
                continue
            }
            closeWord()
            if chineseNegations.contains(scalar) { tokens.append(String(scalar)) }
        }
        closeWord()
        return tokens
    }

    private static func isEnglishWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x27, 0x2019: true
        default: false
        }
    }

    // MARK: - Code

    /// Characters that make an ASCII word look like code: paths, calls, assignments, identifiers, handles.
    private static let codeMarks: Set<Unicode.Scalar> = Set("/\\=(){}[]_$#@".unicodeScalars)

    /// Backtick spans (an unclosed one runs to the end), then every ASCII word that contains a code mark,
    /// "::" or "->", or a dot between two letters or digits (file names, versions, URLs, e-mail addresses).
    /// Words are runs of printable ASCII, so CamelCase names such as GitHub or OpenAI are not code: fixing
    /// them is what the lexicon is for.
    static func codeTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var outside = String.UnicodeScalarView()
        var span: String.UnicodeScalarView?
        for scalar in text.unicodeScalars {
            if scalar == "`" {
                if var open = span {
                    open.append(scalar)
                    tokens.append(String(open))
                    span = nil
                } else {
                    tokens += codeWords(String(outside))
                    outside.removeAll()
                    span = String.UnicodeScalarView([scalar])
                }
            } else if span != nil {
                span?.append(scalar)
            } else {
                outside.append(scalar)
            }
        }
        if let open = span { tokens.append(String(open)) }
        tokens += codeWords(String(outside))
        return tokens
    }

    private static func codeWords(_ text: String) -> [String] {
        runs(of: text) { (0x21...0x7E).contains($0.value) && $0 != "`" }.filter(isCodeWord)
    }

    private static func isCodeWord(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        if scalars.contains(where: codeMarks.contains) { return true }
        if word.contains("::") || word.contains("->") { return true }
        guard scalars.count >= 3 else { return false }
        for index in 1..<(scalars.count - 1) where scalars[index] == "." {
            if isAlphanumericASCII(scalars[index - 1]) && isAlphanumericASCII(scalars[index + 1]) { return true }
        }
        return false
    }

    private static func isAlphanumericASCII(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: false
        }
    }

    // MARK: - Runs

    private static func runs(of text: String, where belongs: (Unicode.Scalar) -> Bool) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if belongs(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                result.append(String(current))
                current.removeAll()
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }
}
