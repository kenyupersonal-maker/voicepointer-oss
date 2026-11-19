import AppKit
import SwiftUI
import VoicePointerCore

struct OnlineAPIPalette {
    let dark: Bool
    var accent: Color { Color(red: dark ? 0.153 : 0.110, green: dark ? 0.682 : 0.604, blue: dark ? 0.322 : 0.278) }
    var window: Color { Color(white: dark ? 0.118 : 0.965) }
    var card: Color { Color(white: dark ? 0.165 : 1) }
    var field: Color { Color(white: dark ? 0.122 : 1) }
    var secondary: Color { Color(white: dark ? 0.65 : 0.44) }
    var tertiary: Color { Color(white: dark ? 0.47 : 0.61) }
    var line: Color { (dark ? Color.white : .black).opacity(dark ? 0.10 : 0.09) }
    var softLine: Color { (dark ? Color.white : .black).opacity(dark ? 0.07 : 0.06) }
    var red: Color { dark ? Color(red: 1, green: 0.41, blue: 0.38) : Color(red: 0.84, green: 0, blue: 0.08) }
}

struct OnlineAPIButtonStyle: ButtonStyle {
    let palette: OnlineAPIPalette
    var primary = false
    var tinted = false
    var height: CGFloat = 34
    var horizontalPadding: CGFloat = 14
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: primary || tinted ? .semibold : .regular))
            .padding(.horizontal, horizontalPadding).frame(height: height)
            .foregroundStyle(primary ? .white : tinted ? palette.accent : .primary)
            .background(primary ? palette.accent : tinted ? palette.accent.opacity(palette.dark ? 0.18 : 0.10) : palette.card,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary || tinted ? .clear : palette.line))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
    }
}

struct OnlineAPISetupView: View {
    let purpose: OnlineAPISetupPurpose
    let context: OnlineAPISetupContext
    let onCancel: () -> Void
    @StateObject private var model: OnlineAPISetupModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var keyFocused: Bool
    @State private var revealKey = false
    @State private var advanced = false
    @State private var quotaTip = false
    @State private var pasteFlash = false
    private var palette: OnlineAPIPalette { .init(dark: colorScheme == .dark) }

