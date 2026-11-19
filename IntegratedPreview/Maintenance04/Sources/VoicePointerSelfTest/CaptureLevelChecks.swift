@preconcurrency import AVFoundation
import Foundation
import VoicePointerCore

/// The ripple follows what the recognizer hears when the HUD's own meter engine reads silence
/// (Bluetooth headset switching profile); these pin the shared level bus and the level formula.
enum CaptureLevelChecks {
    static func run() -> [String] {
        var failures: [String] = []

        let bus = CaptureLevelBus()
        if bus.recent(now: 1_000) != nil { failures.append("a bus nobody published to must read nil") }
        bus.publish(0.4, now: 1_000)
        if bus.recent(maxAgeNanoseconds: 300, now: 1_200) != 0.4 { failures.append("a fresh reading must be returned") }
        if bus.recent(maxAgeNanoseconds: 300, now: 1_300) != 0.4 { failures.append("a reading exactly at the age limit is still fresh") }
        if bus.recent(maxAgeNanoseconds: 300, now: 1_301) != nil { failures.append("a stale reading must read nil") }
        if bus.recent(maxAgeNanoseconds: 300, now: 900) != nil { failures.append("a reading from the future must read nil") }
        bus.publish(3, now: 2_000)
        if bus.recent(maxAgeNanoseconds: 300, now: 2_000) != 1 { failures.append("levels clamp to 1") }
        bus.publish(.nan, now: 2_100)
        bus.publish(-0.5, now: 2_200)
        if bus.recent(maxAgeNanoseconds: 300, now: 2_200) != 0 { failures.append("negative levels clamp to 0 and NaN is ignored") }
        if bus.sampleCount() != 3 { failures.append("sample count must count accepted publishes (\(bus.sampleCount()))") }
        bus.invalidate()
        if bus.recent(maxAgeNanoseconds: .max, now: 2_300) != nil { failures.append("an invalidated bus must read nil") }
        if bus.sampleCount() != 3 { failures.append("invalidate must not rewind the sample count") }
        bus.publish(0.2, now: 3_000)
        if bus.recent(maxAgeNanoseconds: 10, now: 3_005) != 0.2 { failures.append("publishing after invalidate must work") }

        bus.captureBegan()
        bus.captureBegan()
        bus.captureEnded()
        if bus.activeCaptures != 1 { failures.append("capture counter must count open captures") }
        bus.captureEnded()
        bus.captureEnded()
        if bus.activeCaptures != 0 { failures.append("capture counter must never go below zero") }

        // The level formula: max(rms x 2.8, peak x 0.72), 0...1, for both channel layouts.
        func buffer(interleaved: Bool, channels: AVAudioChannelCount, samples: [Float]) -> AVAudioPCMBuffer? {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: interleaved
            ), let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let data = pcm.floatChannelData else { return nil }
            pcm.frameLength = AVAudioFrameCount(samples.count)
            let stride = pcm.stride
            for channel in 0..<Int(channels) {
                for (frame, value) in samples.enumerated() { data[channel][frame * stride] = value }
            }
            return pcm
        }
        let constant = [Float](repeating: 0.25, count: 8)
        var spike = [Float](repeating: 0, count: 8)
        spike[3] = 0.5
        let cases: [(String, AVAudioPCMBuffer?, Float)] = [
            ("constant mono", buffer(interleaved: false, channels: 1, samples: constant), 0.7),
            ("constant stereo planar", buffer(interleaved: false, channels: 2, samples: constant), 0.7),
            ("constant stereo interleaved", buffer(interleaved: true, channels: 2, samples: constant), 0.7),
            ("single spike", buffer(interleaved: false, channels: 1, samples: spike), 0.4950),
            ("digital silence", buffer(interleaved: false, channels: 1, samples: [Float](repeating: 0, count: 8)), 0),
            ("loud clamps", buffer(interleaved: false, channels: 1, samples: [Float](repeating: 0.9, count: 8)), 1),
        ]
        for (name, pcm, expected) in cases {
            guard let pcm else {
                failures.append("could not build the \(name) buffer")
                continue
            }
            let level = PCMBufferLevel.level(of: pcm)
            if abs(level - expected) > 0.001 { failures.append("\(name) level \(level) != \(expected)") }
        }
        if let empty = buffer(interleaved: false, channels: 1, samples: [0]) {
            empty.frameLength = 0
            if PCMBufferLevel.level(of: empty) != 0 { failures.append("an empty buffer must read 0") }
        }
        return failures
    }
}
