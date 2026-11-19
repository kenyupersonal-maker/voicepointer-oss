//  PermissionDragAssistant.swift  (VoicePointer app target)

import AppKit
import CoreGraphics
import VoicePointerCore

/// Drag-to-authorize helper, using the technique PermissionFlow and Permiso ship (see NOTES.md).
/// It opens the privacy pane by deep link and docks a small non-activating panel under the System
/// Settings window. The panel's app icon is a drag source carrying the app bundle's file URL;
/// dropping it onto the pane's list adds the app just like the "+" button. The user must then flip
/// the switch: macOS ignores synthetic clicks on privacy switches, and this code does not try.
/// The window is found with CGWindowListCopyWindowInfo reading only owner PID, layer, bounds and
/// alpha, which needs no Screen Recording permission (kCGWindowName would).
@MainActor
final class PermissionDragAssistant {
    /// Privacy panes whose app list accepts a dropped `.app` bundle.
    enum Kind: CaseIterable {
        case accessibility
        case inputMonitoring
        // Screen Recording later: add `case screenRecording`, anchor "Privacy_ScreenCapture" below,
        // and `CGPreflightScreenCaptureAccess()` in `isGranted(_:)`.

        /// Anchor of the pane inside Privacy & Security.
        var paneAnchor: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .inputMonitoring: return "Privacy_ListenEvent"
            }
        }

        /// Maps the anchor strings the settings views already use; nil for other panes (Microphone).
        init?(privacyAnchor: String) {
            guard let match = Self.allCases.first(where: { $0.paneAnchor == privacyAnchor }) else { return nil }
            self = match
        }
    }

    private struct Session {
        let kind: Kind
        var onGranted: (@MainActor () -> Void)?
        let panel: DragHelperPanel
        let content: DragHelperContentView
        var timers: [Timer] = []
        var lastSeenWindowAt: TimeInterval?
        var lastPanelFrame: NSRect?
    }

    static let shared = PermissionDragAssistant()
    private static let settingsBundleID = "com.apple.systempreferences"
    private var session: Session?

    private init() {}

    /// Opens the pane and shows the docked drag helper, replacing any running session.
    /// `onGranted` runs at most once, as soon as the permission is detected.
    func begin(_ kind: Kind, onGranted: @escaping @MainActor () -> Void) {
        dismiss()
        guard !Self.isGranted(kind) else {
            onGranted()
            return
        }
        let link = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?" + kind.paneAnchor
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else { return }

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        let icon = NSApplication.shared.applicationIconImage
            ?? NSWorkspace.shared.icon(forFile: bundleURL.path(percentEncoded: false))
        let content = DragHelperContentView(appName: appName, icon: icon, bundleURL: bundleURL)
        content.onClose = { [weak self] in self?.dismiss() }
        content.iconView.onDragStateChange = { [weak self] dragging in self?.setDropPassthrough(dragging) }

        session = Session(kind: kind, onGranted: onGranted, panel: DragHelperPanel(content: content), content: content)
        session?.timers = [
            makeTimer(every: DragHelperMetrics.dockInterval) { $0.updateDocking() },
            makeTimer(every: DragHelperMetrics.permissionInterval) { $0.checkPermission() },
            makeTimer(every: DragHelperMetrics.sessionTimeout, repeats: false) { $0.dismiss() },
        ]
        updateDocking()
    }

    /// Closes the helper, if any, and stops its timers. `onGranted` is not called.
    func dismiss() {
        guard let session else { return }
        self.session = nil
        session.timers.forEach { $0.invalidate() }
        session.panel.orderOut(nil)
        session.panel.close()
    }

    // MARK: - Session

    private static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility: return AccessibilityPermission.isTrusted
        case .inputMonitoring: return EventAccessPermission.canListen
        }
    }

    private func checkPermission() {
        guard let current = session, let callback = current.onGranted, Self.isGranted(current.kind) else { return }
        current.timers.forEach { $0.invalidate() }
        session?.onGranted = nil
        session?.timers = [makeTimer(every: DragHelperMetrics.grantedCloseDelay, repeats: false) { $0.dismiss() }]
        current.content.showGranted()
        callback() // Last, because it may call begin(), which cleanly replaces this session.
    }

    private func updateDocking() {
        guard let current = session else { return }
        let panel = current.panel
        let now = ProcessInfo.processInfo.systemUptime
        guard let window = Self.systemSettingsWindowFrame() else {
            // Not seen yet: keep waiting (the lifetime timer covers "never appears").
            guard let lastSeen = current.lastSeenWindowAt else { return }
            if now - lastSeen >= DragHelperMetrics.closeAfterMissing {
                dismiss() // Closed, minimised, or left behind on another Space.
            } else if now - lastSeen >= DragHelperMetrics.hideAfterMissing, panel.isVisible {
                panel.orderOut(nil)
            }
            return
        }
        session?.lastSeenWindowAt = now
        let target = Self.dockedFrame(for: window, panelSize: DragHelperMetrics.panelSize)
        if target != current.lastPanelFrame { // Only move when the target actually changed.
            panel.setFrame(target, display: true)
            session?.lastPanelFrame = target
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// During a drag the panel lets the drop fall through to the list underneath; this matters when
    /// it had to sit inside the window's bottom area (PermissionFlow does the same).
    private func setDropPassthrough(_ dragging: Bool) {
        session?.panel.ignoresMouseEvents = dragging
        session?.panel.alphaValue = dragging ? 0.72 : 1
    }

    /// Main-run-loop timer in `.common` mode, so it keeps firing during drags and menu tracking.
    private func makeTimer(every interval: TimeInterval, repeats: Bool = true,
                           _ action: @escaping @MainActor @Sendable (PermissionDragAssistant) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
            guard let owner = self else { return }
            MainActor.assumeIsolated { action(owner) } // The main run loop fires it on the main thread.
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: - System Settings window

    /// Largest on-screen, normal-level System Settings window, in AppKit coordinates. Largest rather
    /// than frontmost, so a sheet such as the "+" file picker is never mistaken for the window.
    private static func systemSettingsWindowFrame() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID)
            .map { $0.processIdentifier })
        guard !pids.isEmpty, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        var best: CGRect?
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width > 320, bounds.height > 240 // Skip popovers and small helper windows.
            else { continue }
            if bounds.area > (best?.area ?? 0) { best = bounds }
        }
        guard let cg = best else { return nil }
        // CG window space: origin at the top-left of the primary display, y grows down.
        // AppKit: origin at the bottom-left of the primary screen (screens[0]), y grows up.
        return NSRect(x: cg.minX, y: primary.frame.maxY - cg.maxY, width: cg.width, height: cg.height)
    }

    /// Centred 10 pt under the window; inside its bottom area when there is no room below.
    private static func dockedFrame(for window: NSRect, panelSize size: NSSize) -> NSRect {
        let screen = NSScreen.screens.max { $0.frame.intersection(window).area < $1.frame.intersection(window).area }
        let visible = screen.map { $0.frame.intersects(window) ? $0.visibleFrame : window } ?? window
        let gap = DragHelperMetrics.dockGap
        let x = min(max(window.midX - size.width / 2, visible.minX + gap), visible.maxX - size.width - gap)
        var y = window.minY - gap - size.height
        if y < visible.minY { y = max(window.minY + gap, visible.minY + gap) }
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

// MARK: - Panel and views

private enum DragHelperMetrics {
    static let panelSize = NSSize(width: 360, height: 104)
    static let cornerRadius: CGFloat = 14
    static let iconSize: CGFloat = 56
    static let dockGap: CGFloat = 10
    static let dockInterval: TimeInterval = 0.25
    static let permissionInterval: TimeInterval = 0.5
    static let hideAfterMissing: TimeInterval = 1
    static let closeAfterMissing: TimeInterval = 4
    static let grantedCloseDelay: TimeInterval = 1.2
    static let sessionTimeout: TimeInterval = 5 * 60
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Borderless, non-activating floating panel that never takes key or main status, so System
/// Settings stays the active app while the user drags.
private final class DragHelperPanel: NSPanel {
    convenience init(content: NSView) {
        self.init(contentRect: NSRect(origin: .zero, size: DragHelperMetrics.panelSize),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Rounded material card: icon (drag source) or green check, two lines of text, close button.
/// The card never resizes, so its subviews use fixed frames.
private final class DragHelperContentView: NSVisualEffectView {
    let iconView: DragHelperIconView
    var onClose: (() -> Void)?
    private let checkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "把图标拖进上面的列表")
    private let subtitleLabel: NSTextField
    private let closeButton = DragHelperCloseButton()

    init(appName: String, icon: NSImage, bundleURL: URL) {
        iconView = DragHelperIconView(bundleURL: bundleURL, icon: icon,
                                      label: "\(appName) 图标，拖到系统设置的列表里")
        subtitleLabel = NSTextField(labelWithString: "再打开 \(appName) 旁边的开关")
        super.init(frame: NSRect(origin: .zero, size: DragHelperMetrics.panelSize))
        material = .popover // Follows light and dark mode by itself.
        blendingMode = .behindWindow
        state = .active // Stay vibrant even though VoicePointer is not the active app.
        maskImage = Self.roundedMask(radius: DragHelperMetrics.cornerRadius)
        configureSubviews()
    }

    required init?(coder: NSCoder) { return nil }

    func showGranted() {
        iconView.isHidden = true
        checkView.isHidden = false
        titleLabel.stringValue = "已授权"
        subtitleLabel.stringValue = "可以关掉系统设置了"
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: "已授权"])
    }

    @objc private func closeClicked() {
        Task { @MainActor [weak self] in self?.onClose?() } // Next turn: don't free the panel mid-click.
    }

    private func configureSubviews() {
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let checkStyle = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
        checkView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已授权")?
            .withSymbolConfiguration(checkStyle)
        checkView.imageScaling = .scaleProportionallyUpOrDown
        checkView.isHidden = true

        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel("关闭")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let iconSize = DragHelperMetrics.iconSize
        let textX = 20 + iconSize + 14
        iconView.frame = NSRect(x: 20, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        checkView.frame = iconView.frame.insetBy(dx: 5, dy: 5)
        closeButton.frame = NSRect(x: bounds.maxX - 28, y: bounds.maxY - 28, width: 20, height: 20)
        let titleHeight = titleLabel.fittingSize.height
        let subtitleHeight = subtitleLabel.fittingSize.height
        titleLabel.frame = NSRect(x: textX, y: bounds.midY + 1, width: closeButton.frame.minX - 6 - textX,
                                  height: titleHeight)
        subtitleLabel.frame = NSRect(x: textX, y: bounds.midY - 3 - subtitleHeight, width: bounds.maxX - 16 - textX,
                                     height: subtitleHeight)
        for view in [iconView, checkView, titleLabel, subtitleLabel, closeButton] as [NSView] {
            addSubview(view)
        }
    }

    /// Stretchable rounded-rect mask; as the window's content view it also shapes the shadow.
    /// Nonisolated because AppKit may run an image's drawing handler on any thread.
    nonisolated private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Close button that works on the first click although its panel is never key.
private final class DragHelperCloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The app icon as an AppKit drag source carrying the app bundle URL.
private final class DragHelperIconView: NSView, NSDraggingSource {
    var onDragStateChange: ((Bool) -> Void)?
    private let bundleURL: URL
    private let icon: NSImage
    private var mouseDownPoint: NSPoint?
    private var retainedDuringDrag: DragHelperIconView? // AppKit keeps calling us until the drag ends.

    init(bundleURL: URL, icon: NSImage, label: String) {
        self.bundleURL = bundleURL
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: DragHelperMetrics.iconSize, height: DragHelperMetrics.iconSize))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // The panel is never key.
    override func mouseEntered(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        NSCursor.openHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownPoint = nil

        let dragImage = (icon.copy() as? NSImage) ?? icon // Resize a copy, never the shared app icon.
        dragImage.size = bounds.size
        let item = NSDraggingItem(pasteboardWriter: DragHelperPasteboardWriter(url: bundleURL))
        item.setDraggingFrame(bounds, contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [] // Never move/generic: a stray drop must not move the app.
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        retainedDuringDrag = self // Survives even if the session closes the panel mid-drag.
        onDragStateChange?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        retainedDuringDrag = nil
        onDragStateChange?(false)
    }
}

/// Writes the bundle URL in the flavours a Finder file drag carries, exactly as PermissionFlow does
/// (Permiso sends `.fileURL` only; PermissionFlow found System Settings accepts drags more reliably
/// when they look Finder-originated). NSPasteboardWriting is not main-actor isolated.
private final class DragHelperPasteboardWriter: NSObject, NSPasteboardWriting {
    private static var filenamesType: NSPasteboard.PasteboardType { .init("NSFilenamesPboardType") }
    private static var promisedURLType: NSPasteboard.PasteboardType { .init("com.apple.pasteboard.promised-file-url") }
    private let url: URL

    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, Self.filenamesType, Self.promisedURLType, .string]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL, Self.promisedURLType: return url.absoluteString
        case Self.filenamesType: return [url.path(percentEncoded: false)]
        case .string: return url.path(percentEncoded: false)
        default: return nil
        }
    }
}
