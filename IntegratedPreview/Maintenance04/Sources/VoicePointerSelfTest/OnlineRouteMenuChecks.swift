import Foundation
import VoicePointerCore

/// T2: synthetic settings and finite outcomes only. No key, network, microphone or installed app.
@MainActor
enum OnlineRouteMenuChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) {
            if !value { failures.append("online menu: " + label) }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let confirmed = CloudEntryStatus.confirmed(validUntil: now.addingTimeInterval(3_600))
        let enabled = CloudEntryPreferences(visible: true, routeEnabled: true, uploadConsent: true)
        let config = OnlineAPIConfiguration(provider: .aliyunBailian, modelID: OnlineAPIProvider.aliyunBailian.modelIDs[0], credentialRevision: "fixture")
        for health in [EngineHealthState.idle, .checking, .passed(detail: .providerVerified)]
            + HealthFailureReason.allCases.map({ EngineHealthResult.failed($0).state }) {
            let menu = OnlineRouteMenuState(configuration: config, statusKind: .passed, mayUse: true, selection: nil, health: health)
            expect(menu.statusKind == OnlineRouteMenuState.healthStatus(health), "menu uses the card's shared health state")
            if case .failed = health {
                expect(menu.statusSuffix == (health.statusTitle.isEmpty ? "" : " · " + health.statusTitle) && menu.action == .openSettings, "failed health cannot switch route and shows its reason")
            }
            let blocked = OnlineRouteMenuState(configuration: config, statusKind: .expired, mayUse: false, selection: nil, health: health)
            expect(blocked.action == .openSettings, "health success cannot override missing authorization")
        }
        do {
            let local = try VoiceInputSelection(mode: .voiceNative, routeID: "qwen17-rolling", language: "zh")
            let online = try VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.routeID, language: "zh")
            let doubao = try VoiceInputSelection(mode: .doubao, routeID: "qwen06-rolling", language: "zh")
            func state(
                loaded: Bool = true, key: Bool = true, busy: Bool = false,
                preferences: CloudEntryPreferences = enabled, status: CloudEntryStatus = confirmed,
                check: OnlineConnectionCheckState = .idle, selection: VoiceInputSelection? = local,
                label: String? = "Fixture Provider"
            ) -> OnlineRouteMenuState {
                OnlineRouteMenuState(
                    loaded: loaded, keySaved: key, credentialChanging: busy, preferences: preferences,
                    status: status, check: check, selection: selection, label: label
                )
            }
            for saved in [false, true] {
                for chosen in [false, true] {
                    let menu = state(key: saved, selection: chosen ? online : local)
                    expect(menu.selected == chosen, "configured/selected matrix checkmark")
                    expect(menu.title == (saved
                        ? "在线 API 识别（Fixture Provider）"
                        : "在线 API 识别 · 未配置"), "configured/selected matrix title")
                    if saved { expect(!menu.title.contains("需要配置"), "saved entry never needs configuration") }
                }
            }
            expect(state(label: nil).baseTitle == "在线 API 识别", "no label remains generic")
            expect(state(label: "  ").baseTitle == "在线 API 识别", "blank label remains generic")
            expect(state(check: .passed(now)).title.hasSuffix(" · 可用"), "only connection evidence says passed")
            expect(!state(status: confirmed).title.contains(" · 可用"), "confirmation is not a connection check")
            expect(state(loaded: false, key: false).statusSuffix.isEmpty, "unknown is not missing")
            expect(state(check: .running).statusSuffix.isEmpty, "running shared state")
            expect(state(check: .failed(.network)).title.hasSuffix("连不上服务商"), "bounded failure phrase")
            for (status, suffix) in [
                (CloudEntryStatus.unavailable, "状态不可用"), (.paused(.freeQuotaExhausted), "免费额度已用完"),
                (.paused(.accountBalanceBlocked), "账户欠费或余额不足")
            ] {
                let menu = state(status: status, check: .passed(now))
                expect(menu.title.hasSuffix(suffix) && !menu.title.contains(" · 可用"),
                       "current authorization restriction overrides an earlier connection success")
                expect(menu.action == .openSettings, "earlier connection success cannot bypass gate restriction")
            }
            expect(state(selection: doubao).selected == false, "doubao does not acquire online checkmark")
            for status in [CloudEntryStatus.unconfirmed, .expired] {
                let optionalQuota = state(status: status, check: .passed(now))
                expect(optionalQuota.statusKind == .passed && optionalQuota.action == .switchRoute,
                       "quota checkbox and age never block the online menu")
            }

            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
                .appendingPathComponent("OnlineRouteMenuChecks-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try ProviderSettingsStore(fileURL: root.appendingPathComponent("preferences.json"))
            var initial = try ProviderPreferences(selection: local)
            initial.cloudConsent = ["groq"]
            try store.update(initial)
            let originalBytes = try Data(contentsOf: store.fileURL)
            var events: [String] = []
            var switches = enabled
            // Remove exactly one prerequisite each time, leaving every other input granted.
            var noVisible = enabled; noVisible.visible = false
            var noRoute = enabled; noRoute.routeEnabled = false
            var noUpload = enabled; noUpload.uploadConsent = false
            let unsupported = try VoiceInputSelection(mode: .voiceNative, routeID: "qwen17-rolling", language: "ja")
            let refused = [
                state(loaded: false), state(key: false), state(busy: true), state(preferences: noVisible),
                state(preferences: noRoute), state(preferences: noUpload), state(status: .unavailable),
                state(status: .paused(.freeQuotaExhausted)),
                state(status: .paused(.accountBalanceBlocked)), state(selection: unsupported), state(selection: nil)
            ] + CloudConnectionCheck.Failure.allCases.map { state(check: .failed($0)) }
            for menu in refused {
                expect(menu.action == .openSettings, "each missing permission or failed check opens settings")
                let selected = try menu.select(store: store, onPreferencesChanged: { _ in events.append("changed") },
                                               notify: { events.append("notify") })
                expect(!selected && store.value == initial, "refusal never switches local selection")
                expect(events.isEmpty && switches == enabled, "refusal never creates callbacks or permissions")
                expect(try Data(contentsOf: store.fileURL) == originalBytes, "refusal never persists")
            }
            // The production callback reconciles only after a successful menu save.
            var callbackFinished = false
            let selected = try state(check: .passed(now)).select(
                store: store,
                onPreferencesChanged: { preferences in
                    expect(store.value == preferences, "callback sees persisted selection")
                    expect((try? ProviderSettingsStore(fileURL: store.fileURL).value) == preferences,
                           "callback sees durable persisted selection")
                    switches = switches.reconciled(CloudEntryReconcileContext(
                        selection: preferences.selection, credentialAvailable: true, entryVisible: true
                    ))
                    events.append("changed")
                    callbackFinished = true
                },
                notify: {
                    expect(callbackFinished && switches == enabled, "notification sees completed reconciliation")
                    expect((try? ProviderSettingsStore(fileURL: store.fileURL).value.selection) == online,
                           "notification sees durable online selection")
                    events.append("notify")
                }
            )
            let reread = try ProviderSettingsStore(fileURL: store.fileURL)
            expect(selected && reread.value.selection == online, "click persists online route")
            expect(reread.value.cloudConsent == initial.cloudConsent, "existing provider consent is preserved")
            expect(events == ["changed", "notify"], "exactly one callback precedes exactly one notification")
            expect(switches == enabled, "successful menu click opens no switch")

            // Settings uses this same commit boundary without OnlineRouteMenu.select.
            events = []; callbackFinished = false
            try ProviderPreferencesCommit.persistAndNotify(initial, store: store, onPreferencesChanged: { preferences in
                expect(events.isEmpty && preferences == initial && store.value == initial,
                       "settings callback sees saved value before notification")
                expect((try? ProviderSettingsStore(fileURL: store.fileURL).value) == initial,
                       "settings callback sees durable saved value")
                events.append("changed"); callbackFinished = true
            }, notify: {
                expect(callbackFinished && events == ["changed"], "settings notification follows callback completion")
                events.append("notify")
            })
            expect(events == ["changed", "notify"], "settings emits each callback exactly once")

            // Make a once-valid destination unwritable by replacing its absent path with a directory.
            let broken = try ProviderSettingsStore(fileURL: root.appendingPathComponent("unwritable.json"))
            let beforeFailure = broken.value
            try FileManager.default.createDirectory(at: broken.fileURL, withIntermediateDirectories: false)
            events = []
            let beforeSwitches = switches
            do {
                _ = try state().select(store: broken, onPreferencesChanged: { _ in events.append("changed") },
                                       notify: { events.append("notify") })
                expect(false, "write failure must throw")
            } catch {
                expect(broken.value == beforeFailure, "write failure preserves selection")
                expect(events.isEmpty && switches == beforeSwitches, "write failure preserves switches and emits nothing")
            }
        } catch {
            failures.append("online menu: synthetic fixture setup failed")
        }
        // These three events share one invalidation path in CloudEntryRuntime.
        for _ in ["key changed", "key removed", "entry hidden"] {
            var check = OnlineConnectionCheckLedger()
            let old = check.begin()
            check.invalidate()
            check.complete(.connected, generation: old, now: now)
            expect(check.state == .idle, "late passed result cannot survive invalidation")
            let current = check.begin()
            check.complete(.failed(.network), generation: current, now: now)
            expect(check.state == .failed(.network), "current finite failure is shared")
            let newer = check.begin()
            check.complete(.connected, generation: current, now: now)
            expect(check.state == .running, "earlier test cannot overwrite newer test")
            check.complete(.connected, generation: newer, now: now)
            expect(check.state == .passed(now), "current finite success is shared")
        }
        return failures
    }
}
