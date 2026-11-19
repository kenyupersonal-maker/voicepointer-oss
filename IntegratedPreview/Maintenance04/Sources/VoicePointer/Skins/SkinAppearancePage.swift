import AppKit
import SwiftUI
import VoicePointerCore

@MainActor
struct SkinAppearancePage: View {
    @State private var selectedSkin = HUDSkinPreferences.shared.selection
    @State private var texture = HUDSkinPreferences.shared.defaultTexture
    @State private var previewDark = false
    @State private var pageIsVisible = false
    @State private var releaseTick = 0
    @State private var releaseAction: HUDRelease = .send
    @State private var shaderRevision = 0
    @State private var screenTrial = SkinScreenTrial()
    /// The preview follows the system's light/dark look, like the real disc does; the 浅色/深色 switch above
    /// the stage only overrides it until the system look changes (2026-11-07: it always started light).
    @Environment(\.colorScheme) private var systemScheme

    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 158), spacing: 14, alignment: .top)]

    var body: some View {
        SettingsPageBody(SettingsStrings.settingsRootViewCopy002) {
                VStack(alignment: .leading, spacing: 10) {
                    stage
                    stageControls
                }
                // Under the basic tiles, not above them: picking 经典 / 液态玻璃 must not move the tile under the
                // pointer (Ken, 2026-11-07: the page jumped and the outlines slid up and down).
                defaultSkinGroup
                if selectedSkin == .liquidGlass || selectedSkin == .classic {
                    LiquidGlassTuningSection(texture: selectedSkin == .classic ? .frost : texture)
                }
                skinGroup(title: SettingsStrings.skinGroupSmall, skins: HUDSkinID.small)
                SendSoundSection()
                Text(footerText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
        }
        .onAppear {
            selectedSkin = HUDSkinPreferences.shared.selection
            texture = HUDSkinPreferences.shared.defaultTexture
            previewDark = systemScheme == .dark
            pageIsVisible = true
            HUDShaderLibrary.shared.preparePreviews()
        }
        .onDisappear {
            pageIsVisible = false
            screenTrial.dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudShaderLibraryDidChange)) { _ in
            shaderRevision += 1
        }
        .onChange(of: systemScheme) { _, scheme in previewDark = scheme == .dark }
    }

    private var footerText: String {
        let base = SettingsStrings.skinAppearancePageCopy003
        return SkinParamStore.shared.isAvailable ? base + SettingsStrings.skinAppearancePageCopy004 : base
    }

    /// 2026-11-07 简洁版：和其他页一样只留页名。
    private var pageHeader: some View {
        Text(SettingsStrings.settingsRootViewCopy002)
            .font(.system(size: 22, weight: .bold))
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 2)
    }

    private var stage: some View {
        ZStack(alignment: .topLeading) {
            SkinStage(
                skin: selectedSkin,
                dark: previewDark,
                active: pageIsVisible && isReady(selectedSkin),
                releaseTick: releaseTick,
                releaseAction: releaseAction
            )
            .frame(maxWidth: .infinity)
            .frame(height: 300)

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                SettingsSegmented(selection: $previewDark, options: [
                    (false, SettingsStrings.skinAppearancePageCopy008),
                    (true, SettingsStrings.skinAppearancePageCopy009),
                ])
                .accessibilityLabel(SettingsStrings.skinAppearancePageCopy007)
            }
            .environment(\.colorScheme, previewDark ? .dark : .light)
            .padding(10)

            if !isReady(selectedSkin) {
                readinessMessage(for: selectedSkin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.colorScheme, previewDark ? .dark : .light)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                .strokeBorder(SettingsPalette.hairline, lineWidth: 1)
        }
    }

    /// 2026-09-29 Claude：按钮移到舞台下面。原来按钮条压在舞台底部，挡住圆盘下半圈和 Cancel。
    private var stageControls: some View {
        HStack(spacing: 8) {
            Button(SettingsStrings.skinAppearancePageCopy010) { playStageRelease(.send) }
            Button(SettingsStrings.skinAppearancePageCopy011) { playStageRelease(.cancel) }
            Spacer(minLength: 10)
            Button(SettingsStrings.skinAppearancePageCopy012) { screenTrial.play(selectedSkin) }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(!isReady(selectedSkin) || !isSupported(selectedSkin))
        }
        .controlSize(.small)
    }

    /// 「默认」: one tile and its 质感 (Ken, 2026-11-08). 清透/柔和 are the Liquid Glass skin, 磨砂 is the classic one.
    private var defaultSkinGroup: some View {
        let isDefault = selectedSkin == .classic || selectedSkin == .liquidGlass
        let tileSkin: HUDSkinID = texture == .frost ? .classic : .liquidGlass
        let options: [(value: HUDSkinPreferences.DefaultTexture, title: String)] = LiquidGlassSkin.isSupported
            ? [(.clear, SettingsStrings.skinTextureClear), (.soft, SettingsStrings.skinTextureSoft),
               (.frost, SettingsStrings.skinTextureFrost)]
            : [(.frost, SettingsStrings.skinTextureFrost)]
        return VStack(alignment: .leading, spacing: 10) {
            Text(SettingsStrings.skinAppearancePageCopy001)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
            HStack(alignment: .top, spacing: 18) {
                SkinTile(
                    skin: tileSkin,
                    selected: isDefault,
                    dark: previewDark,
                    active: pageIsVisible,
                    ready: true,
                    failed: false,
                    action: { pickTexture(texture) }
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(SettingsStrings.skinTextureLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    SettingsSegmented(selection: Binding(get: { texture }, set: { pickTexture($0) }), options: options)
                    Text(textureNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            // Astra keeps a whole disc too (Ken, 2026-11-10: 「Astra 那个算是大圆盘吧」).
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(HUDSkinID.bigDiscExtras, id: \.self) { id in tile(id) }
            }
        }
    }

    private var textureNote: String {
        guard LiquidGlassSkin.isSupported else { return SettingsStrings.skinTextureNeedsGlass }
        switch texture {
        case .clear: return SettingsStrings.skinTextureClearNote
        case .soft: return SettingsStrings.skinTextureSoftNote
        case .frost: return SettingsStrings.skinTextureFrostNote
        }
    }

    private func pickTexture(_ value: HUDSkinPreferences.DefaultTexture) {
        HUDSkinPreferences.shared.selectDefault(value)
        withAnimation(SettingsMotion.quick) {
            selectedSkin = HUDSkinPreferences.shared.selection
            texture = HUDSkinPreferences.shared.defaultTexture
        }
    }

    private func skinGroup(title: String, skins: [HUDSkinID]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(skins, id: \.self) { id in tile(id) }
            }
        }
    }

    private func tile(_ id: HUDSkinID) -> some View {
        SkinTile(
            skin: id,
            selected: selectedSkin == id,
            dark: previewDark,
            active: pageIsVisible && isReady(id),
            ready: isReady(id),
            failed: HUDShaderLibrary.shared.lastError != nil,
            action: { select(id) }
        )
    }

    private func select(_ id: HUDSkinID) {
        guard isSupported(id) else { return }
        HUDSkinPreferences.shared.select(id)
        selectedSkin = HUDSkinPreferences.shared.selection
        texture = HUDSkinPreferences.shared.defaultTexture
    }

    private func isReady(_ id: HUDSkinID) -> Bool {
        _ = shaderRevision
        return !id.isShaderSkin || HUDShaderLibrary.shared.isPrepared(id)
    }

    private func isSupported(_ id: HUDSkinID) -> Bool {
        id.isAvailableHere
    }

    private func playStageRelease(_ action: HUDRelease) {
        releaseAction = action
        releaseTick &+= 1
    }

    @ViewBuilder
    private func readinessMessage(for id: HUDSkinID) -> some View {
        VStack(spacing: 8) {
            if HUDShaderLibrary.shared.lastError == nil {
                ProgressView()
                Text(SettingsStrings.skinAppearancePageCopy013)
                    .font(.system(size: 11.5))
            } else {
                Image(systemName: "exclamationmark.circle")
                Text(SettingsStrings.skinAppearancePageCopy014)
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityLabel(SkinCatalog.title(id) + SettingsStrings.skinAppearancePageCopy015)
    }
}

@MainActor
private struct SkinTile: View {
    let skin: HUDSkinID
    let selected: Bool
    let dark: Bool
    let active: Bool
    let ready: Bool
    let failed: Bool
    let action: () -> Void
    @State private var hovered = false

    private var supported: Bool { skin.isAvailableHere }
    private var hasEditor: Bool { SkinParamStore.shared.hasParams(skin) }

    /// The 「编辑」 pill is a sibling of the card's button, not part of it: clicking it opens the editor
    /// and never changes the selected skin.
    var body: some View {
        ZStack(alignment: .topTrailing) {
            selectButton
            if hasEditor {
                editPill
                    .padding(.top, 7)
                    .padding(.trailing, 7)
            }
        }
    }

    private var selectButton: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                SkinThumb(skin: skin, dark: dark, active: active, animated: hovered)
                    .frame(width: 158, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? SettingsPalette.ink : SettingsPalette.hairline,
                                          lineWidth: SettingsLayout.stroke)
                    }
                    .overlay {
                        if skin.isShaderSkin && !ready {
                            VStack(spacing: 4) {
                                if !failed { ProgressView().controlSize(.small) }
                                Text(failed ? SettingsStrings.skinAppearancePageCopy016 : SettingsStrings.skinAppearancePageCopy017)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(9)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                    .shadow(color: Color.black.opacity(hovered ? 0.14 : 0), radius: 8, x: 0, y: 3)

                // 2026-11-07 简洁版：卡片下只写名字，一句话介绍放到鼠标悬停提示里。
                Text(SkinCatalog.title(skin))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 2)
            }
            .frame(width: 158, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(supported ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!supported)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(SkinCatalog.title(skin)))
        .accessibilityValue(Text(selected ? SettingsStrings.skinAppearancePageCopy018 : ""))
        .help(supported ? SkinCatalog.blurb(skin) : SettingsStrings.skinAppearancePageCopy019)
    }

    private var editPill: some View {
        Button {
            SkinEditorWindowController.show(skin)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                Text(SettingsStrings.lexiconSettingsPageCopy049)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5) }
            .environment(\.colorScheme, dark ? .dark : .light)
        }
        .buttonStyle(.plain)
        .help(SettingsStrings.lexiconSettingsPageCopy049 + SkinCatalog.title(skin))
        .accessibilityLabel(Text(SettingsStrings.skinAppearancePageCopy022 + SkinCatalog.title(skin)))
    }
}

