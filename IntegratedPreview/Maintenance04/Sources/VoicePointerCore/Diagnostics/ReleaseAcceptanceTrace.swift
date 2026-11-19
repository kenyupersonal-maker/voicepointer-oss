import Foundation

/// Public enum projection only. Never accepts a title, provider label, path,
/// key, transcript or preferences payload as a log field.
public enum ReleaseAcceptanceTrace {
    public static let applicationReady = "event=application_launch,state=ready"

    public static func settingsShown(visible: Bool, windowNumber: Int) -> String? {
        guard visible && windowNumber > 0 else { return nil }
        return "event=settings_window,state=shown,window=\(windowNumber)"
    }

    public static func routeCode(_ selection: VoiceInputSelection?) -> String {
        guard let selection else { return "unavailable" }
        if selection.mode == .doubao { return "doubao" }
        switch selection.routeID {
        case "qwen17-rolling": return "qwen17"
        case "qwen06-rolling": return "qwen06"
        case "apple-speech": return "apple"
        case CloudEntry.routeID: return "online"
        default: return "other"
        }
    }

    public static func healthCode(_ health: EngineHealthState?, needsPreparation: Bool = false) -> String {
        switch health {
        case .none, .idle?: return needsPreparation ? "needsPreparation" : "idle"
        case .checking?: return "checking"
        case .passed?: return "passed"
        case .failed(let reason, _)?: return reason.rawValue
        }
    }

    public static func menu(selection: VoiceInputSelection?, doubao: EngineHealthState?,
                            qwen17: EngineHealthState?, prepare17: Bool,
                            qwen06: EngineHealthState?, prepare06: Bool,
                            online: OnlineRouteMenuState.StatusKind) -> String {
        "event=menu_projection,route=\(routeCode(selection)),doubao=\(healthCode(doubao))," +
        "qwen17=\(healthCode(qwen17, needsPreparation: prepare17))," +
        "qwen06=\(healthCode(qwen06, needsPreparation: prepare06)),online=\(onlineCode(online))"
    }

    public static func onlineCode(_ kind: OnlineRouteMenuState.StatusKind) -> String {
        switch kind {
        case .reading: "reading"
        case .needsConfiguration: "needsConfiguration"
        case .updating: "updating"
        case .unverified: "unverified"
        case .checking: "checking"
        case .passed: "passed"
        case .unavailable: "unavailable"
        case .needsConfirmation: "needsConfirmation"
        case .expired: "expired"
        case .quotaExhausted: "quotaExhausted"
        case .balanceBlocked: "balanceBlocked"
        case .network: "network"
        case .timeout: "timeout"
        case .invalidKey: "invalidKey"
        case .failed: "failed"
        }
    }

    public static func isAllowed(_ line: String) -> Bool {
        guard !line.contains("\n") && !line.contains("\r") else { return false }
        if line == applicationReady { return true }
        if line.range(of: "^event=settings_window,state=shown,window=[1-9][0-9]*$", options: .regularExpression) != nil { return true }
        let health = (["idle", "needsPreparation", "checking", "passed"] + HealthFailureReason.allCases.map(\.rawValue)).joined(separator: "|")
        let online = "reading|needsConfiguration|updating|unverified|checking|passed|unavailable|needsConfirmation|expired|quotaExhausted|balanceBlocked|network|timeout|invalidKey|failed"
        let pattern = "^event=menu_projection,route=(unavailable|doubao|qwen17|qwen06|apple|online|other),doubao=(\(health)),qwen17=(\(health)),qwen06=(\(health)),online=(\(online))$"
        return line.range(of: pattern, options: .regularExpression) != nil
    }
}
