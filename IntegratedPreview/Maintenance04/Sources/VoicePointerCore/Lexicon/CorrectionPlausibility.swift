import Foundation

extension LexiconText {
    /// A Han (CJK ideograph) character. Kana, Hangul and every other script are not.
    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
            default: return false
            }
        }
    }
}

/// Whether "the recognizer wrote A, the person changed it to B" is a slip of hearing or spelling that a
/// context-free lexicon may repeat, or a change of meaning it must never learn on its own.
///
/// Sounding alike is necessary but not enough. Perfect homophones are exactly the swaps that depend on the
/// sentence (他/她, 的/得, 北京/背景, their/there), and pinyin left in the field while an input method is still
/// composing (在 → zai) is a perfect sound match too. So every pair gets one of three answers: reject, weak
/// (worth listing for the person to confirm, never added on its own) or strong (distinctive enough that seeing
/// the same fix twice may be taken as the person's wish).
///
/// Pure and offline: no dictionary, no model. Chinese is compared by toneless pinyin from Foundation's
/// transliteration, English by letters and by a consonant skeleton, and text in two scripts by skeletons only.
public enum CorrectionPlausibility {
    public enum Confidence: String, Sendable, Equatable {
        case weak
        case strong
    }

    public enum Rejection: String, Sendable, Equatable, CaseIterable {
        /// The changed part has no letters, digits or Han characters: punctuation or spaces only.
        case nothingLeft
        /// A digit changed. Numbers are never a spelling.
        case digits
        /// Han characters were only added or only taken away: a change of meaning, not of hearing.
        case insertionOrDeletion
        /// Pinyin (or letters that start it) stands where Han characters were: an input method still composing.
        case composition
        /// A function word or function character changed: the right one depends on the sentence.
        case functionWord
        /// Kana, Hangul, Cyrillic and the like.
        case script
        /// The two spellings do not sound alike.
        case notSoundAlike
    }

    public enum Verdict: Equatable, Sendable {
        case accept(Confidence)
        case reject(Rejection)
    }

    /// Function characters. A change of exactly one of these is never learned: 他/她, 的/得/地, 在/再, 那/哪.
    private static let functionHan = Set("的得地了着过他她它你您在再是不没那哪这吗吧呢啊嘛呀和与跟把被让给就都也还又才会能可要有无未非们个些么什谁我")

    private static let numeralHan = Set("零〇一二两三四五六七八九十百千万亿")

    /// Words whose right form depends on the sentence: negations, homophones and the small words of English.
    private static let functionWords: Set<String> = Set(
        """
        not no yes allow deny true false none all never always enable disable delete remove now know knew new \
        to too two for four their there they the a an and or but of in on at by buy bye from with without is are \
        was were be been do does did can cannot could will would should must i you your youre he she we me my it \
        its his her this that these those then than here hear where wear write right one won before after up down \
        off out over under
        """.split(whereSeparator: { $0 == " " }).map(String.init)
    )

