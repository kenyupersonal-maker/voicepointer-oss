import Foundation

/// RAM values only. The application owns this value on its main actor; no storage,
/// recognizer, logger or network is consulted here.
public struct RecognitionMemoryStore: Sendable {
    public enum Source: String, Sendable { case delivered, doubao, userCorrected }
    public enum Skip: String, Sendable { case sensitive, denyApp, noise, empty, notDelivered }
    public enum Change: Sendable { case edited(String), undone, cleared }
    public struct Entry: Sendable, Equatable {
        public let id: UUID
        public let appKey: String
        public var text: String
        public let createdAt: Date
        public var source: Source
        public let cloudSeen: Bool
    }
    public static let lifetime: TimeInterval = 600
    public static let maximumApps = 8
    public static let maximumEntries = 3
    public static let maximumCharacters = 400
    private var apps: [String: [Entry]] = [:]
    private var touches: [String: UInt64] = [:]
    private var serial: UInt64 = 0
    public init() {}

    /// Privacy filtering applies before truncation: a secret at the beginning of
    /// a long dictation must not be made invisible to the filter by taking its tail.
    public static func isSensitive(_ text: String) -> Bool {
        let value = text.lowercased()
        let patterns = [
            "[0-9]{7,}", "[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}",
            "(?:token|key|secret)\\s*=", "sk-", "akia[a-z0-9]*",
            "[a-z0-9]{32,}", "password|passcode|密码|口令|验证码"
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
    public static func denies(appKey: String) -> Bool {
        let value = appKey.lowercased()
        return ["com.1password", "com.agilebits", "com.bitwarden", "com.lastpass",
                "com.dashlane", "com.apple.keychainaccess", "com.apple.passwords"]
            .contains { value == $0 || value.hasPrefix($0 + ".") }
    }
    public static func hasDisallowedControls(_ text: String, allowLineBreaks: Bool = true) -> Bool {
        text.unicodeScalars.contains {
            // Foundation's controlCharacters also contains format scalars, including
            // the ZWJ that makes one family emoji. Reject C0/C1, keep whole graphemes.
            if allowLineBreaks, $0 == "\n" || $0 == "\t" { return false }
            return $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
        }
    }
    private static func usable(_ text: String) -> String? {
        guard !isSensitive(text), !hasDisallowedControls(text) else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.suffix(maximumCharacters))
    }
    private mutating func touch(_ key: String) {
        serial &+= 1
        touches[key] = serial
    }
    public mutating func expire(now: Date) {
        for key in Array(apps.keys) {
            apps[key]?.removeAll {
                let age = now.timeIntervalSince($0.createdAt)
                return !age.isFinite || age < 0 || age >= Self.lifetime
            }
            if apps[key]?.isEmpty == true { apps[key] = nil; touches[key] = nil }
        }
    }
    /// Only already-confirmed VoiceNative delivery is eligible. CloudSeen describes
    /// that round's audio transport, never current preferences or final source.
    @discardableResult public mutating func add(
        id: UUID, appKey: String, text: String, now: Date,
        voiceNative: Bool, delivered: Bool, cancelled: Bool, noise: Bool, cloudSeen: Bool, source: Source = .delivered
    ) -> Skip? {
        expire(now: now)
        guard voiceNative || source == .doubao, delivered, !cancelled else { return .notDelivered }
        guard !noise else { return .noise }
        guard !appKey.isEmpty else { return .empty }
        guard !Self.denies(appKey: appKey) else { return .denyApp }
        guard !Self.isSensitive(text) else { return .sensitive }
        guard let clean = Self.usable(text) else { return .empty }
        remove(id: id)
        if apps[appKey] == nil, apps.count >= Self.maximumApps,
           let oldest = touches.min(by: { $0.value < $1.value })?.key {
            apps[oldest] = nil; touches[oldest] = nil
        }
        apps[appKey, default: []].append(Entry(id: id, appKey: appKey, text: clean,
            createdAt: now, source: source, cloudSeen: cloudSeen))
        apps[appKey] = Array((apps[appKey] ?? []).suffix(Self.maximumEntries))
        touch(appKey)
        return nil
    }
    public mutating func entries(appKey: String, now: Date) -> [Entry] {
        expire(now: now)
        guard !appKey.isEmpty, !Self.denies(appKey: appKey), let entries = apps[appKey] else { return [] }
        touch(appKey)
        return entries
    }
    public mutating func count(now: Date) -> Int {
        expire(now: now)
        return apps.values.reduce(0) { $0 + $1.count }
    }
    /// An invalid/sensitive edit removes the old record, rather than retaining
    /// stale words which the person explicitly replaced. Age/cloudSeen stay frozen.
    public mutating func replace(id: UUID, text: String, now: Date) {
        expire(now: now)
        guard let key = apps.first(where: { $0.value.contains(where: { $0.id == id }) })?.key,
              let index = apps[key]?.firstIndex(where: { $0.id == id }) else { return }
        guard let clean = Self.usable(text) else { remove(id: id); return }
        apps[key]?[index].text = clean
        apps[key]?[index].source = .userCorrected
        touch(key)
    }
    public mutating func observe(id: UUID, change: Change, now: Date) {
        switch change {
        case .edited(let text): replace(id: id, text: text, now: now)
        case .undone: remove(id: id)
        case .cleared: break // Sending normally clears an editor; it is confirmation.
        }
    }
    public mutating func remove(id: UUID) {
        for key in Array(apps.keys) {
            apps[key]?.removeAll { $0.id == id }
            if apps[key]?.isEmpty == true { apps[key] = nil; touches[key] = nil }
        }
    }
    public mutating func clear() { apps.removeAll(); touches.removeAll(); serial = 0 }
}
