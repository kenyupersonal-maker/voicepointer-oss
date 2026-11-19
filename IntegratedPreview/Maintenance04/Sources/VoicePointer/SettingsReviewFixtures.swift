// T5 2026-10-02: Safe, static native-window fixtures; no live credentials, audio, provider calls or user stores.
// T6 2026-10-02: Lexicon fixtures add in-memory terms and corrections only for the isolated review host.
import Foundation
import VoicePointerCore

struct SettingsReviewLexiconFixture {
    let termCount: Int
    let pendingCount: Int

    static let empty = Self(termCount: 0, pendingCount: 0)
    static let withPending = Self(termCount: 3, pendingCount: 2)
}

@MainActor final class SettingsReviewContext {
    let page: SettingsPage
    let method: RecognitionMethod
    let logic: SettingsLogicRuntime
    let cloudPage: CloudEntryPageState
    let lexiconFixture: SettingsReviewLexiconFixture?
    let magicMouseState: MagicMouseSettingsState
    let magicMouseExpanded: Bool
    @MainActor private final class Preference { var enabled: Bool; init(_ value: Bool) { enabled = value } }
    @MainActor private final class Provider: EngineHealthProviding {
        func check(_ method: RecognitionMethod) async -> EngineHealthResult { .failed(.unavailable) }
    }
    @MainActor private final class Ledger: SettingsConnectionLedgerBridge {
        var state = OnlineConnectionCheckLedger()
        var settingsConnectionState: OnlineConnectionCheckState { state.state }
        func beginConnectionCheck() -> UUID { state.begin() }
        func completeSettingsCheck(_ outcome: CloudConnectionCheck.Outcome, generation: UUID) { state.complete(outcome, generation: generation) }
        func invalidateSettingsCheck() { state.invalidate() }
    }
    init(page: SettingsPage = .voice, method: RecognitionMethod = .local, phase: SettingsLoadState = .content,
         health: EngineHealthState? = nil, configured: Bool = true, enhancement: Bool = false,
         label: String? = nil, memoryGB: UInt64 = 16, lexiconFixture: SettingsReviewLexiconFixture? = nil,
         modelInstallationFixture: Bool = false, magicMouse: Bool = false, magicMouseExpanded: Bool = false,
         magicMouseEmpty: Bool = false) {
        self.page = page; self.method = method
        self.magicMouseExpanded = magicMouseExpanded
        var mouse = MagicMouseReviewFixture(present: magicMouse, expanded: magicMouseExpanded)
        if magicMouse {
            let points = [TouchSamplePoint(stage: 4, x: 0.32, y: 0.66, major: 0.24, minor: 0.24, size: 0.05, density: 1.28),
                          TouchSamplePoint(stage: 4, x: 0.68, y: 0.54, major: 0.20, minor: 0.20, size: 0.04, density: 0.62)]
            mouse.snapshot = .init(deviceToken: 1, points: points, frameAgeSeconds: 0.01,
                newestTouchAgeSeconds: 0.01, oldestTouchAgeSeconds: 0.04, maximumMovement: 0.01)
            mouse.decision = .init(reason: .density, minDensity: 0.62)
            if !magicMouseEmpty {
                mouse.samples = [Float(0.6), 0.68, 0.92, 1.08, 1.32, 1.18, 1.25, 1.3, 1.45, 1.55].enumerated().map { i, density in
                    let json: [String: Any] = ["t": 1000 + i, "b": "L", "dec": TouchSampleDecision.passed.rawValue,
                        "n": 2, "hover": 0, "points": (0..<2).map { _ in ["stage": 4, "x": 0.4, "y": 0.6,
                            "major": 0.2, "minor": 0.15, "size": 0.04, "density": Double(density)] },
                        "holdMS": 125, "threshold": 1, "skewLimitMS": 80, "freshLimitMS": 350, "movementLimit": 0.08,
                        "frameAgeMS": 10, "newestAgeMS": 10, "oldestAgeMS": 40, "movement": 0.01,
                        "label": i < 5 ? "single" : "real"]
                    return try! JSONDecoder().decode(TouchSample.self, from: JSONSerialization.data(withJSONObject: json))
                }
            }
        }
        magicMouseState = MagicMouseSettingsState(fixture: mouse)
        self.lexiconFixture = lexiconFixture
        let preference = Preference(enhancement)
        let source = OnlineEnhancementPreferenceSource(read: { preference.enabled }, write: { preference.enabled = $0 })
        logic = SettingsLogicRuntime(provider: Provider(), enhancement: source, ledger: Ledger(),
            hardware: .init(memoryBytes: memoryGB << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true),
            readLabel: { label }, writeLabel: { _ in }, credentialEpoch: { UUID() }, log: { _ in })
        cloudPage = CloudEntryPageState(isVisible: true, key: configured ? .saved : .missing, isLoaded: true)
        let selection = try! VoiceInputSelection(mode: method == .doubao ? .doubao : .voiceNative,
            routeID: method == .online ? CloudEntry.routeID : LocalModelID.qwen06.rawValue, language: "zh")
        logic.update(page: cloudPage, selection: selection, label: label)
        logic.options.select(method)
        let state: EngineHealthState = health ?? (phase == .loading ? .checking : phase == .error
            ? .failed(reason: method == .doubao ? .doubaoNotEnabled : method == .local ? .modelCorrupt : .network,
                      nextAction: method == .doubao ? .enableSystemInput : method == .local ? .redownloadModel : .retryNetwork)
            : phase == .content ? .passed(detail: method == .doubao ? .publicInputSource : method == .local ? .localContainerLoadable : .providerVerified) : .idle)
        logic.health.applyFixture(phase: phase, method: method, state: state)
        logic.options.applyFixture(phase: phase)
        logic.online.applyFixture(phase: phase)
        logic.doubao.update(.init(installed: phase != .empty, enabledInSystem: phase == .content))
        logic.doubao.applyFixture(phase: phase)
        logic.local.update(models: LocalModelID.allCases.map { id in
            .init(id: id, sizeBytes: modelInstallationFixture ? (id == .qwen17 ? 2_500_516_700 : 1_876_091_704)
                    : phase == .empty ? 0 : id == .qwen17 ? 1_900_000_000 : 1_200_000_000,
                  recommended: memoryGB >= 16 ? id == .qwen17 : id == .qwen06,
                  state: !logic.local.hardware.supports(id) ? .notApplicable(reason: .hardwareUnsuitable)
                    : modelInstallationFixture ? (id == .qwen17 ? .converting : .downloading(progress: 0.4))
                    : phase == .empty ? .notDownloaded : phase == .loading ? .downloading(progress: 0.4)
                    : phase == .error ? .corrupt : .ready,
                  downloadBytes: modelInstallationFixture ? (id == .qwen17 ? 4_703_112_789 : 1_880_560_561) : nil,
                  conversionOutputBytes: modelInstallationFixture && id == .qwen17 ? 2_500_516_700 : nil,
                  requiredSpaceBytes: modelInstallationFixture ? (id == .qwen17 ? 8_277_371_313 : 2_417_431_473) : nil)
        })
        logic.local.applyFixture(phase: phase)
        logic.permissions.update([.accessibility: .granted, .inputMonitoring: .granted, .microphone: .granted])
        logic.permissions.applyFixture(phase: phase)
        logic.data.update(phase == .empty ? [] : [.init(id: .model17, sizeBytes: 2_500_516_700),
            .init(id: .model06, sizeBytes: 1_879_340_000), .init(id: .punctuation, sizeBytes: 227_000_000),
            .init(id: .modelDownloads, sizeBytes: 340_000_000), .init(id: .touchSamples, sizeBytes: 2400)], totalBytes: phase == .empty ? 0 : 4_950_002_400)
        logic.data.applyFixture(phase: phase)
        logic.menu.applyFixture(phase: phase)
    }
}
