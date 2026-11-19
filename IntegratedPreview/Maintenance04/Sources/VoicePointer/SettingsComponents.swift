// T5 2026-10-02: Native settings components, evolved from ef388af RouteChoiceCard and status pill.
import AppKit
import SwiftUI
import VoicePointerCore

enum SettingsTone {
    case neutral, accent, success, warning, failure
    var color: Color {
        switch self { case .neutral: .secondary; case .accent: SettingsPalette.ink2; case .success: SettingsPalette.brand
        case .warning: Color(nsColor: .systemOrange); case .failure: Color(nsColor: .systemRed) }
    }
    init(_ health: EngineHealthState) {
        if health.isUnverified { self = .neutral; return }
        switch health { case .idle, .checking: self = .neutral; case .passed: self = .success; case .failed: self = .failure }
    }
}

struct SettingsCapsule: View {
    let text: String
    var tone: SettingsTone = .neutral
    var spinning = false
    var body: some View {
        // 2026-11-07 简洁版：不再是彩色胶囊，只是一个小圆点加文字。
        HStack(spacing: 5) {
            if spinning { ProgressView().controlSize(.mini).frame(width: 10, height: 10) }
            else if tone != .accent { Circle().fill(tone.color).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 11.5)).lineLimit(2)
                .foregroundStyle(tone == .neutral || tone == .success ? Color.secondary : tone.color)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

struct RecognitionIcon: View {
    let method: RecognitionMethod
    var size: CGFloat = 28
    var tint: Color {
        switch method { case .doubao: Color(red: 0.14, green: 0.49, blue: 0.98)
        case .local: Color(red: 0.19, green: 0.73, blue: 0.40); case .online: Color(red: 0.60, green: 0.36, blue: 0.93) }
    }
    var symbol: String {
        switch method { case .doubao: "bubble.left.and.text.bubble.right.fill"; case .local: "cpu"; case .online: "cloud.fill" }
    }
    /// The line icon used on the settings cards.
    /// The Doubao input method's own monochrome mark (the one it shows in the menu bar), read once from the
    /// installed Doubao bundle as a template image (Ken, 2026-11-07). Only that one image file is read; nothing of
    /// Doubao's is shipped with VoicePointer. nil when Doubao is not installed: the card then shows a symbol.
    @MainActor static let doubaoMark: NSImage? = {
        let candidates = [URL(fileURLWithPath: "/Library/Input Methods/DoubaoIme.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/DoubaoIme.app"),
                          URL(fileURLWithPath: "/Applications/DoubaoIme.app")]
        for app in candidates {
            let url = app.appendingPathComponent("Contents/Resources/menu_icon.pdf")
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }()

    static func plainSymbol(_ method: RecognitionMethod) -> String {
        // Filled glyphs in the card tiles (Ken, 2026-11-07).
        switch method { case .doubao: "bubble.left.and.bubble.right.fill"; case .local: "macbook"; case .online: "cloud.fill" }
    }
    var body: some View {
        Group {
            if method == .doubao, let url = Bundle.main.url(forResource: "doubao", withExtension: "png", subdirectory: "Icons"),
               let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.gradient)
                    .overlay { Image(systemName: symbol).font(.system(size: size * 15 / 28, weight: .semibold)).foregroundStyle(.white) }
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct RecognitionCard: View {
    let method: RecognitionMethod
    let title: String
    let detail: String
    let state: EngineHealthState
    let idle: String
    let selected: Bool
    var statusText: String? = nil
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    // 2026-11-07 简洁版：单色线条图标，选中时用强调色，不再是彩色方块。
                    // The same icon tile as every settings row (Ken, 2026-11-07), a little larger on a card.
                    SettingsIconTile(symbol: RecognitionIcon.plainSymbol(method), size: 32, emphasized: selected,
                                     image: method == .doubao ? RecognitionIcon.doubaoMark : nil)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                            .symbolRenderingMode(.palette).foregroundStyle(SettingsPalette.card, SettingsPalette.ink)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                        .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                    if let help { InfoPopoverButton(text: help) }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !caption.isEmpty {
                    SettingsCapsule(text: caption, tone: SettingsTone(state))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading).padding(12)
            .background(SettingsPalette.card,
                        in: RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                .strokeBorder(selected ? SettingsPalette.ink : hovering ? SettingsPalette.tileHover : SettingsPalette.hairline,
                              lineWidth: SettingsLayout.stroke) }
            .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityLabel(title + (caption.isEmpty ? "" : ", " + caption))
        .accessibilityValue(selected ? SettingsStrings.select : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var caption: String { statusText ?? SettingsStrings.status(state, idle: idle) }
}

struct CheckStatusRow: View {
    let state: EngineHealthState
    let provider: String
    var primaryAction = true
    var checking = false
    var resultDetail: String? = nil
    let recheck: () -> Void
    let next: (HealthNextAction) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if state == .checking { ProgressView().controlSize(.small) }
                else { Image(systemName: icon).font(.system(size: 18)).foregroundStyle(SettingsTone(state).color) }
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(SettingsStrings.status(state)).font(.system(size: 13, weight: .semibold))
                Text(resultDetail ?? SettingsStrings.detail(state, provider: provider)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Button(checking ? SettingsStrings.checkBusy : SettingsStrings.check, action: recheck).buttonStyle(SettingsLinkButtonStyle()).disabled(checking)
                    .accessibilityLabel(SettingsStrings.check)
                if case .failed(_, let action) = state {
                    if primaryAction {
                        Button(SettingsStrings.nextAction(action)) { next(action) }.buttonStyle(.borderedProminent).controlSize(.small)
                    } else {
                        Button(SettingsStrings.nextAction(action)) { next(action) }.buttonStyle(SettingsButtonStyle())
                    }
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(Color.primary.opacity(scheme == .dark ? 0.05 : 0.03), in: RoundedRectangle(cornerRadius: 10))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: state)
        .accessibilityElement(children: .contain).accessibilityValue(SettingsStrings.status(state))
    }
    private var icon: String {
        if state.isUnverified { return "circle.dotted" }
        return switch state { case .idle: "circle.dotted"; case .checking: "hourglass"; case .passed: "checkmark.circle.fill"; case .failed: "exclamationmark.circle.fill" }
    }
}

struct InfoPopoverButton: View {
    let text: String
    var question = false
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            // A small circled mark at the title's cap height, not a badge (Ken, 2026-11-07).
            Image(systemName: question ? "questionmark.circle" : "exclamationmark.circle")
                .font(.system(size: 11.5, weight: .regular)).foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(SettingsStrings.help)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 260, alignment: .leading).padding(12)
            }
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String
    let help: String
    @Binding var isOn: Bool
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            if let icon { SettingsIconTile(symbol: icon) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) { Text(title).font(.system(size: 13)); InfoPopoverButton(text: help) }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).toggleStyle(SettingsBareSwitchStyle()).accessibilityLabel(title)
        }.accessibilityElement(children: .contain)
    }
}

struct GoConfigureRow: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(title, icon: icon)
            Spacer(minLength: 8)
            Button(action: action) { Label(SettingsStrings.configure, systemImage: "chevron.right") }
                .buttonStyle(SettingsLinkButtonStyle()).accessibilityLabel(SettingsStrings.configure)
        }
    }
}

