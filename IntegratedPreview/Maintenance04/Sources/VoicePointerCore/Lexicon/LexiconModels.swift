import Foundation

/// Where a lexicon entry came from. Automatically learned entries are retained but no longer applied.
public enum LexiconSource: String, Codable, Sendable, CaseIterable {
    /// Typed into the personal lexicon page.
    case manual
    /// Made from a recent dictation the person corrected.
    case recentFix
    /// Learned from the person editing the same thing twice.
    case learned
    /// Accepted from an API curation suggestion.
    case suggested
    /// Promoted from repeated, confidence-qualified recognizer differences, without a person's confirmation.
    case automaticallyLearned

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LexiconSource(rawValue: raw) ?? .manual
    }
}

public enum LexiconLimits {
    public static let maxTerms = 2_000
    public static let maxVariantsPerTerm = 12
    /// The hit counter stops here; it is only a number to look at.
    public static let maxHitCount = 1_000_000
    /// Characters, for the canonical spelling and for each variant.
    public static let maxCharacters = 64
    /// Letters and digits a wrong spelling must contain (spaces and punctuation do not count): a shorter one
    /// would fire inside ordinary words.
    public static let minVariantCharacters = 2
}

/// These limits apply only to recognizer differences, never to a person's keyboard correction.
public enum AutomaticLearningLimits {
    public static let perDay = 20
    public static let total = 200
}

/// Shared production gate: existing automatic entries remain stored, but no new promotions persist.
public enum AutomaticPromotionPolicy {
    @discardableResult
    public static func permitPersist(trace: (String) -> Void) -> Bool {
        trace("learn promotion suppressed=1")
        return false
    }
}

public enum LexiconValidationError: Error, Equatable, Sendable {
    case emptyCanonical
    case tooLong(String)
    case unsafeCharacters(String)
    case variantTooShort(String)
    case variantHasNoLetters(String)
    case tooManyVariants
    case tooManyTerms
    case duplicateCanonical(String)
    case termNotFound

    /// One plain Chinese sentence for the settings page.
    public var message: String {
        switch self {
        case .emptyCanonical:
            return "请先填写正确写法。"
        case .tooLong(let text):
            return "「\(Self.excerpt(text))」太长了，一条最多 \(LexiconLimits.maxCharacters) 个字。"
        case .unsafeCharacters(let text):
            return "「\(Self.excerpt(text))」里有换行或看不见的控制字符，请去掉。"
        case .variantTooShort(let text):
            return "「\(Self.excerpt(text))」太短：识别成的错误写法至少要 \(LexiconLimits.minVariantCharacters) 个字或字母（标点和空格不算），一个字会误伤太多正常句子。"
        case .variantHasNoLetters(let text):
            return "「\(Self.excerpt(text))」里没有文字或数字，不能当作错误写法。"
        case .tooManyVariants:
            return "一个词条最多放 \(LexiconLimits.maxVariantsPerTerm) 个错误写法。"
        case .tooManyTerms:
            return "词库已满（最多 \(LexiconLimits.maxTerms) 条），请先删掉一些。"
        case .duplicateCanonical(let text):
            return "词库里已经有「\(Self.excerpt(text))」这个写法了。"
        case .termNotFound:
            return "这个词条已经不存在了。"
        }
    }

    private static func excerpt(_ text: String) -> String {
        text.count > 16 ? String(text.prefix(16)) + "…" : text
    }
}

