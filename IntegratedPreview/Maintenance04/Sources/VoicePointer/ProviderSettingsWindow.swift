import AppKit
import SwiftUI
import VoicePointerCore

@MainActor
final class ProviderSettingsWindow: NSWindowController, NSWindowDelegate {
    struct Actions {
        var onSelectionChanged: () -> Void
        var modelState: (String) -> String
        var prepareModel: (String, String) async throws -> Void
        var credentialState: (String) -> String
        var onInteractionChanged: (Bool) -> Void
        var onRecheck: () -> Void
        var onShowOnboarding: () -> Void
        var onPermissionPageVisibilityChanged: (Bool) -> Void
    }

    private let store: ProviderSettingsStore
    private let actions: Actions
    private var permissionPageSelected = false

    init(store: ProviderSettingsStore, actions: Actions, initialMethod: RecognitionMethod? = nil, initialPage: SettingsPage? = nil) {
        self.store = store
        self.actions = actions

        let window = GlassActiveLookWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = SettingsStrings.providerSettingsWindowCopy001
        // 2026-11-07 简洁版：标题栏不再显示「设置」，每页顶上直接是页名（窗口标题仍是「设置」，供辅助功能和截图找窗口）。
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 860, height: 640))
        window.minSize = NSSize(width: 780, height: 560)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsRootView(
            providerStore: store,
            modelState: actions.modelState,
            prepareModel: actions.prepareModel,
            credentialState: actions.credentialState,
            onSelectionChanged: actions.onSelectionChanged,
            onInteractionChanged: actions.onInteractionChanged,
            onRecheck: actions.onRecheck,
            onShowOnboarding: actions.onShowOnboarding,
            onPermissionPageVisibilityChanged: { [weak self] selected in
                guard let self else { return }
                self.permissionPageSelected = selected
                let visible = self.window?.isVisible == true && self.window?.isMiniaturized == false
                self.actions.onPermissionPageVisibilityChanged(selected && visible)
            },
            initialMethod: initialMethod,
            initialPage: initialPage
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        actions.onPermissionPageVisibilityChanged(
            permissionPageSelected && window?.isVisible == true && window?.isMiniaturized == false
        )
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor [weak self] in
            guard let window = self?.window else { return }
            window.displayIfNeeded()
            if let line = ReleaseAcceptanceTrace.settingsShown(
                visible: window.isVisible && !window.isMiniaturized && window.contentView != nil,
                windowNumber: window.windowNumber) {
                RuntimeTrace.record(line)
            }
        }
    }

    internal func refreshAvailableStatuses() {
        NotificationCenter.default.post(name: .voicePointerSettingsChanged, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        actions.onPermissionPageVisibilityChanged(false)
        // The SwiftUI settings pages own no preview engine or long-running task.
    }

    func windowDidMiniaturize(_ notification: Notification) {
        actions.onPermissionPageVisibilityChanged(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        actions.onPermissionPageVisibilityChanged(permissionPageSelected && window?.isVisible == true)
    }
}
