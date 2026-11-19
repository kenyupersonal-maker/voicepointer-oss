import Foundation
@_spi(Testing) import VoicePointerCore

enum InlineWritePolicyChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("W \(label)") } }
        expect(!InlineWritePolicy.allows(bundle: "com.tencent.workbuddy.mac", chromium: false), "WorkBuddy always final-only")
        expect(InlineWritePolicy.allows(bundle: "com.anthropic.claudefordesktop", chromium: true), "verified Claude allowed")
        expect(InlineWritePolicy.allows(bundle: "com.openai.codex", chromium: true), "Codex allowed")
        expect(!InlineWritePolicy.allows(bundle: "fixture.chromium", chromium: true), "unknown Chromium final-only")
        expect(InlineWritePolicy.allows(bundle: "com.apple.TextEdit", chromium: false), "native editor unchanged")
        expect(!InlineWritePolicy.allows(bundle: "com.openai.codex", chromium: true, automaticallyDenied: true), "demotion overrides allowlist")
        expect(InlineWritePolicy.diagnosticClasses(["cm-content", "editor", "sk-invalid", String(repeating: "a", count: 25), "a b", "123", "user@host"]) == ["cm-content", "editor"], "bounded interface names only")
        expect(InlineWritePolicy.diagnosticClasses(Array(repeating: "editor", count: 8)).count == 6, "six class ceiling")
        let suite = "VoicePointerInlinePolicyChecks." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return failures + ["W defaults fixture"] }
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = InlineWriteRuntime(defaults: defaults)
        runtime.noteWrite(bundle: "fixture.app", now: 100)
        expect(!runtime.noteFailure(bundle: "fixture.app", reason: .deliveryUnconfirmed, now: 101), "uncertain delivery never demotes")
        expect(!runtime.isDenied("fixture.app", now: 101), "uncertainty keeps inline allowed")
        expect(!runtime.noteFailure(bundle: "fixture.app", reason: .deliveryUnconfirmed, hintRelated: true, now: 101), "hint mismatch never demotes")
        expect(!runtime.noteFailure(bundle: "fixture.app", reason: .unchangedPaste, now: 102), "one unchanged paste retained")
        expect(runtime.noteFailure(bundle: "fixture.app", reason: .unchangedPaste, now: 103), "two consecutive unchanged pastes demote")
        expect(InlineWriteRuntime(defaults: defaults).isDenied("fixture.app"), "denial survives restart")
        expect(!runtime.noteFailure(bundle: "fixture.unwritten", reason: .sendStillPresent, now: 104), "no prior inline write means no demotion")
        runtime.noteWrite(bundle: "fixture.old", now: 100)
        expect(!runtime.noteFailure(bundle: "fixture.old", reason: .sendStillPresent, now: 1901), "past 30min is ignored")
        runtime.noteWrite(bundle: "fixture.confirmed", now: 100)
        _ = runtime.noteFailure(bundle: "fixture.confirmed", reason: .unchangedPaste, now: 101)
        runtime.notePasteConfirmed(bundle: "fixture.confirmed")
        expect(!runtime.noteFailure(bundle: "fixture.confirmed", reason: .unchangedPaste, now: 102), "confirmed paste resets streak")
        for bundle in InlineWritePolicy.chromiumAllowlist.sorted() {
            runtime.noteWrite(bundle: bundle, now: 200)
            expect(runtime.noteFailure(bundle: bundle, reason: .sendStillPresent, now: 201), "strong send evidence demotes allowlisted app")
            expect(!runtime.noteFailure(bundle: bundle, reason: .sendStillPresent, now: 202), "duplicate evidence does not repeat notice")
            expect(runtime.isDenied(bundle, now: 201 + InlineWriteRuntime.temporaryLifetime - 1), "allowlist retains active demotion before 24 hours")
            expect(!InlineWriteRuntime(defaults: defaults).isDenied(bundle, now: 202), "allowlist recovers after process restart")
            expect(!runtime.isDenied(bundle, now: 201 + InlineWriteRuntime.temporaryLifetime), "allowlist recovers at 24 hours")
            runtime.noteWrite(bundle: bundle, now: 90000)
            expect(!runtime.noteFailure(bundle: bundle, reason: .unchangedPaste, now: 90001), "allowlist single unchanged paste retained")
            expect(runtime.noteFailure(bundle: bundle, reason: .unchangedPaste, now: 90002), "allowlist repeated unchanged paste demotes")
            expect(runtime.restore(bundle: bundle), "user restore succeeds")
            expect(!runtime.isDenied(bundle, now: 90003), "user restore clears deny")
            runtime.noteWrite(bundle: bundle, now: 91000)
            expect(runtime.noteFailure(bundle: bundle, reason: .sendStillPresent, now: 91001), "fresh strong evidence can temporarily demote again")
            expect(runtime.noteApplicationRestart(bundle: bundle) && !runtime.isDenied(bundle, now: 91002), "target application restart restores allowlist")
        }
        runtime.noteWrite(bundle: "fixture.interrupted", now: 300)
        _ = runtime.noteFailure(bundle: "fixture.interrupted", reason: .unchangedPaste, now: 301)
        _ = runtime.noteFailure(bundle: "fixture.interrupted", reason: .deliveryUnconfirmed, now: 302)
        expect(runtime.noteFailure(bundle: "fixture.interrupted", reason: .unchangedPaste, now: 303), "weak final outcome does not erase preceding unchanged-paste evidence")
        runtime.noteWrite(bundle: "fixture.persistent", now: 400)
        expect(runtime.noteFailure(bundle: "fixture.persistent", reason: .sendStillPresent, now: 401), "other app strong evidence demotes")
        expect(runtime.isDenied("fixture.persistent", now: 401 + InlineWriteRuntime.temporaryLifetime), "other app denial does not expire")
        expect(!runtime.noteApplicationRestart(bundle: "fixture.persistent") && runtime.isDenied("fixture.persistent"), "other app restart preserves persistent denial")
        let legacy: [InlineWriteRuntime.Denial] = [
            .init(bundle: "com.anthropic.claudefordesktop", reason: .deliveryUnconfirmed, at: 10),
            .init(bundle: "fixture.legacy", reason: .deliveryUnconfirmed, at: 10),
            .init(bundle: "com.openai.codex", reason: .sendStillPresent, at: 10),
            .init(bundle: "com.tencent.workbuddy.mac", reason: .unchangedPaste, at: 10)]
        defaults.set(try? JSONEncoder().encode(legacy), forKey: InlineWriteRuntime.key)
        let migrated = InlineWriteRuntime(defaults: defaults)
        expect(migrated.activeDenials(now: 11) == [legacy[3]], "startup removes all obsolete reasons and allowlist records only")
        let persisted = defaults.data(forKey: InlineWriteRuntime.key).flatMap { try? JSONDecoder().decode([InlineWriteRuntime.Denial].self, from: $0) }
        expect(persisted == [legacy[3]], "startup migration persisted")
        expect(migrated.restore(bundle: legacy[3].bundle), "persistent application can be explicitly restored")
        let hint = "synthetic empty input hint27"
        let origin = NSRange(location: 1, length: 0)
        var memory = EmptyHintMemory()
        expect(!memory.recognizesAtStart(value: hint, selection: origin, processIdentifier: 1, bundleIdentifier: nil), "real draft at 1:0 is not a hint")
        let expected = (hint as NSString).replacingCharacters(in: origin, with: "fixture")
        expect(memory.noteVanished(original: hint, selection: origin, expectedDocument: expected, observed: "fixture", processIdentifier: 1), "1:0 vanished hint observed")
        expect(!memory.isKnown(hint, processIdentifier: 1), "vanished value needs return evidence")
        expect(memory.recognizesAtStart(value: hint, selection: origin, processIdentifier: 1, bundleIdentifier: nil), "return promotes exact hint")
        expect(SwallowedReturnPolicy.allowsRetry(bundleIdentifier: "com.tencent.workbuddy.mac"), "WorkBuddy Return retry enabled")
        expect(ClearSwipePolicy.allowsClear(bundleIdentifier: "com.tencent.workbuddy.mac", role: "AXTextArea", valueLength: 27), "WorkBuddy short composer clear remains allowed")
        expect(!ClearSwipePolicy.allowsClear(bundleIdentifier: "com.tencent.workbuddy.mac", role: "AXTextArea", valueLength: 100000), "retry list does not authorize clearing WorkBuddy documents")
        return failures
    }
}
