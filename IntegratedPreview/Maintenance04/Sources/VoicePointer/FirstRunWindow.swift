import AppKit
import AVFoundation
import SwiftUI
import VoicePointerCore

@MainActor
final class FirstRunWindow: NSWindowController, NSWindowDelegate {
    private let progressStore: OnboardingProgressStore
    private let provider: ProviderSettingsController
    private let practice = FirstRunPracticeBuffer()
    var onPermissionVisibilityChanged: ((Bool) -> Void)?

    func capturePracticeSink() -> (@MainActor @Sendable (UUID, String) -> Void)? {
        practice.captureSink()
    }

    func watchPracticeSession(token: OperationCancellationToken, coordinator: VoicePointerCoordinator) {
        practice.watch(token: token, coordinator: coordinator)
    }

    func windowDidResignKey(_ notification: Notification) { practice.revokeLease() }

    var shouldAutoShow: Bool { progressStore.progress.needsUserChoice }

    init(provider: ProviderSettingsController) throws {
        self.provider = provider
        progressStore = try OnboardingProgressStore(dataRoot: IntegratedRuntimePaths.dataRoot)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = SettingsStrings.firstRunWindowCopy001
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.minSize = NSSize(width: 640, height: 560)
        window.maxSize = NSSize(width: 640, height: 560)
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 640, height: 560)), display: false)
        window.center()
        super.init(window: window)
        practice.window = window
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResigned),
            name: NSApplication.didResignActiveNotification, object: nil)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func applicationResigned() { practice.revokeLease() }

    override func showWindow(_ sender: Any?) {
        do {
            if progressStore.progress.isDeferred {
                if progressStore.progress.wasMigratedFromProviderSettings {
                    try progressStore.begin()
                } else {
                    try progressStore.resume()
                }
            } else if progressStore.progress.isCompleted || progressStore.progress.needsUserChoice {
                try progressStore.begin()
            }
        } catch {
            RuntimeTrace.record("onboarding progress resume failed")
            return
        }
        window?.contentView = NSHostingView(rootView: FirstRunView(
            store: progressStore, provider: provider, practice: practice,
            close: { [weak self] in self?.window?.close() }
        ))
        super.showWindow(sender)
        onPermissionVisibilityChanged?(window?.isVisible == true && window?.isMiniaturized == false)
        RuntimeTrace.record("event=onboarding_window,state=shown,window=\(window?.isVisible == true ? 1 : 0)")
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        onPermissionVisibilityChanged?(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        onPermissionVisibilityChanged?(window?.isVisible == true)
    }

    func windowWillClose(_ notification: Notification) {
        onPermissionVisibilityChanged?(false)
        practice.invalidate()
        let progress = progressStore.progress
        guard !progress.isCompleted && !progress.isDeferred else { return }
        do { try progressStore.deferOnboarding() }
        catch { RuntimeTrace.record("onboarding defer failed") }
    }
}

@MainActor
struct FirstRunReviewScene {
    var missingPermission = false
    var device = CompletionDeviceSelection.trackpad
    var scene = "up"
    var enhancementEnabled = false
    var selectedDevice: String? = nil
}

@MainActor
struct FirstRunView: View {
    let store: OnboardingProgressStore
    let provider: ProviderSettingsController
    let close: () -> Void
    private let review: Bool
    private let reviewScene: FirstRunReviewScene

    @State private var progress: OnboardingProgress
    @State private var busy = false
    @State private var localPreparationEpoch = UUID()
    @State private var message = ""
    @State private var doubaoURL: URL?
    @State private var modelStatus = ""
    @State private var canPrepareSelectedModel = false
    @ObservedObject private var practice: FirstRunPracticeBuffer
    @State private var practiceConfirmed = false
    @State private var permissionRevision = 0
    @State private var downloadAsked = false
    @State private var onlineSelectable = false
    @State private var enhanceWizardShown = false
    @ObservedObject private var logic: SettingsLogicRuntime

