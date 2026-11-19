// T4 2026-10-02: Foundation-only settings contracts; this file owns health states/actions and timing policy.
import Foundation

public enum SettingsLoadState: String, Sendable, CaseIterable { case idle, loading, empty, error, content }
public enum RecognitionMethod: String, Sendable, CaseIterable { case doubao, local, online }
public enum HealthNextAction: String, Sendable, CaseIterable {
    case installDoubao, enableSystemInput, downloadRecommendedModel, redownloadModel, use06B
    case configureAPI, replaceKey, retryNetwork, providerConsole, providerDocumentation, recheck
    public var title: String {
        switch self {
        case .installDoubao: "去下载安装"
        case .enableSystemInput: "去系统设置启用"
        case .downloadRecommendedModel: "下载推荐模型"
        case .redownloadModel: "重新下载"
        case .use06B: "改用 0.6B"
        case .configureAPI: "去配置"
        case .replaceKey: "重新填写 Key"
        case .retryNetwork: "检查网络后重试"
        case .providerConsole: "查看服务商控制台"
        case .providerDocumentation: "查看说明文档"
        case .recheck: "重新检查"
        }
    }
}
public enum HealthFailureReason: String, Codable, Sendable, CaseIterable {
    case doubaoNotInstalled, doubaoNotEnabled, inspectionUnavailable
    case modelNotDownloaded, modelCorrupt, hardwareUnsuitable, localLoadFailed
    case noKey, invalidKey, network, freeQuotaExhausted, notNetworkVerified, timeout, unavailable
    case noAccess, balanceDue, rateLimited, modelUnavailable, serviceUnavailable, worker, taskStartFailed, notClosed
    public var message: String {
        switch self {
        case .doubaoNotInstalled: "没有找到豆包输入法"
        case .doubaoNotEnabled: "豆包输入法没有在系统里启用"
        case .inspectionUnavailable: "无法读取系统输入源状态"
        case .modelNotDownloaded: "还没有本地模型"
        case .modelCorrupt: "本地模型文件损坏"
        case .hardwareUnsuitable: "当前配置不适用此模型"
        case .localLoadFailed: "本地模型未能加载"
        case .noKey: "还没有配置 API"
        case .invalidKey: "Key 无效或已过期"
        case .network: "连不上服务商"
        case .freeQuotaExhausted: "免费额度已用完，已自动停用"
        case .notNetworkVerified: ""
        case .timeout: "检查超时"
        case .unavailable: "无法完成检查"
        case .noAccess: CloudConnectionCheck.Failure.noAccess.message
        case .balanceDue: CloudConnectionCheck.Failure.balanceDue.message
        case .rateLimited: CloudConnectionCheck.Failure.rateLimited.message
        case .modelUnavailable: CloudConnectionCheck.Failure.modelUnavailable.message
        case .serviceUnavailable: CloudConnectionCheck.Failure.serviceUnavailable.message
        case .worker: CloudConnectionCheck.Failure.worker.message
        case .taskStartFailed: CloudConnectionCheck.Failure.taskStartFailed.message
        case .notClosed: CloudConnectionCheck.Failure.notClosed.message
        }
    }
    public var nextAction: HealthNextAction {
        switch self {
        case .doubaoNotInstalled: .installDoubao
        case .doubaoNotEnabled: .enableSystemInput
        case .modelNotDownloaded: .downloadRecommendedModel
        case .modelCorrupt, .localLoadFailed: .redownloadModel
        case .hardwareUnsuitable: .use06B
        case .noKey: .configureAPI
        case .invalidKey: .replaceKey
        case .network, .timeout: .retryNetwork
        case .freeQuotaExhausted: .providerConsole
        case .notNetworkVerified: .providerDocumentation
        case .inspectionUnavailable, .unavailable: .recheck
        case .noAccess, .balanceDue, .modelUnavailable: .providerConsole
        case .rateLimited, .serviceUnavailable, .worker, .taskStartFailed, .notClosed: .recheck
        }
    }
}
public enum HealthDetail: String, Codable, Sendable { case publicInputSource, localContainerLoadable, providerVerified, dictationSucceeded }
public enum EngineHealthState: Sendable, Equatable {
    case idle, checking
    case passed(detail: HealthDetail)
    case failed(reason: HealthFailureReason, nextAction: HealthNextAction)
    public var statusTitle: String {
        switch self { case .idle, .checking, .failed(.notNetworkVerified, _): ""; case .passed: "可用"
        case .failed(.noKey, _): "未配置"
        case .failed(.doubaoNotInstalled, _): "未安装"
        case .failed(.doubaoNotEnabled, _): "未启用"
        case .failed(.modelNotDownloaded, _): "未下载"
        case .failed(.modelCorrupt, _), .failed(.localLoadFailed, _): "文件损坏"
        case .failed(let reason, _): "不可用 · " + reason.message }
    }
    public var phase: SettingsLoadState {
        switch self { case .idle: .idle; case .checking: .loading; case .passed, .failed(.notNetworkVerified, _): .content; case .failed: .error }
    }
    public var isUnverified: Bool {
        switch self { case .idle, .failed(.notNetworkVerified, _), .failed(.noKey, _): true; default: false }
    }
}
public enum EngineHealthResult: Sendable, Equatable {
    case passed(HealthDetail), failed(HealthFailureReason)
    public var state: EngineHealthState {
        switch self { case .passed(let detail): .passed(detail: detail)
        case .failed(let reason): .failed(reason: reason, nextAction: reason.nextAction) }
    }
}
public enum HealthCheckTrigger: String, Sendable { case launch, selection, foreground, settingsOpened, configurationChanged, recheck }

