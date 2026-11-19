import Foundation

public enum InlineWritePolicy {
    public static let chromiumAllowlist: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.codex"]
    public static let explicitDenylist: Set<String> = ["com.tencent.workbuddy.mac"]
    public static let knownChromium: Set<String> = chromiumAllowlist.union(explicitDenylist)
    public static func allows(bundle: String?, chromium: Bool, automaticallyDenied: Bool = false) -> Bool {
        if automaticallyDenied { return false }
        if let bundle, explicitDenylist.contains(bundle) { return false }
        return !chromium || bundle.map(chromiumAllowlist.contains) == true
    }
    public static func safeBundle(_ value: String) -> Bool {
        value.count <= 160 && value.range(of: #"^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil
    }
    public static func diagnosticClasses(_ values: [String]) -> [String] {
        values.filter { !$0.hasPrefix("sk-") && $0.count <= 24 &&
            $0.range(of: #"^[A-Za-z_][A-Za-z_-]*$"#, options: .regularExpression) != nil }.prefix(6).map { $0 }
    }
    public static func acceptsPartial(_ text: String, hotwordEcho: Bool = false) -> Bool {
        !hotwordEcho && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Stores only app identity, finite reason and time; no editor content. Writes and failures
/// are counted in memory. Allowlisted apps recover after 24 hours or process restart.
public final class InlineWriteRuntime: @unchecked Sendable {
    public enum Reason: String, Codable, Sendable { case deliveryUnconfirmed, unchangedPaste, sendStillPresent }
    public struct Denial: Codable, Equatable, Sendable {
        public let bundle: String
        public let reason: Reason
        public let at: TimeInterval
        public init(bundle: String, reason: Reason, at: TimeInterval) {
            self.bundle = bundle; self.reason = reason; self.at = at
        }
    }
    public static let key = "inlineDeniedBundles"
    public static let changed = Notification.Name("VoicePointerInlinePolicyChanged")
    public static let demoted = Notification.Name("VoicePointerInlinePolicyDemoted")
    public static let temporaryLifetime: TimeInterval = 24 * 60 * 60
    public static let shared = InlineWriteRuntime()
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var denied: [Denial]
    private var writes: [String: [TimeInterval]] = [:]
    private var unchangedPastes: [String: Int] = [:]
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Denial].self, from: $0) } ?? []
        // Obsolete weak evidence is never carried forward. A new app process also
        // resets strong-evidence demotions for the two verified inline editors.
        denied = Array(decoded.filter {
            InlineWritePolicy.safeBundle($0.bundle) && $0.at.isFinite && $0.at >= 0 &&
            $0.reason != .deliveryUnconfirmed && !InlineWritePolicy.chromiumAllowlist.contains($0.bundle)
        }.prefix(64))
        if denied != decoded { persistLocked() }
    }
    public func activeDenials(now: TimeInterval = Date().timeIntervalSince1970) -> [Denial] {
        let (value, changed) = lock.withLock { () -> ([Denial], Bool) in
            let changed = expireLocked(now: now)
            return (denied, changed)
        }
        if changed { notifyChanged() }
        return value
    }
    public func isDenied(_ bundle: String?, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        activeDenials(now: now).contains { $0.bundle == bundle }
    }
    public func recordActiveDenials() {
        for entry in activeDenials() {
            RuntimeTrace.record("composer policy active bundle=\(entry.bundle) reason=\(entry.reason.rawValue)")
        }
        RuntimeTrace.record("composer policy startup state=ready")
    }
    @discardableResult public func noteApplicationRestart(bundle: String) -> Bool {
        guard InlineWritePolicy.chromiumAllowlist.contains(bundle) else { return false }
        return restore(bundle: bundle)
    }
    @discardableResult public func restore(bundle: String) -> Bool {
        let changed = lock.withLock {
            let before = denied.count
            denied.removeAll { $0.bundle == bundle }
            unchangedPastes.removeValue(forKey: bundle)
            writes.removeValue(forKey: bundle)
            guard denied.count != before else { return false }
            persistLocked(); return true
        }
        if changed { notifyChanged() }
        return changed
    }
    private func persistLocked() {
        if let data = try? JSONEncoder().encode(denied) { defaults.set(data, forKey: Self.key) }
    }
    private func expireLocked(now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0 else { return false }
        let expired = denied.filter { InlineWritePolicy.chromiumAllowlist.contains($0.bundle) &&
            (now < $0.at || now - $0.at >= Self.temporaryLifetime) }
        guard !expired.isEmpty else { return false }
        let bundles = Set(expired.map(\.bundle))
        denied.removeAll { bundles.contains($0.bundle) }
        for bundle in bundles { unchangedPastes.removeValue(forKey: bundle); writes.removeValue(forKey: bundle) }
        persistLocked(); return true
    }
    private func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    public func noteWrite(bundle: String?, now: TimeInterval = Date().timeIntervalSince1970) {
        guard let bundle, InlineWritePolicy.safeBundle(bundle), now.isFinite else { return }
        lock.withLock {
            if writes.count >= 64, writes[bundle] == nil { writes.removeAll() }
            var recent = writes[bundle, default: []].filter { $0 <= now && now - $0 <= 1800 }
            if recent.count >= 2048 { recent.removeFirst() }
            recent.append(now); writes[bundle] = recent
        }
    }
    @discardableResult public func noteFailure(bundle: String?, reason: Reason, hintRelated: Bool = false,
        now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let bundle, InlineWritePolicy.safeBundle(bundle), now.isFinite, now >= 0 else { return false }
        // AX sometimes cannot confirm a successful Claude write. Preserve the
        // delivery safety outcome, but never learn a demotion from uncertainty.
        if hintRelated || reason == .deliveryUnconfirmed {
            return false
        }
        let count: Int? = lock.withLock {
            _ = expireLocked(now: now)
            guard !denied.contains(where: { $0.bundle == bundle }) else { return nil }
            let recent = writes[bundle, default: []].filter { $0 <= now && now - $0 <= 1800 }
            writes[bundle] = recent
            guard !recent.isEmpty else { return nil }
            if reason == .unchangedPaste {
                unchangedPastes[bundle, default: 0] += 1
                guard unchangedPastes[bundle, default: 0] >= 2 else { return nil }
            }
            if denied.count >= 64 { denied.removeFirst() }
            denied.append(.init(bundle: bundle, reason: reason, at: now))
            persistLocked()
            return recent.count
        }
        guard let count else { return false }
        RuntimeTrace.record("composer policy demote bundle=\(bundle) reason=\(reason.rawValue) recentInlineWrites=\(count)")
        notifyChanged()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.demoted, object: nil) }
        return true
    }
    public func notePasteConfirmed(bundle: String?) { if let bundle { lock.withLock { unchangedPastes[bundle] = 0 } } }
}
