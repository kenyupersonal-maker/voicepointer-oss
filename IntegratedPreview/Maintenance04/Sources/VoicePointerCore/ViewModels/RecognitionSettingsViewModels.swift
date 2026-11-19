// T4 2026-10-02: State/fixture layer; download/delete services are injected, T4 never cleans user data.
import Foundation

@MainActor public final class RecognitionOptionsViewModel {
    public private(set) var selected: RecognitionMethod
    public private(set) var phase: SettingsLoadState = .idle
    public let health: EngineHealthCheckViewModel
    public let online: OnlineAPIConfigViewModel
    public init(selected: RecognitionMethod = .doubao, health: EngineHealthCheckViewModel, online: OnlineAPIConfigViewModel) {
        self.selected = selected; self.health = health; self.online = online
    }
    public var visibleSettings: RecognitionMethod { selected }
    public var methods: [RecognitionMethod] { RecognitionMethod.allCases }
    public var states: [RecognitionMethod: EngineHealthState] { health.states }
    public var onlineTitle: String { online.recognitionTitle }
    public var enhancementEffective: Bool { online.enhancement.isEffective(method: selected, configured: online.isConfigured) }
    public func select(_ method: RecognitionMethod, trigger: HealthCheckTrigger = .selection, checkHealth: Bool = true) {
        selected = method; phase = .content
        if checkHealth { health.check(method, trigger: trigger) } else { health.selectWithoutChecking(method) }
    }
    public func applyFixture(phase: SettingsLoadState) { self.phase = phase }
    public static func method(for selection: VoiceInputSelection) -> RecognitionMethod {
        selection.mode == .doubao ? .doubao : OnlineAPIConfiguration.cloudRouteIDs.contains(selection.routeID) ? .online : .local
    }
}