    init(store: OnboardingProgressStore, provider: ProviderSettingsController,
         practice: FirstRunPracticeBuffer? = nil,
         close: @escaping () -> Void, review: Bool = false, logic: SettingsLogicRuntime? = nil,
         reviewScene: FirstRunReviewScene = .init()) {
        self.store = store
        self.provider = provider
        self.close = close
        self.review = review
        self.reviewScene = reviewScene
        _practice = ObservedObject(wrappedValue: practice ?? FirstRunPracticeBuffer())
        _logic = ObservedObject(wrappedValue: logic ?? SettingsLogicRuntime.shared)
        _progress = State(initialValue: store.progress)
        if review, let logic {
            _canPrepareSelectedModel = State(initialValue: logic.local.models.first { $0.id.rawValue == store.progress.selectedLocalRouteID }?.state == .ready)
        }
    }

    var body: some View {
        Group {
            if enhanceWizardShown || progress.step == .onlineConfiguration {
                OnlineAPISetupView(purpose: enhanceWizardShown ? .enhanceLocal : .route,
                    context: .onboarding, start: .form,
                    onFinish: { _ in
                        if enhanceWizardShown { enhanceWizardShown = false }
                        else { perform { try store.onlineConfigured(selectable: true) } }
                    }, onCancel: {
                        if enhanceWizardShown { enhanceWizardShown = false; return }
                        if !review { perform { try store.returnToMethodChoice() } }
                    }, validator: review ? OnlineAPIUnavailableValidator() : OnlineAPIRuntime.shared.validator(),
                    completion: review ? nil : OnlineAPIRuntime.shared.complete)
            } else { onboardingBody }
        }
    }

