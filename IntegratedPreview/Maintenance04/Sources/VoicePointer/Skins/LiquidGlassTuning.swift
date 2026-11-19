import AppKit
import SwiftUI
import VoicePointerCore

// 质感调节（2026-11-10 重排，Claude；前身是 2026-11-07 的「液态玻璃调节」）：设置 → 圆盘样式 → 选中「默认」时出现。
// 「默认」有三种质感：清透、柔和是系统液态玻璃的透明 / 常规两种样式，磨砂是经典圆盘。每种质感各存一套参数，
// 选哪种就调哪种，互不影响（Ken：每种情况都给一个控制器）。只放真实存在的旋钮：
//   明暗：玻璃上盖一层黑或白（系统自己的着色不看强度，见 LiquidGlassSkin）。清透默认压暗一点：系统透明玻璃放在亮的
//         内容上是一片亮，苹果的做法也是在它上面压一层暗（Ken：清透总是过曝）。默认压暗 8 %。
//   边缘加深：玻璃边上一圈渐暗，给它一点厚度。
//   纹路、中心亮度：咻自己画的两条槽、中心那圈和中心底色。
//   投影：强度、扩散、下沉。
// Toast 和回中动画三种质感共用。系统玻璃边缘那圈细亮线和折射是系统画的，没有接口能调。
// 值存在 UserDefaults（v3）。v2 及以前的玻璃参数不再读（Ken 对那套外观不满意，新版从新的默认值开始），
// 只带过来质感、Toast 和回中动画；旧值不删也不改。

/// One 质感's look.
struct GlassLook: Codable, Equatable, Sendable {
    /// 明暗：负数压暗（盖一层黑），正数提亮（盖一层白），绝对值就是那层的不透明度。磨砂不用。
    var tone = 0.0
    /// 边缘加深：玻璃最外面一圈渐暗到这个不透明度，0 没有。磨砂不用。
    var rimShade = 0.0
    /// 两条槽和中心那圈的深浅，0 不画。
    var lines = 1.0
    /// 中间那颗比周围亮多少（深色模式下只取 15 %，见 RadialHUDView.applyCoreFills）。磨砂不用。
    var coreBrightness = 0.14
    var shadowStrength = 1.0
    var shadowSpread = 24.0
    var shadowDrop = 9.0

    /// 清透：压暗 8 %，中心亮一点。边缘加深默认是 0：0.5.90–0.5.92 默认开着（清透 14 %、柔和 5 %），而且渐变从半径
    /// 62 % 就开始，圆盘看着像一块鼓起来的厚饼（Ken，2026-11-10）。存的键名也从 edgeShade 换成 rimShade，
    /// 所以那几版存下的数值不会带过来。
    static let clear = GlassLook(tone: -0.08, coreBrightness: 0.10)
    /// 柔和：系统常规玻璃原样。0.5.102（Ken）：两条槽和中心那圈还是太重，减半；投影再散开一点、再淡一点。
    static let soft = GlassLook(lines: 0.5, shadowStrength: 0.8, shadowSpread: 30)
    /// 柔和 up to 0.5.101. A saved 柔和 that is exactly this was never touched, so it moves to the new default.
    static let softBefore0_5_102 = GlassLook()
    /// 磨砂：经典圆盘原样（它的投影是另一套画法，100 % / 30 pt / 8 pt 就是一直以来的样子）。
    static let frost = GlassLook(shadowSpread: 30, shadowDrop: 8)

    static func defaults(for texture: HUDSkinPreferences.DefaultTexture) -> GlassLook {
        switch texture {
        case .clear: return .clear
        case .soft: return .soft
        case .frost: return .frost
        }
    }

    /// The layer laid over the glass for 明暗; nil at 0.
    var toneColor: NSColor? {
        if tone < -0.001 { return NSColor.black.withAlphaComponent(min(-tone, 1)) }
        if tone > 0.001 { return NSColor.white.withAlphaComponent(min(tone, 1)) }
        return nil
    }

    /// A saved look with keys missing (an older or partial save): each missing number keeps this look's value.
    fileprivate func filled(from saved: PartialGlassLook?) -> GlassLook {
        guard let saved else { return self }
        var look = self
        look.tone = saved.tone ?? tone
        look.rimShade = saved.rimShade ?? rimShade
        look.lines = saved.lines ?? lines
        look.coreBrightness = saved.coreBrightness ?? coreBrightness
        look.shadowStrength = saved.shadowStrength ?? shadowStrength
        look.shadowSpread = saved.shadowSpread ?? shadowSpread
        look.shadowDrop = saved.shadowDrop ?? shadowDrop
        return look
    }
}

