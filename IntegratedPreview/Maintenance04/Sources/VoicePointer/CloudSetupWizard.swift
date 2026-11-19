import AppKit
import SwiftUI
import VoicePointerCore

enum CloudWizardFixture { case none, preview, failure, practice }

@MainActor
struct CloudSetupWizard: View {
    let purpose: CloudEntryPurpose
    let providerStore: ProviderSettingsStore
    let logic: SettingsLogicRuntime
    let onSelectionChanged: () -> Void
    let close: (Bool) -> Void
    let savedCredentialEpoch: UUID?
    var chooseAnotherMethod: (() -> Void)? = nil
    var actionsFixture: CloudSetupFlow.Actions? = nil
    var fixture: CloudWizardFixture = .none
    @State private var step: Int
    @State private var quotaAcknowledged = false
    @State private var keyDraft = ""
    @State private var practiceText = ""
    @State private var note = ""
    @State private var noteIsError = true
    @State private var keyRecoveryAvailable = false
    @State private var offersSavedKeyReplacement = false
    @State private var replacingSavedCredential = false
    @State private var busy = false
    @State private var attempt = CloudSetupAttemptState()
    @State private var credentialIsCurrent: ((UUID) -> Bool)?
    @State private var task: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    init(purpose: CloudEntryPurpose, providerStore: ProviderSettingsStore, logic: SettingsLogicRuntime,
         onSelectionChanged: @escaping () -> Void, close: @escaping (Bool) -> Void,
         startStep: Int = 1, fixture: CloudWizardFixture = .none,
         actionsFixture: CloudSetupFlow.Actions? = nil,
         savedCredentialEpoch: UUID? = nil,
         chooseAnotherMethod: (() -> Void)? = nil) {
        self.purpose = purpose; self.providerStore = providerStore; self.logic = logic
        self.onSelectionChanged = onSelectionChanged; self.close = close
        self.fixture = fixture; self.actionsFixture = actionsFixture
        self.savedCredentialEpoch = savedCredentialEpoch
        self.chooseAnotherMethod = chooseAnotherMethod
        _step = State(initialValue: savedCredentialEpoch == nil ? min(4, max(1, startStep)) : 2)
        _note = State(initialValue: fixture == .failure ? "Key 无效或已过期。" : "")
        _keyRecoveryAvailable = State(initialValue: fixture == .failure)
        // Source-fixture presentation only: no credential, consent or runtime writes.
        _quotaAcknowledged = State(initialValue: fixture != .none && startStep >= 3)
        _keyDraft = State(initialValue: fixture != .none && startStep == 3 ? "sk-synthetic-placeholder" : "")
    }
    private var languageUnsupported: Bool { !CloudEntry.supportedLanguages.contains(providerStore.value.selection.language) }
    private var authenticated: Bool {
        if fixture == .practice { return true }
        return attempt.isAuthenticated(isCancelled: task?.isCancelled == true,
            credentialIsCurrent: { credentialIsCurrent?($0) == true })
    }
    private var enabled: Bool {
        if fixture == .practice { return true }
        return attempt.isEnabled(isCancelled: task?.isCancelled == true,
            credentialIsCurrent: { credentialIsCurrent?($0) == true })
    }
    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [OnboardingStyle.accent.opacity(colorScheme == .dark ? 0.20 : 0.13), .clear],
                           center: .top, startRadius: 0, endRadius: 280).frame(height: 160)
            VStack(spacing: 6) {
                if purpose == .route { HStack(spacing: 10) {
                    Label("权限", systemImage: "checkmark.circle.fill")
                    Text("—").foregroundStyle(.tertiary)
                    Label("选择方式", systemImage: "checkmark.circle.fill")
                    Text("—").foregroundStyle(.tertiary)
                    Label("完成配置", systemImage: "3.circle")
                }.font(.system(size: 12)).foregroundStyle(OnboardingStyle.accent).frame(height: 24)
                } else { Color.clear.frame(height: 24) }
                Text(replacingSavedCredential ? SettingsStrings.replaceSavedKeyTitle : savedCredentialEpoch != nil ? "重新确认免费额度用完即停" : purpose == .enhanceLocal ? "配置云端增强" : "配置阿里云识别")
                    .font(.system(size: 22, weight: .semibold)).padding(.top, 16)
                Text(replacingSavedCredential ? SettingsStrings.replaceSavedKeyDescription : savedCredentialEpoch != nil ? "验证已保存的 Key 后更新确认，保留当前识别方式与开关。" : purpose == .enhanceLocal ? "可选，约 3 分钟。本地先识别，阿里云帮你校对。"
                     : "在线识别由阿里云完成，声音会上传。免费额度用完即停。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: 560)
            }.padding(.top, 34)
            ScrollView {
                VStack(spacing: 0) {
                    if savedCredentialEpoch == nil { accordion(1, title: "创建 API Key", summary: "已复制") { createKey } }
                    accordion(2, title: "打开「免费额度用完即停」", summary: savedCredentialEpoch != nil && !authenticated ? "待验证后更新" : "已确认") { quotaStep }
                    accordion(3, title: savedCredentialEpoch != nil ? "验证已保存的 Key，更新确认" : "粘贴 Key，验证连接", summary: authenticated ? "连接正常 · 阿里云百炼" : "") { keyStep }
                    accordion(4, title: savedCredentialEpoch != nil ? "确认已更新" : "说一句话，看看效果", summary: "") {
                        if savedCredentialEpoch != nil {
                            Label(replacingSavedCredential ? SettingsStrings.replacedSavedKeyConfirmed : "30 天确认已更新，Key、识别方式与开关保持不变。", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12.5)).foregroundStyle(OnboardingStyle.accent)
                        } else { practiceStep }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
            }.scrollIndicators(.hidden).frame(width: 560, height: 344).padding(.top, 146)
            VStack(spacing: 0) {
                Spacer()
                Divider()
                HStack {
                    Button(savedCredentialEpoch != nil || purpose == .enhanceLocal ? "返回" : "稍后", action: finish)
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                        .accessibilityLabel(savedCredentialEpoch != nil || purpose == .enhanceLocal ? "返回" : "稍后")
                    if savedCredentialEpoch == nil, purpose == .route, let chooseAnotherMethod {
                        Button("换一种方式") { dismissAttempt(); chooseAnotherMethod() }
                            .buttonStyle(.plain).accessibilityLabel("换一种方式")
                    }
                    Spacer()
                    Button(primaryTitle, action: primaryAction).buttonStyle(.borderedProminent)
                        .controlSize(.large).frame(minWidth: 128)
                        .keyboardShortcut(.defaultAction).disabled(primaryDisabled)
                        .accessibilityLabel(primaryTitle)
                }.padding(.horizontal, 40).frame(height: 68).background(.bar)
            }
        }
        .frame(width: 640, height: 560).ignoresSafeArea().tint(OnboardingStyle.accent)
        .animation(reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.32), value: step)
        .onAppear { attempt.appear() }
        .background(CloudConnectionVisibilityGuard(onHidden: { dismissAttempt() }, onVisible: { attempt.appear() }))
        .onDisappear { dismissAttempt() }
        .onReceive(NotificationCenter.default.publisher(for: .voicePointerSettingsChanged)) { _ in
            if attempt.authorizedEpoch != nil && !authenticated {
                resetAttempt(); note = "凭据或配置已改变，请重新验证。"
                if step == 4 { step = 3 }
            }
        }
    }
    private func accordion<Content: View>(_ index: Int, title: String, summary: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if index <= step || (index == 4 && authenticated) {
                    if index < step { resetAttempt() }
                    step = index
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(index <= step ? OnboardingStyle.accent : Color.secondary.opacity(0.12))
                        if index < step && (index != 3 || authenticated) {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                        } else { Text("\(index)").font(.system(size: 13, weight: .semibold)) }
                    }.foregroundStyle(index <= step ? Color.white : Color.secondary).frame(width: 22, height: 22)
                    Text(title).font(.system(size: 13, weight: index == step ? .semibold : .medium))
                        .foregroundStyle(index > step ? .secondary : .primary)
                    Spacer()
                    if index < step && !summary.isEmpty { Text(summary).font(.system(size: 11)).foregroundStyle(OnboardingStyle.accent) }
                    Image(systemName: index == step ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.frame(height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(busy).accessibilityLabel(title)
            if step == index { content().padding(.leading, 31).padding(.bottom, 14).transition(.opacity) }
            if index < 4 { Divider() }
        }.padding(.horizontal, 14)
    }
    private var createKey: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1）打开下面的页面并登录；没有阿里云账号，就按提示注册")
            Text("地域必须是华北2（北京），Key 按地域独立。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("2）点「创建 API Key」，归属账号和业务空间保持默认，权限选「全部」")
            Text("3）点新 Key 旁边的复制图标。")
            HStack(spacing: 12) {
                link("打开 API Key 页面 ↗", CloudEntry.keyPageURL)
                link("官方图文说明 ↗", CloudEntry.keyHelpURL)
            }.padding(.top, 4)
        }.font(.system(size: 12.5)).foregroundStyle(.secondary)
    }
    private var quotaStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在免费额度页面找到语音识别模型 \(CloudEntry.modelID)，打开它右侧的「免费额度用完即停」开关，免得超出额度后扣费。")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                link("打开免费额度页面 ↗", CloudEntry.freeQuotaURL)
                link("控制台 ↗", CloudEntry.consoleURL)
            }
            Toggle("我已打开这个开关", isOn: $quotaAcknowledged).toggleStyle(.checkbox)
            if !quotaAcknowledged {
                Text(SettingsStrings.quotaRecommended).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12.5)).foregroundStyle(.secondary)
    }
    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            if savedCredentialEpoch != nil && !replacingSavedCredential {
                Label("使用已保存的 API Key，无需重新粘贴。", systemImage: "key.fill")
                    .accessibilityLabel("验证已保存的 API Key，不替换凭据")
            } else { HStack {
                SecureField("粘贴以 sk- 开头的 API Key", text: Binding(get: { keyDraft }, set: { updateKeyDraft($0) })).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("API Key")
                Button("从剪贴板粘贴") {
                    guard fixture == .none else { return }
                    if let value = NSPasteboard.general.string(forType: .string) {
                        updateKeyDraft(value.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }.buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("从剪贴板粘贴 API Key")
            } }
            if busy { HStack { ProgressView().controlSize(.small); Text(SettingsStrings.connectionVerifying) } }
            if !note.isEmpty {
                Label(note, systemImage: authenticated ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(authenticated ? OnboardingStyle.accent : noteIsError ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(savedCredentialEpoch != nil
                 ? "测试连接不发送声音。连接正常后更新 30 天确认。"
                 : purpose == .enhanceLocal
                 ? "Key 只加密保存在这台 Mac 上。测试连接不发送声音；开启后，声音会同时发给阿里云做增强，可在「设置 → 语音输入」关闭。"
                 : "Key 只加密保存在这台 Mac 上。测试连接不发送声音；开启后，在线识别的声音会上传到阿里云，可在「设置 → 语音输入」切换方式。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if languageUnsupported && savedCredentialEpoch == nil {
                HStack {
                    Text("当前语言不受阿里云支持；增强不会生效。").font(.system(size: 11)).foregroundStyle(.orange)
                    Button("改成自动") { changeLanguage() }.buttonStyle(.plain).foregroundStyle(OnboardingStyle.accent).accessibilityLabel("识别语言改成自动")
                }
            }
            if keyRecoveryAvailable {
                if offersSavedKeyReplacement {
                    Button(SettingsStrings.replaceRejectedSavedKey) { beginSavedKeyReplacement() }
                        .buttonStyle(.bordered).accessibilityLabel(SettingsStrings.replaceRejectedSavedKey)
                }
                link("回到 API Key 页面重新复制 ↗", CloudEntry.keyPageURL)
            }
        }.font(.system(size: 12.5))
    }
    private var practiceStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            PracticeInput(text: $practiceText, compact: true,
                placeholder: purpose == .enhanceLocal
                    ? (enabled ? "按住手势说一句话。这次会用「本地识别 + 阿里云增强」。" : "按住手势说一句话，试试本地识别；云端增强尚未开启。")
                    : "按住手势说一句话，试试在线识别。")
            Text("可以直接点「完成」，以后再试。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            // No existing bounded RAM result-pair source exists. Do not start
            // a new transcript collector or invent diagnostic success pills.
        }
    }
    private var primaryTitle: String {
        if savedCredentialEpoch != nil { return step < 3 ? "下一步" : step == 3 ? (replacingSavedCredential ? SettingsStrings.replaceSavedKeyAndVerify : "验证并更新确认") : "完成" }
        return step < 3 ? "下一步" : step == 3 ? (purpose == .enhanceLocal ? "验证并开启增强" : "验证并开启") : "完成"
    }
    private var primaryDisabled: Bool { busy || (step == 3 && (savedCredentialEpoch == nil || replacingSavedCredential) && keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    private func primaryAction() {
        if step < 3 { step += 1; return }
        if step == 4 { finish(); return }
        guard !busy, fixture == .none || actionsFixture != nil else { return }
        task?.cancel()
        let request = attempt.begin()
        credentialIsCurrent = nil
        busy = true; note = ""; noteIsError = true; keyRecoveryAvailable = false; offersSavedKeyReplacement = false
        let actions = actionsFixture ?? CloudSetupActions.flowActions(store: providerStore, logic: logic,
            onSelectionChanged: onSelectionChanged,
            isVisible: { attempt.isActive(request, isCancelled: Task.isCancelled) })
        credentialIsCurrent = actions.credentialIsCurrent
        let draft = keyDraft
        task = Task { @MainActor in
            let result: CloudSetupResult
            if savedCredentialEpoch != nil && replacingSavedCredential {
                result = await CloudSetupFlow.replaceSavedCredential(draft: draft,
                    quotaAcknowledged: quotaAcknowledged, actions: actions,
                    isVisible: { attempt.isActive(request, isCancelled: Task.isCancelled) })
            } else if let savedCredentialEpoch {
                result = await CloudSetupFlow.renewSavedCredential(credentialEpoch: savedCredentialEpoch,
                    quotaAcknowledged: quotaAcknowledged, actions: actions,
                    isVisible: { attempt.isActive(request, isCancelled: Task.isCancelled) })
            } else {
                result = await CloudSetupFlow.run(draft: draft, quotaAcknowledged: quotaAcknowledged,
                    purpose: purpose, actions: actions, enhancementLanguageSupported: !languageUnsupported,
                    isVisible: { attempt.isActive(request, isCancelled: Task.isCancelled) })
            }
            guard attempt.isActive(request, isCancelled: Task.isCancelled) else { return }
            busy = false
            guard attempt.accept(result, request: request, isCancelled: Task.isCancelled,
                credentialIsCurrent: actions.credentialIsCurrent) else {
                note = "凭据或配置已改变，请重新验证。"; return
            }
            switch result {
            case .renewed:
                guard authenticated else { return }
                note = replacingSavedCredential ? SettingsStrings.replacedSavedKeyConfirmed : "连接正常，30 天确认已更新。"
                step = 4
            case .enabled, .authenticatedWithoutEnhancement:
                guard authenticated else { return }
                note = enabled
                    ? CloudConnectionCheck.successMessage
                    : "连接正常。当前语言不受支持，增强没有开启；可改成自动后再配置增强。"
                do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                guard attempt.isActive(request, isCancelled: Task.isCancelled) else { return }
                guard authenticated else {
                    resetAttempt(); note = "凭据或配置已改变，请重新验证。"; return
                }
                step = 4
            case .invalidFormat: note = "Key 格式不对：应该以 sk- 开头，请重新复制。"
            case .capabilityMissing:
                noteIsError = false
                note = "暂时无法测试连接。请重新打开应用后再试。"
            case .notNetworkVerified:
                noteIsError = false
                note = SettingsStrings.connectionNotVerified
            case .connectionFailed(let failure):
                note = CloudConnectionVerificationFlow.failureMessage(failure)
                keyRecoveryAvailable = [.noKey, .keyUnreadable, .rejectedKey].contains(failure)
                offersSavedKeyReplacement = savedCredentialEpoch != nil && failure == .rejectedKey
            case .verificationFailed(let reason):
                note = failureText(reason)
                keyRecoveryAvailable = reason == .invalidKey || reason == .noKey
            case .confirmationFailed:
                note = savedCredentialEpoch != nil ? "确认没有更新，请重试；已保存的 Key、识别方式与开关未改变。" : "确认没有保存，请重试；上传和增强没有开启。"
            case .enableFailed: note = languageUnsupported ? "当前语言不受支持，增强没有开启。可改成自动后重试。" : "设置没有保存，云端保持关闭。"
            case .saveFailed: note = "Key 没有保存，请检查本机存储后重试。"
            case .cancelled: note = "凭据或配置已改变，请重新验证。"
            }
            task = nil
        }
    }
    private func resetAttempt() {
        invalidateConnectionIfNeeded()
        task?.cancel(); task = nil; attempt.begin(); credentialIsCurrent = nil
        busy = false; note = ""
    }
    private func beginSavedKeyReplacement() {
        guard savedCredentialEpoch != nil, offersSavedKeyReplacement else { return }
        resetAttempt()
        replacingSavedCredential = true; offersSavedKeyReplacement = false; keyDraft = ""
    }
    private func dismissAttempt() {
        invalidateConnectionIfNeeded()
        attempt.dismiss(); task?.cancel(); task = nil; credentialIsCurrent = nil
        busy = false; keyDraft = ""
    }
    private func finish() {
        // Recheck the authorized epoch before invalidating the visible attempt.
        let completed = enabled
        dismissAttempt()
        close(completed)
    }
    private func updateKeyDraft(_ value: String) {
        guard value != keyDraft else { return }
        resetAttempt(); keyDraft = value
    }
    private func invalidateConnectionIfNeeded() {
        if (task != nil || busy || attempt.authorizedEpoch != nil), fixture == .none, actionsFixture == nil {
            CloudEntryRuntime.shared.invalidateSetupAuthentication()
        }
    }
    private func failureText(_ reason: HealthFailureReason) -> String {
        switch reason {
        case .invalidKey, .noKey: return "Key 无效或已过期。请回到 API Key 页面重新复制。"
        case .network, .timeout: return "没连上阿里云，检查网络后重试。"
        default: return SettingsStrings.failure(reason)
        }
    }
    private func changeLanguage() {
        guard fixture == .none else { return }
        var preferences = providerStore.value
        guard let selection = try? VoiceInputSelection(mode: preferences.selection.mode,
            routeID: preferences.selection.routeID, language: "auto") else { return }
        preferences.selection = selection
        _ = CloudSetupActions.persist(preferences, store: providerStore, credentialAvailable: true, onSelectionChanged: onSelectionChanged)
    }
    private func link(_ title: String, _ url: String) -> some View {
        Button(title) { if fixture == .none, let address = URL(string: url) { NSWorkspace.shared.open(address) } }
            .buttonStyle(.plain).foregroundStyle(OnboardingStyle.accent).accessibilityLabel(title)
    }
}

/// Observe only the host window's visibility, without a global monitor. Closing,
/// minimizing or hiding it cancels its pending authentication transaction.
struct CloudConnectionVisibilityGuard: NSViewRepresentable {
    let onHidden: () -> Void
    var onVisible: () -> Void = {}
    func makeNSView(context: Context) -> ConnectionVisibilityView {
        let view = ConnectionVisibilityView(); view.onHidden = onHidden; view.onVisible = onVisible; return view
    }
    func updateNSView(_ nsView: ConnectionVisibilityView, context: Context) {
        nsView.onHidden = onHidden; nsView.onVisible = onVisible
    }
    final class ConnectionVisibilityView: NSView {
        var onHidden: (() -> Void)?
        var onVisible: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { onHidden?(); return }
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        @objc private func visibilityChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            if window.occlusionState.contains(.visible) { onVisible?() }
            else { onHidden?() }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
