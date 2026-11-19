import AppKit
import SwiftUI

// 2026-11-07 设置窗口重做（Claude）：所有页面共用一套尺寸、颜色和容器。
// 同一个左边距、顶边距、标题字号；分组是白底细边的圆角卡片，行里开关、选项、数值一律左字右控件。
// 样式参考 ChatHand：浅灰底、白卡片、细线、灰色小方块里放线条图标，没有彩色渐变。

enum SettingsLayout {
    static let pageLeading: CGFloat = 32
    static let pageTrailing: CGFloat = 32
    static let pageTop: CGFloat = 2
    static let pageBottom: CGFloat = 36
    static let contentMaxWidth: CGFloat = 680
    static let sectionSpacing: CGFloat = 22
    static let cardRadius: CGFloat = 14
    /// One outline weight everywhere, chosen or not: 1 pt (2 px on Retina). A chosen card or tile only turns ink.
    static let stroke: CGFloat = 1
    static let cardPaddingH: CGFloat = 16
    static let cardPaddingV: CGFloat = 14
    static let rowSpacing: CGFloat = 12
    static let tileSize: CGFloat = 28
}

enum SettingsPalette {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    static let page = dynamic(light: NSColor(srgbRed: 0.965, green: 0.966, blue: 0.97, alpha: 1),
                              dark: NSColor(srgbRed: 0.115, green: 0.117, blue: 0.125, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(srgbRed: 0.168, green: 0.17, blue: 0.18, alpha: 1))
    static let hairline = dynamic(light: NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.09),
                                  dark: NSColor(white: 1, alpha: 0.085))
    static let tile = dynamic(light: NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.05),
                              dark: NSColor(white: 1, alpha: 0.08))
    static let tileHover = dynamic(light: NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.085),
                                   dark: NSColor(white: 1, alpha: 0.13))
    /// Text: ink for titles and the selected item, ink2 one step lighter for unselected sidebar rows.
    static let ink = dynamic(light: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.095, alpha: 1),
                             dark: NSColor(white: 0.95, alpha: 1))
    static let ink2 = dynamic(light: NSColor(srgbRed: 0.33, green: 0.35, blue: 0.34, alpha: 1),
                              dark: NSColor(white: 0.72, alpha: 1))
    /// The one colour: the green of the disc's waveform (#12BE1D), for switches, sliders and links. No blue anywhere.
    static let brand = dynamic(light: NSColor(srgbRed: 0x12 / 255.0, green: 0xBE / 255.0, blue: 0x1D / 255.0, alpha: 1),
                               dark: NSColor(srgbRed: 0x2C / 255.0, green: 0xCF / 255.0, blue: 0x38 / 255.0, alpha: 1))
    static let selectionFill = dynamic(light: NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.075),
                                       dark: NSColor(white: 1, alpha: 0.12))
    static let switchOff = dynamic(light: NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.16),
                                   dark: NSColor(white: 1, alpha: 0.22))
    static let segmentOn = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.2))
}

/// One settings page: the page name, then its groups, in a scroll view with the same margins on every page.
struct SettingsPageBody<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, -4)
                content()
            }
            .settingsControls()
            .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
            .padding(.leading, SettingsLayout.pageLeading)
            .padding(.trailing, SettingsLayout.pageTrailing)
            .padding(.top, SettingsLayout.pageTop)
            .padding(.bottom, SettingsLayout.pageBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SettingsPalette.page)
    }
}

extension View {
    /// Switch on the right, value on the right, quiet capsule buttons: the row grammar of every page.
    func settingsControls() -> some View {
        toggleStyle(SettingsSwitchStyle())
            .labeledContentStyle(SettingsLabeledStyle())
            .buttonStyle(SettingsButtonStyle())
            .tint(SettingsPalette.brand)
    }

    /// The white rounded card with a hairline that every group uses.
    func settingsCard(padding: Bool = true) -> some View {
        self
            .padding(.horizontal, padding ? SettingsLayout.cardPaddingH : 0)
            .padding(.vertical, padding ? SettingsLayout.cardPaddingV : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                    .strokeBorder(SettingsPalette.hairline, lineWidth: 1)
            }
    }
}

