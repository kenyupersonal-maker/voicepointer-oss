import Foundation

public enum SilentSendPolicy {
    // 10/3: all 19 silent sends were <=0.0058; quiet speech had a partial.
    public static let maximumPeak: Float = 0.008
    public static func qualifies(partials: Int, peak: Float?) -> Bool {
        guard partials == 0 else { return false }
        guard let peak else { return true }
        return peak.isFinite && peak >= 0 && peak < maximumPeak
    }
    public static func externalSettleMilliseconds(action: VoiceReleaseAction, heard: SpeechHeard) -> Int {
        action == .send ? (heard == .silence ? 250 : 1000) : (heard == .silence ? 250 : 800)
    }
}
