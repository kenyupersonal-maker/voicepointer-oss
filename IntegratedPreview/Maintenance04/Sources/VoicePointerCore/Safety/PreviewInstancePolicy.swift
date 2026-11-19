import Foundation

/// Pure, Foundation-only policy for VoicePointer instance conflicts.
/// This is defensive process exclusion only: the retained 04 application does not
/// participate in any locking protocol, so these checks are not atomic
/// cross-app exclusion.
public enum PreviewInstancePolicy {
    public static let releaseBundleID = "com.kenyu.voicepointer.mac"
    public static let dailyBundleID = "com.kenyu.VoicePointer"
    public static let previewBundleID = "com.kenyu.VoicePointer.IntegratedPreview"

    public struct RunningEntry: Sendable, Equatable {
        public let bundleID: String
        public let pid: Int32

        public init(bundleID: String, pid: Int32) {
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    /// True when any entry conflicts with this process: another release,
    /// a retained 04 process, or a different preview process.
    public static func hasConflict(ownPID: Int32, entries: [RunningEntry]) -> Bool {
        conflictingEntry(ownPID: ownPID, entries: entries) != nil
    }

    /// Returns the first existing process the user can switch to when the
    /// current instance is blocked. The caller may activate it, but must not
    /// terminate or otherwise mutate the other application.
    public static func conflictingEntry(ownPID: Int32, entries: [RunningEntry]) -> RunningEntry? {
        entries.first { entry in
            isConflictingEntry(ownPID: ownPID, bundleID: entry.bundleID, pid: entry.pid)
        }
    }

    /// Only another copy of this release is safe for the new app to activate.
    /// The retained 04 and preview processes are detected but left untouched.
    public static func switchableEntry(ownPID: Int32, entries: [RunningEntry]) -> RunningEntry? {
        entries.first { $0.bundleID == releaseBundleID && $0.pid != ownPID }
    }

    /// Single-entry check shared by observers that see one launch event.
    public static func isConflictingEntry(ownPID: Int32, bundleID: String, pid: Int32) -> Bool {
        if bundleID == releaseBundleID { return pid != ownPID }
        if bundleID == dailyBundleID { return true }
        if bundleID == previewBundleID { return pid != ownPID }
        return false
    }
}

public enum InstanceConflictPrompt {
    public static let title = "VoicePointer 已在运行"
    public static let message = "请切换到已打开的 VoicePointer 继续使用。"
    public static let switchButtonTitle = "切换到已运行实例"
    public static let dismissButtonTitle = "取消"
    public static let legacyMessage = "另一个 VoicePointer 正在运行。为避免冲突，本应用已暂停；请手动切换或退出另一实例。"
}
