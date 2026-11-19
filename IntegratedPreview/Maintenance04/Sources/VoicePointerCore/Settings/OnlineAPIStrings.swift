import Foundation

/// All NEW 0.5.55 user-facing text lives here; phase B/C/D adds form/guide/pane text here only.
public enum OnlineAPIStrings {
    public static let hudOpenSettings = "去设置"
    public static let deleteFailed = "未能删除 Key，请重试。"
    public static func onlineMenuTitle(_ provider: OnlineAPIProvider?) -> String {
        provider.map { "在线 API 识别（\(providerName($0))）" } ?? "在线 API 识别"
    }
    public static func onlineMenuSuffix(_ status: OnlineRouteMenuState.StatusKind) -> String {
        switch status {
        case .passed: " · 可用"
        case .reading, .updating, .checking, .unverified: ""
        case .needsConfiguration: " · 未配置"
        case .expired: " · 不可用 · 确认已过期"
        case .needsConfirmation: " · 不可用 · 需要确认"
        case .quotaExhausted: " · 不可用 · 免费额度已用完"
        case .balanceBlocked: " · 不可用 · 账户欠费或余额不足"
        case .network: " · 不可用 · 连不上服务商"
        case .timeout: " · 不可用 · 检查超时"
        case .invalidKey: " · 不可用 · Key 无效或不可用"
        case .unavailable: " · 不可用 · 状态不可用"
        case .failed: " · 不可用 · 检查失败"
        }
    }
    public static func hud(provider: OnlineAPIProvider, code: String) -> String {
        let name = providerName(provider)
        if code.hasSuffix("AUTH_FAILED") || code.hasSuffix("HTTP_401") { return "\(name)不认这个 Key，请到「设置 → 语音输入 → 在线 API」重新配置。" }
        if code.hasSuffix("INSUFFICIENT_QUOTA") { return "OpenAI 账户额度不足，请充值后再试，或更换识别方式。" }
        if code.hasSuffix("FREE_QUOTA_EXHAUSTED") { return "\(name)的免费额度已用完，请换一个模型或识别方式。" }
        if code.hasSuffix("BALANCE_DUE") { return "\(name)账户欠费，请充值或更换 Key。" }
        if code.hasSuffix("TIMEOUT") || code.hasSuffix("NETWORK_FAILED") || code.hasSuffix("REQUEST_FAILED") { return "连不上\(name)，请检查网络或代理。" }
        if code.contains("CREDENTIAL") { return "请到「设置 → 语音输入 → 在线 API」重新填写\(name) Key。" }
        return "\(name)识别未能完成，请重试或到在线 API 设置检查。"
    }
    public static let title = "配置在线识别"
    public static let subtitle = "粘贴 API Key，自动认出服务商和能用的语音模型。"
    public static let enhanceTitle = "开启云端增强"
    public static let enhanceSubtitle = "本地先出字，再由当前在线服务商校对。需要配置 API Key。"
    public static let permissionStep = "权限"
    public static let chooseStep = "选择方式"
    public static let finishStep = "完成配置"
    public static let keyLabel = "API Key"
    public static let keyPlaceholder = "粘贴 API Key"
    public static let paste = "粘贴"
    public static let showKey = "显示 API Key"
    public static let hideKey = "隐藏 API Key"
    public static let provider = "服务商"
    public static let model = "模型"
    public static let quota = "免费额度"
    public static let note = "说明"
    public static let change = "更改"
    public static let how = "怎么打开 ↗"
    public static let endpoint = "服务地址：自动"
    public static let advanced = "高级"
    public static let endpointPlaceholder = "自动"
    public static let groqNote = "免费层有速率限制；如果你在 Groq 开了付费，会按量计费。"
    public static let openaiNote = "OpenAI 按用量计费，没有免费额度。"
    public static let siliconflowNote = "停止说话后上传识别；费用和可用额度以 SiliconFlow 控制台为准。"
    public static func providerNote(_ provider: OnlineAPIProvider) -> String {
        provider == .groq ? groqNote : provider == .siliconflow ? siliconflowNote : openaiNote
    }
    public static let noKeyTitle = "还没有 API Key？"
    public static let free = "免费"
    public static let noKeyCN = "用支付宝扫码登录阿里云，3 分钟创建一个；新用户有 90 天免费额度。"
    public static let noKeyIntl = "几分钟免费创建一个，用 Google 或邮箱登录就行。"
    public static let later = "稍后"
    public static let otherMethod = "换一种方式"
    public static let cancel = "取消"
    public static let done = "完成"
    public static let completionUnavailable = "配置暂时无法完成，请稍后再试。"
    public static let completionFailed = "配置没有完成，请重试。"
    public static let quotaTip = "在免费额度页右上角点「批量设置 → 批量开启」，所有模型一次打开。"
    public static let guideTitle = "免费创建一个 API Key"
    public static let guideAliSubtitle = "跟着做 3 步，大约 3 分钟；新用户有 90 天免费额度。"
    public static let guideGroqSubtitle = "跟着做 3 步，大约 2 分钟。"
    public static let haveKey = "我已经有 Key 了"
    public static let pasteCopied = "粘贴刚复制的 Key"
    public static let clipboardNoKey = "剪贴板里没有 Key，先点 Key 旁边的复制图标。"
    public static let openAIKeyLink = "已有 OpenAI 账号？去创建 Key ↗"
    public static let panelTitle = "在线 API"
    public static let panelAvailable = "可用"
    public static let panelAttention = "需处理"
    public static let replace = "更换"
    public static let delete = "删除"
    public static let replaceKey = "更换 Key"
    public static let changeModel = "换模型"
    public static let confirm = "确认"
    public static let panelEmptyTitle = "还没有配置在线识别"
    public static let panelEmptyDetail = "粘贴 API Key 就能用；没有的话几分钟免费创建一个。"
    public static let freeCreate = "免费创建"
    public static let configure = "配置…"
    public static let keyRejectedTitle = "Key 用不了了"
    public static let quotaExhaustedTitle = "免费额度用完了"
    public static let quotaExpiredTitle = "免费额度确认到期了"
    public static let quotaExhaustedDetail = "当前模型的免费额度已经用完，换一个模型继续。"
    public static let panelModelUnavailable = "这个模型还没开通，请换一个模型。"
    public static let reconfirmTitle = "确认一下"
    public static let reconfirmLook = "去看看 ↗"
    public static let reconfirmYes = "还开着"
    public static let reconfirmOff = "关掉在线识别"
    public static let modelCheckUnavailable = "暂时无法更换模型，请稍后再试。"
    public static let modelSaveFailed = "模型没有更换成功，请重试。"
    public static let modelSelectionCancelled = "没换成，请再选一次。"
    public static let modelChecking = "正在检查…"
    public static func modelChoice(_ id: String, recommended: Bool) -> String {
        modelName(id) + (recommended ? " · 推荐" : "") + (modelDetail(id).map { " — " + $0 } ?? "")
    }
    public static func modelQuotaConfirmation(_ id: String) -> String {
        "换成 \(modelName(id)) 前，请先在阿里云免费额度页，把 \(modelName(id)) 的『免费额度用完即停』打开。"
    }
    public static let reconfirmFailed = "这次操作没有完成，请重试。"
    public static func quotaExpiredDetail(_ provider: OnlineAPIProvider) -> String {
        "确认一下「\(provider == .aliyunIntl ? quotaOnlyIntl : "用完即停")」还开着。"
    }
    public static func panelModelProblem(_ value: OnlineAPIProblem) -> String {
        if case .connection(let failure) = value.cause, failure == .noAccess || failure == .modelUnavailable {
            return panelModelUnavailable
        }
        return problem(value)
    }
    public static func keyRejectedDetail(_ provider: OnlineAPIProvider) -> String {
        "\(uploadName(provider))不认这个 Key，可能已经重新生成过。"
    }
    public static func reconfirmText(_ provider: OnlineAPIProvider) -> String {
        "上次确认「\(provider == .aliyunIntl ? quotaOnlyIntl : quotaOnlyCN)」已经过了 30 天。它还开着吗？"
    }
    public static func confirmedQuota(_ provider: OnlineAPIProvider, until: Date) -> String {
        let name = provider == .aliyunIntl ? quotaOnlyIntl : "用完即停"
        return "「\(name)」已确认"
    }
    public static func guideProvider(_ provider: OnlineAPIProvider) -> String {
        switch provider {
        case .aliyunBailian: "阿里云 · 中国大陆"
        case .aliyunIntl: "阿里云 · 国际"
        case .groq: "Groq"
        case .openai: "OpenAI"
        case .siliconflow: "SiliconFlow"
        }
    }
    public struct GuideStep: Sendable {
        public let title: String
        public let detail: String
        public let button: String?
        public let via: String?
        public init(_ title: String, _ detail: String, _ button: String? = nil, _ via: String? = nil) {
            self.title = title; self.detail = detail; self.button = button; self.via = via
        }
    }
    public static func guideSteps(_ provider: OnlineAPIProvider) -> [GuideStep] {
        switch provider {
        case .aliyunBailian:
            [.init("打开阿里云百炼，扫码登录", "支付宝、阿里云 App 或钉钉扫码；新用户按提示注册。", "打开阿里云百炼 ↗", "支付宝 / 钉钉 扫码"),
             .init("点右上角「创建 API Key」，再点「确定」", "归属账号、业务空间保持默认，权限选「全部」。"),
             .init("点新 Key 旁边的复制图标，回到这里", "创建后马上复制；以后再看明文需要重新生成。")]
        case .aliyunIntl:
            [.init("打开阿里云国际站，登录", "邮箱、Google 或 GitHub 都行；补全资料后才发免费额度。", "打开阿里云国际站 ↗", "邮箱 / Google / GitHub"),
             .init("点右上角「Create API Key」，再点「OK」", "页面是英文的，按这两个按钮名找。"),
             .init("点新 Key 旁边的复制图标，回到这里", "创建后马上复制。")]
        case .groq:
            [.init("打开 Groq 控制台，登录", "Google、GitHub 或邮箱都行；免费层不用绑卡。", "打开 Groq 控制台 ↗", "Google / GitHub / 邮箱"),
             .init("点「Create API Key」，起个名，点「Submit」", "名字随便填。"),
             .init("马上复制 Key，回到这里", "Groq 只显示一次，关掉就看不到了。")]
        case .openai: []
        case .siliconflow:
            [.init("打开 SiliconFlow 控制台，登录", "按控制台提示完成注册或登录。", "打开 SiliconFlow 控制台 ↗"),
             .init("创建 API Key", "确认当前账号的模型和额度可用。"),
             .init("复制 Key，回到这里", "在服务商中选择 SiliconFlow，再验证。")]
        }
    }
    public static func quotaLabel(_ provider: OnlineAPIProvider) -> String {
        "我已打开「\(provider == .aliyunIntl ? quotaOnlyIntl : quotaOnlyCN)」"
    }
    public static func upload(_ provider: OnlineAPIProvider) -> String {
        "开启后，说话的声音会上传到 \(uploadName(provider)) 识别。"
    }
    public static let checking = "正在识别…"
    public static let finishingValidation = "验证中…"
    public static let recommended = "推荐"
    public static let keyWhitespace = "Key 里有空格，请重新复制。"
    public static let unrecognized = "认不出这个 Key 是哪家的。支持的服务商：阿里云百炼、阿里云国际站、Groq、OpenAI、SiliconFlow。"
    public static let aliRejectedKey = "这个 Key 用不了，可能已经重新生成过。"
    public static let modelSwitched = "这个模型还没开通，已换成下一个可用的。"
    public static let enhanceUnsupported = "当前配置无法用于增强本地识别"
    public static let quotaOnlyCN = "免费额度用完即停"
    public static let quotaOnlyIntl = "Free Quota Only"

