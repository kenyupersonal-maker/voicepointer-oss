import Foundation

/// 公共本地模型准备门面。
/// 只检查外置资源库与包内运行环境，以及 Apple 系统语音资源准备。
/// 不启动 ASR 或麦克风，不做真实推理验证。
public enum VoiceNativeModelPreparation {

    // T4: these read-only checks consume the packaged catalog/manifest, not a second model whitelist.
    public static func localHealthFingerprint(routeID: String, hardware: SettingsHardwareInfo) -> String? {
        guard let spec = checkSpecification(routeID: routeID, hardware: hardware) else { return nil }
        return LocalModelHealthInspector.fingerprint(spec)
    }
    private static func checkSpecification(routeID: String, hardware: SettingsHardwareInfo) -> LocalModelCheckSpecification? {
        guard let id = LocalModelID(rawValue: routeID), let runtimeRoot = IntegratedRuntimePaths.assetRoot else { return nil }
        let library = ModelResourceLibrary.current
        guard library.isReady(routeID) else { return nil }
        return .init(id: id, root: library.root, files: library.integrityFiles(routeID), hardware: hardware,
            runtimeExecutable: URL(fileURLWithPath: BetaWorkerClient.pythonPath(root: runtimeRoot.path, profileID: routeID)), runtimeRoot: runtimeRoot)
    }
    public static func inspectLocalModel(routeID: String, hardware: SettingsHardwareInfo, force: Bool = false) async -> EngineHealthResult {
        guard let id = LocalModelID(rawValue: routeID) else { return .failed(.unavailable) }
        let library = ModelResourceLibrary.current
        guard let runtimeRoot = IntegratedRuntimePaths.assetRoot else { return .failed(.localLoadFailed) }
        guard (try? library.index()) != nil else { return .failed(.modelCorrupt) }
        guard library.entry(routeID) != nil else { return .failed(.modelNotDownloaded) }
        guard library.isReady(routeID) else { return .failed(.modelCorrupt) }
        return await LocalModelHealthInspector.check(.init(id: id, root: library.root, files: library.integrityFiles(routeID), hardware: hardware,
            runtimeExecutable: URL(fileURLWithPath: BetaWorkerClient.pythonPath(root: runtimeRoot.path, profileID: routeID)), runtimeRoot: runtimeRoot), force: force)
    }

    public static func localModelInventory(hardware: SettingsHardwareInfo) -> [LocalModelItem] {
        LocalModelID.allCases.map { id in
            let library = ModelResourceLibrary.current
            let entry = library.entry(id.rawValue)
            let size = entry?.files.reduce(UInt64(0)) { $0 + $1.bytes } ?? 0
            let state: LocalModelState = !hardware.supports(id) ? .notApplicable(reason: .hardwareUnsuitable)
                : entry == nil ? .notDownloaded : !library.isReady(id.rawValue) ? .corrupt : .needsVerification
            return .init(id: id, sizeBytes: size, recommended: id == .qwen17 ? hardware.supports(id) : !hardware.supports(.qwen17), state: state,
                         libraryInstalled: library.isReady(id.rawValue))
        }
    }

    /// Apple SpeechTranscriber runs one locale at a time. `auto` must not pass
    /// preparation only to fail when the microphone session starts.
    public static func isAppleLanguageSupported(_ language: String) -> Bool {
        language == "zh" || language == "en" || language == "yue"
    }

    public enum PreparationError: Error, Sendable {
        case unknownRoute
        case missingAssets
        case unsupportedLanguage
        case cloudRoute
    }

    private static let cloudRouteIDs = OnlineAPIConfiguration.cloudRouteIDs

    /// A conservative, side-effect-free gate for switching to a bundled local
    /// route. This proves only that the declared files and worker are present;
    /// it does not claim that recognition or the target editor was tested.
    public static func isLocalPrepared(routeID: String, language: String) -> Bool {
        guard !cloudRouteIDs.contains(routeID), routeID != "apple-speech",
              LocalModelID(rawValue: routeID) != nil, ModelResourceLibrary.current.isReady(routeID),
              let profile = try? availableAssets(routeID: routeID),
              !profile.isApple, profile.languages.contains(language),
              profile.missingFiles.isEmpty else { return false }
        return pythonRuntimeUsable(profileID: profile.id)
    }

