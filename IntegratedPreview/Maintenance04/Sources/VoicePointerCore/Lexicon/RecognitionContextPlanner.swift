import Foundation

public struct RecognitionContextPlan: Sendable, Equatable {
    public let terms: [String]
    public let recent: [String]
    public let localText: String?
    public var bytes: Int { localText?.utf8.count ?? 0 }
    public var characters: Int { terms.reduce(0) { $0 + $1.count } + recent.reduce(0) { $0 + $1.count } }
}

/// No inference, substitutions or I/O. Callers pass RecognitionHotwords.select's
/// existing order; this only narrows that selection to the combined budget.
public enum RecognitionContextPlanner {
    public enum Destination: Sendable { case local, cloud }
    public struct Options: Sendable {
        public var termsEnabled: Bool
        public var recentEnabled: Bool
        public var localBytes: Int
        public init(termsEnabled: Bool = true, recentEnabled: Bool = true, localBytes: Int = 600) {
            self.termsEnabled = termsEnabled; self.recentEnabled = recentEnabled
            self.localBytes = max(0, min(1024, localBytes))
        }
    }
    public static let maximumTerms = 16
    public static let maximumTermBytes = 240
    public static let localBytes = 600
    public static let hardMaximumBytes = 1024
    public static func plan(
        selectedTerms: [String], memory: [RecognitionMemoryStore.Entry], appKey: String,
        now: Date, destination: Destination, options: Options = Options()
    ) -> RecognitionContextPlan? {
        var terms: [String] = []; var seenTerms = Set<String>(); var termBytes = 0
        if options.termsEnabled {
            for raw in selectedTerms {
                let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = term.lowercased()
                guard term.count >= 2, !RecognitionMemoryStore.hasDisallowedControls(term, allowLineBreaks: false),
                      !seenTerms.contains(key), terms.count < maximumTerms else { continue }
                if case .cloud = destination, term.count > 64 { continue }
                let cost = term.utf8.count + (terms.isEmpty ? 0 : 2)
                guard termBytes + cost <= maximumTermBytes else { continue }
                seenTerms.insert(key); terms.append(term); termBytes += cost
            }
        }
        var recent: [String] = []; var seenRecent = Set<String>()
        if options.recentEnabled, !appKey.isEmpty, !RecognitionMemoryStore.denies(appKey: appKey) {
            let entries = memory.filter {
                let age = now.timeIntervalSince($0.createdAt)
                guard $0.appKey == appKey, age.isFinite, age >= 0, age < RecognitionMemoryStore.lifetime,
                      !RecognitionMemoryStore.isSensitive($0.text) else { return false }
                if case .cloud = destination { return $0.cloudSeen }
                return true
            }.sorted { $0.createdAt < $1.createdAt }
            // Deduplicate newest first, so repeated sentences don't consume an old slot.
            for entry in entries.reversed() {
                let text = String(entry.text.suffix(RecognitionMemoryStore.maximumCharacters))
                guard !text.isEmpty, !seenRecent.contains(text), !RecognitionMemoryStore.hasDisallowedControls(text) else { continue }
                seenRecent.insert(text); recent.append(text)
                if recent.count == RecognitionMemoryStore.maximumEntries { break }
            }
            recent.reverse()
        }
        if case .cloud = destination {
            guard !terms.isEmpty || !recent.isEmpty else { return nil }
            return RecognitionContextPlan(terms: terms, recent: recent, localText: nil)
        }
        // Whole terms take priority even when callers request a smaller test budget.
        let budget = max(0, min(hardMaximumBytes, options.localBytes))
        var fittingTerms: [String] = []; var used = 0
        for term in terms {
            let cost = term.utf8.count + (fittingTerms.isEmpty ? 0 : 2)
            if used + cost <= budget { fittingTerms.append(term); used += cost }
        }
        func joined(_ texts: [String]) -> String {
            ([fittingTerms.isEmpty ? nil : fittingTerms.joined(separator: ", ")].compactMap { $0 } + texts).joined(separator: "\n")
        }
        // Remove characters from the oldest entry first. A Character may span many
        // scalars (a family emoji); never split its UTF-8 representation.
        while !recent.isEmpty, joined(recent).utf8.count > budget {
            recent[0].removeFirst()
            if recent[0].isEmpty { recent.removeFirst() }
        }
        let text = joined(recent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return RecognitionContextPlan(terms: fittingTerms, recent: recent, localText: text)
    }
}