/// One entry of the personal lexicon: the spelling the person wants (`canonical`) and the spellings a
/// recognizer gets wrong (`variants`). An entry without variants is a plain hot word: it corrects nothing on
/// its own, it only tells recognizers that accept vocabulary hints what to expect.
public struct LexiconTerm: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var canonical: String
    public var variants: [String]
    public var isEnabled: Bool
    public var source: LexiconSource
    public let createdAt: Date
    /// How many dictations this entry corrected. Flushed lazily; never affects matching.
    public var hitCount: Int
    public var lastHitAt: Date?
    public var learningSightings: Int

    public init(
        id: UUID = UUID(),
        canonical: String,
        variants: [String] = [],
        isEnabled: Bool = true,
        source: LexiconSource = .manual,
        createdAt: Date = Date(),
        hitCount: Int = 0,
        lastHitAt: Date? = nil,
        learningSightings: Int = 0
    ) {
        self.id = id
        self.canonical = canonical
        self.variants = variants
        self.isEnabled = isEnabled
        self.source = source
        self.createdAt = createdAt
        self.hitCount = hitCount
        self.lastHitAt = lastHitAt
        self.learningSightings = min(max(0, learningSightings), 100)
    }

    private enum CodingKeys: String, CodingKey {
        case id, canonical, variants, enabled, source, createdAt, hits, lastHitAt, learningSightings
    }

    /// Tolerant on purpose: the file may have been edited by hand, and a bad bookkeeping field (a counter that
    /// is not a number, a date in another format) must not cost the person the entry. Only what changes how
    /// text is corrected, the right spelling and the wrong ones, has to be readable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        canonical = try c.decode(String.self, forKey: .canonical)
        variants = try c.decodeIfPresent([String].self, forKey: .variants) ?? []
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        source = (try? c.decodeIfPresent(LexiconSource.self, forKey: .source)) ?? .manual
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        hitCount = min(max(0, (try? c.decodeIfPresent(Int.self, forKey: .hits)) ?? 0), LexiconLimits.maxHitCount)
        lastHitAt = try? c.decodeIfPresent(Date.self, forKey: .lastHitAt)
        learningSightings = min(max(0, (try? c.decodeIfPresent(Int.self, forKey: .learningSightings)) ?? 0), 100)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(canonical, forKey: .canonical)
        try c.encode(variants, forKey: .variants)
        try c.encode(isEnabled, forKey: .enabled)
        try c.encode(source, forKey: .source)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(hitCount, forKey: .hits)
        try c.encodeIfPresent(lastHitAt, forKey: .lastHitAt)
        if learningSightings > 0 { try c.encode(learningSightings, forKey: .learningSightings) }
    }
}

/// Spelling rules shared by the store, the matcher and the correction diff.
public enum LexiconText {
    /// ASCII letters fold to lower case; everything else is compared exactly. This is the one definition of
    /// "the same spelling" for dedupe and matching.
    @inline(__always)
    public static func fold(_ character: Character) -> Character {
        guard let value = character.asciiValue, value >= 65, value <= 90 else { return character }
        return Character(UnicodeScalar(value + 32))
    }

    public static func foldKey(_ text: String) -> String {
        String(text.map(fold))
    }

    /// Letters and digits of any script: what counts toward a wrong spelling's minimum length.
    @inline(__always)
    public static func isSignificant(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// How many letters and digits `text` has: the length that counts for a wrong spelling.
    public static func significantCount<S: Sequence>(_ text: S) -> Int where S.Element == Character {
        text.reduce(0) { $0 + (isSignificant($1) ? 1 : 0) }
    }

    /// ASCII letters and digits: the characters a match must not cut through.
    @inline(__always)
    public static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard let value = character.asciiValue else { return false }
        return (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    /// Trims, drops what cannot be a wrong spelling and returns the cleaned pair. Variants equal to the
    /// canonical spelling (exactly) are dropped silently, so are repeats that differ only in ASCII case.
    public static func normalize(
        canonical rawCanonical: String,
        variants rawVariants: [String],
        allowSingleHanVariant: Bool = false
    ) throws -> (canonical: String, variants: [String]) {
        let canonical = try clean(rawCanonical)
        guard !canonical.isEmpty else { throw LexiconValidationError.emptyCanonical }
        try checkSpelling(canonical)
        var seen = Set<String>()
        var variants: [String] = []
        for raw in rawVariants {
            let variant = try clean(raw)
            if variant.isEmpty || variant == canonical { continue }
            try checkSpelling(variant)
            let significant = significantCount(variant)
            guard significant > 0 else { throw LexiconValidationError.variantHasNoLetters(variant) }
            guard significant >= LexiconLimits.minVariantCharacters
                || (allowSingleHanVariant && variant.count == 1 && variant.allSatisfy(isHan)) else {
                throw LexiconValidationError.variantTooShort(variant)
            }
            if seen.insert(foldKey(variant)).inserted { variants.append(variant) }
        }
        guard variants.count <= LexiconLimits.maxVariantsPerTerm else {
            throw LexiconValidationError.tooManyVariants
        }
        return (canonical, variants)
    }

    private static func clean(_ text: String) throws -> String {
        // Nothing this large can be a spelling; refuse before doing any work on it.
        guard text.utf8.count <= 1_024 else { throw LexiconValidationError.tooLong(String(text.prefix(20))) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    private static func checkSpelling(_ text: String) throws {
        guard text.count <= LexiconLimits.maxCharacters else { throw LexiconValidationError.tooLong(text) }
        if text.unicodeScalars.contains(where: isUnsafe) {
            throw LexiconValidationError.unsafeCharacters(text)
        }
    }
}
