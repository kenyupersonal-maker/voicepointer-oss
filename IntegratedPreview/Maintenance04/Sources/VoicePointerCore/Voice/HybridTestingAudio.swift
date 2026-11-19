import Foundation
import AVFoundation

/// Silent PCM for the hybrid self-tests' scripted capture: made in memory, never from a microphone.
enum HybridTestingPCM {
    static func silence(frames: Int, sampleRate: Double) -> OwnedPCMBuffer? {
        guard frames > 0, frames <= Int(UInt32.max), sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        memset(channel, 0, frames * MemoryLayout<Float>.size)
        return try? OwnedPCMBuffer(copying: buffer)
    }
}

extension HybridTestingFactory {
    /// True when the hybrid dictation's one capture is configured exactly like the capture `LocalSpeechBackend`
    /// and `AliSpeechBackend` build for themselves (no Apple stream, 256 MB, 300 s). Builds the pipeline without
    /// starting it: no microphone is touched.
    @MainActor public static func liveSourceMatchesBackendDefaults() -> Bool {
        guard let pipeline = SharedCaptureHub.liveSource() as? LiveAudioPipeline else { return false }
        return pipeline.input == nil
            && pipeline.captured.byteLimit == 256 * 1024 * 1024
            && pipeline.captured.durationSeconds == 300
    }

    /// The frame count and sample rate the scripted capture's buffers really carry on this platform.
    @MainActor public static func silentBufferShape(frames: Int, sampleRate: Double) -> (frames: Int, sampleRate: Double)? {
        guard let owned = HybridTestingPCM.silence(frames: frames, sampleRate: sampleRate) else { return nil }
        return (Int(owned.buffer.frameLength), owned.buffer.format.sampleRate)
    }
}
