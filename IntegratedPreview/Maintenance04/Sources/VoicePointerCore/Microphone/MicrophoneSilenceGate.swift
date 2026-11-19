import Foundation

/// T1: startup silence is held before any PCM reaches a recognizer. Once real
/// audio arrives, pauses remain in the stream. Startup failures may select one fallback device.
public struct MicrophoneSilenceGate: Sendable {
    public struct Configuration: Sendable {
        public let peakThreshold: Float
        public let minimumCallbacks: Int
        public let silenceMilliseconds: UInt64
        public let noCallbackMilliseconds: UInt64
        public let stalledMilliseconds: UInt64

        public init(peakThreshold: Float = 0.00001, minimumCallbacks: Int = 3,
                    silenceMilliseconds: UInt64 = 500, noCallbackMilliseconds: UInt64 = 800,
                    stalledMilliseconds: UInt64 = 500) {
            self.peakThreshold = peakThreshold.isFinite ? max(0, peakThreshold) : 0.00001
            self.minimumCallbacks = max(1, minimumCallbacks)
            self.silenceMilliseconds = min(max(1, silenceMilliseconds), 60_000)
            self.noCallbackMilliseconds = min(max(1, noCallbackMilliseconds), 60_000)
            self.stalledMilliseconds = min(max(1, stalledMilliseconds), 60_000)
        }
    }

    public enum Decision: String, Sendable {
        case waiting, audible, allZero, noCallbacks, stalled
        public var blocksRecognition: Bool { self != .audible }
        public var failureCode: String? {
            switch self {
            case .allZero: return MicrophoneSilenceGate.noSoundCode
            case .noCallbacks, .stalled: return MicrophoneSilenceGate.noCallbacksCode
            case .waiting, .audible: return nil
            }
        }
    }

    public static let noSoundCode = "MICROPHONE_NO_SOUND"
    public static let noCallbacksCode = "MICROPHONE_NO_CALLBACKS"
    public static let message = "麦克风没有声音（耳机可能静音了，或连在手机上）"
    // Built-in input in the 10/3 trace starts in 146–159 ms. Bound startup failure,
    // not pauses after speech. No inference about a headset's hardware mute state.
    public static let stalledMilliseconds: UInt64 = 500
    public static let shortTapMilliseconds: UInt64 = 400

    public static func isSilenceCode(_ code: String) -> Bool {
        code == noSoundCode || code == noCallbacksCode
    }

    private let configuration: Configuration
    private let startedAt: UInt64
    public private(set) var callbacks = 0
    public private(set) var maximumPeak: Float = 0
    public private(set) var hasAudio = false
    private var lastCallbackAt: UInt64?

    public init(now: UInt64 = DispatchTime.now().uptimeNanoseconds, configuration: Configuration = .init()) {
        startedAt = now
        self.configuration = configuration
    }

    @discardableResult
    public mutating func observe(peak: Float, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Decision {
        callbacks += 1
        lastCallbackAt = now
        if peak.isFinite {
            maximumPeak = max(maximumPeak, max(0, peak))
            if peak > configuration.peakThreshold { hasAudio = true }
        }
        return decision(now: now)
    }

    public func decision(now: UInt64 = DispatchTime.now().uptimeNanoseconds, final: Bool = false) -> Decision {
        if hasAudio { return .audible }
        let elapsedMs = now >= startedAt ? (now - startedAt) / 1_000_000 : 0
        if callbacks == 0 && (final || elapsedMs >= configuration.noCallbackMilliseconds) { return .noCallbacks }
        // Final means the complete capture had no audible sample, even for a
        // short tap: never ask an ASR to hallucinate from an empty/zero input.
        if callbacks > 0 && final { return .allZero }
        if let lastCallbackAt, now >= lastCallbackAt,
           (now - lastCallbackAt) / 1_000_000 >= configuration.stalledMilliseconds { return .stalled }
        if callbacks >= configuration.minimumCallbacks,
           elapsedMs >= configuration.silenceMilliseconds,
           maximumPeak <= configuration.peakThreshold { return .allZero }
        return .waiting
    }
}
