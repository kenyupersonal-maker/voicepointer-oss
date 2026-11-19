// Production bridge shared by menu/settings. Explicit settings events may check the saved model without audio.
import AppKit
import Carbon
import Combine
import VoicePointerCore

extension Notification.Name {
    static let voicePointerSettingsLogicChanged = Notification.Name("VoicePointerSettingsLogicChanged")
}

@MainActor enum DoubaoPublicInspector {
    static let bundleID = "com.bytedance.inputmethod.doubaoime"
    struct Result {
        let detection: DoubaoDetection
        let matchingSources: Int
        var logLine: String {
            "event=public_input_source,installed=\(detection.installed ? 1 : 0),matches=\(matchingSources),available=\(detection.enabledInSystem == nil ? 0 : 1),enabled=\(detection.enabledInSystem == true ? 1 : 0)"
        }
    }
    static func inspect() -> Result {
        let known = [URL(fileURLWithPath: "/Library/Input Methods/DoubaoIme.app"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/DoubaoIme.app"),
                     URL(fileURLWithPath: "/Applications/DoubaoIme.app")]
        // Bundle accesses only public Contents/Info.plist. No package data/config is read.
        let installed = known.contains { Bundle(url: $0)?.bundleIdentifier == bundleID }
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource], !list.isEmpty else {
            return .init(detection: .init(installed: installed, enabledInSystem: nil), matchingSources: 0)
        }
        let matching = list.filter { source in
            let bundle = string(source, key: kTISPropertyBundleID)
            let sourceID = string(source, key: kTISPropertyInputSourceID)
            return bundle == bundleID || sourceID == bundleID || sourceID?.hasPrefix(bundleID + ".") == true
        }
        let enabled = matching.contains { source in
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
        }
        return .init(detection: .init(installed: installed, enabledInSystem: enabled), matchingSources: matching.count)
    }
    private static func string(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

@MainActor protocol SettingsConnectionLedgerBridge: AnyObject {
    var settingsConnectionState: OnlineConnectionCheckState { get }
    func beginConnectionCheck() -> UUID
    func completeSettingsCheck(_ outcome: CloudConnectionCheck.Outcome, generation: UUID)
    func invalidateSettingsCheck()
}
extension CloudEntryRuntime: SettingsConnectionLedgerBridge {
    var settingsConnectionState: OnlineConnectionCheckState { connectionCheck.state }
}

@MainActor final class SettingsLogicRuntime: ObservableObject {
    static let shared = SettingsLogicRuntime()
    @Published private(set) var revision: UInt64 = 0
    let health: EngineHealthCheckViewModel
    private let onlineHealth: EngineHealthCheckViewModel?
    private let healthArchive: EngineHealthArchive?
    let online: OnlineAPIConfigViewModel
    let options: RecognitionOptionsViewModel
    let local: LocalModelInstallerViewModel
    private let downloadManager: LocalModelDownloadManager?
    let doubao: DoubaoSetupViewModel
    let permissions = PermissionsViewModel()
    let data: DataManagementViewModel
    let dataRuntime: SettingsDataRuntime?
    private var dataRemovalPending = false
    let menu: MenuBarStatusViewModel
    private let ledger: any SettingsConnectionLedgerBridge
    private let tracksOnlineHealthChecks: Bool
    private var ledgerGeneration: UUID?
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var localChecks: [LocalModelID: Task<Void, Never>] = [:]
    private var localCheckGenerations: [LocalModelID: UInt64] = [:]
    private var projectingLocalModels = false
    private var pendingOnlineCheck: HealthCheckTrigger?
    private let readLabel: () -> String?
    private let writeLabel: (String?) -> Void
    private let currentCredentialEpoch: () -> UUID
    private let readPage: () async -> CloudEntryPageState
    var onCloudAuthorizationClosed: (() -> Void)?
    var onNotification: (() -> Void)?
    private var lastProjection: Projection?
    private struct Projection: Equatable {
        let selection: VoiceInputSelection
        let method: RecognitionMethod
        let credential: OnlineCredentialState
        let visible: Bool, enhancement: Bool
        let label: String?
        let configPhase: SettingsLoadState, healthPhase: SettingsLoadState
        let states: [RecognitionMethod: EngineHealthState]
        let models: [LocalModelItem]
        let preparation: [LocalModelID: Bool], modelHealth: [LocalModelID: EngineHealthState]
        let doubaoInstalled: Bool, doubaoEnabled: Bool?
        let permissions: [SettingsPermission: SettingsPermissionStatus]
        let data: [ManagedDataItem]
        let dataPhase: SettingsLoadState, dataFailure: AppDataFailure?, dataConfirmation: DataRemovalConfirmation
        let dataTotal: UInt64
        let ledgerStatus: String
    }
    private(set) var selection = try! VoiceInputSelection()
    private let facts: Facts
    private final class Facts { var localRoute = CloudEntry.localFallbackRouteID; var forceLocal = false }

    init(provider: (any EngineHealthProviding)? = nil, enhancement: OnlineEnhancementPreferenceSource? = nil,
         ledger: (any SettingsConnectionLedgerBridge)? = nil, clock: (any SettingsHealthClock)? = nil,
         hardware: SettingsHardwareInfo? = nil, tracksOnlineHealthChecks: Bool? = nil,
         automaticOnlineChecks: Bool? = nil,
         pageState: (() async -> CloudEntryPageState)? = nil,
         readLabel: @escaping () -> String? = { UserDefaults.standard.string(forKey: "online.api.label") },
         writeLabel: @escaping (String?) -> Void = { value in
             if let value { UserDefaults.standard.set(value, forKey: "online.api.label") }
             else { UserDefaults.standard.removeObject(forKey: "online.api.label") }
         }, credentialEpoch: @escaping () -> UUID = { CloudEntryRuntime.shared.settingsCredentialEpoch },
         log: @escaping (String) -> Void = { RuntimeTrace.record($0) }) {
        self.readLabel = readLabel; self.writeLabel = writeLabel
        currentCredentialEpoch = credentialEpoch
        readPage = pageState ?? { await CloudEntryRuntime.shared.pageState() }
        let dedicated = automaticOnlineChecks ?? (provider == nil)
        let savedCheck: (@MainActor () async -> OnlineAPIValidation)?
        if provider == nil { savedCheck = { await OnlineAPIRuntime.shared.checkSavedHealth() } }
        else { savedCheck = nil }
        let adapter = AliyunOnlineAPIProvider(checkSaved: savedCheck)
        self.tracksOnlineHealthChecks = tracksOnlineHealthChecks
            ?? (provider != nil || adapter.capabilities.supportsLightweightValidation)
        let source = enhancement ?? OnlineEnhancementPreferenceSource()
        let detectedHardware = hardware ?? Self.hardwareInfo()
        let archive = provider == nil ? EngineHealthArchive(defaults: .standard) : nil
        healthArchive = archive
        online = OnlineAPIConfigViewModel(provider: adapter, enhancement: source)
        let downloads = provider == nil ? LocalModelDownloadManager() : nil
        downloadManager = downloads
        local = LocalModelInstallerViewModel(hardware: detectedHardware, manager: downloads)
        let cleanup = provider == nil ? SettingsDataRuntime() : nil
        dataRuntime = cleanup
        data = DataManagementViewModel(inventory: cleanup.map { service in { try await service.inventory() } },
            deleteItem: cleanup.map { service in { try await service.remove($0) } },
            clearLexicon: cleanup.map { service in { try await service.clearLexicon() } },
            prepareUninstall: cleanup.map { service in { try await service.prepareUninstall() } })
        doubao = DoubaoSetupViewModel()
        let facts = Facts(); self.facts = facts
        let doubaoModel = doubao
        let realProvider = RecognitionHealthProvider(online: adapter,
            doubao: { let result = DoubaoPublicInspector.inspect(); doubaoModel.update(result.detection); return result.detection },
            local: { await VoiceNativeModelPreparation.inspectLocalModel(routeID: facts.localRoute, hardware: detectedHardware, force: facts.forceLocal) },
            credential: { await CloudEntryRuntime.shared.credentialPresenceForHealth() })
        health = EngineHealthCheckViewModel(provider: provider ?? realProvider, clock: clock ?? SystemSettingsHealthClock(), archive: archive, log: log)
        onlineHealth = dedicated ? EngineHealthCheckViewModel(provider: provider ?? realProvider,
            clock: clock ?? SystemSettingsHealthClock(), timeout: 8, archive: archive, log: log) : nil
        options = RecognitionOptionsViewModel(health: health, online: online)
        menu = MenuBarStatusViewModel(options: options)
        self.ledger = ledger ?? CloudEntryRuntime.shared
        if archive != nil {
            health.configure(.doubao, slot: "doubao", identity: "doubao")
            let identity = UserDefaults.standard.string(forKey: "engine.health.online.configuration") ?? "initial"
            health.configure(.online, slot: "online", identity: identity)
            onlineHealth?.configure(.online, slot: "online", identity: identity)
            let localFingerprint = VoiceNativeModelPreparation.localHealthFingerprint(routeID: facts.localRoute, hardware: detectedHardware) ?? "missing"
            health.configure(.local, slot: facts.localRoute, identity: localFingerprint)
            local.update(models: VoiceNativeModelPreparation.localModelInventory(hardware: detectedHardware))
            restoreLocalModels()
        }
        source.onChange = { [weak self] in self?.changed() }
        online.onChange = { [weak self] in self?.changed() }
        menu.onChange = { [weak self] in self?.changed() }
        permissions.onChange = { [weak self] in self?.changed() }
        local.onChange = { [weak self] in
            guard let self else { return }
            if self.healthArchive != nil { self.restoreLocalModels(checkMissing: true) }
            self.changed()
        }
        data.onChange = { [weak self] in self?.changed() }
        cleanup?.beforeRemoval = { [weak self] all in
            guard let self else { throw AppDataFailure.removal }
            self.cancelLocalChecks()
            await self.local.cancelDownloadsAndWait(); self.health.cancel()
            if all { self.dataRemovalPending = true; self.refreshGeneration &+= 1; self.refreshTask?.cancel() }
            guard let action = self.onBeforeDataRemoval else { throw AppDataFailure.removal }
            try await action(all)
        }
        cleanup?.afterRemoval = { [weak self] in await self?.refreshModelInventory() }
        health.onChange = { [weak self] in self?.healthChanged() }
        health.onResult = { [weak self] method, result in self?.completed(method, result) }
        onlineHealth?.onChange = { [weak self] in
            guard let self, let state = self.onlineHealth?.states[.online] else { return }
            self.health.project(.online, state: state)
            self.healthChanged()
        }
        onlineHealth?.onResult = { [weak self] method, result in self?.completed(method, result) }
    }
    static func hardwareInfo() -> SettingsHardwareInfo {
        let root = IntegratedRuntimePaths.assetRoot ?? FileManager.default.homeDirectoryForCurrentUser
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        #if arch(arm64)
        let apple = true
        #else
        let apple = false
        #endif
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(1, size))
        let read = sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        let chip = read == 0 ? String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "unknown"
        return .init(memoryBytes: ProcessInfo.processInfo.physicalMemory, availableDiskBytes: UInt64(max(0, free)), isAppleSilicon: apple, chipModel: chip)
    }
    enum LabelUpdate { case preserve, replace(String?) }
    func update(page: CloudEntryPageState, selection: VoiceInputSelection, labelUpdate: LabelUpdate = .preserve) {
        guard page.isLoaded else { return }
        if let epoch = page.credentialEpoch, epoch != currentCredentialEpoch() { return }
        self.selection = selection
        if healthArchive != nil { restoreLocalModels(checkMissing: true) }
        let key: OnlineCredentialState = page.key == .saved ? .saved : page.key == .unreadable ? .unreadable : .missing
        let effectiveLabel: String?
        switch labelUpdate { case .preserve: effectiveLabel = online.userLabel; case .replace(let value): effectiveLabel = value }
        if online.credential != key || online.isVisible != page.isVisible || online.userLabel != effectiveLabel || online.phase == .idle {
            online.update(credential: key, visible: page.isVisible, userLabel: effectiveLabel)
        }
        changed()
    }
    /// An explicit nil means clear; callers omitting label use the preserving overload above.
    func update(page: CloudEntryPageState, selection: VoiceInputSelection, label: String?) {
        update(page: page, selection: selection, labelUpdate: .replace(label))
    }
    func saveUserLabel(_ value: String?) {
        writeLabel(value)
        online.update(credential: online.credential, visible: online.isVisible, userLabel: value)
    }
    func scheduleRefresh(selection: VoiceInputSelection, trigger: HealthCheckTrigger) {
        guard !dataRemovalPending else { return }
        if trigger == .settingsOpened || trigger == .configurationChanged { pendingOnlineCheck = trigger }
        if health.selected != RecognitionOptionsViewModel.method(for: selection)
            || (RecognitionOptionsViewModel.method(for: selection) == .local && facts.localRoute != selection.routeID)
            || trigger == .configurationChanged { health.cancel() }
        self.selection = selection
        refreshTask?.cancel()
        if healthArchive != nil { restoreLocalModels(checkMissing: true) }
        refreshTask = Task { [weak self] in await self?.refresh(selection: selection, trigger: trigger) }
    }
    func refresh(selection: VoiceInputSelection, trigger: HealthCheckTrigger) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let page = await readPage()
        guard !Task.isCancelled, generation == refreshGeneration, page.isLoaded else { return }
        update(page: page, selection: selection, label: readLabel())
        online.enhancement.reconcile(selection: selection, credentialAvailable: online.keySaved, visible: online.isVisible)
        await refreshModelInventory()
        if trigger == .launch, let last = (onlineHealth ?? health).record(for: .online),
           Date().timeIntervalSince(last.date) > 86400 { checkOnline(trigger: .foreground) }
        if onlineHealth != nil, let pending = pendingOnlineCheck {
            pendingOnlineCheck = nil; checkOnline(trigger: pending)
        }
        inspect(RecognitionOptionsViewModel.method(for: selection), routeID: selection.routeID, trigger: trigger)
    }
    func inspect(_ method: RecognitionMethod, routeID: String? = nil, trigger: HealthCheckTrigger = .selection) {
        if method != .local && (trigger == .selection || options.selected != method) { local.cancelDownloads() }
        if method == .local {
            if let routeID { facts.localRoute = routeID }
            facts.forceLocal = trigger == .recheck
            let identity = healthArchive == nil ? facts.localRoute : localIdentity(facts.localRoute)
            health.configure(.local, slot: facts.localRoute, identity: identity)
        }
        if method == .online, onlineHealth != nil {
            options.select(method, trigger: trigger, checkHealth: false)
            if trigger == .recheck { checkOnline(trigger: trigger) }
        } else { options.select(method, trigger: trigger) }
    }
    func refreshModelInventory() async {
        let bundled = VoiceNativeModelPreparation.localModelInventory(hardware: local.hardware)
        let models = await downloadManager?.inventory(bundled, hardware: local.hardware) ?? bundled
        guard !Task.isCancelled else { return }
        local.update(models: models)
        if healthArchive != nil { restoreLocalModels(checkMissing: true) }
    }
    private func cancelLocalChecks() {
        for id in LocalModelID.allCases {
            localCheckGenerations[id, default: 0] &+= 1
            localChecks[id]?.cancel()
        }
        localChecks.removeAll()
    }
    /// Restore each model independently; a background check must never select
    /// another engine or overwrite the shared check's route/force parameters.
    private func restoreLocalModels(checkMissing: Bool = false) {
        guard !projectingLocalModels else { return }
        projectingLocalModels = true
        defer { projectingLocalModels = false }
        var preparation: [LocalModelID: Bool] = [:]
        for id in LocalModelID.allCases {
            preparation[id] = VoiceNativeModelPreparation.isLocalPrepared(routeID: id.rawValue, language: selection.language)
            let fingerprint = VoiceNativeModelPreparation.localHealthFingerprint(routeID: id.rawValue, hardware: local.hardware)
            let record = local.hardware.supports(id) ? fingerprint.flatMap { healthArchive?.read(id.rawValue, configuration: $0) } : nil
            let row = local.models.first { $0.id == id }
            if row?.state.isInstalling == true { continue }
            let state: EngineHealthState
            if let record { state = record.state }
            else if row?.state == .notDownloaded { state = .failed(reason: .modelNotDownloaded, nextAction: .downloadRecommendedModel) }
            else if row?.state == .corrupt { state = .failed(reason: .modelCorrupt, nextAction: .redownloadModel) }
            else { state = .idle }
            menu.updateLocalHealth(id, state: state)
            switch state {
            case .passed(let detail): local.checked(id, result: .passed(detail))
            case .failed(let reason, _): local.checked(id, result: .failed(reason))
            default: break
            }
            guard checkMissing, record == nil, fingerprint != nil, local.hardware.supports(id),
                  localChecks[id] == nil else { continue }
            localCheckGenerations[id, default: 0] &+= 1
            let generation = localCheckGenerations[id]!
            let hardware = local.hardware
            localChecks[id] = Task { [weak self] in
                let started = ProcessInfo.processInfo.systemUptime
                let result = await VoiceNativeModelPreparation.inspectLocalModel(routeID: id.rawValue, hardware: hardware)
                guard let self, !Task.isCancelled, self.localCheckGenerations[id] == generation else { return }
                self.localChecks[id] = nil
                guard fingerprint == VoiceNativeModelPreparation.localHealthFingerprint(routeID: id.rawValue, hardware: self.local.hardware) else {
                    self.restoreLocalModels(checkMissing: true)
                    return
                }
                let state = result.state
                if let fingerprint {
                    self.healthArchive?.write(.init(state: state, date: Date(), source: .check, configuration: fingerprint), slot: id.rawValue)
                }
                self.menu.updateLocalHealth(id, state: state)
                self.local.checked(id, result: result)
                if self.facts.localRoute == id.rawValue { self.health.project(.local, state: state) }
                RuntimeTrace.record(SettingsHealthLog.line(method: .local, state: state, generation: generation,
                    milliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000), source: .check))
                self.changed()
            }
        }
        menu.updateLocalPreparation(preparation)
    }
    private func checkOnline(trigger: HealthCheckTrigger) { (onlineHealth ?? health).check(.online, trigger: trigger) }
    func isChecking(_ method: RecognitionMethod) -> Bool {
        (method == .online ? onlineHealth ?? health : health).checkingMethod == method
    }
    func healthDetail(_ method: RecognitionMethod) -> String {
        let vm = method == .online ? onlineHealth ?? health : health
        guard let record = vm.record(for: method) else { return "还没用过" }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        if record.result == .available, let used = record.lastDictation { return "可用 · \(formatter.string(from: used)) 听写成功" }
        if record.result == .unavailable { return record.state.statusTitle }
        if record.result == .notConfigured { return method == .online && !online.keySaved ? SettingsStrings.notConfigured : "" }
        return "可用 · \(formatter.string(from: record.date)) 检查通过；还没用过"
    }
    private func localIdentity(_ route: String) -> String {
        VoiceNativeModelPreparation.localHealthFingerprint(routeID: route, hardware: local.hardware) ?? "missing"
    }
    /// A card requests health before switching; this never commits or grants a route itself.
    func prepareSelection(_ method: RecognitionMethod, routeID: String?) async -> Bool {
        inspect(method, routeID: routeID)
        let vm = method == .online ? onlineHealth ?? health : health
        if method == .online { checkOnline(trigger: .selection) }
        let cutoff = ProcessInfo.processInfo.systemUptime + 8.2
        while vm.checkingMethod == method, ProcessInfo.processInfo.systemUptime < cutoff {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
        }
        guard !Task.isCancelled, vm.checkingMethod != method else { return false }
        if case .passed = vm.states[method] { return true }
        return false
    }
    func recheckOnline() { checkOnline(trigger: .recheck) }
    func recordDictation(selection: VoiceInputSelection, failure: HealthFailureReason?) {
        let method = RecognitionOptionsViewModel.method(for: selection)
        let slot = method == .local ? selection.routeID : method.rawValue
        guard EngineHealthArchive.slots.contains(slot) else { return }
        let identity = method == .online ? UserDefaults.standard.string(forKey: "engine.health.online.configuration") ?? "initial"
            : method == .local ? localIdentity(slot) : slot
        let vm = method == .online ? onlineHealth ?? health : health
        vm.recordDictation(method, slot: slot, identity: identity, failure: failure)
        if method == .online { health.project(.online, state: vm.states[.online] ?? .idle) }
        if let id = LocalModelID(rawValue: slot) {
            menu.updateLocalHealth(id, state: healthArchive?.read(slot, configuration: identity)?.state ?? .idle)
        }
        changed(force: true)
    }
    func configurationWillChange() {
        refreshGeneration &+= 1; refreshTask?.cancel(); onlineHealth?.configurationChanged(.online); health.configurationChanged(.online)
        if healthArchive != nil {
            let identity = UUID().uuidString
            UserDefaults.standard.set(identity, forKey: "engine.health.online.configuration")
            health.configure(.online, slot: "online", identity: identity)
            onlineHealth?.configure(.online, slot: "online", identity: identity)
        }
        pendingOnlineCheck = nil
        ledgerGeneration = nil; ledger.invalidateSettingsCheck()
    }
    func configurationDidChange() { scheduleRefresh(selection: selection, trigger: .configurationChanged) }
    var onEnhancementAuthorizationChanged: (@MainActor () -> Void)?
    var onBeforeDataRemoval: ((Bool) async throws -> Void)?
    private func changed(force: Bool = false) {
        let ledgerStatus: String
        switch ledger.settingsConnectionState {
        case .idle: ledgerStatus = "idle"
        case .running: ledgerStatus = "running"
        case .passed: ledgerStatus = "passed" // A timestamp/generation is not a product-state change.
        case .failed(let reason): ledgerStatus = "failed.\(reason)"
        }
        let next = Projection(selection: selection, method: options.selected, credential: online.credential,
            visible: online.isVisible, enhancement: online.enhanceLocalWithOnlineAPI, label: online.userLabel,
            configPhase: online.phase, healthPhase: health.phase, states: health.states, models: local.models,
            preparation: menu.localPreparation, modelHealth: menu.localHealth,
            doubaoInstalled: doubao.installed, doubaoEnabled: doubao.enabledInSystem,
            permissions: permissions.statuses, data: data.items, dataPhase: data.phase, dataFailure: data.failure,
            dataConfirmation: data.confirmation, dataTotal: data.totalBytes, ledgerStatus: ledgerStatus)
        guard force || lastProjection != next else { return }
        lastProjection = next
        if !dataRemovalPending { onEnhancementAuthorizationChanged?() }
        revision &+= 1
        onNotification?()
        NotificationCenter.default.post(name: .voicePointerSettingsLogicChanged, object: nil)
    }
    private func healthChanged() {
        if health.selected == .local, let id = LocalModelID(rawValue: facts.localRoute) {
            menu.updateLocalHealth(id, state: health.current)
        }
        if tracksOnlineHealthChecks {
            if isChecking(.online), ledgerGeneration == nil {
                ledgerGeneration = ledger.beginConnectionCheck()
            } else if !isChecking(.online), health.states[.online] == .idle, ledgerGeneration != nil {
                ledgerGeneration = nil; ledger.invalidateSettingsCheck()
            }
        }
        changed()
    }
    private func completed(_ method: RecognitionMethod, _ result: EngineHealthResult) {
        if method == .local, let id = LocalModelID(rawValue: facts.localRoute) { local.checked(id, result: result) }
        guard tracksOnlineHealthChecks, method == .online, let generation = ledgerGeneration else { return }
        ledgerGeneration = nil
        let outcome: CloudConnectionCheck.Outcome
        switch result {
        case .passed: outcome = .connected
        case .failed(.notNetworkVerified): ledger.invalidateSettingsCheck(); return
        case .failed(.noKey): outcome = .failed(.noKey)
        case .failed(.invalidKey): outcome = .failed(.rejectedKey)
        case .failed(.network): outcome = .failed(.network)
        case .failed(.timeout): outcome = .failed(.timeout)
        case .failed(.freeQuotaExhausted):
            onCloudAuthorizationClosed?()
            outcome = .failed(.freeQuotaExhausted)
        case .failed(.noAccess): outcome = .failed(.noAccess)
        case .failed(.balanceDue): outcome = .failed(.balanceDue)
        case .failed(.rateLimited): outcome = .failed(.rateLimited)
        case .failed(.modelUnavailable): outcome = .failed(.modelUnavailable)
        case .failed(.serviceUnavailable): outcome = .failed(.serviceUnavailable)
        case .failed(.worker): outcome = .failed(.worker)
        case .failed(.taskStartFailed): outcome = .failed(.taskStartFailed)
        case .failed(.notClosed): outcome = .failed(.notClosed)
        case .failed: outcome = .failed(.unknown)
        }
        ledger.completeSettingsCheck(outcome, generation: generation)
    }
}

