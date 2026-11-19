import Foundation

/// Production-only observation seam. The payload never carries recognized text or provider configuration.
@MainActor public enum DictationHealthObservation {
    public static var receive: ((VoiceInputSelection, HealthFailureReason?) -> Void)?
    public static func success(_ selection: VoiceInputSelection) { receive?(selection, nil) }
    public static func failure(_ selection: VoiceInputSelection, code: String?) {
        guard let code else { return }
        let reason: HealthFailureReason?
        if code.hasSuffix("AUTH_FAILED") || code.hasSuffix("HTTP_401") { reason = .invalidKey }
        else if code.hasSuffix("ACCESS_DENIED") || code.hasSuffix("HTTP_403") { reason = .noAccess }
        else if code.hasSuffix("FREE_QUOTA_EXHAUSTED") || code.hasSuffix("INSUFFICIENT_QUOTA") { reason = .freeQuotaExhausted }
        else if code.hasSuffix("BALANCE_DUE") { reason = .balanceDue }
        else if code.contains("MODEL_MISSING") || code.contains("MODEL_NOT_FOUND") || code == "LOCAL_MODEL_FILES_MISSING" { reason = .modelNotDownloaded }
        else if code.contains("MODEL_CORRUPT") { reason = .modelCorrupt }
        else if code.hasSuffix("TIMEOUT") { reason = .timeout }
        else if code.hasSuffix("NETWORK_FAILED") || code.hasSuffix("REQUEST_FAILED") { reason = .network }
        else { reason = nil } // Delivery/gesture/microphone failures are not an engine health result.
        if let reason { receive?(selection, reason) }
    }
}
