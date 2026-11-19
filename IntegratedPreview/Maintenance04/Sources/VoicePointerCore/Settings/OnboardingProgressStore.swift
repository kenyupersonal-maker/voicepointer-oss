import Foundation
import Darwin

public enum OnboardingPath: String, Codable, Sendable {
    case doubao
    case local
    case online
}

public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case initialPermissions
    case onlineConfiguration
    case onlineReady
    case chooseMethod
    case doubaoCheckInstallation
    case doubaoInstallOfficial
    case doubaoManualEnable
    case doubaoPermissions
    case doubaoPractice
    case localChooseModel
    case localPrepareModel
    case localCloudConfiguration
    case localPermissions
    case localPractice
    case completion

    fileprivate func belongs(to path: OnboardingPath?) -> Bool {
        switch self {
        case .chooseMethod, .initialPermissions:
            return path == nil
        case .onlineConfiguration, .onlineReady: return path == .online
        case .doubaoCheckInstallation, .doubaoInstallOfficial, .doubaoManualEnable,
             .doubaoPermissions, .doubaoPractice:
            return path == .doubao
        case .localChooseModel, .localPrepareModel, .localCloudConfiguration,
             .localPermissions, .localPractice:
            return path == .local
        case .completion:
            return path != nil
        }
    }
}

public enum OnboardingProgressStatus: String, Codable, Sendable {
    case notStarted
    case inProgress
    case deferred
    case completed
}

public struct OnboardingProgress: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let path: OnboardingPath?
    public let step: OnboardingStep
    public let status: OnboardingProgressStatus
    /// Only the public route identifier, never a model path or downloaded data.
    public let selectedLocalRouteID: String?
    public let wasMigratedFromProviderSettings: Bool
    public let updatedAt: Date

    public var canResume: Bool { status == .inProgress }
    public var needsUserChoice: Bool { status == .notStarted }
    public var isDeferred: Bool { status == .deferred }
    public var isCompleted: Bool { status == .completed }

    fileprivate init(path: OnboardingPath?, step: OnboardingStep,
                     status: OnboardingProgressStatus,
                     selectedLocalRouteID: String? = nil,
                     wasMigratedFromProviderSettings: Bool = false,
                     updatedAt: Date = Date()) {
        self.schemaVersion = 1
        self.path = path
        self.step = step
        self.status = status
        self.selectedLocalRouteID = selectedLocalRouteID
        self.wasMigratedFromProviderSettings = wasMigratedFromProviderSettings
        self.updatedAt = updatedAt
    }

    fileprivate var isConsistent: Bool {
        guard schemaVersion == 1, step.belongs(to: path) else { return false }
        if let selectedLocalRouteID {
            guard path == .local,
                  Self.allowedLocalRoutes.contains(selectedLocalRouteID) else { return false }
        }
        switch status {
        case .notStarted:
            return path == nil && [.chooseMethod, .initialPermissions].contains(step) && !wasMigratedFromProviderSettings
        case .inProgress:
            return !wasMigratedFromProviderSettings && (path != nil || [.chooseMethod, .initialPermissions].contains(step))
                && step != .completion
        case .deferred:
            return step != .completion
                && (!wasMigratedFromProviderSettings || (path == nil && step == .chooseMethod))
        case .completed:
            return path != nil && step == .completion && !wasMigratedFromProviderSettings
        }
    }

    fileprivate static let allowedLocalRoutes: Set<String> = [
        "qwen17-rolling", "qwen06-rolling", "apple-speech"
    ]
}

public enum OnboardingProgressStoreError: Error, Sendable {
    case malformedProgress
    case unsupportedProgressVersion(Int)
    case invalidTransition
    case symlink
    case persistence(String)
}

/// Persists only the selected setup path and the wizard checkpoint.
/// Provider credentials, transcripts, and audio are deliberately outside this store.
@MainActor
public final class OnboardingProgressStore {
    public let fileURL: URL
    public let providerSettingsURL: URL
    public private(set) var progress: OnboardingProgress

    public init(fileURL: URL, providerSettingsURL: URL) throws {
        self.fileURL = fileURL
        self.providerSettingsURL = providerSettingsURL

        if let saved = try Self.readProgress(at: fileURL) {
            progress = saved
        } else if Self.isValidProviderSettings(at: providerSettingsURL) {
            let migrated = OnboardingProgress(
                path: nil,
                step: .chooseMethod,
                status: .deferred,
                wasMigratedFromProviderSettings: true
            )
            try Self.write(migrated, to: fileURL)
            progress = migrated
        } else {
            progress = OnboardingProgress(path: nil, step: .chooseMethod, status: .notStarted)
        }
    }

    public convenience init(dataRoot: URL) throws {
        try self.init(
            fileURL: dataRoot.appendingPathComponent("onboarding-progress.json"),
            providerSettingsURL: dataRoot.appendingPathComponent("provider-settings.json")
        )
    }

