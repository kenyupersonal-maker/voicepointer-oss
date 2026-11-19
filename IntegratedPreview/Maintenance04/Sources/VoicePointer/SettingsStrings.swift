// T5 2026-10-02: Settings presentation copy. State contracts stay in VoicePointerCore.
// T6 2026-10-02: Separate total lexicon size from its approximate per-dictation hint count.
import Foundation
import VoicePointerCore

enum SettingsStrings {
    static let omitTerminalPeriod = "句末不加句号"
    static let gestureOutputSection = "输入的文字"
    static let hapticTapToFeel = "点一下档位，触控板就按这一档震给你感受"
    static let omitTerminalPeriodDoubaoHint = "用豆包输入时，字是豆包自己写进去的，这一项管不到。要去掉句末句号，请在豆包输入法设置里把语音标点改成「句末不加标点」。"
    static let tipPageTitle = "打赏"
    static let recentContextToggle = "参考最近说过的话"
    static let recentContextHelp = "同一个应用最近 10 分钟的三句听写和词库会帮助本地识别选择同音词。近期文字只留内存，退出咻就清空。"
    static let recentContextClear = "清除"
    static func recentContextCount(_ count: Int) -> String { "当前记着 \(count) 句" }
    static let inlineRecoveryTitle = "松手后一次贴入的应用"
    static let inlineRecoveryTemporary = "重启咻、重启这个应用或 24 小时后自动恢复边说边写"
    static let inlineRecoveryStrong = "检测到贴入或发送后文字没有变化"
    static let inlineRecoveryAction = "恢复"
    static let inlineRecoveryNotice = "这个应用改成松手后一次贴入"
    static let quotaRecommended = "推荐打开，免得超出免费额度后扣费。"
    static let autoLearnedDisabledNotice = "自动学习的词条已停用，不会再改字。"
    static let outputDuckingSection = "说话时"
    static let outputDuckingToggle = "压低其他声音"
    static let outputDuckingMute = "静音"
    static let outputDuckingAccessibilityLabel = "压低其他声音的比例"
    static let outputDuckingHelp = "按住说话时，电脑正在播放的声音降到这个比例，松手恢复。"
    static func outputDuckingRatio(_ ratio: Double) -> String {
        "压低到原来的\(Int((ratio * 100).rounded()))%"
    }
    static let justLearnedTitle = "刚学会"
    static let justLearnedUndo = "撤销"
    static let learnedHotwordSuffix = "（作为热词）"
    static let connectionVerifying = "正在测试阿里云连接…"
    static let connectionNotVerified = "连接尚未确认，请重新测试。"
    static let replaceRejectedSavedKey = "换成新 Key"
    static let replaceSavedKeyAndVerify = "换成新 Key 并验证"
    static let replaceSavedKeyTitle = "替换 Key 并更新确认"
    static let replaceSavedKeyDescription = "保存并验证新 Key 后更新确认，不另外开启上传或增强。"
    static let replacedSavedKeyConfirmed = "新 Key 已保存，30 天确认已更新；没有另外开启上传或增强。"
    static let connectionValidationCancelled = "连接测试已取消。"
    static let savedKeyNotReadyForRenewal = "已保存的 Key 状态尚未就绪，请稍后再确认；当前配置未改变。"
    static let savedKeyUnreadableAttention = "本机凭据读不出来，请重新配置。"
    static let savedKeyRejectedAttention = "Key 无效或已过期，云端增强暂时没有生效。"
    static let onboardingDoubaoNeedsInstall = "需先安装豆包输入法"
    static let onboardingLocalRouteDetail = "不联网　需下载模型"
    static let onboardingOnlineRouteDetail = "需要 Key　声音会上传"
    static let onboardingConfiguredTitle = "配置成功，可以开始使用"
    static let onboardingPracticeGestureDetail = "跟着演示试一次。手势可在「设置 → 手势与输入」里调整。"
    static let onboardingLargerModelDetail = "识别更准，推荐使用。"
    static let onboardingSmallerModelDetail = "更省内存，适合配置较低的 Mac。"
    static let onboardingModelReadyDetail = "已就绪，可直接使用。"
    static let onboardingModelPreparationDetail = "模型准备好后，识别不再需要联网。"
    static let onboardingChangeModel = "换一个模型"
    static let onboardingPermissionDetail = "授权只在这台 Mac 上使用。这里不会主动打开麦克风。"
    static let onboardingAccessibilityDetail = "把文字写进你正在用的输入框"
    static let onboardingGesturePermissionDetail = "识别触控板与鼠标手势"
    static let onboardingMicrophonePermissionDetail = "听你说话"
    static let onboardingDoubaoDetected = "已检测到豆包输入法。"
    static let onboardingEnableInSettings = "在系统设置里启用"
    static let onboardingDoubaoEnabled = "已检测到豆包输入法已启用。"
    static let onboardingDoubaoEnableDetail = "打开「系统设置 → 键盘 → 输入法」，勾选豆包输入法。"
    static let onboardingDownloadDoubao = "下载豆包输入法"
    static let microphoneTitle = "麦克风"
    static let microphoneAutomatic = "自动"
    static let microphoneSystem = "跟随系统"
    static let microphoneMissing = "选定设备暂不可用"
    static let microphoneAutomaticDetail = "自动：系统默认是蓝牙耳机（如 AirPods）时，改用这台 Mac 自带的麦克风。蓝牙耳机的麦克风可能收不到声音，被打开时耳机还会切到通话模式，正在听的声音会变差。其他情况跟随系统设置。"
    static let magicMouseTuning = "妙控鼠标手感"
    static let magicMouseFeel = "手感"
    static let magicMouseRecordSection = "触点记录"
    static let magicMouseLegend = "长虚线：同时落下 · 短虚线：先后落下"
    static let magicMouseAbsent = "连接妙控鼠标后，可在这里调校双指按下。"
    static let magicMouseDensity = "密度阈值"
    static let magicMouseDensityDetail = "同时落指可轻按；先后落指需压实。均衡适合日常使用。"
    static let magicMouseMore = "更多（一般不用动）"
    static let magicMouseLanding = "落指间隔上限"
    static let magicMouseFresh = "新鲜窗口"
    static let magicMouseMovement = "最大移动量"
    static let magicMouseRestore = "恢复默认"
    static let magicMouseLiveTouch = "实时触点"
    static let magicMouseAwaitClick = "按一下，查看判定"
    static let magicMouseMark = "记录标注"
    static let magicMouseRecording = "记录触点数据"
    static let magicMouseClear = "清除记录"
    static let magicMouseClearRetry = "重试清除"
    static let magicMouseClearing = "正在移到废纸篓…"
    static let magicMouseClearFailure = "清除未完成，记录保留在原目录或废纸篓，可重试。"
    static let magicMouseStorageFailure = "记录未写入，请检查本 app 缓存目录的访问权限。"
    static let magicMouseRecordDetail = "只在这台 Mac 保存传感器数值；不含屏幕位置、应用名、文字或音频。每份最多 2 MB，最多两份；标注每次启动回到不标注。"
    static let magicMouseComparison = "当前设置下的对比"
    static let magicMouseComparisonEmpty = "选择记录标注并点击几次，就能在这里比较。"
    static let magicMouseDensityAxis = "较小手指的密度 · 竖线为当前阈值"
    static func magicMouseNumber(_ value: Float) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
    static func magicMouseMilliseconds(_ value: Int) -> String { "\(value) ms" }
    static func magicMouseLabel(_ value: TouchSampleLabel) -> String { switch value { case .none: "不标注"; case .single: "单击"; case .real: "双指按下" } }
    static func magicMouseRecorded(_ count: Int) -> String { "已记录 \(count) 次" }
    static func magicMouseTriggered(_ count: Int, ratio: Double) -> String { "会触发 \(count) 次 · \(Int((ratio * 100).rounded()))%" }
    static func magicMouseDecision(_ value: TouchSampleLatestDecision?) -> String {
        guard let value else { return magicMouseAwaitClick }
        if value.reason == .passed { return "触发 · 密度 \(magicMouseNumber(value.minDensity))" }
        if value.reason == .density { return "当作普通点击 · 密度 \(magicMouseNumber(value.minDensity)) < 阈值 \(magicMouseNumber(value.threshold))" }
        let reason: String = switch value.reason {
        case .touchCount: "触点数不符"; case .landingSkew: "落指间隔过长"; case .freshWindow: "超出新鲜窗口"
        case .movement: "移动量过大"; case .frameExpired: "触点帧过期"; case .density, .passed: ""
        }
        return "当作普通点击 · \(reason)"
    }
    static let diagnosticExport = "导出脱敏诊断包…"
    static let diagnosticFileName = "VoicePointer-diagnostics.zip"
    static let diagnosticExportDetail = "只包含近期数值与状态、版本和设置摘要；不含 API Key、识别文本或录音。"
    static let diagnosticExporting = "正在整理诊断包…"
    static let diagnosticExported = "诊断包已导出。"
    static let diagnosticExportFailed = "诊断包未导出。请选择一个可写位置与新的文件名后重试。"
    static let dataPageTitle = "数据与卸载"
    static let dataPageSubtitle = "管理下载内容、词库和本 app 的数据"
    static let dataDownloaded = "已下载的内容"
    static let dataLoading = "正在读取内容大小…"
    static let dataEmpty = "还没有下载内容。可在语音输入页下载本地模型。"
    static let dataReload = "重新读取"
    static let dataLexiconSection = "清空词库"
    static let dataClearLexicon = "清空词库与已学词条…"
    static let dataClearLexiconTitle = "确定清空词库？"
    static let dataClearLexiconDetail = "手动添加和自动学习的词条将移到废纸篓，待确认纠错也会清空。识别方式和学习开关保持原值。"
    static let dataPrepareUninstall = "删除全部数据并准备卸载…"
    static let dataRemovalTitle = "确定删除全部数据？"
    static let dataRemovalScope = "还将清理词库与已学词条、已保存的 API 配置、偏好、缓存和本 app 的登录项。数据与偏好先作一份小于 50 MB 的备份，其余内容移到废纸篓，然后退出本 app。应用可随后移到废纸篓；恢复备份会保留。"
    static func dataName(_ id: ManagedDataID) -> String {
        switch id {
        case .model17: "千问 1.7B"
        case .model06: "千问 0.6B"
        case .punctuation: "本地标点模型"
        case .modelDownloads: "未启用的模型文件与未完成下载"
        case .diagnosticLogs: "本 app 的诊断缓存"
        case .touchSamples: "妙控鼠标触点记录"
        case .personalLexicon: "词库与已学词条"
        }
    }
    static func dataSize(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
    static func deleteDataName(_ id: ManagedDataID) -> String { "删除\(dataName(id))" }
    static func dataRemovalDetail(_ items: [ManagedDataItem], total: UInt64) -> String {
        let content = items.map { "\(dataName($0.id))（\(dataSize($0.sizeBytes))）" }.joined(separator: "\n")
        return (content.isEmpty ? "" : content + "\n\n") + dataRemovalScope + "\n\n总大小：\(dataSize(total))"
    }
    static func dataFailure(_ failure: AppDataFailure?) -> String {
        switch failure {
        case .unsafePath: "发现受保护目录或不安全的路径，已停止清理。"
        case .snapshotTooLarge: "数据与偏好超过备份上限，未删除任何内容。请先减少数据后重试。"
        case .snapshot: "备份未完成，未删除任何内容。请检查磁盘空间和目录权限。"
        case .loginItem: "无法停用本 app 的登录项，数据未删除。请从正式安装的应用重试。"
        case .removal: "清理未完成，部分内容可能仍在原位置。请重新读取并检查访问权限。"
        case .inventory, nil: "无法读取内容大小或模型索引，请检查本 app 目录的访问权限。"
        }
    }
    static let downloadConsentTitle = "下载本地模型？"
    static let downloadConsentDetail = "将从魔搭下载，失败时改用 Hugging Face。1.7B 先下载约 4.70GB 原始文件，再在本机转换为约 2.50GB 的 8bit 模型并重载校验，另需保留空间。取消后可继续；不上传录音。"
    static let downloadConsentAction = "同意并下载"
    static let modelLibraryPending = "模型保存在本 app 的模型库；文件与容器检查不代表实际听写已验证。"
    static let deleteModelLibraryCopy = "删除下载的副本"
    static let onboardingAPIConfigure = "配置在线 API"
    static let onboardingAPIContinue = "配置完成，继续"
    static let onboardingAPINeedsConfiguration = "请先在在线 API 页完成配置及授权。"
    static let modelBenchmarkDetail = "M1 Max / 32GB 合成测试的加载峰值约为 0.6B：1.5GB、1.7B 8bit：2.4GB。"
    static func hardwareSummary(_ hardware: SettingsHardwareInfo) -> String {
        "这台 Mac：\(hardware.chipModel == "unknown" ? unknownChip : hardware.chipModel) · 内存 \(hardware.memoryBytes >> 30) GB · 可用空间 \(hardware.availableDiskBytes >> 30) GB"
    }
    static func modelRecommendation(_ hardware: SettingsHardwareInfo) -> String {
        hardware.supports(.qwen17) ? "推荐千问 1.7B：这台 Mac 跑得动，识别更准。" : "推荐千问 0.6B：更快、更省内存。"
    }
    static func modelGB(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
    static func modelDiskBytes(_ model: LocalModelItem) -> UInt64 {
        model.libraryInstalled ? model.sizeBytes : model.conversionOutputBytes ?? model.downloadBytes ?? model.sizeBytes
    }
    static func modelDescription(_ model: LocalModelItem) -> String {
        let performance = model.id == .qwen17 ? "更准，稍慢 · 运行时约占 2.4 GB 内存" : "更快 · 运行时约占 1.5 GB 内存"
        if model.state == .notDownloaded {
            let space = model.requiredSpaceBytes.map { "；下载时要先空出约 \(modelGB($0))" } ?? ""
            return performance + " · 下载后占磁盘约 \(modelGB(modelDiskBytes(model)))" + space
        }
        return performance + " · 占磁盘 \(modelGB(modelDiskBytes(model)))"
    }
    static func localModelStatus(_ state: LocalModelState) -> String {
        switch state {
        case .ready: "可用"
        case .notDownloaded: "未下载"
        case .downloading(let progress): "下载中 \(Int(min(1, max(0, progress)) * 100))%"
        case .converting: "正在转换"
        case .corrupt: "文件损坏"
        case .needsVerification, .verifying, .notApplicable: ""
        }
    }
    static func modelDownloadButton(_ model: LocalModelItem) -> String { "下载（\(modelGB(model.downloadBytes ?? model.sizeBytes))）" }
    static func modelDeleteButton(_ model: LocalModelItem) -> String { "删除这个模型（释放 \(modelGB(modelDiskBytes(model)))）" }
    static func modelDeleteWarning(_ model: LocalModelItem) -> String { "删除后，要用得重新下载（\(modelGB(model.downloadBytes ?? model.sizeBytes))）" }
    static func originalDeleteButton(_ bytes: UInt64) -> String { "删除原始下载文件（\(modelGB(bytes))）" }
    static func originalRemovalQuestion(_ bytes: UInt64) -> String { "转换好了。原始下载文件（\(modelGB(bytes))）用不上了，要删掉吗？" }
    static func downloadRemaining(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "正在估算剩余时间…" }
        return "约剩 \(max(1, Int(ceil(seconds / 60)))) 分钟"
    }
    static let appleModelName = "Apple 系统识别"
    static let appleModelDescription = "不用下载 · 准确度一般 · 不支持词库和识别记忆"
    static let recheckModelFiles = "重新检查文件"
    static let switchBeforeModelDelete = "先换用别的模型"
    static let convertForMac = "正在转换成这台 Mac 能用的格式…"
    static let keepOriginal = "先留着"
    static let removeOriginal = "删掉"
    static let unknownChip = "芯片信息未知"
    static func downloadFailure(_ error: ModelDownloadError) -> String {
        switch error {
        case .consentRequired: "请先同意下载本地模型。"
        case .sourceUnavailable: "尚未取得此版本的可靠下载源；请使用已准备的模型。"
        case .busy: "模型仍在收尾，请稍后重试。"
        case .diskFull: "磁盘空间不足，请腾出空间后重试。"
        case .offline: "下载中断，请检查网络后继续。"
        case .certificate: "无法验证下载源证书，请检查系统时间或代理证书。"
        case .proxy: "代理需要认证，请检查代理设置后重试。"
        case .checksum: "文件校验不符，已丢弃损坏文件，请重新下载。"
        case .http: "下载源响应异常，请检查网络或代理后重试。"
        case .unsafePath, .io: "无法安全保存模型，请检查本 app 目录的访问权限。"
        case .conversion: "本地模型转换未完成，可从已校验的文件重新转换。"
        case .reloadFailed: "转换后的模型重载校验失败，未启用，请重新转换。"
        }
    }
    static let convertingModel = "正在本机转换为 8bit…"
    static let verifyingModel = "正在校验模型文件…"
    static func modelDownloadSummary(_ model: LocalModelItem) -> String? {
        guard let bytes = model.downloadBytes, let required = model.requiredSpaceBytes else { return nil }
        let converted = model.conversionOutputBytes.map { " · 转换后\(modelSize($0))" } ?? ""
        return "下载\(modelSize(bytes))\(converted) · 需\(modelSize(required)) 可用空间"
    }
    static let recognition = "识别方式"
    static let doubao = "豆包输入法"
    static let local = "本地识别"
    static let online = "在线 API 识别"
    static let doubaoDetail = "使用系统输入法，在系统设置中启用。"
    static let localDetail = "在这台 Mac 上识别，默认不上传声音。"
    static let enhancedLocalDetail = "本地识别并在线增强，声音也会上传。"
    static let fixturePermissions = "已授权（预览夹具）"
    static let onlineDetail = "由服务商识别，声音会上传。"
    static let onlineEnhancement = "在线增强"
    static let enhanceLocal = "用于增强本地识别"
    static let enhancementHelp = "用在线 API 对本地识别结果做增强；只在本地路线生效。开启后声音也会发给服务商。"
    static let enhancementDetail = "用本地识别时，用云端结果纠正，并在本地学你常用的词；只记词，不存整句。"
    static let enhancementLocalOnly = "只在用本地识别时起作用"
    // T7: Token model scores and alignment are conservative guards, never correctness guarantees.
    static let learningSection = "学习"
    static let enhancementLearning = "增强学习"
    static let enhancementLearningExplanation = "开启后，豆包给出的词会用同一段声音在本地复核，帮助本地识别学习常用词。声音不保存、不上传。"
    static let enhancementLearningUnavailable = "候选词会用同一段声音在本地复核；认对就学会，没认对则继续观察专有词。"
    static let enhancementLearningNeedsOnline = "豆包老师跟随增强学习，只在本地处理。"
    static let doubaoLearningPrivacy = "听写时本 app 会在本机处理一份你的声音（不保存、不上传）"
    static func automaticallyLearned(_ count: Int) -> String { "自动学习 · \(count) 次匹配" }
    static let help = "说明"
    static let check = "重新检查"
    static let checkBusy = "检查中…"
    static let checking = "检查中"
    static let checkingDetail = "正在检查…"
    static let passed = "可用"
    static let failed = "不可用"
    static let notChecked = ""
    static let notInstalled = "未安装"
    static let notDownloaded = "未下载"
    static let notConfigured = "未配置"
    static let publicInputSourcePassed = "已安装，并在系统中启用。"
    static let localContainerPassed = "文件与容器检查通过；还没用过。"
    static let nonBillingCheckUnavailable = "尚未完成连接检查。检查只握手，不发送声音。"
    static let configure = "去配置"
    static let localModels = "本地模型"
    static let ready = "已就绪"
    static let inUse = "使用中"
    static let recommended = "推荐"
    static let download = "下载"
    static let redownload = "重新下载"
    static let cancel = "取消"
    static let delete = "删除"
    static let use = "设为使用"
    static let verifyFiles = "检查文件"
    static let needsVerification = "待校验"
    static let unsuitable = "当前配置不适用"
    static let corrupt = "文件损坏"
    static let modelSizeUnknown = "下载大小待来源核实"
    static let modelMemoryUnknown = "内存占用尚未实测"
    static let localGuideTitle = "先准备一个本地模型"
    static let localGuideSteps = ["选择千问 1.7B 或更轻量的 0.6B。", "下载后无需联网；首次使用前会校验文件。"]
    static let localGuideLimitedSteps = ["这台 Mac 建议使用更轻量的千问 0.6B。", "下载后无需联网；首次使用前会校验文件。"]
    static let downloadRecommended = "下载推荐模型"
    static let doubaoGuideTitle = "准备豆包输入法"
    static let doubaoGuideSteps = ["下载并安装豆包输入法。", "在系统设置的输入法列表中启用它。"]
    static let doubaoPrivateHint = "按下说话没有反应时，请在豆包里打开它的语音输入（这一项咻读不到）"
    static let provider = "服务商"
    static let key = "Key"
    static let keyGuideTitle = "怎么免费获取 Key"
    static let keyGuideSteps = ["打开服务商控制台，注册并登录。", "创建并复制 API Key。", "回来粘贴并保存。"]
    static let keyHelp = "查看获取方法"
    static let documentation = "说明文档"
    static let keyPlaceholder = "粘贴 API Key"
    static let optionalLabel = "标签（可选）"
    static let save = "保存"
    static let saved = "已保存"
    static let saveFailed = "没能保存，请稍后重试。"
    static let invalidKeyFormat = "Key 格式不正确，请核对后重新粘贴。"
    static let deletingKey = "正在删除…"
    static let deleteKeyTitle = "删除 API Key？"
    static let deleteKeyDetail = "删除后需要重新添加 Key；在线识别和在线增强会关闭。"
    static let enhancementSection = "增强"
    static let expiry = "有效期"
    static let remainingQuota = "剩余额度"
    static let language = "识别语言"
    static let english = "English"
    static func percent(_ value: Int) -> String { "\(value)%" }
    static func lexiconCapacity(_ count: Int, _ limit: Int) -> String { "\(count) / \(limit)" }
    static func correction(_ variant: String, _ canonical: String) -> String { "「\(variant)」→「\(canonical)」" }
    static let engine = "识别引擎"
    static let select = "选择"
    static let close = "关闭"
    static let manageRecognition = "管理识别方式…"
    static let onboardingSteps = ["1 权限", "2 选择识别方式", "3 完成配置"]
    static let modelDocumentationURL = URL(string: "https://huggingface.co/Qwen/Qwen3-ASR-1.7B")!
    static let doubaoDocumentationURL = URL(string: "https://shurufa.doubao.com/pc")!
    static let inputSourcesURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources")!
    static let apiGuideResource = "APIKeyGuide"
    static let apiGuideExtension = "md"
    static let apiGuideTitle = "API Key 说明"
    static let apiGuideMarkdown = """
    # API Key 说明

    **什么是 API Key**
    API Key 是服务商签发的访问凭据。不要分享，也不要放进截图或日志。

    **如何领取免费额度**
    在服务商官方控制台查看当前免费额度与领取条件。额度及有效期以服务商信息为准；本应用无法取得时不显示，也不要求手填。

    **如何用完即停**
    在服务商控制台启用它提供的免费额度用完即停设置。仅在自动得到明确额度耗尽结果时，本应用会关闭在线功能。连接检查不代表识别或额度已验证。

    **Key 存在哪里**
    保存后加密放在本应用自己的本机数据目录；设置页只显示是否已保存，不显示 Key。

    **如何删除**
    在“语音输入 → 在线 API 识别 → Key”点击“删除”。依赖它的在线识别和增强会关闭。
    """

    static func onlineTitle(_ name: String) -> String { name.isEmpty ? online : "\(online)（\(name)）" }
    static func providerChecked(_ name: String) -> String { "服务商：\(name)" }
    static func modelSize(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return modelSizeUnknown }
        return "约 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))"
    }
    static func modelMenuTitle(_ id: LocalModelID) -> String { "\(local) · \(id.name)" }
    static func menuSuffix(_ kind: OnlineRouteMenuState.StatusKind) -> String {
        OnlineAPIStrings.onlineMenuSuffix(kind)
    }
    static func menuSuffix(_ state: EngineHealthState?, needsPreparation: Bool = false) -> String {
        guard let state else { return "" }
        let value = status(state)
        return value.isEmpty ? "" : " · " + value
    }
    static func failure(_ reason: HealthFailureReason) -> String {
        switch reason {
        case .doubaoNotInstalled: "没有找到豆包输入法"
        case .doubaoNotEnabled: "豆包输入法没有在系统里启用"
        case .inspectionUnavailable: "无法读取系统输入源状态"
        case .modelNotDownloaded: "还没有本地模型"
        case .modelCorrupt: "本地模型文件损坏"
        case .hardwareUnsuitable: "当前配置不适用此模型"
        case .localLoadFailed: "本地模型未能加载"
        case .noKey: "还没有配置 API"
        case .invalidKey: "Key 无效或已过期"
        case .network: "连不上服务商"
        case .freeQuotaExhausted: "免费额度已用完，已自动停用"
        case .notNetworkVerified: ""
        case .timeout: "检查超时"
        case .unavailable: "无法完成检查"
        case .noAccess, .balanceDue, .rateLimited, .modelUnavailable, .serviceUnavailable, .worker, .taskStartFailed, .notClosed: reason.message
        }
    }
    static func nextAction(_ action: HealthNextAction) -> String {
        switch action {
        case .installDoubao: "去下载安装"
        case .enableSystemInput: "去系统设置启用"
        case .downloadRecommendedModel: downloadRecommended
        case .redownloadModel: redownload
        case .use06B: "改用 0.6B"
        case .configureAPI: configure
        case .replaceKey: "重新填写 Key"
        case .retryNetwork: "检查网络后重试"
        case .providerConsole: "查看服务商控制台"
        case .providerDocumentation: documentation
        case .recheck: check
        }
    }
    static func status(_ state: EngineHealthState, idle: String = notChecked) -> String {
        state == .idle ? idle : state.statusTitle
    }
    static func detail(_ state: EngineHealthState, provider: String) -> String {
        switch state {
        case .idle: notChecked
        case .checking: checkingDetail
        case .passed(.publicInputSource): publicInputSourcePassed
        case .passed(.localContainerLoadable): localContainerPassed
        case .passed(.providerVerified): providerChecked(provider)
        case .passed(.dictationSucceeded): "可用 · 听写成功"
        case .failed(.notNetworkVerified, _): nonBillingCheckUnavailable
        case .failed(let reason, _): failure(reason)
        }
    }
}