@MainActor public protocol SettingsHealthClock {
    var now: TimeInterval { get }
    func sleep(seconds: TimeInterval) async throws
}
@MainActor public struct SystemSettingsHealthClock: SettingsHealthClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
@MainActor public protocol EngineHealthProviding {
    func check(_ method: RecognitionMethod) async -> EngineHealthResult
}

/// No arbitrary strings enter this log constructor. Exact fields and enum values are checked by self-test.
public enum SettingsHealthLog {
    public static func line(method: RecognitionMethod, state: EngineHealthState, generation: UInt64, milliseconds: Int,
                            source: EngineHealthSource = .check) -> String {
        let status: String, reason: String
        switch state {
        case .idle: status = "idle"; reason = "none"
        case .checking: status = "checking"; reason = "none"
        case .passed: status = "passed"; reason = "none"
        case .failed(let value, _): status = "failed"; reason = value.rawValue
        }
        return "event=engine_check,method=\(method.rawValue),state=\(status),reason=\(reason),generation=\(generation),ms=\(max(0, milliseconds)),source=\(source.rawValue)"
    }
    public static func isWhitelisted(_ line: String) -> Bool {
        guard line.range(of: "^[A-Za-z0-9_.=:,-]+$", options: .regularExpression) != nil else { return false }
        let fields = line.split(separator: ",").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        guard fields.count == 7, fields.allSatisfy({ $0.count == 2 }),
              fields.map({ $0[0] }) == ["event", "method", "state", "reason", "generation", "ms", "source"],
              fields[0][1] == "engine_check", RecognitionMethod(rawValue: fields[1][1]) != nil,
              ["idle", "checking", "passed", "failed"].contains(fields[2][1]),
              fields[3][1] == "none" || HealthFailureReason(rawValue: fields[3][1]) != nil,
              UInt64(fields[4][1]) != nil, UInt64(fields[5][1]) != nil,
              EngineHealthSource(rawValue: fields[6][1]) != nil else { return false }
        return true
    }
}