@MainActor
private struct SkinStage: NSViewRepresentable {
    let skin: HUDSkinID
    let dark: Bool
    let active: Bool
    let releaseTick: Int
    let releaseAction: HUDRelease

    final class Coordinator {
        var lastReleaseTick = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SkinPreviewView {
        let view = SkinPreviewView(paper: .text)
        view.motion = .demo
        view.previewFrameRate = 60
        view.configure(skin: skin, dark: dark)
        view.setPreviewActive(active)
        context.coordinator.lastReleaseTick = releaseTick
        return view
    }

    func updateNSView(_ view: SkinPreviewView, context: Context) {
        view.configure(skin: skin, dark: dark)
        view.motion = .demo
        view.previewFrameRate = 60
        view.setPreviewActive(active)
        if releaseTick != context.coordinator.lastReleaseTick {
            context.coordinator.lastReleaseTick = releaseTick
            view.playRelease(releaseAction)
        }
    }

    static func dismantleNSView(_ view: SkinPreviewView, coordinator: Coordinator) {
        view.shutdown()
    }
}

@MainActor
private struct SkinThumb: NSViewRepresentable {
    let skin: HUDSkinID
    let dark: Bool
    let active: Bool
    let animated: Bool

    func makeNSView(context: Context) -> SkinPreviewView {
        let view = SkinPreviewView(paper: .lines)
        view.voiceAmount = 0.55
        view.previewScale = Self.scale(for: skin)
        view.previewFrameRate = animated ? 60 : 24
        view.motion = animated ? .demo : .idle
        view.configure(skin: skin, dark: dark)
        view.setPreviewActive(active)
        return view
    }