public enum LocalModelID: String, Codable, Sendable, CaseIterable {
    case qwen17 = "qwen17-rolling", qwen06 = "qwen06-rolling"
    public var name: String { self == .qwen17 ? "千问 1.7B" : "千问 0.6B" }
}
public struct SettingsHardwareInfo: Sendable, Equatable {
    public var memoryBytes: UInt64
    public var availableDiskBytes: UInt64
    public var isAppleSilicon: Bool
    public var chipModel: String
    public init(memoryBytes: UInt64, availableDiskBytes: UInt64, isAppleSilicon: Bool, chipModel: String = "unknown") {
        self.memoryBytes = memoryBytes; self.availableDiskBytes = availableDiskBytes; self.isAppleSilicon = isAppleSilicon; self.chipModel = chipModel
    }
    /// Conservative preparation policy, not a throughput/accuracy claim. T10 may refine measured thresholds.
    public func supports(_ id: LocalModelID, downloadBytes: UInt64 = 0, policy: ModelHardwarePolicy = .init()) -> Bool {
        isAppleSilicon && memoryBytes >= (id == .qwen17 ? policy.model17MinimumBytes : policy.model06MinimumBytes)
            && availableDiskBytes >= downloadBytes + policy.diskReserveBytes
    }
}
public struct ModelHardwarePolicy: Sendable {
    public var model17MinimumBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
    public var model06MinimumBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    public var diskReserveBytes: UInt64 = 512 * 1_024 * 1_024
    public init() {}
    public func recommended(on hardware: SettingsHardwareInfo) -> LocalModelID? {
        hardware.supports(.qwen17, policy: self) ? .qwen17 : hardware.supports(.qwen06, policy: self) ? .qwen06 : nil
    }
}
public enum LocalModelState: Sendable, Equatable {
    case notDownloaded, downloading(progress: Double), ready, needsVerification
    case converting, verifying
    case notApplicable(reason: HealthFailureReason), corrupt
    public var isInstalling: Bool {
        switch self { case .downloading, .converting, .verifying: true; default: false }
    }
}
public enum LocalModelAction: String, Sendable { case download, cancel, delete, use, deleteOriginal, keepOriginal }
public struct LocalModelItem: Sendable, Equatable {
    public let id: LocalModelID
    public var sizeBytes: UInt64
    public var recommended: Bool
    public var state: LocalModelState
    public var downloadBytes: UInt64?
    public var conversionOutputBytes: UInt64?
    public var requiredSpaceBytes: UInt64?
    public var libraryInstalled: Bool = false
    public var remainingSeconds: TimeInterval?
    public var originalDownloadBytes: UInt64?
    public var offersOriginalRemoval = false
    public var name: String { id.name }
    public init(id: LocalModelID, sizeBytes: UInt64, recommended: Bool, state: LocalModelState,
                downloadBytes: UInt64? = nil, conversionOutputBytes: UInt64? = nil, requiredSpaceBytes: UInt64? = nil, libraryInstalled: Bool = false) {
        self.id = id; self.sizeBytes = sizeBytes; self.recommended = recommended; self.state = state
        self.downloadBytes = downloadBytes; self.conversionOutputBytes = conversionOutputBytes; self.requiredSpaceBytes = requiredSpaceBytes
        self.libraryInstalled = libraryInstalled
    }
    public var actions: [LocalModelAction] {
        switch state {
        case .notDownloaded: [.download]
        case .downloading, .converting, .verifying: [.cancel]
        case .ready: [.use, .delete] + (originalDownloadBytes == nil ? [] : [.deleteOriginal, .keepOriginal])
        case .needsVerification: [.use, .delete]
        case .notApplicable: []
        case .corrupt: [.download, .delete]
        }
    }
}
@MainActor public protocol LocalModelManaging {
    func download(_ id: LocalModelID, progress: @escaping @MainActor (Double) -> Void) async throws
    func download(_ id: LocalModelID, progress: @escaping @MainActor (Double) -> Void,
                  stage: @escaping @MainActor (ModelDownloadStage) -> Void) async throws
    func cancel(_ id: LocalModelID)
    /// An implementation must move only its app-owned directory to Trash; T10/T12 supply the implementation.
    func moveToTrash(_ id: LocalModelID) async throws
    func use(_ id: LocalModelID) async throws
    func stateAfterAction(_ id: LocalModelID, action: LocalModelAction) -> LocalModelState?
    func originalDownloadInfo(_ id: LocalModelID) async -> (bytes: UInt64?, offer: Bool)
    func removeOriginalDownload(_ id: LocalModelID) async throws
    func keepOriginalDownload(_ id: LocalModelID)
    func installedModelBytes(_ id: LocalModelID) -> UInt64?
}
public extension LocalModelManaging {
    func originalDownloadInfo(_ id: LocalModelID) async -> (bytes: UInt64?, offer: Bool) { (nil, false) }
    func removeOriginalDownload(_ id: LocalModelID) async throws { throw ModelDownloadError.sourceUnavailable }
    func keepOriginalDownload(_ id: LocalModelID) {}
    func installedModelBytes(_ id: LocalModelID) -> UInt64? { nil }
    func download(_ id: LocalModelID, progress: @escaping @MainActor (Double) -> Void,
                  stage: @escaping @MainActor (ModelDownloadStage) -> Void) async throws {
        stage(.downloading); try await download(id, progress: progress)
    }
    func stateAfterAction(_ id: LocalModelID, action: LocalModelAction) -> LocalModelState? { nil }
}
@MainActor public final class LocalModelInstallerViewModel {
    public private(set) var phase: SettingsLoadState = .idle
    public private(set) var models: [LocalModelItem] = []
    public private(set) var hardware: SettingsHardwareInfo
    public var onChange: (() -> Void)?
    private let manager: (any LocalModelManaging)?
    private var tasks: [LocalModelID: Task<Void, Never>] = [:]
    private var generations: [LocalModelID: UInt64] = [:]
    public private(set) var downloadError: ModelDownloadError?
    public init(hardware: SettingsHardwareInfo, manager: (any LocalModelManaging)? = nil) { self.hardware = hardware; self.manager = manager }
    public var recommendedModels: [LocalModelItem] { models.filter { hardware.supports($0.id) } }
    public func update(models: [LocalModelItem], hardware: SettingsHardwareInfo? = nil) {
        self.models = models.map { incoming in
            if let current = self.models.first(where: { $0.id == incoming.id }), current.state.isInstalling { return current }
            return incoming
        }; if let hardware { self.hardware = hardware }
        phase = models.isEmpty ? .empty : .content; onChange?()
    }
    public func checked(_ id: LocalModelID, result: EngineHealthResult) {
        guard let i = models.firstIndex(where: { $0.id == id }) else { return }
        guard !models[i].state.isInstalling else { return }
        if models[i].libraryInstalled, result == .failed(.modelNotDownloaded) { models[i].state = .needsVerification; onChange?(); return }
        switch result {
        case .passed: models[i].state = .ready
        case .failed(.modelNotDownloaded): models[i].state = .notDownloaded
        case .failed(.hardwareUnsuitable): models[i].state = .notApplicable(reason: .hardwareUnsuitable)
        case .failed(.modelCorrupt): models[i].state = .corrupt
        case .failed: models[i].state = .needsVerification
        }
        onChange?()
    }
    public func perform(_ action: LocalModelAction, id: LocalModelID, consent: Bool = false) {
        if action == .download, !consent { downloadError = .consentRequired; onChange?(); return }
        if action == .download, tasks[id] != nil { return }
        guard let row = models.first(where: { $0.id == id }), row.actions.contains(action), let manager else { phase = .error; onChange?(); return }
        downloadError = nil
        generations[id, default: 0] &+= 1
        let token = generations[id, default: 0]
        let downloadStarted = ProcessInfo.processInfo.systemUptime
        if action == .cancel {
            tasks[id]?.cancel(); tasks[id] = nil; manager.cancel(id); set(id, state: .notDownloaded); phase = .content; return
        }
        phase = .loading
        if action == .download { set(id, state: .downloading(progress: 0)) }
        tasks[id] = Task { [weak self] in
            do {
                switch action {
                case .download:
                    try await manager.download(id, progress: { [weak self] progress in
                        guard self?.generations[id] == token else { return }
                        guard let state = self?.models.first(where: { $0.id == id })?.state, case .downloading = state else { return }
                        self?.set(id, state: .downloading(progress: min(1, max(0, progress))))
                        if progress > 0.001, progress < 1, let i = self?.models.firstIndex(where: { $0.id == id }) {
                            self?.models[i].remainingSeconds = (ProcessInfo.processInfo.systemUptime - downloadStarted) * (1 - progress) / progress
                        }
                    }, stage: { [weak self] stage in
                        guard self?.generations[id] == token else { return }
                        switch stage { case .downloading: self?.set(id, state: .downloading(progress: 0))
                        case .converting: self?.set(id, state: .converting)
                        case .verifying: self?.set(id, state: .verifying) }
                    })
                case .delete: try await manager.moveToTrash(id)
                case .use: try await manager.use(id)
                case .deleteOriginal: try await manager.removeOriginalDownload(id)
                case .keepOriginal: manager.keepOriginalDownload(id)
                case .cancel: break
                }
                guard let self, !Task.isCancelled, self.generations[id] == token else { return }
                self.generations[id, default: 0] &+= 1 // Fence queued progress/stage callbacks after completion.
                self.set(id, state: manager.stateAfterAction(id, action: action)
                    ?? (action == .delete ? .notDownloaded : action == .download ? .needsVerification : row.state))
                if let i = self.models.firstIndex(where: { $0.id == id }) {
                    if action == .download {
                        self.models[i].libraryInstalled = true
                        self.models[i].sizeBytes = manager.installedModelBytes(id) ?? row.conversionOutputBytes ?? row.sizeBytes
                    }
                    if action == .delete { self.models[i].libraryInstalled = false }
                    let original = await manager.originalDownloadInfo(id)
                    guard !Task.isCancelled, self.generations[id] == (token &+ 1), self.models.indices.contains(i), self.models[i].id == id else { return }
                    self.models[i].originalDownloadBytes = original.bytes
                    self.models[i].offersOriginalRemoval = original.offer
                    self.models[i].remainingSeconds = nil
                }
                self.tasks[id] = nil; self.phase = .content; self.onChange?()
            } catch {
                guard let self, !Task.isCancelled, self.generations[id] == token else { return }
                self.generations[id, default: 0] &+= 1
                self.tasks[id] = nil; self.downloadError = error as? ModelDownloadError ?? .io
                self.set(id, state: row.state); self.phase = .error; self.onChange?()
            }
        }
    }
    public func cancelDownloads() {
        for id in LocalModelID.allCases where tasks[id] != nil {
            generations[id, default: 0] &+= 1; tasks[id]?.cancel(); tasks[id] = nil; manager?.cancel(id)
            set(id, state: .notDownloaded)
        }
        phase = models.isEmpty ? .empty : .content; onChange?()
    }
    public func cancelDownloadsAndWait() async {
        let pending = Array(tasks.values)
        cancelDownloads()
        for task in pending { await task.value }
    }
    private func set(_ id: LocalModelID, state: LocalModelState) {
        if let i = models.firstIndex(where: { $0.id == id }) { models[i].state = state }; onChange?()
    }
    public func applyFixture(phase: SettingsLoadState) { self.phase = phase }
}

