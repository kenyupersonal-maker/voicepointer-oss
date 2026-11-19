// T7 2026-10-02: Source-neutral, fail-closed enhancement learning; memory candidates only.
import Foundation

public struct EnhancementLearningConfiguration: Sendable, Equatable {
    public var timeWindow: TimeInterval = 8
    public var minimumLengthRatio = 0.8
    public var minimumSimilarity = 0.8
    public var minimumLocalConfidence = 0.9
    public var minimumAlignmentConfidence = 0.9
    public var requiredRounds = 3
    public var candidateLimit = 100
    public var candidateLifetime: TimeInterval = 300
    public var observationLifetime: TimeInterval = 300
    public var maximumTextCharacters = 512
    public init() {}
    public var isValid: Bool {
        timeWindow.isFinite && timeWindow >= 0 && candidateLifetime.isFinite && candidateLifetime > 0
        && observationLifetime.isFinite && observationLifetime > 0
        && [minimumLengthRatio, minimumSimilarity, minimumLocalConfidence, minimumAlignmentConfidence]
            .allSatisfy { $0.isFinite && (0...1).contains($0) }
        && (2...100).contains(requiredRounds) && (1...200).contains(candidateLimit)
        && (1...1024).contains(maximumTextCharacters)
    }
}

/// Complete sentences are transient inputs only. The source is a closed vocabulary, never a log label.
public struct EnhancementComparison: Sendable, Equatable {
    public enum Source: String, Sendable { case onlineAPI, doubao }
    public let roundID: UUID
    public let localText: String
    public let referenceText: String
    public let localAt: Date
    public let referenceAt: Date
    /// A recognizer's actual numeric confidence, if available. Stability/timing cannot supply this value.
    public let localConfidence: Double?
    public let source: Source
    public let audio: DoubaoLearningAudio?
    public let snapshot: VoiceInputSnapshot?
    public init(roundID: UUID, localText: String, referenceText: String, localAt: Date, referenceAt: Date,
                localConfidence: Double?, source: Source, audio: DoubaoLearningAudio? = nil, snapshot: VoiceInputSnapshot? = nil) {
        self.roundID = roundID; self.localText = localText; self.referenceText = referenceText
        self.localAt = localAt; self.referenceAt = referenceAt; self.localConfidence = localConfidence; self.source = source
        self.audio = audio; self.snapshot = snapshot
    }
}

public enum EnhancementLearningPipeline {
    public enum Decision: String, Sendable { case disabled, invalidConfiguration, edited, timeWindow, lengthRatio,
        alignment, unknownConfidence, lowConfidence, privacy, conflict, noDifference, candidate, duplicateRound, promoted,
        unobserved, expired, cancelled, persistenceFailed }
    public struct Difference: Sendable, Equatable {
        public let variant: String
        public let canonical: String
        public init(variant: String, canonical: String) { self.variant = variant; self.canonical = canonical }
    }
    public struct Evaluation: Sendable, Equatable {
        public let decision: Decision
        public let differences: [Difference]
        public let alignmentConfidence: Double
    }

