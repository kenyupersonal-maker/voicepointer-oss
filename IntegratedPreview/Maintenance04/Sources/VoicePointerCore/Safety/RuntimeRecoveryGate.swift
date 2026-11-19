import Foundation

/// Reasons that automatic runtime recovery must stop and await an explicit
/// user action.
public enum BlockReason: String, Sendable {
    case systemSettingsFrontmost
    case permissionLost
    case eventTapDisabled
    case eventTapStartFailed
    case inputSessionInvalidated
}

/// Temporary interruptions recover only after the app has stopped the old
/// listener and observed stable permissions. Permission/start failures stay
/// latched; repeated interruptions have a bounded restart budget.
public struct RuntimeRecoveryGate: Sendable {
    public private(set) var blockedReason: BlockReason?
    public private(set) var systemSettingsFrontmost: Bool = false
    private var automaticRecoveryTimes: [TimeInterval] = []

    public init() {}

    public var requiresManualRecovery: Bool {
        blockedReason != nil
    }

    public mutating func observeSystemSettingsFrontmost(_ frontmost: Bool) {
        systemSettingsFrontmost = frontmost
        if frontmost, blockedReason == nil {
            latch(.systemSettingsFrontmost)
        } else if !frontmost, blockedReason == .systemSettingsFrontmost {
            blockedReason = nil
        }
    }

    public mutating func latch(_ reason: BlockReason) {
        blockedReason = reason
    }

    public func mayAutomaticallyArm(permissionsGranted: Bool) -> Bool {
        permissionsGranted && !systemSettingsFrontmost && blockedReason == nil
    }

    /// Called only after teardown and four successful permission polls.
    /// Never continues a canceled speech session or replays an input event.
    public mutating func recoverTransientInterruption(
        permissionsGranted: Bool, now: TimeInterval
    ) -> Bool {
        guard permissionsGranted, !systemSettingsFrontmost,
              blockedReason == .inputSessionInvalidated || blockedReason == .eventTapDisabled
        else { return false }
        automaticRecoveryTimes.removeAll { now - $0 >= 30 }
        guard automaticRecoveryTimes.count < 3 else { return false }
        automaticRecoveryTimes.append(now)
        blockedReason = nil
        return true
    }

    @discardableResult
    public mutating func authorizeManualRecovery(permissionsGranted: Bool) -> Bool {
        guard permissionsGranted, !systemSettingsFrontmost else { return false }
        blockedReason = nil
        automaticRecoveryTimes.removeAll()
        return true
    }
}