    init(purpose: OnlineAPISetupPurpose, context: OnlineAPISetupContext, start: OnlineAPISetupPage = .form,
         onFinish: @escaping @MainActor (OnlineAPIConfiguration) -> Void, onCancel: @escaping () -> Void,
         validator: any OnlineAPIValidating = OnlineAPIUnavailableValidator(),
         clipboard: @escaping @MainActor () -> String? = { NSPasteboard.general.string(forType: .string) },
         completion: OnlineAPISetupModel.Completion? = nil, market: MarketRegion = .current) {
        self.purpose = purpose; self.context = context; self.onCancel = onCancel
        _model = StateObject(wrappedValue: .init(purpose: purpose, start: start, market: market, validator: validator,
            clipboard: clipboard, completion: completion, finished: onFinish))
    }
    /// Native fixtures inject the same production model without touching a store.
    init(model: OnlineAPISetupModel, context: OnlineAPISetupContext, onCancel: @escaping () -> Void = {}) {
        purpose = model.purpose; self.context = context; self.onCancel = onCancel
        _model = StateObject(wrappedValue: model)
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                RadialGradient(colors: [palette.accent.opacity(palette.dark ? 0.18 : 0.10), .clear],
                               center: .top, startRadius: 0, endRadius: 230).frame(height: 170)
                ZStack {
                    if model.page == .form { form.transition(pageTransition) }
                    else { OnlineAPIGuideView(model: model, context: context).transition(pageTransition) }
                }.animation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.32), value: model.page)
                if context == .onboarding { progress.padding(.top, 22) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }.frame(width: 640, height: 560).background(palette.window).ignoresSafeArea().tint(palette.accent)
            .background(OnlineAPIWindowCloseGuard(closed: { model.close() }))
            .onAppear { if model.state.phase == .empty && model.page == .form { keyFocused = true } }
            .onChange(of: model.page) { _, page in keyFocused = page == .form && model.keyInput.isEmpty }
            .onDisappear { model.close() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard model.page == .guide, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.3)) { pasteFlash = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation(.easeOut(duration: 0.3)) { pasteFlash = false }
                }
            }
    }
    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: model.page == .guide ? .trailing : .leading),
                                              removal: .move(edge: model.page == .guide ? .leading : .trailing))
    }
    private var form: some View {
        VStack(spacing: 0) {
            Text(purpose == .enhanceLocal ? OnlineAPIStrings.enhanceTitle : OnlineAPIStrings.title)
                .font(.system(size: 22, weight: .semibold)).fontWeight(.semibold).frame(height: 32)
            Text(purpose == .enhanceLocal ? OnlineAPIStrings.enhanceSubtitle : OnlineAPIStrings.subtitle)
                .font(.system(size: 13, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.secondary).frame(height: 19).padding(.top, 7)
            VStack(spacing: 0) {
                keyCard
                if let models = model.models {
                    configurationCard(models).padding(.top, 10)
                } else {
                    if case .failure = model.state.phase { providerRecovery.padding(.top, 8) }
                    if model.state.phase != .checking { noKeyCard.padding(.top, 12) }
                }
                if let provider = model.displayProvider, model.models != nil || advanced {
                    privacy(provider).padding(.top, 9)
                }
                if model.unsupportedEnhance {
                    Text(OnlineAPIStrings.enhanceUnsupported).font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 8)
                }
                if !model.completionMessage.isEmpty {
                    Text(model.completionMessage).font(.system(size: 12)).foregroundStyle(palette.red).padding(.top, 6)
                }
            }.padding(.top, 18)
                .animation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.25), value: model.models != nil)
            Spacer(minLength: 0)
        }.padding(.horizontal, 40).padding(.top, context == .onboarding ? 62 : 30)
    }
    private var progress: some View {
        HStack(spacing: 10) {
            step(OnlineAPIStrings.permissionStep, done: true)
            Rectangle().fill(palette.line).frame(width: 22, height: 1.5)
            step(OnlineAPIStrings.chooseStep, done: true)
            Rectangle().fill(palette.line).frame(width: 22, height: 1.5)
            step(OnlineAPIStrings.finishStep, done: false)
        }.font(.system(size: 13)).foregroundStyle(palette.accent)
    }
    private func step(_ text: String, done: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(done ? palette.accent : .clear)
                Circle().stroke(palette.accent, lineWidth: 1.5)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                else { Text("3").font(.system(size: 11, weight: .semibold)) }
            }.frame(width: 18, height: 18)
            Text(text).fontWeight(done ? .regular : .semibold)
        }
    }
    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(OnlineAPIStrings.keyLabel).fontWeight(.semibold)
                Spacer()
                Text(OnlineAPIStrings.support(model.market)).foregroundStyle(palette.tertiary)
            }.font(.system(size: 12)).foregroundStyle(palette.secondary).frame(height: 17).padding(.bottom, 7)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        if revealKey {
                            TextField(OnlineAPIStrings.keyPlaceholder, text: keyBinding).focused($keyFocused)
                        } else {
                            SecureField(OnlineAPIStrings.keyPlaceholder, text: keyBinding).focused($keyFocused)
                                .opacity(!keyFocused && !model.keyInput.isEmpty ? 0 : 1)
                            if !keyFocused && !model.keyInput.isEmpty {
                                Text(model.maskedKey).allowsHitTesting(false)
                            }
                        }
                    }.textFieldStyle(.plain).font(.system(size: 12.5, weight: .regular, design: .monospaced)).fontWeight(.regular)
                        .contentShape(Rectangle()).onTapGesture { keyFocused = true }
                    Button { revealKey.toggle() } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye").font(.system(size: 14)).foregroundStyle(palette.tertiary)
                    }.buttonStyle(.plain).accessibilityLabel(revealKey ? OnlineAPIStrings.hideKey : OnlineAPIStrings.showKey)
                }.padding(.horizontal, 10).frame(height: 34)
                    .background(palette.field, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(keyFocused ? palette.accent.opacity(0.55) : palette.line))
                Button(OnlineAPIStrings.paste) { model.pasteKey() }.buttonStyle(OnlineAPIButtonStyle(palette: palette, tinted: true))
            }.disabled(model.completing)
            if model.state.phase != .empty { status.padding(.top, 9).frame(minHeight: 18, alignment: .leading) }
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12).apiCard(palette)
    }
    private var keyBinding: Binding<String> { .init(get: { model.keyInput }, set: { model.editKey($0) }) }
    @ViewBuilder private var status: some View {
        switch model.state.phase {
        case .empty: EmptyView()
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(OnlineAPIStrings.checking) }
                .font(.system(size: 12.5, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.secondary)
        case .success(let models):
            HStack(spacing: 6) {
                Image(systemName: "checkmark").fontWeight(.bold)
                Text(models.recommendationChanged ? OnlineAPIStrings.modelSwitched : OnlineAPIStrings.success(models.provider))
            }.font(.system(size: 12.5, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.accent)
        case .failure(let problem):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "xmark").fontWeight(.bold)
                Text(OnlineAPIStrings.problem(problem)).fixedSize(horizontal: false, vertical: true)
                if let action = problem.action {
                    Button(OnlineAPIStrings.action(action)) { problemAction(action) }
                        .buttonStyle(.plain).foregroundStyle(palette.accent).fixedSize()
                }
            }.font(.system(size: 12.5, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.red)
        }
    }
    private func configurationCard(_ models: OnlineAPIValidatedModels) -> some View {
        VStack(spacing: 0) {
            configRow(OnlineAPIStrings.provider) { providerControl(models.provider) }
            Divider().overlay(palette.softLine)
            configRow(OnlineAPIStrings.model) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(models.availableModelIDs, id: \.self) { id in
                        Button { model.selectModel(id) } label: {
                            HStack(spacing: 9) {
                                ZStack {
                                    Circle().fill(model.state.selectedModelID == id ? palette.accent : .clear)
                                    Circle().stroke(model.state.selectedModelID == id ? palette.accent : palette.line, lineWidth: 1.5)
                                    if model.state.selectedModelID == id { Circle().fill(.white).frame(width: 5, height: 5) }
                                }.frame(width: 15, height: 15)
                                Text(OnlineAPIStrings.modelName(id)).fontWeight(.regular)
                                if id == models.recommendedModelID { apiTag(OnlineAPIStrings.recommended, palette: palette) }
                                if let detail = OnlineAPIStrings.modelDetail(id) { Text(detail).font(.system(size: 12, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.tertiary) }
                                Spacer(minLength: 0)
                            }.frame(height: 30).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(id)
                    }
                }
            }
            Divider().overlay(palette.softLine)
            configRow(models.provider.isAliyun ? OnlineAPIStrings.quota : OnlineAPIStrings.note) {
                if models.provider.isAliyun {
                    VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Toggle(OnlineAPIStrings.quotaLabel(models.provider), isOn: .init(get: { model.state.quotaOnlyConfirmed }, set: { model.confirmQuota($0) }))
                            .toggleStyle(.checkbox).fontWeight(.regular).fixedSize()
                        Button(OnlineAPIStrings.how) {
                            open(OnlineAPIPublicLinks.quota(models.provider)); quotaTip = models.provider == .aliyunBailian
                        }.buttonStyle(.plain).foregroundStyle(palette.accent).font(.system(size: 12))
                            .popover(isPresented: $quotaTip) { Text(OnlineAPIStrings.quotaTip).font(.system(size: 12)).padding(12).frame(width: 270) }
                    }
                    if !model.state.quotaOnlyConfirmed {
                        Text(SettingsStrings.quotaRecommended).font(.system(size: 12)).foregroundStyle(palette.tertiary)
                    }
                    }
                } else {
                    Text(OnlineAPIStrings.providerNote(models.provider))
                        .font(.system(size: 12, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.font(.system(size: 13, weight: .regular)).apiCard(palette).disabled(model.completing)
            .transition(reduceMotion ? .opacity : .modifier(active: OnlineAPICardReveal(fraction: 0), identity: OnlineAPICardReveal(fraction: 1)))
    }
    private func configRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).fontWeight(.regular).foregroundStyle(palette.secondary).frame(width: 70, alignment: .leading).padding(.top, 1)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
    private func providerControl(_ provider: OnlineAPIProvider) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) { Circle().fill(palette.accent).frame(width: 7, height: 7); Text(OnlineAPIStrings.providerName(provider)).fontWeight(.semibold) }
                .font(.system(size: 12.5)).padding(.horizontal, 8).frame(height: 22).background(palette.softLine, in: RoundedRectangle(cornerRadius: 6))
            providerMenu
        }
    }
    private var providerMenu: some View {
        Menu {
            ForEach(OnlineAPIProvider.allCases, id: \.self) { provider in
                Button(OnlineAPIStrings.providerName(provider)) { model.changeProvider(provider) }
            }
        } label: { Text(OnlineAPIStrings.change).font(.system(size: 12)).foregroundStyle(palette.accent) }
            .menuStyle(.borderlessButton).fixedSize().disabled(model.completing)
    }
    private var providerRecovery: some View {
        HStack(spacing: 12) { Text(OnlineAPIStrings.provider).foregroundStyle(palette.secondary); providerMenu; Spacer() }.font(.system(size: 12)).padding(.horizontal, 4)
    }
    private func privacy(_ provider: OnlineAPIProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(OnlineAPIStrings.endpoint)
                Text("·")
                Button(OnlineAPIStrings.advanced) { advanced.toggle() }.buttonStyle(.plain).foregroundStyle(palette.accent)
                Text("｜")
                Text(OnlineAPIStrings.upload(provider)).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11.5, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.tertiary).frame(maxWidth: .infinity, alignment: .leading)
            if advanced {
                TextField(OnlineAPIStrings.endpointPlaceholder, text: .init(get: { model.endpointInput }, set: { model.editEndpoint($0) }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12)).help(provider.defaultEndpoint)
            }
        }.padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var noKeyCard: some View {
        Button { model.page = .guide } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(.white).frame(width: 38, height: 38)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) { Text(OnlineAPIStrings.noKeyTitle).font(.system(size: 14, weight: .semibold)); apiTag(OnlineAPIStrings.free, palette: palette) }
                    Text(model.market == .cn ? OnlineAPIStrings.noKeyCN : OnlineAPIStrings.noKeyIntl)
                        .font(.system(size: 12.5, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(palette.accent, in: Circle())
            }.padding(.vertical, 14).padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [palette.accent.opacity(0.10), palette.card], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.accent.opacity(0.55)))
        }.buttonStyle(.plain)
    }
    @ViewBuilder private var footer: some View {
        if model.page == .guide { guideFooter } else { formFooter }
    }
    private var guideFooter: some View {
        HStack(spacing: 8) {
            Button { model.page = .form } label: {
                HStack(spacing: 6) { Image(systemName: "chevron.left"); Text(OnlineAPIStrings.haveKey) }
            }.buttonStyle(.plain).padding(.horizontal, 14).keyboardShortcut(.cancelAction)
            Spacer()
            Button(OnlineAPIStrings.pasteCopied) { model.pasteFromGuide() }
                .buttonStyle(OnlineAPIButtonStyle(palette: palette, primary: true))
                .shadow(color: palette.accent.opacity(pasteFlash ? 0.45 : 0), radius: pasteFlash ? 8 : 0)
                .keyboardShortcut(.defaultAction)
        }.font(.system(size: 13)).padding(.horizontal, 24).frame(height: 56)
            .overlay(alignment: .top) { Rectangle().fill(palette.softLine).frame(height: 1) }
            .overlay(alignment: .topTrailing) {
                if !model.guidePasteMessage.isEmpty {
                    Text(model.guidePasteMessage).font(.system(size: 12)).foregroundStyle(palette.secondary)
                        .padding(.trailing, 24).offset(y: -22)
                }
            }
    }
    private var formFooter: some View {
        HStack(spacing: 8) {
            Button(context == .onboarding ? OnlineAPIStrings.later : OnlineAPIStrings.cancel, action: cancel)
                .buttonStyle(.plain).padding(.horizontal, 14).keyboardShortcut(.cancelAction)
            if context == .onboarding { Button(OnlineAPIStrings.otherMethod, action: cancel).buttonStyle(.plain).padding(.horizontal, 14) }
            Spacer()
            Button { model.requestFinish() } label: {
                HStack(spacing: 6) {
                    if model.awaitingValidation || model.completing { ProgressView().controlSize(.mini) }
                    Text(model.awaitingValidation || model.completing ? OnlineAPIStrings.finishingValidation : OnlineAPIStrings.done)
                }
            }.buttonStyle(OnlineAPIButtonStyle(palette: palette, primary: true)).disabled(!model.finishEnabled).keyboardShortcut(.defaultAction)
        }.font(.system(size: 13)).padding(.horizontal, 24).frame(height: 56)
            .overlay(alignment: .top) { Rectangle().fill(palette.softLine).frame(height: 1) }
    }
    private func cancel() { model.close(); onCancel() }
    private func open(_ url: String) { if let value = URL(string: url) { NSWorkspace.shared.open(value) } }
    private func problemAction(_ action: OnlineAPIProblem.Action) {
        switch action {
        case .guide: model.page = .guide
        case .retry: model.retry()
        case .keyPage(let provider): open(OnlineAPIPublicLinks.key(provider))
        case .modelGallery(let provider): open(OnlineAPIPublicLinks.models(provider))
        case .billing(let provider): open(OnlineAPIPublicLinks.billing(provider))
        }
    }
}