// Existing SettingsRootView.swift presentation, preserved while centralizing its copy.
extension SettingsStrings {
    static let settingsRootViewCopy001 = "语音输入"
    static let settingsRootViewCopy002 = "圆盘样式"
    static let settingsRootViewCopy003 = "手势与输入"
    static let settingsRootViewCopy004 = "个人词库"
    static let settingsRootViewCopy005 = "通用"
    static let settingsRootViewCopy006 = "选择由谁把你说的话变成文字。"
    static let settingsRootViewCopy007 = "说话时出现在光标旁的圆盘。"
    static let settingsRootViewCopy008 = "怎样叫出圆盘。"
    static let settingsRootViewCopy009 = "常用词与识别纠错。"
    static let settingsRootViewCopy010 = "启动、权限与诊断。"
    static let settingsRootViewCopy011 = "千问 1.7B（本地）"
    static let settingsRootViewCopy012 = "千问 0.6B（本地）"
    static let settingsRootViewCopy013 = "Apple 系统识别"
    static let settingsRootViewCopy014 = "Groq v3（云端）"
    static let settingsRootViewCopy015 = "Groq Turbo（云端）"
    static let settingsRootViewCopy016 = "阿里云识别（云端）"
    static let settingsRootViewCopy017 = "正在检查本机配置…"
    static let settingsRootViewCopy018 = "未知芯片架构"
    static let settingsRootViewCopy019 = "未知"
    static func settingsRootViewCopy020(_ value0: Any, _ value1: Any, _ value2: Any) -> String { "本机概况：\(value0)，内存 \(value1)，模型所在磁盘可用 \(value2)" }
    static func settingsRootViewCopy021(_ value0: Any) -> String { "\(value0)（当前用不了）" }
    static let settingsRootViewCopy022 = "中文"
    static let settingsRootViewCopy023 = "粤语"
    static let settingsRootViewCopy024 = "自动"
    static func settingsRootViewCopy025(_ value0: Any) -> String { "\(value0)（当前用不了）" }
    static let settingsRootViewCopy026 = "阿里云识别只支持中文、English 和自动"
    static let settingsRootViewCopy027 = "云端识别还没开放"
    static let settingsRootViewCopy028 = "Apple 系统识别需要 macOS 26 或更新版本"
    static let settingsRootViewCopy029 = "Apple 系统识别要选一种具体语言"
    static let settingsRootViewCopy030 = "这个识别方案在当前版本里用不了"
    static let settingsRootViewCopy031 = "模型与运行环境已包含"
    static let settingsRootViewCopy032 = "这个模型不支持所选语言"
    static let settingsRootViewCopy033 = "正在检查 Apple 系统语音资源…"
    static let settingsRootViewCopy034 = "系统语音资源已检查"
    static let settingsRootViewCopy035 = "系统资源已检查，可切换"
    static let settingsRootViewCopy036 = "文件与运行环境已检查"
    static let settingsRootViewCopy037 = "文件与运行环境已检查，可切换"
    static let settingsRootViewCopy038 = "需要检查系统语音资源"
    static func settingsRootViewCopy039(_ value0: Any) -> String { "已停用云端识别，声音不再上传；但「\(value0)」现在也用不了，请在下面换一个引擎。" }
    static let settingsRootViewCopy040 = "要先检查系统语音资源"
    static let settingsRootViewCopy041 = "现在用不了"
    static func settingsRootViewCopy042(_ value0: Any, _ value1: Any, _ value2: Any) -> String { "已改回「\(value0)」。原来用的「\(value1)」\(value2)，可以在下面的本地模型列表里换回去。" }
    static func settingsRootViewCopy043(_ value0: Any) -> String { "已改回「\(value0)」，下次开始说话时生效。" }
    static let settingsRootViewCopy044 = "没找到豆包输入法，当前识别方式未更改。"
    static let settingsRootViewCopy045 = "豆包已选择；请确认系统已启用，并检查豆包内部语音快捷键。应用无法自动读取这两项。"
    static let settingsRootViewCopy046 = "已选择豆包；请确认系统已启用，并检查豆包内部语音快捷键。应用无法自动读取这两项。"
    static let settingsRootViewCopy047 = "Apple 系统识别要先检查语音资源；当前方式未更改。点下面的「检查 / 准备」。"
    static func settingsRootViewCopy048(_ value0: Any, _ value1: Any) -> String { "\(value0)。现在用的还是「\(value1)」。" }
    static let settingsRootViewCopy049 = "Apple 系统识别要选中文、English 或粤语。"
    static let settingsRootViewCopy051 = "Apple 系统语音资源已检查。"
    static let settingsRootViewCopy052 = "系统语音资源未准备好，请稍后重试。"
    static func settingsRootViewCopy053(_ value0: Any) -> String { "这个组合用不了；现在用的还是「\(value0)」。" }
    static let settingsRootViewCopy054 = "识别语言已改，下次开始说话时生效。"
    static func settingsRootViewCopy055(_ value0: Any) -> String { "已切换到「\(value0)」，下次开始说话时生效。" }
    static let settingsRootViewCopy056 = "保存失败，已恢复原来的设置。"
    static let settingsRootViewCopy057 = "千问 1.7B"
    static let settingsRootViewCopy058 = "千问 0.6B"
    static let settingsRootViewCopy060 = "本地识别 · 千问 1.7B"
    static let settingsRootViewCopy061 = "本地识别 · 千问 0.6B"
    static let settingsRootViewCopy063 = "阿里云识别"
    static func settingsRootViewCopy064(_ value0: Any) -> String { "本地识别 · \(value0)" }
    static let settingsRootViewCopy065 = "云端识别已关闭"
    static let settingsRootViewCopy066 = "阿里云 Key 读不出来"
    static let settingsRootViewCopy067 = "还没添加阿里云 API"
    static func settingsRootViewCopy068(_ value0: Any) -> String { "\(value0)，现在用本机" }
    static let settingsRootViewCopy070 = "正在删除 API…"
    static let settingsRootViewCopy071 = "只认中文、English、自动"
    static let settingsRootViewCopy072 = "已添加"
    static let settingsRootViewCopy073 = "测试中…"
    static func settingsRootViewCopy074(_ value0: Any) -> String { "连接正常 · \(value0) 测试" }
    static let settingsRootViewCopy075 = "连接失败"
    static let settingsRootViewCopy077 = "还没添加"
    static let settingsRootViewCopy078 = "读不出来，需要重填"
    static let settingsRootViewCopy079 = "云端识别入口被关闭了，不会发起任何云请求。"
    static let settingsRootViewCopy080 = "添加自己的 API 后，「阿里云」会出现在上面的识别方式里，还可以勾选「用于增强本地识别」。Key 只加密保存在这台 Mac 上。"
    static let settingsRootViewCopy081 = "Key 只加密保存在这台 Mac 上；「测试连接」只握手，不发送声音。"
    static let settingsRootViewCopy082 = "保存的 Key 读不出来。重新填写一个，或者先删除再添加。"
    static let settingsRootViewCopy085 = "在这台 Mac 上识别。"
    static func settingsRootViewCopy086(_ value0: Any) -> String { "模型：\(value0)（华北2（北京））" }
    static let settingsRootViewCopy087 = "请先在阿里云百炼控制台，给这个模型打开「免费额度用完即停」。应用查不到这个开关，只能按你的确认办；确认管 30 天，到期后要再确认一次。"
    static let settingsRootViewCopy088 = "打开百炼控制台"
    static func settingsRootViewCopy090(_ value0: Any) -> String { "已改回「\(value0)」。" }
    static func settingsRootViewCopy091(_ value0: Any) -> String { "阿里云 API 已删除，Key 已从这台 Mac 移除。\(value0)" }
    static func settingsRootViewCopy092(_ value0: Any) -> String { "没能删除本机保存的 Key，请稍后再试；阿里云已经停用，声音不会再发出去。\(value0)" }
    static let settingsRootViewCopy093 = "阿里云识别只支持中文、English 和自动。先点「本地识别」，把识别语言改成其中一种。"
    static func settingsRootViewCopy094(_ value0: Any) -> String { "阿里云的状态读不到，暂时不能选（重启 VoicePointer 后再试）。现在用的还是「\(value0)」。" }
    static let settingsRootViewCopy095 = "阿里云现在用不了，没有切换。"
    static let settingsRootViewCopy098 = "没能保存确认，阿里云保持关闭。请稍后再试；反复失败的话，重启 VoicePointer 后再试。"
    static let settingsRootViewCopy099 = "已记下你的确认，没有切换。点「阿里云」卡片再选用。"
    static let settingsRootViewCopy100 = "「用于增强本地识别」勾着，下次开始说话时声音也会发给阿里云。"
    static let settingsRootViewCopy101 = "触控板三指按压"
    static let settingsRootViewCopy102 = "听写方式"
    static let settingsRootViewCopy103 = "按住说话"
    static let settingsRootViewCopy104 = "点按开关"
    static let settingsRootViewCopy105 = "键盘"
    static let settingsRootViewCopy106 = "左 Option 长按 · 右 Option 点按"
    static let settingsRootViewCopy107 = "妙控鼠标"
    static let settingsRootViewCopy108 = "双指按压"
    static let settingsRootViewCopy109 = "叫出圆盘"
    static let settingsRootViewCopy110 = "键盘快捷键保持固定；妙控鼠标的误触过滤可以调校。"
    static let settingsRootViewCopy111 = "聚焦方式"
    static let settingsRootViewCopy112 = "仅当前焦点"
    static let settingsRootViewCopy113 = "智能聚焦"
    static let settingsRootViewCopy114 = "仅听写，不改变焦点"
    static let settingsRootViewCopy115 = "聚焦失败时允许模拟点击"
    static let settingsRootViewCopy116 = "文字写到哪里"
    static let settingsRootViewCopy117 = "模拟点击可能点到其他窗口；此选择默认关闭，已有的用户设置会保留。"
    static let settingsRootViewCopy118 = "登录时自动启动"
    static let settingsRootViewCopy119 = "系统登记"
    static let settingsRootViewCopy120 = "打开登录项设置"
    static let settingsRootViewCopy121 = "后台监听"
    static let settingsRootViewCopy122 = "重新检查权限与监听"
    static let settingsRootViewCopy123 = "启动与监听"
    static let settingsRootViewCopy124 = "这里显示授权情况。圆盘是否响应，请用手势实际试一下。"
    static let settingsRootViewCopy125 = "麦克风"
    static let settingsRootViewCopy126 = "用于圆盘说话时读取声音电平；仅在用户开始说话后使用。"
    static let settingsRootViewCopy127 = "辅助功能"
    static let settingsRootViewCopy128 = "读取当前焦点并将文字交给目标应用。"
    static let settingsRootViewCopy129 = "已授权"
    static let settingsRootViewCopy130 = "需要授权"
    static let settingsRootViewCopy131 = "输入监控"
    static let settingsRootViewCopy132 = "接收触控板、键盘和妙控鼠标的全局手势。"
    static let settingsRootViewCopy135 = "权限"
    static let settingsRootViewCopy136 = "未授权时，按钮只打开对应的系统设置页面，不会自动申请麦克风或启动监听。"
    static let settingsRootViewCopy137 = "诊断与版本"
    static let settingsRootViewCopy138 = "版本"
    static let settingsRootViewCopy140 = "运行日志"
    static let settingsRootViewCopy141 = "在访达中显示"
    static let settingsRootViewCopy142 = "重新运行首次引导"
    static let settingsRootViewCopy143 = "输入权限待授权"
    static let settingsRootViewCopy144 = "麦克风权限待确认"
    static let settingsRootViewCopy145 = "权限齐全"
    static let settingsRootViewCopy147 = "已拒绝"
    static let settingsRootViewCopy148 = "尚未询问"
    static let settingsRootViewCopy149 = "状态未知"
    static let settingsRootViewCopy150 = "去授权"
    static let settingsRootViewCopy152 = "已启用"
    static let settingsRootViewCopy153 = "等待系统批准"
    static let settingsRootViewCopy154 = "系统尚未登记"
    static let settingsRootViewCopy155 = "未登记"
    static let settingsRootViewCopy156 = "登录项不可用"
    static let settingsRootViewCopy157 = "系统状态未知"
}