    func updateNSView(_ view: SkinPreviewView, context: Context) {
        view.previewScale = Self.scale(for: skin)
        view.motion = animated ? .demo : .idle
        view.previewFrameRate = animated ? 60 : 24
        view.configure(skin: skin, dark: dark)
        view.setPreviewActive(active)
    }

    static func scale(for skin: HUDSkinID) -> CGFloat {
        switch skin {
        case .classic, .liquidGlass, .frosted: 0.56
        default: 0.9
        }
    }

    static func dismantleNSView(_ view: SkinPreviewView, coordinator: ()) {
        view.shutdown()
    }
}

@MainActor
private final class SkinScreenTrial {
    private var panel: NSPanel?
    private var assembly: SkinPreviewAssembly?
    private var task: Task<Void, Never>?
    private var generation = 0
    private lazy var hudGate = SettingsHUDTrialGate { [weak self] in self?.dismiss() }

    func play(_ id: HUDSkinID) {
        guard hudGate.allowsStart,
              id != .liquidGlass || LiquidGlassSkin.isSupported,
              !id.isShaderSkin || HUDShaderLibrary.shared.isPrepared(id),
              let screen = NSScreen.main else { return }
        dismiss()
        generation += 1
        let currentGeneration = generation
        let newAssembly = SkinPreviewFactory.makeOnScreen(id)
        let skin = newAssembly.skin
        // The trial is the real thing on screen, so it uses the overall size saved for the skin.
        (skin as? ShaderSkin)?.setLayoutScale(SkinParamStore.shared.hudScale(for: id))
        let size = HUDLayout.panelSize(scale: (skin as? ShaderSkin)?.layoutScale ?? 1)
        let newPanel = GlassActiveLookPanel(
            contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .statusBar
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.ignoresMouseEvents = true
        newPanel.hasShadow = false
        newPanel.contentView = skin.view
        let dark = newPanel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        skin.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        skin.apply(SkinPreviewFactory.environment(isDark: dark))
        newAssembly.syntheticMonitor?.start()
        skin.present(coreOnly: false)
        newPanel.orderFrontRegardless()
        panel = newPanel
        assembly = newAssembly

        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            newAssembly.syntheticMonitor?.level = 0.62
            skin.update(level: 0.62)
            skin.update(pointer: HUDPointer(dy: 72, aim: .send, progress: 1))
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled, self.generation == currentGeneration else { return }
            skin.release(.send) { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        generation += 1
        task?.cancel()
        task = nil
        assembly?.shutdown()
        assembly?.skin.view.removeFromSuperview()
        assembly = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private enum SkinCatalog {
    static func title(_ id: HUDSkinID) -> String {
        switch id {
        case .waterDrop: SettingsStrings.skinAppearancePageCopy023
        case .classic, .liquidGlass: SettingsStrings.skinDefaultTitle
        default: id.title
        }
    }

    static func blurb(_ id: HUDSkinID) -> String {
        switch id {
        case .classic: SettingsStrings.skinAppearancePageCopy024
        case .liquidGlass: SettingsStrings.skinAppearancePageCopy025
        case .frosted: SettingsStrings.skinAppearancePageCopy026
        case .astra: SettingsStrings.skinAppearancePageCopy027
        case .liquidMetal: SettingsStrings.skinAppearancePageCopy028
        case .waterDrop: SettingsStrings.skinAppearancePageCopy029
        case .liquidChrome: SettingsStrings.skinAppearancePageCopy030
        case .dither: SettingsStrings.skinAppearancePageCopy031
        case .metaballs: SettingsStrings.skinAppearancePageCopy032
        case .blackHole: SettingsStrings.skinAppearancePageCopy033
        case .particles: SettingsStrings.skinAppearancePageCopy034
        case .inkSprite: SettingsStrings.skinAppearancePageCopy035
        case .bubble: SettingsStrings.skinAppearancePageCopy036
        case .flame: SettingsStrings.skinAppearancePageCopy037
        case .miniDisc: SettingsStrings.skinBlurbMiniDisc
        case .miniMorph: SettingsStrings.skinBlurbMiniMorph
        case .glassDisc: SettingsStrings.skinBlurbGlassDisc
        case .frostDisc: SettingsStrings.skinBlurbFrostDisc
        case .ferrofluid: SettingsStrings.skinBlurbFerrofluid
        case .voiceLine: SettingsStrings.skinBlurbVoiceLine
        case .ripple: SettingsStrings.skinBlurbRipple
        case .plasma: SettingsStrings.skinBlurbPlasma
        }
    }
}
