import AppKit
import AVFoundation
import VoicePointerCore

/// Uses the matching macOS system sounds when present, with short in-memory
/// PCM fallbacks so an OS resource-path change never makes feedback silent.
@MainActor
final class VoicePointerHUDSound {
    static let shared = VoicePointerHUDSound()

    /// Playback runs on its own queue: opening the output device can wait for seconds while a
    /// Bluetooth headset changes profile, and that must never block the main thread.
    private let output = HUDSoundOutput()
    private var sendSoundData: Data?
    private var sendSoundSource = "synth"
    private var sendRenderStarted = false
    /// Table-rendered Send sounds (see `SendSoundChoice`), rendered once in the background.
    private var tableSounds: [SendSoundChoice: Data] = [:]
    private var tableRendersInFlight: Set<SendSoundChoice> = []
    private var pendingPreview: SendSoundChoice?

    private enum SoundProfile { case sendWhoosh, cancelTrash }

    /// "咻" v6 (2026-09-30): v5 re-synthesized the system "sent" sound as a sine that follows
    /// its measured pitch and level. The pitch survived but the swoosh texture did not, so
    /// Send stopped sounding like "咻" (user: had not heard it for a long time). v6 plays the
    /// real system sound again, a major third higher (+400 cents) at its original length
    /// through AVAudioUnitTimePitch, rendered offline once in the background. The v5
    /// synthesis below remains only as the fallback when the file is missing or rendering fails.
    nonisolated private static let sendPitchCents: Float = 400
    nonisolated private static let sendCandidates = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/SentMessage.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/acknowledgment_sent.caf",
    ]

    /// v5 fallback: the original system "sent" sound is a soft tone gliding 350 → 460 Hz.
    /// Its level and pitch were measured every 10 ms; the fallback replays that contour a
    /// major third higher at the original length (0.49 s), with a faint breath of
    /// band-passed noise riding on the same contour.
    static let sendLevels: [Double] = [
        0.0001, 0.0003, 0.0004, 0.0003, 0.0011, 0.0021, 0.0036, 0.0059, 0.0086, 0.0124,
        0.0177, 0.0229, 0.0313, 0.0388, 0.0497, 0.0603, 0.0816, 0.0969, 0.1003, 0.1360,
        0.1564, 0.2161, 0.2792, 0.2877, 0.2519, 0.1985, 0.1361, 0.0774, 0.0761, 0.0746,
        0.0647, 0.0506, 0.0344, 0.0240, 0.0147, 0.0104, 0.0067, 0.0042, 0.0025, 0.0014,
        0.0007, 0.0005, 0.0005, 0.0003, 0.0001, 0.0001, 0.0000, 0.0000, 0.0000,
    ]
    private static let sendPitches: [Double] = [
        364, 364, 364, 364, 364, 364, 351, 358, 359, 355, 354, 355,
        357, 356, 360, 357, 358, 359, 356, 364, 367, 389, 406, 418,
        423, 436, 445, 464, 459, 457, 455, 455, 455, 456, 458, 455,
        454, 457, 449, 449, 449, 449, 449, 449, 449, 449, 449, 449,
        449,
    ]
    /// A major third: 2^(4/12).
    private static let sendPitchRatio = 1.259_921
    /// Breath level relative to the tone (about -23 dB RMS).
    private static let sendBreath = 0.35

    /// Starts rendering the Send sounds in the background so the first Send never waits for them.
    func prepare() {
        let choice = SendSoundChoice.load()
        prepare(choice)
        prepareSelectedOutput(choice)
        guard sendSoundData == nil, !sendRenderStarted else { return }
        sendRenderStarted = true
        Task.detached(priority: .utility) {
            let rendered = VoicePointerHUDSound.renderSystemSend()
            await MainActor.run {
                VoicePointerHUDSound.shared.adoptRenderedSend(rendered)
            }
        }
    }

    private func adoptRenderedSend(_ rendered: Data?) {
        if let rendered {
            sendSoundData = rendered
            sendSoundSource = "system"
            RuntimeTrace.record("hud sound send render=ok bytes=\(rendered.count)")
        } else {
            sendSoundData = Self.makeWaveData(profile: .sendWhoosh)
            sendSoundSource = "synth"
            RuntimeTrace.record("hud sound send render=failed fallback=synth")
        }
        prepareSelectedOutput(SendSoundChoice.load())
    }

    /// Prepares the selected player's output without playing a buffer or opening input.
    func prepareForDictation() {
        prepare()
        output.prepareForPlayback()
    }

    private func prepareSelectedOutput(_ choice: SendSoundChoice) {
        let data = choice == .system ? sendSoundData : tableSounds[choice]
        if let data { output.prepare(data, volume: 0.5) }
    }

    func playSend() {
        OutputVolumeController.shared.restoreForCue() // Must attempt restoring before playback starts.
        let choice = SendSoundChoice.load()
        prepare()
        if choice != .system, let data = tableSounds[choice] {
            playSendData(data, source: choice.rawValue, note: "", fallbackDuration: 0.40)
            return
        }
        playSystemSend(requested: choice)
    }

    /// Settings "试听": plays `choice` now, or as soon as its background render lands.
    func preview(_ choice: SendSoundChoice) {
        prepare(choice)
        prepareSelectedOutput(choice)
        guard choice != .system else {
            pendingPreview = nil
            playSystemSend(requested: .system)
            return
        }
        if let data = tableSounds[choice] {
            pendingPreview = nil
            output.play([.data(data)], volume: 0.5, fallbackDuration: 0.40) { _, _ in }
            return
        }
        pendingPreview = choice
        prepare(choice)
    }

    private func playSystemSend(requested: SendSoundChoice) {
        // Until the background render lands (only right after launch), play the synthesized
        // stand-in without caching it, so the real sound is used as soon as it is ready.
        let data = sendSoundData ?? Self.makeWaveData(profile: .sendWhoosh)
        let source = sendSoundData == nil ? "synth" : sendSoundSource
        let note = requested == .system ? "" : " requested=\(requested.rawValue)"
        playSendData(data, source: source, note: note, fallbackDuration: 0.60)
    }

    /// Hands the Send sound to the background output and logs when the device call returns.
    /// `playMs` is how long that call waited: a value in the hundreds or thousands means the
    /// output device was busy (a Bluetooth headset switching profile), not that the app was.
    private func playSendData(_ data: Data, source: String, note: String, fallbackDuration: TimeInterval) {
        output.play([.data(data)], volume: 0.5, fallbackDuration: fallbackDuration) { started, waitedMs in
            RuntimeTrace.record("hud sound send played=\(started) source=\(source)\(note) playMs=\(waitedMs)")
        }
    }

    private func prepare(_ choice: SendSoundChoice) {
        guard let table = choice.table, tableSounds[choice] == nil,
              !tableRendersInFlight.contains(choice) else { return }
        tableRendersInFlight.insert(choice)
        Task.detached(priority: .userInitiated) {
            let data = VoicePointerHUDSound.renderTable(table)
            await MainActor.run {
                VoicePointerHUDSound.shared.adoptTableSound(choice, data)
            }
        }
    }

    private func adoptTableSound(_ choice: SendSoundChoice, _ data: Data?) {
        tableRendersInFlight.remove(choice)
        guard let data else {
            RuntimeTrace.record("hud sound table render=failed choice=\(choice.rawValue)")
            return
        }
        tableSounds[choice] = data
        if choice == SendSoundChoice.load() { output.prepare(data, volume: 0.5) }
        if pendingPreview == choice {
            pendingPreview = nil
            output.play([.data(data)], volume: 0.5, fallbackDuration: 0.40) { _, _ in }
        }
    }

    nonisolated private static func renderTable(_ table: [[Int8]]) -> Data? {
        let samples = ShapedNoiseSound.render(halfDecibels: table)
        guard !samples.isEmpty else { return nil }
        return encodeWave(channels: [samples], sampleRate: ShapedNoiseSound.sampleRate)
    }

    func playCancel(early: Bool = false) {
        OutputVolumeController.shared.restoreForCue() // Cancel cue uses the same safety ordering.
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/poof item off dock.aif",
        ]
        var sources = candidates
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { HUDSoundOutput.Source.file($0) }
        sources.append(.data(cancelFallbackData))
        output.play(sources, volume: 0.36, fallbackDuration: 0.90) { started, waitedMs in
            RuntimeTrace.record("hud sound cancel played=\(started) playMs=\(waitedMs) early=\(early ? 1 : 0)")
        }
    }

    /// A short distinct failure cue. The output level is restored before a system beep.
    func playFailure() {
        OutputVolumeController.shared.restoreForCue()
        NSSound.beep()
        RuntimeTrace.record("hud sound failure cue=systemBeep")
    }

    private lazy var cancelFallbackData: Data = Self.makeWaveData(profile: .cancelTrash)

    /// The first system "sent" sound that exists, pitched up by `sendPitchCents` at its
    /// original length; nil when neither file is present or rendering fails.
    nonisolated private static func renderSystemSend() -> Data? {
        for path in sendCandidates where FileManager.default.fileExists(atPath: path) {
            if let data = renderPitched(URL(fileURLWithPath: path), cents: sendPitchCents) {
                return data
            }
        }
        return nil
    }

    /// Offline pitch shift that keeps the clip's length. No audio device, microphone, or main
    /// thread is involved; the result is a 16-bit PCM WAV held in memory.
    nonisolated private static func renderPitched(_ url: URL, cents: Float) -> Data? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard file.length > 0, Double(file.length) < format.sampleRate * 5 else { return nil }
        let inputFrames = AVAudioFrameCount(file.length)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inputFrames),
              (try? file.read(into: input)) != nil else { return nil }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let shifter = AVAudioUnitTimePitch()
        shifter.pitch = cents
        engine.attach(player)
        engine.attach(shifter)
        engine.connect(player, to: shifter, format: format)
        engine.connect(shifter, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2_048)
            try engine.start()
        } catch {
            return nil
        }
        defer {
            player.stop()
            engine.stop()
        }
        player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
        player.play()

        let output = engine.manualRenderingFormat
        guard let chunk = AVAudioPCMBuffer(
            pcmFormat: output, frameCapacity: engine.manualRenderingMaximumFrameCount) else { return nil }
        // The time-pitch unit delays its output: render a tail past the input, then trim silence.
        let totalFrames = inputFrames + AVAudioFrameCount(output.sampleRate * 0.3)
        let channelCount = Int(output.channelCount)
        guard channelCount > 0 else { return nil }
        var channels = [[Float]](repeating: [], count: channelCount)
        var renderedFrames: AVAudioFrameCount = 0
        while renderedFrames < totalFrames {
            let request = min(chunk.frameCapacity, totalFrames - renderedFrames)
            guard let status = try? engine.renderOffline(request, to: chunk), status == .success,
                  let samples = chunk.floatChannelData, chunk.frameLength > 0 else { return nil }
            for channel in 0..<channelCount {
                channels[channel].append(contentsOf: UnsafeBufferPointer(
                    start: samples[channel], count: Int(chunk.frameLength)))
            }
            renderedFrames += chunk.frameLength
        }
        // Keep only the audible span (above about -66 dBFS) so the unit's latency never
        // delays the sound.
        let rendered = channels
        let frameCount = rendered[0].count
        let audible = { (frame: Int) -> Bool in rendered.contains { abs($0[frame]) > 0.0005 } }
        guard let first = (0..<frameCount).first(where: audible),
              let last = (0..<frameCount).last(where: audible), last > first else { return nil }
        return encodeWave(
            channels: rendered.map { Array($0[first...last]) },
            sampleRate: Int(output.sampleRate.rounded()))
    }

    nonisolated private static func encodeWave(channels: [[Float]], sampleRate: Int) -> Data? {
        guard let frameCount = channels.first?.count, frameCount > 0, sampleRate > 0,
              channels.allSatisfy({ $0.count == frameCount }) else { return nil }
        let channelCount = channels.count
        let blockAlign = channelCount * MemoryLayout<Int16>.size
        let dataByteCount = frameCount * blockAlign
        var data = Data(capacity: 44 + dataByteCount)
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(channelCount), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * blockAlign), to: &data)
        appendLittleEndian(UInt16(blockAlign), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(dataByteCount), to: &data)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let value = max(-1, min(1, channels[channel][frame]))
                appendLittleEndian(Int16(value * Float(Int16.max)), to: &data)
            }
        }
        return data
    }

    private static func makeWaveData(profile: SoundProfile, sampleRate: Int = 44_100) -> Data {
        let duration = profile == .sendWhoosh ? Double(sendLevels.count) * 0.01 : 0.32
        let frameCount = max(1, Int(duration * Double(sampleRate)))
        let dataByteCount = frameCount * MemoryLayout<Int16>.size
        var data = Data(capacity: 44 + dataByteCount)

        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * MemoryLayout<Int16>.size), to: &data)
        appendLittleEndian(UInt16(MemoryLayout<Int16>.size), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(dataByteCount), to: &data)

        var phase = 0.0
        var noiseState: UInt32 = 0x51A7_CE11
        var smoothedNoise = 0.0
        // Breath: white noise through a wide band-pass at 1.6 kHz (Chamberlin form,
        // Q 0.7), then a one-pole low-pass at 4 kHz.
        var breathLow = 0.0
        var breathBand = 0.0
        var breathSoft = 0.0
        let breathCoefficient = 2 * sin(Double.pi * 1_600 / Double(sampleRate))
        let breathDamping = 1 / 0.7
        let breathLowPass = 1 - exp(-2 * Double.pi * 4_000 / Double(sampleRate))
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let progress = time / duration
            noiseState = 1_664_525 &* noiseState &+ 1_013_904_223
            let whiteNoise = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
            smoothedNoise += (whiteNoise - smoothedNoise) * 0.10
            let airyNoise = whiteNoise - smoothedNoise

            let normalized: Double
            switch profile {
            case .sendWhoosh:
                let tone = Self.sendContour(at: time)
                let breathLevel = Self.sendContour(at: time + 0.012).level
                phase += 2 * .pi * tone.pitch * Self.sendPitchRatio / Double(sampleRate)
                breathLow += breathCoefficient * breathBand
                let breathHigh = whiteNoise - breathLow - breathDamping * breathBand
                breathBand += breathCoefficient * breathHigh
                breathSoft += breathLowPass * (breathBand - breathSoft)
                normalized = tone.level * sin(phase) + breathLevel * Self.sendBreath * breathSoft
                _ = (airyNoise, progress)

            case .cancelTrash:
                let burstCenters = [0.05, 0.18, 0.36, 0.58, 0.76]
                let burst = burstCenters.reduce(0.0) { value, center in
                    let distance = (progress - center) / 0.075
                    return value + exp(-distance * distance)
                }
                let body = (whiteNoise * 0.52 + smoothedNoise * 0.48) * min(1, time / 0.008)
                let tail = pow(max(0, 1 - progress), 0.72)
                let thump = sin(2 * .pi * 92 * time) * exp(-18 * max(0, time - 0.19))
                    * (time >= 0.19 ? 1 : 0)
                normalized = (body * (0.22 + min(1, burst) * 0.78) * tail + thump * 0.16) * 0.22
            }
            let sample = Int16(clamping: Int(normalized * Double(Int16.max)))
            appendLittleEndian(sample, to: &data)
        }
        return data
    }

    /// Level and pitch of the measured contour at `time`, linearly interpolated.
    private static func sendContour(at time: Double) -> (level: Double, pitch: Double) {
        let position = time / 0.01 - 0.5
        let index = Int(position.rounded(.down))
        let fraction = position - Double(index)
        let last = sendLevels.count - 1
        let i0 = min(max(index, 0), last)
        let i1 = min(max(index + 1, 0), last)
        let level = sendLevels[i0] * (1 - fraction) + sendLevels[i1] * fraction
        let pitch = sendPitches[i0] * (1 - fraction) + sendPitches[i1] * fraction
        return (level, pitch)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    nonisolated private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

/// Owns every call that can wait on Core Audio. Opening the output device can take seconds when
/// a Bluetooth headset is still changing profile right after a dictation: on 2026-09-30 three
/// AirPods sends stalled the main thread for 0.25 to 3.1 s, the longest long enough for the
/// input watchdog to re-arm. So playback never runs on the main thread. Everything here is
/// confined to `queue`; there are no completion or render callbacks that could inherit an
/// actor's isolation onto a Core Audio thread.
private final class HUDSoundOutput: @unchecked Sendable {
    enum Source: Sendable {
        case data(Data)
        case file(String)
    }

    private let queue = DispatchQueue(label: "com.kenyu.VoicePointer.hud-sound", qos: .userInteractive)
    private var current: AVAudioPlayer? // queue-confined
    private var preparedSend: AVAudioPlayer? // retained, no continuously playing audio
    private var preparedSendData: Data?
    private var generation: UInt64 = 0 // queue-confined

    func prepare(_ data: Data, volume: Float) {
        queue.async { [self] in
            if preparedSendData != data {
                preparedSend = try? AVAudioPlayer(data: data)
                preparedSendData = preparedSend == nil ? nil : data
            }
            preparedSend?.volume = volume
            preparedSend?.prepareToPlay()
        }
    }

    func prepareForPlayback() {
        queue.async { [self] in preparedSend?.prepareToPlay() }
    }

    /// Plays the first source that opens and reports whether it started and how long the
    /// device call waited, in milliseconds. A newer sound replaces the one still playing.
    func play(
        _ sources: [Source],
        volume: Float,
        fallbackDuration: TimeInterval,
        completion: @escaping @Sendable (_ started: Bool, _ waitedMs: Int) -> Void
    ) {
        let began = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            current?.stop()
            current = nil
            generation &+= 1
            let mine = generation
            var started = false
            for source in sources {
                let candidate: AVAudioPlayer?
                if case .data(let data) = source, preparedSendData == data {
                    candidate = preparedSend
                } else {
                    candidate = Self.makePlayer(source)
                }
                guard let player = candidate else { continue }
                player.volume = volume
                player.currentTime = 0
                player.prepareToPlay()
                guard player.play() else { continue }
                current = player
                started = true
                let reported = player.duration
                let duration = reported.isFinite && reported > 0 ? max(0.2, reported) : fallbackDuration
                queue.asyncAfter(deadline: .now() + duration + 0.15) { [self] in
                    if generation == mine { current = nil }
                }
                break
            }
            let waitedMs = Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            completion(started, waitedMs)
        }
    }

    private static func makePlayer(_ source: Source) -> AVAudioPlayer? {
        switch source {
        case .data(let data): return try? AVAudioPlayer(data: data)
        case .file(let path): return try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        }
    }
}
