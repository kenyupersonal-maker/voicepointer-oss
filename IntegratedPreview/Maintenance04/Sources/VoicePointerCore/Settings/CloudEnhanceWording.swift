import Foundation

// The settings' words for "用于增强本地识别" (Aliyun helping the local Qwen route), and when its row is shown.
//
// Pure Foundation, like `CloudEntryWording`, so the self-tests run every case. Nothing here decides whether a
// dictation goes to the cloud: that stays with `CloudAdmissionGate` and the coordinator, asked once per
// dictation. This file only turns facts the settings already hold (what is selected, whether a key is saved,
// what the gate's persisted state says) into which row the page shows, the lines on it, what a tick has to do
// first, and the words of the confirmation sheet for this purpose.
//
// What the words may promise follows what the dictation does. The local route writes its text while the
// person speaks. The cloud only gets a chance to supply the final text: when its complete result is in within
// the budget it is used (after the personal lexicon), otherwise the local text is. A dictation the gate denies
// at its start (nothing confirmed, confirmation expired, quota paused) and one whose cloud branch fails or
// stops later both end on the local text, so the lines say "可能" and "不保证", never that the result is more
// accurate, free, or protected, and they do not say that anything switches by itself.

/// Why "用于增强本地识别" cannot be ticked for the selection the person has now.
public enum CloudEnhanceBlocker: Sendable, Equatable, CaseIterable {
    /// Doubao is the recognition method.
    case doubao
    /// Aliyun itself is the recognition method.
    case aliyunRoute
    /// A local engine the Aliyun recognizer cannot enhance (Apple system recognition).
    case engine
    /// A Qwen engine in a language the Aliyun recognizer does not take.
    case language

    /// nil when the selection can be enhanced (`CloudEntry.canEnhance`, the question the dictation path asks too).
    public init?(selection: VoiceInputSelection, provider: OnlineAPIProvider = .aliyunBailian) {
        guard !CloudEntry.canEnhance(selection, provider: provider) else { return nil }
        if selection.mode != .voiceNative {
            self = .doubao
        } else if provider.isAliyun && selection.routeID == CloudEntry.routeID {
            self = .aliyunRoute
        } else if provider.isAliyun && HybridSpeechRoute.localRouteIDs.contains(selection.routeID) {
            self = .language
        } else {
            self = .engine
        }
    }

    /// The one line the page shows in place of the checkbox.
    public var hint: String {
        switch self {
        case .doubao: "用于增强本地识别：先选上面的「本地识别」，再回来勾选。"
        case .aliyunRoute: "用于增强本地识别：现在用的就是阿里云识别；选「本地识别」后才能勾选。"
        case .engine: "用于增强本地识别：只支持千问模型；在上面的本地模型列表里选千问后可以打开。"
        case .language: "用于增强本地识别：阿里云只认中文、English 和自动，把识别语言改成其中一种后可以勾选。"
        }
    }
}

/// What a tick of the checkbox has to do.
public enum CloudEnhanceTick: Sendable, Equatable {
    /// A valid confirmation is on record: switch on at once.
    case enable
    /// The person confirms first, in the sheet worded for the kind.
    case confirm(CloudConfirmationKind)
    /// Nothing changes; this is why.
    case refuse(String)
}

/// Which row the page shows for "用于增强本地识别".
public enum CloudEnhanceRow: Sendable, Equatable {
    /// Nothing: the entry has not been read yet, is switched off, or no key is saved.
    case hidden
    /// A key is saved but this selection cannot be enhanced: one line, no control.
    case unavailable(CloudEnhanceBlocker)
    /// The checkbox. `isOn` is the stored switch. While it is on, `status` says whether the speech really goes to
    /// Aliyun at the moment and `button` is the confirmation step that would make it so (nil when none is needed
    /// or the state cannot be read).
    case offered(isOn: Bool, status: CloudEntrySummary?, button: CloudConfirmationKind?)