/// A titled group: header above, the rows in a card, a note below. Takes the place of a grouped-Form `Section`.
struct SettingsGroup<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer
    private let boxed: Bool

    init(boxed: Bool = true, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header,
         @ViewBuilder footer: () -> Footer) {
        self.boxed = boxed
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 2)
                .textCase(nil)
            if boxed {
                VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) { content }
                    .settingsCard()
            } else {
                VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) { content }
            }
            footer
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }
}

extension SettingsGroup where Header == EmptyView, Footer == EmptyView {
    init(boxed: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(boxed: boxed, content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension SettingsGroup where Header == Text, Footer == EmptyView {
    init(_ title: String, boxed: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(boxed: boxed, content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension SettingsGroup where Header == Text {
    init(_ title: String, boxed: Bool = true, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(boxed: boxed, content: content, header: { Text(title) }, footer: footer)
    }
}

extension SettingsGroup where Footer == EmptyView {
    init(boxed: Bool = true, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(boxed: boxed, content: content, header: header, footer: { EmptyView() })
    }
}

extension SettingsGroup where Header == EmptyView {
    init(boxed: Bool = true, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(boxed: boxed, content: content, header: { EmptyView() }, footer: footer)
    }
}

/// A line icon in a small grey rounded square, as in ChatHand's settings rows.
struct SettingsIconTile: View {
    let symbol: String
    var size: CGFloat = SettingsLayout.tileSize
    /// Ink instead of grey, for a chosen card.
    var emphasized = false
    /// A template image used instead of the symbol (the Doubao card shows Doubao's own mark).
    var image: NSImage? = nil

    var body: some View {
        glyph
            .foregroundStyle(emphasized ? AnyShapeStyle(SettingsPalette.ink) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(SettingsPalette.tile, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        if let image {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                .frame(width: size * 0.56, height: size * 0.56)
        } else {
            Image(systemName: symbol).font(.system(size: size * 0.5, weight: .regular))
        }
    }
}

/// Icon tile, title and an optional grey line under it. Used as the label of toggles and value rows.
struct SettingsRowLabel: View {
    let icon: String?
    let title: String
    var subtitle: String? = nil

    init(_ title: String, icon: String? = nil, subtitle: String? = nil) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon { SettingsIconTile(symbol: icon) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A 1 pt hairline between parts of a card or the two groups of the sidebar.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(SettingsPalette.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

/// Motion shared by the settings window: short and eased, and off when the person asks macOS for less motion.
enum SettingsMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Hover, fills and strokes.
    static var quick: Animation? { reduced ? nil : .easeOut(duration: 0.16) }
    /// Things that move: the segmented chip, the switch knob, a highlight, a disclosure.
    static var slide: Animation? { reduced ? nil : .spring(response: 0.3, dampingFraction: 0.86) }
    /// A page or a panel coming in.
    static var page: Animation? { reduced ? nil : .easeOut(duration: 0.24) }
    /// Content swapped in place (the tip QR code and its lines): the old one goes almost at once, the new one fades in.
    static var swap: AnyTransition {
        reduced ? .identity : .asymmetric(
            insertion: .opacity,
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.07)))
    }
    /// The new page fades in rising 6 pt; the old one fades out quickly, so two pages are never seen on top of each other.
    static var pageTransition: AnyTransition {
        reduced ? .identity : .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(y: 6)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.07)))
    }
}

/// A switch at the right edge of the row; the label fills the rest.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitchRow(configuration: configuration)
    }
}

/// Only the small switch, for rows that lay out their own label.
struct SettingsBareSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitch(isOn: configuration.$isOn)
            .accessibilityElement(children: .ignore)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
                    .toggleStyle(.switch)
            }
    }
}

/// A compact switch (32 × 19 pt): accent when on, grey when off. The system switch is much bigger on macOS 26.
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? SettingsPalette.brand : SettingsPalette.switchOff)
            Circle()
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 0.5)
                .padding(2)
        }
        .frame(width: 32, height: 19)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture { if isEnabled { isOn.toggle() } }
        .animation(SettingsMotion.slide, value: isOn)
    }
}