/// Exercises the production bridge using safe fixtures and the real public input-source API. Never reads credentials.
@MainActor enum SettingsLogicRuntimeProbe {
    private final class ControlledProvider: EngineHealthProviding {
        var onlineCalls = 0
        var pending: CheckedContinuation<EngineHealthResult, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?
        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func check(_ method: RecognitionMethod) async -> EngineHealthResult {
            if method != .online { return .passed(.publicInputSource) }
            onlineCalls += 1
            return await withCheckedContinuation {
                pending = $0; startWaiter?.resume(); startWaiter = nil
            }
        }
        func finish(_ result: EngineHealthResult) { let continuation = pending; pending = nil; continuation?.resume(returning: result) }
    }
    private final class Ledger: SettingsConnectionLedgerBridge {
        var value = OnlineConnectionCheckLedger()
        var begins = 0, completions = 0, invalidations = 0
        var settingsConnectionState: OnlineConnectionCheckState { value.state }
        func beginConnectionCheck() -> UUID { begins += 1; return value.begin() }
        func completeSettingsCheck(_ outcome: CloudConnectionCheck.Outcome, generation: UUID) { completions += 1; value.complete(outcome, generation: generation) }
        func invalidateSettingsCheck() { invalidations += 1; value.invalidate() }
    }
    /// Only synthetic dependencies. Automatic presence refresh must preserve a
    /// passed, running or failed explicit connection check without new I/O.
    static func runPresenceOnlyConnectionChecks() async -> Bool {
        var passed = true
        for scenario in 0..<3 {
            let provider = ControlledProvider(), ledger = Ledger(), epoch = UUID()
            let token = ledger.value.begin()
            if scenario == 0 { ledger.value.complete(.connected, generation: token) }
            if scenario == 2 { ledger.value.complete(.failed(.network), generation: token) }
            let original = ledger.settingsConnectionState
            var enhancement = false
            let source = OnlineEnhancementPreferenceSource(read: { enhancement }, write: { enhancement = $0 })
            let runtime = SettingsLogicRuntime(provider: provider, enhancement: source, ledger: ledger,
                hardware: .init(memoryBytes: 16 << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true),
                tracksOnlineHealthChecks: false, readLabel: { nil }, writeLabel: { _ in },
                credentialEpoch: { epoch }, log: { _ in })
            runtime.inspect(.online)
            await provider.waitUntilStarted()
            passed = passed && ledger.settingsConnectionState == original && ledger.begins == 0
            let completed = runtime.health.onResult
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                runtime.health.onResult = { method, result in
                    completed?(method, result); continuation.resume()
                }
                provider.finish(.failed(.notNetworkVerified))
            }
            passed = passed && ledger.settingsConnectionState == original && ledger.completions == 0
                && ledger.invalidations == 0 && !enhancement
            // An explicit key change must still invalidate an old connection.
            runtime.configurationWillChange()
            passed = passed && ledger.settingsConnectionState == .idle && ledger.invalidations == 1
        }
        print("F4_PRESENCE_REFRESH_CHECKS passed=\(passed ? 1 : 0)")
        return passed
    }
    static func run() async -> Bool {
        let connectionLedgerPassed = await runPresenceOnlyConnectionChecks()
        let automaticOnlinePassed = await runAutomaticOnlineChecks()
        let automaticLearningPassed = await CorrectionLearningRuntime.runAutomaticLearningProbe()
        let automaticPassed = automaticOnlinePassed && automaticLearningPassed && CorrectionLearningRuntime.runAuthorizationProbe()
        let presentationPassed = SettingsPresentationProbe.run() && FirstRunView.runPresentationProbe()
        var enabled = false
        var savedLabel: String?
        var logs: [String] = []
        let source = OnlineEnhancementPreferenceSource(read: { enabled }, write: { enabled = $0 })
        let provider = RecognitionHealthProvider(online: AliyunOnlineAPIProvider(), doubao: { .init(installed: true, enabledInSystem: true) },
                                                local: { .passed(.localContainerLoadable) }, credential: { .saved })
        let ledger = Ledger()
        let runtime = SettingsLogicRuntime(provider: provider, enhancement: source, ledger: ledger,
            hardware: .init(memoryBytes: 16 << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true),
            readLabel: { savedLabel }, writeLabel: { savedLabel = $0 }, log: { logs.append($0) })
        let page = CloudEntryPageState(isVisible: true, key: .saved, isLoaded: true)
        let selection = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "zh")
        var notifications = 0
        runtime.onNotification = {
            notifications += 1
            if notifications < 40 {
                // Same call chain as the real menu: update safe facts, project from the shared VM.
                runtime.update(page: page, selection: selection)
                _ = runtime.menu.onlineState(loaded: true, credentialChanging: false, preferences: .init(),
                    admission: .unconfirmed, ledger: ledger.settingsConnectionState, selection: selection)
            }
        }
        runtime.update(page: page, selection: selection)
        let beforeRepeated = notifications
        for _ in 0..<100 { runtime.update(page: page, selection: selection); source.synchronize() }
        let stableNotifications = notifications == beforeRepeated
        runtime.saveUserLabel("Fixture Label")
        let changedNotifications = notifications > beforeRepeated
        runtime.update(page: page, selection: selection) // Both old settings and menu omit the label.
        let preservedLabel = savedLabel == "Fixture Label" && runtime.online.userLabel == "Fixture Label"
        runtime.update(page: page, selection: selection, label: nil)
        let explicitClear = runtime.online.userLabel == nil
        runtime.saveUserLabel("Fixture Label")
        runtime.saveUserLabel(nil) // Credential-removal uses the same explicit clear path.
        let removedLabel = savedLabel == nil && runtime.online.userLabel == nil
        runtime.online.setEnhancementFromUser(true, authorized: true)
        let mirrored = runtime.options.online.enhanceLocalWithOnlineAPI && runtime.menu.options.online.enhanceLocalWithOnlineAPI
        runtime.options.online.setEnhancementFromUser(false, authorized: false)
        runtime.inspect(.online)
        for _ in 0..<30 { await Task.yield() }
        let shared = runtime.menu.options.health === runtime.health && runtime.options.online === runtime.online
        let unverified = runtime.health.current == EngineHealthResult.failed(.notNetworkVerified).state && ledger.settingsConnectionState == .idle
        let publicResult = DoubaoPublicInspector.inspect()
        let safeLog = publicResult.logLine.range(of: "^event=public_input_source,installed=[01],matches=[0-9]+,available=[01],enabled=[01]$", options: .regularExpression) != nil
        let controlled = ControlledProvider(), secondLedger = Ledger()
        var epoch = UUID(), stopped = 0
        let second = SettingsLogicRuntime(provider: controlled, enhancement: source, ledger: secondLedger,
            hardware: .init(memoryBytes: 16 << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true),
            readLabel: { nil }, writeLabel: { _ in }, credentialEpoch: { epoch }, log: { logs.append($0) })
        let oldPage = CloudEntryPageState(isVisible: true, key: .saved, isLoaded: true, credentialEpoch: epoch)
        second.update(page: oldPage, selection: selection, label: "Current")
        epoch = UUID()
        let beforeStale = second.revision
        second.update(page: oldPage, selection: selection, label: "Stale")
        let epochFenced = second.revision == beforeStale && second.online.userLabel == "Current"
        second.inspect(.online); for _ in 0..<30 { await Task.yield() }
        second.configurationWillChange()
        controlled.finish(.passed(.providerVerified)); for _ in 0..<30 { await Task.yield() }
        let oldCheckDiscarded = secondLedger.settingsConnectionState == .idle && second.health.states[.online] == .idle
        second.online.setEnhancementFromUser(true, authorized: true)
        second.onCloudAuthorizationClosed = { stopped += 1 }
        second.inspect(.online); for _ in 0..<30 { await Task.yield() }
        controlled.finish(.failed(.freeQuotaExhausted)); for _ in 0..<30 { await Task.yield() }
        let quotaClosed = enabled && stopped == 1 && secondLedger.settingsConnectionState == .failed(.freeQuotaExhausted)
        second.online.setEnhancementFromUser(false, authorized: false)
        print(publicResult.logLine)
        let passed = automaticPassed && connectionLedgerPassed && presentationPassed && mirrored && !enabled && shared && unverified && safeLog && stableNotifications && changedNotifications
            && preservedLabel && explicitClear && removedLabel && epochFenced && oldCheckDiscarded && quotaClosed
            && logs.allSatisfy(SettingsHealthLog.isWhitelisted)
        print("event=settings_runtime_probe,shared=\(shared ? 1 : 0),unverified=\(unverified ? 1 : 0),stable=\(stableNotifications ? 1 : 0),labels=\(preservedLabel && explicitClear && removedLabel ? 1 : 0),epoch=\(epochFenced && oldCheckDiscarded ? 1 : 0),quota=\(quotaClosed ? 1 : 0),passed=\(passed ? 1 : 0)")
        return passed
    }
    /// Drives the production event policy with a fake page, provider and ledger. No credential access or I/O.
    private static func runAutomaticOnlineChecks() async -> Bool {
        let provider = ControlledProvider(), ledger = Ledger(), epoch = UUID()
        var enhancement = true
        let source = OnlineEnhancementPreferenceSource(read: { enhancement }, write: { enhancement = $0 })
        let runtime = SettingsLogicRuntime(provider: provider, enhancement: source, ledger: ledger,
            hardware: .init(memoryBytes: 16 << 30, availableDiskBytes: 20 << 30, isAppleSilicon: true),
            automaticOnlineChecks: true,
            pageState: { .init(isVisible: true, key: .saved, isLoaded: true, credentialEpoch: epoch) },
            readLabel: { nil }, writeLabel: { _ in }, credentialEpoch: { epoch }, log: { _ in })
        let online = try! VoiceInputSelection(mode: .voiceNative, routeID: CloudEntry.routeID, language: "zh")
        let local = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "zh")
        await runtime.refresh(selection: online, trigger: .launch)
        for _ in 0..<30 { await Task.yield() }
        var passed = provider.onlineCalls == 0
        runtime.scheduleRefresh(selection: local, trigger: .settingsOpened)
        // App activation can supersede the page refresh, but must not lose the opening event.
        runtime.scheduleRefresh(selection: local, trigger: .foreground)
        await provider.waitUntilStarted()
        passed = passed && provider.onlineCalls == 1 && runtime.health.states[.online] == .checking
            && runtime.options.selected == .local && ledger.settingsConnectionState == .running
        runtime.inspect(.doubao)
        provider.finish(.passed(.providerVerified))
        for _ in 0..<30 { await Task.yield() }
        passed = passed && runtime.options.selected == .doubao && runtime.health.states[.online] == .passed(detail: .providerVerified)
        await runtime.refresh(selection: online, trigger: .foreground)
        for _ in 0..<30 { await Task.yield() }
        passed = passed && provider.onlineCalls == 1 && enhancement
        // Both a Key replacement and a model replacement go through this invalidation boundary.
        for failure in [HealthFailureReason.noAccess, .network] {
            runtime.configurationWillChange(); runtime.configurationDidChange()
            await provider.waitUntilStarted()
            provider.finish(.failed(failure))
            for _ in 0..<30 { await Task.yield() }
            passed = passed && runtime.health.states[.online] == EngineHealthResult.failed(failure).state
        }
        passed = passed && provider.onlineCalls == 3
        runtime.recheckOnline() // Explicit recheck dispatches; reopening now retains the recent cached result.
        await provider.waitUntilStarted()
        runtime.configurationWillChange()
        provider.finish(.passed(.providerVerified))
        for _ in 0..<30 { await Task.yield() }
        passed = passed && runtime.health.states[.online] == .idle && ledger.settingsConnectionState == .idle
        let unverified = EngineHealthResult.failed(.notNetworkVerified).state
        let neutral: Bool
        if case .neutral = SettingsTone(unverified) { neutral = true } else { neutral = false }
        passed = passed && neutral && SettingsStrings.status(unverified).isEmpty
            && SettingsStrings.status(.failed(reason: .noAccess, nextAction: .providerConsole)) == "不可用 · " + HealthFailureReason.noAccess.message
        print("ONLINE_HEALTH_EVENT_CHECKS calls=\(provider.onlineCalls),passed=\(passed ? 1 : 0)")
        return passed
    }
}