    public init(
        entryLoaded: Bool,
        entryVisible: Bool,
        keySaved: Bool,
        selection: VoiceInputSelection,
        enhanceOn: Bool,
        status: CloudEntryStatus,
        timeZone: TimeZone = .current,
        provider: OnlineAPIProvider = .aliyunBailian
    ) {
        guard entryLoaded, entryVisible, keySaved else {
            self = .hidden
            return
        }
        if let blocker = CloudEnhanceBlocker(selection: selection, provider: provider) {
            self = .unavailable(blocker)
            return
        }
        guard enhanceOn else {
            self = .offered(isOn: false, status: nil, button: nil)
            return
        }
        self = provider.isAliyun
            ? .offered(isOn: true, status: status.enhanceSummary(timeZone: timeZone), button: status.enhanceStepButton)
            : .offered(isOn: true, status: CloudEntrySummary("已开启", .ready), button: nil)
    }
}

extension CloudEntryStatus {
    /// The status line of the ticked checkbox. "已开启" only with a valid confirmation; every other state says that
    /// for now the dictation only uses this Mac.
    public func enhanceSummary(timeZone: TimeZone = .current) -> CloudEntrySummary {
        switch self {
        case .confirmed, .unconfirmed, .expired:
            return CloudEntrySummary("已开启", .ready)
        case .paused(.freeQuotaExhausted):
            return CloudEntrySummary("免费额度用完，现在只用本地识别", .attention)
        case .paused(.accountBalanceBlocked):
            return CloudEntrySummary("账户欠费，现在只用本地识别", .attention)
        case .unavailable:
            return CloudEntrySummary("状态读不到，现在只用本地识别", .attention)
        }
    }

    /// The button next to the status line: the step that would make the ticked checkbox work. Nothing while the
    /// confirmation is valid, and nothing when the state cannot be read.
    public var enhanceStepButton: CloudConfirmationKind? {
        if case .confirm(let kind) = enableStep { return kind }
        return nil
    }

    /// The line at the foot of the sidebar while a local Qwen route is selected and the checkbox is ticked.
    public var enhanceFooterText: String {
        switch self {
        case .confirmed, .unconfirmed, .expired: "本地识别；声音也会发给阿里云"
        case .paused(.freeQuotaExhausted): "阿里云额度用完，只用本地识别"
        case .paused(.accountBalanceBlocked): "阿里云账户欠费，只用本地识别"
        case .unavailable: "阿里云状态读不到，只用本地识别"
        }
    }
}

/// How the enhancement was just switched on, which decides the note under the checkbox.
public enum CloudEnhanceSwitch: Sendable, Equatable, CaseIterable {
    /// A valid confirmation was on record: ticking switched at once.
    case direct
    /// Confirmed in the sheet, the first time or again after 30 days.
    case confirmed
    /// Rechecked and resumed in the sheet after a pause.
    case resumed

    /// When it starts. What it does is the line under the checkbox (`CloudEnhanceWording.inline`), on screen the whole
    /// time, so the note does not repeat it. The recognition method stays the local one, so nothing here says that
    /// the method changed.
    public var note: String {
        switch self {
        case .direct: "已开启，下次开始说话时生效。"
        case .confirmed: "已确认并开启，下次开始说话时生效。"
        case .resumed: "已记下你的确认并恢复，下次开始说话时生效。"
        }
    }
}

public enum CloudEnhanceWording {
    public static let toggleTitle = "用于增强本地识别"
    public static let uploadConsentAction = "允许上传并开启"
    public static let helpAccessibilityLabel = "关于「用于增强本地识别」"
    public static let helpTooltip = "这是做什么的"

    /// Under the checkbox at all times, ticked or not: what it does in one breath, and that the speech is sent.
    public static let inline = "勾选后，用本地识别说话时声音也会发给阿里云；松手后它几秒内给出完整结果就用它，否则用本地的。"

