import Foundation
@_spi(Testing) import VoicePointerCore

/// HP-29: the row, the words and the decisions of the "用于增强本地识别" checkbox, every combination of what the
/// settings know. Pure, so no Mac-only API is needed: the point is that the page cannot offer, word or switch
/// the enhancement in a way the dictation path would not honour, and cannot promise what the app cannot keep.
enum CloudEnhanceWordingChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            if !condition { failures.append("enhance wording: " + label()) }
        }
        // Words that would promise what the app cannot know or keep (as in the route's wording checks), plus what
        // the enhancement must not claim: a better result, or a switch the app makes by itself.
        // "不保证" and "不一定" are hedges, not promises.
        let promises = [
            "保护", "保证", "一定", "零费用", "不会收费", "免费使用", "更准确", "准确率", "提升", "永久",
            "自动积累词库", "自动切换", "自动改用"
        ]
        func promise(in text: String) -> String? {
            let hedged = text.replacingOccurrences(of: "不保证", with: "").replacingOccurrences(of: "不一定", with: "")
            return promises.first { hedged.contains($0) }
        }
        expect(
            promise(in: "可能改善部分结果，不保证每句都更准") == nil && promise(in: "一定更准确") == "一定",
            "the promise check must tell a hedge from a promise"
        )

        func selection(_ mode: VoiceInputMode, _ routeID: String, _ language: String) -> VoiceInputSelection {
            guard let value = try? VoiceInputSelection(mode: mode, routeID: routeID, language: language) else {
                fatalError("a test selection must be valid")
            }
            return value
        }
        let enhanceable: [(String, VoiceInputSelection)] = [
            ("qwen17 zh", selection(.voiceNative, "qwen17-rolling", "zh")),
            ("qwen17 en", selection(.voiceNative, "qwen17-rolling", "en")),
            ("qwen17 auto", selection(.voiceNative, "qwen17-rolling", "auto")),
            ("qwen06 zh", selection(.voiceNative, "qwen06-rolling", "zh")),
            ("qwen06 incremental en", selection(.voiceNative, "qwen06-incremental", "en"))
        ]
        let blocked: [(String, VoiceInputSelection, CloudEnhanceBlocker)] = [
            ("doubao", selection(.doubao, "qwen17-rolling", "zh"), .doubao),
            ("doubao with a leftover cloud route", selection(.doubao, CloudEntry.routeID, "zh"), .doubao),
            ("aliyun route", selection(.voiceNative, CloudEntry.routeID, "zh"), .aliyunRoute),
            ("aliyun route in English", selection(.voiceNative, CloudEntry.routeID, "en"), .aliyunRoute),
            ("apple speech", selection(.voiceNative, "apple-speech", "zh"), .engine),
            ("a leftover Groq route", selection(.voiceNative, "groq-v3", "zh"), .engine),
            ("an unknown route", selection(.voiceNative, "something-else", "zh"), .engine),
            ("qwen17 Cantonese", selection(.voiceNative, "qwen17-rolling", "yue"), .language),
            ("qwen06 Japanese", selection(.voiceNative, "qwen06-rolling", "ja"), .language)
        ]
        let utc = TimeZone(secondsFromGMT: 0)!
        let until = Date(timeIntervalSince1970: 30 * 86_400 + 14 * 3_600)
        let statuses: [(String, CloudEntryStatus)] = [
            ("unavailable", .unavailable), ("unconfirmed", .unconfirmed), ("confirmed", .confirmed(validUntil: until)),
            ("expired", .expired), ("quota", .paused(.freeQuotaExhausted)), ("balance", .paused(.accountBalanceBlocked))
        ]

        // Which selections can be enhanced: the same answer the dictation path and the reconcile rules give.
        for (name, value) in enhanceable {
            expect(CloudEntry.canEnhance(value), "\(name) must be enhanceable")
            expect(CloudEnhanceBlocker(selection: value) == nil, "\(name) has no blocker")
        }
        for (name, value, blocker) in blocked {
            expect(!CloudEntry.canEnhance(value), "\(name) must not be enhanceable")
            expect(CloudEnhanceBlocker(selection: value) == blocker, "\(name) must be blocked as \(blocker)")
        }
        let hints = CloudEnhanceBlocker.allCases.map(\.hint)
        expect(Set(hints).count == CloudEnhanceBlocker.allCases.count, "each blocker has its own line")
        for (blocker, hint) in zip(CloudEnhanceBlocker.allCases, hints) {
            expect(hint.hasPrefix("\(CloudEnhanceWording.toggleTitle)："), "\(blocker): the line starts with the option's name: \(hint)")
            expect(hint.contains("选") || hint.contains("支持") || hint.contains("改成"), "\(blocker): the line says what to do or what is supported: \(hint)")
            if let word = promise(in: hint) { expect(false, "\(blocker): the line must not promise anything (\(word)): \(hint)") }
        }
        expect(
            CloudEnhanceBlocker.language.hint.contains("中文、English 和自动")
                && Set(CloudEntry.supportedLanguages) == ["auto", "zh", "en"],
            "the language line names exactly the languages the Aliyun recognizer takes"
        )

        // The row, for every combination of the facts the page holds.
        for loaded in [false, true] {
            for visible in [false, true] {
                for keySaved in [false, true] {
                    for enhanceOn in [false, true] {
                        for (statusName, status) in statuses {
                            let all = enhanceable.map { ($0.0, $0.1, CloudEnhanceBlocker?.none) }
                                + blocked.map { ($0.0, $0.1, CloudEnhanceBlocker?.some($0.2)) }
                            for (selectionName, current, blocker) in all {
                                let label = "loaded=\(loaded) visible=\(visible) key=\(keySaved) on=\(enhanceOn) \(statusName) \(selectionName)"
                                let row = CloudEnhanceRow(
                                    entryLoaded: loaded, entryVisible: visible, keySaved: keySaved,
                                    selection: current, enhanceOn: enhanceOn, status: status, timeZone: utc
                                )
                                if !(loaded && visible && keySaved) {
                                    expect(row == .hidden, "\(label): nothing is shown before the entry is read, while it is off or without a key: \(row)")
                                } else if let blocker {
                                    expect(row == .unavailable(blocker), "\(label): a selection the enhancement cannot apply to gets one line, not a control: \(row)")
                                } else if !enhanceOn {
                                    expect(row == .offered(isOn: false, status: nil, button: nil), "\(label): an unticked box carries no status: \(row)")
                                } else {
                                    let summary = status.enhanceSummary(timeZone: utc)
                                    expect(
                                        row == .offered(isOn: true, status: summary, button: status.enhanceStepButton),
                                        "\(label): a ticked box carries the state's line and its one step: \(row)"
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        // The ticked box's line: "已开启" only with a valid confirmation, the confirmation step for the rest.
        for (name, status) in statuses {
            let summary = status.enhanceSummary(timeZone: utc)
            let confirmed = status.isUsable
            expect((summary.tone == .ready) == confirmed, "\(name): only a valid confirmation reads as on, got \(summary.text)")
            expect(summary.text.hasPrefix("已开启") == confirmed, "\(name): \"已开启\" is said only while the speech really goes to Aliyun: \(summary.text)")
            expect(confirmed || summary.text.contains("现在只用本地识别"), "\(name): a box that is ticked but not working says the dictation uses this Mac only: \(summary.text)")
            expect(confirmed == (status.enhanceStepButton == nil) || name == "unavailable", "\(name): the button is offered exactly while a confirmation step is missing")
            if let button = status.enhanceStepButton {
                expect(status.enableStep == .confirm(button), "\(name): the button is the step the gate's state calls for")
            }
            expect(summary.text.count <= 26, "\(name): the status line is too long (\(summary.text.count)): \(summary.text)")
            let footer = status.enhanceFooterText
            expect(!footer.isEmpty && footer.count <= 20, "\(name): the sidebar line is empty or too long (\(footer.count)): \(footer)")
            expect(footer.contains("发给阿里云") == confirmed, "\(name): the sidebar says the speech is sent only while it is: \(footer)")
            expect(confirmed || footer.contains("只用本地识别"), "\(name): the sidebar says the dictation uses this Mac only: \(footer)")
            for text in [summary.text, footer] {
                if let word = promise(in: text) { expect(false, "\(name): must not promise anything (\(word)): \(text)") }
            }
        }
        expect(
            CloudEntryStatus.confirmed(validUntil: until).enhanceSummary(timeZone: utc).text == "已开启",
            "a valid confirmation says when it runs out in the route's words"
        )

        // What a tick does: only a valid confirmation, a saved key, no removal under way and an enhanceable
        // selection switch on at once; the sheet asks for what the state calls for; everything else only says why.
        let noKeyLine = CloudEnhanceWording.entryUnusable
        for (selectionName, current) in enhanceable.map({ ($0.0, $0.1) }) + blocked.map({ ($0.0, $0.1) }) {
            for keySaved in [false, true] {
                for removing in [false, true] {
                    for (statusName, status) in statuses {
                        let label = "\(selectionName) key=\(keySaved) removing=\(removing) \(statusName)"
                        let tick = CloudEnhanceWording.tick(selection: current, keySaved: keySaved, removing: removing, status: status)
                        let refusal = CloudEnhanceWording.refusal(selection: current, keySaved: keySaved, removing: removing)
                        if tick == .enable {
                            expect(
                                status.isUsable && keySaved && !removing && CloudEntry.canEnhance(current),
                                "\(label): switched on without everything the gate needs"
                            )
                        }
                        if case .confirm(let kind) = tick {
                            expect(status.enableStep == .confirm(kind) && refusal == nil, "\(label): the sheet asks for another step than the state calls for")
                        }
                        if !keySaved || removing {
                            expect(tick == .refuse(noKeyLine), "\(label): without a key, or while it is being removed, nothing is switched on: \(tick)")
                        } else if let blocker = CloudEnhanceBlocker(selection: current) {
                            expect(tick == .refuse(blocker.hint), "\(label): a selection that cannot be enhanced says why: \(tick)")
                        } else {
                            switch status {
                            case .confirmed, .unconfirmed, .expired:
                                expect(tick == .enable, "\(label): optional quota acknowledgment does not block enhancement: \(tick)")
                            case .unavailable: expect(tick == .refuse(CloudEnhanceWording.statusUnreadable), "\(label): an unreadable state blocks: \(tick)")
                            default:
                                if case .confirm(let kind) = status.enableStep {
                                    expect(tick == .confirm(kind), "\(label): a missing confirmation asks for it: \(tick)")
                                } else {
                                    expect(false, "\(label): a state without a confirmation must be confirmed, unavailable or needing a step")
                                }
                            }
                        }
                        expect((refusal == nil) == (keySaved && !removing && CloudEntry.canEnhance(current)), "\(label): the refusal follows the same guards")
                    }
                }
            }
        }

        // The sheet by purpose. The route's words are untouched; the enhancement's say that the speech goes to
        // Aliyun, that the local result is used when Aliyun is not, and never that anything is switched or fails.
        let kinds: [CloudConfirmationKind] = [.first, .renew, .resume(.freeQuotaExhausted), .resume(.accountBalanceBlocked)]
        for kind in kinds {
            expect(kind.title(for: .route) == kind.title, "\(kind): the route's sheet title is unchanged")
            expect(kind.confirmTitle(for: .route) == kind.confirmTitle, "\(kind): the route's sheet button is unchanged")
            expect(kind.lead(for: .route) == kind.lead, "\(kind): the route's sheet text is unchanged")
            let title = kind.title(for: .enhanceLocal)
            let button = kind.confirmTitle(for: .enhanceLocal)
            let lead = kind.lead(for: .enhanceLocal)
            expect(!title.isEmpty && !button.isEmpty && !lead.isEmpty, "\(kind): the enhancement's sheet is worded")
            expect(lead.contains("发给阿里云") && lead.contains("本地"), "\(kind): the sheet says that the speech goes to Aliyun and that the local result stays: \(lead)")
            expect(
                !lead.contains("切到") && !lead.contains("切换") && !lead.contains("改用") && !lead.contains("会失败"),
                "\(kind): the enhancement switches nothing and fails no dictation: \(lead)"
            )
            for text in [title, button, lead] {
                if let word = promise(in: text) { expect(false, "\(kind): the sheet must not promise anything (\(word)): \(text)") }
            }
            // The title and the button are checked as well: the enhancement does not switch the method either.
            for text in [title, button] {
                expect(
                    !text.contains("切到") && !text.contains("切换") && !text.contains("改用"),
                    "\(kind): the enhancement's sheet title and button switch nothing: \(text)"
                )
            }
            // What the sheet says is sent stays "sent", and the two pauses keep saying that nothing goes out meanwhile.
            expect(
                !lead.contains("不会发给阿里云") && !lead.contains("不发给阿里云") && !lead.contains("不上传"),
                "\(kind): the sheet says that the speech is sent, not the opposite: \(lead)"
            )
            if case .resume = kind {
                expect(lead.contains("不会向阿里云发声音"), "\(kind): a paused sheet says that nothing goes out during the pause: \(lead)")
            }
        }
        expect(Set(kinds.map { $0.lead(for: .enhanceLocal) }).count == 4, "each situation has its own text, the two pauses included")
        expect(
            CloudConfirmationKind.first.title(for: .enhanceLocal) != CloudConfirmationKind.first.title(for: .route)
                && CloudConfirmationKind.first.title(for: .enhanceLocal).contains(CloudEnhanceWording.toggleTitle),
            "the first sheet names the option it is about"
        )
        expect(
            CloudConfirmationKind.resume(.accountBalanceBlocked).lead(for: .enhanceLocal).contains("欠费")
                && !CloudConfirmationKind.resume(.accountBalanceBlocked).lead(for: .enhanceLocal).contains("免费额度用完暂停"),
            "an unpaid account is not passed off as a used-up free quota"
        )
        expect(
            CloudConfirmationKind.resume(.freeQuotaExhausted).lead(for: .enhanceLocal).contains("处理额度问题"),
            "resuming after a used-up quota asks the person to check that this model still has free quota"
        )

        // The note after switching on, the other short lines, and the popover behind the "？".
        let notes = CloudEnhanceSwitch.allCases.map(\.note)
        expect(notes.count == 3 && Set(notes).count == 3, "switching at once, after confirming and after resuming each have their own note")
        for (how, note) in zip(CloudEnhanceSwitch.allCases, notes) {
            expect(note.contains("下次开始说话时生效"), "\(how): the note says when it takes effect: \(note)")
            expect(note.count <= 24, "\(how): the note stays short, the line under the box says what it does: \(note)")
            expect(!note.contains("切换") && !note.contains("改用"), "\(how): the method stays the local one: \(note)")
            if let word = promise(in: note) { expect(false, "\(how): the note must not promise anything (\(word)): \(note)") }
        }
        let lines: [(String, String)] = [
            ("offNote", CloudEnhanceWording.offNote), ("closedByChange", CloudEnhanceWording.closedByChange),
            ("closedByKeyRemoval", CloudEnhanceWording.closedByKeyRemoval), ("statusUnreadable", CloudEnhanceWording.statusUnreadable),
            ("entryUnusable", CloudEnhanceWording.entryUnusable), ("confirmKeptNotEnabled", CloudEnhanceWording.confirmKeptNotEnabled),
            ("confirmFailed", CloudEnhanceWording.confirmFailed), ("closedByRoute", CloudEnhanceWording.closedByRoute),
            ("confirmKeptAlreadyOn", CloudEnhanceWording.confirmKeptAlreadyOn),
            ("inline", CloudEnhanceWording.inline), ("help tooltip", CloudEnhanceWording.helpTooltip)
        ]
        for (name, line) in lines {
            expect(!line.isEmpty, "\(name) is empty")
            if let word = promise(in: line) { expect(false, "\(name) must not promise anything (\(word)): \(line)") }
        }
        // The sheet's outcome notes and the route's closing line are true in every state they can appear in.
        expect(
            !CloudEnhanceWording.closedByRoute.contains("不再发给阿里云") && CloudEnhanceWording.closedByRoute.contains("已关闭"),
            "choosing the Aliyun route closes the enhancement, and its line must not say that the speech stops going to Aliyun: \(CloudEnhanceWording.closedByRoute)"
        )
        expect(
            CloudEnhanceWording.confirmKeptAlreadyOn.contains("开着")
                && CloudEnhanceWording.confirmKeptAlreadyOn.contains("发给阿里云")
                && !CloudEnhanceWording.confirmKeptAlreadyOn.contains("没有开启"),
            "a confirmation kept for a box that was already ticked says that it is on and sends: \(CloudEnhanceWording.confirmKeptAlreadyOn)"
        )
        expect(
            CloudEnhanceWording.confirmFailed.contains("不会发给阿里云") && !CloudEnhanceWording.confirmFailed.contains("保持关闭"),
            "a failed confirmation says that nothing is sent, whatever the box shows: \(CloudEnhanceWording.confirmFailed)"
        )
        expect(
            CloudEnhanceBlocker.engine.hint.contains("本地模型列表") && CloudEnhanceBlocker.engine.hint.contains("千问"),
            "the engine line says where to change the engine: \(CloudEnhanceBlocker.engine.hint)"
        )
        expect(CloudEnhanceWording.toggleTitle == "用于增强本地识别", "the option keeps the name the person chose")
        expect(CloudEnhanceWording.helpAccessibilityLabel.contains(CloudEnhanceWording.toggleTitle), "the \"？\" is named after the option for VoiceOver")
        expect(
            CloudEnhanceWording.inline.contains("发给阿里云") && CloudEnhanceWording.inline.count <= 70,
            "the line under the box says the speech is sent and stays short: \(CloudEnhanceWording.inline)"
        )
        expect(
            CloudEnhanceWording.offNote.contains("不再发给阿里云") && CloudEnhanceWording.closedByChange.contains("不再发给阿里云"),
            "closing the option says that the speech stops going to Aliyun"
        )

        // The local card says "not uploaded" only while nothing is sent.
        expect(
            CloudEnhanceWording.localCardDetail(enhanceActive: false, status: .confirmed(validUntil: until))
                == "在这台 Mac 上识别，声音不上传。",
            "with the box unticked the local card says what it always said"
        )
        for (name, status) in statuses {
            let confirmed = status.isUsable
            let detail = CloudEnhanceWording.localCardDetail(enhanceActive: true, status: status)
            expect(detail.count <= 22, "\(name): the local card line is too long for two lines (\(detail.count)): \(detail)")
            expect(
                detail.contains("发给阿里云") == confirmed && detail.contains("不上传") == !confirmed,
                "\(name): the local card says the speech is sent only while it really is, and not uploaded otherwise: \(detail)"
            )
            if let word = promise(in: detail) { expect(false, "\(name): the local card must not promise anything (\(word)): \(detail)") }
            expect(
                CloudEnhanceWording.localCardDetail(enhanceActive: false, status: status) == CloudEnhanceWording.plainLocalCardDetail,
                "\(name): an unticked box never changes the card"
            )
        }

        let help = CloudEnhanceWording.helpParagraphs
        let helpText = help.joined(separator: "\n")
        expect(help.count == 4 && help.allSatisfy { !$0.isEmpty && $0.count <= 120 }, "the popover is four short paragraphs")
        expect(helpText.contains("发给阿里云"), "the popover says that the speech goes to Aliyun")
        expect(
            help[0].contains("发给阿里云") && help[0].contains("华北2") && help[0].contains("北京") && CloudEntry.region == "cn-beijing",
            "the popover's first paragraph says that the speech goes to Aliyun, and where (the region the endpoint uses): \(help[0])"
        )
        for (name, text) in [("the line under the box", CloudEnhanceWording.inline), ("the popover's first paragraph", help[0])] {
            expect(
                !text.contains("不会发给阿里云") && !text.contains("不发给阿里云") && !text.contains("不上传"),
                "\(name) says that the speech is sent, not the opposite: \(text)"
            )
        }
        // The short lines keep the state they report: what is off says off, what was not enabled says so.
        expect(CloudEnhanceWording.entryUnusable.contains("没有开启"), "the unusable-entry line says that nothing was switched on")
        expect(CloudEnhanceWording.statusUnreadable.contains("不能开启"), "the unreadable-state line says that it cannot be switched on")
        expect(CloudEnhanceWording.confirmKeptNotEnabled.contains("没有开启"), "a confirmation kept for an unticked box says that nothing was switched on")
        expect(
            CloudEnhanceWording.closedByKeyRemoval.contains("关闭") && !CloudEnhanceWording.closedByKeyRemoval.contains("开着"),
            "removing the key says that the option was closed"
        )
        expect(
            CloudEnhanceWording.offNote.contains("已关闭") && CloudEnhanceWording.closedByChange.contains("已关闭")
                && CloudEnhanceWording.closedByRoute.contains("已关闭"),
            "every line that reports the option closed says closed"
        )
        expect(helpText.contains("可能改善") && helpText.contains("不保证每句都更准"), "the popover hedges the benefit")
        expect(helpText.contains("只用本地的结果"), "the popover says what is used when Aliyun is not")
        expect(
            helpText.contains("免费额度用完即停") && helpText.contains("不保证不产生费用"),
            "the popover says where the free-quota protection lives and that nothing is guaranteed"
        )
        expect(
            helpText.contains("最多多等约 2 秒") && HybridBudget().cloudTailMs == 2_000,
            "the wait the popover names is the wait the final-text budget allows"
        )
        if let word = promise(in: helpText) { expect(false, "the popover must not promise anything (\(word)): \(helpText)") }
        return failures
    }
}
