import ApplicationServices
import Foundation

public enum AccessibilityPermission {
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public static func requestIfNeeded() -> Bool {
        guard !isTrusted else { return true }
        // The imported SDK declaration is mutable and therefore rejected by
        // Swift 6 strict concurrency. The constant's documented CFString value
        // is stable across supported macOS releases.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
