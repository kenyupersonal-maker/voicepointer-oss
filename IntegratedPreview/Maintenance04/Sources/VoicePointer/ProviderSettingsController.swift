import AppKit
import VoicePointerCore

@MainActor
final class ProviderSettingsController {

    let store: ProviderSettingsStore
    var onPreferencesChanged: (@MainActor (ProviderPreferences) -> Void)?
    var onInteractionChanged: (@MainActor (Bool) -> Void)?
    var onPermissionPageVisibilityChanged: (@MainActor (Bool) -> Void)?
    var onRecheck: (@MainActor () -> Void)?
    var onShowOnboarding: (@MainActor () -> Void)?

    private var window: ProviderSettingsWindow?
    private let credentials = CloudCredentialStore()
    private var states: [String: String] = [:]
    private var refreshTask: Task<Void, Never>?
    private var pendingLocalModel: LocalModelID?

    init(store: ProviderSettingsStore? = nil) throws {
        self.store = try store ?? ProviderSettingsStore(
            fileURL: IntegratedRuntimePaths.dataRoot.appendingPathComponent("provider-settings.json")
        )
        // 不在 init 写入配置；损坏的 store 直接抛错，不使用回退数据。
        OnlineAPIRuntime.shared.bind(store: self.store, changed: { [weak self] in
            guard let self else { return }; self.onPreferencesChanged?(self.store.value)
        })
    }

    func show() {
        SettingsLogicRuntime.shared.scheduleRefresh(selection: store.value.selection, trigger: .settingsOpened)
        if let existing = window {
            existing.showWindow(nil)
            refreshPresence { [weak self] in
                self?.window?.refreshAvailableStatuses()
            }
            return
        }
        refreshPresence { [weak self] in
            guard let self else { return }
            let settingsWindow = ProviderSettingsWindow(store: self.store, actions: self.makeActions())
            self.window = settingsWindow
            settingsWindow.showWindow(nil)
        }
    }

    func showVoicePage(online: Bool = false) {
        SettingsLogicRuntime.shared.scheduleRefresh(selection: store.value.selection, trigger: .settingsOpened)
        if let existing = window {
            existing.showWindow(nil)
            NotificationCenter.default.post(name: .voicePointerShowVoiceSettings, object: nil)
            if online { NotificationCenter.default.post(name: .voicePointerShowOnlineAPISettings, object: nil) }
            focusLocalModel()
            refreshPresence { [weak self] in self?.window?.refreshAvailableStatuses() }
            return
        }
        refreshPresence { [weak self] in
            guard let self else { return }
            let settingsWindow = ProviderSettingsWindow(store: self.store, actions: self.makeActions(), initialMethod: online ? .online : nil)
            self.window = settingsWindow
            settingsWindow.showWindow(nil)
            self.focusLocalModel()
        }
    }
    func showLocalModel(_ id: LocalModelID) {
        pendingLocalModel = id
        showVoicePage()
    }
    private func focusLocalModel() {
        guard let id = pendingLocalModel else { return }
        pendingLocalModel = nil
        Task { @MainActor in
            await Task.yield()
            NotificationCenter.default.post(name: .voicePointerShowLocalModelSettings, object: nil, userInfo: ["model": id.rawValue])
        }
    }

    /// Retained explicit General-page entry. The Settings menu opens Voice instead.
    func showGeneralPage() {
        SettingsLogicRuntime.shared.scheduleRefresh(selection: store.value.selection, trigger: .settingsOpened)
        if let existing = window {
            NotificationCenter.default.post(name: .voicePointerShowGeneralSettings, object: nil)
            existing.showWindow(nil)
            return
        }
        let settingsWindow = ProviderSettingsWindow(store: store, actions: makeActions(), initialPage: .general)
        window = settingsWindow
        settingsWindow.showWindow(nil)
    }

    func showAppearancePage() {
        SettingsLogicRuntime.shared.scheduleRefresh(selection: store.value.selection, trigger: .settingsOpened)
        if let existing = window {
            existing.showWindow(nil)
            NotificationCenter.default.post(name: .voicePointerShowAppearanceSettings, object: nil)
            refreshPresence { [weak self] in self?.window?.refreshAvailableStatuses() }
            return
        }
        refreshPresence { [weak self] in
            guard let self else { return }
            let settingsWindow = ProviderSettingsWindow(store: self.store, actions: self.makeActions())
            self.window = settingsWindow
            settingsWindow.showWindow(nil)
            NotificationCenter.default.post(name: .voicePointerShowAppearanceSettings, object: nil)
        }
    }

    // MARK: - Credential presence (attributes only, no secrets)

    private static let cloudProviders: [CloudCredentialProvider] = [.groq, .aliyunBeijing, .openai, .siliconflow]

    private static func provider(forRoute routeID: String) -> CloudCredentialProvider? {
        switch routeID {
        case "groq-v3", "groq-turbo":
            return .groq
        case "aliyun":
            return .aliyunBeijing
        case "openai-transcribe", "openai-mini-transcribe": return .openai
        case "siliconflow-sensevoice": return .siliconflow
        default:
            return nil
        }
    }

    private func refreshPresence(completion: @escaping () -> Void) {
        if refreshTask != nil { return }
        refreshTask = Task { [weak self] in
            await self?.readCredentialPresence()
            completion()
            self?.refreshTask = nil
        }
    }

    private func readCredentialPresence() async {
        for provider in Self.cloudProviders {
            do {
                states[provider.rawValue] = try await credentials.hasStoredCredentialFile(provider: provider) ? "已本机加密保存" : "请填写 API Key，仅需保存一次"
            } catch {
                states[provider.rawValue] = "本地密钥不可用，请重新保存"
            }
        }
    }

    // MARK: - Window actions

    private func makeActions() -> ProviderSettingsWindow.Actions {
        ProviderSettingsWindow.Actions(
            onSelectionChanged: { [weak self] in
                guard let self else { return }
                self.onPreferencesChanged?(self.store.value)
            },
            modelState: { routeID in
                VoiceNativeModelPreparation.status(routeID: routeID)
            },
            prepareModel: { routeID, language in
                try await VoiceNativeModelPreparation.prepare(routeID: routeID, language: language)
            },
            credentialState: { [weak self] routeID in
                guard let provider = Self.provider(forRoute: routeID) else {
                    return "非云端"
                }
                return self?.states[provider.rawValue] ?? "请填写 API Key，仅需保存一次"
            },
            onInteractionChanged: { [weak self] invalidatesSession in
                self?.onInteractionChanged?(invalidatesSession)
            },
            onRecheck: { [weak self] in self?.onRecheck?() },
            onShowOnboarding: { [weak self] in self?.onShowOnboarding?() },
            onPermissionPageVisibilityChanged: { [weak self] visible in
                self?.onPermissionPageVisibilityChanged?(visible)
            }
        )
    }
}
