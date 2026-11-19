@preconcurrency import AVFoundation
import Foundation

/// The HUD's level scale for one captured buffer: the larger of RMS x 2.8 and peak x 0.72, clamped to
/// 0...1. It is the same formula the HUD's own meter applies (`VPCLevelForPCMBuffer`), so a level
/// published by the recognizer's capture reads exactly like the meter's.
public enum PCMBufferLevel {
    /// Raw, format-aware numbers for diagnostics and the silence gate. No audio is retained.
    public struct Measurement: Sendable {
        public let peak: Float
        public let level: Float
        public let supported: Bool
    }

    public static func measure(_ buffer: AVAudioPCMBuffer) -> Measurement {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let bytes: Int
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32, .pcmFormatInt32: bytes = 4
        case .pcmFormatFloat64: bytes = 8
        case .pcmFormatInt16: bytes = 2
        default: return Measurement(peak: 0, level: 0, supported: false)
        }
        guard frames > 0, channels > 0, list.count >= (interleaved ? 1 : channels) else {
            return Measurement(peak: 0, level: 0, supported: false)
        }
        var sum = 0.0, peak = 0.0
        var valid = 0
        for channel in 0..<channels {
            let audio = list[interleaved ? 0 : channel]
            let elements = interleaved ? frames * channels : frames
            guard let pointer = audio.mData, Int(audio.mDataByteSize) >= elements * bytes else {
                return Measurement(peak: 0, level: 0, supported: false)
            }
            for frame in 0..<frames {
                let index = interleaved ? frame * channels + channel : frame
                let sample: Double
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32: sample = Double(pointer.assumingMemoryBound(to: Float.self)[index])
                case .pcmFormatFloat64: sample = pointer.assumingMemoryBound(to: Double.self)[index]
                case .pcmFormatInt16: sample = Double(pointer.assumingMemoryBound(to: Int16.self)[index]) / 32768
                case .pcmFormatInt32: sample = Double(pointer.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
                default: return Measurement(peak: 0, level: 0, supported: false)
                }
                guard sample.isFinite else { continue }
                sum += sample * sample
                peak = max(peak, abs(sample))
                valid += 1
            }
        }
        guard valid > 0, sum.isFinite, peak <= Double(Float.greatestFiniteMagnitude) else {
            return Measurement(peak: 0, level: 0, supported: false)
        }
        let rms = (sum / Double(valid)).squareRoot()
        return Measurement(peak: Float(peak), level: Float(min(max(rms * 2.8, peak * 0.72), 1)), supported: true)
    }

    public static func level(of buffer: AVAudioPCMBuffer) -> Float {
        measure(buffer).level
    }
}