private struct PartialGlassLook: Decodable {
    var tone: Double?
    var rimShade: Double?
    var lines: Double?
    var coreBrightness: Double?
    var shadowStrength: Double?
    var shadowSpread: Double?
    var shadowDrop: Double?
}

struct LiquidGlassTuning: Codable, Equatable, Sendable {
    /// 质感：0 清透（系统「透明」玻璃）· 1 柔和（系统「常规」玻璃）。磨砂是经典皮肤，不在这里。
    /// Set by 圆盘样式 → 默认 → 质感 (HUDSkinPreferences.selectDefault), not by this panel.
    var blur = 1
    var clear = GlassLook.clear
    var soft = GlassLook.soft
    var frost = GlassLook.frost
    /// 24 表示两头全圆（胶囊）。
    var toastCornerRadius = 24.0
    /// 0 常规 · 1 中等 · 2 粗
    var toastWeight = 1
    var snapAmplitude = 0.10
    var snapDuration = 0.22

    static let defaults = LiquidGlassTuning()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case blur, clear, soft, frost, toastCornerRadius, toastWeight, snapAmplitude, snapDuration
    }

    /// 0.5.79 and earlier: 「样式」 常规/透明.
    private enum PreviousKeys: String, CodingKey { case clearStyle }

    /// Missing or unreadable keys keep their default, so older or partial saves never fail. A v2 or v1 save decodes
    /// too: its 质感, Toast and snap carry over and its flat glass numbers are simply not read.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LiquidGlassTuning.defaults
        if let saved = try? c.decodeIfPresent(Int.self, forKey: .blur) {
            // 0.5.80-0.5.82 also had 2 (a frost under regular glass); that is the classic skin now.
            blur = min(max(saved, 0), 1)
        } else {
            var isClear = false
            if let previous = try? decoder.container(keyedBy: PreviousKeys.self),
               let saved = try? previous.decodeIfPresent(Bool.self, forKey: .clearStyle) {
                isClear = saved
            }
            blur = isClear ? 0 : d.blur
        }
        clear = GlassLook.clear.filled(from: (try? c.decodeIfPresent(PartialGlassLook.self, forKey: .clear)) ?? nil)
        soft = GlassLook.soft.filled(from: (try? c.decodeIfPresent(PartialGlassLook.self, forKey: .soft)) ?? nil)
        if soft == GlassLook.softBefore0_5_102 { soft = .soft }
        frost = GlassLook.frost.filled(from: (try? c.decodeIfPresent(PartialGlassLook.self, forKey: .frost)) ?? nil)
        toastCornerRadius = (try? c.decodeIfPresent(Double.self, forKey: .toastCornerRadius)) ?? d.toastCornerRadius
        toastWeight = (try? c.decodeIfPresent(Int.self, forKey: .toastWeight)) ?? d.toastWeight
        snapAmplitude = (try? c.decodeIfPresent(Double.self, forKey: .snapAmplitude)) ?? d.snapAmplitude
        snapDuration = (try? c.decodeIfPresent(Double.self, forKey: .snapDuration)) ?? d.snapDuration
    }

    /// The Liquid Glass skin's look: 清透 or 柔和, whichever its 质感 is.
    var look: GlassLook {
        get { blur == 0 ? clear : soft }
        set { if blur == 0 { clear = newValue } else { soft = newValue } }
    }

    subscript(texture: HUDSkinPreferences.DefaultTexture) -> GlassLook {
        get {
            switch texture {
            case .clear: return clear
            case .soft: return soft
            case .frost: return frost
            }
        }
        set {
            switch texture {
            case .clear: clear = newValue
            case .soft: soft = newValue
            case .frost: frost = newValue
            }
        }
    }

    var toastFontWeight: NSFont.Weight {
        switch toastWeight {
        case 0: return .regular
        case 2: return .semibold
        default: return .medium
        }
    }
}

@MainActor
protocol LiquidGlassTunable: AnyObject {
    func applyTuning()
}

@MainActor
final class LiquidGlassTuningStore {
    static let shared = LiquidGlassTuningStore()
    static let key = "hud.liquidGlass.tuning.v3"
    /// 0.5.80-0.5.89 (v2) and 0.5.79 and earlier (v1). Read only while there is no v3 save yet, and only for the 质感,
    /// Toast and snap; never written or removed.
    static let previousKeys = ["hud.liquidGlass.tuning.v2", "hud.liquidGlass.tuning.v1"]

