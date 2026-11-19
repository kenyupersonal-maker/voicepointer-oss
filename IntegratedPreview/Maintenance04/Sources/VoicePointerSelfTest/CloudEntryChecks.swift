import Foundation
@_spi(Testing) import VoicePointerCore

/// The Aliyun opt-in entry: what the settings toggles and the credential state turn into for the K06 gate,
/// and that the confirm button drives the gate's own API. Offline: one temporary state file, one temporary
/// UserDefaults suite and canned credential states; no key, network, microphone or worker.
@MainActor
enum CloudEntryChecks {
    private static func evidence(status: Int, code: String) -> AliFailureEvidence {
        let response = HTTPURLResponse(
            url: URL(string: "https://invalid.example/fixture")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = try? JSONSerialization.data(withJSONObject: ["code": code])
        return AliFailureEvidence.httpResponse(response, body: body)!
    }

    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let suiteName = "vp.selftest.cloudentry.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return ["temporary UserDefaults suite unavailable"]
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("CloudEntryChecks-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return ["temporary cloud entry store directory could not be created"]
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: root.appendingPathComponent("state.json")))

        // The entry is offered by default so a key can be pasted, but every switch behind it defaults closed.
        let fresh = CloudEntryPreferences.load(from: defaults)
        expect(fresh == CloudEntryPreferences(), "the defaults must match a freshly built preference set")
        expect(fresh.visible && !fresh.routeEnabled && !fresh.uploadConsent, "the entry must be offered by default with the route and the upload closed")
        // Only the kill switch hides it: with cloud.entry.visible explicitly off there are no inputs and the
        // legacy consent is untouched.
        defaults.set(false, forKey: CloudEntryPreferences.visibleKey)
        expect(!CloudEntryPreferences.load(from: defaults).visible, "an explicit false must switch the entry off")
        defaults.set("NO", forKey: CloudEntryPreferences.visibleKey)
        expect(!CloudEntryPreferences.load(from: defaults).visible, "a string NO written with `defaults write -string` must switch the entry off too")
        defaults.set(false, forKey: CloudEntryPreferences.visibleKey)
        let saved = CloudEntryCredential(isSaved: true, revision: "entry-revision-01")
        CloudEntryPreferences.setRouteEnabled(true, in: defaults)
        CloudEntryPreferences.setUploadConsent(true, in: defaults)
        let flagOff = CloudEntryPreferences.load(from: defaults)
        expect(!flagOff.visible && flagOff.routeEnabled && flagOff.uploadConsent, "the toggles must persist independently of the flag")
        expect(
            CloudEntry.inputs(preferences: flagOff, gate: gate, credential: saved) == nil,
            "with cloud.entry.visible off there must be no admission inputs, whatever else is set"
        )
        expect(flagOff.legacyConsent(merging: ["groq"]) == ["groq"], "with the flag off the legacy consent set must stay as stored")

        // Flag on: still nothing without a saved key and its revision.
        defaults.set(true, forKey: CloudEntryPreferences.visibleKey)
        let on = CloudEntryPreferences.load(from: defaults)
        expect(on.legacyConsent(merging: ["groq"]) == ["groq", CloudEntry.provider], "flag, route and consent must grant the legacy provider consent")
        expect(CloudEntry.inputs(preferences: on, gate: gate, credential: .missing) == nil, "no saved key must give no inputs")
        expect(
            CloudEntry.inputs(preferences: on, gate: gate, credential: CloudEntryCredential(isSaved: true, revision: nil)) == nil,
            "a saved key without a revision must give no inputs"
        )
        expect(
            CloudEntry.inputs(preferences: on, gate: gate, credential: CloudEntryCredential(isSaved: false, revision: "entry-revision-01")) == nil,
            "a revision without a saved key must give no inputs"
        )

