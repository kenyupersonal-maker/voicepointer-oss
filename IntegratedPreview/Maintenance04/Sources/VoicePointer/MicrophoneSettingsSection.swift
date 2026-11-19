import SwiftUI
import VoicePointerCore

struct MicrophoneSettingsSection: View {
    @AppStorage(InputDeviceRuntime.policyKey) private var policy = "auto"
    @AppStorage(InputDeviceRuntime.pinnedKey) private var pinned = ""
    @State private var devices: [InputDevice] = []
    var body: some View {
        SettingsGroup(SettingsStrings.microphoneTitle) {
            LabeledContent {
            Picker(SettingsStrings.microphoneTitle, selection: Binding(get: {
                policy == "pinned" ? "device:" + pinned : policy
            }, set: { value in
                if value.hasPrefix("device:") { pinned = String(value.dropFirst(7)); policy = "pinned" }
                else { policy = value }
            })) {
                Text(SettingsStrings.microphoneAutomatic).tag("auto")
                Text(SettingsStrings.microphoneSystem).tag("system")
                ForEach(devices, id: \.key) { Text($0.name).tag("device:" + $0.key) }
                if policy == "pinned", !devices.contains(where: { $0.key == pinned }) {
                    Text(SettingsStrings.microphoneMissing).tag("device:" + pinned)
                }
            }
            // The pop-up draws at its own width inside this frame; keep it on the right edge like every other control.
            .labelsHidden().frame(width: 180, alignment: .trailing)
            } label: { SettingsRowLabel(SettingsStrings.microphoneTitle, icon: "mic") }
            Text(SettingsStrings.microphoneAutomaticDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, SettingsLayout.tileSize + 12)
        }.task {
            while !Task.isCancelled {
                devices = InputDeviceInventory.read().devices
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
