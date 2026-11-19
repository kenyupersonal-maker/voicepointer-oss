import AppKit
import SwiftUI
import VoicePointerCore

enum OnboardingStyle {
    static var accent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgbRed: dark ? 39/255 : 28/255, green: dark ? 174/255 : 154/255,
                           blue: dark ? 82/255 : 71/255, alpha: 1)
        })
    }
}

extension View {
    func onboardingCard(padding: CGFloat = 16) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, 16).frame(minWidth: 128, minHeight: 32)
            .background(enabled ? OnboardingStyle.accent : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct OnboardingModelCard: View {
    let model: LocalModelItem
    let action: (LocalModelAction) -> Void
    let verify: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            RecognitionIcon(method: .local, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name).font(.system(size: 13, weight: .semibold))
                    if model.recommended {
                        Text(SettingsStrings.recommended).font(.system(size: 10)).foregroundStyle(OnboardingStyle.accent)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(OnboardingStyle.accent.opacity(0.12), in: Capsule())
                    }
                }
                Text(SettingsStrings.modelSize(model.sizeBytes)).font(.system(size: 12)).foregroundStyle(.secondary)
                if case .downloading(let value) = model.state {
                    ProgressView(value: value).tint(OnboardingStyle.accent).frame(maxWidth: 320)
                    Text(value, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            switch model.state {
            case .notDownloaded: Button(SettingsStrings.download) { action(.download) }.buttonStyle(.bordered)
            case .downloading, .converting, .verifying:
                Button(SettingsStrings.cancel) { action(.cancel) }.buttonStyle(.bordered)
            case .ready: SettingsCapsule(text: SettingsStrings.ready, tone: .success)
            default: ModelRow(model: model, inUse: true, primaryDownload: false, action: action, verify: verify)
            }
        }.onboardingCard()
    }
}

struct PracticeInput: View {
    @Binding var text: String
    var compact = false
    var placeholder = "按住手势，说一句话试试。文字会出现在这里。"
    var onFocus: (Bool) -> Void = { _ in }
    var autoFocus = false
    @FocusState private var focused: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty { Text(placeholder).font(.system(size: 12)).foregroundStyle(.tertiary).padding(8) }
            TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden)
                .focused($focused)
                .onChange(of: focused) { _, value in onFocus(value) }
        }
        .frame(height: compact ? 52 : 124)
        .padding(4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
        .accessibilityLabel(placeholder)
        .onAppear { if autoFocus { focused = true } }
        .onDisappear { onFocus(false) }
    }
}
