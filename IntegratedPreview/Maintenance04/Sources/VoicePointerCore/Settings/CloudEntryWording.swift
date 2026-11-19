import Foundation

// The settings' words for the Aliyun cloud route, and what choosing it has to do first.
//
// Pure Foundation, so the self-tests run it. Nothing here decides whether a dictation goes to the cloud: that
// stays with `CloudAdmissionGate`. It only turns the gate's persisted state (as `CloudEntryStatus`) and a few
// facts about the settings into the short lines the recognition-method card, its details and the sidebar
// show, into the one question the person is asked before the route is switched on, and into the note shown
// right after it was switched.
//
// What the words may promise follows what the dictation path really does. A dictation the gate denies when it
// starts (nothing confirmed, confirmation expired, quota paused) runs on the local route instead, and fails
// when that local route is not ready either, so "现在用本地识别" is only said while it is. Once a cloud dictation is
// under way, no network, a rejected key, a lost connection or a used-up quota fails that one dictation: there
// is no switch to the local route in mid-sentence, so no line here says "automatically local" about anything
// but the start.

/// One short line for the settings and how to colour it.
public struct CloudEntrySummary: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case ready, attention, neutral }

    public let text: String
    public let tone: Tone

    public init(_ text: String, _ tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

/// Lines that do not follow from the gate's state alone.
public enum CloudEntryLine {
    /// Before the first read of the entry has come back: neither "on" nor "off" is known yet.
    public static let loading = "正在读取阿里云的状态…"
    /// The Aliyun route is chosen but cannot take the next dictation, and the local route it would fall back to
    /// is not ready either, so that dictation fails.
    public static let nothingReady = "云端用不了，本地也没准备好"
    /// Saving failed on the way into or out of the Aliyun route. Its switches are off afterwards either way (a
    /// failed switch-on closes them again, a switch-off closes them before saving), so nothing is restored.
    public static let saveFailedCloudOff = "保存失败；阿里云已停用。"
}

/// How the Aliyun route was just switched on, which decides the note under the recognition-method cards.
public enum CloudRouteSwitch: Sendable, Equatable, CaseIterable {
    /// A valid confirmation was on record: choosing the card switched at once.
    case direct
    /// Confirmed in the sheet, the first time or again after 30 days.
    case confirmed
    /// Rechecked and resumed in the sheet after a pause.
    case resumed

    /// Where the speech goes from the next dictation on, and what fails a dictation that is under way. The gate
    /// lets a dictation start without knowing about the network or the key, so the note promises no switch to
    /// the local route.
    public var note: String {
        switch self {
        case .direct: "在线识别已选用，下次开始说话时生效，声音会发给阿里云。\(Self.failureClause)"
        case .confirmed: "已确认，并切换到阿里云识别，下次开始说话时生效，声音会发给阿里云。\(Self.failureClause)"
        case .resumed: "已记下你的确认并恢复，下次开始说话时用阿里云识别，声音会发给阿里云。\(Self.failureClause)"
        }
    }

    private static let failureClause = "没网、Key 失效、说到一半断线或额度用完，这次听写会失败。"
}

/// Why the confirmation sheet is shown, which decides its title and its words.
public enum CloudConfirmationKind: Sendable, Equatable {
    /// Nothing is on record for this key yet.
    case first
    /// A confirmation is on record but it is older than its lifetime.
    case renew
    /// The route was paused: the free quota is used up, or the account has no balance.
    case resume(CloudAdmissionPauseReason)

    public var title: String {
        switch self {
        case .first: "启用阿里云识别"
        case .renew: "重新确认「免费额度用完即停」"
        case .resume: "重新检查并恢复"
        }
    }

    /// The sheet's one button that does it all: confirm, allow the upload, switch.
    public var confirmTitle: String {
        switch self {
        case .first: "我已开启，启用"
        case .renew: "我已开启，确认"
        case .resume: "确认并恢复"
        }
    }

    /// The button that opens the sheet again from the details row.
    public var rowButtonTitle: String {
        switch self {
        case .first: "确认…"
        case .renew: "重新确认"
        case .resume: "重新检查并恢复"
        }
    }

    /// The first paragraph of the sheet. Every kind says that the speech goes to Aliyun, because the button
    /// switches the route on.
    public var lead: String {
        switch self {
        case .first:
            "选用后，你说的话会发给阿里云识别。开始说话时阿里云用不了（额度暂停），这次改用本地识别；没网、Key 失效、说到一半断线或额度用完，这次听写会失败。"
        case .renew:
            "免费额度用完即停是推荐设置；已有确认不会到期，也不影响在线识别。启用后声音会发给阿里云。"
        case .resume(.freeQuotaExhausted):
            "阿里云识别因为免费额度用完暂停了，暂停期间不会向阿里云发声音。处理额度问题后可以恢复；恢复后会切到阿里云，你说的话会发给阿里云识别。"
        case .resume(.accountBalanceBlocked):
            "阿里云识别因为账户欠费或余额不足暂停了，暂停期间不会向阿里云发声音。请先到阿里云控制台处理账户；之后可以恢复，恢复后会切到阿里云，你说的话会发给阿里云识别。"
        }
    }
}

/// What has to happen before the cloud route can be switched on, from the gate's persisted state alone.
public enum CloudEnableStep: Sendable, Equatable {
    /// A confirmation is on record and still valid: choosing the route switches at once.
    case switchNow
    /// The person confirms first, in the sheet worded for the kind.
    case confirm(CloudConfirmationKind)
    /// The state cannot be read: nothing is switched on (the gate fails closed as well).
    case blocked
}

extension CloudEntryStatus {
    public var enableStep: CloudEnableStep {
        switch self {
        case .confirmed: .switchNow
        case .unconfirmed, .expired: .switchNow
        case .paused(let reason): .confirm(.resume(reason))
        case .unavailable: .blocked
        }
    }

    /// "10月31日 14:00": when a confirmation runs out, to the minute on a 24-hour clock. A confirmation lasts 30
    /// days from the moment it was given, so a day alone reads up to a day off either way. The POSIX locale keeps
    /// the system's 12-hour or regional formats out of it; the time zone is the caller's.
    public static func validUntilText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// The line on the cloud card among the recognition methods. `selected`: the cloud route is the saved
    /// choice; `switchesOn`: its switches (route and upload) are on as well. Only both together mean "in use";
    /// every other selected case says plainly that the dictation runs on this Mac, or, when the local route it
    /// would fall back to (`localFallbackReady`) is not ready, that nothing can take it. "有效至" is when the
    /// person's own confirmation runs out: the app protects nothing, it only remembers what the person said.
    public func cardSummary(
        selected: Bool, switchesOn: Bool, localFallbackReady: Bool, timeZone: TimeZone = .current
    ) -> CloudEntrySummary {
        if selected, !(isUsable && switchesOn), !localFallbackReady {
            return CloudEntrySummary(CloudEntryLine.nothingReady, .attention)
        }
        switch self {
        case .unavailable:
            return CloudEntrySummary(selected ? "状态读不到，现在用本地识别" : "状态读不到，暂不能选", .attention)
        case .unconfirmed, .expired:
            if selected {
                return switchesOn ? CloudEntrySummary("使用中", .ready)
                    : CloudEntrySummary("现在用本地识别 · 点一下启用", .attention)
            }
            return CloudEntrySummary("点一下启用", .neutral)
        case .paused(let reason):
            let why = reason == .freeQuotaExhausted ? "免费额度用完" : "账户欠费"
            return selected
                ? CloudEntrySummary("\(why)，现在用本地识别", .attention)
                : CloudEntrySummary("已暂停 · \(why)", .attention)
        case .confirmed:
            if selected {
                return switchesOn
                    ? CloudEntrySummary("使用中", .ready)
                    : CloudEntrySummary("现在用本地识别 · 点一下启用", .attention)
            }
            return CloudEntrySummary("可切换", .neutral)
        }
    }

    /// The "用完即停确认" line of the cloud details.
    public func protectionSummary(timeZone: TimeZone = .current) -> CloudEntrySummary {
        CloudEntrySummary(title(timeZone: timeZone), .neutral)
    }

    /// The line at the foot of the sidebar while the cloud route is the saved choice and the entry is usable.
    /// "现在用本地识别" only while the local route a denied dictation falls back to is ready.
    public func footerText(switchesOn: Bool, localFallbackReady: Bool) -> String {
        if !(isUsable && switchesOn), !localFallbackReady { return CloudEntryLine.nothingReady }
        switch self {
        case .confirmed, .unconfirmed, .expired: return switchesOn ? "阿里云识别，声音会上传" : "阿里云还没启用，现在用本地识别"
        case .paused(.freeQuotaExhausted): return "阿里云免费额度用完，现在用本地识别"
        case .paused(.accountBalanceBlocked): return "阿里云账户欠费，现在用本地识别"
        case .unavailable: return "阿里云状态读不到，现在用本地识别"
        }
    }
}
