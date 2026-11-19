import Foundation
@_spi(Testing) import VoicePointerCore

/// Which lexicon words are offered to the recognizer on this Mac, in which order and within which limits, and
/// that a dictation's snapshot (and the local fallback of a cloud dictation) carries them.
enum HotwordChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append("hotwords: " + label) }
        }

        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_750_000_000)
        func term(
            _ canonical: String, variants: [String] = [], enabled: Bool = true, hits: Int = 0,
            lastHit: Date? = nil, created: Date = Date(timeIntervalSince1970: 1_700_000_000)
        ) -> LexiconTerm {
            LexiconTerm(
                canonical: canonical, variants: variants, isEnabled: enabled, source: .manual,
                createdAt: created, hitCount: hits, lastHitAt: lastHit
            )
        }

        // Order: entries with a wrong spelling on record (most hits, then the most recent hit) and plain words
        // (newest first) take turns. Disabled, one-character, repeated (case ignored) and unprintable words never.
        let terms = [
            term("Alpha"),
            term("Bravo", variants: ["braavo"]),
            term("Charlie", variants: ["charly"], hits: 5, lastHit: older),
            term("Delta", variants: ["delter"], hits: 5, lastHit: newer),
            term("Echo", enabled: false),
            term("F"),
            term("alpha"),
            term("Gol\u{7}f"),
            term("Hotel", created: newer),
        ]
        let selected = RecognitionHotwords.select(from: terms)
        expect(selected == ["Delta", "Hotel", "Charlie", "Alpha", "Bravo"], "order and filtering, got \(selected)")
        // A lexicon full of entries with wrong spellings does not shut plain words out, nor the other way round.
        let corrected = (0..<40).map { term("fix\($0)", variants: ["fixed\($0)"], hits: 40 - $0) }
        let withPlain = RecognitionHotwords.select(from: corrected + [term("Plain")])
        expect(withPlain.count == RecognitionHotwords.maximumTerms && withPlain.contains("Plain"), "plain words get a turn")
        expect(withPlain.first == "fix0" && withPlain.dropFirst().first == "Plain", "the two kinds take turns")
        let plains = (0..<40).map { term("plain\($0)") } + [term("Fixed", variants: ["fixd"])]
        expect(RecognitionHotwords.select(from: plains).contains("Fixed"), "entries with wrong spellings get a turn")
        expect(RecognitionHotwords.select(from: []).isEmpty, "an empty lexicon offers nothing")

        // Limits: word count, then bytes.
        let many = (0..<60).map { term("word\($0)") }
        expect(RecognitionHotwords.select(from: many).count == RecognitionHotwords.maximumTerms, "word cap")
        let wide = (0..<40).map { "声声声声声声声声声" + String($0) }
        let wideLine = RecognitionHotwords.line(for: wide) ?? ""
        expect(
            !wideLine.isEmpty && wideLine.utf8.count <= RecognitionHotwords.maximumBytes,
            "byte cap, got \(wideLine.utf8.count)"
        )
        expect(RecognitionHotwords.clean(wide).count > 10 && RecognitionHotwords.clean(wide).count < 32, "byte cap cuts the list")
        let long1 = String(repeating: "a", count: 390)
        let long2 = String(repeating: "b", count: 100)
        expect(
            RecognitionHotwords.clean([long1, long2, "cc"]) == [long1, "cc"],
            "a word that does not fit is skipped and a shorter one after it still fits"
        )
        expect(
            RecognitionHotwords.clean([String(repeating: "z", count: 401)]).isEmpty,
            "a single word longer than the byte cap is never sent"
        )

        // The line: what the worker accepts (no padding, no control characters, well under 1024 bytes).
        expect(RecognitionHotwords.line(for: ["OpenAI", "Qwen"]) == "OpenAI, Qwen", "line format")
        expect(RecognitionHotwords.line(for: []) == nil, "no words, no line")
        expect(
            RecognitionHotwords.line(for: ["  OpenAI\n", "\u{00A0}Qwen\u{3000}"]) == "OpenAI, Qwen",
            "white space is trimmed, non-breaking and ideographic spaces included"
        )
        expect(RecognitionHotwords.line(for: ["x\ny", "ok", "\t"]) == "ok", "control characters and blanks are dropped")
        expect(RecognitionHotwords.line(for: ["OpenAI", "openai", "OPENAI"]) == "OpenAI", "one of each, case ignored")
        expect(RecognitionHotwords.line(for: ["咻"]) == nil, "a single character is not a hot word")
        expect(RecognitionHotwords.line(for: ["C#", "C++"]) == "C#, C++", "two symbols are enough")
        let scalarsOK = wideLine.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        expect(scalarsOK && wideLine == wideLine.trimmingCharacters(in: .whitespacesAndNewlines), "line is plain and unpadded")

        // An echo of the hint: a transcript of nothing but hot words (observed and counted, never dropped).
        let hints = ["OpenAI", "Qwen"]
        expect(RecognitionHotwords.echoedWordCount(in: "OpenAI, Qwen", words: hints) == 2, "echo of the list")
        expect(RecognitionHotwords.echoedWordCount(in: "openai", words: hints) == 1, "one hot word, any case")
        expect(RecognitionHotwords.echoedWordCount(in: "OpenAI is great", words: hints) == 0, "words besides hot words")
        expect(RecognitionHotwords.echoedWordCount(in: "", words: hints) == 0, "nothing said")
        expect(RecognitionHotwords.echoedWordCount(in: "OpenAI", words: []) == 0, "no hot words, no echo")
        expect(
            RecognitionHotwords.echoedWordCount(in: "OpenAI", words: ["Open", "OpenAI"]) == 1,
            "a hot word that contains another is not taken apart"
        )
        expect(
            RecognitionHotwords.echoedWordCount(in: "声声声声声声声声声0，声声声声声声声声声1", words: wide) == 2,
            "an echo of Chinese words"
        )

        // Which local routes take hot words.
        expect(RecognitionHotwords.localRouteAccepts("qwen17-rolling"), "1.7B takes hot words")
        expect(RecognitionHotwords.localRouteAccepts("qwen06-rolling"), "0.6B takes hot words")
        expect(!RecognitionHotwords.localRouteAccepts("aliyun") && !RecognitionHotwords.localRouteAccepts("apple-speech"),
               "other routes do not")

        // The snapshot carries the words; a cloud dictation's local fallback carries them along.
        guard let selection = try? VoiceInputSelection(mode: .voiceNative, routeID: "aliyun", language: "zh"),
              let plain = try? VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 1),
              let hinted = try? VoiceInputSnapshot(
                sessionID: UUID(), selection: selection, lexiconRevision: 1, localHotwords: ["OpenAI", "Qwen"]
              ) else {
            return failures + ["hotwords: snapshot fixtures could not be created"]
        }
        expect(plain.localHotwords.isEmpty, "a snapshot has no hot words unless it is given some")
        expect(hinted.localHotwords == ["OpenAI", "Qwen"], "a snapshot keeps the words it was given")
        expect(
            CloudDictationStart.localFallbackSnapshot(for: hinted)?.localHotwords == ["OpenAI", "Qwen"],
            "the local fallback of a cloud dictation keeps the hot words"
        )
        expect(
            CloudDictationStart.localFallbackSnapshot(for: plain)?.localHotwords == [],
            "the local fallback of a dictation without hot words has none"
        )
        let stripped = hinted.withoutLocalHotwords()
        expect(
            stripped.localHotwords.isEmpty && stripped.sessionID == hinted.sessionID
                && stripped.selection == hinted.selection && stripped.lexiconRevision == hinted.lexiconRevision,
            "a snapshot without hot words is the same capture otherwise"
        )
        expect(hinted.localHotwords == ["OpenAI", "Qwen"], "taking the words out of a copy leaves the original alone")
        return failures
    }
}