    private let defaults: UserDefaults
    private let listeners = NSHashTable<AnyObject>.weakObjects()
    private(set) var value: LiquidGlassTuning

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = ([Self.key] + Self.previousKeys).lazy.compactMap { defaults.data(forKey: $0) }.first
        if let data, let saved = try? JSONDecoder().decode(LiquidGlassTuning.self, from: data) {
            value = saved
        } else {
            value = .defaults
        }
    }

    var listenerCount: Int { listeners.allObjects.count }

    /// Skins register themselves; they are held weakly and re-tuned on every change.
    func register(_ listener: any LiquidGlassTunable) {
        listeners.add(listener)
    }

    /// Posted after every change, so an open tuning panel picks up a 质感 chosen elsewhere.
    static let didChange = Notification.Name("VoicePointerLiquidGlassTuningDidChange")

    func setBlur(_ blur: Int) {
        var next = value
        next.blur = min(max(blur, 0), 1)
        update(next)
    }

    func update(_ newValue: LiquidGlassTuning) {
        guard newValue != value else { return }
        value = newValue
        if let data = try? JSONEncoder().encode(newValue) {
            defaults.set(data, forKey: Self.key)
        }
        for case let listener as any LiquidGlassTunable in listeners.allObjects {
            listener.applyTuning()
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    var exportText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return "咻 质感调节参数\n" + text
    }
}

private enum TuningCopy {
    static let title = "质感调节"
    static let changed = "已调整"
    static let note = "清透、柔和、磨砂各有一套，这里调的是上面选中的那一种。拖动后预览立刻变，之后出现的圆盘也照这个来。玻璃是透明的，看起来还取决于背后的内容，想看真实效果就点上面的「在屏幕上试一下」。"
    static let frostNote = "磨砂是不透明的底，没有明暗和边缘可调。"
    static let toastTrial = "看一下 Toast"
    static let copy = "复制参数"
    static let copied = "已复制"
    static let reset = "这一种恢复默认"
    static let glass = "玻璃"
    static let tone = "明暗"
    static let toneDarker = "压暗"
    static let toneLighter = "提亮"
    static let toneNone = "原样"
    static let rimShade = "边缘加深"
    static let marks = "纹路"
    static let lines = "深浅"
    static let coreBrightness = "中心亮度"
    static let shadow = "投影"
    static let shadowStrength = "强度"
    static let shadowSpread = "扩散范围"
    static let shadowDrop = "下沉距离"
    static let shared = "三种质感共用"
    static let toastCorner = "Toast 圆角"
    static let toastCapsule = "全圆"
    static let toastWeight = "Toast 字重"
    static let weightRegular = "常规"
    static let weightMedium = "中等"
    static let weightBold = "粗"
    static let snapAmplitude = "回中弹动"
    static let snapOff = "不弹"
    static let snapDuration = "回中时长"
    static let sampleToast = "没找到输入框"
    static func textureName(_ texture: HUDSkinPreferences.DefaultTexture) -> String {
        switch texture {
        case .clear: return SettingsStrings.skinTextureClear
        case .soft: return SettingsStrings.skinTextureSoft
        case .frost: return SettingsStrings.skinTextureFrost
        }
    }
}

@MainActor
struct LiquidGlassTuningSection: View {
    /// The 质感 picked next to the 默认 tile: the one this panel tunes.
    let texture: HUDSkinPreferences.DefaultTexture
    @State private var tuning = LiquidGlassTuningStore.shared.value
    @State private var copied = false
    @State private var toastTrial = LiquidGlassToastTrial()
    /// 默认收起，页面保持清爽；展开后才是全部滑块（2026-11-07 简洁版）。
    @State private var expanded = false

    private var look: Binding<GlassLook> {
        Binding(get: { tuning[texture] }, set: { tuning[texture] = $0 })
    }

