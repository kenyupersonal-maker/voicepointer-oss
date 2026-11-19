import Foundation
import Speech

struct BetaProfile: Decodable, Sendable {
    let id: String
    let label: String
    let summary: String
    let backend: String
    let host: String?
    let correction: String
    let streaming_kind: String
    let max_seconds: Int
    let initial_seconds: Double
    let interval_seconds: Double
    let experimental: Bool
    let required_files: [String]
    let languages: [String]

    var isApple: Bool { host == "native" }
    var group: String {
        if id.hasPrefix("qwen06") { return "Qwen3-ASR 0.6B" }
        if id == "zipformer" || backend == "two_pass" { return "Zipformer" }
        return label
    }
    var modeLabel: String {
        if id == "qwen06-incremental" { return "社区增量 · 已知质量问题" }
        if correction == "sensevoice" { return "实时 + SenseVoice 分段复核" }
        if correction == "qwen17" { return "实时 + Qwen 1.7B 分段复核" }
        if streaming_kind == "rolling" { return "累计音频滚动重识别" }
        if streaming_kind == "offline" { return "停止后整段识别" }
        return "原生实时识别"
    }
    var warning: String {
        if id == "qwen06-incremental" {
            return "已知质量问题：公开样本仍出现碎片文本和无效输出。仅用于实验对照，不建议日常使用。"
        }
        if backend == "two_pass" {
            return "每 8 秒重听一段原音频。硬分段可能切断词句，质量收益尚未确认。"
        }
        if streaming_kind == "rolling" {
            return "草稿会随上下文改写。这是累计音频重识别，停止后请等待最终文本。"
        }
        if streaming_kind == "offline" { return "录音期间只显示真实音量，停止后生成整段文本。" }
        return "文字会随录音逐步出现，停止后生成最终文本。准确度仍需亲自试用。"
    }
    var languageChoices: [String] { isApple ? ["zh", "en", "yue"] : languages }
    var missingFiles: [String] {
        if ModelResourceLibrary.identifiers.contains(id) {
            return ModelResourceLibrary.current.isReady(id) ? [] : required_files
        }
        if id == "qwen06-incremental" { return ModelResourceLibrary.current.isReady("qwen06-rolling") ? [] : required_files }
        guard let root = IntegratedRuntimePaths.assetRoot else { return required_files }
        return required_files.filter { rel in
            // Defensive: reject absolute paths or any ".." component; treat as missing.
            if rel.hasPrefix("/") { return true }
            if rel.split(separator: "/").contains("..") { return true }
            return !FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path)
        }
    }
}

enum BetaCatalog {
    static func load() throws -> [BetaProfile] {
        guard let path = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Backend") else {
            throw TrialCoreError.invalid("CATALOG_RESOURCE_MISSING")
        }
        let profiles = try JSONDecoder().decode([BetaProfile].self, from: Data(contentsOf: path))
        guard Set(profiles.map(\.id)).count == profiles.count,
              profiles.contains(where: { $0.id == "qwen17-rolling" }),
              profiles.allSatisfy({ (1...60).contains($0.max_seconds) &&
                  $0.initial_seconds.isFinite && $0.initial_seconds >= 0 &&
                  $0.interval_seconds.isFinite && $0.interval_seconds >= 0 }) else {
            throw TrialCoreError.invalid("INVALID_BETA_CATALOG")
        }
        return profiles
    }
    static func locale(_ language: String) -> Locale {
        Locale(identifier: ["zh": "zh-CN", "en": "en-US", "yue": "yue-CN"][language] ?? "zh-CN")
    }
    static func languageLabel(_ language: String) -> String {
        ["auto": "自动 / 中英混合", "zh": "中文", "en": "English", "yue": "粤语"][language] ?? language
    }
    @MainActor
    @available(macOS 26.0, *)
    static func checkApple(_ language: String) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw TrialCoreError.invalid("此设备不支持 Apple SpeechTranscriber") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale(language)) else {
            throw TrialCoreError.invalid("系统不支持所选语言")
        }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [module])
        guard status == .installed else { throw TrialCoreError.invalid("本 Beta 的 Apple 资源尚未就绪（\(locale.identifier)：\(status)）") }
        return locale.identifier
    }
    @MainActor
    @available(macOS 26.0, *)
    static func installAppleResources(_ language: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale(language)) else {
            throw TrialCoreError.invalid("系统不支持所选语言")
        }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        _ = try await checkApple(language)
    }
    @MainActor
    @available(macOS 26.0, *)
    static func appleDiagnostics(_ language: String) async -> [String: String] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale(language)) else {
            return ["status": "unsupported"]
        }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return ["locale": locale.identifier, "status": String(describing: await AssetInventory.status(forModules: [module])),
                "installed_locales": await SpeechTranscriber.installedLocales.map(\.identifier).joined(separator: ","),
                "reserved_locales": await AssetInventory.reservedLocales.map(\.identifier).joined(separator: ","),
                "bundle_id": Bundle.main.bundleIdentifier ?? "unbundled"]
    }
}
