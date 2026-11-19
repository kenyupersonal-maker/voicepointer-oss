import AppKit
import SwiftUI
import VoicePointerCore

struct OnlineAPIGuideView: View {
    @ObservedObject var model: OnlineAPISetupModel
    let context: OnlineAPISetupContext
    @Environment(\.colorScheme) private var colorScheme
    private var palette: OnlineAPIPalette { .init(dark: colorScheme == .dark) }
    var body: some View {
        VStack(spacing: 0) {
            Text(OnlineAPIStrings.guideTitle).font(.system(size: 22, weight: .semibold)).fontWeight(.semibold).frame(height: 32)
            Text(model.guideProvider.isAliyun ? OnlineAPIStrings.guideAliSubtitle : OnlineAPIStrings.guideGroqSubtitle)
                .font(.system(size: 13, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.secondary).frame(height: 19).padding(.top, 7)
            HStack(spacing: 2) {
                ForEach(model.market.guideProviders, id: \.self) { provider in
                    Button { model.guideProvider = provider } label: {
                        HStack(spacing: 6) {
                            Text(OnlineAPIStrings.guideProvider(provider))
                            if provider == model.market.guideProviders.first { apiTag(OnlineAPIStrings.recommended, palette: palette) }
                        }.font(.system(size: 12.5, weight: model.guideProvider == provider ? .semibold : .regular))
                            .foregroundStyle(model.guideProvider == provider ? Color.primary : palette.secondary)
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(model.guideProvider == provider ? palette.card : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(2).background(palette.softLine, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 14)
            Button(OnlineAPIStrings.openAIKeyLink) { open(OnlineAPIPublicLinks.key(.openai)) }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.accent).padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(OnlineAPIStrings.guideSteps(model.guideProvider).enumerated()), id: \.offset) { index, step in
                    if index > 0 { Divider().overlay(palette.softLine) }
                    HStack(alignment: .top, spacing: 14) {
                        Text(String(index + 1)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(palette.accent, in: Circle()).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).font(.system(size: 13.5, weight: .semibold)).fontWeight(.semibold).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(step.detail).font(.system(size: 12, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.secondary).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if let title = step.button {
                                HStack(spacing: 8) {
                                    Button(title) { open(OnlineAPIPublicLinks.key(model.guideProvider)) }
                                        .font(.system(size: 12, weight: .regular)).fontWeight(.regular).buttonStyle(.plain).padding(.horizontal, 10).frame(height: 26)
                                        .background(palette.card, in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.line))
                                    if let via = step.via {
                                        Label(via, systemImage: model.guideProvider == .aliyunBailian ? "qrcode" : "person")
                                            .font(.system(size: 12, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.secondary).fixedSize()
                                    }
                                }.padding(.top, 5)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        OnlineAPIGuideIllustration(kind: index == 0 ? (model.guideProvider == .aliyunBailian ? .scan : .login) : index == 1 ? .create : .copy,
                                                   palette: palette)
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }
            }.padding(.vertical, 4).apiCard(palette).padding(.top, 12)
            Spacer(minLength: 0)
        }.padding(.horizontal, 40).padding(.top, context == .onboarding ? 56 : 28)
    }
    private func open(_ raw: String) { if let url = URL(string: raw) { NSWorkspace.shared.open(url) } }
}

/// Original schematic shapes, matching the reference SVG geometry; no provider logo or screenshot.
struct OnlineAPIGuideIllustration: View {
    enum Kind { case scan, login, create, copy }
    let kind: Kind
    let palette: OnlineAPIPalette
    var body: some View {
        ZStack(alignment: .topLeading) {
            palette.window
            switch kind {
            case .scan:
                box(8, 8, 48, 48, 6, fill: palette.card, stroke: palette.line)
                ForEach(Array([(15.0, 15.0), (38.0, 15.0), (15.0, 38.0)].enumerated()), id: \.offset) { _, point in
                    box(point.0, point.1, 11, 11, 2, fill: Color.primary.opacity(0.7))
                }
                box(33, 33, 5, 5, 0, fill: Color.primary.opacity(0.7))
                box(41, 41, 5, 5, 0, fill: Color.primary.opacity(0.7))
                box(72, 6, 34, 52, 7, fill: palette.card, stroke: palette.line)
                box(78, 15, 22, 22, 3, fill: .clear, stroke: palette.accent, lineWidth: 2)
                Rectangle().fill(palette.accent).frame(width: 22, height: 1.5).offset(x: 78, y: 26)
            case .login:
                box(14, 8, 92, 48, 6, fill: palette.card, stroke: palette.line)
                box(26, 18, 68, 9, 4.5, fill: palette.softLine)
                box(26, 33, 68, 11, 5.5, fill: .clear, stroke: palette.accent, lineWidth: 1.6)
                Circle().fill(palette.accent).frame(width: 6, height: 6).offset(x: 33, y: 35.5)
                box(43, 36.5, 40, 4, 2, fill: palette.line)
            case .create:
                box(6, 8, 108, 50, 5, fill: palette.card, stroke: palette.line)
                box(12, 14, 36, 5, 2.5, fill: palette.line)
                box(72, 12, 36, 11, 3, fill: palette.accent)
                box(68, 8, 44, 19, 6, fill: .clear, stroke: palette.accent.opacity(0.55), lineWidth: 1.6)
                box(12, 33, 96, 7, 2, fill: palette.softLine)
                box(12, 45, 96, 7, 2, fill: palette.softLine)
            case .copy:
                box(6, 8, 108, 50, 5, fill: palette.card, stroke: palette.line)
                box(12, 26, 96, 16, 3, fill: palette.accent.opacity(palette.dark ? 0.18 : 0.10))
                box(18, 32, 56, 4, 2, fill: Color.primary.opacity(0.55))
                box(88, 28, 12, 12, 3, fill: .clear, stroke: palette.accent, lineWidth: 1.6)
                box(91, 31, 5, 6, 1, fill: .clear, stroke: palette.accent, lineWidth: 1.2)
                Circle().stroke(palette.accent.opacity(0.4), lineWidth: 1.4).frame(width: 20, height: 20).offset(x: 84, y: 24)
            }
        }.frame(width: 120, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line)).accessibilityHidden(true)
    }
    private func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double,
                     fill: Color, stroke: Color = .clear, lineWidth: Double = 1) -> some View {
        RoundedRectangle(cornerRadius: radius).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke, lineWidth: lineWidth))
            .frame(width: width, height: height).offset(x: x, y: y)
    }
}