    /// Character edit similarity, distinct from model confidence. Bounded by configuration before use.
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(LexiconText.foldKey(lhs)), b = Array(LexiconText.foldKey(rhs))
        guard !a.isEmpty, !b.isEmpty else { return a == b ? 1 : 0 }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                row[j + 1] = min(row[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1))
            }
            previous = row
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    /// Conservative context + word filtering: false positives are preferable to learning personal details.
    public static func containsPrivateInformation(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return true }
        if text.contains("@") || text.contains("://") || text.contains("¥") || text.contains("￥") || text.contains("$") { return true }
        let hints = ["邮箱", "电话", "手机", "证件", "身份证", "护照", "账号", "帐号", "银行卡", "地址", "住址", "住在",
                     "我叫", "姓名", "联系人", "生日", "出生", "金额", "人民币", "美元", "万元", "百元", "元钱", "门牌", "小区",
                     "街道", "路口", "先生", "女士", "密码", "邮编", "号码", "隐私", "email", "phone", "address", "password", "account"]
        let folded = text.lowercased()
        if hints.contains(where: { folded.contains($0) }) { return true }
        // Chinese written numbers and address suffixes are also rejected without needing a numeric parser.
        if text.contains(where: { "零一二三四五六七八九十百千万亿〇壹贰叁肆伍陆柒捌玖拾佰仟元省市县镇村路街号楼室".contains($0) }) { return true }
        return false
    }

    public static func conflicts(_ difference: Difference, terms: [LexiconTerm], confirmed: [Difference]) -> Bool {
        if CorrectionLearner.conflict(variant: difference.variant, canonical: difference.canonical, terms: terms) != nil { return true }
        let keys = Set([LexiconText.foldKey(difference.variant), LexiconText.foldKey(difference.canonical)])
        return terms.contains { keys.contains(LexiconText.foldKey($0.canonical)) }
            || confirmed.contains { !keys.isDisjoint(with: [LexiconText.foldKey($0.variant), LexiconText.foldKey($0.canonical)]) }
    }

    public static func evaluate(_ input: EnhancementComparison, userEdited: Bool,
                                configuration c: EnhancementLearningConfiguration,
                                terms: [LexiconTerm], confirmed: [Difference] = []) -> Evaluation {
        func reject(_ reason: Decision, _ score: Double = 0) -> Evaluation {
            Evaluation(decision: reason, differences: [], alignmentConfidence: score)
        }
        guard c.isValid else { return reject(.invalidConfiguration) }
        guard !userEdited else { return reject(.edited) }
        let interval = abs(input.referenceAt.timeIntervalSince(input.localAt))
        guard interval.isFinite, interval <= c.timeWindow else { return reject(.timeWindow) }
        let n = input.localText.count, m = input.referenceText.count
        guard n > 0, m > 0, max(n, m) <= c.maximumTextCharacters else { return reject(.lengthRatio) }
        guard Double(min(n, m)) / Double(max(n, m)) >= c.minimumLengthRatio else { return reject(.lengthRatio) }
        let alignment = similarity(input.localText, input.referenceText)
        guard alignment >= c.minimumSimilarity, alignment >= c.minimumAlignmentConfidence else { return reject(.alignment, alignment) }
        guard let confidence = input.localConfidence, confidence.isFinite, (0...1).contains(confidence) else { return reject(.unknownConfidence, alignment) }
        guard confidence >= c.minimumLocalConfidence else { return reject(.lowConfidence, alignment) }
        guard !containsPrivateInformation(input.localText), !containsPrivateInformation(input.referenceText) else { return reject(.privacy, alignment) }
        // Existing hunk, reading/plausibility, matcher and conflict rules remain the only spelling extractor.
        let record = DictationRecord(id: input.roundID, date: input.localAt, rawText: input.localText,
                                     text: input.localText, hits: [], routeID: "enhancement")
        let result = CorrectionLearner.evaluate(record: record, editedDictation: input.referenceText,
                                               finalDocument: input.referenceText, terms: [])
        let differences = result.candidates.map { Difference(variant: $0.variant, canonical: $0.canonical) }
        guard !differences.isEmpty else { return reject(.noDifference, alignment) }
        guard !differences.contains(where: { conflicts($0, terms: terms, confirmed: confirmed) }) else { return reject(.conflict, alignment) }
        // Short CJK names are ambiguous: never automatically learn a plausible person's name.
        guard !differences.contains(where: { d in
            [d.variant, d.canonical].contains { word in
                containsPrivateInformation(word) || ((2...4).contains(word.count) && word.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) })
            }
        }) else { return reject(.privacy, alignment) }
        return Evaluation(decision: .candidate, differences: differences, alignmentConfidence: alignment)
    }

    /// Only this shape is handed to persistence: a difference word pair + cross-round count.
    public struct Promotion: Sendable, Equatable {
        public let difference: Difference
        public let sightings: Int
        public let verified: Bool
        public let hotwordOnly: Bool
        public let rechecked: Bool
        public init(difference: Difference, sightings: Int, verified: Bool = false, hotwordOnly: Bool = false, rechecked: Bool = false) {
            self.difference=difference;self.sightings=sightings;self.verified=verified;self.hotwordOnly=hotwordOnly;self.rechecked=rechecked
        }
    }
    public struct CandidatePool: Sendable {
        private struct Entry: Sendable { let difference: Difference; var rounds: Set<UUID>; var lastAt: Date }
        private var entries: [Entry] = []
        private var previousConfiguration: EnhancementLearningConfiguration?
        public var count: Int { entries.count }
        public init() {}
        public mutating func removeAll() { entries.removeAll() }
        public mutating func ingest(_ evaluation: Evaluation, roundID: UUID, now: Date,
                                    configuration c: EnhancementLearningConfiguration,
                                    terms: [LexiconTerm], confirmed: [Difference] = []) -> (Decision, [Promotion]) {
            guard c.isValid else { return (.invalidConfiguration, []) }
            if previousConfiguration != c { entries.removeAll(); previousConfiguration = c }
            entries.removeAll { now.timeIntervalSince($0.lastAt) > c.candidateLifetime || now < $0.lastAt }
            guard evaluation.decision == .candidate else { return (evaluation.decision, []) }
            var promotions: [Promotion] = [], fresh = false
            for difference in evaluation.differences {
                guard !conflicts(difference, terms: terms, confirmed: confirmed) else {
                    entries.removeAll { $0.difference == difference }; continue
                }
                if let i = entries.firstIndex(where: { $0.difference == difference }) {
                    if entries[i].rounds.insert(roundID).inserted { fresh = true; entries[i].lastAt = now }
                    if entries[i].rounds.count >= c.requiredRounds {
                        promotions.append(Promotion(difference: difference, sightings: entries[i].rounds.count))
                        entries.remove(at: i)
                    }
                } else {
                    if entries.count >= c.candidateLimit { entries.removeFirst() }
                    entries.append(Entry(difference: difference, rounds: [roundID], lastAt: now)); fresh = true
                }
            }
            return (promotions.isEmpty ? (fresh ? .candidate : .duplicateRound) : .promoted, promotions)
        }
    }

    /// Exact whitelist serialization, with no freely supplied string values.
    public static func log(decision: Decision, candidates: Int, promotions: Int) -> String {
        "event=enhancement_learning decision=\(decision.rawValue) candidates=\(max(0, candidates)) promotions=\(max(0, promotions))"
    }
    public static func authorizationLog(online: Bool, learning: Bool, doubao: Bool) -> String {
        "event=enhancement_learning authorize online=\(online ? 1 : 0) learning=\(learning ? 1 : 0) doubao=\(doubao ? 1 : 0)"
    }
    public static func isSafeLog(_ line: String) -> Bool {
        if line.hasPrefix("event=enhancement_learning authorize ") {
            return line.range(of: "^event=enhancement_learning authorize online=[01] learning=[01] doubao=[01]$", options: .regularExpression) != nil
        }
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count == 4, parts[0] == "event=enhancement_learning",
              parts[1].hasPrefix("decision="), Decision(rawValue: String(parts[1].dropFirst(9))) != nil else { return false }
        return zip(parts.suffix(2), ["candidates=", "promotions="]).allSatisfy { value, prefix in
            value.hasPrefix(prefix) && !value.dropFirst(prefix.count).isEmpty
                && value.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}

/// A synchronous permit shared with the store actor. Closing waits for an already-admitted write;
/// after it returns, no queued or late write from the old generation can commit.
public final class EnhancementLearningPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    public init() {}
    public func update(enabled newValue: Bool) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if enabled != newValue { generation &+= 1; enabled = newValue }
        return generation
    }
    public func allows(_ epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return enabled && generation == epoch
    }
    public func withAuthorization<T>(_ epoch: UInt64, _ body: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard enabled && generation == epoch else { return nil }; return try body()
    }
}