/// Generation fencing does not depend on a provider cooperating with cancellation. Timers never block switching.
@MainActor public final class EngineHealthCheckViewModel {
    public private(set) var selected: RecognitionMethod?
    public private(set) var states = Dictionary(uniqueKeysWithValues: RecognitionMethod.allCases.map { ($0, EngineHealthState.idle) })
    public private(set) var phase: SettingsLoadState = .idle
    public var onChange: (() -> Void)?
    public var onResult: ((RecognitionMethod, EngineHealthResult) -> Void)?
    private let provider: any EngineHealthProviding
    private let clock: any SettingsHealthClock
    private let timeout: TimeInterval
    private let cacheInterval: TimeInterval
    private let log: (String) -> Void
    private var generation: UInt64 = 0
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cache: [RecognitionMethod: (TimeInterval, EngineHealthResult)] = [:]
    private let archive: EngineHealthArchive?
    private var slots: [RecognitionMethod: String] = [.doubao: "doubao", .local: "qwen06-rolling", .online: "online"]
    private var configurations: [RecognitionMethod: String] = [:]
    public private(set) var checkingMethod: RecognitionMethod?
    public func isFresh(_ method: RecognitionMethod) -> Bool {
        guard let record = record(for: method), record.result == .available else { return false }
        switch method {
        case .local: return true // configure() binds the result to the current file fingerprint.
        case .online: return Date().timeIntervalSince(record.date) >= 0 && Date().timeIntervalSince(record.date) < 1800
        case .doubao: return false
        }
    }
    private var dictationFailures: [String: Int] = [:]
    public func recordDictation(_ method: RecognitionMethod, slot: String, identity: String, failure: HealthFailureReason? = nil) {
        let old = archive?.read(slot, configuration: identity)
        if let failure, failure == .network || failure == .timeout {
            dictationFailures[slot, default: 0] += 1
            guard dictationFailures[slot, default: 0] >= 2 || old?.result == .unavailable else {
                log(SettingsHealthLog.line(method: method, state: EngineHealthResult.failed(failure).state,
                    generation: generation, milliseconds: 0, source: .dictation)); return
            }
        } else { dictationFailures[slot] = 0 }
        let state = failure.map { EngineHealthResult.failed($0).state } ?? .passed(detail: .dictationSucceeded)
        let time = Date()
        let saved = EngineHealthRecord(state: state, date: time, source: .dictation, configuration: identity,
            lastDictation: failure == nil ? time : old?.lastDictation)
        archive?.write(saved, slot: slot)
        if slots[method] == slot, configurations[method] == identity {
            if checkingMethod == method { cancel() }
            states[method] = archive == nil ? state : saved.state
            if selected == method { phase = states[method]!.phase }
            cache[method] = nil
        }
        log(SettingsHealthLog.line(method: method, state: saved.state, generation: generation, milliseconds: 0, source: .dictation))
        onChange?()
    }
    public func record(for method: RecognitionMethod) -> EngineHealthRecord? {
        archive?.read(slots[method] ?? method.rawValue, configuration: configurations[method] ?? "default")
    }
    public func configure(_ method: RecognitionMethod, slot: String, identity: String) {
        guard slots[method] != slot || configurations[method] != identity else { return }
        if selected == method { cancel() }
        slots[method] = slot; configurations[method] = identity; cache[method] = nil
        states[method] = record(for: method)?.state ?? .idle
        onChange?()
    }

