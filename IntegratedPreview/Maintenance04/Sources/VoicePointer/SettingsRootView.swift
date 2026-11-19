import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import VoicePointerCore

extension Notification.Name {
    static let voicePointerSettingsChanged = Notification.Name("VoicePointerSettingsChanged")
    static let voicePointerShowVoiceSettings = Notification.Name("VoicePointerShowVoiceSettings")
    static let voicePointerShowOnlineAPISettings = Notification.Name("VoicePointerShowOnlineAPISettings")
    static let voicePointerShowAppearanceSettings = Notification.Name("VoicePointerShowAppearanceSettings")
    static let voicePointerShowGeneralSettings = Notification.Name("VoicePointerShowGeneralSettings")
    static let voicePointerShowLocalModelSettings = Notification.Name("VoicePointerShowLocalModelSettings")
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case voice, appearance, gestures, lexicon, general, data, tip

    var id: String { rawValue }

    static let sidebarPages: [SettingsPage] = [.voice, .appearance, .gestures, .lexicon, .general, .data]
    /// Below the main pages, apart from them (2026-11-07: tip jar for the open-source release).
    static let supportPages: [SettingsPage] = [.tip]

    var title: String {
        switch self {
        case .voice: SettingsStrings.settingsRootViewCopy001
        case .appearance: SettingsStrings.settingsRootViewCopy002
        case .gestures: SettingsStrings.settingsRootViewCopy003
        case .lexicon: SettingsStrings.settingsRootViewCopy004
        case .general: SettingsStrings.settingsRootViewCopy005
        case .data: SettingsStrings.dataPageTitle
        case .tip: SettingsStrings.tipPageTitle
        }
    }

    var subtitle: String {
        switch self {
        case .voice: SettingsStrings.settingsRootViewCopy006
        case .appearance: SettingsStrings.settingsRootViewCopy007
        case .gestures: SettingsStrings.settingsRootViewCopy008
        case .lexicon: SettingsStrings.settingsRootViewCopy009
        case .general: SettingsStrings.settingsRootViewCopy010
        case .data: SettingsStrings.dataPageSubtitle
        case .tip: SettingsStrings.tipPageTitle
        }
    }

    var symbol: String {
        switch self {
        case .voice: "waveform"
        case .appearance: "tshirt"
        case .gestures: "hand.tap"
        case .lexicon: "character.book.closed"
        case .general: "gearshape"
        case .data: "externaldrive"
        case .tip: "mug"
        }
    }

    var tint: Color {
        switch self {
        case .voice: Color(red: 0.19, green: 0.73, blue: 0.40)
        case .appearance: Color(red: 0.60, green: 0.36, blue: 0.93)
        case .gestures: Color(red: 0.14, green: 0.49, blue: 0.98)
        case .lexicon: Color(red: 1.00, green: 0.57, blue: 0.10)
        case .general: Color(red: 0.54, green: 0.55, blue: 0.60)
        case .data: .secondary
        case .tip: .secondary
        }
    }
}

struct VoiceRouteOption: Identifiable, Hashable {
    let id: String
    let title: String

    var isCloud: Bool { Self.cloudRouteIDs.contains(id) }

    static let cloudRouteIDs = OnlineAPIConfiguration.cloudRouteIDs

    /// 引擎选择框只列现在能启用的方案。云端识别还没开放，不列出来。
    static var selectable: [VoiceRouteOption] { available.filter { !$0.isCloud } }

    static var available: [VoiceRouteOption] {
        let routes = [
            VoiceRouteOption(id: "qwen17-rolling", title: SettingsStrings.settingsRootViewCopy011),
            VoiceRouteOption(id: "qwen06-rolling", title: SettingsStrings.settingsRootViewCopy012),
            VoiceRouteOption(id: "apple-speech", title: SettingsStrings.settingsRootViewCopy013),
            VoiceRouteOption(id: "groq-v3", title: SettingsStrings.settingsRootViewCopy014),
            VoiceRouteOption(id: "groq-turbo", title: SettingsStrings.settingsRootViewCopy015),
            VoiceRouteOption(id: "aliyun", title: SettingsStrings.settingsRootViewCopy016),
            VoiceRouteOption(id: "openai-transcribe", title: OnlineAPIStrings.modelName("gpt-transcribe")),
            VoiceRouteOption(id: "openai-mini-transcribe", title: OnlineAPIStrings.modelName("gpt-4o-mini-transcribe"))
        ]
        if #available(macOS 26.0, *) { return routes }
        return routes.filter { $0.id != "apple-speech" }
    }
}

private struct RouteStatus: Equatable {
    /// ready = 绿（对应前置项已确认，不代表真实听写通过）；needsAttention = 橙；neutral = 灰。
    enum Tone: Equatable { case ready, needsAttention, failure, neutral }

    let text: String
    let tone: Tone
}

/// 所选识别方案现在能不能直接切过去。
private enum RouteReadiness: Equatable {
    case ready
    case needsApplePreparation
    case unavailable(String)
}

@MainActor
struct SettingsRootView: View {
    let providerStore: ProviderSettingsStore
    let modelState: (String) -> String
    let prepareModel: (String, String) async throws -> Void
    let credentialState: (String) -> String
    let onSelectionChanged: () -> Void
    let onInteractionChanged: (Bool) -> Void
    let onRecheck: () -> Void
    let onShowOnboarding: () -> Void
    let onPermissionPageVisibilityChanged: (Bool) -> Void

    @State private var page: SettingsPage? = .voice
    @Namespace private var sidebarHighlight
    @State private var refreshVersion = 0
    @State private var focusedLocalModel: LocalModelID?
    @State private var modelFocusTicket = 0
    @State private var localSettings: VoicePointerSettings
    /// 实际在用的识别方式（已保存）。卡片上的对勾只跟它走，不跟草稿走。
    @State private var savedMode: VoiceInputMode
    /// 用户正在看的识别方式。点了「本地识别」但方案还没准备好时，它和 savedMode 不同。
    @State private var draftMode: VoiceInputMode
    @State private var draftRouteID: String
    @State private var draftLanguage: String
    @State private var preparedAppleLanguage: String?
    @State private var voiceActionBusy = false
    @State private var voiceMessage = ""
    @State private var voiceMessageIsError = false
    @State private var loginSnapshot: LoginItemServiceSnapshot?
    @State private var loginBusy = false
    @State private var permissionRevision = 0
    // Default on (50%); AppStorage persists a drag immediately, without a Save button.
    @AppStorage(OutputVolumeController.enabledKey) private var outputDuckingEnabled = true
    @AppStorage(OutputVolumeController.ratioKey) private var outputDuckingRatio = 0.5
    @State private var localDeviceSummary = SettingsStrings.settingsRootViewCopy017
    @State private var diagnosticExport = DiagnosticExportViewModel()
    /// 阿里云识别入口。默认显示；旗标 cloud.entry.visible 明确设为 false 时才收起，这些保持默认，也不读密钥文件。
    @State private var cloudPage = CloudEntryPageState()
    /// 确认说明弹窗现在是哪一种：第一次、过期重新确认、暂停后恢复。
    @State private var cloudSheetKind: CloudConfirmationKind = .first
    /// 每次读云端入口的状态都加一；比它旧的读取结果不再采用。
    @State private var cloudRefreshGeneration = 0
    @State private var cloudSheetShown = false
    @State private var cloudSheetBusy = false
    @State private var cloudSheetNote = ""
    @State private var cloudNote = ""
    @State private var cloudKeySheetShown = false
    @State private var cloudKeyDraft = ""
    @State private var cloudKeySheetBusy = false
    @State private var cloudKeySheetNote = ""
    @State private var cloudRemoveAsked = false
    @State private var modelDownloadAsked = false
    @State private var pendingModelDownload: LocalModelID?
    @ObservedObject private var cloudRuntime = CloudEntryRuntime.shared
    @ObservedObject private var settingsLogic: SettingsLogicRuntime
    private let review: SettingsReviewContext?
    @State private var onlineLabelDraft = ""
    @State private var apiGuideShown = false
    @State private var keyFocusTicket = 0
    private var cloudTest: OnlineConnectionCheckState { cloudRuntime.connectionCheck.state }
    /// 每次测试、换 Key、移除 Key 都会加一；比它旧的测试结果不再显示。
    @State private var cloudTestGeneration = 0
    /// 删 Key 进行中：从点「删除」到删完、读回删除之后的状态为止。这期间阿里云卡、删除、编辑、测试连接都不能用，
    /// 否则删到一半点阿里云会把开关重新打开，删完就成了「选着阿里云 + 开关开 + 没有 Key」。
    @State private var cloudRemoving = false
    /// 确认说明弹窗每离开一次屏幕就加一（取消、确认完、切页、关窗都算，由弹窗自己的 onDisappear 记下）。处理中的
    /// 确认只在它没变时才替用户切换，不靠 SwiftUI 把 cloudSheetShown 写回 false。
    @State private var cloudSheetGeneration = 0
    /// 卡片、侧栏、确认行和「声音上传」行共用的「现在」，每 30 秒前进一次：同一时刻它们按同一个时间算，确认到期时一起变。
    @State private var cloudClock = Date()
    /// 「用于增强本地识别」存着的开关。真值在 CloudEntryPreferences 里，这里是给界面用的副本：每次写完、每次收到设置变更、
    /// 每次读云端入口的状态都重读一次，不靠它做任何「传不传」的决定。
    private var enhanceOn: Bool { settingsLogic.online.enhanceLocalWithOnlineAPI }
    /// 勾选框旁「？」的说明弹出框开没开。
    @State private var enhanceHelpShown = false
    /// 勾选框下面的一句提示：刚开了、刚关了、为什么没开成。换了识别方式等设置变更时清掉。
    @State private var enhanceNote = ""
    @State private var enhancementUploadAsked = false
    @State private var pendingEnhancementConfiguration: OnlineAPIConfiguration?
    @State private var enhancementActivationTask: Task<Void, Never>?
    /// 确认说明弹窗这次是为哪个用途问的：选用阿里云，还是勾选「用于增强本地识别」。和 cloudSheetKind 一起在弹窗打开前设好，
    /// 按下确认时先取当时的值，之后状态怎么变都不影响这次确认做什么。
    @State private var cloudSheetPurpose: CloudEntryPurpose = .route
    @State private var cloudWizardShown = false
    @ObservedObject private var onlineAPIRuntime = OnlineAPIRuntime.shared
    @State private var cloudWizardPurpose: CloudEntryPurpose = .route
    @State private var cloudWizardSavedEpoch: UUID?
    @State private var methodChoiceFocusTicket = 0
    @State private var cloudWizardStartStep = 1
    @State private var safeOnlineTestNote = ""
    @State private var connectionTestGeneration = UUID()
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var recognitionChoiceTask: Task<Void, Never>?
    /// 最近一次保存识别方式时顺手把「用于增强本地识别」关掉了（换了识别方式、引擎或语言）：调用方在提示后面带上一句，带过就清掉。
    @State private var enhanceClosedBySave = false

    init(
        providerStore: ProviderSettingsStore,
        modelState: @escaping (String) -> String,
        prepareModel: @escaping (String, String) async throws -> Void,
        credentialState: @escaping (String) -> String,
        onSelectionChanged: @escaping () -> Void,
        onInteractionChanged: @escaping (Bool) -> Void,
        onRecheck: @escaping () -> Void,
        onShowOnboarding: @escaping () -> Void,
        onPermissionPageVisibilityChanged: @escaping (Bool) -> Void = { _ in },
        review: SettingsReviewContext? = nil,
        initialMethod: RecognitionMethod? = nil,
        initialPage: SettingsPage? = nil
    ) {
        self.providerStore = providerStore
        self.modelState = modelState
        self.prepareModel = prepareModel
        self.credentialState = credentialState
        self.onSelectionChanged = onSelectionChanged
        self.onInteractionChanged = onInteractionChanged
        self.onRecheck = onRecheck
        self.onShowOnboarding = onShowOnboarding
        self.onPermissionPageVisibilityChanged = onPermissionPageVisibilityChanged
        self.review = review
        _settingsLogic = ObservedObject(wrappedValue: review?.logic ?? SettingsLogicRuntime.shared)
        _localSettings = State(initialValue: review == nil ? SettingsStore.shared.value : VoicePointerSettings())
        _page = State(initialValue: review?.page ?? initialPage ?? .voice)
        if let review {
            _cloudPage = State(initialValue: review.cloudPage)
            _onlineLabelDraft = State(initialValue: review.logic.online.userLabel ?? "")
            _loginSnapshot = State(initialValue: .init(desiredEnabled: false, systemState: .notRegistered,
                registeredBundleIdentity: nil, lastCheckedAt: Date(timeIntervalSince1970: 0), failureReason: nil))
        }
        let selection = providerStore.value.selection
        _savedMode = State(initialValue: selection.mode)
        _draftMode = State(initialValue: initialMethod == .online ? .voiceNative : selection.mode)
        _draftRouteID = State(initialValue: initialMethod == .online ? CloudEntry.routeID : selection.routeID)
        _draftLanguage = State(initialValue: selection.language)
    }