    /// Whether the first-run primary action can do useful work for this route.
    /// Bundled local routes are actionable only when their selected language,
    /// files, and worker runtime are already present. Apple is actionable on
    /// macOS 26+ for a supported single language because its system assets can
    /// be prepared on demand. Cloud and unknown routes remain closed.
    public static func canStartPreparation(routeID: String, language: String) -> Bool {
        guard !cloudRouteIDs.contains(routeID) else { return false }
        guard let profile = try? availableAssets(routeID: routeID) else { return false }
        if profile.isApple {
            guard routeID == "apple-speech" else { return false }
            guard isAppleLanguageSupported(language) else { return false }
            if #available(macOS 26.0, *) { return true }
            return false
        }
        return isLocalPrepared(routeID: routeID, language: language)
    }

    /// 返回方案状态描述文本（不声明已验证识别）。
    public static func status(routeID: String) -> String {
        if cloudRouteIDs.contains(routeID) {
            return "云端方案"
        }
        if routeID == "apple-speech", #unavailable(macOS 26.0) {
            return "Apple 系统识别需要 macOS 26"
        }
        let matched: BetaProfile?
        do { matched = try availableAssets(routeID: routeID) }
        catch { return "模型目录未准备" }
        guard let profile = matched else {
            return "未找到方案"
        }
        if profile.isApple {
            return "系统语音资源，点击检查"
        }
        if !profile.missingFiles.isEmpty {
            return "资源库尚未准备该模型"
        }
        if !pythonRuntimeUsable(profileID: profile.id) {
            return "运行环境未准备"
        }
        return "资源库文件与运行环境已准备（启动时加载）"
    }

    /// 用户显式点击准备按钮时调用。
    /// Apple 路线下载系统资源；本地路线校验后直接返回；云端路线抛错。
    @MainActor
    public static func prepare(routeID: String, language: String) async throws {
        if cloudRouteIDs.contains(routeID) {
            throw PreparationError.cloudRoute
        }
        guard let profile = try availableAssets(routeID: routeID) else {
            throw PreparationError.unknownRoute
        }
        if profile.isApple {
            guard isAppleLanguageSupported(language) else {
                throw PreparationError.unsupportedLanguage
            }
            guard #available(macOS 26.0, *) else {
                throw PreparationError.missingAssets
            }
            try await BetaCatalog.installAppleResources(language)
            _ = try await BetaCatalog.checkApple(language)
            return
        }
        guard profile.languages.contains(language) else {
            throw PreparationError.unsupportedLanguage
        }
        guard ModelResourceLibrary.current.isReady(routeID), profile.missingFiles.isEmpty else {
            throw PreparationError.missingAssets
        }
        guard pythonRuntimeUsable(profileID: profile.id) else {
            throw PreparationError.missingAssets
        }
        // 已准备的资源库文件：直接返回；不把存在检查提升为真实识别验收。
    }

    /// 加载目录并匹配方案。返回 nil 表示目录可加载但方案未知；
    /// 加载失败抛错，未知方案返回 nil。
    static func availableAssets(routeID: String) throws -> BetaProfile? {
        let profiles = try BetaCatalog.load()
        return profiles.first { $0.id == routeID }
    }

    /// 检查 Python 运行路径存在、为常规可执行文件，且解析后仍在 assetRoot 内。
    private static func pythonRuntimeUsable(profileID: String) -> Bool {
        guard let assetRoot = IntegratedRuntimePaths.assetRoot else {
            return false
        }
        let rawPath = BetaWorkerClient.pythonPath(root: assetRoot.path, profileID: profileID)
        let fm = FileManager.default

        let canonical = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath()
        guard let attributes = try? fm.attributesOfItem(atPath: canonical.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              fm.isExecutableFile(atPath: canonical.path) else { return false }
        let rootPath = assetRoot.resolvingSymlinksInPath().path + "/"
        return canonical.path.hasPrefix(rootPath)
    }
}