    private var isAdjusted: Bool { tuning[texture] != GlassLook.defaults(for: texture) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            controls
                .padding(.top, 12)
        } label: {
            HStack(spacing: 6) {
                Text(TuningCopy.title + " · " + TuningCopy.textureName(texture))
                    .font(.system(size: 13, weight: .semibold))
                if isAdjusted {
                    Text(TuningCopy.changed)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(SettingsMotion.slide) { expanded.toggle() } }
        }
        .settingsCard()
        .onChange(of: tuning) { _, newValue in
            LiquidGlassTuningStore.shared.update(newValue)
            copied = false
        }
        .onReceive(NotificationCenter.default.publisher(for: LiquidGlassTuningStore.didChange)) { _ in
            let saved = LiquidGlassTuningStore.shared.value
            if saved != tuning { tuning = saved }
        }
        .onDisappear { toastTrial.dismiss() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(texture == .frost ? TuningCopy.note + TuningCopy.frostNote : TuningCopy.note)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if texture != .frost {
                group(TuningCopy.glass) {
                    slider(TuningCopy.tone, look.tone, -0.4...0.4, step: 0.01, format: Self.tone)
                    slider(TuningCopy.rimShade, look.rimShade, 0...0.4, step: 0.01, format: Self.percent)
                    slider(TuningCopy.coreBrightness, look.coreBrightness, 0...0.3, step: 0.01, format: Self.percent)
                }
            }

            group(TuningCopy.marks) {
                slider(TuningCopy.lines, look.lines, 0...1, step: 0.05, format: Self.percent)
            }

            group(TuningCopy.shadow) {
                slider(TuningCopy.shadowStrength, look.shadowStrength, 0...1.5, step: 0.05, format: Self.percent)
                slider(TuningCopy.shadowSpread, look.shadowSpread, 0...40, step: 1, format: Self.points)
                slider(TuningCopy.shadowDrop, look.shadowDrop, 0...20, step: 0.5, format: Self.points)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Button(TuningCopy.reset) { tuning[texture] = GlassLook.defaults(for: texture) }
                    .disabled(!isAdjusted)
            }
            .controlSize(.small)

            Divider()

            group(TuningCopy.shared) {
                slider(TuningCopy.toastCorner, $tuning.toastCornerRadius, 4...24, step: 1) { value in
                    value >= 23.5 ? TuningCopy.toastCapsule : Self.points(value)
                }
                row(TuningCopy.toastWeight) {
                    SettingsSegmented(selection: $tuning.toastWeight,
                                      options: [(0, TuningCopy.weightRegular), (1, TuningCopy.weightMedium), (2, TuningCopy.weightBold)])
                    Spacer(minLength: 0)
                }
                slider(TuningCopy.snapAmplitude, $tuning.snapAmplitude, 0...0.15, step: 0.01) { value in
                    value < 0.005 ? TuningCopy.snapOff : Self.percent(value)
                }
                slider(TuningCopy.snapDuration, $tuning.snapDuration, 0.1...0.4, step: 0.01, format: Self.seconds)
                    .disabled(tuning.snapAmplitude < 0.005)
            }

            HStack(spacing: 8) {
                Button(TuningCopy.toastTrial) { toastTrial.play() }
                Button(copied ? TuningCopy.copied : TuningCopy.copy) { copyParameters() }
                Spacer(minLength: 8)
            }
            .controlSize(.small)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 72, alignment: .leading)
            content()
        }
        .font(.system(size: 12))
    }

    private func slider(
        _ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 72, alignment: .leading)
            // No `step:` here: on macOS a stepped slider draws a row of tick marks. Values still snap to the step.
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }
            ), in: range)
            Text(format(value.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 12))
    }

    private func copyParameters() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(LiquidGlassTuningStore.shared.exportText, forType: .string)
        copied = true
    }

    private nonisolated static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private nonisolated static func tone(_ value: Double) -> String {
        let amount = Int((abs(value) * 100).rounded())
        if amount == 0 { return TuningCopy.toneNone }
        return (value < 0 ? TuningCopy.toneDarker : TuningCopy.toneLighter) + " \(amount)%"
    }
    private nonisolated static func points(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)) pt" : String(format: "%.1f pt", value)
    }
    private nonisolated static func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }
}

/// Shows the real Liquid Glass Toast at the centre of the screen for a moment, over whatever is behind it.
@MainActor
final class LiquidGlassToastTrial {
    private var panel: NSPanel?
    private var assembly: SkinPreviewAssembly?
    private var generation = 0
    private lazy var hudGate = SettingsHUDTrialGate { [weak self] in self?.dismiss() }

    func play() {
        guard hudGate.allowsStart, LiquidGlassSkin.isSupported, let screen = NSScreen.main else { return }
        dismiss()
        generation += 1
        let current = generation
        let made = SkinPreviewFactory.makeOnScreen(.liquidGlass)
        let size = HUDLayout.panelSize
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
        newPanel.contentView = made.skin.view
        let dark = newPanel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        made.skin.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        made.skin.apply(SkinPreviewFactory.environment(isDark: dark))
        made.skin.present(coreOnly: false)
        made.skin.showFeedback(TuningCopy.sampleToast) { [weak self] in
            guard let self, self.generation == current else { return }
            self.dismiss()
        }
        newPanel.orderFrontRegardless()
        panel = newPanel
        assembly = made
    }

    func dismiss() {
        generation += 1
        assembly?.shutdown()
        assembly?.skin.view.removeFromSuperview()
        assembly = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