// Existing FirstRunWindow.swift presentation, preserved while centralizing its copy.
extension SettingsStrings {
    static let firstRunWindowCopy001 = "开始使用 VoicePointer"
    static let firstRunWindowCopy002 = "选择语音输入方式"
    static let firstRunWindowCopy003 = "安装豆包输入法"
    static let firstRunWindowCopy004 = "启用豆包输入法"
    static let firstRunWindowCopy005 = "检查必要权限"
    static let firstRunWindowCopy006 = "试着说一句话"
    static let firstRunWindowCopy007 = "选择本地识别模型"
    static let firstRunWindowCopy008 = "准备本地识别"
    static let firstRunWindowCopy009 = "云端增强可以稍后配置"
    static let firstRunWindowCopy010 = "可以开始使用"
    static let firstRunWindowCopy011 = "三种方式之后都能在设置里切换；在线功能需你配置并授权。"
    static let firstRunWindowCopy012 = "还没装豆包输入法？装好后回到这里，会自动重新检查。"
    static let firstRunWindowCopy013 = "启用需要你在系统设置里完成，我们不会修改豆包自己的配置。"
    static let firstRunWindowCopy014 = "开始之前，需要你在系统里打开三项权限。授权后这里会自动更新。"
    static let firstRunWindowCopy015 = "在这个临时输入框里用真实手势试一次，不向外部应用发送。"
    static let firstRunWindowCopy016 = "推荐千问 1.7B，0.6B 更轻；Apple 需 macOS 26 及以上。"
    static let firstRunWindowCopy017 = "模型就绪后，识别全程在这台 Mac 上完成。"
    static let firstRunWindowCopy018 = "本地路线已选好，接下来只检查必要权限。"
    static let firstRunWindowCopy019 = "登录后自动启动会继续按设置执行；不会自动开始录音。"
    static let firstRunWindowCopy021 = "千问 1.7B · 推荐"
    static let firstRunWindowCopy022 = "千问 0.6B · 轻量"
    static let firstRunWindowCopy024 = "Apple 识别一次只使用一种语言；现有语言为“自动”时，引导会选中文。之后可在语音设置中更改。"
    static let firstRunWindowCopy025 = "重新选择本地方案"
    static let firstRunWindowCopy026 = "千问文件保存在本 app 的模型库；Apple 系统语音资源由 macOS 26 及以上准备。"
    static let firstRunWindowCopy027 = "先用本地识别"
    static let firstRunWindowCopy028 = "以后想让阿里云参与本地识别：到「设置 → 语音输入 → 在线 API」添加阿里云 API，再勾选「用于增强本地识别」。本引导不会上传语音。"
    static let firstRunWindowCopy032 = "语音输入练习框"
    static let firstRunWindowCopy033 = "我已用语音手势在这里输入文字"
    static let firstRunWindowCopy034 = "勾选来自你的实际练习；输入框里有字本身不能证明语音识别成功。"
    static func firstRunWindowCopy035(_ value0: Any) -> String { "已选择：\(value0)" }
    static let firstRunWindowCopy036 = "如果之后遇到权限或目标输入框问题，可从菜单栏的设置里重新检查。"
    static let firstRunWindowCopy037 = "稍后"
    static let firstRunWindowCopy038 = "换一种方式"
    static let firstRunWindowCopy039 = "开始使用"
    static let firstRunWindowCopy040 = "继续"
    static let firstRunWindowCopy041 = "重新检查并继续"
    static let firstRunWindowCopy042 = "检查所选模型"
    static let firstRunWindowCopy043 = "准备 Apple 语音资源"
    static let firstRunWindowCopy044 = "检查并启用本地识别"
    static let firstRunWindowCopy045 = "检查权限并继续"
    static let firstRunWindowCopy047 = "完成设置"
    static let firstRunWindowCopy048 = "豆包安装对象已找不到；请返回重新安装。"
    static let firstRunWindowCopy049 = "无法保存当前方式，请稍后重试。"
    static let firstRunWindowCopy050 = "还有权限未开启；完成后回来重新检查。"
    static let firstRunWindowCopy051 = "系统语音资源没准备好；当前识别方式保持不变，请重试。"
    static let firstRunWindowCopy052 = "本地方案没准备好；当前识别方式保持不变。"
    static let firstRunWindowCopy059 = "请求授权"
    static let firstRunWindowCopy060 = "打开系统设置"
    static let firstRunWindowCopy061 = "设置进度未能保存；请稍后重试。"
}


