// T4 2026-10-02: Offline data-flow tests; synthetic metadata/model containers only, no Key/audio/network.
import Foundation
import CryptoKit
import VoicePointerCore

@MainActor enum SettingsViewModelChecks {
    private final class Clock: SettingsHealthClock {
        var now: TimeInterval = 0
        private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
        func sleep(seconds: TimeInterval) async throws {
            let id = UUID()
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    sleepers[id] = (now + seconds, continuation)
                }
            }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } })
        }
        private func cancel(_ id: UUID) { sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        func advance(_ seconds: TimeInterval) {
            now += seconds
            let due = sleepers.filter { $0.value.0 <= now }.map(\.key)
            for id in due { sleepers.removeValue(forKey: id)?.1.resume() }
        }
    }
    private final class Provider: EngineHealthProviding {
        struct Request { let method: RecognitionMethod; let continuation: CheckedContinuation<EngineHealthResult, Never> }
        var requests: [Request] = []
        var calls = 0
        var immediate: EngineHealthResult?
        func check(_ method: RecognitionMethod) async -> EngineHealthResult {
            calls += 1
            if let immediate { return immediate }
            return await withCheckedContinuation { requests.append(.init(method: method, continuation: $0)) }
        }
        func deliverAll(_ result: EngineHealthResult) {
            let pending = requests; requests = []; for request in pending { request.continuation.resume(returning: result) }
        }
    }
    private struct MetadataProvider: OnlineAPIHealthAdapter {
        let displayName: String = "Fixture Provider"
        let keyHelpURL = URL(string: "https://example.org/key")!
        let docURL = URL(string: "https://example.org/docs")!
        let capabilities: OnlineAPICapabilities
        func validate(credential: OnlineCredentialState) async -> OnlineAPIValidation { .verified }
    }
    private final class CountingAdapter: OnlineAPIHealthAdapter {
        let displayName = "Fixture Provider"
        let keyHelpURL = URL(string: "https://example.org/key")!
        let docURL = URL(string: "https://example.org/docs")!
        let capabilities = OnlineAPICapabilities(supportsLightweightValidation: true)
        var calls = 0
        var outcome: OnlineAPIValidation = .verified
        func validate(credential: OnlineCredentialState) async -> OnlineAPIValidation { calls += 1; return outcome }
    }
    private final class ModelManager: LocalModelManaging {
        var pending: CheckedContinuation<Void, Never>?
        var actions: [LocalModelAction] = []
        func download(_ id: LocalModelID, progress: @escaping @MainActor (Double) -> Void) async throws {
            actions.append(.download); progress(0.5)
            await withCheckedContinuation { pending = $0 }
        }
        func cancel(_ id: LocalModelID) { actions.append(.cancel) }
        func moveToTrash(_ id: LocalModelID) async throws { actions.append(.delete) }
        func use(_ id: LocalModelID) async throws { actions.append(.use) }
        func finish() { let continuation = pending; pending = nil; continuation?.resume() }
    }
    private static func flush() async { for _ in 0..<30 { await Task.yield() } }

    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("T4 settings: " + label) } }
        var allLogs: [String] = []
        // Same production VM, with provider and monotonic clock injected. No real waiting/network.
        for method in RecognitionMethod.allCases {
            for result in [EngineHealthResult.passed(.providerVerified), .failed(.network), .failed(.timeout)] {
                let provider = Provider(), clock = Clock()
                let vm = EngineHealthCheckViewModel(provider: provider, clock: clock, log: { allLogs.append($0) })
                vm.check(method); await flush()
                expect(vm.current == .checking && provider.calls == 1, "each method begins checking")
                if result == .failed(.timeout) { clock.advance(8); await flush() }
                else { provider.deliverAll(result); await flush() }
                expect(vm.current == result.state, "passed/failed/8-second timeout for each method")
                provider.deliverAll(.passed(.providerVerified)); await flush()
                expect(vm.current == result.state, "late success cannot overwrite failed/timeout outcome")
                vm.cancel(); await flush()
            }
        }
        let switching = Provider(), switchClock = Clock()
        let switchVM = EngineHealthCheckViewModel(provider: switching, clock: switchClock)
        for i in 0..<20 { switchVM.check(RecognitionMethod.allCases[i % 3]); await flush() }
        let final = RecognitionMethod.allCases[19 % 3]
        expect(switching.requests.count == 20, "20 rapid switches actually dispatch 20 requests")
        let pending = switching.requests; switching.requests = []
        for (i, request) in pending.enumerated().reversed() {
            request.continuation.resume(returning: i == 19 ? .passed(.localContainerLoadable) : .failed(.network))
        }
        await flush()
        expect(switchVM.selected == final && switchVM.current == .passed(detail: .localContainerLoadable), "final selection survives all stale completions")
        switchVM.check(.doubao); await flush(); switchVM.cancel(); switching.deliverAll(.passed(.publicInputSource)); await flush()
        expect(switchVM.current == .checking, "explicit cancellation discards provider completion without resetting the label")

        let cached = Provider(), cacheClock = Clock(); cached.immediate = .passed(.providerVerified)
        let cacheVM = EngineHealthCheckViewModel(provider: cached, clock: cacheClock)
        cacheVM.check(.online); await flush(); cacheClock.advance(59)
        cacheVM.check(.online, trigger: .foreground); await flush()
        expect(cached.calls == 1, "60-second online cache avoids repeated provider call")
        cacheVM.recheck(); await flush(); expect(cached.calls == 2, "explicit recheck bypasses cache")
        cacheVM.check(.online, trigger: .configurationChanged); await flush(); expect(cached.calls == 3, "configuration change bypasses cache")
        cacheClock.advance(60); cacheVM.check(.online); await flush(); expect(cached.calls == 4, "expired cache checks again")
        cacheVM.invalidate(.online); cacheVM.check(.online); await flush(); expect(cached.calls == 5, "credential epoch invalidation discards cache")
        let inFlight = Provider(); let inFlightVM = EngineHealthCheckViewModel(provider: inFlight, clock: Clock())
        inFlightVM.check(.online); await flush(); inFlightVM.check(.online, trigger: .foreground); await flush()
        expect(inFlight.calls == 1, "same-method in-flight refresh is coalesced")
        inFlightVM.cancel(); inFlight.deliverAll(.failed(.network)); await flush()
        let adapter = CountingAdapter(), adapterClock = Clock()
        let dispatch = RecognitionHealthProvider(online: adapter, doubao: { .init(installed: false, enabledInSystem: nil) },
            local: { .failed(.modelNotDownloaded) }, credential: { .saved })
        let adapterVM = EngineHealthCheckViewModel(provider: dispatch, clock: adapterClock)
        adapterVM.check(.online); await flush(); adapterVM.check(.online, trigger: .foreground); await flush()
        expect(adapter.calls == 1 && adapterVM.current == .passed(detail: .providerVerified), "adapter through production dispatcher/VM cache")
        adapter.outcome = .failed(.network); adapterVM.recheck(); await flush(); adapterVM.check(.online); await flush()
        expect(adapter.calls == 2 && adapterVM.current == EngineHealthResult.failed(.network).state, "failed adapter result cached too")
        let unsupportedDispatch = RecognitionHealthProvider(online: MetadataProvider(capabilities: .init()),
            doubao: { .init(installed: false, enabledInSystem: nil) }, local: { .failed(.unavailable) }, credential: { .saved })
        expect(await unsupportedDispatch.check(.online) == .failed(.notNetworkVerified), "format-only adapter cannot claim network passed")

        let table: [(HealthFailureReason, HealthNextAction)] = [
            (.doubaoNotInstalled, .installDoubao), (.doubaoNotEnabled, .enableSystemInput),
            (.modelNotDownloaded, .downloadRecommendedModel), (.modelCorrupt, .redownloadModel),
            (.hardwareUnsuitable, .use06B), (.noKey, .configureAPI), (.invalidKey, .replaceKey),
            (.network, .retryNetwork), (.freeQuotaExhausted, .providerConsole), (.timeout, .retryNetwork)
        ]
        for (reason, action) in table { expect(reason.nextAction == action && !reason.message.isEmpty, "reason/action matrix") }
        expect(DoubaoDetection(installed: false, enabledInSystem: nil).result == .failed(.doubaoNotInstalled), "public installed fact")
        expect(DoubaoDetection(installed: true, enabledInSystem: false).result == .failed(.doubaoNotEnabled), "public enabled fact")
        expect(DoubaoDetection(installed: true, enabledInSystem: nil).result == .failed(.inspectionUnavailable), "unreadable input list is unknown")
        expect(DoubaoDetection(installed: true, enabledInSystem: true).result == .passed(.publicInputSource), "two public facts pass")
        let ali = AliyunOnlineAPIProvider()
        for (credential, result) in [(OnlineCredentialState.missing, OnlineAPIValidation.failed(.noKey)),
            (.unreadable, .failed(.invalidKey)), (.saved, .notNetworkVerified)] {
            expect(await ali.validate(credential: credential) == result, "Ali presence is not network validation")
        }
        expect(!ali.capabilities.supportsLightweightValidation, "inert fixture cannot run a connection check")
        var handshakes = 0
        let connectedAli = AliyunOnlineAPIProvider(checkSaved: { handshakes += 1; return .verified })
        expect(await connectedAli.validate(credential: .missing) == .failed(.noKey) && handshakes == 0, "missing key never probes")
        expect(await connectedAli.validate(credential: .unreadable) == .failed(.invalidKey) && handshakes == 0, "unreadable key never probes")
        expect(await connectedAli.validate(credential: .saved) == .verified && handshakes == 1, "saved key uses exactly one injected handshake")
        expect(connectedAli.capabilities.supportsLightweightValidation, "selected-model zero-audio checker supported")
        let unknown = EngineHealthResult.failed(.notNetworkVerified).state
        expect(unknown.isUnverified && unknown.statusTitle.isEmpty && unknown.phase == .content, "unknown configuration is neutral content")
        for failure in CloudConnectionCheck.Failure.allCases {
            let reason = AliyunOnlineAPIProvider.failure(failure)
            let failed = AliyunOnlineAPIProvider(checkSaved: { .failed(reason) })
            expect(await failed.validate(credential: .saved) == .failed(reason), "finite handshake failure retained")
            expect(!reason.message.isEmpty, "every connection failure has a reason")
        }
        var retained = true
        let remembered = OnlineEnhancementPreferenceSource(read: { retained }, write: { retained = $0 })
        remembered.reconcile(selection: try! VoiceInputSelection(mode: .doubao), credentialAvailable: true, visible: true)
        expect(retained && !remembered.isEffective(method: .doubao, configured: true), "fallback preference keeps choice but is not effective on Doubao")
        remembered.reconcile(selection: try! VoiceInputSelection(mode: .doubao), credentialAvailable: false, visible: true)
        expect(!retained, "fallback reconciliation closes on deleted key")
        expect(AliyunOnlineAPIProvider.failure(.rejectedKey) == .invalidKey && AliyunOnlineAPIProvider.failure(.freeQuotaExhausted) == .freeQuotaExhausted, "existing Ali finite failures adapted")
        for method in RecognitionMethod.allCases {
            let provider = RecognitionHealthProvider(online: ali, doubao: { .init(installed: false, enabledInSystem: false) },
                local: { .failed(.hardwareUnsuitable) }, credential: { .missing })
            let expected: EngineHealthResult = method == .doubao ? .failed(.doubaoNotInstalled) : method == .local ? .failed(.hardwareUnsuitable) : .failed(.noKey)
            expect(await provider.check(method) == expected, "production dispatch supplies method-specific reasons")
        }
        for configured in [false, true] { for initial in [false, true] {
            var saved = initial, writes = 0
            let source = OnlineEnhancementPreferenceSource(read: { saved }, write: { saved = $0; writes += 1 })
            let config = OnlineAPIConfigViewModel(provider: ali, enhancement: source)
            config.update(credential: configured ? .saved : .missing, visible: true)
            expect(config.showsEnhancementSwitch == configured && config.enhancementAction == (configured ? nil : .configureAPI), "configured matrix exposes switch or configure action")
            expect(saved == initial && writes == 0, "save/migration/init do not enable")
            source.synchronize(); config.update(credential: configured ? .saved : .missing, visible: true)
            _ = await ali.validate(credential: configured ? .saved : .missing); source.synchronize()
            expect(saved == initial && writes == 0, "check/refresh preserve enhancement preference")
            for method in RecognitionMethod.allCases { expect(source.isEffective(method: method, configured: configured) == (method == .local && configured && initial), "central effectiveness predicate") }
            config.setEnhancementFromUser(true, authorized: false)
            expect(saved == initial, "no authorization bypass through VM")
        } }
        var mirrorValue = false, notifications = 0
        let mirror = OnlineEnhancementPreferenceSource(read: { mirrorValue }, write: { mirrorValue = $0 })
        mirror.onChange = { notifications += 1 }
        let entrance1 = OnlineAPIConfigViewModel(provider: ali, enhancement: mirror)
        let entrance2 = OnlineAPIConfigViewModel(provider: ali, enhancement: mirror)
        entrance1.update(credential: .saved, visible: true); entrance2.update(credential: .saved, visible: true)
        entrance1.setEnhancementFromUser(true, authorized: true); expect(entrance2.enhanceLocalWithOnlineAPI, "local entrance mirrors online")
        entrance2.setEnhancementFromUser(false, authorized: false); expect(!entrance1.enhanceLocalWithOnlineAPI && notifications == 2, "online entrance mirrors local")
        for _ in 0..<50 { mirror.synchronize() }; expect(notifications == 2, "unchanged source emits nothing")
        let localSelection = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "zh")
        entrance1.setEnhancementFromUser(true, authorized: true)
        mirror.reconcile(selection: localSelection, credentialAvailable: true, visible: true); expect(mirrorValue, "valid migration never changes true")
        mirror.reconcile(selection: try! VoiceInputSelection(), credentialAvailable: true, visible: true)
        expect(mirrorValue, "route switch preserves enhancement choice")
        mirror.reconcile(selection: localSelection, credentialAvailable: true, visible: true); expect(mirrorValue, "returning local retains enhancement choice")
        let metadata = OnlineAPIReadOnlyMetadata(serviceExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), serviceRemainingFreeUnits: 12)
        entrance1.update(credential: .saved, visible: true, metadata: metadata)
        expect(entrance1.expiresAt == nil && entrance1.remainingFreeUnits == nil, "unsupported metadata rows hidden")
        let capable = OnlineAPIConfigViewModel(provider: MetadataProvider(capabilities: .init(canReadExpiry: true, canReadQuota: true, supportsLightweightValidation: true)), enhancement: mirror)
        capable.update(credential: .saved, visible: true, userLabel: "Custom", metadata: metadata)
        expect(capable.expiresAt == metadata.expiresAt && capable.remainingFreeUnits == 12 && capable.recognitionTitle.contains("Custom"), "service metadata and user-label priority")
        let generic = OnlineAPIConfigViewModel(provider: MetadataProvider(capabilities: .init()), enhancement: mirror)
        expect(generic.recognitionTitle == "在线 API 识别（Fixture Provider）", "generic provider naming")
        expect(ali.keyHelpURL.scheme == "https" && ali.docURL.scheme == "https", "adapter documentation URLs construct")

        let fixture = SettingsViewModelFixtures.Set(phase: .content, configured: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let permitted = CloudEntryPreferences(visible: true, routeEnabled: true, uploadConsent: true)
        let admission = CloudEntryStatus.confirmed(validUntil: now.addingTimeInterval(3600))
        let selectedOnline = try! VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.routeID, language: "zh")
        func menu(_ ledger: OnlineConnectionCheckState, selection: VoiceInputSelection = localSelection, preferences: CloudEntryPreferences = permitted) -> OnlineRouteMenuState {
            fixture.menu.onlineState(loaded: true, credentialChanging: false, preferences: preferences, admission: admission, ledger: ledger, selection: selection)
        }
        fixture.online.update(credential: .missing, visible: true)
        expect(menu(.idle).title.contains("未配置") && menu(.idle).action == .openSettings, "menu unconfigured")
        fixture.online.update(credential: .saved, visible: true, userLabel: "Label")
        expect(menu(.running).statusSuffix.isEmpty, "menu checking")
        expect(menu(.passed(now)).title.contains("可用") && !menu(.passed(now)).title.contains("未配置"), "menu passed")
        expect(menu(.failed(.network)).title.contains("连不上服务商") && menu(.failed(.network)).action == .openSettings, "menu failed")
        expect(menu(.passed(now), selection: selectedOnline).selected && !menu(.passed(now)).selected, "menu switched checkmark")
        for denied in [CloudEntryPreferences(visible: false, routeEnabled: true, uploadConsent: true),
            .init(visible: true, routeEnabled: false, uploadConsent: true), .init(visible: true, routeEnabled: true, uploadConsent: false)] {
            expect(menu(.passed(now), preferences: denied).action == .openSettings, "VM cannot bypass T2 permissions")
        }
        fixture.menu.updateLocalPreparation([.qwen17: true, .qwen06: true])
        fixture.menu.updateLocalHealth(.qwen17, state: .failed(reason: .timeout, nextAction: .retryNetwork))
        expect(fixture.menu.title(for: .local, engine: .qwen17).contains("检查超时"), "engine-specific failure")
        expect(!fixture.menu.title(for: .local, engine: .qwen06).contains("检查超时") && fixture.menu.localPreparation[.qwen06] == true, "other prepared engine keeps qualification and independent status")
        for phase in [SettingsLoadState.idle, .loading, .empty, .error] {
            for method in RecognitionMethod.allCases {
                let f = SettingsViewModelFixtures.Set(phase: phase, method: method)
                expect([f.health.phase, f.online.phase, f.options.phase, f.local.phase, f.doubao.phase, f.permissions.phase, f.data.phase, f.menu.phase].allSatisfy { $0 == phase }, "all VM four-state fixtures construct")
                expect(f.options.visibleSettings == method, "only selected settings projected")
                expect(f.local.recommendedModels.allSatisfy { $0.id == .qwen06 }, "8GB fixture only recommends 0.6B")
            }
        }
        let installer = fixture.local
        for reason in HealthFailureReason.allCases {
            installer.checked(.qwen06, result: .failed(reason))
            let expected: LocalModelState = reason == .modelCorrupt ? .corrupt : reason == .modelNotDownloaded ? .notDownloaded
                : reason == .hardwareUnsuitable ? .notApplicable(reason: .hardwareUnsuitable) : .needsVerification
            expect(installer.models.first { $0.id == .qwen06 }?.state == expected, "only proven corruption maps to corrupt")
        }
        let manager = ModelManager()
        let actionsVM = LocalModelInstallerViewModel(hardware: .init(memoryBytes: 16 << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true), manager: manager)
        actionsVM.update(models: [.init(id: .qwen06, sizeBytes: 12, recommended: true, state: .notDownloaded)])
        actionsVM.perform(.download, id: .qwen06, consent: true); await flush()
        expect(actionsVM.models[0].state == .downloading(progress: 0.5), "download progress flows through VM")
        actionsVM.perform(.cancel, id: .qwen06); manager.finish(); await flush()
        expect(actionsVM.models[0].state == .notDownloaded && manager.actions == [.download, .cancel], "cancelled download cannot mark ready")
        actionsVM.perform(.download, id: .qwen06, consent: true); await flush(); manager.finish(); await flush()
        expect(actionsVM.models[0].state == .needsVerification, "download completion still needs integrity check")
        actionsVM.checked(.qwen06, result: .passed(.localContainerLoadable)); actionsVM.perform(.use, id: .qwen06); await flush()
        actionsVM.perform(.delete, id: .qwen06); await flush()
        expect(actionsVM.models[0].state == .notDownloaded && manager.actions.suffix(2) == [.use, .delete], "use/delete flow through typed app-owned delegate")
        var removals = 0
        let data = DataManagementViewModel(deleteItem: { _ in removals += 1 }, prepareUninstall: { removals += 10 })
        data.update([.init(id: .model06, sizeBytes: 100)])
        await data.confirmUninstall(); expect(removals == 0, "uninstall requires first confirmation state")
        data.requestUninstall(); data.cancelUninstall(); await data.confirmUninstall(); expect(removals == 0, "cancelled uninstall does nothing")
        await data.delete(.model06); expect(removals == 1 && data.phase == .empty, "per-item deletion uses typed delegate")
        data.requestUninstall(); await data.confirmUninstall(); expect(removals == 11 && data.confirmation == .confirmed, "second confirmation delegates once")
        await data.confirmUninstall(); expect(removals == 11, "confirmed state cannot execute twice")

        failures += await modelIntegrityChecks()
        expect(allLogs.allSatisfy(SettingsHealthLog.isWhitelisted), "all new health logs satisfy exact whitelist")
        for reason in HealthFailureReason.allCases {
            expect(SettingsHealthLog.isWhitelisted(SettingsHealthLog.line(method: .local, state: .failed(reason: reason, nextAction: reason.nextAction), generation: 4, milliseconds: 8000)), "reason log vocabulary")
        }
        expect(!SettingsHealthLog.isWhitelisted("event=engine_check,key=forbidden") && !SettingsHealthLog.isWhitelisted("event=engine_check,method=online,state=custom,reason=none,generation=1,ms=0"), "unknown fields/states rejected")
        return failures
    }

    private static func modelIntegrityChecks() async -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("T4 integrity: " + label) } }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("T4-model-fixture-\(UUID().uuidString)")
        let fm = FileManager.default
        var stage = "create_root"
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let header = Data("{\"weight\":{\"dtype\":\"F32\",\"shape\":[1],\"data_offsets\":[0,4]}}".utf8)
            var model = Data((0..<8).map { UInt8((UInt64(header.count) >> ($0 * 8)) & 255) }); model.append(header); model.append(Data(repeating: 0, count: 4))
            stage = "write_model"
            try model.write(to: root.appendingPathComponent("model.safetensors"))
            let runtime = root.appendingPathComponent("runtime")
            stage = "write_runtime"
            try Data("synthetic-executable-marker".utf8).write(to: runtime); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
            let hash = SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined()
            let file = LocalModelIntegrityFile(path: "model.safetensors", sha256: hash, size: UInt64(model.count))
            let hardware = SettingsHardwareInfo(memoryBytes: 16 << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true)
            func spec(_ files: [LocalModelIntegrityFile], hardware: SettingsHardwareInfo = hardware, runtimeURL: URL = runtime) -> LocalModelCheckSpecification {
                .init(id: .qwen17, root: root, files: files, hardware: hardware, runtimeExecutable: runtimeURL)
            }
            expect(await LocalModelHealthInspector.check(spec([file])) == .passed(.localContainerLoadable), "hash/size/container/runtime real data flow")
            expect(await LocalModelHealthInspector.check(spec([.init(path: file.path, sha256: String(repeating: "0", count: 64), size: file.size)])) == .failed(.modelCorrupt), "checksum mismatch")
            expect(await LocalModelHealthInspector.check(spec([.init(path: "absent", sha256: hash, size: 4)])) == .failed(.modelNotDownloaded), "no files downloaded")
            expect(await LocalModelHealthInspector.check(spec([file, .init(path: "absent", sha256: hash, size: 4)])) == .failed(.modelCorrupt), "partial model missing")
            expect(await LocalModelHealthInspector.check(spec([.init(path: file.path, sha256: nil, size: file.size)])) == .failed(.unavailable), "missing authoritative checksum remains unknown")
            expect(await LocalModelHealthInspector.check(spec([file], runtimeURL: root.appendingPathComponent("missing-runtime"))) == .failed(.localLoadFailed), "runtime missing")
            expect(await LocalModelHealthInspector.check(spec([file], hardware: .init(memoryBytes: 8 << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true))) == .failed(.hardwareUnsuitable), "1.7B unsuitable hardware")
            expect(await LocalModelHealthInspector.check(spec([.init(path: "../outside", sha256: hash, size: 4)])) == .failed(.modelCorrupt), "model cannot escape root")
            stage = "write_invalid_container"
            let invalid = Data(repeating: 0, count: 12); try invalid.write(to: root.appendingPathComponent("invalid.safetensors"))
            let invalidHash = SHA256.hash(data: invalid).map { String(format: "%02x", $0) }.joined()
            expect(await LocalModelHealthInspector.check(spec([.init(path: "invalid.safetensors", sha256: invalidHash, size: 12)])) == .failed(.localLoadFailed), "actual container parse required after hash")
            let credentials = root.appendingPathComponent("credentials")
            let store = CloudCredentialStore(service: "T4-synthetic-presence", directory: credentials)
            stage = "missing_credential_attributes"
            expect(try await !store.hasStoredCredentialFile(provider: .aliyunBeijing), "missing metadata needs no Key")
            stage = "create_credential_fixture"
            try fm.createDirectory(at: credentials, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let marker = credentials.appendingPathComponent("cred-aliyun-beijing.bin")
            try Data("synthetic-not-a-credential".utf8).write(to: marker); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            stage = "read_credential_attributes"
            expect(try await store.hasStoredCredentialFile(provider: .aliyunBeijing), "attributes do not decrypt/read synthetic contents")
            // Invalid metadata cannot qualify; no attempt is made to read a master/key.
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
            do { _ = try await store.hasStoredCredentialFile(provider: .aliyunBeijing); expect(false, "unsafe mode rejected") } catch {}
        } catch { failures.append("T4 integrity: fixture_stage=\(stage),error_code=\((error as NSError).code)") }
        return failures
    }
}
