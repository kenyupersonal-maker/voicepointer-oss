import Foundation
@_spi(Testing) import VoicePointerCore

enum VoiceRoutePreparationChecks {
    static func run() -> [String] {
        var failures = [String]()
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        expect(!VoiceNativeModelPreparation.canStartPreparation(routeID: "unknown-route", language: "zh"),
               "unknown route must not expose a preparation action")
        expect(!VoiceNativeModelPreparation.canStartPreparation(routeID: "doubao", language: "zh"),
               "Doubao must use its external setup path, not local-model preparation")
        expect(!VoiceNativeModelPreparation.canStartPreparation(routeID: "aliyun", language: "zh"),
               "cloud route must remain unavailable to first-run preparation")
        expect(!VoiceNativeModelPreparation.canStartPreparation(routeID: "groq-v3", language: "zh"),
               "Groq route must remain unavailable to first-run preparation")

        if let current = try? VoiceInputSelection(mode: .voiceNative, routeID: "qwen17-rolling", language: "zh") {
            expect(VoiceInputSelectionTransition.selectingDoubao(from: current, isInstalled: false) == nil,
                   "missing Doubao installation must not replace the current route")
            expect(VoiceInputSelectionTransition.selectingDoubao(from: current, isInstalled: true)?.mode == .doubao,
                   "installed Doubao may be selected while activation still requires manual confirmation")
        } else {
            expect(false, "local route fixture must be constructible")
        }
        expect(!VoiceNativeModelPreparation.canStartPreparation(routeID: "apple-speech", language: "auto"),
               "Apple preparation must reject automatic language selection")
        expect(VoiceNativeModelPreparation.isAppleLanguageSupported("zh")
               && VoiceNativeModelPreparation.isAppleLanguageSupported("en")
               && VoiceNativeModelPreparation.isAppleLanguageSupported("yue")
               && !VoiceNativeModelPreparation.isAppleLanguageSupported("auto"),
               "Apple route language choices must remain single-language only")

        if #unavailable(macOS 26.0) {
            expect(!VoiceNativeModelPreparation.canStartPreparation(routeID: "apple-speech", language: "zh"),
                   "Apple preparation must remain unavailable before macOS 26")
        }

        for routeID in ["qwen17-rolling", "qwen06-rolling"] {
            let prepared = VoiceNativeModelPreparation.isLocalPrepared(routeID: routeID, language: "zh")
            expect(
                VoiceNativeModelPreparation.canStartPreparation(routeID: routeID, language: "zh") == prepared,
                "\(routeID) preparation action must match the external-resource gate"
            )
        }
        return failures
    }
}
