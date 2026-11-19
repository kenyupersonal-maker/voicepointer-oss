import Foundation

/// Pure permission-state presentation data shared by the menu alert and tests.
public enum PermissionFeedbackKind: String, CaseIterable, Sendable {
    case accessibility
    case inputMonitoring
    case eventPosting

    public var displayName: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .inputMonitoring: return "输入监控"
        case .eventPosting: return "键盘操作（辅助功能）"
        }
    }

    public var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        case .eventPosting:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

public enum PermissionFeedback {
    public static func missing(
        accessibility: Bool,
        inputMonitoring: Bool,
        eventPosting: Bool
    ) -> [PermissionFeedbackKind] {
        PermissionFeedbackKind.allCases.filter { kind in
            switch kind {
            case .accessibility: return !accessibility
            case .inputMonitoring: return !inputMonitoring
            // Both checks use the same settings page. Do not show users a
            // second, nonexistent permission to enable when AX is missing.
            case .eventPosting: return accessibility && !eventPosting
            }
        }
    }
}
