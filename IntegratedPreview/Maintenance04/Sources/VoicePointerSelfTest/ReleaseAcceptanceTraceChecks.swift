import Foundation
import VoicePointerCore

enum ReleaseAcceptanceTraceChecks {
    static func run() -> [String] {
        var failures: [String] = []
        var cases = 0
        func check(_ value: Bool, _ name: String) {
            cases += 1
            if !value { failures.append("release acceptance trace: " + name) }
        }
        check(ReleaseAcceptanceTrace.isAllowed(ReleaseAcceptanceTrace.applicationReady), "startup fixed event")
        check(ReleaseAcceptanceTrace.settingsShown(visible: false, windowNumber: 1) == nil, "hidden window excluded")
        check(ReleaseAcceptanceTrace.settingsShown(visible: true, windowNumber: 0) == nil, "invalid window excluded")
        check(ReleaseAcceptanceTrace.settingsShown(visible: true, windowNumber: 42).map(ReleaseAcceptanceTrace.isAllowed) == true,
              "visible numeric window")
        let statuses: [OnlineRouteMenuState.StatusKind] = [.reading, .needsConfiguration, .updating, .unverified,
            .checking, .passed, .unavailable, .needsConfirmation, .expired, .quotaExhausted, .balanceBlocked,
            .network, .timeout, .invalidKey, .failed]
        for status in statuses {
            let event = ReleaseAcceptanceTrace.menu(selection: nil, doubao: .checking,
                qwen17: .passed(detail: .localContainerLoadable), prepare17: false,
                qwen06: nil, prepare06: true, online: status)
            check(ReleaseAcceptanceTrace.isAllowed(event) && event.components(separatedBy: ",").count == 6,
                  "all menu fields and online enum")
        }
        for reason in HealthFailureReason.allCases {
            let failed = EngineHealthState.failed(reason: reason, nextAction: reason.nextAction)
            let event = ReleaseAcceptanceTrace.menu(selection: nil, doubao: failed,
                qwen17: failed, prepare17: false, qwen06: failed, prepare06: false, online: .failed)
            check(ReleaseAcceptanceTrace.healthCode(failed) == reason.rawValue && ReleaseAcceptanceTrace.isAllowed(event),
                  "all health failure enums")
        }
        for route in ["qwen17-rolling", "qwen06-rolling", "apple-speech", CloudEntry.routeID, "synthetic-secret-route"] {
            let selection = try? VoiceInputSelection(mode: .voiceNative, routeID: route, language: "synthetic-secret-language")
            let event = ReleaseAcceptanceTrace.menu(selection: selection, doubao: .idle,
                qwen17: .idle, prepare17: false, qwen06: .idle, prepare06: false, online: .unverified)
            check(ReleaseAcceptanceTrace.isAllowed(event) && !event.contains("synthetic-secret"), "route projection drops free input")
        }
        let doubao = try? VoiceInputSelection(mode: .doubao)
        check(ReleaseAcceptanceTrace.routeCode(doubao) == "doubao", "external route enum")
        for unsafe in [ReleaseAcceptanceTrace.applicationReady + ",key=synthetic",
                       ReleaseAcceptanceTrace.applicationReady + "\n", "event=settings_window,state=shown,window=-1",
                       "event=settings_window,state=shown,window=1,path=/synthetic",
                       "event=menu_projection,route=synthetic,doubao=idle,qwen17=idle,qwen06=idle,online=passed",
                       "event=menu_projection,route=online,doubao=idle,qwen17=idle,qwen06=idle,online=passed,text=synthetic"] {
            check(!ReleaseAcceptanceTrace.isAllowed(unsafe), "reject extra/free/private fields")
        }
        if failures.isEmpty { print("RELEASE_ACCEPTANCE_TRACE_PASS cases=\(cases) private_fields=0") }
        return failures
    }
}