    private var pageOrder: [SettingsPage] { SettingsPage.sidebarPages + SettingsPage.supportPages }

    private func canStepPage(_ direction: Int) -> Bool {
        guard let index = pageOrder.firstIndex(of: page ?? .voice) else { return false }
        return pageOrder.indices.contains(index + direction)
    }

    private func stepPage(_ direction: Int) {
        guard let index = pageOrder.firstIndex(of: page ?? .voice), pageOrder.indices.contains(index + direction) else { return }
        open(pageOrder[index + direction])
    }

    /// Sidebar clicks switch pages with the shared page motion; other code that sets `page` stays instant.
    private func open(_ item: SettingsPage) {
        guard page != item else { return }
        withAnimation(SettingsMotion.slide) { page = item }
    }

    var body: some View {
        NavigationSplitView {
            // 2026-11-07 重做：线条图标；选中是浮起来的浅灰圆角块（像系统设置），打赏在分隔线下面单独一组。
            // A plain stack rather than a List: the grey selection block is one shape that slides from row to
            // row, as in the tip methods, instead of fading out on one row and in on the next (Ken, 2026-11-07).
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SettingsPage.sidebarPages) { item in
                        SettingsSidebarRow(page: item, selected: (page ?? .voice) == item, highlight: sidebarHighlight) {
                            open(item)
                        }
                    }
                    SettingsDivider()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    ForEach(SettingsPage.supportPages) { item in
                        SettingsSidebarRow(page: item, selected: page == item, highlight: sidebarHighlight) { open(item) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            // Scrolling over the sidebar walks the pages up and down (Ken, 2026-11-07).
            .background(SettingsWheelStepper(distance: 80, canStep: canStepPage, step: stepPage))
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 按共用的 cloudClock 算：阿里云的确认到期时，这一行和卡片、确认行一起变。
                routeFooter
                    .id(refreshVersion)
            }
        } detail: {
            ZStack {
            Group {
                switch page ?? .voice {
                case .voice:
                    voicePage
                case .appearance:
                    SkinAppearancePage()
                case .gestures:
                    gesturesPage
                case .lexicon:
                    LexiconSettingsPage(
                        lexicon: LexiconRuntime.shared,
                        providerStore: providerStore,
                        usesDoubao: savedMode == .doubao,
                        reviewFixture: review?.lexiconFixture
                    )
                case .general:
                    generalPage
                case .data:
                    DataSettingsPage(runtime: settingsLogic, review: review != nil)
                case .tip:
                    TipJarPage()
                }
            }
            .id(page ?? .voice)
            .transition(SettingsMotion.pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsPalette.page.ignoresSafeArea())
        }
        .navigationSplitViewStyle(.balanced)
        // Let native settings controls use the person's macOS accent color.
        // NSWindow owns the 780×560 minimum. A second 560-point body minimum
        // adds the title-bar safe area again and crops the sidebar footer.
        .frame(minWidth: 780)
        .onAppear { if review == nil { onPermissionPageVisibilityChanged(page == .general) } }
        .onChange(of: page) { _, newPage in
            if review == nil { onPermissionPageVisibilityChanged(newPage == .general) }
        }
        .onDisappear { if review == nil { onPermissionPageVisibilityChanged(false) } }
        .onReceive(NotificationCenter.default.publisher(for: .voicePointerSettingsChanged)) { _ in
            guard review == nil else { return }
            if !CloudEntryPreferences.load().visible { cancelOnlineConnectionTest() }
            reloadProviderDraft()
            refreshVersion += 1
            Task { await refreshCloudEntry() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voicePointerShowVoiceSettings)) { _ in
            page = .voice
        }
        .onReceive(NotificationCenter.default.publisher(for: .voicePointerShowOnlineAPISettings)) { _ in
            guard review == nil else { return }
            page = .voice; selectRecognition(.online)
        }
        .onReceive(NotificationCenter.default.publisher(for: .voicePointerShowLocalModelSettings)) { note in
            guard let value = note.userInfo?["model"] as? String, let id = LocalModelID(rawValue: value) else { return }
            page = .voice; focusedLocalModel = id; draftMode = .voiceNative; draftRouteID = id.rawValue
            modelFocusTicket += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .voicePointerShowAppearanceSettings)) { _ in
            page = .appearance
        }
        .onReceive(NotificationCenter.default.publisher(for: .voicePointerShowGeneralSettings)) { _ in
            page = .general
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard review == nil else { return }
            permissionRevision += 1
            Task { await refreshLogin() }
            Task { await refreshCloudEntry() }
        }
        .task { if review == nil { await refreshLogin() } }
        .task { if review == nil { await refreshCloudEntry(); onlineLabelDraft = settingsLogic.online.userLabel ?? "" } }
        .task { if review == nil { await settingsLogic.refresh(selection: providerStore.value.selection, trigger: .foreground) } }
        .onChange(of: draftMode) { _, _ in if review == nil { inspectDraftMethod() } }
        .onChange(of: draftRouteID) { _, _ in if review == nil { inspectDraftMethod() } }
        .task {
            guard review == nil else { return }
            // 共用的「现在」每 30 秒前进一次。只推时间、不重读闸门：重读要解开本机保存的 Key 文件，只在窗口回到
            // 前台和设置变更时做。
            while !Task.isCancelled {
                cloudClock = Date()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .task {
            guard review == nil else { return }
            let summary = await Task.detached(priority: .utility) {
                Self.readLocalDeviceSummary()
            }.value
            localDeviceSummary = summary
        }
    }

    // MARK: - Voice input
    //
    // 2026-09-29 Claude：识别方式改成「点了就生效」。
    // - 卡片上的对勾只表示实际在用的方式（savedMode），不再出现「卡片选中了、实际还是豆包」。
    // - 选引擎、选语言时，方案能用就直接切过去；不能用就在原地说明原因，当前方式不变。
    // - 去掉「启用所选方式」按钮。Apple 系统识别只保留一个「准备」按钮（要下载系统语音资源），准备好后自动切换。
    // 2026-10-01 Claude：识别方式并排三张卡——豆包、本地识别、阿里云（添加了 API 才出现）；下面跟着当前方式自己的
    // 细节（本地：引擎、语言、状态；阿里云：语言、用完即停确认），最后是「在线 API」一块（添加、测试连接、编辑、删除）。
    // 云端相关的开关不再各自摆出来，见下面「在线 API 与阿里云」。卡片、侧栏、确认行和「声音上传」行按同一个
    // cloudClock 每 30 秒重算一次，阿里云的确认到期时窗口开着也会一起变。
    // 2026-10-01 Claude（0.5.49）：云端入口的状态还没读回来时不当成「关着」：选着阿里云就只说「正在读取」，
    // 不摆本地识别的细节；删 Key 进行中阿里云卡和那一行按钮都不能点。
    // 2026-10-01 Claude（0.5.50）：「在线 API」里多了「用于增强本地识别」勾选框（见下面 MARK），勾了以后「本地识别」卡片和
    // 侧栏不再说「声音不上传」，改说声音也会发给阿里云；换识别方式、引擎、语言和删 Key 都会把它收回。

    // T5: three cards stay visible. Browsing a panel is separate from authorizing/saving a live route.
    private var displayedMethod: RecognitionMethod {
        if focusedLocalModel != nil { return .local }
        return draftMode == .doubao ? .doubao : VoiceRouteOption.cloudRouteIDs.contains(draftRouteID) ? .online : .local
    }
    private var presentation: RecognitionSettingsPresentation {
        .init(method: displayedMethod, installed: settingsLogic.doubao.installed,
              enabledInSystem: settingsLogic.doubao.enabledInSystem, models: settingsLogic.local.models,
              keySaved: settingsLogic.online.keySaved)
    }
    private var displayedHealth: EngineHealthState { settingsLogic.health.states[displayedMethod] ?? .idle }
    private var voicePage: some View {
        ScrollViewReader { reader in
            SettingsPageBody(SettingsPage.voice.title) {
                SettingsGroup(boxed: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(RecognitionMethod.allCases, id: \.rawValue) { method in
                            RecognitionCard(method: method, title: recognitionTitle(method), detail: recognitionDetail(method),
                                state: settingsLogic.health.states[method] ?? .idle, idle: idleTitle(method), selected: displayedMethod == method,
                                statusText: recognitionStatus(method)) {
                                selectRecognition(method)
                            }.frame(maxWidth: .infinity)
                        }
                    }.fixedSize(horizontal: false, vertical: true).id("recognition-choices")
                } header: {
                    Text(SettingsStrings.recognition)
                } footer: {
                    if displayedMethod == .doubao { Text(SettingsStrings.doubaoPrivateHint) }
                }

                switch displayedMethod {
                case .doubao: doubaoPanel
                case .local: localModelPanel
                case .online: onlinePanel
                }
                enhancementPanel
                MicrophoneSettingsSection()
                if review == nil { InlineDemotedApplicationsSection() }
            }
            // Switching the recognition method fades the panel and lets the groups below slide into place.
            .animation(SettingsMotion.page, value: displayedMethod)
            .onChange(of: keyFocusTicket) { _, _ in reader.scrollTo("online-key", anchor: .top) }
            .onChange(of: methodChoiceFocusTicket) { _, _ in reader.scrollTo("recognition-choices", anchor: .top) }
            .onChange(of: modelFocusTicket) { _, _ in
                if let id = focusedLocalModel { reader.scrollTo("model-" + id.rawValue, anchor: .center) }
            }
        }
        .sheet(isPresented: $cloudSheetShown) {
            OnlineAPIReconfirmationView(provider: onlineAPIRuntime.panel.configuration?.provider ?? .aliyunBailian,
                look: { if let provider = onlineAPIRuntime.panel.configuration?.provider, let url = URL(string: OnlineAPIPublicLinks.quota(provider)) { openURL(url) } },
                confirm: { try await onlineAPIRuntime.activate(purpose: cloudSheetPurpose == .route ? .route : .enhanceLocal, reconfirm: true); cloudSheetShown = false },
                disable: { try await onlineAPIRuntime.disable(purpose: cloudSheetPurpose == .route ? .route : .enhanceLocal); cloudSheetShown = false })
        }
        .sheet(isPresented: $cloudWizardShown) {
            OnlineAPISetupView(purpose: cloudWizardPurpose == .route ? .route : .enhanceLocal,
                context: .settings, start: cloudWizardStartStep == 0 ? .guide : .form,
                onFinish: { _ in cloudWizardShown = false; Task { await onlineAPIRuntime.refresh(); await refreshCloudEntry(); reloadProviderDraft() } },
                onCancel: { cloudWizardShown = false }, validator: onlineAPIRuntime.validator(), completion: onlineAPIRuntime.complete)
        }
        .sheet(isPresented: $apiGuideShown) {
            OnlineAPISetupView(purpose: .configure, context: .settings, start: .guide,
                onFinish: { _ in apiGuideShown = false; Task { await onlineAPIRuntime.refresh(); await refreshCloudEntry(); reloadProviderDraft() } }, onCancel: { apiGuideShown = false },
                validator: onlineAPIRuntime.validator(), completion: onlineAPIRuntime.complete)
        }
        .confirmationDialog(SettingsStrings.deleteKeyTitle, isPresented: $cloudRemoveAsked) {
            Button(SettingsStrings.delete, role: .destructive) {
                if review == nil { Task { do { try await onlineAPIRuntime.remove(); reloadProviderDraft() } catch { setMessage(OnlineAPIStrings.deleteFailed, error: true) } } }
            }
            Button(SettingsStrings.cancel, role: .cancel) {}
        } message: { Text(SettingsStrings.deleteKeyDetail) }
        .confirmationDialog(SettingsStrings.downloadConsentTitle, isPresented: $modelDownloadAsked) {
            Button(SettingsStrings.downloadConsentAction) {
                guard let id = pendingModelDownload, displayedMethod == .local, review == nil else { return }
                pendingModelDownload = nil
                settingsLogic.local.perform(.download, id: id, consent: true)
            }
        } message: { Text(SettingsStrings.downloadConsentDetail) }
        .confirmationDialog(CloudEnhanceWording.toggleTitle, isPresented: $enhancementUploadAsked) {
            Button(CloudEnhanceWording.uploadConsentAction) {
                guard let configuration = pendingEnhancementConfiguration,
                      providerStore.value.onlineAPIConfiguration == configuration else { return }
                pendingEnhancementConfiguration = nil
                activateEnhancement(configuration)
            }
            Button(SettingsStrings.cancel, role: .cancel) { pendingEnhancementConfiguration = nil }
        } message: {
            Text(CloudEnhanceWording.uploadConsentDetail(provider:
                pendingEnhancementConfiguration?.provider ?? enhancementProvider))
        }
    }
    private func recognitionTitle(_ method: RecognitionMethod) -> String {
        switch method { case .doubao: SettingsStrings.doubao; case .local: SettingsStrings.local
        case .online: SettingsStrings.onlineTitle(onlineAPIRuntime.panel.configuration.map { OnlineAPIStrings.providerName($0.provider) } ?? settingsLogic.online.displayName) }
    }
    private func recognitionDetail(_ method: RecognitionMethod) -> String {
        switch method { case .doubao: SettingsStrings.doubaoDetail
        case .local: settingsLogic.online.enhancement.isEffective(selection: providerStore.value.selection,
            configured: settingsLogic.online.isConfigured, provider: enhancementProvider)
            ? CloudEnhanceWording.localCardDetail(enhanceActive: true, status: cloudEntryStatus, provider: enhancementProvider)
            : SettingsStrings.localDetail
        case .online: SettingsStrings.onlineDetail }
    }
    private func recognitionStatus(_ method: RecognitionMethod) -> String {
        if method == .local, let id = LocalModelID(rawValue: draftRouteID), let model = settingsLogic.local.models.first(where: { $0.id == id }) {
            return SettingsStrings.localModelStatus(model.state)
        }
        return SettingsStrings.status(settingsLogic.health.states[method] ?? .idle, idle: idleTitle(method))
    }
    private func idleTitle(_ method: RecognitionMethod) -> String {
        switch method { case .doubao: settingsLogic.doubao.installed ? SettingsStrings.notChecked : SettingsStrings.notInstalled
        case .local: !settingsLogic.local.models.isEmpty && settingsLogic.local.models.allSatisfy { $0.state == .notDownloaded }
            ? SettingsStrings.notDownloaded : SettingsStrings.notChecked
        case .online: settingsLogic.online.keySaved ? HealthFailureReason.notNetworkVerified.message : SettingsStrings.notConfigured }
    }
    @ViewBuilder private var doubaoPanel: some View {
        if case .failed(let reason, let action) = displayedHealth {
            SettingsGroup {
                Text(SettingsStrings.failure(reason)).foregroundStyle(.secondary)
                Button(SettingsStrings.nextAction(action)) { performHealthAction(action) }
            }
        }
    }
    @ViewBuilder private var localModelPanel: some View {
        SettingsGroup(SettingsStrings.localModels) {
            Text(SettingsStrings.hardwareSummary(settingsLogic.local.hardware)).font(.caption).foregroundStyle(.secondary)
            Text(SettingsStrings.modelRecommendation(settingsLogic.local.hardware)).font(.callout).foregroundStyle(.secondary)
            if let error = settingsLogic.local.downloadError {
                Text(SettingsStrings.downloadFailure(error)).font(.caption).foregroundStyle(.orange)
            }
            ForEach(settingsLogic.local.models, id: \.id) { model in
                ModelRow(model: model, inUse: savedMode == .voiceNative && providerStore.value.selection.routeID == model.id.rawValue,
                    primaryDownload: !settingsLogic.local.models.allSatisfy({ $0.state == .notDownloaded }),
                    action: { performModelAction($0, id: model.id) },
                    verify: { if review == nil { settingsLogic.inspect(.local, routeID: model.id.rawValue, trigger: .recheck) } })
                    .id("model-" + model.id.rawValue)
                if model.state == .ready, model.offersOriginalRemoval, let bytes = model.originalDownloadBytes {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SettingsStrings.originalRemovalQuestion(bytes)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(SettingsStrings.removeOriginal) { performModelAction(.deleteOriginal, id: model.id) }
                            Button(SettingsStrings.keepOriginal) { performModelAction(.keepOriginal, id: model.id) }
                        }
                    }
                }
            }
            if #available(macOS 26.0, *) {
                Button {
                    guard review == nil else { return }
                    focusedLocalModel = nil
                    routeSelection.wrappedValue = "apple-speech"
                    if draftReadiness == .needsApplePreparation { prepareSelectedRoute() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: savedMode == .voiceNative && providerStore.value.selection.routeID == "apple-speech" ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SettingsStrings.appleModelName).font(.system(size: 13, weight: .semibold))
                            Text(SettingsStrings.appleModelDescription).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if savedMode == .voiceNative && providerStore.value.selection.routeID == "apple-speech" { Text(SettingsStrings.inUse).font(.caption) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if displayedMethod == .local {
                LabeledContent(SettingsStrings.language) {
                    Picker(SettingsStrings.language, selection: languageSelection) {
                        ForEach(languageOptions, id: \.tag) { option in Text(option.title).tag(option.tag) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }
    @ViewBuilder private var enhancementPanel: some View {
        SettingsGroup(SettingsStrings.settingsRootViewCopy005) {
            if settingsLogic.online.showsEnhancementSwitch {
                ToggleRow(title: SettingsStrings.onlineEnhancement, detail: CloudEnhanceWording.detail(provider: enhancementProvider),
                          help: CloudEnhanceWording.help(provider: enhancementProvider), isOn: enhanceBinding, icon: "sparkles")
            } else { GoConfigureRow(title: SettingsStrings.onlineEnhancement, icon: "sparkles") { browseOnlineConfiguration() } }
            if displayedMethod != .local {
                Text(SettingsStrings.enhancementLocalOnly).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, SettingsLayout.tileSize + 12)
            }
        }
    }
    @ViewBuilder private var onlinePanel: some View {
        SettingsGroup {
            OnlineAPISettingsPanel(snapshot: review == nil ? onlineAPIRuntime.panel : .empty,
                configure: { openCloudWizard(step: $0 == .guide ? 0 : 1) }, replace: { openCloudWizard(step: 1) },
                remove: { cloudRemoveAsked = true }, confirmQuota: onlineAPIRuntime.reconfirm, disableOnline: onlineAPIRuntime.disable,
                validateModel: onlineAPIRuntime.validateModel, commitModel: onlineAPIRuntime.commitModel,
                healthState: settingsLogic.health.states[.online] ?? .idle)
                .task { if review == nil { await onlineAPIRuntime.refresh() } }
            CheckStatusRow(state: settingsLogic.health.states[.online] ?? .idle, provider: settingsLogic.online.displayName,
                primaryAction: false, checking: settingsLogic.isChecking(.online), resultDetail: settingsLogic.healthDetail(.online),
                recheck: { if review == nil { settingsLogic.recheckOnline() } }, next: performHealthAction)
            if displayedMethod == .online {
                LabeledContent(SettingsStrings.language) {
                    Picker(SettingsStrings.language, selection: languageSelection) {
                        ForEach(cloudLanguageOptions, id: \.tag) { option in Text(option.title).tag(option.tag) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }
    private var onlineAudioUploadStatus: OnlineAudioUploadStatus {
        guard cloudPage.isLoaded, !cloudRemoving, !cloudRuntime.credentialChanging,
              cloudPage.credentialEpoch == cloudRuntime.settingsCredentialEpoch else { return .unknown }
        let preferences = CloudEntryPreferences.load()
        guard preferences.visible, cloudPage.isActive else { return .inactive }
        let status = cloudEntryStatus
        if enhancementProvider.isAliyun {
            guard status != .unavailable else { return .unknown }
            guard status.isUsable else { return .inactive }
        }
        guard preferences.uploadConsent else { return .inactive }
        if cloudRouteSelected, preferences.routeEnabled { return .onlineRecognition }
        if CloudEntry.canEnhance(providerStore.value.selection, provider: enhancementProvider), preferences.enhanceLocal {
            return .localEnhancement
        }
        return .inactive
    }
    private var connectionAuthenticated: Bool {
        guard cloudPage.isActive, !cloudRemoving, !cloudRuntime.credentialChanging,
              cloudPage.credentialEpoch == cloudRuntime.settingsCredentialEpoch else { return false }
        if case .passed = cloudTest { return true }
        return false
    }
    private var onlineConnectionTestNote: String {
        guard !cloudRuntime.credentialChanging,
              cloudPage.credentialEpoch == cloudRuntime.settingsCredentialEpoch else { return "" }
        switch cloudTest {
        case .passed: return CloudConnectionCheck.successMessage
        case .failed(let failure): return CloudConnectionVerificationFlow.failureMessage(failure)
        case .running: return SettingsStrings.connectionVerifying
        case .idle: return safeOnlineTestNote
        }
    }
    private func testSavedConnection() {
        guard review == nil, !cloudRemoving, connectionTestTask == nil else { return }
        let request = UUID(); connectionTestGeneration = request
        safeOnlineTestNote = SettingsStrings.connectionVerifying
        connectionTestTask = Task { @MainActor in
            let result = await CloudSetupActions.verifySavedConnection(isVisible: {
                connectionTestGeneration == request && !cloudRemoving
            })
            guard connectionTestGeneration == request, !Task.isCancelled else { return }
            connectionTestTask = nil
            switch result {
            case .authenticated, .connectionFailed: safeOnlineTestNote = ""
            case .notNetworkVerified: safeOnlineTestNote = SettingsStrings.connectionNotVerified
            case .failed(let reason): safeOnlineTestNote = SettingsStrings.failure(reason)
            }
        }
    }
    private func cancelOnlineConnectionTest() {
        guard connectionTestTask != nil else { return }
        connectionTestGeneration = UUID(); connectionTestTask?.cancel(); connectionTestTask = nil
        cloudRuntime.invalidateSetupAuthentication()
        safeOnlineTestNote = SettingsStrings.connectionValidationCancelled
    }
    private func openCloudWizard(step: Int, renewSaved: Bool = false) {
        guard review == nil, !cloudRemoving else { return }
        if renewSaved && (!cloudPage.isActive || cloudPage.credentialEpoch == nil) {
            safeOnlineTestNote = SettingsStrings.savedKeyNotReadyForRenewal
            return
        }
        cloudWizardPurpose = onlineAPIRuntime.purpose == .enhanceLocal ? .enhanceLocal : .route
        cloudWizardSavedEpoch = renewSaved ? cloudPage.credentialEpoch : nil
        cloudWizardStartStep = step; cloudWizardShown = true
    }
    private var onlinePanelAttention: String? {
        if cloudPage.key == .unreadable { return SettingsStrings.savedKeyUnreadableAttention }
        switch cloudEntryStatus {
        case .paused, .expired: return cloudEntryStatus.title()
        default: break
        }
        if case .failed(let reason, _) = displayedHealth, reason == .invalidKey { return SettingsStrings.savedKeyRejectedAttention }
        return nil
    }
    private var bundledGuideURL: URL {
        Bundle.main.url(forResource: SettingsStrings.apiGuideResource, withExtension: SettingsStrings.apiGuideExtension, subdirectory: "Help")
            ?? URL(fileURLWithPath: "/Help/APIKeyGuide.md")
    }
    private func openURL(_ url: URL) { if review == nil { NSWorkspace.shared.open(url) } }
    private func browseOnlineConfiguration() {
        apiGuideShown = true
    }
    private func selectRecognition(_ method: RecognitionMethod) {
        guard review == nil else { return }
        focusedLocalModel = nil
        recognitionChoiceTask?.cancel()
        if method == .online, providerStore.value.onlineAPIConfiguration == nil {
            keyFocusTicket += 1; openCloudWizard(step: 0); return
        }
        let route = method == .local ? localEngineID(for: providerStore.value.selection) : nil
        if method == .local {
            draftMode = .voiceNative
            draftRouteID = route ?? LocalModelID.qwen06.rawValue
        }
        recognitionChoiceTask = Task { @MainActor in
            guard await settingsLogic.prepareSelection(method, routeID: route), !Task.isCancelled else { return }
            commitRecognitionSelection(method)
        }
    }
    private func commitRecognitionSelection(_ method: RecognitionMethod) {
        switch method {
        case .doubao: chooseDoubao(); draftMode = .doubao
        case .local: chooseLocal(); draftMode = .voiceNative
            if VoiceRouteOption.cloudRouteIDs.contains(draftRouteID) { draftRouteID = localEngineID(for: providerStore.value.selection) }
        case .online:
            if let config = providerStore.value.onlineAPIConfiguration {
                Task { @MainActor in
                    do { try await onlineAPIRuntime.activate(purpose: .route); reloadProviderDraft() }
                    catch {
                        if config.provider.isAliyun, onlineAPIRuntime.panel.attention == .confirmationExpired {
                            openCloudConfirmSheet(.renew, purpose: .route)
                        }
                    }
                }
            }
        }
        inspectDraftMethod()
    }
    private func performHealthAction(_ action: HealthNextAction) {
        guard review == nil else { return }
        switch action {
        case .installDoubao: openURL(SettingsStrings.doubaoDocumentationURL)
        case .enableSystemInput: openURL(SettingsStrings.inputSourcesURL)
        case .configureAPI, .replaceKey: browseOnlineConfiguration()
        case .downloadRecommendedModel, .redownloadModel:
            performModelAction(.download, id: settingsLogic.local.hardware.supports(.qwen17) ? .qwen17 : .qwen06)
        case .use06B: routeSelection.wrappedValue = LocalModelID.qwen06.rawValue
        case .providerConsole: if let url = URL(string: CloudEntry.consoleURL) { openURL(url) }
        case .providerDocumentation: apiGuideShown = true
        case .retryNetwork, .recheck: settingsLogic.inspect(displayedMethod, routeID: draftRouteID, trigger: .recheck)
        }
    }
    // T10: explicit consent is shared by row/guide actions; use retains existing route admission.
    private func performModelAction(_ action: LocalModelAction, id: LocalModelID) {
        guard review == nil else { return }
        if action == .download { pendingModelDownload = id; modelDownloadAsked = true }
        else if action == .use {
            recognitionChoiceTask?.cancel()
            recognitionChoiceTask = Task { @MainActor in
                guard await settingsLogic.prepareSelection(.local, routeID: id.rawValue), !Task.isCancelled else { return }
                focusedLocalModel = nil
                draftMode = .voiceNative; draftRouteID = id.rawValue
                applyDraftIfReady()
            }
        }
        else { settingsLogic.local.perform(action, id: id) }
    }
    private func saveInlineKey() {
        guard review == nil, !cloudKeySheetBusy else { return }
        let key = cloudKeyDraft
        cloudKeySheetBusy = true; cloudKeySheetNote = ""
        Task { @MainActor in
            do {
                try await CloudSetupActions.saveKey(key, logic: settingsLogic, label: onlineLabelDraft)
                cloudKeyDraft = ""
                _ = await refreshCloudEntry()
                settingsLogic.inspect(.online, trigger: .configurationChanged)
            } catch CredentialError.invalidKey { cloudKeySheetNote = SettingsStrings.invalidKeyFormat }
            catch { cloudKeySheetNote = SettingsStrings.saveFailed }
            cloudKeySheetBusy = false
        }
    }

    nonisolated private static func readLocalDeviceSummary() -> String {
        #if arch(arm64)
        let chipFamily = "Apple Silicon"
        #elseif arch(x86_64)
        let chipFamily = "Intel"
        #else
        let chipFamily = SettingsStrings.settingsRootViewCopy018
        #endif

        let memory = ByteCountFormatter.string(
            fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
            countStyle: .memory
        )
        let freeDisk: String
        if let root = IntegratedRuntimePaths.assetRoot,
           let attributes = try? FileManager.default.attributesOfFileSystem(forPath: root.path),
           let bytes = attributes[.systemFreeSize] as? NSNumber {
            freeDisk = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
        } else {
            freeDisk = SettingsStrings.settingsRootViewCopy019
        }
        return SettingsStrings.settingsRootViewCopy020(chipFamily, memory, freeDisk)
    }

    private struct LanguageOption {
        let tag: String
        let title: String
    }

    private var routeOptions: [VoiceRouteOption] {
        var options = VoiceRouteOption.selectable
        if !options.contains(where: { $0.id == draftRouteID }) {
            let title = SettingsStrings.settingsRootViewCopy021(routeTitle(draftRouteID))
            options.insert(VoiceRouteOption(id: draftRouteID, title: title), at: 0)
        }
        return options
    }

    private var languageOptions: [LanguageOption] {
        var options = [
            LanguageOption(tag: "zh", title: SettingsStrings.settingsRootViewCopy022),
            LanguageOption(tag: "en", title: SettingsStrings.english),
            LanguageOption(tag: "yue", title: SettingsStrings.settingsRootViewCopy023)
        ]
        // Apple 系统识别一次只能认一种语言，不提供「自动」。
        if draftRouteID != "apple-speech" {
            options.insert(LanguageOption(tag: "auto", title: SettingsStrings.settingsRootViewCopy024), at: 0)
        }
        if !options.contains(where: { $0.tag == draftLanguage }) {
            options.insert(LanguageOption(tag: draftLanguage, title: SettingsStrings.settingsRootViewCopy025(draftLanguage)), at: 0)
        }
        return options
    }

    private var routeSelection: Binding<String> {
        Binding(
            get: { draftRouteID },
            set: { value in
                guard value != draftRouteID else { return }
                draftRouteID = value
                if value == "apple-speech",
                   !VoiceNativeModelPreparation.isAppleLanguageSupported(draftLanguage) {
                    draftLanguage = "zh"
                }
                applyDraftIfReady()
            }
        )
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { draftLanguage },
            set: { value in
                guard value != draftLanguage else { return }
                draftLanguage = value
                applyDraftIfReady()
            }
        )
    }

    private var draftReadiness: RouteReadiness {
        readiness(routeID: draftRouteID, language: draftLanguage)
    }

    /// 只做本机检查，不下载、不开麦、不启动识别。
    private func readiness(routeID: String, language: String) -> RouteReadiness {
        if routeID == CloudEntry.routeID {
            // 还没读回来不等于关着：先只说在读，不下结论。
            guard cloudPage.isLoaded else { return .unavailable(CloudEntryLine.loading) }
            if let reason = cloudEntryClosedReason { return .unavailable(reason) }
            // 云端路线不看本地模型文件；阿里云只认这三种语言。
            return CloudEntry.supportedLanguages.contains(language) ? .ready : .unavailable(SettingsStrings.settingsRootViewCopy026)
        }
        if VoiceRouteOption.cloudRouteIDs.contains(routeID) {
            return .unavailable(SettingsStrings.settingsRootViewCopy027)
        }
        if routeID == "apple-speech" {
            guard #available(macOS 26.0, *) else {
                return .unavailable(SettingsStrings.settingsRootViewCopy028)
            }
            guard VoiceNativeModelPreparation.isAppleLanguageSupported(language) else {
                return .unavailable(SettingsStrings.settingsRootViewCopy029)
            }
            if preparedAppleLanguage == language { return .ready }
            // 已保存的选择不证明系统资源仍安装；每次打开设置都要求重新检查。
            return .needsApplePreparation
        }
        guard isKnownRoute(routeID) else {
            return .unavailable(SettingsStrings.settingsRootViewCopy030)
        }
        if VoiceNativeModelPreparation.isLocalPrepared(routeID: routeID, language: language) {
            return .ready
        }
        let state = modelState(routeID)
        if state.hasPrefix(SettingsStrings.settingsRootViewCopy031) {
            return .unavailable(SettingsStrings.settingsRootViewCopy032)
        }
        return .unavailable(state)
    }

    private var draftStatus: RouteStatus {
        if voiceActionBusy {
            return RouteStatus(text: SettingsStrings.settingsRootViewCopy033, tone: .neutral)
        }
        switch draftReadiness {
        case .ready:
            let saved = providerStore.value.selection
            let inUse = savedMode == .voiceNative
                && saved.routeID == draftRouteID
                && saved.language == draftLanguage
            if draftRouteID == "apple-speech" {
                return RouteStatus(text: inUse ? SettingsStrings.settingsRootViewCopy034 : SettingsStrings.settingsRootViewCopy035, tone: .ready)
            }
            return RouteStatus(text: inUse ? SettingsStrings.settingsRootViewCopy036 : SettingsStrings.settingsRootViewCopy037, tone: .neutral)
        case .needsApplePreparation:
            return RouteStatus(text: SettingsStrings.settingsRootViewCopy038, tone: .needsAttention)
        case .unavailable(let reason):
            return RouteStatus(text: reason, tone: .needsAttention)
        }
    }

    /// 本地的识别引擎（不是云端的那几个）。
    private func isLocalRoute(_ id: String) -> Bool {
        isKnownRoute(id) && !VoiceRouteOption.cloudRouteIDs.contains(id)
    }

    /// 「本地识别」该用哪个引擎：选择里记的（是本地的话）；记的是云端路线，就用选阿里云之前记下的，再没有就是默认。
    private func localEngineID(for selection: VoiceInputSelection) -> String {
        if isLocalRoute(selection.routeID) { return selection.routeID }
        if let previous = CloudEntryPreferences.previousSelection(), isLocalRoute(previous.routeID) {
            return previous.routeID
        }
        return CloudEntry.localFallbackRouteID
    }

    /// 从阿里云回本地识别时用的引擎和语言：先试记着的那个，不行再试默认的千问 1.7B；都用不了返回 nil。
    /// 只做本机检查，不下载、不开麦。
    private func localReturnTarget() -> (routeID: String, language: String)? {
        let current = providerStore.value.selection
        var candidates = [localEngineID(for: current)]
        if !candidates.contains(CloudEntry.localFallbackRouteID) { candidates.append(CloudEntry.localFallbackRouteID) }
        for routeID in candidates {
            let language = routeID == "apple-speech" && !VoiceNativeModelPreparation.isAppleLanguageSupported(current.language)
                ? "zh" : current.language
            if readiness(routeID: routeID, language: language) == .ready {
                return (routeID, language)
            }
        }
        return nil
    }

    /// 阿里云这次听写用不了时，听写改走的本地路线（千问 1.7B）对当前语言准备好了没有。
    private var localFallbackReady: Bool {
        readiness(routeID: CloudEntry.localFallbackRouteID, language: providerStore.value.selection.language) == .ready
    }

    /// 本地识别是当前的方式：选的是应用自己的识别（不是豆包），而且不是「能用的阿里云」（阿里云路线用不了时，
    /// 听写实际走本地）。云端入口的状态还没读回来、选的又是阿里云时，先不在任何一张卡上打勾，读回来就有了。
    private var localRouteSelected: Bool {
        guard savedMode == .voiceNative, !cloudRouteSelected else { return false }
        if !cloudPage.isLoaded, providerStore.value.selection.routeID == CloudEntry.routeID { return false }
        return true
    }

    /// 「本地识别」卡片上的状态。说的都是点下去或实际会用到的引擎：选着用不了的阿里云时听写走回退路线
    /// （千问 1.7B），从阿里云点回来落到 `localReturnTarget()` 挑的那个。
    private func chooseLocal() {
        cloudNote = ""
        let current = providerStore.value.selection
        if current.mode == .voiceNative, isLocalRoute(current.routeID) {
            draftMode = .voiceNative
            setMessage("")
            return
        }
        let wanted = localEngineID(for: current)
        if current.mode == .voiceNative {
            guard let title = leaveCloudRoute(toDoubao: false) else { return }  // 存不下来时已提示
            let landed = providerStore.value.selection
            if readiness(routeID: landed.routeID, language: landed.language) != .ready {
                setMessage(SettingsStrings.settingsRootViewCopy039(title), error: true)
            } else if landed.routeID != wanted {
                let why = wanted == "apple-speech" ? SettingsStrings.settingsRootViewCopy040 : SettingsStrings.settingsRootViewCopy041
                setMessage(SettingsStrings.settingsRootViewCopy042(title, shortRouteTitle(wanted), why))
            } else {
                setMessage(SettingsStrings.settingsRootViewCopy043(title))
            }
            return
        }
        // 从豆包过来。
        draftMode = .voiceNative
        draftRouteID = wanted
        if wanted == "apple-speech", !VoiceNativeModelPreparation.isAppleLanguageSupported(draftLanguage) {
            draftLanguage = "zh"
        }
        applyDraftIfReady()
    }

    private static var isDoubaoInstalled: Bool {
        let bundleID = "com.bytedance.inputmethod.doubaoime"
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            URL(fileURLWithPath: "/Library/Input Methods/DoubaoIme.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Input Methods/DoubaoIme.app")
        ].compactMap { $0 }
        return candidates.contains { Bundle(url: $0)?.bundleIdentifier == bundleID }
    }

    private func setMessage(_ text: String, error: Bool = false) {
        voiceMessage = text
        voiceMessageIsError = error
    }

    private func chooseDoubao() {
        guard var selection = VoiceInputSelectionTransition.selectingDoubao(
            from: providerStore.value.selection,
            isInstalled: Self.isDoubaoInstalled
        ) else {
            reloadProviderDraft()
            setMessage(SettingsStrings.settingsRootViewCopy044, error: true)
            return
        }
        draftMode = .doubao
        guard savedMode != .doubao else {
            setMessage(SettingsStrings.settingsRootViewCopy045)
            return
        }
        selection.routeID = localEngineID(for: providerStore.value.selection)  // 豆包下面不留云端路线
        var preferences = providerStore.value
        preferences.selection = selection
        if saveProviderPreferences(preferences) {
            setMessage(withEnhanceClosedNote(SettingsStrings.settingsRootViewCopy046))
        }
    }

    /// 选了引擎或语言：能用就直接切过去；不能用就说明原因，当前方式不变。
    private func applyDraftIfReady() {
        guard draftMode == .voiceNative else { return }
        switch draftReadiness {
        case .ready:
            let saved = providerStore.value.selection
            if savedMode == .voiceNative, saved.routeID == draftRouteID, saved.language == draftLanguage {
                setMessage("")
                return
            }
            activateSelectedRoute()
        case .needsApplePreparation:
            setMessage(SettingsStrings.settingsRootViewCopy047, error: true)
        case .unavailable(let reason):
            setMessage(SettingsStrings.settingsRootViewCopy048(reason, currentRouteTitle), error: true)
        }
    }

    /// 只给 Apple 系统识别用：核对系统资源，缺少时按需下载，成功后自动切换。
    private func prepareSelectedRoute() {
        guard !voiceActionBusy, draftRouteID == "apple-speech" else { return }
        guard VoiceNativeModelPreparation.isAppleLanguageSupported(draftLanguage) else {
            setMessage(SettingsStrings.settingsRootViewCopy049, error: true)
            return
        }
        let routeID = draftRouteID
        let language = draftLanguage
        voiceActionBusy = true
        setMessage(SettingsStrings.settingsRootViewCopy033)
        Task { @MainActor in
            do {
                try await prepareModel(routeID, language)
                preparedAppleLanguage = language
                voiceActionBusy = false
                if routeID == draftRouteID, language == draftLanguage, draftMode == .voiceNative {
                    activateSelectedRoute()
                } else {
                    setMessage(SettingsStrings.settingsRootViewCopy051)
                }
            } catch {
                voiceActionBusy = false
                if routeID == draftRouteID {
                    setMessage(SettingsStrings.settingsRootViewCopy052, error: true)
                }
            }
        }
    }

    private func activateSelectedRoute() {
        guard !voiceActionBusy, draftReadiness == .ready else { return }
        guard let selection = try? VoiceInputSelection(
            mode: .voiceNative,
            routeID: draftRouteID,
            language: draftLanguage
        ) else {
            setMessage(SettingsStrings.settingsRootViewCopy053(currentRouteTitle), error: true)
            return
        }
        var preferences = providerStore.value
        preferences.selection = selection
        let title = routeTitle(draftRouteID)
        let sameRoute = savedMode == .voiceNative && providerStore.value.selection.routeID == draftRouteID
        if saveProviderPreferences(preferences) {
            draftMode = .voiceNative
            setMessage(withEnhanceClosedNote(
                sameRoute ? SettingsStrings.settingsRootViewCopy054 : SettingsStrings.settingsRootViewCopy055(title)
            ))
        }
    }

    /// 存下新的选择。先把新选择用不上的云端开关收回（阿里云的「使用」、「用于增强本地识别」、没人用的「允许上传」），
    /// 统一走 CloudEntryPreferences.reconcile：声音只在用户明确选的用法下才会发出去。先收回再存，存不下来时也已经收回了。
    /// `cloudSwitchesTouched`：调用方存之前已经动过阿里云的开关（选用时打开、离开时收回），存不下来时开关也都是关着的
    /// （选用失败由调用方关上），提示就不能说「已恢复原来的设置」。顺手关掉了增强的话，成功后 enhanceClosedBySave 为真。
    @discardableResult
    private func saveProviderPreferences(_ preferences: ProviderPreferences, cloudSwitchesTouched: Bool = false) -> Bool {
        enhanceClosedBySave = false
        let result = CloudSetupActions.persist(preferences, store: providerStore,
            credentialAvailable: cloudPage.isLoaded ? cloudPage.key == .saved : true,
            onSelectionChanged: onSelectionChanged, onPersisted: { enhanceClosedBySave = $0 })
        reloadProviderDraft()
        if result.saved { return true }
        setMessage(result.revoked || cloudSwitchesTouched ? CloudEntryLine.saveFailedCloudOff : SettingsStrings.settingsRootViewCopy056, error: true)
        return false
    }

    private func reloadProviderDraft() {
        let selection = providerStore.value.selection
        // 识别方式、引擎或语言变了，勾选框下面旧的提示就不再对：清掉，开关的真值重读一遍。
        settingsLogic.online.enhancement.synchronize()
        enhanceNote = ""
        savedMode = selection.mode
        draftMode = selection.mode
        draftRouteID = selection.routeID
        draftLanguage = selection.language
        // A menu download target changes only the visible draft, never the saved route.
        if let focusedLocalModel {
            draftMode = .voiceNative
            draftRouteID = focusedLocalModel.rawValue
        }
    }

    private func isKnownRoute(_ id: String) -> Bool {
        VoiceRouteOption.available.contains(where: { $0.id == id })
    }

    private func shortRouteTitle(_ id: String) -> String {
        switch id {
        case "qwen17-rolling": SettingsStrings.settingsRootViewCopy057
        case "qwen06-rolling": SettingsStrings.settingsRootViewCopy058
        case "apple-speech": SettingsStrings.settingsRootViewCopy013
        default: routeTitle(id)
        }
    }

    private var routeFooter: some View {
        let status = currentRouteStatus
        return VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(status.tone.color)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentRouteTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(status.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// 下次开始说话实际用的方式。选着阿里云、但开始时闸门会拒绝的话，听写走回退的千问 1.7B，就写它；它也没
    /// 准备好（这次听写会失败）或阿里云的状态还没读回来时，仍写阿里云。
    private var currentRouteTitle: String {
        let selection = providerStore.value.selection
        if selection.mode == .doubao { return SettingsStrings.doubao }
        if VoiceRouteOption.cloudRouteIDs.contains(selection.routeID) { return SettingsStrings.onlineTitle(onlineAPIRuntime.panel.configuration.map { OnlineAPIStrings.providerName($0.provider) } ?? settingsLogic.online.displayName) }
        if cloudDeniedAtStart, localFallbackReady { return routeTitle(CloudEntry.localFallbackRouteID) }
        return routeTitle(selection.routeID)
    }

    /// 这里只报告授权与配置准备情况，不代表监听正在运行或实机听写已验证。
    private var currentRouteStatus: RouteStatus {
        let selection = providerStore.value.selection
        let method: RecognitionMethod = selection.mode == .doubao ? .doubao : VoiceRouteOption.cloudRouteIDs.contains(selection.routeID) ? .online : .local
        let state = settingsLogic.health.states[method] ?? .idle
        let tone: RouteStatus.Tone
        switch state { case .passed: tone = .ready; case .failed: tone = .failure; case .idle, .checking: tone = .neutral }
        return .init(text: settingsLogic.healthDetail(method), tone: tone)
    }

    private func routeTitle(_ id: String) -> String {
        switch id {
        case "qwen17-rolling": SettingsStrings.settingsRootViewCopy060
        case "qwen06-rolling": SettingsStrings.settingsRootViewCopy061
        case "apple-speech": SettingsStrings.settingsRootViewCopy013
        case "aliyun": SettingsStrings.settingsRootViewCopy063
        case "groq-v3": "Groq v3"
        case "groq-turbo": "Groq Turbo"
        default: SettingsStrings.settingsRootViewCopy064(id)
        }
    }

    // MARK: - 在线 API 与阿里云
    //
    // 2026-10-01 Claude：云端的东西分两处放。「在线 API」管 Key（添加、测试连接、编辑、删除）；「识别方式」里的
    // 阿里云卡片管用不用它，Key 保存后卡片才出现。点卡片就是选用：有效的确认在，直接切；没有，弹一个说明，
    // 一个按钮完成「确认 + 允许上传 + 切换」。离开阿里云（点别的卡片、删除 API）时，「使用」和「允许上传」
    // 两个开关一起收回：声音只在选着阿里云的时候才会发出去，回到别的方式再选回来，又是一次明确的选择。
    // 应用查不到用户在阿里云控制台的「免费额度用完即停」开关，所以只能记下「用户已确认」（30 天内有效），
    // 从不写「已核实」，界面也不承诺一定不产生费用。旗标 cloud.entry.visible 明确设为 false 时整段收起。
    // 每次听写是否真的上传，仍由 K06 闸门逐次决定；这里只是把闸门要的几样东西按人的话摆出来。
    // 文案只说实际会发生的事：开始说话时闸门拒绝（没确认、过期、暂停），这次改用本地识别（千问 1.7B），它也没
    // 准备好时这次听写会失败，所以只在它准备好时才说「现在用本机」；已经开始之后断网、Key 失效或额度用完，
    // 这一次听写会失败，不会中途换成本地。切换、提示用的短句放在 CloudEntryWording，由自测逐条核对。

    /// 当前选中的正是阿里云路线，而且云端入口开着（旗标打开且已保存 Key）。
    private var cloudRouteSelected: Bool {
        cloudPage.isActive
            && savedMode == .voiceNative
            && providerStore.value.selection.routeID == CloudEntry.routeID
    }

    /// 画面上用的阿里云状态，按共用的 cloudClock 算，卡片、侧栏、确认行、「声音上传」行同一时刻说的一致。
    /// 点卡片时的决定不用它，按点下去那一刻重新算（见 chooseCloud）。
    private var cloudEntryStatus: CloudEntryStatus {
        CloudEntryStatus(snapshot: cloudPage.snapshot, now: cloudClock)
    }

    /// 阿里云的两个开关（使用、允许上传）都开着。再加上有效的确认，才是真的在用云端。
    private var cloudSwitchesOn: Bool {
        let preferences = CloudEntryPreferences.load()
        return preferences.routeEnabled && preferences.uploadConsent
    }

    private var cloudLanguageSupported: Bool {
        CloudEntry.supportedLanguages.contains(providerStore.value.selection.language)
    }

    /// 云端入口用不了的原因（入口被关闭、没有 Key、Key 读不出来）；能用时是 nil。只在读回来之后有意义。
    private var cloudEntryClosedReason: String? {
        guard !cloudPage.isActive else { return nil }
        guard cloudPage.isVisible else { return SettingsStrings.settingsRootViewCopy065 }
        return cloudPage.key == .unreadable ? SettingsStrings.settingsRootViewCopy066 : SettingsStrings.settingsRootViewCopy067
    }

    /// 选着阿里云、状态已读回来，而且开始说话时闸门会拒绝（入口关着、没 Key、没确认、过期、暂停、开关没开）：
    /// 这次听写改走千问 1.7B。
    private var cloudDeniedAtStart: Bool {
        guard savedMode == .voiceNative, providerStore.value.selection.routeID == CloudEntry.routeID,
              cloudPage.isLoaded else { return false }
        return cloudEntryClosedReason != nil || !(cloudEntryStatus.isUsable && cloudSwitchesOn)
    }

    /// 选着阿里云时侧栏那一行：还没读回来只说在读；用得上就说会上传；用不上就说原因——千问 1.7B 也没准备好时
    /// 说两边都用不了，不说「现在用本机」。
    private var cloudSidebarStatus: RouteStatus {
        guard cloudPage.isLoaded else { return RouteStatus(text: CloudEntryLine.loading, tone: .neutral) }
        if let reason = cloudEntryClosedReason {
            return RouteStatus(
                text: localFallbackReady ? SettingsStrings.settingsRootViewCopy068(reason) : CloudEntryLine.nothingReady,
                tone: .needsAttention
            )
        }
        guard cloudLanguageSupported else {
            return RouteStatus(text: SettingsStrings.settingsRootViewCopy026, tone: .needsAttention)
        }
        let running = cloudEntryStatus.isUsable && cloudSwitchesOn
        return RouteStatus(
            text: cloudEntryStatus.footerText(switchesOn: cloudSwitchesOn, localFallbackReady: localFallbackReady),
            tone: running ? .neutral : .needsAttention
        )
    }

    private func routeStatus(_ summary: CloudEntrySummary) -> RouteStatus {
        switch summary.tone {
        case .ready: RouteStatus(text: summary.text, tone: .ready)
        case .attention: RouteStatus(text: summary.text, tone: .needsAttention)
        case .neutral: RouteStatus(text: summary.text, tone: .neutral)
        }
    }

    private var cloudCardStatus: RouteStatus {
        if cloudRemoving { return RouteStatus(text: SettingsStrings.settingsRootViewCopy070, tone: .neutral) }
        if !cloudRouteSelected, !cloudLanguageSupported {
            return RouteStatus(text: SettingsStrings.settingsRootViewCopy071, tone: .needsAttention)
        }
        return routeStatus(cloudEntryStatus.cardSummary(
            selected: cloudRouteSelected, switchesOn: cloudSwitchesOn, localFallbackReady: localFallbackReady
        ))
    }

    private var cloudTestStatus: RouteStatus {
        switch cloudTest {
        case .idle: RouteStatus(text: SettingsStrings.settingsRootViewCopy072, tone: .neutral)
        case .running: RouteStatus(text: SettingsStrings.settingsRootViewCopy073, tone: .neutral)
        case .passed(let date):
            RouteStatus(text: SettingsStrings.settingsRootViewCopy074(date.formatted(date: .omitted, time: .shortened)), tone: .ready)
        case .failed: RouteStatus(text: SettingsStrings.settingsRootViewCopy075, tone: .needsAttention)
        }
    }

    /// 「在线 API」里阿里云这一行右上角的状态。
    private var cloudAPIStatus: RouteStatus {
        if cloudRemoving { return RouteStatus(text: SettingsStrings.deletingKey, tone: .neutral) }
        switch cloudPage.key {
        case .missing: return RouteStatus(text: SettingsStrings.settingsRootViewCopy077, tone: .neutral)
        case .unreadable: return RouteStatus(text: SettingsStrings.settingsRootViewCopy078, tone: .needsAttention)
        case .saved: return cloudTestStatus
        }
    }

    /// 测试结果的一句话说明；没测过或正在测时不显示。
    private var cloudTestMessage: (text: String, isError: Bool)? {
        switch cloudTest {
        case .idle, .running: nil
        case .passed: (CloudConnectionCheck.successMessage, false)
        case .failed(let failure): (CloudConnectionVerificationFlow.failureMessage(failure), true)
        }
    }

    private var apiFooterText: String {
        guard cloudPage.isLoaded else { return "" }
        guard cloudPage.isVisible else { return SettingsStrings.settingsRootViewCopy079 }
        switch cloudPage.key {
        case .missing: return SettingsStrings.settingsRootViewCopy080
        case .saved: return SettingsStrings.settingsRootViewCopy081
        case .unreadable: return SettingsStrings.settingsRootViewCopy082
        }
    }

    /// 阿里云只认这三种语言。
    private var cloudLanguageOptions: [LanguageOption] {
        [
            LanguageOption(tag: "auto", title: SettingsStrings.settingsRootViewCopy024),
            LanguageOption(tag: "zh", title: SettingsStrings.settingsRootViewCopy022),
            LanguageOption(tag: "en", title: SettingsStrings.english)
        ]
    }

    // MARK: - 用于增强本地识别
    //
    // 2026-10-01 Claude（0.5.50）：勾选框在「在线 API」里阿里云那一行下面。只有保存了 Key、选着千问（本地）而且识别语言是
    // 中文、English 或自动时才能勾；其它情形只留一行原因，不摆灰掉的控件。勾的时候，有效的确认在就直接开，没有就弹说明
    // （和选用阿里云同一个弹窗，按用途换标题和说明），确认完只开增强、不动识别方式。切换方式保留偏好；
    // 用户关闭、删 Key 或关闭云端入口时收回。是否生效仍取决于当前本地路线与语言。
    // 哪一行出现、每一句写什么都在 CloudEnhanceWording，由自测逐条核对。是否真的上传仍由 K06 闸门和协调器逐次决定。

    /// 这一行现在该显示什么（不显示、一行原因，还是勾选框）。
    private var enhanceRowState: CloudEnhanceRow {
        CloudEnhanceRow(
            entryLoaded: cloudPage.isLoaded,
            entryVisible: cloudPage.isVisible,
            keySaved: cloudPage.key == .saved,
            selection: providerStore.value.selection,
            enhanceOn: enhanceOn,
            status: cloudEntryStatus,
            provider: enhancementProvider
        )
    }

    /// 「本地识别」卡片的说明：平常是「声音不上传」；勾了增强而且确认有效，声音会同时发给阿里云，这句就不能留着。
    private var localCardDetail: String {
        guard CloudEntry.canEnhance(providerStore.value.selection, provider: enhancementProvider) else { return SettingsStrings.localDetail }
        // The Aliyun state is not read yet: a ticked box may be sending, so the line does not say "不上传".
        if !cloudPage.isLoaded, enhanceOn { return SettingsStrings.settingsRootViewCopy085 }
        var enhanceActive = false
        if case .offered(true, _, _) = enhanceRowState { enhanceActive = true }
        return CloudEnhanceWording.localCardDetail(enhanceActive: enhanceActive, status: cloudEntryStatus, provider: enhancementProvider)
    }

    /// 勾了增强、选着千问时侧栏那一行：声音也会发给阿里云；确认不在了就说只用本机。用不上时是 nil。
    private var enhanceSidebarStatus: RouteStatus? {
        guard case .offered(true, _, _) = enhanceRowState else { return nil }
        let status = cloudEntryStatus
        return RouteStatus(text: CloudEnhanceWording.footer(status: status, provider: enhancementProvider),
            tone: !enhancementProvider.isAliyun || status.isUsable ? .neutral : .needsAttention)
    }
    private var enhancementProvider: OnlineAPIProvider {
        providerStore.value.onlineAPIConfiguration?.provider ?? .aliyunBailian
    }

    private var enhanceBinding: Binding<Bool> {
        Binding(get: { enhanceOn }, set: { wanted in changeEnhance(to: wanted) })
    }

    /// 给 saveProviderPreferences 用：新选择用不上的云端开关收回，「不知道」的事实（Key 还没读回来）不当成缺。
    private func reconcileContext(
        for selection: VoiceInputSelection, credentialAvailable: Bool? = nil
    ) -> CloudEntryReconcileContext {
        CloudEntryReconcileContext(
            selection: selection,
            credentialAvailable: credentialAvailable ?? (cloudPage.isLoaded ? cloudPage.key == .saved : true),
            entryVisible: CloudEntryPreferences.load().visible,
            provider: enhancementProvider
        )
    }

    /// 这次保存顺手关了增强的话，在提示后面带一句；带过就清掉。
    private func withEnhanceClosedNote(_ text: String) -> String {
        guard enhanceClosedBySave else { return text }
        enhanceClosedBySave = false
        return "\(text)\(CloudEnhanceWording.closedByChange)"
    }

    /// 勾选框被点了。关：马上关、收回没人用的上传许可、通知协调器。开：按点下去这一刻的状态（不用画面上共用的 cloudClock）
    /// 定：有效的确认在就直接开，没有就弹说明，开不了就说原因，框保持原样。删 Key 进行中什么都不做。
    private func changeEnhance(to wanted: Bool) {
        guard !cloudRemoving else { return }
        enhanceNote = ""
        guard wanted else {
            enhancementActivationTask?.cancel(); enhancementActivationTask = nil
            pendingEnhancementConfiguration = nil; enhancementUploadAsked = false
            onlineAPIRuntime.service?.withdrawEnhancement()
            turnOffEnhance()
            return
        }
        guard let configuration = providerStore.value.onlineAPIConfiguration else {
            cloudWizardPurpose = .enhanceLocal; cloudWizardStartStep = 1; cloudWizardShown = true
            return
        }
        if let reason = CloudEnhanceWording.refusal(selection: providerStore.value.selection,
            keySaved: settingsLogic.online.isConfigured, removing: cloudRemoving, provider: configuration.provider) {
            enhanceNote = reason; return
        }
        let consent = CloudEntryPreferences.load()
        if !consent.uploadConsent || (!configuration.provider.isAliyun && !providerStore.value.cloudConsent.contains(configuration.consentID)) {
            pendingEnhancementConfiguration = configuration
            enhancementUploadAsked = true
            return
        }
        activateEnhancement(configuration)
    }
    private func activateEnhancement(_ configuration: OnlineAPIConfiguration) {
        enhancementActivationTask?.cancel()
        enhancementActivationTask = Task { @MainActor in
            guard !Task.isCancelled, providerStore.value.onlineAPIConfiguration == configuration,
                  CloudEntry.canEnhance(providerStore.value.selection, provider: configuration.provider) else { return }
            do { try await onlineAPIRuntime.activate(purpose: .enhanceLocal) }
            catch {
                guard !Task.isCancelled else { return }
                if configuration.provider.isAliyun, onlineAPIRuntime.panel.attention == .confirmationExpired { openCloudConfirmSheet(.renew, purpose: .enhanceLocal) }
                else { enhanceNote = OnlineAPIStrings.completionFailed }
            }
        }
    }

    /// 先关增强，再让 reconcile 收回没人用的「允许上传」，最后通知协调器：正在说的这一段里，阿里云那一路立刻停。
    private func turnOffEnhance() {
        settingsLogic.online.setEnhancementFromUser(false, authorized: false)
        CloudEntryPreferences.reconcile(reconcileContext(for: providerStore.value.selection))
        settingsLogic.online.enhancement.synchronize()
        onSelectionChanged()
        enhanceNote = CloudEnhanceWording.offNote(provider: enhancementProvider)
    }

    /// 开增强：先「允许上传」再开增强（中间崩了也只留下没人用的许可，下次 reconcile 收走）。点的时候和确认回来的时候
    /// 都再查一遍：Key、识别方式、语言在弹窗开着的时候可能变了。不改识别方式，也不记「原来的方式」。
    @discardableResult
    private func enableEnhance(_ how: CloudEnhanceSwitch) -> Bool {
        if let reason = CloudEnhanceWording.refusal(
            selection: providerStore.value.selection, keySaved: cloudPage.isActive, removing: cloudRemoving,
            provider: enhancementProvider
        ) {
            enhanceNote = reason
            return false
        }
        _ = CloudSetupActions.enableEnhancement(selection: providerStore.value.selection, page: cloudPage,
            removing: cloudRemoving, logic: settingsLogic, onSelectionChanged: onSelectionChanged)
        enhanceNote = enhanceOn ? how.note : CloudEnhanceWording.entryUnusable
        return enhanceOn
    }

    /// 选用阿里云、或勾选「用于增强本地识别」之前的一次确认。三种情形（第一次、过期、暂停后恢复）和两种用途，标题和说明
    /// 各不同，按钮只有一个，按下就完成：记下确认、允许上传，再按用途切到阿里云或只开增强。处理中不能被 Esc 关掉。
    private var cloudConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(cloudSheetKind.title(for: cloudSheetPurpose))
                .font(.headline)
            Text(SettingsStrings.settingsRootViewCopy086(CloudEntry.modelID))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(cloudSheetKind.lead(for: cloudSheetPurpose))
                .fixedSize(horizontal: false, vertical: true)
            Text(SettingsStrings.settingsRootViewCopy087)
                .fixedSize(horizontal: false, vertical: true)
            Button(SettingsStrings.settingsRootViewCopy088) {
                if let url = URL(string: CloudEntry.consoleURL) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(SettingsLinkButtonStyle())
            .help(CloudEntry.consoleURL)
            if !cloudSheetNote.isEmpty {
                Text(cloudSheetNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                Button(SettingsStrings.cancel) { cloudSheetShown = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(cloudSheetBusy)
                Button(cloudSheetKind.confirmTitle(for: cloudSheetPurpose)) { confirmCloudGuard() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cloudSheetBusy)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(cloudSheetBusy)
        // 弹窗不管怎么离开（按钮、切页、关窗）都记一笔，并自己把 cloudSheetShown 放回 false：处理中的确认据此
        // 只留下确认、不替用户切换，回到这一页时弹窗也不会自己又冒出来。
        .onDisappear {
            cloudSheetGeneration &+= 1
            cloudSheetShown = false
        }
    }

    /// 只保留最新一次读取的结果：读的期间又发起了新的读取（删 Key、换 Key、窗口回到前台…），旧的作废。
    /// 返回这次读到的有没有用上（被更新的读取顶掉时是 false）。
    @discardableResult
    private func refreshCloudEntry() async -> Bool {
        cloudRefreshGeneration &+= 1
        let generation = cloudRefreshGeneration
        let state = await CloudEntryRuntime.shared.pageState()
        guard generation == cloudRefreshGeneration else { return false }
        if state != cloudPage {
            cloudPage = state
            enhanceNote = ""  // the key or the Aliyun state changed: what was said under the box may no longer hold
        }
        settingsLogic.update(page: state, selection: providerStore.value.selection)
        cloudClock = Date()
        return true
    }

    private func openCloudConfirmSheet(_ kind: CloudConfirmationKind, purpose: CloudEntryPurpose = .route) {
        guard !cloudRemoving else { return }
        cloudSheetKind = kind
        cloudSheetPurpose = purpose
        cloudSheetNote = ""
        cloudSheetShown = true
    }

    /// 存下粘贴的 Key（格式不对就原地提示，什么都不写），然后立刻测一次连接。
    private func inspectDraftMethod() {
        let method: RecognitionMethod = draftMode == .doubao ? .doubao : VoiceRouteOption.cloudRouteIDs.contains(draftRouteID) ? .online : .local
        settingsLogic.inspect(method, routeID: draftRouteID)
    }

    /// 删掉本机保存的 Key。先停用、后删：删不掉（文件被锁、存储损坏）时阿里云也已经停用，声音不会再发出去。
    /// 正在用阿里云识别的话，改回选阿里云之前的方式，「使用」「允许上传」一起收回。从这里起到读回删除之后的
    /// 状态为止 cloudRemoving 为真，阿里云卡和这一行的按钮都不能用。
    private func removeCloudKey() {
        guard !cloudRemoving else { return }
        cancelOnlineConnectionTest()
        cloudRemoving = true
        var switched = ""
        var leaveFailed = false
        let selection = providerStore.value.selection
        // 依赖这把 Key 的开关先收回（「用于增强本地识别」，以及没人用的「允许上传」），再动识别方式、删文件。
        let enhanceWasOn = CloudEntryPreferences.load().enhanceLocal
        CloudEntryPreferences.reconcile(reconcileContext(for: selection, credentialAvailable: false))
        settingsLogic.online.enhancement.synchronize()
        enhanceNote = ""
        if selection.mode == .voiceNative, selection.routeID == CloudEntry.routeID {
            let previous = CloudEntryPreferences.previousSelection()
            let toDoubao = previous?.mode == .doubao && Self.isDoubaoInstalled
            if let title = leaveCloudRoute(toDoubao: toDoubao) {
                switched = SettingsStrings.settingsRootViewCopy090(title)
            } else {
                leaveFailed = true
            }
        } else {
            onSelectionChanged()  // 开关已在上面收回；让正在进行的云端听写（或增强的那一路）停下
        }
        cloudTestGeneration += 1
        let switchedNote = switched + (enhanceWasOn ? CloudEnhanceWording.closedByKeyRemoval : "")
        let keepMessage = leaveFailed
        Task { @MainActor in
            let removed: Bool
            do {
                try await CloudEntryRuntime.shared.removeKey()
                removed = true
            } catch {
                removed = false
            }
            // 用上的必须是删除之后读到的状态才放开：这次读取被中途开始的另一次顶掉时就再读一次，免得按旧状态又把
            // 阿里云卡放出来。
            while !(await refreshCloudEntry()) {}
            cloudRemoving = false
            cloudNote = removed
                ? SettingsStrings.settingsRootViewCopy091(switchedNote)
                : SettingsStrings.settingsRootViewCopy092(switchedNote)
            if !keepMessage { setMessage("") }
        }
    }

    /// 点了阿里云卡片。有效的确认在，直接切；否则按情形（第一次、过期、暂停）弹说明；状态读不到就不切。
    /// 删 Key 进行中什么都不做。确认是否有效按点下去这一刻算，不按画面上共用的 cloudClock。
    private func chooseCloud() {
        guard cloudPage.isActive, !cloudRemoving else { return }
        cloudNote = ""
        guard cloudLanguageSupported else {
            setMessage(SettingsStrings.settingsRootViewCopy093, error: true)
            return
        }
        let status = CloudEntryStatus(snapshot: cloudPage.snapshot)
        if cloudRouteSelected, status.isUsable, cloudSwitchesOn {
            setMessage("")
            return
        }
        switch status.enableStep {
        case .switchNow:
            enableCloudRoute(.direct)
        case .confirm(let kind):
            openCloudConfirmSheet(kind)
        case .blocked:
            setMessage(SettingsStrings.settingsRootViewCopy094(currentRouteTitle), error: true)
        }
    }

    /// 选用阿里云：记住原来的方式、允许上传、打开「使用」，再存选择；存不下来就把两个开关都关上（原来开着的也关），
    /// 并通知协调器。是否真的上传仍由 K06 闸门逐次决定。删 Key 进行中或入口已经用不了时什么都不打开。
    @discardableResult
    private func enableCloudRoute(_ how: CloudRouteSwitch) -> Bool {
        let result = CloudSetupActions.enableRoute(store: providerStore, page: cloudPage, removing: cloudRemoving,
            previousLocalRouteID: localEngineID(for: providerStore.value.selection),
            persist: { saveProviderPreferences($0, cloudSwitchesTouched: true) }, onSelectionChanged: onSelectionChanged)
        switch result {
        case .unavailable:
            setMessage(SettingsStrings.settingsRootViewCopy095, error: true)
            return false
        case .unsupportedLanguage:
            setMessage(SettingsStrings.settingsRootViewCopy093, error: true)
            return false
        case .enabled:
            let closedEnhance = enhanceClosedBySave
            enhanceClosedBySave = false
            setMessage(closedEnhance ? "\(how.note)\(CloudEnhanceWording.closedByRoute)" : how.note)
            return true
        case .saveFailed: return false
        }
    }

    /// 离开阿里云：先收回「使用」，由 reconcile 保留仍用于本地增强的上传许可，再通知协调器和存新的选择。
    /// 后续保存失败也不会继续在线路线；增强只在可增强的本地路线生效，不会替用户补回许可。
    /// `toDoubao`：选阿里云之前用的是豆包就回豆包，否则回本地识别。返回回到的方式名；没能存下来返回 nil（已提示）。
    private func leaveCloudRoute(toDoubao: Bool) -> String? {
        CloudEntryPreferences.leaveRoute(reconciling: reconcileContext(for: providerStore.value.selection))
        onSelectionChanged()
        let current = providerStore.value.selection
        let target = localReturnTarget()
        let routeID = target?.routeID ?? CloudEntry.localFallbackRouteID
        let language = target?.language ?? current.language
        let mode: VoiceInputMode = toDoubao ? .doubao : .voiceNative
        guard let selection = try? VoiceInputSelection(mode: mode, routeID: routeID, language: language) else {
            reloadProviderDraft()
            setMessage(CloudEntryLine.saveFailedCloudOff, error: true)
            return nil
        }
        var preferences = providerStore.value
        preferences.selection = selection
        guard saveProviderPreferences(preferences, cloudSwitchesTouched: true) else { return nil }
        return toDoubao ? SettingsStrings.doubao : routeTitle(routeID)
    }

    /// 只记「用户已确认」，然后选用阿里云。已暂停时走「重新检查并恢复」；两者都由 CloudEntry.confirm
    /// 按闸门接口完成。只有按下按钮的那个弹窗还在时才替用户切换：弹窗离开过（cloudSheetGeneration 变了），
    /// 就只留下确认。
    private func confirmCloudGuard() {
        guard !cloudSheetBusy else { return }
        cloudSheetBusy = true
        cloudSheetNote = ""
        let sheet = cloudSheetGeneration
        let purpose = cloudSheetPurpose  // 按下去时这个弹窗是为什么问的；之后状态怎么变，这次确认做的事不变
        Task { @MainActor in
            let result = await CloudEntryRuntime.shared.confirm()
            await refreshCloudEntry()
            cloudSheetBusy = false
            let sheetStillUp = cloudSheetShown && sheet == cloudSheetGeneration
            switch result {
            case .failed:
                let failure = purpose == CloudEntryPurpose.route
                    ? SettingsStrings.settingsRootViewCopy098
                    : CloudEnhanceWording.confirmFailed
                if sheetStillUp {
                    cloudSheetNote = failure
                } else if purpose == CloudEntryPurpose.route {
                    cloudNote = failure
                } else {
                    enhanceNote = failure
                }
            case .confirmed, .resumed:
                guard sheetStillUp else {
                    // 处理中弹窗被关掉了：只留下确认，不替用户切换或开启。
                    if purpose == CloudEntryPurpose.route {
                        cloudNote = SettingsStrings.settingsRootViewCopy099
                            + (CloudEntry.canEnhance(providerStore.value.selection) && CloudEntryPreferences.load().enhanceLocal
                                ? SettingsStrings.settingsRootViewCopy100 : "")
                    } else {
                        enhanceNote = CloudEntry.canEnhance(providerStore.value.selection) && CloudEntryPreferences.load().enhanceLocal
                            ? CloudEnhanceWording.confirmKeptAlreadyOn
                            : CloudEnhanceWording.confirmKeptNotEnabled
                    }
                    return
                }
                cloudSheetShown = false
                switch purpose {
                case .route:
                    enableCloudRoute(result == CloudEntryConfirmation.resumed ? CloudRouteSwitch.resumed : CloudRouteSwitch.confirmed)
                case .enhanceLocal:
                    enableEnhance(result == CloudEntryConfirmation.resumed ? CloudEnhanceSwitch.resumed : CloudEnhanceSwitch.confirmed)
                }
            }
        }
    }

    // MARK: - Gestures and input

    private var gesturesPage: some View {
        SettingsPageBody(SettingsPage.gestures.title) {
            SettingsGroup {
                Toggle(isOn: Binding(
                    get: { localSettings.gesture.trackpadEnabled },
                    set: { value in changeSettings { $0.gesture.trackpadEnabled = value } }
                )) { SettingsRowLabel(SettingsStrings.settingsRootViewCopy101, icon: "rectangle.and.hand.point.up.left") }
                LabeledContent {
                    Picker(SettingsStrings.settingsRootViewCopy102, selection: Binding(
                        get: { localSettings.voiceShortcut.mode },
                        set: { value in changeSettings(invalidateSession: true) { $0.voiceShortcut.mode = value } }
                    )) {
                        Text(SettingsStrings.settingsRootViewCopy103).tag(VoiceShortcutMode.hold)
                        Text(SettingsStrings.settingsRootViewCopy104).tag(VoiceShortcutMode.toggle)
                    }
                    .labelsHidden().fixedSize()
                } label: { SettingsRowLabel(SettingsStrings.settingsRootViewCopy102, icon: "waveform") }
                LabeledContent { Text(SettingsStrings.settingsRootViewCopy106) } label: {
                    SettingsRowLabel(SettingsStrings.settingsRootViewCopy105, icon: "keyboard")
                }
                LabeledContent { Text(SettingsStrings.settingsRootViewCopy108) } label: {
                    SettingsRowLabel(SettingsStrings.settingsRootViewCopy107, icon: "magicmouse")
                }
                HapticStrengthSettingsRow(strength: Binding(
                    get: { localSettings.gesture.hapticStrength },
                    set: { value in changeSettings { $0.gesture.hapticStrength = value } }
                ), deviceFixture: review == nil ? nil : [HapticReviewDevice(kind: .builtInTrackpad)])
            } header: {
                Text(SettingsStrings.settingsRootViewCopy109)
            } footer: {
                Text(SettingsStrings.settingsRootViewCopy110)
            }

            SettingsGroup(SettingsStrings.gestureOutputSection) {
                Toggle(isOn: Binding(
                    get: { localSettings.omitTerminalPeriod },
                    set: { value in changeSettings { $0.omitTerminalPeriod = value } }
                )) { SettingsRowLabel(SettingsStrings.omitTerminalPeriod, icon: "textformat") }
            } footer: {
                // Doubao writes its own text into the field; this switch only reaches VoicePointer's routes.
                if savedMode == .doubao { Text(SettingsStrings.omitTerminalPeriodDoubaoHint) }
            }

            MagicMouseSettingsSection(configuration: Binding(
                get: { localSettings.gesture },
                set: { value in changeSettings { $0.gesture = value } }
            ), state: review?.magicMouseState ?? MagicMouseSettingsState(fixture: nil),
               expanded: review?.magicMouseExpanded ?? false)

            /* 智能聚焦暂不做，需要时恢复。
            Section {
                Picker(SettingsStrings.settingsRootViewCopy111, selection: Binding(
                    get: { localSettings.focusMode },
                    set: { value in changeSettings { $0.focusMode = value } }
                )) {
                    Text(SettingsStrings.settingsRootViewCopy112).tag(FocusMode.currentOnly)
                    Text(SettingsStrings.settingsRootViewCopy113).tag(FocusMode.smart)
                    Text(SettingsStrings.settingsRootViewCopy114).tag(FocusMode.voiceOnly)
                }
                Toggle(SettingsStrings.settingsRootViewCopy115, isOn: Binding(
                    get: { localSettings.allowSyntheticClickFallback },
                    set: { value in changeSettings { $0.allowSyntheticClickFallback = value } }
                ))
            } header: {
                Text(SettingsStrings.settingsRootViewCopy116)
            } footer: {
                Text(SettingsStrings.settingsRootViewCopy117)
            }
            */
        }
        .onAppear { if review == nil { localSettings = SettingsStore.shared.value } }
    }

    private func changeSettings(
        invalidateSession: Bool = false,
        _ change: (inout VoicePointerSettings) -> Void
    ) {
        if review != nil { change(&localSettings); return }
        SettingsStore.shared.update(change)
        localSettings = SettingsStore.shared.value
        onInteractionChanged(invalidateSession)
    }

    // MARK: - General

    private var generalPage: some View {
        SettingsPageBody(SettingsPage.general.title) {
            SettingsGroup {
                Toggle(isOn: Binding(
                    get: { loginSnapshot?.desiredEnabled ?? LoginItemService.shared.desiredEnabled },
                    set: { enabled in Task { await setLogin(enabled) } }
                )) { SettingsRowLabel(SettingsStrings.settingsRootViewCopy118, icon: "power") }
                .disabled(loginBusy || loginSnapshot?.failureReason == LoginItemService.nonOfficialInstallReason)
                LabeledContent {
                    SettingsStatusPill(text: loginStatus, tone: loginSnapshot?.systemState == .enabled ? .ready : .needsAttention)
                } label: { SettingsRowLabel(SettingsStrings.settingsRootViewCopy119, icon: "checkmark.seal") }
                if let reason = loginSnapshot?.failureReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, SettingsLayout.tileSize + 12)
                }
                if loginSnapshot?.systemState == .requiresApproval {
                    Button(SettingsStrings.settingsRootViewCopy120) { SMAppService.openSystemSettingsLoginItems() }
                }
                LabeledContent {
                    SettingsStatusPill(text: listenerStatus.text, tone: listenerStatus.tone)
                } label: { SettingsRowLabel(SettingsStrings.settingsRootViewCopy121, icon: "dot.radiowaves.left.and.right") }
                Button(SettingsStrings.settingsRootViewCopy122) {
                    onRecheck()
                    permissionRevision += 1
                    Task { await refreshLogin() }
                }
                .padding(.leading, SettingsLayout.tileSize + 12)
            } header: {
                Text(SettingsStrings.settingsRootViewCopy123)
            } footer: {
                Text(SettingsStrings.settingsRootViewCopy124)
            }

            SettingsGroup {
                Toggle(isOn: $outputDuckingEnabled) { SettingsRowLabel(SettingsStrings.outputDuckingToggle, icon: "speaker.wave.2") }
                VStack(alignment: .leading, spacing: 4) {
                    let ratioLabel = outputDuckingRatio < 0.05
                        ? SettingsStrings.outputDuckingMute
                        : SettingsStrings.outputDuckingRatio(outputDuckingRatio)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ratioLabel).font(.system(size: 13))
                        Spacer(minLength: 4)
                        Text(outputDuckingRatio < 0.05 ? "0%" : "\(Int((outputDuckingRatio * 100).rounded()))%")
                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $outputDuckingRatio, in: 0...0.8, step: 0.1)
                        .accessibilityLabel(SettingsStrings.outputDuckingAccessibilityLabel)
                        .accessibilityValue(ratioLabel)
                }
                .disabled(!outputDuckingEnabled)
                .opacity(outputDuckingEnabled ? 1 : 0.45)
                .padding(.leading, SettingsLayout.tileSize + 12)
                Text(SettingsStrings.outputDuckingHelp)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsLayout.tileSize + 12)
            } header: {
                Text(SettingsStrings.outputDuckingSection)
            }

            SettingsGroup {
                permissionRow(
                    SettingsStrings.settingsRootViewCopy125, icon: "mic",
                    detail: SettingsStrings.settingsRootViewCopy126,
                    granted: review != nil || AVAudioApplication.shared.recordPermission == .granted,
                    stateText: microphonePermissionText,
                    panel: "Privacy_Microphone"
                )
                permissionRow(
                    SettingsStrings.settingsRootViewCopy127, icon: "accessibility",
                    detail: SettingsStrings.settingsRootViewCopy128,
                    granted: review != nil || AccessibilityPermission.isTrusted,
                    stateText: review != nil || AccessibilityPermission.isTrusted ? SettingsStrings.settingsRootViewCopy129 : SettingsStrings.settingsRootViewCopy130,
                    panel: "Privacy_Accessibility"
                )
                permissionRow(
                    SettingsStrings.settingsRootViewCopy131, icon: "keyboard",
                    detail: SettingsStrings.settingsRootViewCopy132,
                    granted: review != nil || EventAccessPermission.canListen,
                    stateText: review != nil || EventAccessPermission.canListen ? SettingsStrings.settingsRootViewCopy129 : SettingsStrings.settingsRootViewCopy130,
                    panel: "Privacy_ListenEvent"
                )
            } header: {
                Text(SettingsStrings.settingsRootViewCopy135)
            } footer: {
                Text(SettingsStrings.settingsRootViewCopy136)
            }
            .id(permissionRevision)

            SettingsGroup {
                LabeledContent {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? SettingsStrings.settingsRootViewCopy019)
                        .monospacedDigit()
                } label: { SettingsRowLabel(SettingsStrings.settingsRootViewCopy138, icon: "info.circle") }
                LabeledContent {
                    Text(RuntimeTrace.fileURL.path)
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } label: { SettingsRowLabel(SettingsStrings.settingsRootViewCopy140, icon: "doc.text") }
                // 2026-11-07 简洁版：三个按钮排成一行，不再各占一行。
                HStack(spacing: 8) {
                    Button(SettingsStrings.settingsRootViewCopy141) {
                        NSWorkspace.shared.selectFile(
                            RuntimeTrace.fileURL.path,
                            inFileViewerRootedAtPath: RuntimeTrace.fileURL.deletingLastPathComponent().path
                        )
                    }
                    Button(SettingsStrings.settingsRootViewCopy142, action: onShowOnboarding)
                    Button(SettingsStrings.diagnosticExport, action: exportDiagnostics)
                        .accessibilityLabel(SettingsStrings.diagnosticExport)
                        .disabled(diagnosticExport.isRunning)
                    Spacer(minLength: 0)
                }
                .padding(.leading, SettingsLayout.tileSize + 12)
                switch diagnosticExport.state {
                case .idle: EmptyView()
                case .exporting:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(SettingsStrings.diagnosticExporting) }
                case .exported:
                    Text(SettingsStrings.diagnosticExported).foregroundStyle(.secondary)
                case .failed:
                    Text(SettingsStrings.diagnosticExportFailed).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(SettingsStrings.settingsRootViewCopy137)
            } footer: {
                Text(SettingsStrings.diagnosticExportDetail).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func exportDiagnostics() {
        guard review == nil, !diagnosticExport.isRunning else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = SettingsStrings.diagnosticFileName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let preferences = providerStore.value
        let process = ProcessInfo.processInfo
        let summary = DiagnosticSummary(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            cpuCount: process.processorCount, memoryBytes: process.physicalMemory,
            osMajor: process.operatingSystemVersion.majorVersion,
            mode: preferences.selection.mode, routeID: preferences.selection.routeID,
            lexiconEnabled: preferences.applyPersonalLexicon, correctionLearning: preferences.learnCorrections,
            enhancementLearning: CorrectionLearningRuntime.shared.isOnlineEnhancementLearningAuthorized, onlineEnhancement: enhanceOn)
        let logDirectory = RuntimeTrace.fileURL.deletingLastPathComponent()
        let workspace = logDirectory.appendingPathComponent("diagnostic-exports", isDirectory: true)
        RuntimeTrace.flush()
        Task { await diagnosticExport.export {
            try DiagnosticBundle.export(summary: summary, logDirectory: logDirectory,
                workspaceParent: workspace, destination: destination)
        } }
    }

    private var listenerStatus: RouteStatus {
        if review != nil { return .init(text: SettingsStrings.fixturePermissions, tone: .ready) }
        guard AccessibilityPermission.isTrusted, EventAccessPermission.canListen else {
            return RouteStatus(text: SettingsStrings.settingsRootViewCopy143, tone: .needsAttention)
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return RouteStatus(text: SettingsStrings.settingsRootViewCopy144, tone: .needsAttention)
        }
        return RouteStatus(text: SettingsStrings.settingsRootViewCopy145, tone: .ready)
    }

    private var microphonePermissionText: String {
        if review != nil { return SettingsStrings.fixturePermissions }
        return switch AVAudioApplication.shared.recordPermission {
        case .granted: SettingsStrings.settingsRootViewCopy129
        case .denied: SettingsStrings.settingsRootViewCopy147
        case .undetermined: SettingsStrings.settingsRootViewCopy148
        @unknown default: SettingsStrings.settingsRootViewCopy149
        }
    }

    private func permissionRow(
        _ title: String,
        icon: String,
        detail: String,
        granted: Bool,
        stateText: String,
        panel: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowLabel(title, icon: icon, subtitle: detail)
            Spacer(minLength: 8)
            if granted {
                SettingsStatusPill(text: stateText, tone: .ready)
            } else {
                HStack(spacing: 10) {
                    SettingsStatusPill(text: stateText, tone: .needsAttention)
                    Button(SettingsStrings.settingsRootViewCopy150) { openPrivacyPane(panel) }
                }
            }
        }
    }

    private func openPrivacyPane(_ panel: String) {
        if let kind = PermissionDragAssistant.Kind(privacyAnchor: panel) {
            PermissionDragAssistant.shared.begin(kind) {
                permissionRevision += 1
                onRecheck()
            }
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(panel)") else { return }
        NSWorkspace.shared.open(url)
    }

    private var loginStatus: String {
        guard let snapshot = loginSnapshot else { return SettingsStrings.checkingDetail }
        switch snapshot.systemState {
        case .enabled: return SettingsStrings.settingsRootViewCopy152
        case .requiresApproval: return SettingsStrings.settingsRootViewCopy153
        case .notRegistered: return snapshot.desiredEnabled ? SettingsStrings.settingsRootViewCopy154 : SettingsStrings.settingsRootViewCopy155
        case .notFound: return SettingsStrings.settingsRootViewCopy156
        case .unknown: return SettingsStrings.settingsRootViewCopy157
        }
    }

    private func refreshLogin() async {
        guard review == nil else { return }
        loginSnapshot = await LoginItemService.shared.currentSnapshot()
    }

    private func setLogin(_ enabled: Bool) async {
        guard review == nil else { return }
        loginBusy = true
        loginSnapshot = await LoginItemService.shared.setDesiredEnabled(enabled)
        loginBusy = false
    }
}

@MainActor
struct InlineDemotedApplicationsSection: View {
    private let runtime: InlineWriteRuntime
    @State private var denials: [InlineWriteRuntime.Denial]
    init(runtime: InlineWriteRuntime = .shared) {
        self.runtime = runtime
        _denials = State(initialValue: runtime.activeDenials())
    }
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    var body: some View {
        Group {
            if !denials.isEmpty {
                SettingsGroup(SettingsStrings.inlineRecoveryTitle) {
                    ForEach(denials, id: \.bundle) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(appName(entry.bundle))
                                Text(InlineWritePolicy.chromiumAllowlist.contains(entry.bundle)
                                    ? SettingsStrings.inlineRecoveryTemporary : SettingsStrings.inlineRecoveryStrong)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(SettingsStrings.inlineRecoveryAction) { runtime.restore(bundle: entry.bundle); refresh() }
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: InlineWriteRuntime.changed)) { _ in refresh() }
        .onReceive(clock) { _ in refresh() }
    }
    private func refresh() { denials = runtime.activeDenials() }
    private func appName(_ bundle: String) -> String {
        if bundle == "com.anthropic.claudefordesktop" { return "Claude" }
        if bundle == "com.openai.codex" { return "Codex" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundle
    }
}

private extension RouteStatus.Tone {
    var color: Color {
        switch self {
        case .ready: .green
        case .needsAttention: .orange
        case .failure: Color(nsColor: .systemRed)
        case .neutral: .secondary
        }
    }
}

private struct SettingsStatusPill: View {
    let text: String
    let tone: RouteStatus.Tone

    private var tint: Color { tone.color }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sidebar row: line icon and page name; the selected one sits on a floating accent block, as in System Settings.
@MainActor
struct SettingsSidebarRow: View {
    let page: SettingsPage
    let selected: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .frame(width: 20)
                    .foregroundStyle(selected ? SettingsPalette.ink : SettingsPalette.ink2)
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? SettingsPalette.ink : SettingsPalette.ink2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsPalette.selectionFill)
                        .matchedGeometryEffect(id: "sidebar-selection", in: highlight)
                } else if hovering {
                    // Lighter than the selection, so a hovered row is never mistaken for a second selection.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsPalette.tile.opacity(0.6))
                }
            }
            .animation(SettingsMotion.quick, value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(page.title))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
