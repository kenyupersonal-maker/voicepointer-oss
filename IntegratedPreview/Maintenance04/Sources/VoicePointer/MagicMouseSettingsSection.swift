import AppKit
import SwiftUI
import VoicePointerCore

/// Window notifications stop polling before close/miniaturize; occlusion also covers orderOut.
@MainActor private struct MagicMouseWindowVisibility: NSViewRepresentable {
    let changed: @MainActor (NSWindow?, Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { let view = VisibilityView(); view.changed = changed; return view }
    func updateNSView(_ nsView: VisibilityView, context: Context) { nsView.changed = changed }
    static func dismantleNSView(_ nsView: VisibilityView, coordinator: ()) { nsView.detach() }
    final class VisibilityView: NSView {
        var changed: (@MainActor (NSWindow?, Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); NotificationCenter.default.removeObserver(self)
            guard let window else { changed?(nil, false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(activity(_:)), name: name, object: window)
            }
            updateVisibility()
        }
        @objc private func activity(_ notification: Notification) {
            if [NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification].contains(notification.name) {
                changed?(window, false)
            } else { updateVisibility() }
        }
        private func updateVisibility() {
            changed?(window, window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
        }
        func detach() { NotificationCenter.default.removeObserver(self); changed?(nil, false); changed = nil }
    }
}

@MainActor struct MagicMouseSettingsSection: View {
    static let landingSkewRange: ClosedRange<Double> = 40...1500
    static let freshChordRange: ClosedRange<Double> = 200...2000
    @Binding var configuration: GestureConfiguration
    @StateObject private var state: MagicMouseSettingsState
    @State private var expanded: Bool
    init(configuration: Binding<GestureConfiguration>, state: MagicMouseSettingsState, expanded: Bool = false) {
        _configuration = configuration; _state = StateObject(wrappedValue: state); _expanded = State(initialValue: expanded)
    }
    // 2026-11-07 重排：手感一组（档位、实时触点、更多），触点记录另起一组（开关、标注、对比、清除）。
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsGroup(SettingsStrings.magicMouseTuning) {
                if state.present {
                    HStack(spacing: 12) {
                        SettingsRowLabel(SettingsStrings.magicMouseFeel, icon: "magicmouse",
                                         subtitle: SettingsStrings.magicMouseDensityDetail)
                        Spacer(minLength: 12)
                        SettingsSegmented(
                            selection: Binding<MagicMouseFeel?>(
                                get: { MagicMouseFeel.selected(in: configuration) },
                                set: { feel in if let feel { configuration = feel.applying(to: configuration) } }
                            ),
                            options: MagicMouseFeel.allCases.map { (Optional($0), $0.title) }
                        )
                    }
                    touchPreview
                    DisclosureGroup(isExpanded: $expanded) { advanced } label: {
                        Text(SettingsStrings.magicMouseMore).font(.system(size: 13))
                    }
                } else {
                    Text(SettingsStrings.magicMouseAbsent).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if state.present {
                SettingsGroup(SettingsStrings.magicMouseRecordSection) {
                    recording
                    SettingsDivider()
                    comparison
                } footer: {
                    Text(SettingsStrings.magicMouseRecordDetail)
                }
            }
        }
        .background(MagicMouseWindowVisibility(changed: { window, visible in state.attach(window, visible: visible) }).frame(width: 0, height: 0))
        .onAppear { state.appear(configuration: configuration) }
        .onChange(of: configuration) { _, next in state.updateConfiguration(next) }
        .onDisappear { state.disappear() }
    }
    /// The mouse seen from above with the fingers on it now, and what the last press was judged to be.
    private var touchPreview: some View {
        HStack(spacing: 16) {
            GeometryReader { proxy in
                let points = (state.snapshot?.points ?? []).filter {
                    [$0.x, $0.y, $0.major, $0.minor, $0.density].allSatisfy(\.isFinite)
                }
                ZStack {
                    Capsule().fill(SettingsPalette.card)
                    Capsule().strokeBorder(SettingsPalette.hairline, lineWidth: 1)
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        Ellipse().fill(SettingsPalette.brand).opacity(min(0.85, max(0.18, Double(point.density) / 1.8)))
                            .frame(width: max(6, min(30, CGFloat(point.minor) * proxy.size.width)),
                                   height: max(9, min(40, CGFloat(point.major) * proxy.size.height)))
                            .position(x: min(0.9, max(0.1, CGFloat(point.x))) * proxy.size.width,
                                      y: (1 - min(0.92, max(0.08, CGFloat(point.y)))) * proxy.size.height)
                    }
                }
            }
            .frame(width: 62, height: 100)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(SettingsStrings.magicMouseLiveTouch).font(.system(size: 13))
                Text(SettingsStrings.magicMouseDecision(state.decision)).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(state.decision?.reason == .passed ? SettingsPalette.brand : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            slider("同时落下的门槛", value: float(\.magicMouseMinDensity), range: 0.5...1.8, step: 0.05,
                   text: SettingsStrings.magicMouseNumber(configuration.magicMouseMinDensity))
            slider("先后落下的门槛", value: float(\.magicMouseSlowMinDensity), range: 0.5...1.8, step: 0.05,
                   text: SettingsStrings.magicMouseNumber(configuration.magicMouseSlowMinDensity))
            slider("同时落下的间隔", value: integer(\.magicMouseFastLandingMilliseconds), range: 0...300, step: 5,
                   text: SettingsStrings.magicMouseMilliseconds(configuration.magicMouseFastLandingMilliseconds))
            slider(SettingsStrings.magicMouseLanding, value: integer(\.magicMouseMaxLandingSkewMilliseconds), range: Self.landingSkewRange, step: 5,
                   text: SettingsStrings.magicMouseMilliseconds(configuration.magicMouseMaxLandingSkewMilliseconds))
            slider(SettingsStrings.magicMouseFresh, value: integer(\.magicMouseFreshChordWindowMilliseconds), range: Self.freshChordRange, step: 50,
                   text: SettingsStrings.magicMouseMilliseconds(configuration.magicMouseFreshChordWindowMilliseconds))
            slider(SettingsStrings.magicMouseMovement, value: float(\.maximumTouchMovement), range: 0.01...0.20, step: 0.01,
                   text: SettingsStrings.magicMouseNumber(configuration.maximumTouchMovement))
            HStack {
                Spacer(minLength: 0)
                Button(SettingsStrings.magicMouseRestore) { restoreDefaults() }
                    .accessibilityLabel(SettingsStrings.magicMouseRestore)
            }
        }.padding(.top, 10)
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13)); Spacer(minLength: 4)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title).accessibilityValue(text)
        }
    }
    func float(_ path: WritableKeyPath<GestureConfiguration, Float>) -> Binding<Double> {
        Binding(get: { Double(configuration[keyPath: path]) }, set: { var next = configuration; next[keyPath: path] = Float($0); configuration = next })
    }
    func integer(_ path: WritableKeyPath<GestureConfiguration, Int>) -> Binding<Double> {
        Binding(get: { Double(configuration[keyPath: path]) }, set: { var next = configuration; next[keyPath: path] = Int($0.rounded()); configuration = next })
    }
    func restoreDefaults() {
        let defaults = GestureConfiguration()
        var updated = configuration
        updated.magicMouseMinDensity = defaults.magicMouseMinDensity
        updated.magicMouseMaxLandingSkewMilliseconds = defaults.magicMouseMaxLandingSkewMilliseconds
        updated.magicMouseFastLandingMilliseconds = defaults.magicMouseFastLandingMilliseconds
        updated.magicMouseSlowMinDensity = defaults.magicMouseSlowMinDensity
        updated.magicMouseFreshChordWindowMilliseconds = defaults.magicMouseFreshChordWindowMilliseconds
        updated.maximumTouchMovement = defaults.maximumTouchMovement
        configuration = updated
    }
    var recordingBinding: Binding<Bool> {
        Binding(get: { configuration.touchSampleRecordingEnabled },
                set: { var next = configuration; next.touchSampleRecordingEnabled = $0; configuration = next })
    }
    private var recording: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
            Toggle(isOn: recordingBinding) {
                SettingsRowLabel(SettingsStrings.magicMouseRecording, icon: "record.circle")
            }
            .accessibilityLabel(SettingsStrings.magicMouseRecording)
            HStack(spacing: 12) {
                SettingsRowLabel(SettingsStrings.magicMouseMark, icon: "tag")
                Spacer(minLength: 12)
                SettingsSegmented(selection: Binding(get: { state.label }, set: { value in state.mark(value) }),
                                  options: TouchSampleLabel.allCases.map { ($0, SettingsStrings.magicMouseLabel($0)) })
                    .accessibilityLabel(SettingsStrings.magicMouseMark)
            }
            if state.clearing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(SettingsStrings.magicMouseClearing).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if state.clearFailed || state.storageFailed {
                Label(state.clearFailed ? SettingsStrings.magicMouseClearFailure : SettingsStrings.magicMouseStorageFailure,
                      systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var comparison: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
            HStack(spacing: 12) {
                Text(SettingsStrings.magicMouseComparison).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Button(state.clearFailed ? SettingsStrings.magicMouseClearRetry : SettingsStrings.magicMouseClear, role: .destructive) {
                    Task { await state.clear() }
                }
                .disabled(state.clearing)
                .accessibilityLabel(SettingsStrings.magicMouseClear)
            }
            HStack(spacing: 10) {
                ForEach(state.samplePresentation.rows, id: \.label) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SettingsStrings.magicMouseLabel(summary.label)).font(.system(size: 12.5, weight: .semibold))
                        Text(SettingsStrings.magicMouseRecorded(summary.count)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Text(SettingsStrings.magicMouseTriggered(summary.triggered, ratio: summary.ratio))
                            .font(.system(size: 13)).monospacedDigit()
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(SettingsPalette.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            if state.samples.isEmpty {
                Text(SettingsStrings.magicMouseComparisonEmpty).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else { scatter }
        }
    }
    private var scatter: some View {
        MagicMouseScatterPlot(points: state.samplePresentation.scatter, density: configuration.magicMouseMinDensity,
                              slowDensity: max(configuration.magicMouseMinDensity, configuration.magicMouseSlowMinDensity),
                              stateID: ObjectIdentifier(state), revision: state.samplePresentationRevision).equatable()
    }
}

/// Contour updates do not rebuild the 500-point plot; its cache revision and threshold admit changes.
private struct MagicMouseScatterPlot: View, Equatable {
    let points: [MagicMouseScatterPoint]
    let density: Float
    let slowDensity: Float
    let stateID: ObjectIdentifier
    let revision: UInt64
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stateID == rhs.stateID && lhs.revision == rhs.revision && lhs.density == rhs.density && lhs.slowDensity == rhs.slowDensity
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 28) {
                    Text(SettingsStrings.magicMouseLabel(.single)); Text(SettingsStrings.magicMouseLabel(.real))
                }.font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let position: (Float) -> CGFloat = { min(1, max(0, (CGFloat($0) - 0.4) / 1.4)) * width }
                    Path { path in
                        for y in [CGFloat(20), 60] { path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: width, y: y)) }
                    }.stroke(SettingsPalette.hairline, lineWidth: 1)
                    ForEach(points) { sample in
                        Circle().fill(Color.primary.opacity(0.45)).frame(width: 4, height: 4)
                            .position(x: position(sample.density), y: sample.label == .single ? 20 : 60)
                    }
                    Path { path in let x = position(density)
                        path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: 80))
                    }.stroke(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    Path { path in let x = position(slowDensity)
                        path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: 80))
                    }.stroke(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [2, 3])).opacity(0.6)
                }.frame(height: 80).accessibilityHidden(true)
            }
            Text(SettingsStrings.magicMouseDensityAxis).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(SettingsStrings.magicMouseLegend).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
