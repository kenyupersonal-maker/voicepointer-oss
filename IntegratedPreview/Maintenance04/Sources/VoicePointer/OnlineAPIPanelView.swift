import SwiftUI
import VoicePointerCore

/// Display-only projection of existing authorization; connection authentication is independent.
enum OnlineAudioUploadStatus {
    case unknown, inactive, onlineRecognition, localEnhancement

    var text: String {
        switch self {
        case .unknown: "阿里云声音上传状态尚未确认。"
        case .inactive: "当前阿里云声音上传未启用。"
        case .onlineRecognition: "阿里云识别已启用，说话时声音会上传。"
        case .localEnhancement: "本地识别增强已启用，说话时声音也会上传给阿里云。"
        }
    }
}

struct OnlineAPIPanelView<LanguagePicker: View>: View {
    let saved: Bool
    let attention: String?
    let authenticated: Bool
    let confirmation: CloudEntryStatus
    let now: Date
    let audioUploadStatus: OnlineAudioUploadStatus
    let testNote: String
    let busy: Bool
    @Binding var enhancement: Bool
    let configure: () -> Void
    let replace: () -> Void
    let remove: () -> Void
    let reconfirm: () -> Void
    let test: () -> Void
    let help: () -> Void
    @ViewBuilder let languagePicker: () -> LanguagePicker
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !saved {
                VStack(spacing: 12) {
                    icon
                    Text("还没有配置云端").font(.system(size: 18, weight: .semibold))
                    Text("把阿里云接入咻，用于在线识别或增强本地识别。\n配置前会说明声音上传和免费额度确认。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("开始配置", action: configure).buttonStyle(.borderedProminent).controlSize(.large).accessibilityLabel("开始配置云端")
                    Button("官方图文说明 ↗", action: help).buttonStyle(.plain).foregroundStyle(OnboardingStyle.accent).accessibilityLabel("打开官方图文说明")
                }.frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 14).card()
                Text("配置向导共 4 步，约 3 分钟：创建 Key → 打开「免费额度用完即停」→ 粘贴并验证 → 说一句试试。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    icon
                    VStack(alignment: .leading, spacing: 4) {
                        Text("在线 API").font(.system(size: 18, weight: .semibold))
                        Text("云端识别与本地识别增强，由你控制开启。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if let attention {
                    HStack(spacing: 8) {
                        Label(attention, systemImage: "exclamationmark.circle.fill").font(.system(size: 12))
                        Spacer()
                        Button("重新配置", action: configure).buttonStyle(.borderedProminent).accessibilityLabel("重新配置云端")
                    }.foregroundStyle(.orange).padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("阿里云百炼").font(.system(size: 13, weight: .semibold))
                            Text("华北2（北京）· \(CloudEntry.modelID)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(attention != nil ? "需要处理" : authenticated ? "连接正常" : "尚未测试",
                              systemImage: attention != nil ? "exclamationmark.circle.fill" : authenticated ? "checkmark.circle.fill" : "minus.circle")
                            .font(.system(size: 11)).foregroundStyle(attention != nil ? Color.orange : authenticated ? OnboardingStyle.accent : Color.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background((attention != nil ? Color.orange : authenticated ? OnboardingStyle.accent : Color.secondary).opacity(0.12), in: Capsule())
                            .fixedSize()
                        Button("测试连接", action: test).buttonStyle(.bordered).disabled(busy).accessibilityLabel("测试阿里云连接，不发送声音")
                    }
                    if !testNote.isEmpty { Text(testNote).font(.system(size: 11)).foregroundStyle(.secondary) }
                }.padding(12).card()
                groupTitle("凭据")
                VStack(spacing: 0) {
                    HStack {
                        Text("API Key")
                        Spacer()
                        Text("已保存").foregroundStyle(.secondary)
                        Button("替换", action: replace).buttonStyle(.plain).foregroundStyle(OnboardingStyle.accent).accessibilityLabel("替换 API Key")
                        Button("删除", action: remove).buttonStyle(.plain).foregroundStyle(.red).accessibilityLabel("删除 API Key")
                    }.padding(12)
                    Divider().padding(.horizontal, 14)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("免费额度用完即停")
                            Text(confirmationText).font(.system(size: 11)).foregroundStyle(confirmationNearExpiry ? Color.orange : Color.secondary)
                        }
                        Spacer()
                        Button("重新确认", action: reconfirm).buttonStyle(.plain).foregroundStyle(OnboardingStyle.accent).accessibilityLabel("重新确认免费额度用完即停")
                    }.padding(12)
                }.font(.system(size: 13)).card()
                groupTitle("使用方式")
                VStack(alignment: .leading, spacing: 0) {
                    Toggle("用于增强本地识别", isOn: Binding(get: { attention == nil && enhancement }, set: { enhancement = $0 }))
                        .toggleStyle(SettingsSwitchStyle()).disabled(attention != nil).font(.system(size: 13)).padding([.horizontal, .top], 12)
                    Text("开启后，说话时声音也会发给阿里云，帮你校对本地结果。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 12)
                    Divider().padding(.horizontal, 14)
                    languagePicker().padding([.horizontal, .top], 12)
                    Text("阿里云只支持中文、English 和自动。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 12)
                }.card()
                Text(audioUploadStatus.text)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("测试连接不发送声音。删除 Key 后，依赖它的在线识别和增强会关闭。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4).tint(OnboardingStyle.accent)
    }
    private var icon: some View {
        Image(systemName: "cloud.fill").font(.system(size: 24)).foregroundStyle(.white)
            .frame(width: saved ? 36 : 52, height: saved ? 36 : 52)
            .background(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
    }
    private func groupTitle(_ value: String) -> some View { Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
    private var confirmationText: String {
        if case .confirmed(let until) = confirmation {
            let days = max(0, Int(ceil(until.timeIntervalSince(now) / 86400)))
            return days <= 7 ? "已确认 · \(days) 天后到期" : "已确认 · 至 \(until.formatted(date: .abbreviated, time: .omitted))"
        }
        return confirmation.title()
    }
    private var confirmationNearExpiry: Bool {
        if case .confirmed(let until) = confirmation { return until.timeIntervalSince(now) <= 7 * 86400 }
        return true
    }
}

private extension View {
    func card() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
    }
}