struct ModelRow: View {
    let model: LocalModelItem
    let inUse: Bool
    var primaryDownload = true
    let action: (LocalModelAction) -> Void
    let verify: () -> Void
    @State private var deleteAsked = false
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { if model.state == .ready || model.state == .needsVerification { action(.use) } } label: {
            HStack(spacing: 12) {
            Image(systemName: inUse ? "largecircle.fill.circle" : "circle").foregroundStyle(inUse ? SettingsPalette.brand : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name).font(.system(size: 13, weight: .semibold))
                    if model.recommended { SettingsCapsule(text: SettingsStrings.recommended, tone: .accent) }
                }
                Text(SettingsStrings.modelDescription(model))
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                if case .notApplicable(let reason) = model.state {
                    Text(SettingsStrings.failure(reason)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            modelActions
        }
        .contentShape(Rectangle())
        .confirmationDialog(SettingsStrings.modelDeleteButton(model), isPresented: $deleteAsked) {
            Button(SettingsStrings.delete, role: .destructive) { if !inUse { action(.delete) } }
            Button(SettingsStrings.cancel, role: .cancel) {}
        } message: { Text(SettingsStrings.modelDeleteWarning(model)) }
        .opacity(isUnsuitable ? 0.6 : 1)
        .accessibilityElement(children: .contain).accessibilityLabel(model.name)
    }
    private var isUnsuitable: Bool { if case .notApplicable = model.state { true } else { false } }
    @ViewBuilder private var modelActions: some View {
        switch model.state {
        case .notDownloaded:
            Button(SettingsStrings.modelDownloadButton(model)) { action(.download) }.buttonStyle(SettingsButtonStyle())
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: progress).frame(width: 120)
                HStack(spacing: 8) { Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.system(size: 12))
                    Button(SettingsStrings.cancel) { action(.cancel) }.buttonStyle(SettingsLinkButtonStyle()) }
                Text(SettingsStrings.downloadRemaining(model.remainingSeconds)).font(.caption).foregroundStyle(.secondary)
            }
        case .converting, .verifying:
            VStack(alignment: .trailing, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.state == .converting ? SettingsStrings.convertForMac : SettingsStrings.verifyingModel).font(.caption)
                Button(SettingsStrings.cancel) { action(.cancel) }.buttonStyle(SettingsLinkButtonStyle())
            }.fixedSize(horizontal: true, vertical: false)
        case .ready, .needsVerification:
            HStack(spacing: 12) {
                if inUse { Text(SettingsStrings.inUse).font(.caption).foregroundStyle(SettingsPalette.brand) }
                modelMenu
            }
        case .notApplicable: SettingsCapsule(text: SettingsStrings.unsuitable, tone: .warning)
        case .corrupt:
            VStack(alignment: .trailing, spacing: 8) {
                SettingsCapsule(text: SettingsStrings.corrupt, tone: .failure)
                Button(SettingsStrings.redownload) { action(.download) }.buttonStyle(SettingsButtonStyle())
                modelMenu
            }
        }
    }
    private var modelMenu: some View {
        Menu {
            Button(SettingsStrings.recheckModelFiles, action: verify)
            Button(SettingsStrings.modelDeleteButton(model), role: .destructive) { deleteAsked = true }
                .disabled(inUse).help(inUse ? SettingsStrings.switchBeforeModelDelete : SettingsStrings.modelDeleteWarning(model))
            if inUse { Text(SettingsStrings.switchBeforeModelDelete) }
            if let bytes = model.originalDownloadBytes, !model.offersOriginalRemoval {
                Button(SettingsStrings.originalDeleteButton(bytes), role: .destructive) { action(.deleteOriginal) }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(model.name)
    }
}

struct GuideCard: View {
    let title: String
    let steps: [String]
    let actionTitle: String
    let documentationURL: URL
    let action: () -> Void
    var documentation: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(index + 1)).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(SettingsPalette.ink, in: Circle())
                    Text(step).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.small)
                if let documentation {
                    Button(action: documentation) { Label(SettingsStrings.documentation, systemImage: "arrow.up.right.square") }.buttonStyle(SettingsLinkButtonStyle())
                } else {
                    Link(destination: documentationURL) { Label(SettingsStrings.documentation, systemImage: "arrow.up.right.square") }.buttonStyle(SettingsLinkButtonStyle())
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct KeyArea: View {
    let saved: Bool
    @Binding var keyDraft: String
    @Binding var label: String
    let busy: Bool
    let helpURL: URL
    var focusTicket = 0
    let save: () -> Void
    let remove: () -> Void
    let documentation: () -> Void
    @FocusState private var keyFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if saved {
                HStack { SettingsCapsule(text: SettingsStrings.saved, tone: .success); Spacer()
                    Button(SettingsStrings.delete, role: .destructive, action: remove).buttonStyle(SettingsButtonStyle()) }
            } else {
                HStack(spacing: 12) {
                    Text(SettingsStrings.keyGuideTitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    Link(SettingsStrings.keyHelp, destination: helpURL).buttonStyle(SettingsLinkButtonStyle())
                    Button(SettingsStrings.documentation, action: documentation).buttonStyle(SettingsLinkButtonStyle())
                }.font(.system(size: 12))
                SecureField(SettingsStrings.keyPlaceholder, text: $keyDraft).textFieldStyle(.roundedBorder).focused($keyFocused)
                    .accessibilityLabel(SettingsStrings.keyPlaceholder).onSubmit(save)
                HStack(spacing: 12) {
                    TextField(SettingsStrings.optionalLabel, text: $label).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(SettingsStrings.optionalLabel)
                    Button(SettingsStrings.save, action: save).buttonStyle(SettingsButtonStyle())
                        .disabled(busy || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.onChange(of: focusTicket) { _, _ in keyFocused = true }
            .onAppear { if focusTicket > 0 { keyFocused = true } }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    var body: some View {
        LabeledContent(title) { Text(value).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit() }
    }
}

struct SettingsDisclosure<Content: View>: View {
    let title: String
    var count: Int? = nil
    @ViewBuilder let content: () -> Content
    @State private var expanded: Bool

    init(
        title: String,
        count: Int? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.count = count
        self.content = content
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded, content: content) {
            HStack(spacing: 8) { Text(title); if let count, count > 0 { SettingsCapsule(text: String(count), tone: .accent) } }
        }.accessibilityLabel(title)
    }
}

struct APIKeyGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(SettingsStrings.apiGuideTitle).font(.system(size: 18, weight: .semibold))
            ScrollView { Text((try? AttributedString(markdown: SettingsStrings.apiGuideMarkdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(SettingsStrings.apiGuideMarkdown))
                .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            HStack { Spacer(); Button(SettingsStrings.close) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 500, height: 440)
    }
}

struct OnboardingRecognitionChoice: View {
    let method: RecognitionMethod
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
        Group {
            if method == .doubao {
                HStack(spacing: 16) {
                    RecognitionIcon(method: method, size: 54)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(SettingsStrings.doubao).font(.system(size: 16, weight: .semibold))
                            Text(SettingsStrings.recommended).font(.system(size: 10)).foregroundStyle(OnboardingStyle.accent)
                                .padding(.horizontal, 6).padding(.vertical, 3).background(OnboardingStyle.accent.opacity(0.12), in: Capsule())
                        }
                        Text(SettingsStrings.doubaoDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(SettingsStrings.onboardingDoubaoNeedsInstall).font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Color.secondary.opacity(0.08), in: Capsule())
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26).background(Color.secondary.opacity(0.08), in: Circle())
                }.padding(16).frame(minHeight: 112).background(OnboardingStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(OnboardingStyle.accent.opacity(0.7), lineWidth: 1.5))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        RecognitionIcon(method: method)
                        Text(method == .local ? SettingsStrings.local : SettingsStrings.online)
                            .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(method == .local ? SettingsStrings.localDetail : SettingsStrings.onlineDetail)
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(method == .local ? SettingsStrings.onboardingLocalRouteDetail : SettingsStrings.onboardingOnlineRouteDetail)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .frame(width: 26, height: 26).background(Color.secondary.opacity(0.08), in: Circle())
                    }
                }.padding(16).frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }
        }
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .offset(y: hovered ? -1.5 : 0)
            .onHover { hovered = $0 }
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .accessibilityLabel(method == .doubao ? SettingsStrings.doubao : method == .local ? SettingsStrings.local : SettingsStrings.online)
    }
}
