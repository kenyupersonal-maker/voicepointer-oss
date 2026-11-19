import AppKit
import SwiftUI
import VoicePointerCore

extension Notification.Name {
    /// Posted by a skin editor window when it becomes visible or hidden. `object` is the skin key (a String) and
    /// `userInfo["active"]` a Bool. The live preview runs only while its window is visible.
    static var skinEditorActivityChanged: Notification.Name { Notification.Name("SkinEditorActivityChanged") }
}

/// The editor window of one skin with tunable parameters (Astra, black hole). There is one window per skin:
/// opening the editor again brings the same window to the front. See SkinEditorView.swift for its content.
@MainActor
final class SkinEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [HUDSkinID: SkinEditorWindowController] = [:]

    /// Opens (or focuses) the editor for `skin`. Does nothing for a skin without parameters.
    static func show(_ skin: HUDSkinID) {
        guard SkinParamStore.shared.hasParams(skin) else { return }
        let controller: SkinEditorWindowController
        if let existing = controllers[skin] {
            controller = existing
        } else {
            controller = SkinEditorWindowController(skin: skin)
            controllers[skin] = controller
        }
        controller.showWindow(nil)
    }

    private let skin: HUDSkinID
    private var terminationObserver: (any NSObjectProtocol)?

    private init(skin: HUDSkinID) {
        self.skin = skin
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "编辑 " + skin.title
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 760))
        window.minSize = NSSize(width: 720, height: 620)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SkinEditorView(skin: skin))
        // Edits are saved a moment after the last change; make sure quitting right after one does not lose it.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { SkinParamStore.shared.flush() } // Posted on the main thread.
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        postActivity(true)
    }

    func windowWillClose(_ notification: Notification) {
        SkinParamStore.shared.flush()
        postActivity(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        postActivity(window.isVisible && window.occlusionState.contains(.visible))
    }

    private func postActivity(_ active: Bool) {
        NotificationCenter.default.post(
            name: .skinEditorActivityChanged, object: skin.rawValue, userInfo: ["active": active])
    }
}