        // Identity and requirements come straight from the settings and the credential state.
        guard let inputs = CloudEntry.inputs(preferences: on, gate: gate, credential: saved) else {
            return failures + ["flag, saved key and revision must build admission inputs"]
        }
        let identity = inputs.identity
        expect(
            identity.provider == "aliyun-beijing" && identity.accountReference == "default"
                && identity.credentialRevision == "entry-revision-01" && identity.region == "cn-beijing"
                && identity.workspace == "default" && identity.modelID == "qwen-audio-3.0-asr-flash-streaming",
            "the identity must be the fixed Aliyun Beijing slot plus the credential revision"
        )
        expect(
            inputs.requirements == CloudAdmissionRequirements(
                cloudRouteEnabled: true, credentialAvailable: true, sampleUploadAllowed: true, sessionUploadAllowed: true
            ),
            "route, key and consent must map straight onto the requirements"
        )
        var noConsent = on
        noConsent.uploadConsent = false
        var noRoute = on
        noRoute.routeEnabled = false

        // What a dictation on the Aliyun route gets from the provider closure the app installs.
        guard let selection = try? VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.routeID, language: "zh"),
              let snapshot = try? VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 0) else {
            return failures + ["dictation snapshot fixture could not be created"]
        }
        func start(_ preferences: CloudEntryPreferences, _ credential: CloudEntryCredential) async -> String {
            let provider: CloudAdmissionInputsProvider = { _ in
                CloudEntry.inputs(preferences: preferences, gate: gate, credential: credential)
            }
            switch await CloudDictationStart.resolve(snapshot: snapshot, provider: provider) {
            case .admitted: return "admitted"
            case .denied(let reason): return reason
            }
        }
        expect(await start(on, saved) == "admitted", "a fresh identity must be denied until the user confirms")
        expect(
            CloudEntryStatus(snapshot: await gate.snapshot(for: identity)).enableStep == .switchNow,
            "a fresh identity must ask for the first confirmation before the route is switched on"
        )
        // The settings name 千问 1.7B as where a denied dictation goes. Pinned to the literal route, not to the
        // constant: `CloudDictationStart.localFallbackRouteID` is defined as `CloudEntry.localFallbackRouteID`.
        expect(CloudEntry.localFallbackRouteID == "qwen17-rolling", "the cards name 千问 1.7B as the route a denied cloud dictation runs on")
        for language in ["auto", "zh", "en"] {
            guard let cloudSelection = try? VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.routeID, language: language),
                  let cloudSnapshot = try? VoiceInputSnapshot(
                      sessionID: UUID(), selection: cloudSelection, lexiconRevision: 7, localHotwords: ["词库"]
                  ) else {
                failures.append("fallback fixture could not be created for \(language)")
                continue
            }
            let fallback = CloudDictationStart.localFallbackSnapshot(for: cloudSnapshot)
            expect(
                fallback?.selection == (try? VoiceInputSelection(mode: .voiceNative, routeID: "qwen17-rolling", language: language))
                    && fallback?.sessionID == cloudSnapshot.sessionID && fallback?.lexiconRevision == 7
                    && fallback?.localHotwords == ["词库"],
                "a denied cloud dictation (\(language)) must run on 千问 1.7B with the same session, language, lexicon revision and hot words"
            )
        }
        expect(CloudEntry.supportedLanguages == ["auto", "zh", "en"], "the cloud route recognizes automatic, Chinese and English")
        expect(await start(flagOff, saved) == "notConfigured", "the flag off must reach the coordinator as not configured")
        var noSwitches = CloudEntryPreferences()
        noSwitches.visible = true
        let closedResult = await start(noSwitches, saved)
        expect(closedResult != "admitted", "a saved key with every switch closed must never be admitted")
        expect(await start(on, .missing) == "notConfigured", "no saved key must reach the coordinator as not configured")

        expect(await CloudEntry.confirm(gate: gate, identity: identity) == .confirmed, "the confirm action must be accepted by the gate")
        let confirmedSnapshot = await gate.snapshot(for: identity)
        expect(
            confirmedSnapshot?.policy == .freeOnly && confirmedSnapshot?.guardEvidence == .userConfirmed,
            "confirm must record freeOnly with userConfirmed evidence only"
        )
        expect(await start(on, saved) == "admitted", "flag, key, route, consent and a fresh confirmation must be admitted")
        expect(
            CloudEntryStatus(snapshot: confirmedSnapshot).enableStep == .switchNow,
            "a confirmation the gate admits must let the route switch on at once"
        )
        expect(await start(noConsent, saved) == "sampleUploadNotAllowed", "switching consent off must deny the next dictation")
        expect(await start(noRoute, saved) == "cloudRouteDisabled", "switching the route off must deny the next dictation")
        expect(
            await start(on, CloudEntryCredential(isSaved: true, revision: "entry-revision-02")) == "admitted",
            "a re-saved key must not inherit the confirmation"
        )

        // The status line, and the 30-day lifetime it shows is the one the gate enforces.
        if case .confirmed(let validUntil) = CloudEntryStatus(snapshot: confirmedSnapshot), let observed = confirmedSnapshot?.guardObservedAt {
            expect(
                abs(validUntil.timeIntervalSince(observed) - CloudEntryStatus.confirmationLifetime) < 1,
                "a confirmation must be shown valid for the confirmation lifetime"
            )
        } else {
            expect(false, "a fresh confirmation must read as confirmed")
        }
        let utc = TimeZone(secondsFromGMT: 0)!
        expect(
            CloudEntryStatus.confirmed(validUntil: Date(timeIntervalSince1970: 30 * 86_400 + 14 * 3_600)).title(timeZone: utc) == "已确认"
                && CloudEntryStatus.unconfirmed.title() == "未确认" && CloudEntryStatus.expired.title() == "已确认"
                && CloudEntryStatus.paused(.freeQuotaExhausted).title() == "已暂停：免费额度用完",
            "the status lines must match the wording of the settings section"
        )
        func aged(_ age: TimeInterval, revision: String) async -> (String, CloudEntryStatus)? {
            let credential = CloudEntryCredential(isSaved: true, revision: revision)
            guard let fixture = CloudEntry.inputs(preferences: on, gate: gate, credential: credential) else { return nil }
            _ = await CloudEntry.confirm(gate: gate, identity: fixture.identity, now: Date(timeIntervalSinceNow: -age))
            return (await start(on, credential), CloudEntryStatus(snapshot: await gate.snapshot(for: fixture.identity)))
        }
        let lifetime = CloudEntryStatus.confirmationLifetime
        if let inside = await aged(lifetime - 5, revision: "entry-age-inside"),
           let outside = await aged(lifetime + 5, revision: "entry-age-outside") {
            expect(inside.0 == "admitted" && inside.1.isConfirmed, "a confirmation just inside the shown lifetime must admit")
            expect(outside.0 == "admitted" && outside.1.isConfirmed, "a confirmation just outside the shown lifetime must be expired")
            expect(
                inside.1.enableStep == .switchNow && outside.1.enableStep == .switchNow,
                "inside its lifetime the route switches on at once, an expired confirmation asks to be renewed"
            )
        } else {
            expect(false, "lifetime fixtures could not be built")
        }

        // A pause is shown, and only the explicit recheck-and-resume that the button uses clears it.
        _ = await gate.recordProviderFailure(evidence(status: 403, code: "AllocationQuota.FreeTierOnly"), for: identity)
        expect(await start(on, saved) == "paused.freeQuotaExhausted", "a quota pause must deny the next dictation")
        expect(
            CloudEntryStatus(snapshot: await gate.snapshot(for: identity)).title() == "已暂停：免费额度用完",
            "a quota pause must show in the status line"
        )
        expect(
            CloudEntryStatus(snapshot: await gate.snapshot(for: identity)).enableStep == .confirm(.resume(.freeQuotaExhausted)),
            "a paused identity must offer the resume sheet, not switch on"
        )
        expect(await CloudEntry.confirm(gate: gate, identity: identity) == .resumed, "confirming a paused identity must recheck and resume")
        expect(await start(on, saved) == "admitted", "a resumed identity must be admitted again")
        _ = await gate.recordProviderFailure(evidence(status: 400, code: "Arrearage"), for: identity)
        expect(
            CloudEntryStatus(snapshot: await gate.snapshot(for: identity)).title() == "已暂停：账户欠费或余额不足",
            "a balance block must show its own reason"
        )

        // Switching the route off returns to the previous non-cloud selection.
        CloudEntryPreferences.rememberPreviousSelection(mode: .doubao, routeID: "qwen06-rolling", in: defaults)
        let previous = CloudEntryPreferences.previousSelection(in: defaults)
        expect(previous?.mode == .doubao && previous?.routeID == "qwen06-rolling", "the previous selection must round-trip")
        CloudEntryPreferences.rememberPreviousSelection(mode: .voiceNative, routeID: CloudEntry.routeID, in: defaults)
        expect(CloudEntryPreferences.previousSelection(in: defaults) == nil, "the cloud route is never a selection to return to")
        failures += await enhanceLocalChecks()
        failures += wordingChecks()
        return failures
    }

    /// What the settings say about the Aliyun route: which step comes before it is switched on, the short lines of
    /// the recognition-method card, the details and the sidebar, and the notes around switching. Pure, so the words
    /// cannot drift from the states unnoticed.
    private static func wordingChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        // Words that would promise what the app cannot know or keep. "不保证" and "不一定" are hedges, not promises.
        let promises = ["保护", "保证", "一定", "零费用", "不会收费", "免费使用", "更准确", "永久", "自动积累词库"]
        func promise(in text: String) -> String? {
            let hedged = text.replacingOccurrences(of: "不保证", with: "").replacingOccurrences(of: "不一定", with: "")
            return promises.first { hedged.contains($0) }
        }
        expect(
            promise(in: "也不保证不产生费用") == nil && promise(in: "保证不产生费用") == "保证",
            "the promise check must tell a hedge from a promise"
        )
        let utc = TimeZone(secondsFromGMT: 0)!
        // 1970-01-31 14:00 UTC, and 1970-12-31 09:05 UTC (364 days, 9 hours, 5 minutes): the longest month and
        // day, and a morning hour.
        let until = Date(timeIntervalSince1970: 30 * 86_400 + 14 * 3_600)
        let longUntil = Date(timeIntervalSince1970: 31_482_300)
        let all: [(String, CloudEntryStatus)] = [
            ("unavailable", .unavailable), ("unconfirmed", .unconfirmed), ("confirmed", .confirmed(validUntil: until)),
            ("confirmed-long", .confirmed(validUntil: longUntil)), ("expired", .expired),
            ("quota", .paused(.freeQuotaExhausted)), ("balance", .paused(.accountBalanceBlocked))
        ]

        expect(CloudEntryStatus.unavailable.enableStep == .blocked, "an unreadable state must block the switch")
        expect(CloudEntryStatus.unconfirmed.enableStep == .switchNow, "unconfirmed asks for the first confirmation")
        expect(CloudEntryStatus.expired.enableStep == .switchNow, "expired asks to renew")
        expect(
            CloudEntryStatus.paused(.freeQuotaExhausted).enableStep == .confirm(.resume(.freeQuotaExhausted)),
            "a quota pause asks to resume, and knows it is the quota"
        )
        expect(
            CloudEntryStatus.paused(.accountBalanceBlocked).enableStep == .confirm(.resume(.accountBalanceBlocked)),
            "a balance pause asks to resume, and knows it is the account"
        )
        expect(CloudEntryStatus.confirmed(validUntil: until).enableStep == .switchNow, "a valid confirmation switches at once")

        // When a confirmation runs out: to the minute, on a 24-hour clock, in the time zone handed in. It ends at
        // the time of day it was given, so the day alone would be up to a day off.
        expect(
            CloudEntryStatus.validUntilText(until, timeZone: utc) == "1月31日 14:00",
            "the end of a confirmation is written month, day and the 24-hour time"
        )
        expect(CloudEntryStatus.validUntilText(longUntil, timeZone: utc) == "12月31日 09:05", "hours and minutes keep two digits")
        expect(
            CloudEntryStatus.validUntilText(until, timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!) == "1月31日 22:00",
            "the time zone handed in decides the day and the hour"
        )

        // The card: only a valid confirmation with both switches on, on the selected card, reads as in use. A
        // selected card that is not in use says plainly that the dictation runs on this Mac, and says that nothing
        // can take it when the local route it would fall back to is not ready either.
        for (name, status) in all {
            for selected in [false, true] {
                for switchesOn in [false, true] {
                    for localReady in [true, false] {
                        let label = "\(name) selected=\(selected) switchesOn=\(switchesOn) localReady=\(localReady)"
                        let summary = status.cardSummary(
                            selected: selected, switchesOn: switchesOn, localFallbackReady: localReady, timeZone: utc
                        )
                        let inUse = summary.text == "使用中"
                        expect(!summary.text.isEmpty, "\(label): the card line is empty")
                        expect(
                            inUse == (status.isUsable && selected && switchesOn),
                            "\(label): only a confirmed, selected, switched-on route is in use, got \(summary.text)"
                        )
                        if selected && !inUse {
                            if localReady {
                                expect(summary.text.contains("现在用本地识别"), "\(label): a selected but unusable route must say it runs on this Mac, got \(summary.text)")
                            } else {
                                expect(summary.text == CloudEntryLine.nothingReady, "\(label): with the local route not ready either, nothing can take the dictation, got \(summary.text)")
                            }
                            expect(summary.tone == .attention, "\(label): a selected route that is not in use is a warning")
                        }
                        if !selected {
                            expect(
                                summary == status.cardSummary(
                                    selected: false, switchesOn: switchesOn, localFallbackReady: !localReady, timeZone: utc
                                ),
                                "\(label): an unselected card does not depend on the local route"
                            )
                        }
                        expect(summary.text.count <= 20, "\(label): too long for the card (\(summary.text.count)): \(summary.text)")
                        expect(
                            !summary.text.contains("确认至") && !summary.text.contains("前有效"),
                            "\(label): the end of a confirmation is written the old way: \(summary.text)"
                        )
                        if let word = promise(in: summary.text) {
                            expect(false, "\(label): the card must not sound like the app guarantees anything (\(word)): \(summary.text)")
                        }
                    }
                }
            }
        }
        let unselectedConfirmed = CloudEntryStatus.confirmed(validUntil: until)
            .cardSummary(selected: false, switchesOn: false, localFallbackReady: true, timeZone: utc)
        expect(
            unselectedConfirmed.text == "可切换",
            "an unselected confirmed card shows when the person's confirmation runs out, got \(unselectedConfirmed.text)"
        )
        expect(
            CloudEntryStatus.confirmed(validUntil: until).cardSummary(selected: true, switchesOn: true, localFallbackReady: false).tone == .ready,
            "in use is the only green line, whatever the local route"
        )
        expect(
            CloudEntryStatus.unconfirmed.cardSummary(selected: false, switchesOn: false, localFallbackReady: true).tone == .neutral,
            "an unconfirmed card only offers a click"
        )

        // The details row says when the confirmation runs out in the card's words.
        let row = CloudEntryStatus.confirmed(validUntil: until).protectionSummary(timeZone: utc)
        expect(row == CloudEntrySummary("已确认", .neutral), "the confirmation row of a confirmed identity, got \(row.text)")
        let moment = "已确认"
        expect(
            row.text == moment && !unselectedConfirmed.text.contains("有效至"),
            "the card and the row must say when the confirmation runs out in the same words"
        )
        for (name, status) in all {
            let text = status.protectionSummary(timeZone: utc).text
            if !name.hasPrefix("confirmed") {
                expect(status.protectionSummary().tone == .neutral, "\(name): the confirmation row must ask for attention")
            }
            expect(!text.contains("确认至") && !text.contains("前有效"), "\(name): the end of a confirmation is written the old way: \(text)")
            if let word = promise(in: text) { expect(false, "\(name): the row must not promise anything (\(word)): \(text)") }
        }

        // The sidebar: "现在用本地识别" only while the local route a denied dictation falls back to is ready.
        for (name, status) in all {
            for switchesOn in [false, true] {
                for localReady in [true, false] {
                    let label = "\(name) switchesOn=\(switchesOn) localReady=\(localReady)"
                    let text = status.footerText(switchesOn: switchesOn, localFallbackReady: localReady)
                    expect(!text.isEmpty && text.count <= 20, "\(label): the sidebar line is empty or too long (\(text.count)): \(text)")
                    if status.isUsable && switchesOn {
                        expect(text == "阿里云识别，声音会上传", "\(label): a route in use says that the speech is uploaded: \(text)")
                    } else if localReady {
                        expect(text.contains("现在用本地识别"), "\(label): the sidebar line must say it runs on this Mac: \(text)")
                    } else {
                        expect(text == CloudEntryLine.nothingReady, "\(label): with the local route not ready either, nothing can take the dictation: \(text)")
                    }
                    expect(!text.contains("自动"), "\(label): a line about the running route must not promise an automatic switch: \(text)")
                    if let word = promise(in: text) { expect(false, "\(label): the sidebar must not promise anything (\(word)): \(text)") }
                }
            }
        }

        // Lines that do not come from the gate: before the first read, and when nothing can take a dictation.
        for line in [CloudEntryLine.loading, CloudEntryLine.nothingReady] {
            expect(!line.isEmpty && line.count <= 20, "a card or sidebar line is empty or too long (\(line.count)): \(line)")
            if let word = promise(in: line) { expect(false, "a card or sidebar line must not promise anything (\(word)): \(line)") }
        }
        expect(
            !CloudEntryLine.loading.contains("关") && !CloudEntryLine.loading.contains("本地识别") && !CloudEntryLine.loading.contains("本地"),
            "before the first read the page must say neither closed nor local: \(CloudEntryLine.loading)"
        )
        expect(!CloudEntryLine.nothingReady.contains("本地识别"), "with nothing ready the line must not say it runs on this Mac")
        expect(
            CloudEntryLine.saveFailedCloudOff.contains("阿里云已停用") && !CloudEntryLine.saveFailedCloudOff.contains("恢复"),
            "a failed save on the way into or out of Aliyun says Aliyun is off, not that anything was restored"
        )

        // The note right after switching on: where the speech goes, and what fails a dictation that is under way.
        // The gate lets a dictation start whatever the network or the key, so no note promises the local route.
        let notes = CloudRouteSwitch.allCases.map(\.note)
        expect(notes.count == 3 && Set(notes).count == 3, "switching at once, after confirming and after resuming each have their own note")
        for (how, note) in zip(CloudRouteSwitch.allCases, notes) {
            expect(note.contains("发给阿里云"), "\(how): the note must say the speech goes to Aliyun: \(note)")
            expect(
                note.contains("没网") && note.contains("Key 失效") && note.contains("会失败"),
                "\(how): the note must say that no network or a rejected key fails the dictation: \(note)"
            )
            expect(!note.contains("改用本地") && !note.contains("自动"), "\(how): the note must not promise a switch to the local route: \(note)")
            if let word = promise(in: note) { expect(false, "\(how): the note must not promise anything (\(word)): \(note)") }
        }

        // The sheet: three situations (the pause in two flavours), their own words, one button each. Its button
        // switches the route on, so every sheet says that the speech goes to Aliyun; the first one also says that
        // a dictation can fail once it is under way, because nothing switches to the local route mid-sentence.
        let kinds: [CloudConfirmationKind] = [.first, .renew, .resume(.freeQuotaExhausted), .resume(.accountBalanceBlocked)]
        expect(Set(kinds.map(\.title)).count == 3, "first, renew and resume each have their own title")
        expect(Set(kinds.map(\.confirmTitle)).count == 3, "first, renew and resume each have their own button")
        expect(Set(kinds.map(\.rowButtonTitle)).count == 3, "first, renew and resume each have their own row button")
        expect(Set(kinds.map(\.lead)).count == 4, "a used-up quota and an unpaid account are explained in different words")
        expect(kinds.allSatisfy { $0.lead.contains("发给阿里云") }, "each sheet says plainly that the speech goes to Aliyun")
        expect(
            CloudConfirmationKind.first.lead.contains("会失败") && CloudConfirmationKind.first.lead.contains("Key 失效"),
            "the first sheet says a dictation can fail once it is under way, a rejected key included"
        )
        expect(
            CloudConfirmationKind.resume(.accountBalanceBlocked).lead.contains("欠费")
                && !CloudConfirmationKind.resume(.accountBalanceBlocked).lead.contains("免费额度用完暂停"),
            "an unpaid account is not passed off as a used-up free quota"
        )
        let quotaLead = CloudConfirmationKind.resume(.freeQuotaExhausted).lead
        expect(
            quotaLead.contains("处理额度问题") && !quotaLead.contains("额度已经恢复"),
            "resuming after a used-up quota asks the person to check that this model still has free quota: \(quotaLead)"
        )
        for kind in kinds {
            for text in [kind.title, kind.confirmTitle, kind.rowButtonTitle, kind.lead] {
                if let word = promise(in: text) { expect(false, "\(kind): the sheet must not promise anything (\(word)): \(text)") }
            }
        }
        return failures
    }
}
