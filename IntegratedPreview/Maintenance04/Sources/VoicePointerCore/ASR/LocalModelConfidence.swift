import Foundation

/// A model's selected-token probability, not a calibrated transcript/word accuracy estimate.
/// Qwen's observer includes language/header tokens and excludes the validated trailing EOS.
public struct LocalModelConfidence: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case qwenSelectedTokenMinimum = "qwen_selected_token_min_probability_v1"
    }

    public let probability: Double
    public let source: Source
    public let tokenCount: Int

    public init?(probability: Double?, source: String?, tokenCount: Int?) {
        guard let probability, probability.isFinite, (0...1).contains(probability),
              let source, let known = Source(rawValue: source),
              let tokenCount, (1...1_000_000).contains(tokenCount) else { return nil }
        self.probability = probability
        self.source = known
        self.tokenCount = tokenCount
    }

    /// Supply one entry per nonempty segment. One missing entry invalidates the whole result.
    static func minimum(_ segments: [LocalModelConfidence?]) -> LocalModelConfidence? {
        guard !segments.isEmpty else { return nil }
        var probability = 1.0, count = 0
        for evidence in segments {
            guard let evidence, count <= 1_000_000 - evidence.tokenCount else { return nil }
            probability = min(probability, evidence.probability)
            count += evidence.tokenCount
        }
        return LocalModelConfidence(probability: probability,
                                    source: Source.qwenSelectedTokenMinimum.rawValue, tokenCount: count)
    }
}