    /// The popover behind the "？": one short paragraph each.
    public static let helpParagraphs: [String] = [
        "本地识别照常实时出字。开启后，同一段声音也会发给阿里云（华北2 北京）识别。",
        "松手后，阿里云如果几秒内给出完整结果，就用它作为这次的文字（和本地一样套用个人词库），否则用本地的。上推发送也要等这一步定下来，所以最多多等约 2 秒。",
        "可能改善部分识别结果，不保证每句都更准。阿里云用不了（没网、Key 失效、额度用完）或出错时，只用本地的结果。",
        "推荐在百炼控制台为这个模型打开「免费额度用完即停」；应用查不到它开没开，未勾确认也能识别。应用不保证不产生费用。"
    ]

    /// The detail line of the "本地识别" card while nothing is sent: what it always said.
    public static let plainLocalCardDetail = "在这台 Mac 上识别，声音不上传。"

    /// The detail line of the "本地识别" card. The plain line promises that the speech is not uploaded, so it may
    /// only stand while nothing is sent: a ticked box (`enhanceActive`: the row offers it ticked) with a valid
    /// confirmation says that the speech also goes to Aliyun, and a ticked box that cannot send yet says that the
    /// speech is not uploaded for now.
    public static func localCardDetail(enhanceActive: Bool, status: CloudEntryStatus,
                                       provider: OnlineAPIProvider? = nil) -> String {
        guard enhanceActive else { return plainLocalCardDetail }
        let name = provider.map(OnlineAPIStrings.providerName) ?? "阿里云"
        return provider?.isAliyun == false || status.isUsable
            ? "本地识别，已开增强，声音也发给\(name)。" : "在这台 Mac 上识别，声音暂时不上传。"
    }

    public static let offNote = "已关闭，声音不再发给阿里云。"
    /// Appended to the message of a change of recognition method (or language) that closed the enhancement.
    public static let closedByChange = "「用于增强本地识别」已关闭，声音不再发给阿里云。"
    /// Appended when choosing the Aliyun route closed the enhancement: the speech now goes to Aliyun as the route, so
    /// this line must not say that it stops going there.
    public static let closedByRoute = "「用于增强本地识别」已关闭；回到本地识别后要用，再勾一次。"
    /// Said when the Key is removed while the enhancement was on.
    public static let closedByKeyRemoval = "「用于增强本地识别」也已关闭。"
    public static let statusUnreadable = "阿里云的状态读不到，暂时不能开启（重启 VoicePointer 后再试）。"
    public static let entryUnusable = "阿里云现在用不了，没有开启。"
    /// The sheet was closed while the confirmation was being saved: only the confirmation was kept.
    public static let confirmKeptNotEnabled = "已记下你的确认，没有开启。再勾一次「用于增强本地识别」。"
    /// The sheet was closed while the confirmation was being saved and the box was already ticked (the row's own
    /// button, after a new key or an expired confirmation): the kept confirmation makes it work again.
    public static let confirmKeptAlreadyOn = "已记下你的确认。「用于增强本地识别」开着，下次开始说话时声音会发给阿里云。"
    /// Said whether or not the box was ticked: without a saved confirmation nothing is sent either way.
    public static let confirmFailed = "没能保存确认，声音不会发给阿里云。请稍后再试；反复失败的话，重启 VoicePointer 后再试。"

    /// Why ticking the box cannot do anything now (nil: nothing stands in the way). The same guards run when the
    /// sheet's confirmation comes back, since the selection or the key can change while it is open.
    public static func refusal(selection: VoiceInputSelection, keySaved: Bool, removing: Bool,
                                provider: OnlineAPIProvider = .aliyunBailian) -> String? {
        if !keySaved || removing {
            return provider.isAliyun ? entryUnusable : "\(OnlineAPIStrings.providerName(provider))现在用不了，没有开启。"
        }
        return CloudEnhanceBlocker(selection: selection, provider: provider)?.hint
    }