/// Window close is independent of SwiftUI disappearance; switching to a public guide browser stays open.
struct OnlineAPIWindowCloseGuard: NSViewRepresentable {
    let closed: () -> Void
    func makeNSView(context: Context) -> CloseView { let view = CloseView(); view.closed = closed; return view }
    func updateNSView(_ nsView: CloseView, context: Context) { nsView.closed = closed }
    final class CloseView: NSView {
        var closed: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); NotificationCenter.default.removeObserver(self)
            if let window { NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window) }
        }
        @objc private func windowClosed(_ notification: Notification) { closed?() }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private struct OnlineAPICardReveal: AnimatableModifier {
    nonisolated var fraction: CGFloat
    nonisolated var animatableData: CGFloat { get { fraction } set { fraction = newValue } }
    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: fraction, anchor: .top).opacity(Double(fraction))
    }
}

func apiTag(_ text: String, palette: OnlineAPIPalette) -> some View {
    Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.accent)
        .padding(.horizontal, 6).frame(height: 18).background(palette.accent.opacity(palette.dark ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 5))
}
extension View {
    func apiCard(_ palette: OnlineAPIPalette) -> some View {
        background(palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line))
            .shadow(color: .black.opacity(palette.dark ? 0 : 0.05), radius: 1, y: 1)
    }
}
enum OnlineAPIPublicLinks {
    static func key(_ provider: OnlineAPIProvider) -> String {
        switch provider {
        case .aliyunBailian: CloudEntry.keyPageURL
        case .aliyunIntl: "https://modelstudio.console.alibabacloud.com/"
        case .groq: "https://console.groq.com/keys"
        case .openai: "https://platform.openai.com/api-keys"
        case .siliconflow: "https://cloud.siliconflow.cn/account/ak"
        }
    }
    static func quota(_ provider: OnlineAPIProvider) -> String {
        provider == .aliyunBailian ? CloudEntry.freeQuotaURL : key(provider)
    }
    static func models(_ provider: OnlineAPIProvider) -> String {
        provider == .aliyunBailian ? "https://bailian.console.aliyun.com/cn-beijing/model-market" : key(provider)
    }
    static func billing(_ provider: OnlineAPIProvider) -> String {
        provider == .openai ? "https://platform.openai.com/settings/organization/billing/overview" : quota(provider)
    }
}
