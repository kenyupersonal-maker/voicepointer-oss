import AppKit
import SwiftUI
import VoicePointerCore

// The skin editor: a live preview of the skin with its parameters underneath (the window is in
// SkinEditorWindow.swift). Values live in SkinParamStore. Every change is saved, reaches the preview at
// once (a new pipeline is built in the background and swapped in when ready) and the real HUD the next
// time it appears.

@MainActor
struct SkinEditorView: View {
    let skin: HUDSkinID

    /// Bumped whenever the store changes, so the controls re-read their values.
    @State private var revision = 0
    @State private var shaderRevision = 0
    @State private var previewDark = false
    @State private var speaking = true
    /// Driven by the window (visible or not); the preview renders only while it is visible.
    @State private var previewActive = true
    @State private var releaseTick = 0
    @State private var releaseAction: HUDRelease = .send

    private var store: SkinParamStore { SkinParamStore.shared }
    private var skinKey: String { skin.paramSkinKey ?? "" }
    private var skinSpec: SkinParamManifest.Skin? { store.skin(skinKey) }

    var body: some View {
        let _ = revision
        VStack(spacing: 0) {
            previewSection
            Divider()
            controlsSection
            Divider()
            parametersSection
        }
        .frame(minWidth: 720, minHeight: 600)
        .onAppear {
            HUDShaderLibrary.shared.prepare(skin)
            previewActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .skinParamsDidChange)) { note in
            if (note.object as? String) == skinKey { revision += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudShaderLibraryDidChange)) { _ in
            shaderRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .skinEditorActivityChanged)) { note in
            guard (note.object as? String) == skinKey,
                  let active = note.userInfo?["active"] as? Bool else { return }
            previewActive = active
        }
    }

    // MARK: Preview

    private var isReady: Bool {
        _ = shaderRevision
        return HUDShaderLibrary.shared.isPrepared(skin)
    }

    private var previewSection: some View {
        ZStack(alignment: .topLeading) {
            SkinEditorPreview(
                skin: skin,
                dark: previewDark,
                active: previewActive && isReady,
                speaking: speaking,
                layoutScale: CGFloat(store.hudScale(skinKey)),
                releaseTick: releaseTick,
                releaseAction: releaseAction
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !isReady {
                readinessMessage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            previewToolbar
        }
        .frame(height: 320)
        .clipped()
    }

    private var previewToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Toggle(SettingsStrings.skinEditorViewCopy001, isOn: $speaking)
                    .toggleStyle(.switch)
                Button(SettingsStrings.skinAppearancePageCopy010) { playRelease(.send) }
                Button(SettingsStrings.skinAppearancePageCopy011) { playRelease(.cancel) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())

            Spacer(minLength: 0)

            SettingsSegmented(selection: $previewDark, options: [
                (value: false, title: SettingsStrings.skinAppearancePageCopy008),
                (value: true, title: SettingsStrings.skinAppearancePageCopy009)
            ])
            .accessibilityLabel(Text(SettingsStrings.skinAppearancePageCopy007))
        }
        .controlSize(.small)
        .tint(SettingsPalette.brand)
        .environment(\.colorScheme, previewDark ? .dark : .light)
        .padding(10)
    }

    @ViewBuilder
    private var readinessMessage: some View {
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
        .environment(\.colorScheme, previewDark ? .dark : .light)
    }

    private func playRelease(_ action: HUDRelease) {
        releaseAction = action
        releaseTick &+= 1
    }

    // MARK: Size and presets

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sizeRow
            presetRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sizeRow: some View {
        if let spec = store.manifest?.hudScale {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text(spec.label)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 64, alignment: .leading)
                    Slider(value: sizeBinding, in: spec.minimum...spec.maximum, step: spec.step)
                        .accessibilityLabel(Text(spec.label))
                    Text(SettingsStrings.percent(Int((store.hudScale(skinKey) * 100).rounded())))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Text((spec.hint.isEmpty ? "" : spec.hint + "。") + SettingsStrings.skinEditorViewCopy009)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 76)
            }
        }
    }

    private var sizeBinding: Binding<Double> {
        Binding<Double>(
            get: { store.hudScale(skinKey) },
            set: { newValue in
                store.setHudScale(skinKey, newValue)
                revision += 1
            })
    }

    @ViewBuilder
    private var presetRow: some View {
        if let spec = skinSpec, !spec.presetKeys.isEmpty {
            let active: String? = store.activePreset(skinKey)
            HStack(spacing: 6) {
                Text(SettingsStrings.skinEditorViewCopy010)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 64, alignment: .leading)
                ForEach(spec.presetKeys, id: \.self) { key in
                    presetChip(title: spec.presetTitle(key), selected: active == key) {
                        store.applyPreset(skinKey, key)
                        revision += 1
                    }
                }
                if active == nil {
                    presetChip(title: SettingsStrings.skinEditorViewCopy011, selected: true) {}
                        .disabled(true)
                }
                Spacer(minLength: 8)
                Button(SettingsStrings.skinEditorViewCopy012) {
                    store.resetToDefaults(skinKey)
                    revision += 1
                }
                .controlSize(.small)
                .disabled(store.isAtDefaults(skinKey))
            }
        }
    }

    private func presetChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? SettingsPalette.card : Color.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? SettingsPalette.ink : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(selected ? SettingsStrings.skinAppearancePageCopy018 : ""))
    }

    // MARK: Parameters

    private var parametersSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let spec = skinSpec {
                    ForEach(spec.groups, id: \.self) { group in
                        groupSection(group, in: spec)
                    }
                } else {
                    Text(SettingsStrings.skinEditorViewCopy014)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func groupSection(_ group: String, in spec: SkinParamManifest.Skin) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group)
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 380), spacing: 28, alignment: .top)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(spec.params(inGroup: group), id: \.key) { definition in
                    parameterRow(definition)
                }
            }
        }
    }

    @ViewBuilder
    private func parameterRow(_ definition: SkinParamDefinition) -> some View {
        switch definition.kind {
        case .float:
            SkinFloatRow(definition: definition, value: floatBinding(definition))
        case .float3:
            SkinColorRow(
                definition: definition,
                color: colorBinding(definition),
                red: componentBinding(definition, 0),
                green: componentBinding(definition, 1),
                blue: componentBinding(definition, 2)
            )
        }
    }

    // MARK: Bindings

    private func floatBinding(_ definition: SkinParamDefinition) -> Binding<Double> {
        Binding<Double>(
            get: { store.float(skinKey, definition.key) ?? 0 },
            set: { newValue in
                store.set(skinKey, definition.key, .float(newValue))
                revision += 1
            })
    }

    /// Colours are sRGB components 0...1, handed to the shader as they are (no gamma conversion).
    private func colorBinding(_ definition: SkinParamDefinition) -> Binding<Color> {
        Binding<Color>(
            get: {
                let c = store.vec3(skinKey, definition.key) ?? (0, 0, 0)
                return Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: 1)
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor.black
                store.set(
                    skinKey, definition.key,
                    .vec3(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)))
                revision += 1
            })
    }

    /// One component (0 red, 1 green, 2 blue) of a colour parameter, for the numeric fields.
    private func componentBinding(_ definition: SkinParamDefinition, _ component: Int) -> Binding<Double> {
        Binding<Double>(
            get: {
                let c = store.vec3(skinKey, definition.key) ?? (0, 0, 0)
                return component == 0 ? c.0 : (component == 1 ? c.1 : c.2)
            },
            set: { newValue in
                var c = store.vec3(skinKey, definition.key) ?? (0, 0, 0)
                if component == 0 { c.0 = newValue } else if component == 1 { c.1 = newValue } else { c.2 = newValue }
                store.set(skinKey, definition.key, .vec3(c.0, c.1, c.2))
                revision += 1
            })
    }
}

