import AppKit
import SwiftUI
import VoicePointerCore

struct HapticReviewDevice {
    let kind: TouchDeviceKind
    let deviceID: UInt64 = 0
}

@MainActor
struct HapticStrengthSettingsRow: View {
    @Binding var strength: HapticStrength
    /// Non-nil only in the isolated review host. Never enumerate or actuate hardware.
    var deviceFixture: [HapticReviewDevice]? = nil
    @State private var devices: [TouchDeviceInfo] = []
    @State private var demoTask: Task<Void, Never>?
    @State private var feedback = ZoneHapticFeedback()

    private var trackpad: TouchDeviceInfo? {
        devices.first { $0.kind == .builtInTrackpad || $0.kind == .externalTrackpad }
    }
    private var hasTrackpad: Bool {
        deviceFixture.map { $0.contains { $0.kind == .builtInTrackpad || $0.kind == .externalTrackpad } } ?? (trackpad != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 2026-11-07: one line like every other row. Clicking a strength (also the one already chosen)
            // plays it on the trackpad, so there is no separate 「试一下」.
            HStack(spacing: 12) {
                SettingsRowLabel(SettingsStrings.hapticStrength, icon: "hand.tap")
                Spacer(minLength: 12)
                SettingsSegmented(selection: $strength, options: [
                    (HapticStrength.standard, SettingsStrings.hapticStandard),
                    (HapticStrength.strong, SettingsStrings.hapticStrong),
                    (HapticStrength.max, SettingsStrings.hapticMax),
                ], onPick: { demonstrate($0) })
                .accessibilityLabel(SettingsStrings.hapticStrength)
                .help(SettingsStrings.hapticTapToFeel)
            }
            .disabled(!hasTrackpad)
            if !hasTrackpad {
                Text(SettingsStrings.hapticMouseExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, SettingsLayout.tileSize + 12)
            }
        }
        .onAppear { if deviceFixture == nil { devices = MultitouchDriver().devices } }
        .onDisappear { demoTask?.cancel(); demoTask = nil; if deviceFixture == nil { feedback.end() } }
    }
    /// The finger that clicked is still on the trackpad, so it feels the strength it picked. A new click
    /// replaces a sample that is still playing.
    private func demonstrate(_ level: HapticStrength) {
        guard deviceFixture == nil, let trackpad else { return }
        // A sample still playing keeps its open actuator; only the first click opens one.
        let opening = demoTask == nil
        demoTask?.cancel()
        if opening { feedback.begin(deviceKind: trackpad.kind, deviceID: trackpad.deviceID) }
        demoTask = Task { @MainActor in
            do {
                // Open is asynchronous; pending Open still safely falls back.
                if opening { try await Task.sleep(for: .milliseconds(120)) }
                for zone in [HapticZone.send, .center, .cancel] {
                    try Task.checkCancellation()
                    feedback.trigger(zone: zone, strength: level)
                    try await Task.sleep(for: .milliseconds(320))
                }
            } catch {}
            guard !Task.isCancelled else { return }
            feedback.end()
            demoTask = nil
        }
    }
}
