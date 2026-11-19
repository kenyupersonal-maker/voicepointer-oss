import ApplicationServices

@_silgen_name("IsSecureEventInputEnabled")
private func IsSecureEventInputEnabled() -> Bool

public enum SecureInputGuard {
    public static var isEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}