// Existing LexiconSettingsPage.swift presentation, preserved while centralizing its copy.
extension SettingsStrings {
    static let lexiconSettingsPageCopy001 = "正在读取词库…"
    static let lexiconSettingsPageCopy002 = "词库文件读不出来（可能被改坏了）。为了不覆盖它，词库现在只读、不生效。你可以把它挪到一边（原文件会原样保留成备份），重新开始一个空词库。"
    static let lexiconSettingsPageCopy003 = "挪开并重新开始…"
    static let lexiconSettingsPageCopy004 = "词库文件是更新版本的应用写的，这个版本读不了，也不会去改它。"
    static let lexiconSettingsPageCopy005 = "词库文件夹现在不能使用（权限、符号链接或磁盘问题），词库暂时关闭，没有改动任何文件。"
    static let lexiconSettingsPageCopy006 = "重试"
    static let lexiconSettingsPageCopy007 = "清空整个词库？"
    static let lexiconSettingsPageCopy008 = "清空词库"
    static let lexiconSettingsPageCopy010 = "所有词条都会被删掉，应用里不能恢复。"
    static let lexiconSettingsPageCopy011 = "把词库文件挪开并重新开始？"
    static let lexiconSettingsPageCopy012 = "挪开并重新开始"
    static let lexiconSettingsPageCopy013 = "没能挪开这个文件，什么都没有改。"
    static let lexiconSettingsPageCopy015 = "原文件不会被删除，只是改名保留在同一个文件夹里。"
    static let lexiconSettingsPageCopy016 = "听写时套用个人词库"
    static let lexiconSettingsPageCopy017 = "让本地识别优先听你的词库词汇"
    static let lexiconSettingsPageCopy018 = "识别时会优先带上最常用的一批词"
    static func lexiconTermCountSummary(_ count: Int) -> String { "词库共 \(count) 条" }
    static let lexiconHotwordHelp = "词库最多可存 \(LexiconLimits.maxTerms) 条；每次听写时，本地识别只会优先带上最常用的约 \(RecognitionHotwords.maximumTerms) 个词作为提示。带得太多，识别模型反而可能被带偏、乱改。"
    static let lexiconSettingsPageCopy019 = "从我的修改中学习"
    static let lexiconSettingsPageCopy020 = "开启后：你亲手把听错的词改对，再按一次手势时，VoicePointer 会在本机比较改动前后，把符合条件的小改动自动加入词库；正常英文单词只将正确写法作为热词，不建替换。最近 5 条列在「刚学会」，可撤销。听写原文和输入框文字只放在内存里（5 分钟内没有下一次手势就丢掉），不写硬盘、不上传，日志只记次数和状态。改数字、否定词、整句重写都不会被学习。"
    static let lexiconSettingsPageCopy021 = "现在用的是豆包输入法：文字由输入法直接写进输入框，应用拿不到，词库对它不生效。换成「本地识别」或「阿里云」后才起作用。"
    static let lexiconSettingsPageCopy023 = "识别出文字后、写进输入框之前，按字面把错的写法换成你要的写法。英文不分大小写，中文错写至少两个字。"
    static let lexiconSettingsPageCopy024 = "现在没有词会交给识别。"
    static let lexiconSettingsPageCopy025 = "当前的识别方式不使用热词（只有本地识别的千问模型会用）。"
    static let lexiconSettingsPageCopy026 = "词库里还没有可以交给识别的词。"
    static func lexiconSettingsPageCopy027(_ value0: Any) -> String { "下一次听写会把其中 \(value0) 个词交给识别。" }
    static let lexiconSettingsPageCopy028 = "正确写法"
    static let lexiconSettingsPageCopy029 = "例如：OpenAI"
    static let lexiconSettingsPageCopy030 = "识别成了什么（可不填）"
    static let lexiconSettingsPageCopy031 = "例如：open ai，欧朋爱（多个用逗号隔开）"
    static let lexiconSettingsPageCopy032 = "添加到词库"
    static let lexiconSettingsPageCopy033 = "手动添加词条"
    static let lexiconSettingsPageCopy034 = "正确写法是最后写进输入框的样子；「识别成了什么」是识别经常听错的写法，可以填好几个，出现时会被换成正确写法。不填也可以：它就只是一个常用词，不会改写任何文字，只是让本地识别优先听它（至少两个字或字母）。同一个错写只会属于一个词条。"
    static let lexiconSettingsPageCopy035 = "还没有。听写一句，手动把听错的词改对，再按一次手势，这里就会出现。"
    static let lexiconSettingsPageCopy036 = "待确认纠错"
    static let lexiconSettingsPageCopy037 = "只存在本次运行的内存里：退出应用就没有了，超过一周没再出现的也会自动消失，不会写到硬盘。点「忽略」后，本次运行里不会再提示同样的改法。"
    static let lexiconSettingsPageCopy038 = "搜索词条"
    static let lexiconSettingsPageCopy039 = "按正确写法或错写搜索"
    static let lexiconSettingsPageCopy040 = "还没有词条。识别错了的词，可以在「手动添加词条」区添加，或在「最近听写」区点「纠正…」。"
    static let lexiconSettingsPageCopy041 = "清空词库…"
    static let lexiconSettingsPageCopy042 = "我的词条"
    static let lexiconSettingsPageCopy043 = "说过话之后，最近几句会出现在这里；识别错了，点「纠正…」，把错的那几个字改对，就会记进词库。"
    static let lexiconSettingsPageCopy044 = "清空最近听写"
    static let lexiconSettingsPageCopy045 = "最近听写"
    static let lexiconSettingsPageCopy046 = "只存在本次运行的内存里：退出应用就没有了，不会写到硬盘；超过 12 小时的不再显示。"
    static func lexiconSettingsPageCopy047(_ value0: Any) -> String { "用到 \(value0) 次" }
    static let lexiconSettingsPageCopy048 = "启用"
    static let lexiconSettingsPageCopy049 = "编辑"
    static let lexiconSettingsPageCopy050 = "删除这个词条"
    static let lexiconDeletedNotice = "已删除"
    static let lexiconSettingsPageCopy051 = "加入词库"
    static let lexiconSettingsPageCopy052 = "忽略"
    static func lexiconSettingsPageCopy053(_ value0: Any) -> String { "词库已纠正 \(value0) 处" }
    static let lexiconSettingsPageCopy054 = "纠正…"
    static let lexiconSettingsPageCopy055 = "这个开关没能保存，设置保持原样。"
    static let lexiconSettingsPageCopy058 = "只填正确写法、不填错写时，至少要两个字或字母，太短的词加进来也不会起作用。"
    static func lexiconSettingsPageCopy059(_ value0: Any) -> String { "「\(value0)」已经在词库里了。" }
    static func lexiconSettingsPageCopy060(_ value0: Any) -> String { "你改过 \(value0) 次" }
    static let lexiconSettingsPageCopy061 = " · 只差大小写或空格"
    static let lexiconSettingsPageCopy062 = " · 读音很接近，像是识别听错"
    static let lexiconSettingsPageCopy063 = "词库里已经有一条词条在用这个错写，这条建议没有加入。"
    static let lexiconSettingsPageCopy064 = "这个错写正是词库里另一条词条的正确写法，这条建议没有加入。"
    static let lexiconSettingsPageCopy065 = "这个正确写法是词库里另一条词条的错写，这条建议没有加入。"
    static let lexiconSettingsPageCopy066 = "词库里同一个正确写法的词条被你关掉了，这条建议没有加入（要用的话先在下面把它打开）。"
    static let lexiconSettingsPageCopy067 = "词库里已经有相关的词条，这条建议没有加入。"
    static let lexiconSettingsPageCopy068 = "只是常用词（没有错写）"
    static let lexiconSettingsPageCopy069 = "识别成："
    static func lexiconSettingsPageCopy070(_ value0: Any) -> String { "已添加「\(value0)」，下一次听写起生效。" }
    static func lexiconSettingsPageCopy071(_ value0: Any) -> String { "「\(value0)」原来就有，已把新的错写并进去，下一次听写起生效。" }
    static func lexiconSettingsPageCopy072(_ value0: Any) -> String { "（有的错写原来属于「\(value0)」，已移到这里。）" }
    static let lexiconSettingsPageCopy073 = "词库还没读好，请稍后再试。"
    static let lexiconSettingsPageCopy074 = "词库文件现在不能写入（权限或磁盘问题），这次改动没有保存。"
    static let lexiconSettingsPageCopy075 = "词库文件现在读不了，这次改动没有保存。"
    static let lexiconSettingsPageCopy076 = "词库文件在应用外面被改过，已重新读取，这次改动没有保存，请再做一次。"
    static let lexiconSettingsPageCopy077 = "编辑词条"
    static let lexiconSettingsPageCopy079 = "识别成了什么（一行一个）"
    static let lexiconSettingsPageCopy080 = "启用这个词条"
    static let lexiconSettingsPageCopy083 = "纠正这句听写"
    static let lexiconSettingsPageCopy084 = "把下面的句子改成你想要的样子，只改识别错的那几个字就行。"
    static func lexiconSettingsPageCopy087(_ value0: Any, _ value1: Any) -> String { "以后听写里出现「\(value0)」，会自动写成「\(value1)」。" }
}