@MainActor public final class DoubaoSetupViewModel {
    public private(set) var phase: SettingsLoadState = .idle
    public private(set) var installed = false
    public private(set) var enabledInSystem: Bool?
    public let steps: [HealthNextAction] = [.installDoubao, .enableSystemInput]
    public let hint = "按下说话没有反应时，请在豆包里打开它的语音输入（这一项我们读不到）"
    public init() {}
    public func update(_ detection: DoubaoDetection) {
        installed = detection.installed; enabledInSystem = detection.enabledInSystem
        phase = !installed ? .empty : enabledInSystem == nil ? .error : .content
    }
    public func applyFixture(phase: SettingsLoadState) { self.phase = phase }
}
public enum SettingsPermission: String, Sendable, CaseIterable { case microphone, accessibility, inputMonitoring }
public enum SettingsPermissionStatus: String, Sendable { case granted, denied, unknown }
@MainActor public final class PermissionsViewModel {
    public private(set) var phase: SettingsLoadState = .idle
    public private(set) var statuses: [SettingsPermission: SettingsPermissionStatus] = [:]
    public var onChange: (() -> Void)?
    public init() {}
    public func update(_ statuses: [SettingsPermission: SettingsPermissionStatus]) {
        let nextPhase: SettingsLoadState = statuses.isEmpty ? .empty : statuses.values.contains(.unknown) ? .error : .content
        guard self.statuses != statuses || phase != nextPhase else { return }
        self.statuses = statuses
        phase = nextPhase
        onChange?()
    }
    public func applyFixture(phase: SettingsLoadState) { self.phase = phase }
}
public enum ManagedDataID: String, Sendable, CaseIterable { case model17, model06, punctuation, modelDownloads, diagnosticLogs, touchSamples, personalLexicon }
public struct ManagedDataItem: Sendable, Equatable {
    public let id: ManagedDataID
    public let sizeBytes: UInt64
    public init(id: ManagedDataID, sizeBytes: UInt64) { self.id = id; self.sizeBytes = sizeBytes }
}
public enum DataRemovalConfirmation: Sendable, Equatable { case none, requested, confirmed }
@MainActor public final class DataManagementViewModel {
    public private(set) var phase: SettingsLoadState = .idle
    public private(set) var items: [ManagedDataItem] = []
    public private(set) var confirmation: DataRemovalConfirmation = .none
    public private(set) var failure: AppDataFailure?
    public private(set) var totalBytes: UInt64 = 0
    public var onChange: (() -> Void)?
    private let inventory: (() async throws -> AppDataSummary)?
    private let clear: (() async throws -> Void)?
    private let deleteItem: ((ManagedDataID) async throws -> Void)?
    private let prepareUninstall: (() async throws -> Void)?
    public init(inventory: (() async throws -> AppDataSummary)? = nil,
                deleteItem: ((ManagedDataID) async throws -> Void)? = nil, clearLexicon: (() async throws -> Void)? = nil,
                prepareUninstall: (() async throws -> Void)? = nil) {
        self.deleteItem = deleteItem; self.prepareUninstall = prepareUninstall
        self.inventory = inventory; clear = clearLexicon
    }
    public func update(_ items: [ManagedDataItem], totalBytes: UInt64? = nil) {
        self.items = items; self.totalBytes = totalBytes ?? items.reduce(0) { $0 + $1.sizeBytes }
        phase = items.isEmpty ? .empty : .content; failure = nil; onChange?()
    }
    public func refresh() async {
        guard phase != .loading, confirmation != .confirmed, let inventory else { return }
        phase = .loading; failure = nil; onChange?()
        do { let result = try await inventory(); update(result.items, totalBytes: result.totalBytes) }
        catch { fail(error) }
    }
    public func delete(_ id: ManagedDataID) async {
        guard phase != .loading, confirmation == .none else { return }
        guard items.contains(where: { $0.id == id }), let deleteItem else { fail(AppDataFailure.removal); return }
        phase = .loading; failure = nil; onChange?()
        do {
            try await deleteItem(id)
            if let inventory { let result = try await inventory(); update(result.items, totalBytes: result.totalBytes) }
            else { update(items.filter { $0.id != id }) }
        } catch { fail(error) }
    }
    public func clearLexicon() async {
        guard phase != .loading, confirmation == .none, let clear else { return }
        phase = .loading; failure = nil; onChange?()
        do {
            try await clear()
            if let inventory { let result = try await inventory(); update(result.items, totalBytes: result.totalBytes) }
            else { update(items.filter { $0.id != .personalLexicon }) }
        } catch { fail(error) }
    }
    public func requestUninstall() {
        guard phase != .loading, confirmation != .confirmed else { return }
        confirmation = .requested; onChange?()
    }
    public func cancelUninstall() { guard confirmation == .requested else { return }; confirmation = .none; onChange?() }
    public func confirmUninstall() async {
        guard confirmation == .requested, let prepareUninstall else { return }
        confirmation = .confirmed; phase = .loading; failure = nil; onChange?()
        do { try await prepareUninstall(); items = []; totalBytes = 0; phase = .empty; onChange?() }
        catch { confirmation = .none; fail(error) }
    }
    private func fail(_ error: Error) { failure = error as? AppDataFailure ?? .removal; phase = .error; onChange?() }
    public func applyFixture(phase: SettingsLoadState) { self.phase = phase; failure = phase == .error ? .inventory : nil; onChange?() }
}

