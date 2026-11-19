import Foundation

/// A value cache shared by the lexicon page and its synthetic search checks.
/// Filtering runs only when source entries or the committed (debounced) query change.
public struct LexiconTermSearchCache: Sendable {
    private var previousTerms: [LexiconTerm] = []
    private var previousQuery = ""
    private var hasCalculated = false

    public private(set) var visibleTerms: [LexiconTerm] = []
    public private(set) var calculationCount: Int = 0

    public init() {}

    @discardableResult
    public mutating func update(terms: [LexiconTerm], query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !hasCalculated || previousTerms != terms || previousQuery != needle else { return false }
        previousTerms = terms
        previousQuery = needle
        hasCalculated = true
        calculationCount += 1
        let all = Array(terms.reversed())
        visibleTerms = needle.isEmpty ? all : all.filter { term in
            term.canonical.lowercased().contains(needle)
                || term.variants.contains { $0.lowercased().contains(needle) }
        }
        return true
    }
}
