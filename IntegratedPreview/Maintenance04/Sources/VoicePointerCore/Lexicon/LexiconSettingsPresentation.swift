// T6 2026-10-02: Lexicon page summary and pending-entry presentation shared by UI and offline checks.
import Foundation

public struct LexiconSettingsPresentation: Equatable, Sendable {
    public struct PendingSection: Equatable, Sendable {
        public let badgeCount: Int
    }

    public let termCount: Int
    public let pendingCount: Int

    public init(termCount: Int, pendingCount: Int) {
        self.termCount = max(0, termCount)
        self.pendingCount = max(0, pendingCount)
    }

    public var pendingSection: PendingSection? {
        pendingCount == 0 ? nil : PendingSection(badgeCount: pendingCount)
    }

    public static let manualAddDisclosureExpandedByDefault = false
    public static let pendingDisclosureExpandedByDefault = false
}
