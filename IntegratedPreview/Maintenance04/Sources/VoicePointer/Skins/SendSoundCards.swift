import AppKit
import SwiftUI
import VoicePointerCore

/// 2026-09-30 Claude：发送音选择，和圆盘样式一样是一排排卡片，不再是下拉框。
/// 点一下就选中并试听；卡片上画的是这个声音的响度轮廓，试听时从左到右点亮，
/// 所以不看名字也能分出哪个长、哪个短、哪个先响后弱。
@MainActor
struct SendSoundSection: View {
    @State private var selected = SendSoundChoice.load()
    @State private var playback: SoundPlayback?
    @State private var playbackToken = 0

    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 158), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SettingsStrings.sendSoundCardsCopy001)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(SendSoundChoice.allCases, id: \.self) { choice in
                    SendSoundCard(
                        choice: choice,
                        selected: selected == choice,
                        playbackStart: playback?.choice == choice ? playback?.start : nil,
                        action: { pick(choice) }
                    )
                }
            }
            Text(SettingsStrings.sendSoundCardsCopy002)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .task(id: playbackToken) { @MainActor in
            guard let current = playback else { return }
            do {
                try await Task.sleep(for: .seconds(SendSoundContour.seconds(for: current.choice) + 0.3))
            } catch {
                return
            }
            playback = nil
        }
    }

    private func pick(_ choice: SendSoundChoice) {
        selected = choice
        SendSoundChoice.save(choice)
        VoicePointerHUDSound.shared.prepare()
        VoicePointerHUDSound.shared.preview(choice)
        playback = SoundPlayback(choice: choice, start: Date())
        playbackToken &+= 1
    }
}

private struct SoundPlayback: Equatable {
    let choice: SendSoundChoice
    let start: Date
}

@MainActor
private struct SendSoundCard: View {
    let choice: SendSoundChoice
    let selected: Bool
    let playbackStart: Date?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                SendSoundContourView(choice: choice, selected: selected, playbackStart: playbackStart)
                    .frame(height: 30)
                // 2026-11-07 简洁版：只写名字，介绍放到悬停提示里；选中靠蓝色边框，不再另加对勾。
                Text(choice.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
            }
            .padding(10)
            .frame(width: 158, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsPalette.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? SettingsPalette.ink : SettingsPalette.hairline,
                                  lineWidth: SettingsLayout.stroke)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(SettingsStrings.sendSoundCardsCopy003 + choice.title))
        .accessibilityValue(Text(selected ? SettingsStrings.skinAppearancePageCopy018 : ""))
        .help(choice.blurb + "\n" + SettingsStrings.sendSoundCardsCopy005)
    }
}

@MainActor
private struct SendSoundContourView: View {
    let choice: SendSoundChoice
    let selected: Bool
    let playbackStart: Date?

    var body: some View {
        let bars = SendSoundContour.bars(for: choice)
        let seconds = SendSoundContour.seconds(for: choice)
        let idle = selected ? SettingsPalette.brand.opacity(0.55) : Color.primary.opacity(0.28)
        let lit = SettingsPalette.brand
        let start = playbackStart
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: start == nil)) { timeline in
            let progress = start.map { timeline.date.timeIntervalSince($0) / seconds }
            Canvas { context, size in
                let count = bars.count
                guard count > 0 else { return }
                let gap: CGFloat = 1.5
                let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                for index in 0..<count {
                    let height = max(2, size.height * CGFloat(bars[index]))
                    let rect = CGRect(
                        x: CGFloat(index) * (width + gap),
                        y: (size.height - height) / 2,
                        width: width,
                        height: height
                    )
                    let reached = progress.map { $0 * Double(count) > Double(index) } ?? false
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(reached ? lit : idle))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The contour and length of each Send sound: the tables for the rendered sounds, the measured level
/// list for the system one.
@MainActor
private enum SendSoundContour {
    static let barCount = 28
    private static var cache: [SendSoundChoice: [Float]] = [:]

    static func bars(for choice: SendSoundChoice) -> [Float] {
        if let cached = cache[choice] { return cached }
        let computed: [Float]
        if let table = choice.table {
            computed = SoundEnvelope.bars(halfDecibels: table, count: barCount)
        } else {
            computed = SoundEnvelope.bars(linearLevels: VoicePointerHUDSound.sendLevels, count: barCount)
        }
        cache[choice] = computed
        return computed
    }

    static func seconds(for choice: SendSoundChoice) -> Double {
        let rows = choice.table?.count ?? VoicePointerHUDSound.sendLevels.count
        return Double(rows) * ShapedNoiseSound.rowSeconds
    }
}