    public init(provider: any EngineHealthProviding, clock: any SettingsHealthClock = SystemSettingsHealthClock(),
                timeout: TimeInterval = 8, cacheInterval: TimeInterval = 60, archive: EngineHealthArchive? = nil,
                log: @escaping (String) -> Void = { _ in }) {
        self.provider = provider; self.clock = clock; self.timeout = max(0.001, timeout)
        self.cacheInterval = max(0, cacheInterval); self.log = log
        self.archive = archive
        for method in RecognitionMethod.allCases { states[method] = record(for: method)?.state ?? .idle }
    }
    public var current: EngineHealthState { selected.flatMap { states[$0] } ?? .idle }
    public func check(_ method: RecognitionMethod, trigger: HealthCheckTrigger = .selection) {
        if method == checkingMethod, trigger != .recheck, trigger != .configurationChanged { return }
        cancel()
        selected = method
        if trigger == .configurationChanged || trigger == .recheck { cache[method] = nil }
        if trigger != .recheck, trigger != .configurationChanged, isFresh(method), let record = record(for: method) {
            states[method] = record.state; phase = record.state.phase
            log(SettingsHealthLog.line(method: method, state: record.state, generation: generation, milliseconds: 0, source: .cache))
            onResult?(method, .passed(record.detail ?? .providerVerified)); onChange?(); return
        }
        // Only the online route can perform network I/O; local/public system facts are read on every trigger.
        if method == .online, let (checkedAt, result) = cache[method],
           clock.now >= checkedAt, clock.now - checkedAt < cacheInterval {
            states[method] = result.state; phase = result.state.phase; onChange?(); return
        }
        generation &+= 1
        let token = generation, started = clock.now
        checkingMethod = method
        if states[method] == .idle { states[method] = .checking }
        phase = .loading; onChange?()
        work = Task { [weak self, provider] in
            let result = await provider.check(method)
            guard !Task.isCancelled else { return }
            self?.finish(result, method: method, token: token, started: started)
        }
        timer = Task { [weak self, clock, timeout] in
            do { try await clock.sleep(seconds: timeout) } catch { return }
            guard !Task.isCancelled else { return }
            self?.finish(.failed(.timeout), method: method, token: token, started: started)
        }
    }
    public func recheck() { if let selected { check(selected, trigger: .recheck) } }
    /// The independent online checker projects into the same states read by cards and menu.
    public func project(_ method: RecognitionMethod, state: EngineHealthState) {
        guard states[method] != state else { return }
        states[method] = state
        if selected == method { phase = state.phase }
        onChange?()
    }
    public func selectWithoutChecking(_ method: RecognitionMethod) {
        cancel(); selected = method; phase = (states[method] ?? .idle).phase; onChange?()
    }
    public func invalidate(_ method: RecognitionMethod) {
        cache[method] = nil
        if selected == method { cancel() }
        onChange?()
    }
    public func configurationChanged(_ method: RecognitionMethod) {
        invalidate(method); archive?.invalidate(slots[method] ?? method.rawValue)
        states[method] = .idle; onChange?()
    }
    public func cancel() {
        let prior = current, priorPhase = phase
        generation &+= 1; work?.cancel(); timer?.cancel(); work = nil; timer = nil
        checkingMethod = nil
        phase = current.phase
        if prior != current || priorPhase != phase { onChange?() }
    }
    private func finish(_ result: EngineHealthResult, method: RecognitionMethod, token: UInt64, started: TimeInterval) {
        guard token == generation, method == selected else { return }
        work?.cancel(); timer?.cancel(); work = nil; timer = nil
        checkingMethod = nil
        generation &+= 1  // A late completion from the other half of the race cannot overwrite this result.
        cache[method] = (clock.now, result)
        let previous = record(for: method)
        let saved = EngineHealthRecord(state: result.state, date: Date(), source: .check,
            configuration: configurations[method] ?? "default", lastDictation: previous?.lastDictation)
        archive?.write(saved, slot: slots[method] ?? method.rawValue)
        states[method] = archive == nil ? result.state : saved.state; phase = states[method]!.phase
        emit(method, result.state, started: started); onResult?(method, result); onChange?()
    }
    private func emit(_ method: RecognitionMethod, _ state: EngineHealthState, started: TimeInterval) {
        log(SettingsHealthLog.line(method: method, state: state, generation: generation,
                                   milliseconds: Int(max(0, clock.now - started) * 1_000)))
    }
    public func applyFixture(phase: SettingsLoadState, method: RecognitionMethod, state: EngineHealthState? = nil) {
        cancel(); self.phase = phase; selected = method
        states[method] = state ?? (phase == .loading ? .checking : phase == .error
            ? EngineHealthResult.failed(.network).state : phase == .content ? EngineHealthResult.passed(.providerVerified).state : .idle)
    }
}