    /// Call only after an explicit user action opens the first-run flow.
    public func begin() throws {
        try replace(with: OnboardingProgress(path: nil, step: .initialPermissions, status: .inProgress))
    }
    /// A snapshot from the permission poll, never a request or TCC mutation.
    public func permissionsSatisfied(accessibility: Bool, inputMonitoring: Bool, microphone: Bool) throws {
        guard progress.status == .inProgress, progress.step == .initialPermissions,
              accessibility && inputMonitoring && microphone else { throw OnboardingProgressStoreError.invalidTransition }
        try replace(with: OnboardingProgress(path: nil, step: .chooseMethod, status: .inProgress))
    }

    public func choose(path: OnboardingPath) throws {
        guard progress.status == .inProgress, progress.step == .chooseMethod else {
            throw OnboardingProgressStoreError.invalidTransition
        }
        let firstStep: OnboardingStep = Self.firstStep(path)
        try replace(with: OnboardingProgress(path: path, step: firstStep, status: .inProgress,
                                            selectedLocalRouteID: path == .local ? "qwen17-rolling" : nil))
    }

    /// Convenience for a UI that records the route choice and first node together.
    public func start(path: OnboardingPath) throws {
        let firstStep: OnboardingStep = Self.firstStep(path)
        try replace(with: OnboardingProgress(path: path, step: firstStep, status: .inProgress,
                                            selectedLocalRouteID: path == .local ? "qwen17-rolling" : nil))
    }
    private static func firstStep(_ path: OnboardingPath) -> OnboardingStep {
        switch path { case .doubao: .doubaoCheckInstallation; case .local: .localPrepareModel; case .online: .onlineConfiguration }
    }
    public static func afterPreparation(path: OnboardingPath, permissionsSatisfied: Bool) -> OnboardingStep {
        if path == .doubao { return permissionsSatisfied ? .doubaoPractice : .doubaoPermissions }
        return permissionsSatisfied ? .localPractice : .localPermissions
    }
    /// Reuses saved enum cases while skipping obsolete/repeated screens.
    public func advanceLegacyCheckpoint(permissionsSatisfied: Bool) throws {
        guard progress.status == .inProgress else { return }
        switch progress.step {
        case .localCloudConfiguration: try advance(to: .localPractice)
        case .doubaoPermissions where permissionsSatisfied: try advance(to: .doubaoPractice)
        case .localPermissions where permissionsSatisfied: try advance(to: .localPractice)
        default: break
        }
    }
    public func onlineConfigured(selectable: Bool) throws {
        guard progress.status == .inProgress, progress.path == .online, progress.step == .onlineConfiguration,
              selectable else { throw OnboardingProgressStoreError.invalidTransition }
        try advance(to: .onlineReady)
    }

    public func selectLocalRoute(_ routeID: String) throws {
        guard progress.path == .local, progress.status == .inProgress,
              OnboardingProgress.allowedLocalRoutes.contains(routeID) else {
            throw OnboardingProgressStoreError.invalidTransition
        }
        try replace(with: OnboardingProgress(path: .local, step: progress.step,
                                            status: .inProgress,
                                            selectedLocalRouteID: routeID))
    }

    /// Saves a route-specific checkpoint. The view can move backward or re-check
    /// after returning from System Settings without losing the selected path.
    public func advance(to step: OnboardingStep) throws {
        guard progress.status == .inProgress,
              let path = progress.path,
              step != .chooseMethod,
              step != .completion,
              step.belongs(to: path) else {
            throw OnboardingProgressStoreError.invalidTransition
        }
        try replace(with: OnboardingProgress(path: path, step: step, status: .inProgress,
                                            selectedLocalRouteID: progress.selectedLocalRouteID))
    }

    public func returnToMethodChoice() throws {
        guard progress.status == .inProgress, progress.path != nil else {
            throw OnboardingProgressStoreError.invalidTransition
        }
        try replace(with: OnboardingProgress(path: nil, step: .chooseMethod, status: .inProgress))
    }

    /// Returns from a failed or unwanted local preparation check to the model
    /// picker without discarding the chosen local path or current model.
    public func returnToLocalModelChoice() throws {
        guard progress.status == .inProgress,
              progress.path == .local,
              progress.step == .localPrepareModel,
              let routeID = progress.selectedLocalRouteID else {
            throw OnboardingProgressStoreError.invalidTransition
        }
        try replace(with: OnboardingProgress(path: .local, step: .localChooseModel,
                                            status: .inProgress, selectedLocalRouteID: routeID))
    }

