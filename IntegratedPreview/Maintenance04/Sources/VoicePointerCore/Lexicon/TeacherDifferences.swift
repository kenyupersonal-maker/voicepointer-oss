import Foundation

/// Teacher comparison ignores formatting and keeps independent changes, including sentence edges.
/// Context widening protects against single-character replacement rules; it is not the human-edit policy.
public enum TeacherDifferences {
    public enum Rejection: String { case span, limit }
    public static func split(local: String, teacher: String, rejected: (Rejection) -> Void = { _ in }) -> [EnhancementLearningPipeline.Difference] {
        let a = Array(TeacherLearningPolicy.normalized(local)), b = Array(TeacherLearningPolicy.normalized(teacher))
        guard !a.isEmpty, !b.isEmpty, a != b, a.count <= 1500, b.count <= 1500 else { return [] }
        let originalA = significantCharacters(local, normalized: a), originalB = significantCharacters(teacher, normalized: b)
        let width = b.count + 1
        var lcs = [UInt16](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i * width + j] = a[i] == b[j] ? lcs[(i + 1) * width + j + 1] + 1
                    : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }
        var spans: [(Int, Int, Int, Int)] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { i += 1; j += 1; continue }
            let ai = i, bj = j
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] { break }
                if j == b.count || (i < a.count && lcs[(i + 1) * width + j] >= lcs[i * width + j + 1]) { i += 1 }
                else { j += 1 }
            }
            spans.append((ai, i, bj, j))
        }
        var result: [EnhancementLearningPipeline.Difference] = []
        for (startA, endA, startB, endB) in spans {
            if result.count == 6 { rejected(.limit); break }
            var loA = startA, hiA = endA, loB = startB, hiB = endB
            // Preserve ASCII token boundaries without swallowing adjacent normalized Chinese.
            while asciiJoined(originalA, at: loA) { loA -= 1 }
            while asciiJoined(originalB, at: loB) { loB -= 1 }
            while asciiJoined(originalA, at: hiA) { hiA += 1 }
            while asciiJoined(originalB, at: hiB) { hiB += 1 }
            while hiA - loA < LexiconLimits.minVariantCharacters || hiB == loB {
                if loA > 0, loB > 0, a[loA - 1] == b[loB - 1] { loA -= 1; loB -= 1 }
                else if hiA < a.count, hiB < b.count, a[hiA] == b[hiB] { hiA += 1; hiB += 1 }
                else { break }
            }
            guard hiA - loA >= LexiconLimits.minVariantCharacters, hiB > loB,
                  hiA - loA <= LexiconLimits.maxCharacters, hiB - loB <= LexiconLimits.maxCharacters else { rejected(.span); continue }
            let candidate = EnhancementLearningPipeline.Difference(variant: String(originalA[loA..<hiA].map(\.character)),
                canonical: String(originalB[loB..<hiB].map(\.character)))
            if !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }
    private static func significantCharacters(_ text: String, normalized: [Character]) -> [(character: Character, offset: Int)] {
        let raw = Array(text.precomposedStringWithCompatibilityMapping).enumerated()
            .filter { $0.element.isLetter || $0.element.isNumber }.map { (character: $0.element, offset: $0.offset) }
        // Some Unicode lowercase mappings expand a character; keep alignment safe in that rare case.
        return raw.count == normalized.count ? raw : normalized.enumerated().map { (character: $0.element, offset: $0.offset) }
    }
    private static func asciiJoined(_ characters: [(character: Character, offset: Int)], at index: Int) -> Bool {
        index > 0 && index < characters.count && characters[index].offset == characters[index - 1].offset + 1
            && LexiconText.isASCIIWordCharacter(characters[index - 1].character)
            && LexiconText.isASCIIWordCharacter(characters[index].character)
    }
}