/// Menu projection uses the same config/health objects as settings; T2's admission/persistence policy is retained.
@MainActor public final class MenuBarStatusViewModel {
    public private(set) var phase: SettingsLoadState = .idle
    public let options: RecognitionOptionsViewModel
    public private(set) var localPreparation: [LocalModelID: Bool] = [:]
    public private(set) var localHealth: [LocalModelID: EngineHealthState] = [:]
    public var onChange: (() -> Void)?
    public init(options: RecognitionOptionsViewModel) { self.options = options }
    public func onlineState(loaded: Bool, credentialChanging: Bool, preferences: CloudEntryPreferences,
                            admission: CloudEntryStatus, ledger: OnlineConnectionCheckState, selection: VoiceInputSelection?) -> OnlineRouteMenuState {
        OnlineRouteMenuState(loaded: loaded, keySaved: options.online.keySaved, credentialChanging: credentialChanging,
                             preferences: preferences, status: admission, check: ledger, selection: selection,
                             label: options.online.displayName)
    }
    public func title(for method: RecognitionMethod, engine: LocalModelID? = nil) -> String {
        let base = method == .doubao ? "豆包输入法" : method == .local ? "本地识别 · \((engine ?? .qwen06).name)" : options.online.recognitionTitle
        let state = method == .local ? localHealth[engine ?? .qwen06] : options.states[method]
        guard let state, !state.statusTitle.isEmpty else { return base }
        return base + " · " + state.statusTitle
    }
    public func isSelected(_ method: RecognitionMethod, selection: VoiceInputSelection?) -> Bool {
        selection.map { RecognitionOptionsViewModel.method(for: $0) == method } ?? false
    }
    public func updateLocalPreparation(_ facts: [LocalModelID: Bool]) {
        guard localPreparation != facts else { return }; localPreparation = facts; onChange?()
    }
    public func updateLocalHealth(_ id: LocalModelID, state: EngineHealthState) {
        guard localHealth[id] != state else { return }; localHealth[id] = state; onChange?()
    }
    public func applyFixture(phase: SettingsLoadState) { self.phase = phase }
}

