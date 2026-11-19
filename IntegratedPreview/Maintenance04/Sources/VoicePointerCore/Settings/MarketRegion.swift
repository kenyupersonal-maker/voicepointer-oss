import Foundation

public enum MarketRegion: String, Sendable { case cn, intl
    public static var current: Self {
        detect(region: Locale.current.region?.identifier, timeZone: TimeZone.current.identifier,
               preferredLanguages: Locale.preferredLanguages)
    }

    /// Local hints only. Provider detection never uses this market preference.
    public static func detect(region: String?, timeZone: String, preferredLanguages: [String]) -> Self {
        if region?.uppercased() == "CN" { return .cn }
        let zones: Set<String> = ["Asia/Shanghai", "Asia/Chongqing", "Asia/Harbin", "Asia/Urumqi"]
        let language = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-").lowercased() ?? ""
        let simplified = language == "zh-hans" || language.hasPrefix("zh-hans-")
            || language == "zh-cn" || language == "zh-sg"
        return zones.contains(timeZone) && simplified ? .cn : .intl
    }

    public var guideProviders: [OnlineAPIProvider] {
        self == .cn ? [.aliyunBailian, .groq, .aliyunIntl] : [.aliyunIntl, .groq, .aliyunBailian]
    }
}