    public static func problem(_ problem: OnlineAPIProblem) -> String {
        let provider = problem.provider ?? .aliyunBailian
        switch problem.cause {
        case .keyWhitespace: return keyWhitespace
        case .unrecognized: return unrecognized
        case .invalidEndpoint: return "这个服务地址不能用，请检查后再试。"
        case .noModels:
            return provider.isAliyun ? "这个 Key 没有可用的语音识别模型，" : "这个 Key 没有可用的语音识别模型。"
        case .insufficientQuota: return "OpenAI 账户额度不足，请到 OpenAI 充值后再试。"
        case .cancelled: return ""
        case .connection(let failure):
            switch failure {
            case .rejectedKey:
                switch provider {
                case .aliyunBailian, .aliyunIntl: return aliRejectedKey
                case .groq: return "Groq 不认这个 Key，请到 Groq 控制台重新复制。"
                case .openai: return "OpenAI 不认这个 Key，请到 OpenAI 控制台重新复制。"
                case .siliconflow: return "SiliconFlow 不认这个 Key，请到 SiliconFlow 控制台重新复制。"
                }
            case .freeQuotaExhausted:
                return "这个模型的免费额度已经用完（用完即停已生效）。换一个模型，或到阿里云开通按量付费。"
            case .balanceDue: return "阿里云账户欠费，先去充值，或换一个账号的 Key。"
            case .network, .timeout: return "连不上\(uploadName(provider))，检查网络或代理。"
            case .noAccess, .modelUnavailable: return modelSwitched
            case .rateLimited: return "请求太频繁，请稍后重试。"
            case .serviceUnavailable: return "识别服务暂时不可用，请稍后重试。"
            case .noKey, .keyUnreadable: return "请重新粘贴 API Key。"
            case .worker, .notClosed, .taskStartFailed, .unknown: return "验证暂时没有完成，请重试。"
            }
        }
    }

