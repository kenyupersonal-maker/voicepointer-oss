import AppKit
import SwiftUI
@preconcurrency import WebKit
import VoicePointerCore

@MainActor
struct OnboardingCompletionView: View {
    let localRoute: Bool
    let enhancementEnabled: Bool
    let configureCloud: () -> Void
    var deviceFixture: CompletionDeviceSelection? = nil
    var staticFrame: Double? = nil
    var sceneFixture: String? = nil
    var selectedDeviceFixture: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var devices = CompletionDeviceSelection.trackpad
    @State private var device = "trackpad"
    @State private var scene = "up"
    @State private var progress = 0.0
    @State private var visible = true
    @State private var failed = false

    init(localRoute: Bool, enhancementEnabled: Bool, configureCloud: @escaping () -> Void,
         deviceFixture: CompletionDeviceSelection? = nil, staticFrame: Double? = nil, sceneFixture: String? = nil,
         selectedDeviceFixture: String? = nil) {
        self.localRoute = localRoute; self.enhancementEnabled = enhancementEnabled; self.configureCloud = configureCloud
        self.deviceFixture = deviceFixture; self.staticFrame = staticFrame; self.sceneFixture = sceneFixture
        self.selectedDeviceFixture = selectedDeviceFixture
        _scene = State(initialValue: sceneFixture ?? "up")
        _device = State(initialValue: selectedDeviceFixture ?? (deviceFixture == .mouse ? "mouse" : "trackpad"))
    }

    var body: some View {
        VStack(spacing: 6) {
            if !failed {
                ZStack(alignment: .topLeading) {
                    CompletionDemoWebView(device: device, dark: colorScheme == .dark,
                        reduce: reduceMotion, active: visible, scene: $scene, progress: $progress,
                        failed: $failed, staticFrame: staticFrame)
                        .id(staticFrame == nil ? "live" : device)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    Group {
                        if devices == .both {
                            Picker("演示设备", selection: $device) {
                                Text("触控板").tag("trackpad")
                                Text("妙控鼠标").tag("mouse")
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 164)
                        } else { Text(device == "mouse" ? "妙控鼠标" : "触控板").font(.system(size: 11, weight: .semibold)) }
                    }.padding(.leading, 14).padding(.top, 12)
                }
                .frame(width: 560, height: 184)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("演示：按住手势说话；上推发送，原地松手只输入文字，下推取消并撤销。")
            }
            (Text(device == "mouse" ? "① 双指按压妙控鼠标并按住说话" : "① 三指按压触控板并按住说话")
                .fontWeight(.semibold).foregroundColor(.primary)
                + Text(device == "mouse" ? "　② 手指不松，整只鼠标往前推或往回拉，再松手" : "　② 手指不松，上滑或下滑，再松手")
                    .foregroundColor(.secondary))
                .font(.system(size: 12.5)).lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 10) {
                sceneCard("up", title: device == "mouse" ? "往前推" : "上推", detail: "发送", symbol: "arrow.up")
                sceneCard("stop", title: "原地松手", detail: "只输入文字", symbol: "circle.dotted")
                sceneCard("down", title: device == "mouse" ? "往回拉" : "下推", detail: "取消并撤销", symbol: "arrow.down")
            }
            if localRoute {
                    HStack(spacing: 12) {
                        Image(systemName: enhancementEnabled ? "checkmark" : "cloud.fill").foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(enhancementEnabled ? OnboardingStyle.accent : .purple, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(enhancementEnabled ? "云端增强已开启" : "让识别更准").fontWeight(.semibold)
                                if !enhancementEnabled { Text("可选").font(.system(size: 10)).foregroundStyle(.secondary) }
                            }
                            Text(enhancementEnabled ? "说话时由阿里云帮你校对本地结果，可在「设置 → 语音输入」里关闭。" : "接入阿里云，本地识别后由云端校对；声音会上传。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !enhancementEnabled {
                            Button("配置云端增强", action: configureCloud).buttonStyle(.bordered)
                        }
                    }.font(.system(size: 13)).padding(.horizontal, 14).frame(height: 56)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
            }
        }
        .onAppear {
            if let sceneFixture { scene = sceneFixture }
            devices = deviceFixture ?? CompletionDeviceSelection.resolve(kinds: MultitouchDriver().devices.map(\.kind))
            device = selectedDeviceFixture ?? (devices == .mouse ? "mouse" : "trackpad")
            visible = true
        }
        .onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in visible = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { event in
            if let window = event.object as? NSWindow, window.title == SettingsStrings.firstRunWindowCopy001 {
                visible = window.occlusionState.contains(.visible) && NSApp.isActive
            }
        }
    }
    private func sceneCard(_ value: String, title: String, detail: String, symbol: String) -> some View {
        Button {
            scene = value; progress = 0
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(scene == value ? Color.white : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(scene == value ? OnboardingStyle.accent : Color.secondary.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 50)
                .background(scene == value ? OnboardingStyle.accent.opacity(0.10) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(scene == value ? OnboardingStyle.accent.opacity(0.55) : Color(nsColor: .separatorColor)))
                .overlay(alignment: .bottomLeading) {
                    if scene == value && !reduceMotion {
                        GeometryReader { geometry in
                            Rectangle().fill(OnboardingStyle.accent).frame(width: geometry.size.width * progress, height: 2)
                        }.frame(height: 2).padding(.horizontal, 8)
                    }
                }
        }.buttonStyle(.plain).accessibilityLabel("\(title)，\(detail)")
    }
}