// MARK: - Rows

/// The digits a slider step needs: 1 -> 0, 0.5 -> 1, 0.01 -> 2.
private func stepDecimals(_ step: Double) -> Int {
    var factor = 1.0
    for digits in 0...4 {
        let scaled = step * factor
        if abs(scaled - scaled.rounded()) < 1e-6 { return digits }
        factor *= 10
    }
    return 4
}

private struct SkinFloatRow: View {
    let definition: SkinParamDefinition
    @Binding var value: Double

    private var valueText: String {
        let number = String(format: "%.\(stepDecimals(definition.step))f", value)
        if definition.unit.isEmpty { return number }
        return definition.unit == "°" || definition.unit == "%" ? number + definition.unit : number + " " + definition.unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(definition.label)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !definition.hint.isEmpty {
                Text(definition.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Slider(value: $value, in: definition.minimum...definition.maximum, step: definition.step)
                .controlSize(.small)
                .accessibilityLabel(Text(definition.label))
        }
    }
}

private struct SkinColorRow: View {
    let definition: SkinParamDefinition
    @Binding var color: Color
    @Binding var red: Double
    @Binding var green: Double
    @Binding var blue: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(definition.label)
                .font(.system(size: 12.5, weight: .medium))
            if !definition.hint.isEmpty {
                Text(definition.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                ColorPicker(definition.label, selection: $color, supportsOpacity: false)
                    .labelsHidden()
                component("R", $red)
                component("G", $green)
                component("B", $blue)
                Spacer(minLength: 0)
            }
        }
    }

    private func component(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("", value: value, format: FloatingPointFormatStyle<Double>().precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
        }
    }
}

// MARK: - Live preview

/// The live preview: the product skin over a quiet document, driven by synthetic voice and pointer input.
@MainActor
private struct SkinEditorPreview: NSViewRepresentable {
    let skin: HUDSkinID
    let dark: Bool
    let active: Bool
    let speaking: Bool
    let layoutScale: CGFloat
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
        view.voiceAmount = speaking ? 1 : 0
        view.layoutScale = layoutScale
        view.configure(skin: skin, dark: dark)
        view.setPreviewActive(active)
        context.coordinator.lastReleaseTick = releaseTick
        return view
    }

    func updateNSView(_ view: SkinPreviewView, context: Context) {
        view.voiceAmount = speaking ? 1 : 0
        view.layoutScale = layoutScale
        view.motion = .demo
        view.previewFrameRate = 60
        view.configure(skin: skin, dark: dark)
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