/// A quiet segmented control: grey track, the chosen option on a raised white chip.
struct SettingsSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// Called on every click, also on the option already chosen (the haptic row plays it).
    var onPick: ((Value) -> Void)?
    @Namespace private var chip

    init(selection: Binding<Value>, options: [(value: Value, title: String)], onPick: ((Value) -> Void)? = nil) {
        _selection = selection
        self.options = options
        self.onPick = onPick
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.value == selection
                Button {
                    selection = option.value
                    onPick?(option.value)
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 36, minHeight: 22)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(SettingsPalette.segmentOn)
                                    .shadow(color: Color.black.opacity(0.10), radius: 1.5, x: 0, y: 0.5)
                                    .matchedGeometryEffect(id: "chip", in: chip)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(SettingsPalette.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(SettingsMotion.slide, value: selection)
        .accessibilityElement(children: .contain)
    }
}

private struct SettingsSwitchRow: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isEnabled ? 1 : 0.5)
            SettingsSwitch(isOn: configuration.$isOn)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

/// Label on the left, value or control on the right.
struct SettingsLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 24)
    }
}

/// Quiet capsule buttons (grey fill, darker on hover); destructive ones in red text.
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration)
    }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color(nsColor: .systemRed) : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(hovering || configuration.isPressed ? SettingsPalette.tileHover : SettingsPalette.tile, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 && isEnabled }
            .animation(SettingsMotion.quick, value: hovering)
            .animation(SettingsMotion.quick, value: configuration.isPressed)
    }
}

/// Text-only action in the brand green (「去配置」「检查」「试一下」). Replaces the system link style, which is blue.
struct SettingsLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsLinkButtonBody(configuration: configuration)
    }
}

private struct SettingsLinkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(SettingsPalette.brand)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : hovering ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isEnabled }
            .animation(SettingsMotion.quick, value: hovering)
    }
}

/// The one filled button of a page (ink on light, white on dark), e.g. 「在屏幕上试一下」.
struct SettingsPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsPrimaryButtonBody(configuration: configuration)
    }
}

private struct SettingsPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(scheme == .dark ? Color.white : Color(nsColor: NSColor(srgbRed: 0.09, green: 0.1, blue: 0.095, alpha: 1)),
                        in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
            .animation(SettingsMotion.quick, value: configuration.isPressed)
    }
}

/// Turns vertical scrolling over the view it sits behind into ±1 steps (the tip methods, the sidebar pages).
/// Mouse wheel: one step per notch. Trackpad: one step per `distance` of travel, momentum included. A scroll
/// that cannot step (already first or last) passes through, except the momentum tail of a swipe that stepped.
struct SettingsWheelStepper: NSViewRepresentable {
    /// Trackpad travel (pt) per step.
    var distance: CGFloat = 64
    let canStep: (Int) -> Bool
    let step: (Int) -> Void

    func makeNSView(context: Context) -> SettingsWheelStepperView {
        let view = SettingsWheelStepperView()
        view.distance = distance
        view.canStep = canStep
        view.step = step
        return view
    }

    func updateNSView(_ view: SettingsWheelStepperView, context: Context) {
        view.distance = distance
        view.canStep = canStep
        view.step = step
    }

    static func dismantleNSView(_ view: SettingsWheelStepperView, coordinator: ()) { view.stop() }
}

final class SettingsWheelStepperView: NSView {
    var canStep: ((Int) -> Bool)?
    var step: ((Int) -> Void)?
    private var monitor: Any?
    private var travel: CGFloat = 0
    private var steppedThisGesture = false
    var distance: CGFloat = 64

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the event was used here and the page must not scroll.
    private func handle(_ event: NSEvent) -> Bool {
        let dy = event.scrollingDeltaY
        if event.phase == .began || event.phase == .mayBegin { travel = 0; steppedThisGesture = false }
        guard abs(dy) > abs(event.scrollingDeltaX) || dy == 0 else { return false }
        if !event.hasPreciseScrollingDeltas {
            guard dy != 0 else { return false }
            let direction = dy > 0 ? -1 : 1
            guard canStep?(direction) == true else { return false }
            step?(direction)
            return true
        }
        let momentum = !event.momentumPhase.isEmpty
        guard dy != 0 else { return momentum ? steppedThisGesture : false }
        let direction = dy > 0 ? -1 : 1
        guard canStep?(direction) == true else {
            travel = 0
            return momentum && steppedThisGesture
        }
        travel += dy
        while abs(travel) >= distance, canStep?(direction) == true {
            step?(direction)
            steppedThisGesture = true
            travel -= dy > 0 ? distance : -distance
        }
        return true
    }
}