    public static func judge(variant: String, canonical: String) -> Verdict {
        let v = Array(variant)
        let c = Array(canonical)
        guard !v.isEmpty, !c.isEmpty, v != c else { return .reject(.nothingLeft) }
        if v.contains(where: isForeignLetter) || c.contains(where: isForeignLetter) { return .reject(.script) }
        if let confidence = caseOrSpacingOnly(v, c) {
            // A case change of small words is grammar, not a spelling (it → IT, never → NEVER, the → The).
            let smallWords = words(variant)
            if !smallWords.isEmpty, smallWords.allSatisfy({ functionWords.contains($0) }) { return .reject(.functionWord) }
            // All capitals is emphasis as often as an acronym (STOP, PLEASE NOTE, JSON): at most weak, unless a
            // digit is part of the name (GPT4).
            if confidence == .strong, !c.contains(where: { $0.isLowercase }), !c.contains(where: isDigit) {
                return .accept(.weak)
            }
            return .accept(confidence)
        }

        // The cores: what is left of the pair once the text both share at either end is taken away.
        var prefix = 0
        let common = min(v.count, c.count)
        while prefix < common, v[prefix] == c[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < common - prefix, v[v.count - 1 - suffix] == c[c.count - 1 - suffix] { suffix += 1 }
        let vCore = Array(v[prefix..<(v.count - suffix)])
        let cCore = Array(c[prefix..<(c.count - suffix)])

        guard vCore.contains(where: LexiconText.isSignificant) || cCore.contains(where: LexiconText.isSignificant) else {
            return .reject(.nothingLeft)
        }
        if vCore.contains(where: isDigit) || cCore.contains(where: isDigit) { return .reject(.digits) }
        if (vCore.isEmpty && cCore.contains(where: LexiconText.isHan))
            || (cCore.isEmpty && vCore.contains(where: LexiconText.isHan)) {
            return .reject(.insertionOrDeletion)
        }
        if v.contains(where: LexiconText.isHan), hasApostropheBetweenLetters(c) { return .reject(.composition) }
        if vCore.contains(where: LexiconText.isHan), let typed = lowercaseLetters(cCore) {
            let pinyin = pinyinSyllables(of: vCore).joined()
            if !pinyin.isEmpty, typedForm(pinyin).hasPrefix(typedForm(typed)) { return .reject(.composition) }
        }
        if (vCore.count == 1 && functionHan.contains(vCore[0])) || (cCore.count == 1 && functionHan.contains(cCore[0])) {
            return .reject(.functionWord)
        }
        let changed = changedWords(words(variant), words(canonical))
        for side in [changed.variant, changed.canonical] where !side.isEmpty && side.allSatisfy({ functionWords.contains($0) }) {
            return .reject(.functionWord)
        }
        // Whole words only added or only taken away, no Han involved: a change of wording, not of hearing
        // (final report → report, report → final report).
        if changed.variant.isEmpty != changed.canonical.isEmpty,
           !vCore.contains(where: LexiconText.isHan), !cCore.contains(where: LexiconText.isHan) {
            return .reject(.insertionOrDeletion)
        }

        let variantHan = v.filter(LexiconText.isHan).count
        let canonicalHan = c.filter(LexiconText.isHan).count
        if variantHan > 0 || canonicalHan > 0 {
            let hasLatin = v.contains(where: isLatinLetter) || c.contains(where: isLatinLetter)
            if variantHan > 0, canonicalHan > 0, !hasLatin {
                return hanToHan(v, c, vCore: vCore, cCore: cCore)
            }
            return crossScript(v, c, hanCount: max(variantHan, canonicalHan))
        }
        return latinToLatin(v, c)
    }

    // MARK: - Classification

    /// Only the case of letters or the spaces between them differ. Strong for a spelling that looks like a
    /// name or brand (GitHub, OpenAI, Claude Code) when it is long enough not to be an ordinary word in capitals
    /// ("it" → "IT"); weak otherwise (python → Python).
    private static func caseOrSpacingOnly(_ v: [Character], _ c: [Character]) -> Confidence? {
        let vKey = v.filter { !$0.isWhitespace }.map(LexiconText.fold)
        let cKey = c.filter { !$0.isWhitespace }.map(LexiconText.fold)
        guard vKey == cKey else { return nil }
        guard hasInteriorCapital(c) else { return .weak }
        let letters = v.filter(LexiconText.isSignificant).count
        return wordCount(v) >= 2 || letters >= 4 ? .strong : .weak
    }

    private static func hanToHan(
        _ v: [Character], _ c: [Character], vCore: [Character], cCore: [Character]
    ) -> Verdict {
        let vSyllables = pinyinSyllables(of: v).map(foldedSyllable)
        let cSyllables = pinyinSyllables(of: c).map(foldedSyllable)
        guard !vSyllables.isEmpty, !cSyllables.isEmpty else { return .reject(.notSoundAlike) }
        // A mishearing keeps the number of syllables; more or fewer characters is a change of wording.
        guard vCore.filter(LexiconText.isHan).count == cCore.filter(LexiconText.isHan).count else {
            return .reject(.insertionOrDeletion)
        }
        let score = similarity(vSyllables, cSyllables)
        guard score >= 0.6 else { return .reject(.notSoundAlike) }
        let coreHan = min(vCore.filter(LexiconText.isHan).count, cCore.filter(LexiconText.isHan).count)
        let strong = v.filter(LexiconText.isHan).count >= 3 && coreHan >= 2 && score >= 0.8
        return .accept(strong ? .strong : .weak)
    }

    /// Han on one side and Latin letters on the other, or a mix: only the consonants are compared, because a
    /// name written in Chinese characters keeps its consonants and loses its vowels (吉特哈布 / GitHub).
    private static func crossScript(_ v: [Character], _ c: [Character], hanCount: Int) -> Verdict {
        let vSkeleton = skeleton(of: v)
        let cSkeleton = skeleton(of: c)
        guard vSkeleton.count >= 2, cSkeleton.count >= 2 else { return .reject(.notSoundAlike) }
        let score = similarity(vSkeleton, cSkeleton)
        guard score >= 0.5 else { return .reject(.notSoundAlike) }
        return .accept(score >= 0.75 && hanCount >= 3 ? .strong : .weak)
    }

    /// A single word is dictionary territory (cloud, Tuesday): at most weak. Only a phrase of two or more words
    /// (cloud code → Claude Code, chat gbt → ChatGPT, Worker Body → WorkBuddy) can be strong.
    private static func latinToLatin(_ v: [Character], _ c: [Character]) -> Verdict {
        let vLetters = v.filter(LexiconText.isSignificant).map(LexiconText.fold)
        let cLetters = c.filter(LexiconText.isSignificant).map(LexiconText.fold)
        guard !vLetters.isEmpty, !cLetters.isEmpty else { return .reject(.notSoundAlike) }
        var score = similarity(vLetters, cLetters)
        let vSkeleton = skeleton(of: v)
        let cSkeleton = skeleton(of: c)
        if vSkeleton.count >= 2, cSkeleton.count >= 2 { score = max(score, similarity(vSkeleton, cSkeleton)) }
        guard score >= 0.4 else { return .reject(.notSoundAlike) }
        // Only a spelling with a capital in it can be a name; all lower case is at most weak (it may be the
        // letters of an input method still composing: cloud code → kelaode).
        let canBeAName = cLetters.isEmpty || c.contains(where: { $0.isUppercase })
        return .accept(score >= 0.6 && wordCount(v) >= 2 && canBeAName ? .strong : .weak)
    }

    // MARK: - Characters and words

    private static func isLatinLetter(_ character: Character) -> Bool {
        character.isLetter && character.unicodeScalars.allSatisfy { $0.value < 0x250 }
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard let value = character.asciiValue else { return false }
        return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    /// A letter of a script other than Han or Latin (kana, Hangul, Cyrillic, full-width Latin…).
    private static func isForeignLetter(_ character: Character) -> Bool {
        character.isLetter && !LexiconText.isHan(character) && !isLatinLetter(character)
    }

    private static func isDigit(_ character: Character) -> Bool {
        if numeralHan.contains(character) { return true }
        return character.isWholeNumber && !LexiconText.isHan(character)
    }

    /// A capital after the first letter: GitHub, OpenAI, iPhone, API, and the second word of Claude Code.
    private static func hasInteriorCapital(_ text: [Character]) -> Bool {
        var seenLetter = false
        for character in text {
            if let value = character.asciiValue, value >= 65, value <= 90, seenLetter { return true }
            if character.isLetter { seenLetter = true }
        }
        return false
    }

    private static func wordCount(_ text: [Character]) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if character.isWhitespace {
                inWord = false
            } else if !inWord, LexiconText.isSignificant(character) {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// The ASCII words of `text`, lower case (digits and apostrophes stay inside a word).
    private static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if LexiconText.isASCIIWordCharacter(character) || character == "'" {
                current.append(LexiconText.fold(character))
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The words that differ once the words both sides share at either end are taken away.
    private static func changedWords(
        _ a: [String], _ b: [String]
    ) -> (variant: [String], canonical: [String]) {
        var prefix = 0
        let common = min(a.count, b.count)
        while prefix < common, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < common - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return (Array(a[prefix..<(a.count - suffix)]), Array(b[prefix..<(b.count - suffix)]))
    }

    private static func hasApostropheBetweenLetters(_ text: [Character]) -> Bool {
        guard text.count >= 3 else { return false }
        for index in 1..<(text.count - 1) where text[index] == "'" || text[index] == "\u{2019}" {
            if isASCIILetter(text[index - 1]) && isASCIILetter(text[index + 1]) { return true }
        }
        return false
    }

    /// The lower-case ASCII letters of `core` when it is nothing but those (spaces and apostrophes between
    /// them do not count): what an input method shows while it composes.
    private static func lowercaseLetters(_ core: [Character]) -> String? {
        var letters = ""
        for character in core {
            if character == " " || character == "'" || character == "\u{2019}" { continue }
            guard let value = character.asciiValue, value >= 97, value <= 122 else { return nil }
            letters.append(character)
        }
        return letters.isEmpty ? nil : letters
    }

    // MARK: - Sound

    /// Toneless pinyin of the Han characters in `characters`, one entry per syllable. Empty when there is no
    /// Han character or the transliteration is not available.
    static func pinyinSyllables(of characters: [Character]) -> [String] {
        let han = String(characters.filter(LexiconText.isHan))
        guard !han.isEmpty,
              let toneless = han.applyingTransform(.mandarinToLatin, reverse: false)?
                  .applyingTransform(.stripDiacritics, reverse: false) else { return [] }
        return toneless.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Letters as an input method shows them while it composes, without the differences people blur when they
    /// type pinyin (zh/z, ch/c, sh/s, l/n, -ng/-n): what is typed is compared with the pinyin of what it replaces.
    private static func typedForm(_ letters: String) -> String {
        letters
            .replacingOccurrences(of: "zh", with: "z")
            .replacingOccurrences(of: "ch", with: "c")
            .replacingOccurrences(of: "sh", with: "s")
            .replacingOccurrences(of: "ng", with: "n")
            .replacingOccurrences(of: "l", with: "n")
    }

    /// zh/z, ch/c, sh/s, l/n and -ng/-n sound alike to many speakers, and recognizers mix them up.
    private static func foldedSyllable(_ syllable: String) -> String {
        var letters = Array(syllable)
        if letters.count >= 2, letters[1] == "h", letters[0] == "z" || letters[0] == "c" || letters[0] == "s" {
            letters.remove(at: 1)
        }
        if letters.first == "l" { letters[0] = "n" }
        if letters.count >= 2, letters[letters.count - 1] == "g", letters[letters.count - 2] == "n" {
            letters.removeLast()
        }
        return String(letters)
    }

    /// The consonants of `text` in a form that survives the trip between spellings: Han characters become
    /// pinyin first; vowels, y, w, h and an r that no vowel follows are dropped; letters that sound alike merge
    /// (b/p, d/t, g/k/c/q/j, s/z/x, f/v, l/r); repeats collapse.
    private static func skeleton(of text: [Character]) -> [Character] {
        var source = String(text)
        if text.contains(where: LexiconText.isHan),
           let romanized = source.applyingTransform(.mandarinToLatin, reverse: false)?
               .applyingTransform(.stripDiacritics, reverse: false) {
            source = romanized
        }
        var result: [Character] = []
        for token in source.lowercased().split(whereSeparator: { !isASCIILetter($0) }) {
            let letters = Array(token)
            var index = 0
            while index < letters.count {
                let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
                var mapped: Character?
                switch letters[index] {
                case "b", "p": mapped = "B"
                case "d", "t": mapped = "D"
                case "g", "k", "c", "q", "j": mapped = "K"
                case "s", "z", "x": mapped = "S"
                case "f", "v": mapped = "F"
                case "l": mapped = "L"
                case "m": mapped = "M"
                case "r":
                    if let next, isVowel(next) { mapped = "L" }
                case "n":
                    mapped = "N"
                    // "ng" closing a syllable is one sound.
                    if next == "g", !(index + 2 < letters.count && isVowel(letters[index + 2])) { index += 1 }
                default:
                    mapped = nil
                }
                if let mapped, result.last != mapped { result.append(mapped) }
                index += 1
            }
        }
        return result
    }

    private static func isVowel(_ character: Character) -> Bool {
        character == "a" || character == "e" || character == "i" || character == "o" || character == "u"
    }

    private static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 1 for equal sequences, 0 for nothing in common.
    private static func similarity<T: Equatable>(_ a: [T], _ b: [T]) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return 1 - Double(editDistance(a, b)) / Double(longest)
    }
}