/// Same static fixtures and policy used by the visible native host and production page. No live services.
@MainActor private enum SettingsPresentationProbe {
    static func run() -> Bool {
        var passed = true, cases = 0
        let emptyLexicon = LexiconSettingsPresentation(termCount: 0, pendingCount: 0)
        let reviewedLexicon = LexiconSettingsPresentation(termCount: 3, pendingCount: 2)
        // 2026-11-07: every page now shows only its own name on top (SettingsPageBody); the lexicon has no extra header.
        let lexiconHeaderIsPageOnly = SettingsPage.lexicon.title == SettingsStrings.settingsRootViewCopy004
        let lexiconCopyAndLimits = SettingsStrings.lexiconSettingsPageCopy018 == "识别时会优先带上最常用的一批词"
            && SettingsStrings.lexiconTermCountSummary(emptyLexicon.termCount) == "词库共 0 条"
            && SettingsStrings.lexiconTermCountSummary(reviewedLexicon.termCount) == "词库共 3 条"
            && SettingsStrings.lexiconSettingsPageCopy033 == "手动添加词条"
            && SettingsStrings.lexiconSettingsPageCopy036 == "待确认纠错"
            && SettingsStrings.lexiconHotwordHelp.contains("\(LexiconLimits.maxTerms) 条")
            && SettingsStrings.lexiconHotwordHelp.contains("约 \(RecognitionHotwords.maximumTerms) 个")
            && !SettingsStrings.lexiconSettingsPageCopy018.contains("最多 32 个")
        let lexiconSectionsAndLimits = emptyLexicon.pendingSection == nil
            && reviewedLexicon.pendingSection?.badgeCount == 2
            && !LexiconSettingsPresentation.manualAddDisclosureExpandedByDefault
            && !LexiconSettingsPresentation.pendingDisclosureExpandedByDefault
            && LexiconLimits.maxTerms == 2_000
            && CorrectionLedger.maximumEntries == 30
            && RecognitionHotwords.maximumTerms == 32
        passed = passed && lexiconCopyAndLimits && lexiconSectionsAndLimits && lexiconHeaderIsPageOnly
        let learningCopy = SettingsStrings.learningSection == "学习"
            && SettingsStrings.enhancementLearning == "增强学习"
            && SettingsStrings.enhancementLearningExplanation.contains("豆包给出的词")
            && SettingsStrings.enhancementDetail.contains("只记词，不存整句")
            && SettingsStrings.enhancementLearningUnavailable.contains("本地复核")
            && SettingsStrings.doubaoLearningPrivacy == "听写时本 app 会在本机处理一份你的声音（不保存、不上传）"
            && SettingsStrings.lexiconSettingsPageCopy019 != SettingsStrings.enhancementLearning
        passed = passed && learningCopy
        cases += 2
        let phases: [SettingsLoadState] = [.idle, .loading, .empty, .error, .content]
        var dataFixturesPassed = SettingsPage.sidebarPages == [.voice, .appearance, .gestures, .lexicon, .general, .data]
        let dataFixtureIDs: [ManagedDataID] = [.model17, .model06, .punctuation, .modelDownloads, .touchSamples]
        for phase in phases {
            let fixture = SettingsReviewContext(page: .data, phase: phase)
            let vm = fixture.logic.data
            dataFixturesPassed = dataFixturesPassed && fixture.logic.dataRuntime == nil && vm.phase == phase
                && (phase == .empty ? vm.items.isEmpty : vm.items.map(\.id) == dataFixtureIDs)
                && (phase == .error ? vm.failure == .inventory : vm.failure == nil)
            if phase == .content {
                let detail = SettingsStrings.dataRemovalDetail(vm.items, total: vm.totalBytes)
                dataFixturesPassed = dataFixturesPassed && detail.contains(SettingsStrings.dataSize(vm.totalBytes))
                    && vm.items.allSatisfy { detail.contains(SettingsStrings.dataName($0.id)) }
            }
            cases += 1
        }
        passed = passed && dataFixturesPassed
        for method in RecognitionMethod.allCases {
            for phase in phases {
                let fixture = SettingsReviewContext(method: method, phase: phase, configured: phase != .empty)
                let p = RecognitionSettingsPresentation(method: method, installed: fixture.logic.doubao.installed,
                    enabledInSystem: fixture.logic.doubao.enabledInSystem, models: fixture.logic.local.models,
                    keySaved: fixture.logic.online.keySaved)
                passed = passed && [p.showsDoubaoControls, p.showsLocalControls, p.showsOnlineControls].filter { $0 }.count == 1
                passed = passed && p.showsDoubaoControls == (method == .doubao)
                    && p.showsLocalControls == (method == .local) && p.showsOnlineControls == (method == .online)
                if phase == .empty {
                    passed = passed && p.showsGuide && p.emptyAction != nil && !p.statusActionIsPrimary
                    let url = method == .doubao ? SettingsStrings.doubaoDocumentationURL
                        : method == .local ? SettingsStrings.modelDocumentationURL : fixture.logic.online.provider.docURL
                    passed = passed && url.scheme == "https" && !(url.host ?? "").isEmpty
                }
                cases += 1
            }
        }
        for method in RecognitionMethod.allCases {
            for state in [EngineHealthState.checking, .passed(detail: method == .local ? .localContainerLoadable : .providerVerified),
                          .failed(reason: .network, nextAction: .retryNetwork)] {
                passed = passed && (state == .checking ? SettingsStrings.status(state).isEmpty : !SettingsStrings.status(state).isEmpty)
                    && !SettingsStrings.detail(state, provider: "Synthetic Provider").isEmpty
                cases += 1
            }
        }
        // This wording is about local recognition accuracy, independent of online connection health.
        passed = passed && SettingsStrings.localContainerPassed.contains("还没用过")
            && SettingsStrings.onlineTitle("Synthetic Long Provider Label").contains("Synthetic Long Provider Label")
        let lowMemory = SettingsReviewContext(method: .local, memoryGB: 8)
        passed = passed && lowMemory.logic.local.models.contains { $0.id == .qwen17 && $0.state == .notApplicable(reason: .hardwareUnsuitable) }
        print("event=settings_presentation_probe,cases=\(cases),empty_actions=3,lexicon_copy=\(lexiconCopyAndLimits ? 1 : 0),lexicon_sections=\(lexiconSectionsAndLimits ? 1 : 0),lexicon_header=\(lexiconHeaderIsPageOnly ? 1 : 0),data=\(dataFixturesPassed ? 1 : 0),passed=\(passed ? 1 : 0)")
        return passed
    }
}