// Existing Skins/SkinAppearancePage.swift presentation, preserved while centralizing its copy.
extension SettingsStrings {
    static let skinAppearancePageCopy001 = "大圆盘"
    static let skinGroupSmall = "小球"
    static let skinBlurbMiniDisc = "一颗清透的玻璃小圆盘：上推画出箭头，下推画出撤回"
    static let skinBlurbMiniMorph = "同一颗玻璃小圆盘，变符号时玻璃自己也跟着变形"
    static let skinBlurbGlassDisc = "按真实光学画的 3D 玻璃片（清透）：会折射、有色散"
    static let skinBlurbFrostDisc = "按真实光学画的 3D 玻璃片（磨砂）：会折射、背后糊开"
    static let skinBlurbFerrofluid = "一滴黑亮的磁流体，声音越大刺越长"
    static let skinBlurbVoiceLine = "没声音时是一个圈，说话时圈散成点往外扩"
    static let skinBlurbRipple = "一小片水面，声音点出一圈圈涟漪"
    static let skinBlurbPlasma = "玻璃球里的电弧，声音越大电弧越多"
    static let skinAppearancePageCopy002 = "趣味"
    static let skinAppearancePageCopy003 = "选好后，下次叫出圆盘时生效。把鼠标移到小图上可以看它的动作。"
    static let skinAppearancePageCopy004 = "带「编辑」的样式还能调整外观和大小。"
    static let skinAppearancePageCopy007 = "预览外观"
    static let skinAppearancePageCopy008 = "浅色"
    static let skinAppearancePageCopy009 = "深色"
    static let skinAppearancePageCopy010 = "看发送"
    static let skinAppearancePageCopy011 = "看撤回"
    static let skinAppearancePageCopy012 = "在屏幕上试一下"
    static let skinAppearancePageCopy013 = "预览正在准备"
    static let skinAppearancePageCopy014 = "着色器暂不可用，实际手势会回退到经典皮肤。"
    static let skinAppearancePageCopy015 = "预览状态"
    static let skinAppearancePageCopy016 = "预览暂不可用"
    static let skinAppearancePageCopy017 = "预览准备中"
    static let skinAppearancePageCopy018 = "已选择"
    static let skinAppearancePageCopy019 = "需要 macOS 26"
    static let skinAppearancePageCopy022 = "编辑 "
    static let skinAppearancePageCopy023 = "玻璃珠"
    static let skinAppearancePageCopy024 = "默认圆盘：清透、柔和、磨砂三种质感"
    static let skinAppearancePageCopy025 = "默认圆盘：清透、柔和、磨砂三种质感"
    static let skinDefaultTitle = "默认"
    static let skinTextureLabel = "质感"
    static let skinTextureClear = "清透"
    static let skinTextureSoft = "柔和"
    static let skinTextureFrost = "磨砂"
    static let skinTextureClearNote = "系统液态玻璃，背后的内容看得很清楚。"
    static let skinTextureSoftNote = "系统液态玻璃的常规样式，背后带一点模糊。"
    static let skinTextureFrostNote = "完整的磨砂底盘，背后的内容看不清。"
    static let skinTextureNeedsGlass = "清透和柔和需要 macOS 26。"
    static let skinAppearancePageCopy026 = "跟随系统外观的磨砂盘"
    static let skinAppearancePageCopy027 = "深空里的黑洞与星河"
    static let skinAppearancePageCopy028 = "会变形的一滴液态金属"
    static let skinAppearancePageCopy029 = "透光、折射的玻璃珠"
    static let skinAppearancePageCopy030 = "倒映着整个影棚的镜面铬球，箭头从球面凸起来"
    static let skinAppearancePageCopy031 = "一小块像素屏，点跟着声音一格一格跳"
    static let skinAppearancePageCopy032 = "玻璃珠里的彩色液滴"
    static let skinAppearancePageCopy033 = "引力透镜下的吸积盘"
    static let skinAppearancePageCopy034 = "一团细沙，声音把它震散，上推聚成三角"
    static let skinAppearancePageCopy035 = "一滴墨在慢慢洇开，上推被一笔提上去"
    static let skinAppearancePageCopy036 = "一颗肥皂泡，说话时冒小泡泡，发送时飘上去破开"
    static let skinAppearancePageCopy037 = "随声音窜动的火苗"
}