    private var onboardingBody: some View {
        ZStack(alignment: .top) {
            Ellipse().fill(OnboardingStyle.accent.opacity(0.15)).blur(radius: 65)
                .frame(width: 460, height: 130).offset(y: -100).allowsHitTesting(false)
            VStack(spacing: 0) {
                breadcrumb.frame(height: 24)
                Text(title).font(.system(size: 22, weight: .semibold)).padding(.top, 22)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .frame(width: 440, height: 40, alignment: .top).padding(.top, 6)
            }.padding(.top, 34)
            content.frame(width: 560, alignment: .topLeading)
                .id(progress.step)
                .transition(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .opacity : .opacity.combined(with: .offset(x: 18)))
                .padding(.top, progress.step == .completion ? 142 : 176)
            VStack(spacing: 8) {
                Spacer()
                if !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                footer.padding(.horizontal, 40).frame(height: 68)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                    .overlay(alignment: .top) { Divider() }
            }
        }
        .frame(width: 640, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .tint(OnboardingStyle.accent)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .linear(duration: 0.1) : .easeInOut(duration: 0.26), value: progress.step)
        .animation(.easeOut(duration: 0.22), value: message)
        .task(id: message) {
            guard !message.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(3)); message = "" } catch {}
        }
        .task(id: progress.step) {
            guard !review else { return }
            do {
                try store.advanceLegacyCheckpoint(permissionsSatisfied: permissionReady)
                if progress != store.progress { progress = store.progress; return }
            } catch { message = SettingsStrings.firstRunWindowCopy061 }
            if progress.step == .doubaoCheckInstallation || progress.step == .doubaoInstallOfficial {
                checkDoubaoInstallation()
            }
            if progress.step == .localPrepareModel { refreshModelStatus() }
            if progress.step == .initialPermissions || progress.step == .doubaoPermissions || progress.step == .localPermissions {
                while !Task.isCancelled {
                    let snapshot = (AccessibilityPermission.isTrusted ? 1 : 0) | (EventAccessPermission.canListen ? 2 : 0) | (microphoneGranted ? 4 : 0)
                    if permissionRevision != snapshot { withAnimation(.easeInOut(duration: 0.25)) { permissionRevision = snapshot } }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
        .confirmationDialog(SettingsStrings.downloadConsentTitle, isPresented: $downloadAsked) {
            Button(SettingsStrings.downloadConsentAction) {
                guard !review, progress.path == .local,
                      let id = LocalModelID(rawValue: progress.selectedLocalRouteID ?? "") else { return }
                logic.local.perform(.download, id: id, consent: true)
            }
        } message: { Text(SettingsStrings.downloadConsentDetail) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !review else { return }
            if progress.step == .onlineConfiguration { refreshOnlineReadiness() }
            if progress.step == .localPrepareModel { refreshModelStatus() }
            if [.doubaoCheckInstallation, .doubaoInstallOfficial, .doubaoManualEnable].contains(progress.step) {
                checkDoubaoInstallation()
            }
        }
        .onDisappear {
            invalidateLocalPreparation()
            if !review { logic.local.cancelDownloads() }
        }
    }

    private var breadcrumb: some View {
        let items = SettingsStrings.onboardingSteps
        let current: Int
        switch progress.step {
        case .initialPermissions, .doubaoPermissions, .localPermissions: current = 0
        case .chooseMethod: current = 1
        default: current = 2
        }
        return HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Label(item, systemImage: progress.step == .completion || index < current ? "checkmark.circle.fill" : "\(index + 1).circle")
                    .font(.system(size: 12, weight: index == current ? .semibold : .regular))
                    .foregroundStyle(index <= current ? OnboardingStyle.accent : Color.secondary)
                if index < items.count - 1 {
                    Rectangle().fill(index < current || progress.step == .completion ? OnboardingStyle.accent : Color(nsColor: .separatorColor))
                        .frame(width: 32, height: 2)
                }
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch progress.step {
        case .initialPermissions: SettingsStrings.firstRunWindowCopy005
        case .onlineConfiguration: SettingsStrings.onboardingAPIConfigure
        case .onlineReady: SettingsStrings.firstRunWindowCopy006
        case .chooseMethod: SettingsStrings.firstRunWindowCopy002
        case .doubaoCheckInstallation, .doubaoInstallOfficial: SettingsStrings.firstRunWindowCopy003
        case .doubaoManualEnable: SettingsStrings.firstRunWindowCopy004
        case .doubaoPermissions, .localPermissions: SettingsStrings.firstRunWindowCopy005
        case .doubaoPractice, .localPractice: SettingsStrings.firstRunWindowCopy006
        case .localChooseModel: SettingsStrings.firstRunWindowCopy007
        case .localPrepareModel: SettingsStrings.firstRunWindowCopy008
        case .localCloudConfiguration: SettingsStrings.firstRunWindowCopy009
        case .completion: SettingsStrings.onboardingConfiguredTitle
        }
    }

    private var subtitle: String {
        switch progress.step {
        case .initialPermissions: SettingsStrings.firstRunWindowCopy014
        case .onlineConfiguration: SettingsStrings.onboardingAPINeedsConfiguration
        case .onlineReady: SettingsStrings.firstRunWindowCopy015
        case .chooseMethod: SettingsStrings.firstRunWindowCopy011
        case .doubaoCheckInstallation, .doubaoInstallOfficial: SettingsStrings.firstRunWindowCopy012
        case .doubaoManualEnable: SettingsStrings.firstRunWindowCopy013
        case .doubaoPermissions, .localPermissions: SettingsStrings.firstRunWindowCopy014
        case .doubaoPractice, .localPractice: SettingsStrings.firstRunWindowCopy015
        case .localChooseModel: SettingsStrings.firstRunWindowCopy016
        case .localPrepareModel: SettingsStrings.firstRunWindowCopy017
        case .localCloudConfiguration: SettingsStrings.firstRunWindowCopy018
        case .completion: SettingsStrings.onboardingPracticeGestureDetail
        }
    }

    @ViewBuilder private var content: some View {
        switch progress.step {
        case .chooseMethod:
            VStack(spacing: 12) {
                OnboardingRecognitionChoice(method: .doubao) { choose(.doubao) }
                HStack(alignment: .top, spacing: 12) {
                    OnboardingRecognitionChoice(method: .local) { choose(.local) }
                    OnboardingRecognitionChoice(method: .online) { choose(.online) }
                }
            }
        case .doubaoCheckInstallation, .doubaoInstallOfficial:
            doubaoSteps
        case .doubaoManualEnable:
            doubaoSteps
        case .localChooseModel:
            VStack(spacing: 0) {
                if logic.local.hardware.supports(.qwen17) { localModelChoice("qwen17-rolling", SettingsStrings.firstRunWindowCopy021, SettingsStrings.onboardingLargerModelDetail) }
                if logic.local.hardware.supports(.qwen06) { Divider(); localModelChoice("qwen06-rolling", SettingsStrings.firstRunWindowCopy022, SettingsStrings.onboardingSmallerModelDetail) }
                if #available(macOS 26, *) { Divider(); localModelChoice("apple-speech", SettingsStrings.settingsRootViewCopy013, SettingsStrings.firstRunWindowCopy024) }
            }.onboardingCard(padding: 0)
        case .localPrepareModel:
            VStack(alignment: .leading, spacing: 12) {
                if let id = LocalModelID(rawValue: progress.selectedLocalRouteID ?? ""),
                   let model = logic.local.models.first(where: { $0.id == id }) {
                    OnboardingModelCard(model: model,
                        action: { action in
                            guard !review else { return }
                            if action == .download { downloadAsked = true }
                            else if action != .use { logic.local.perform(action, id: id) }
                        }, verify: { if !review { refreshModelStatus() } })
                    if let error = logic.local.downloadError { Text(SettingsStrings.downloadFailure(error)).foregroundStyle(.orange) }
                }
                Text(canPrepareSelectedModel ? SettingsStrings.onboardingModelReadyDetail : SettingsStrings.onboardingModelPreparationDetail)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button(SettingsStrings.onboardingChangeModel) {
                    guard !busy else { return }
                    perform { try store.returnToLocalModelChoice() }
                }
                .disabled(busy)
                .buttonStyle(.link).foregroundStyle(OnboardingStyle.accent)
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .localCloudConfiguration:
            VStack(alignment: .leading, spacing: 12) {
                Label(SettingsStrings.firstRunWindowCopy027, systemImage: "checkmark.shield")
                Text(SettingsStrings.firstRunWindowCopy028)
                    .foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .onlineConfiguration:
            GuideCard(title: SettingsStrings.keyGuideTitle, steps: SettingsStrings.keyGuideSteps,
                actionTitle: SettingsStrings.onboardingAPIConfigure, documentationURL: logic.online.provider.docURL) {
                    guard !review else { return }; provider.showVoicePage(online: true)
                }
        case .initialPermissions, .doubaoPermissions, .localPermissions:
            VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                permissionRow(SettingsStrings.settingsRootViewCopy127, granted: review || AccessibilityPermission.isTrusted,
                              panel: "Privacy_Accessibility")
                Divider()
                permissionRow(SettingsStrings.settingsRootViewCopy131, granted: review || EventAccessPermission.canListen,
                              panel: "Privacy_ListenEvent")
                if progress.step == .initialPermissions || progress.path != .doubao {
                    Divider()
                    permissionRow(SettingsStrings.settingsRootViewCopy125, granted: review ? !reviewScene.missingPermission : microphoneGranted,
                                  panel: "Privacy_Microphone")
                }
            }.onboardingCard(padding: 0)
            Label(SettingsStrings.onboardingPermissionDetail, systemImage: "lock")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .doubaoPractice, .localPractice, .onlineReady:
            VStack(alignment: .leading, spacing: 10) {
                PracticeInput(text: $practice.text, onFocus: { practice.focused = $0 }, autoFocus: true)
                    .accessibilityLabel(SettingsStrings.firstRunWindowCopy032)
                Toggle(SettingsStrings.firstRunWindowCopy033, isOn: $practiceConfirmed)
                    .toggleStyle(.checkbox)
                Text(SettingsStrings.firstRunWindowCopy034)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { practice.active = true }
            .onDisappear { practice.invalidate() }
        case .completion:
            OnboardingCompletionView(localRoute: progress.path == .local,
                enhancementEnabled: review ? reviewScene.enhancementEnabled
                    : CloudEntry.canEnhance(provider.store.value.selection) && CloudEntryPreferences.load().enhanceLocal,
                configureCloud: { if !review { enhanceWizardShown = true } },
                deviceFixture: review ? reviewScene.device : nil, staticFrame: review ? 3.15 : nil,
                sceneFixture: review ? reviewScene.scene : nil, selectedDeviceFixture: review ? reviewScene.selectedDevice : nil)
        }
    }

    private var footer: some View {
        HStack {
            if progress.step != .completion {
                Button(SettingsStrings.firstRunWindowCopy037) { close() }.buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
                if progress.step != .chooseMethod && progress.step != .initialPermissions {
                    Button(SettingsStrings.firstRunWindowCopy038) { perform { try store.returnToMethodChoice() } }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if progress.step == .completion {
                Button(SettingsStrings.firstRunWindowCopy039) { close() }.buttonStyle(OnboardingPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else if let primaryTitle {
                Button(primaryTitle) { primaryAction() }.buttonStyle(OnboardingPrimaryButtonStyle())
                    .disabled(busy || primaryDisabled).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var primaryTitle: String? {
        switch progress.step {
        case .initialPermissions: permissionReady ? SettingsStrings.firstRunWindowCopy040 : SettingsStrings.firstRunWindowCopy045
        case .onlineConfiguration: SettingsStrings.onboardingAPIContinue
        case .onlineReady: SettingsStrings.firstRunWindowCopy047
        case .chooseMethod: nil
        case .doubaoCheckInstallation, .doubaoInstallOfficial: SettingsStrings.firstRunWindowCopy040
        case .doubaoManualEnable: logic.doubao.enabledInSystem == true ? SettingsStrings.firstRunWindowCopy040 : SettingsStrings.firstRunWindowCopy041
        case .localChooseModel: SettingsStrings.firstRunWindowCopy042
        case .localPrepareModel:
            progress.selectedLocalRouteID == "apple-speech" ? SettingsStrings.firstRunWindowCopy043 : SettingsStrings.firstRunWindowCopy044
        case .localCloudConfiguration: SettingsStrings.firstRunWindowCopy045
        case .doubaoPermissions, .localPermissions: SettingsStrings.firstRunWindowCopy045
        case .doubaoPractice, .localPractice: SettingsStrings.firstRunWindowCopy047
        case .completion: nil
        }
    }

    private var primaryDisabled: Bool {
        switch progress.step {
        case .initialPermissions: return !permissionReady
        case .onlineConfiguration: return !onlineSelectable
        case .localPrepareModel:
            return !canPrepareSelectedModel
        case .doubaoPractice, .localPractice, .onlineReady:
            return !practiceConfirmed || practice.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    private func primaryAction() {
        guard !review else { return }
        switch progress.step {
        case .initialPermissions:
            perform { try store.permissionsSatisfied(accessibility: review || AccessibilityPermission.isTrusted,
                inputMonitoring: review || EventAccessPermission.canListen, microphone: review || microphoneGranted) }
        case .onlineConfiguration:
            perform { try store.onlineConfigured(selectable: onlineSelectable) }
        case .onlineReady:
            guard practiceConfirmed, !practice.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            perform { try store.complete() }
        case .doubaoCheckInstallation, .doubaoInstallOfficial:
            checkDoubaoInstallation()
            perform { try store.advance(to: doubaoURL == nil ? .doubaoInstallOfficial : .doubaoManualEnable) }
        case .doubaoManualEnable:
            checkDoubaoInstallation()
            guard doubaoURL != nil else {
                message = SettingsStrings.firstRunWindowCopy048
                return
            }
            guard DoubaoPublicInspector.inspect().detection.enabledInSystem == true else {
                message = SettingsStrings.failure(.doubaoNotEnabled)
                return
            }
            var prefs = provider.store.value
            prefs.selection.mode = .doubao
            do {
                try provider.store.update(prefs)
                provider.onPreferencesChanged?(prefs)
                NotificationCenter.default.post(name: .voicePointerSettingsChanged, object: nil)
                perform { try store.advance(to: OnboardingProgressStore.afterPreparation(path: .doubao, permissionsSatisfied: permissionReady)) }
            } catch { message = SettingsStrings.firstRunWindowCopy049 }
        case .localChooseModel:
            perform { try store.advance(to: .localPrepareModel) }
        case .localPrepareModel:
            prepareLocal()
        case .localCloudConfiguration:
            perform { try store.advance(to: .localPractice) }
        case .doubaoPermissions, .localPermissions:
            permissionRevision += 1
            guard permissionReady else {
                message = SettingsStrings.firstRunWindowCopy050
                return
            }
            perform {
                try store.advance(to: progress.path == .doubao ? .doubaoPractice : .localPractice)
            }
        case .doubaoPractice, .localPractice:
            guard practiceConfirmed else { return }
            perform { try store.complete() }
        case .chooseMethod, .completion: break
        }
    }

    private func choose(_ path: OnboardingPath) {
        if !review { logic.local.cancelDownloads() }
        perform { try store.start(path: path) }
        if path == .local, !logic.local.hardware.supports(.qwen17), logic.local.hardware.supports(.qwen06) {
            perform { try store.selectLocalRoute(LocalModelID.qwen06.rawValue) }
        }
        if path == .online, !review { refreshOnlineReadiness() }
    }

    private func prepareLocal() {
        guard !busy, progress.path == .local, progress.step == .localPrepareModel,
              progress.status == .inProgress, progress == store.progress else { return }
        let originalProgress = store.progress
        let taskEpoch = UUID()
        localPreparationEpoch = taskEpoch
        let routeID = originalProgress.selectedLocalRouteID ?? "qwen17-rolling"
        let previousLanguage = provider.store.value.selection.language
        let language = selectedLocalLanguage(from: previousLanguage, routeID: routeID)
        busy = true
        message = ""
        Task { @MainActor in
            defer {
                if localPreparationEpoch == taskEpoch { busy = false }
            }
            do {
                try await VoiceNativeModelPreparation.prepare(routeID: routeID, language: language)
                guard isCurrentLocalPreparation(taskEpoch, progress: originalProgress) else { return }
                var prefs = provider.store.value
                prefs.selection.mode = .voiceNative
                prefs.selection.routeID = routeID
                prefs.selection.language = language
                try provider.store.update(prefs)
                provider.onPreferencesChanged?(prefs)
                NotificationCenter.default.post(name: .voicePointerSettingsChanged, object: nil)
                guard isCurrentLocalPreparation(taskEpoch, progress: originalProgress) else { return }
                try store.advance(to: OnboardingProgressStore.afterPreparation(path: .local, permissionsSatisfied: permissionReady))
                progress = store.progress
            } catch {
                guard isCurrentLocalPreparation(taskEpoch, progress: originalProgress) else { return }
                refreshModelStatus()
                message = routeID == "apple-speech"
                    ? SettingsStrings.firstRunWindowCopy051
                    : SettingsStrings.firstRunWindowCopy052
            }
        }
    }

    private func isCurrentLocalPreparation(_ epoch: UUID, progress original: OnboardingProgress) -> Bool {
        !Task.isCancelled && localPreparationEpoch == epoch
            && progress == original && store.progress == original
    }

    private func invalidateLocalPreparation() {
        localPreparationEpoch = UUID()
        busy = false
    }

    private var permissionReady: Bool {
        _ = permissionRevision
        if review { return !reviewScene.missingPermission }
        return AccessibilityPermission.isTrusted && EventAccessPermission.canListen
            && microphoneGranted
    }

    private var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var activeRouteName: String {
        if progress.path == .online { return SettingsStrings.onlineTitle(logic.online.displayName) }
        if progress.path == .doubao { return SettingsStrings.doubao }
        switch progress.selectedLocalRouteID {
        case "qwen06-rolling": return SettingsStrings.settingsRootViewCopy061
        case "apple-speech": return SettingsStrings.settingsRootViewCopy013
        default: return SettingsStrings.settingsRootViewCopy060
        }
    }

    private func choice(_ title: String, detail: String, symbol: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title).foregroundStyle(.green)
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .padding(15)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func permissionRow(_ title: String, granted: Bool, panel: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: panel == "Privacy_Accessibility" ? "accessibility" : panel == "Privacy_ListenEvent" ? "keyboard" : "mic.fill")
                .font(.system(size: 18)).foregroundStyle(.white).frame(width: 36, height: 36)
                .background(panel == "Privacy_Accessibility" ? Color.blue : panel == "Privacy_ListenEvent" ? Color.purple : Color.orange, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(panel == "Privacy_Accessibility" ? SettingsStrings.onboardingAccessibilityDetail : panel == "Privacy_ListenEvent" ? SettingsStrings.onboardingGesturePermissionDetail : SettingsStrings.onboardingMicrophonePermissionDetail)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted { SettingsCapsule(text: SettingsStrings.settingsRootViewCopy129, tone: .success) }
            else {
                if !review, panel == "Privacy_Microphone",
                   AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    Button(SettingsStrings.firstRunWindowCopy059) {
                        Task {
                            _ = await AVCaptureDevice.requestAccess(for: .audio)
                            permissionRevision += 1
                        }
                    }
                } else {
                    Button(SettingsStrings.firstRunWindowCopy060) {
                        guard !review else { return }
                        if let kind = PermissionDragAssistant.Kind(privacyAnchor: panel) {
                            PermissionDragAssistant.shared.begin(kind) {
                                permissionRevision += 1
                            }
                        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(panel)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }.buttonStyle(.bordered).padding(.horizontal, 16).frame(height: 62)
    }

    private func localModelChoice(_ route: String, _ title: String, _ detail: String) -> some View {
        Button { perform { try store.selectLocalRoute(route) } } label: {
            HStack(spacing: 12) {
                Image(systemName: progress.selectedLocalRouteID == route ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18)).foregroundStyle(progress.selectedLocalRouteID == route ? OnboardingStyle.accent : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }.padding(.horizontal, 16).frame(minHeight: 66)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private var doubaoSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                doubaoStep(1, title: SettingsStrings.firstRunWindowCopy003, done: logic.doubao.installed,
                    detail: logic.doubao.installed ? SettingsStrings.onboardingDoubaoDetected : SettingsStrings.doubaoGuideSteps[0])
                Divider()
                doubaoStep(2, title: SettingsStrings.onboardingEnableInSettings, done: logic.doubao.enabledInSystem == true,
                    detail: logic.doubao.enabledInSystem == true ? SettingsStrings.onboardingDoubaoEnabled : SettingsStrings.onboardingDoubaoEnableDetail)
            }.onboardingCard(padding: 0)
            Label(SettingsStrings.doubaoPrivateHint, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func doubaoStep(_ number: Int, title: String, done: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(done ? "✓" : String(number)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(done || number == 1 || logic.doubao.installed ? OnboardingStyle.accent : Color.secondary.opacity(0.3), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                if !done, number == 1 || logic.doubao.installed {
                    HStack(spacing: 12) {
                        Button(number == 1 ? SettingsStrings.onboardingDownloadDoubao : SettingsStrings.firstRunWindowCopy060) {
                            if !review { NSWorkspace.shared.open(number == 1 ? SettingsStrings.doubaoDocumentationURL : SettingsStrings.inputSourcesURL) }
                        }.buttonStyle(.bordered)
                        Button(SettingsStrings.documentation) { if !review { NSWorkspace.shared.open(SettingsStrings.doubaoDocumentationURL) } }
                            .buttonStyle(.link).foregroundStyle(OnboardingStyle.accent)
                    }
                }
            }
            Spacer()
        }.padding(16)
    }

    private func checkDoubaoInstallation() {
        let bundleID = "com.bytedance.inputmethod.doubaoime"
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            URL(fileURLWithPath: "/Library/Input Methods/DoubaoIme.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Input Methods/DoubaoIme.app")
        ].compactMap { $0 }
        doubaoURL = candidates.first {
            Bundle(url: $0)?.bundleIdentifier == bundleID
        }
        logic.doubao.update(DoubaoPublicInspector.inspect().detection)
    }

    private func refreshModelStatus() {
        Task { @MainActor in await logic.refreshModelInventory() }
        let routeID = progress.selectedLocalRouteID ?? "qwen17-rolling"
        let language = selectedLocalLanguage(from: provider.store.value.selection.language, routeID: routeID)
        modelStatus = VoiceNativeModelPreparation.status(routeID: routeID)
        canPrepareSelectedModel = VoiceNativeModelPreparation.canStartPreparation(
            routeID: routeID,
            language: language
        )
    }
    private func refreshOnlineReadiness() {
        Task { @MainActor in
            let page = await CloudEntryRuntime.shared.pageState()
            guard progress.step == .onlineConfiguration else { return }
            logic.update(page: page, selection: provider.store.value.selection)
            let state = logic.menu.onlineState(loaded: page.isLoaded, credentialChanging: CloudEntryRuntime.shared.credentialChanging,
                preferences: CloudEntryPreferences.load(), admission: CloudEntryStatus(snapshot: page.snapshot),
                ledger: CloudEntryRuntime.shared.connectionCheck.state, selection: provider.store.value.selection)
            onlineSelectable = provider.store.value.selection.mode == .voiceNative
                && provider.store.value.selection.routeID == CloudEntry.routeID && state.action == .switchRoute
        }
    }

    private func selectedLocalLanguage(from language: String, routeID: String) -> String {
        routeID == "apple-speech" && !VoiceNativeModelPreparation.isAppleLanguageSupported(language)
            ? "zh" : language
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            if progress != store.progress { invalidateLocalPreparation() }
            progress = store.progress
            message = ""
        } catch {
            message = SettingsStrings.firstRunWindowCopy061
            RuntimeTrace.record("onboarding progress transition failed")
        }
    }
    /// Production SwiftUI branches, hosted with synthetic state. No visible window, input/permission API or service call.
    static func runPresentationProbe() -> Bool {
        var passed = true
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".cache/maintenance04-build/T10/onboarding-\(UUID().uuidString)")
        do {
            for path in [OnboardingPath.doubao, .local, .online] {
                let data = root.appendingPathComponent(path.rawValue)
                let store = try OnboardingProgressStore(dataRoot: data)
                let settings = try ProviderSettingsStore(fileURL: data.appendingPathComponent("synthetic-settings.json"))
                let provider = try ProviderSettingsController(store: settings)
                try store.begin()
                let context = SettingsReviewContext(method: path == .doubao ? .doubao : path == .local ? .local : .online, phase: .empty)
                let permissions = FirstRunView(store: store, provider: provider, close: {}, review: true, logic: context.logic)
                passed = passed && permissions.title == SettingsStrings.firstRunWindowCopy005
                try store.permissionsSatisfied(accessibility: true, inputMonitoring: true, microphone: true)
                try store.choose(path: path)
                let expected: String
                switch path {
                case .doubao: try store.advance(to: .doubaoManualEnable); expected = SettingsStrings.firstRunWindowCopy004
                case .local: try store.advance(to: .localPrepareModel); expected = SettingsStrings.firstRunWindowCopy008
                case .online: expected = SettingsStrings.onboardingAPIConfigure
                }
                let view = FirstRunView(store: store, provider: provider, close: {}, review: true, logic: context.logic)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
                host.layoutSubtreeIfNeeded()
                passed = passed && view.title == expected && host.fittingSize.width > 0 && host.fittingSize.height > 0
            }
        } catch { passed = false }
        let line = "event=first_run_presentation,branches=3,permissions=1,passed=\(passed ? 1 : 0)"
        let pairs = line.split(separator: ",").map { $0.split(separator: "=") }
        assert(pairs.count == 4 && pairs.allSatisfy { $0.count == 2 } && pairs[0][1] == "first_run_presentation"
            && pairs.dropFirst().allSatisfy { UInt($0[1]) != nil })
        print(line)
        return passed
    }
}