/// Static preview data: no real defaults, credential store, filesystem, permissions, network, or microphone.
@MainActor public enum SettingsViewModelFixtures {
    @MainActor public final class Set {
        public let health: EngineHealthCheckViewModel, online: OnlineAPIConfigViewModel, options: RecognitionOptionsViewModel
        public let local: LocalModelInstallerViewModel, doubao: DoubaoSetupViewModel
        public let permissions: PermissionsViewModel, data: DataManagementViewModel, menu: MenuBarStatusViewModel
        public init(phase: SettingsLoadState, method: RecognitionMethod = .local, configured: Bool = false, enhancement: Bool = false) {
            let box = FixturePreference(enhancement)
            let source = OnlineEnhancementPreferenceSource(read: { box.value }, write: { box.value = $0 })
            let adapter = AliyunOnlineAPIProvider()
            online = OnlineAPIConfigViewModel(provider: adapter, enhancement: source)
            online.update(credential: configured ? .saved : .missing, visible: true)
            online.applyFixture(phase: phase)
            let provider = RecognitionHealthProvider(online: adapter, doubao: { .init(installed: true, enabledInSystem: true) },
                                                     local: { .passed(.localContainerLoadable) }, credential: { configured ? .saved : .missing })
            health = EngineHealthCheckViewModel(provider: provider); health.applyFixture(phase: phase, method: method)
            options = RecognitionOptionsViewModel(selected: method, health: health, online: online); options.applyFixture(phase: phase)
            local = LocalModelInstallerViewModel(hardware: .init(memoryBytes: 8 * 1_024 * 1_024 * 1_024,
                                                                availableDiskBytes: 20 * 1_024 * 1_024 * 1_024, isAppleSilicon: true))
            local.update(models: phase == .empty ? [] : [
                .init(id: .qwen17, sizeBytes: 2_000_000_000, recommended: false, state: .notApplicable(reason: .hardwareUnsuitable)),
                .init(id: .qwen06, sizeBytes: 1_200_000_000, recommended: true, state: phase == .loading ? .downloading(progress: 0.4) : .notDownloaded)
            ]); local.applyFixture(phase: phase)
            doubao = DoubaoSetupViewModel(); doubao.update(.init(installed: phase != .empty, enabledInSystem: phase == .error ? nil : true)); doubao.applyFixture(phase: phase)
            permissions = PermissionsViewModel(); permissions.update(phase == .empty ? [:] : [.microphone: .denied]); permissions.applyFixture(phase: phase)
            data = DataManagementViewModel(); data.update(phase == .empty ? [] : [.init(id: .model06, sizeBytes: 1_200_000_000)]); data.applyFixture(phase: phase)
            menu = MenuBarStatusViewModel(options: options); menu.applyFixture(phase: phase)
        }
    }
    @MainActor private final class FixturePreference { var value: Bool; init(_ value: Bool) { self.value = value } }
}