    /// What ticking the box does: refuse, ask for the confirmation the gate's state calls for, or switch on.
    public static func tick(
        selection: VoiceInputSelection, keySaved: Bool, removing: Bool, status: CloudEntryStatus,
        provider: OnlineAPIProvider = .aliyunBailian
    ) -> CloudEnhanceTick {
        if let reason = refusal(selection: selection, keySaved: keySaved, removing: removing, provider: provider) {
            return .refuse(reason)
        }
        guard provider.isAliyun else { return .enable }
        switch status.enableStep {
        case .switchNow: return .enable
        case .confirm(let kind): return .confirm(kind)
        case .blocked: return .refuse(statusUnreadable)
        }
    }
    public static func uploadConsentDetail(provider: OnlineAPIProvider) -> String {
        let name = OnlineAPIStrings.providerName(provider)
        return "开启后，用本地识别时，同一段声音也会发给\(name)，用于纠正结果和在本地学词。没同意就不会上传。"
    }
    public static func detail(provider: OnlineAPIProvider) -> String {
        "用\(OnlineAPIStrings.providerName(provider))的结果纠正本地识别，并在本地学词；只记词，不存整句。"
    }
    public static func help(provider: OnlineAPIProvider) -> String {
        "只在本地千问识别时生效。开启后，同一段声音也会发给\(OnlineAPIStrings.providerName(provider))；没同意就不会上传。松手后及时结果可用于纠正，晚到结果只在本地学词。"
    }
    public static func offNote(provider: OnlineAPIProvider) -> String {
        "已关闭，声音不再发给\(OnlineAPIStrings.providerName(provider))。"
    }
    public static func footer(status: CloudEntryStatus, provider: OnlineAPIProvider) -> String {
        guard provider.isAliyun else { return "本地识别；声音也会发给\(OnlineAPIStrings.providerName(provider))" }
        return status.enhanceFooterText.replacingOccurrences(of: "阿里云", with: OnlineAPIStrings.providerName(provider))
    }
}

// MARK: - The confirmation sheet, by purpose

extension CloudConfirmationKind {
    /// The sheet's title. The route keeps the words it always had; the enhancement asks about itself.
    public func title(for purpose: CloudEntryPurpose) -> String {
        switch (purpose, self) {
        case (.route, _): return title
        case (.enhanceLocal, .first): return "开启「用于增强本地识别」"
        case (.enhanceLocal, _): return title
        }
    }

    /// The sheet's one button.
    public func confirmTitle(for purpose: CloudEntryPurpose) -> String {
        switch (purpose, self) {
        case (.route, _): return confirmTitle
        case (.enhanceLocal, .first): return "我已开启，启用增强"
        case (.enhanceLocal, _): return confirmTitle
        }
    }

    /// The first paragraph of the sheet. Every wording says that the speech goes to Aliyun; the enhancement's
    /// says that the local result is what is used whenever Aliyun is not (in time), and that nothing is switched
    /// to Aliyun itself.
    public func lead(for purpose: CloudEntryPurpose) -> String {
        switch purpose {
        case .route:
            return lead
        case .enhanceLocal:
            switch self {
            case .first:
                return "开启后，用本地识别说话时，同一段声音也会发给阿里云。本地照常先出字；松手后，阿里云几秒内给出完整结果就用它，否则用本地的。阿里云用不了（没网、Key 失效、额度用完、没确认）时，只用本地的结果。可能改善部分结果，不保证每句都更准。"
            case .renew:
                return "免费额度用完即停是推荐设置，已有确认不会到期。开启增强后，用本地识别说话时同一段声音也会发给阿里云。"
            case .resume(.freeQuotaExhausted):
                return "阿里云因为免费额度用完暂停了，暂停期间不会向阿里云发声音，听写只用本地识别。处理额度问题后可以恢复；恢复后，用本地识别说话时声音又会同时发给阿里云。"
            case .resume(.accountBalanceBlocked):
                return "阿里云因为账户欠费或余额不足暂停了，暂停期间不会向阿里云发声音，听写只用本地识别。请先到阿里云控制台处理账户；之后可以恢复，恢复后用本地识别说话时声音又会同时发给阿里云。"
            }
        }
    }
}
