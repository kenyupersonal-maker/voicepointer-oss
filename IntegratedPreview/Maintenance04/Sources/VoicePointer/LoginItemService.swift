import Foundation
import ServiceManagement

struct LoginItemServiceSnapshot: Equatable, Sendable {
    enum SystemState: String, Sendable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
        case unknown
    }

    let desiredEnabled: Bool
    let systemState: SystemState
    let registeredBundleIdentity: String?
    let lastCheckedAt: Date
    let failureReason: String?

    var systemRegistered: Bool { systemState == .enabled }
}

private struct LoginItemServiceRequest: Sendable {
    let desiredEnabled: Bool
    let isOfficialInstall: Bool
    let mayChangeRegistration: Bool
}

/// All ServiceManagement work runs on one utility queue. SMAppService's synchronous IPC
/// must not block the app's main actor while launch or settings UI is active.
private func performLoginItemServiceRequest(_ request: LoginItemServiceRequest) -> LoginItemServiceSnapshot {
    let service = SMAppService.mainApp
    var failureReason: String?

    if request.mayChangeRegistration, request.isOfficialInstall {
        let before = service.status
        if request.desiredEnabled {
            switch before {
            case .enabled:
                break
            case .notRegistered, .notFound:
                do {
                    try service.register()
                } catch {
                    failureReason = error.localizedDescription
                }
            case .requiresApproval:
                failureReason = "macOS 需要在系统设置中允许 VoicePointer 登录时启动。"
            @unknown default:
                failureReason = "macOS 返回了无法识别的登录项状态。"
            }
        } else {
            switch before {
            case .enabled, .requiresApproval:
                do {
                    try service.unregister()
                } catch {
                    failureReason = error.localizedDescription
                }
            case .notRegistered, .notFound:
                break
            @unknown default:
                failureReason = "macOS 返回了无法识别的登录项状态。"
            }
        }
    } else if !request.isOfficialInstall {
        failureReason = LoginItemService.nonOfficialInstallReason
    }

    let state = LoginItemService.systemState(for: service.status)
    let identity: String? = state == .enabled && request.isOfficialInstall
        ? "\(LoginItemService.officialBundleIdentifier)@\(LoginItemService.officialBundlePath)"
        : nil

    if failureReason == nil, request.isOfficialInstall {
        switch state {
        case .enabled where !request.desiredEnabled:
            failureReason = "用户已关闭自启，但系统仍显示已登记；请重新检查。"
        case .notRegistered where request.desiredEnabled:
            failureReason = "自启尚未登记；请重新检查。"
        case .requiresApproval:
            failureReason = "macOS 需要在系统设置中允许 VoicePointer 登录时启动。"
        case .notFound:
            failureReason = "macOS 未找到 VoicePointer 的登录项服务。请重新安装正式版后重试。"
        case .unknown:
            failureReason = "macOS 返回了无法识别的登录项状态。"
        default:
            break
        }
    }

    return LoginItemServiceSnapshot(
        desiredEnabled: request.desiredEnabled,
        systemState: state,
        registeredBundleIdentity: identity,
        lastCheckedAt: Date(),
        failureReason: failureReason
    )
}

@MainActor
final class LoginItemService {
    enum RemovalError: Error { case unregisterFailed }
    static let shared = LoginItemService()

    static let preferenceKey = "voicePointer.launchAtLogin"
    nonisolated static let officialBundleIdentifier = "com.kenyu.voicepointer.mac"
    nonisolated static let officialBundlePath = "/Applications/VoicePointer.app"
    nonisolated static let nonOfficialInstallReason =
        "开机自启只支持从 /Applications/VoicePointer.app 运行。请先安装正式版；当前仍可手动使用。"

    private let defaults: UserDefaults
    private let serviceQueue = DispatchQueue(
        label: "com.kenyu.voicepointer.login-item-service",
        qos: .utility
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A new installation defaults to enabled; a saved user choice always wins.
    var desiredEnabled: Bool {
        defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    /// Reads the current system state without changing the login item.
    func currentSnapshot() async -> LoginItemServiceSnapshot {
        await perform(
            LoginItemServiceRequest(
                desiredEnabled: desiredEnabled,
                isOfficialInstall: isCurrentAppTheOfficialInstall,
                mayChangeRegistration: false
            )
        )
    }

    /// Applies the saved user intent to SMAppService.mainApp and returns observed system state.
    /// The synchronous ServiceManagement calls run away from the main actor.
    @discardableResult
    func reconcile() async -> LoginItemServiceSnapshot {
        let isOfficialInstall = isCurrentAppTheOfficialInstall
        return await perform(
            LoginItemServiceRequest(
                desiredEnabled: desiredEnabled,
                isOfficialInstall: isOfficialInstall,
                mayChangeRegistration: true
            )
        )
    }

    /// Persists the user choice and reconciles it with macOS. Preview/development copies cannot
    /// mutate either the system login item or the formal app's saved preference.
    @discardableResult
    func setDesiredEnabled(_ enabled: Bool) async -> LoginItemServiceSnapshot {
        guard isCurrentAppTheOfficialInstall else {
            return await perform(
                LoginItemServiceRequest(
                    desiredEnabled: desiredEnabled,
                    isOfficialInstall: false,
                    mayChangeRegistration: false
                )
            )
        }

        defaults.set(enabled, forKey: Self.preferenceKey)
        return await reconcile()
    }

    nonisolated static func isFormalInstall(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        guard bundleIdentifier == officialBundleIdentifier else { return false }

        let expectedURL = URL(fileURLWithPath: officialBundlePath, isDirectory: true)
        let candidateURL = bundleURL.standardizedFileURL
        guard candidateURL.path == expectedURL.path else { return false }

        // Reject an /Applications entry that redirects the official path to a development copy.
        return candidateURL.resolvingSymlinksInPath().path == expectedURL.path
    }

    /// T12 explicit cleanup only. No preference write that could recreate the plist after Trash.
    func unregisterForUninstall() async throws {
        guard isCurrentAppTheOfficialInstall else { throw RemovalError.unregisterFailed }
        let result = await perform(.init(desiredEnabled: false, isOfficialInstall: true, mayChangeRegistration: true))
        guard result.systemState == .notRegistered || result.systemState == .notFound else { throw RemovalError.unregisterFailed }
    }

    nonisolated static func systemState(
        for status: SMAppService.Status
    ) -> LoginItemServiceSnapshot.SystemState {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    private var isCurrentAppTheOfficialInstall: Bool {
        Self.isFormalInstall(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    private func perform(_ request: LoginItemServiceRequest) async -> LoginItemServiceSnapshot {
        await withCheckedContinuation { continuation in
            serviceQueue.async {
                continuation.resume(returning: performLoginItemServiceRequest(request))
            }
        }
    }
}
