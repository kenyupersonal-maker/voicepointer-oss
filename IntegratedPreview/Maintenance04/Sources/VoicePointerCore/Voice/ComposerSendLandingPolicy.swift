import Foundation

public enum ComposerSendLandingPolicy {
    public enum Decision: Equatable, Sendable { case ready, wait, stop }
    public static let timeoutMilliseconds = 800
    public static func decide(expected: String?, original: String?, current: String?, elapsedMilliseconds: Int) -> Decision {
        if current == expected { return .ready }
        guard let expected, !expected.isEmpty, elapsedMilliseconds < timeoutMilliseconds else { return .stop }
        // An unrelated edit never authorizes a retry or a Return.
        if current == nil || current == original || current?.isEmpty == true { return .wait }
        return .stop
    }
}