// Existing Skins/SkinEditorView.swift presentation, preserved while centralizing its copy.
extension SettingsStrings {
    static let skinEditorViewCopy001 = "说话中"
    static let skinEditorViewCopy009 = "预览马上变化，实际圆盘从下次出现起使用这个大小。"
    static let skinEditorViewCopy010 = "预设"
    static let skinEditorViewCopy011 = "自定义"
    static let skinEditorViewCopy012 = "恢复默认"
    static let skinEditorViewCopy014 = "没有可调的参数。"
}


// Existing Skins/SendSoundCards.swift presentation, preserved while centralizing its copy.
extension SettingsStrings {
    static let sendSoundCardsCopy001 = "发送音"
    static let sendSoundCardsCopy002 = "听到语音后，上推松手时播放。点一下就会选中并试听，立即生效。"
    static let sendSoundCardsCopy003 = "发送音："
    static let sendSoundCardsCopy005 = "点一下选中并试听"
}


// Existing ProviderSettingsWindow.swift presentation, preserved while centralizing its copy.
extension SettingsStrings {
    static let providerSettingsWindowCopy001 = "设置"
}

extension SettingsStrings {
    static let hapticStrength = "触感强度"
    static let hapticStandard = "标准"
    static let hapticStrong = "加强"
    static let hapticMax = "最强"
    static let hapticTry = "试一下"
    static let hapticMouseExplanation = "妙控鼠标没有触感马达，圆盘提示靠画面；需要的话可以开启提示音。"
}