private final class PassiveCompletionWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { menu.removeAllItems() }
    override func scrollWheel(with event: NSEvent) {}
}

@MainActor
private struct CompletionDemoWebView: NSViewRepresentable {
    let device: String
    let dark: Bool
    let reduce: Bool
    let active: Bool
    @Binding var scene: String
    @Binding var progress: Double
    @Binding var failed: Bool
    let staticFrame: Double?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "demo")
        let view = PassiveCompletionWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.isInspectable = false
        view.allowsMagnification = false
        view.setAccessibilityElement(false)
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        guard let resource = Bundle.main.url(forResource: "completion-demo", withExtension: "html", subdirectory: "Onboarding") else {
            context.coordinator.fail(); return view
        }
        context.coordinator.resource = resource
        var target = resource
        if let staticFrame {
            var components = URLComponents(url: resource, resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "tt", value: String(staticFrame)), .init(name: "scene", value: scene),
                                    .init(name: "dev", value: device), .init(name: "dark", value: dark ? "1" : "0")]
            target = components.url ?? resource
        }
        view.loadFileURL(target, allowingReadAccessTo: resource.deletingLastPathComponent())
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.evaluateJavaScript("window.demo.stop()")
        nsView.stopLoading()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "demo")
        nsView.navigationDelegate = nil
        coordinator.webView = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: CompletionDemoWebView
        weak var webView: WKWebView?
        var resource: URL?
        var loaded = false
        var lastConfiguration = ""
        var lastScene = ""
        var lastActive: Bool?
        init(_ parent: CompletionDemoWebView) { self.parent = parent }
        func update() {
            guard loaded, parent.staticFrame == nil, let webView else { return }
            let configure = "window.demo.configure({device:'\(parent.device == "mouse" ? "mouse" : "trackpad")',dark:\(parent.dark),reduce:\(parent.reduce)})"
            if configure != lastConfiguration {
                webView.evaluateJavaScript(configure); lastConfiguration = configure; lastActive = nil
            }
            if parent.scene != lastScene, ["up", "stop", "down"].contains(parent.scene) {
                webView.evaluateJavaScript("window.demo.setScene('\(parent.scene)')"); lastScene = parent.scene; lastActive = nil
            }
            if lastActive != parent.active {
                webView.evaluateJavaScript(parent.active ? "window.demo.start()" : "window.demo.stop()")
                lastActive = parent.active
            }
        }
        func fail() {
            RuntimeTrace.record("onboarding demo state=unavailable")
            Task { @MainActor in self.parent.failed = true }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if parent.staticFrame == nil { update() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { fail() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { fail() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(url?.isFileURL == true && url?.standardizedFileURL.path == resource?.standardizedFileURL.path ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "demo", let body = message.body as? [String: Any],
                  let scene = body["scene"] as? String, ["up", "stop", "down"].contains(scene),
                  let progress = body["progress"] as? Double, progress.isFinite else { return }
            parent.scene = scene; parent.progress = min(1, max(0, progress)); lastScene = scene
        }
    }
}