    /// Records “稍后” while preserving the route and current node for resuming.
    public func deferOnboarding() throws {
        guard progress.status != .completed else {
            throw OnboardingProgressStoreError.invalidTransition
        }
        try replace(with: OnboardingProgress(
            path: progress.path,
            step: progress.step,
            status: .deferred,
            selectedLocalRouteID: progress.selectedLocalRouteID,
            wasMigratedFromProviderSettings: progress.wasMigratedFromProviderSettings
        ))
    }

    /// Explicitly resumes a deferred flow at its saved route and node.
    /// Legacy settings migrations are not wizard checkpoints; users can start
    /// a fresh flow from Settings if they choose to configure again.
    public func resume() throws {
        guard progress.status == .deferred,
              !progress.wasMigratedFromProviderSettings else {
            throw OnboardingProgressStoreError.invalidTransition
        }
        try replace(with: OnboardingProgress(
            path: progress.path,
            step: progress.step,
            status: .inProgress,
            selectedLocalRouteID: progress.selectedLocalRouteID
        ))
    }

    public func complete() throws {
        guard let path = progress.path,
              progress.status == .inProgress,
              progress.step == (path == .doubao ? .doubaoPractice : path == .local ? .localPractice : .onlineReady) else {
            throw OnboardingProgressStoreError.invalidTransition
        }
        try replace(with: OnboardingProgress(path: path, step: .completion, status: .completed,
                                            selectedLocalRouteID: progress.selectedLocalRouteID))
    }

    /// Clears only onboarding progress. It never touches provider settings or credentials.
    public func reset() throws {
        if try Self.fileExists(at: fileURL) {
            guard unlink(fileURL.path) == 0 else {
                throw OnboardingProgressStoreError.persistence(Self.errnoString(errno))
            }
        }
        progress = OnboardingProgress(path: nil, step: .chooseMethod, status: .notStarted)
    }

    private func replace(with next: OnboardingProgress) throws {
        guard next.isConsistent else { throw OnboardingProgressStoreError.invalidTransition }
        try Self.write(next, to: fileURL)
        progress = next
    }

    private static func readProgress(at url: URL) throws -> OnboardingProgress? {
        guard try fileExists(at: url) else { return nil }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw OnboardingProgressStoreError.persistence("read failed")
        }
        let saved: OnboardingProgress
        do {
            saved = try JSONDecoder().decode(OnboardingProgress.self, from: data)
        } catch {
            throw OnboardingProgressStoreError.malformedProgress
        }
        guard saved.schemaVersion == 1 else {
            throw OnboardingProgressStoreError.unsupportedProgressVersion(saved.schemaVersion)
        }
        guard saved.isConsistent else { throw OnboardingProgressStoreError.malformedProgress }
        return saved
    }

    private static func isValidProviderSettings(at url: URL) -> Bool {
        guard (try? fileExists(at: url)) == true,
              let data = FileManager.default.contents(atPath: url.path) else { return false }
        return (try? JSONDecoder().decode(ProviderPreferences.self, from: data)) != nil
    }

    private static func write(_ progress: OnboardingProgress, to url: URL) throws {
        guard progress.isConsistent else { throw OnboardingProgressStoreError.invalidTransition }
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw OnboardingProgressStoreError.persistence("create directory failed: \(error)")
        }
        _ = try fileExists(at: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(progress)
        } catch {
            throw OnboardingProgressStoreError.persistence("encode failed: \(error)")
        }

        let tempURL = parent.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw OnboardingProgressStoreError.persistence("open temp: \(errnoString(errno))")
        }
        var closed = false
        do {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count > 0 { offset += count; continue }
                    if count == 0 { throw OnboardingProgressStoreError.persistence("zero-byte write") }
                    if errno == EINTR { continue }
                    throw OnboardingProgressStoreError.persistence("write: \(errnoString(errno))")
                }
            }
            while Darwin.fsync(fd) != 0 {
                if errno == EINTR { continue }
                throw OnboardingProgressStoreError.persistence("fsync: \(errnoString(errno))")
            }
            let closeResult = Darwin.close(fd)
            closed = true
            guard closeResult == 0 else {
                throw OnboardingProgressStoreError.persistence("close: \(errnoString(errno))")
            }
            _ = try fileExists(at: url)
            guard rename(tempURL.path, url.path) == 0 else {
                throw OnboardingProgressStoreError.persistence("rename: \(errnoString(errno))")
            }
        } catch {
            if !closed { _ = Darwin.close(fd) }
            _ = unlink(tempURL.path)
            if let storeError = error as? OnboardingProgressStoreError { throw storeError }
            throw OnboardingProgressStoreError.persistence("write failed: \(error)")
        }
    }

    @discardableResult
    private static func fileExists(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK { throw OnboardingProgressStoreError.symlink }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw OnboardingProgressStoreError.persistence("destination is not a regular file")
            }
            return true
        }
        if errno == ENOENT { return false }
        throw OnboardingProgressStoreError.persistence("lstat: \(errnoString(errno))")
    }

    private static func errnoString(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
