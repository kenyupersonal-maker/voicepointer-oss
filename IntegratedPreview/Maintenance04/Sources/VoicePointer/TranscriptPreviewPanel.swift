import AppKit
import VoicePointerCore

/// Native transcript preview panel for IntegratedPreview.
/// An ordinary utility panel (reuses existing HUD style conventions, no new radial style).
/// All UI access is main-actor; no activation, no focus stealing, no send/undo calls.
@MainActor
final class TranscriptPreviewPanel: NSWindowController {

    // MARK: - State

    /// Current session this panel is displaying. Read-only to callers.
    private(set) var sessionID: UUID?

    private var hasBeenPositioned = false

    // MARK: - UI Elements

    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView: NSTextView = {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 15)
        tv.textColor = .labelColor
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 4
        return tv
    }()

    private let copyButton = NSButton(title: "复制", target: nil, action: nil)

    // MARK: - Init

    /// Constructs the window only. No side effects at launch beyond window construction.
    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "转写预览"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .windowBackgroundColor
        super.init(window: panel)
        setupContentView(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for TranscriptPreviewPanel")
    }

    // MARK: - Layout

    private func setupContentView(in panel: NSPanel) {
        guard let content = panel.contentView else { return }

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        textView.frame = NSRect(x: 0, y: 0, width: 420, height: 110)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        copyButton.bezelStyle = .rounded
        copyButton.toolTip = "复制当前文字"
        copyButton.target = self
        copyButton.action = #selector(copyCurrentText(_:))
        copyButton.isEnabled = false

        let stack = NSStackView(views: [statusLabel, scrollView])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [NSView(), copyButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        // Spacer pushes copy button to the trailing edge.
        if let spacer = footer.arrangedSubviews.first {
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        footer.alignment = .centerY

        let root = NSStackView(views: [stack, footer])
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            stack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
    }

    // MARK: - Positioning

    /// Position at bottom-right of the visible frame once, only while hidden.
    private func positionIfNeeded() {
        guard !hasBeenPositioned, let panel = window as? NSPanel else { return }
        let visible = NSScreen.main?.visibleFrame ?? .zero
        guard visible.width > 0, visible.height > 0 else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.maxX - size.width - 24,
                y: visible.minY + 24
            )
        )
        hasBeenPositioned = true
    }

    // MARK: - Event Consumption

    /// Consume a speech input event for the preview.
    /// The first event of a session establishes the current session and clears prior text.
    func consume(_ event: SpeechInputEvent) {
        // .stopped is an external route that is never passed here; ignore defensively.
        guard event.kind != .stopped else { return }

        if event.sessionID != sessionID {
            sessionID = event.sessionID
            textView.string = ""
        }

        switch event.kind {
        case .ready:
            statusLabel.stringValue = "录音中"
        case .partial:
            statusLabel.stringValue = "转写中"
            setDisplayedText(event.text ?? "")
        case .final:
            statusLabel.stringValue = "正在交付"
            setDisplayedText(event.text ?? "")
        case .failed:
            statusLabel.stringValue = "未完成，文字保留在此"
        case .stopped:
            break // handled above
        }

        updateCopyButtonState()
        showPanel()
    }

    /// Display text with a hard guard at 50,000 UTF-16 code units.
    /// Oversized text is not displayed or silently truncated; the original
    /// record must be preserved by the separate journal integration.
    private func setDisplayedText(_ text: String) {
        if text.utf16.count > 50_000 {
            // Do not truncate; mark the condition explicitly.
            textView.string = ""
            statusLabel.stringValue = "文本过长，未显示"
            return
        }
        textView.string = text
    }

    private func updateCopyButtonState() {
        copyButton.isEnabled = !textView.string.isEmpty
    }

    private func showPanel() {
        guard let panel = window as? NSPanel else { return }
        if !panel.isVisible {
            positionIfNeeded()
        }
        // Only order front. Never makeKey, never activate NSApp, never move focus.
        panel.orderFront(nil)
    }

    // MARK: - Completion

    /// Handle a delivery outcome. Only affects the panel when `id` matches the
    /// current session, so a stale completion cannot hide a newer session's panel.
    func complete(outcome: ComposerActionOutcome, sessionID id: UUID) {
        guard id == sessionID else { return }

        let feedback = ComposerActionFeedback(outcome: outcome)
        if !feedback.shouldPresent {
            (window as? NSPanel)?.orderOut(nil)
            return
        }

        switch outcome {
        case .kept, .sent, .undoSubmitted, .nothingToSend:
            // Retain final text in memory until reset; hide the panel.
            (window as? NSPanel)?.orderOut(nil)
            // Text stays in the text view for copy-after-close (unconfirmed only).
            // reset() clears session/text explicitly.
        default:
            // Warning / other outcomes: keep visible, show feedback, text remains.
            statusLabel.stringValue = feedback.message
            updateCopyButtonState()
        }
    }

    // MARK: - Reset

    /// Hide the panel and clear session, text, and status.
    func reset() {
        (window as? NSPanel)?.orderOut(nil)
        sessionID = nil
        textView.string = ""
        statusLabel.stringValue = ""
        copyButton.isEnabled = false
    }

    // MARK: - Copy Action

    /// Explicit user action only. The only code path that touches NSPasteboard.general.
    /// Intentional global copy; a button inside a nonactivating panel is acceptable.
    @objc private func copyCurrentText(_ sender: Any?) {
        let text = textView.string
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
