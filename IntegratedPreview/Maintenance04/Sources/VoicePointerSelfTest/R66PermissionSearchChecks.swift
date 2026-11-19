import Foundation
import VoicePointerCore

/// R66 small synthetic group: permission publication and search-cache invalidation.
@MainActor enum R66PermissionSearchChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ passed: Bool, _ label: String) {
            if !passed { failures.append("R66 permission/search: " + label) }
        }

        let permissions = PermissionsViewModel()
        var publishCount = 0
        permissions.onChange = { publishCount += 1 }
        let baseline: [SettingsPermission: SettingsPermissionStatus] = [
            .microphone: .granted, .accessibility: .granted, .inputMonitoring: .denied
        ]
        permissions.update(baseline)
        publishCount = 0
        for _ in 0..<10 { permissions.update(baseline) }
        expect(publishCount == 0, "ten identical status updates publish zero changes")
        var oneChanged = baseline
        oneChanged[.inputMonitoring] = .granted
        permissions.update(oneChanged)
        expect(publishCount == 1, "one changed permission publishes once")

        let entries = [
            LexiconTerm(canonical: "Figma", variants: ["SyntheticWrongOne"], source: .manual),
            LexiconTerm(canonical: "Qoder", variants: ["SyntheticWrongTwo"], source: .manual)
        ]
        var search = LexiconTermSearchCache()
        expect(search.update(terms: entries, query: ""), "first evaluation must run")
        expect(search.visibleTerms.count == 2 && search.calculationCount == 1, "empty returns all")
        expect(!search.update(terms: entries, query: ""), "same input is cached")
        expect(search.calculationCount == 1, "unchanged input does not increment calculation count")

        expect(search.update(terms: entries, query: "FIGMA"), "new canonical query recalculates")
        expect(search.visibleTerms.count == 1 && search.visibleTerms[0].canonical == "Figma",
               "find by canonical spelling")
        expect(!search.update(terms: entries, query: "figma"), "case-only query is equivalent")
        expect(search.update(terms: entries, query: "syntheticwrongtwo"), "variant query recalculates")
        expect(search.visibleTerms.count == 1 && search.visibleTerms[0].canonical == "Qoder",
               "find by alternate wrong spelling")
        let queryCount = search.calculationCount
        expect(!search.update(terms: entries, query: " SYNTHETICWRONGTWO "),
               "trim/case-equivalent query must stay cached")
        expect(search.calculationCount == queryCount, "equivalent query avoids recalculation")
        expect(search.update(terms: entries, query: ""), "clearing query recalculates")
        expect(search.visibleTerms.count == entries.count, "clear query restores all terms")
        let termsCount = search.calculationCount
        expect(search.update(terms: entries + [LexiconTerm(canonical: "Third", source: .manual)], query: ""),
               "changed terms recalculates")
        expect(search.visibleTerms.count == 3 && search.calculationCount == termsCount + 1,
               "only changed terms recalculate once")
        return failures
    }
}
