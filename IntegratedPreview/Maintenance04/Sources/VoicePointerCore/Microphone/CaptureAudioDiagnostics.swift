@preconcurrency import AVFoundation
import Foundation

enum CaptureDiagnosticLog {
    static func start(deviceFields: String, format: AVAudioFormat) -> String {
        "capture_diagnostic path=recognition phase=start \(deviceFields) " +
            "sampleRate=\(Int(format.sampleRate)) channels=\(format.channelCount) commonFormat=\(format.commonFormat.rawValue)"
    }

    static func end(deviceFields: String, diagnostics: CaptureAudioDiagnostics) -> String {
        "capture_diagnostic path=recognition phase=end \(deviceFields) \(diagnostics.fields())"
    }

    static func reopen(attempt: Int) -> String { "capture_route phase=reopen attempt=\(attempt)" }
}

/// T1: per-capture numeric telemetry. The tap never logs, stores a device name,
/// or retains audio here. A single summary is formatted when capture closes.
final class CaptureAudioDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: UInt64 = 0
    private var callbacks = 0
    private var nonzero = 0
    private var unsupported = 0
    private var minimumFrames = Int.max
    private var maximumFrames = 0
    private var maximumPeak: Float = 0
    private var firstNonzeroAt: UInt64?
    private var sampleRate = 0
    private var channels = 0
    private var commonFormat = 0

    func begin(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            startedAt = now
            callbacks = 0; nonzero = 0; unsupported = 0
            minimumFrames = Int.max; maximumFrames = 0; maximumPeak = 0
            firstNonzeroAt = nil; sampleRate = 0; channels = 0; commonFormat = 0
        }
    }

    func record(_ source: AVAudioPCMBuffer, measurement: PCMBufferLevel.Measurement,
                now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            callbacks += 1
            let frames = Int(source.frameLength)
            minimumFrames = min(minimumFrames, frames)
            maximumFrames = max(maximumFrames, frames)
            sampleRate = source.format.sampleRate.isFinite && source.format.sampleRate <= 768_000
                ? max(0, Int(source.format.sampleRate)) : 0
            channels = Int(source.format.channelCount)
            commonFormat = Int(source.format.commonFormat.rawValue)
            if !measurement.supported { unsupported += 1 }
            if measurement.peak > 0 {
                nonzero += 1
                if firstNonzeroAt == nil { firstNonzeroAt = now }
            }
            maximumPeak = max(maximumPeak, measurement.peak)
        }
    }

    func fields() -> String {
        lock.withLock {
            let firstMs = firstNonzeroAt.map { $0 >= startedAt ? Int(($0 - startedAt) / 1_000_000) : -1 } ?? -1
            let state = callbacks == 0 ? "no_callbacks" : (nonzero == 0 ? "all_zero" : "nonzero")
            return "sampleRate=\(sampleRate) channels=\(channels) commonFormat=\(commonFormat) " +
                "callbacks=\(callbacks) nonzero=\(nonzero) unsupported=\(unsupported) " +
                "framesMin=\(callbacks == 0 ? 0 : minimumFrames) framesMax=\(maximumFrames) " +
                "rawPeak=\(String(format: "%.7f", Double(maximumPeak))) firstNonzeroMs=\(firstMs) state=\(state)"
        }
    }
    func counts() -> (callbacks: Int, nonzero: Int) { lock.withLock { (callbacks, nonzero) } }
}
