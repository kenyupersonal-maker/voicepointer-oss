import Foundation

/// One-time changes to the saved HUD skin choice. Pure Foundation, so the self-tests can run it.
public enum SkinSelectionMigration {
    /// Makes `skin` the saved selection the first time this runs for `flagKey`. The flag is written together with
    /// the selection, so a skin the user picks afterwards is never overridden by a later launch.
    /// Returns true when it changed the selection.
    @discardableResult
    public static func selectOnce(
        _ skin: String, selectionKey: String, flagKey: String, defaults: UserDefaults
    ) -> Bool {
        guard !defaults.bool(forKey: flagKey) else { return false }
        defaults.set(true, forKey: flagKey)
        defaults.set(skin, forKey: selectionKey)
        return true
    }
}
