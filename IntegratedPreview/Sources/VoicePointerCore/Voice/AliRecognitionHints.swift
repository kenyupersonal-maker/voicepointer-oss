import Foundation

public enum AliRecognitionHintsError: Error { case invalid }

public struct AliRecognitionHints: Sendable, Equatable {
    public let recentTexts: [String]
    public let termTexts: [String]

    public init(recentTexts: [String], termTexts: [String]) throws {
        guard recentTexts.count <= 3, termTexts.count <= 16 else { throw AliRecognitionHintsError.invalid }
        for s in recentTexts {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t == s, !t.isEmpty, t.unicodeScalars.count <= 400,
                  AliRecognitionHints.valid(t, allowLF: true) else { throw AliRecognitionHintsError.invalid }
        }
        var seen = Set<String>()
        for s in termTexts {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t == s, !t.isEmpty, t.unicodeScalars.count <= 64,
                  AliRecognitionHints.valid(t, allowLF: false), !seen.contains(t) else { throw AliRecognitionHintsError.invalid }
            seen.insert(t)
        }
        self.recentTexts = recentTexts
        self.termTexts = termTexts
    }

    public var isEmpty: Bool { recentTexts.isEmpty && termTexts.isEmpty }

    static func valid(_ s: String, allowLF: Bool) -> Bool {
        s.unicodeScalars.allSatisfy { sc in
            if sc.value < 32 || sc.value == 127 {
                return allowLF && (sc.value == 10 || sc.value == 9)
            }
            return true
        }
    }
}