    public static func action(_ action: OnlineAPIProblem.Action) -> String {
        switch action {
        case .guide, .keyPage: "去重新复制 ↗"
        case .modelGallery: "去阿里云开通 ↗"
        case .retry: "重试"
        case .billing: "去充值 ↗"
        }
    }

    public static func providerName(_ provider: OnlineAPIProvider) -> String {
        switch provider {
        case .aliyunBailian: "阿里云百炼"
        case .aliyunIntl: "阿里云国际站"
        case .groq: "Groq"
        case .openai: "OpenAI"
        case .siliconflow: "SiliconFlow"
        }
    }
    public static func uploadName(_ provider: OnlineAPIProvider) -> String {
        provider.isAliyun ? "阿里云" : providerName(provider)
    }
    public static func success(_ provider: OnlineAPIProvider) -> String {
        "认出来了：\(providerName(provider))，Key 可用"
    }
    public static func support(_ region: MarketRegion) -> String {
        region == .cn ? "支持：阿里云、Groq、OpenAI、SiliconFlow" : "支持：Groq、OpenAI、阿里云、SiliconFlow"
    }
    public static func modelName(_ id: String) -> String {
        switch id {
        case "qwen-audio-3.1-asr-flash-streaming": "千问 3.1 实时识别"
        case "qwen-audio-3.0-asr-flash-streaming": "千问 3.0 实时识别"
        case "fun-asr-realtime": "Fun-ASR 实时识别"
        case "fun-asr-realtime-2026-02-28": "Fun-ASR 实时识别 · 2026-02-28"
        case "paraformer-realtime-v2": "Paraformer 实时识别 v2"
        case "paraformer-realtime-v1": "Paraformer 实时识别 v1"
        case "whisper-large-v3-turbo": "Whisper Large v3 Turbo"
        case "whisper-large-v3": "Whisper Large v3"
        case "gpt-transcribe": "GPT Transcribe"
        case "gpt-4o-mini-transcribe": "GPT-4o mini Transcribe"
        case "gpt-4o-transcribe": "GPT-4o Transcribe"
        case "whisper-1": "Whisper 1"
        case "FunAudioLLM/SenseVoiceSmall": "SenseVoice Small"
        case "TeleAI/TeleSpeechASR": "TeleSpeech ASR"
        default: ""
        }
    }
    public static func modelDetail(_ id: String) -> String? {
        switch id {
        case "qwen-audio-3.1-asr-flash-streaming": "最新，方言和多语种更好"
        case "qwen-audio-3.0-asr-flash-streaming": "上一代，稳定"
        case "fun-asr-realtime": "反应快"
        case "fun-asr-realtime-2026-02-28": "固定版本"
        case "paraformer-realtime-v2", "paraformer-realtime-v1": "实时识别"
        case "whisper-large-v3-turbo": "快"
        case "whisper-large-v3": "更准一点，稍慢"
        case "gpt-4o-mini-transcribe": "更便宜"
        default: nil
        }
    }
}
