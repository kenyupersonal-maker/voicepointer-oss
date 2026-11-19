import Foundation

public enum OnlineAPIKeyInputError: Error, Equatable, Sendable {
    case empty, whitespace, invalidFormat
}

public enum OnlineAPIKeyClassifier {
    public enum Classification: Equatable, Sendable {
        case aliyun, groq, openai, ambiguousSK, unrecognized
        public var candidates: [OnlineAPIProvider] {
            switch self {
            case .aliyun: [.aliyunBailian, .aliyunIntl]
            case .groq: [.groq]
            case .openai: [.openai]
            case .ambiguousSK: [.aliyunBailian, .aliyunIntl, .openai, .siliconflow]
            case .unrecognized: []
            }
        }
    }

    /// Caller input is memory only. This API performs no logging, persistence or network.
    public static func clean(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var removedBearer = false
        for _ in 0..<4 {
            let before = value
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !removedBearer, value.lowercased().hasPrefix("bearer ") {
                value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                removedBearer = true
            }
            if value == before { break }
        }
        guard !value.isEmpty else { throw OnlineAPIKeyInputError.empty }
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw OnlineAPIKeyInputError.whitespace
        }
        guard (16...4096).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ $0.isASCII && (33...126).contains($0.value) }) else {
            throw OnlineAPIKeyInputError.invalidFormat
        }
        return value
    }

    public static func classify(_ cleaned: String) -> Classification {
        guard (16...4096).contains(cleaned.utf8.count),
              cleaned.utf8.allSatisfy({ (33...126).contains($0) }) else { return .unrecognized }
        if cleaned.hasPrefix("gsk_") { return cleaned.count >= 40 ? .groq : .unrecognized }
        // Check foreign sk- prefixes before the generic fallback.
        if cleaned.hasPrefix("sk-ant-") { return .unrecognized }
        if ["sk-proj-", "sk-svcacct-", "sk-admin-"].contains(where: cleaned.hasPrefix) { return .openai }
        guard cleaned.hasPrefix("sk-") else { return .unrecognized }
        let suffix = cleaned.dropFirst(3)
        if suffix.count == 32 && suffix.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) { return .aliyun }
        return cleaned.contains("T3BlbkFJ") ? .openai : .ambiguousSK
    }

    public static func guidePasteLooksLikeKey(_ input: String) -> Bool {
        guard let value = try? clean(input) else { return false }
        return value.count >= 20
    }
}

/// Non-Codable, non-loggable draft. Owned buffers are zeroed on clear/deinit.
/// Swift/Foundation temporary strings and transport-owned copies remain bounded by their scopes.
public final class OnlineAPIDraftKey: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var storage: Data
    public let revision = UUID().uuidString
    public init(_ input: String) throws { storage = Data(try OnlineAPIKeyClassifier.clean(input).utf8) }
    public init(pipeBytes: Data) throws {
        guard (16...4096).contains(pipeBytes.count), pipeBytes.allSatisfy({ (33...126).contains($0) }) else { throw OnlineAPIKeyInputError.whitespace }
        storage = pipeBytes.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
    }
    deinit { storage.resetBytes(in: 0..<storage.count) }
    public var description: String { "<OnlineAPIDraftKey>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public var isEmpty: Bool { lock.withLock { storage.isEmpty } }
    public var classification: OnlineAPIKeyClassifier.Classification {
        lock.withLock { OnlineAPIKeyClassifier.classify(String(decoding: storage, as: UTF8.self)) }
    }
    public var masked: String {
        lock.withLock {
            let value = String(decoding: storage, as: UTF8.self)
            guard !value.isEmpty else { return "" }
            let prefix = ["sk-svcacct-", "sk-admin-", "sk-proj-", "gsk_", "sk-"].first(where: value.hasPrefix) ?? ""
            return prefix + "••••" + value.suffix(4)
        }
    }
    /// Intended only for the sandbox pipe and the explicit Complete transaction.
    public func copyForPipe() throws -> Data {
        try lock.withLock {
            guard !storage.isEmpty else { throw OnlineAPIKeyInputError.empty }
            return storage.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        }
    }
    public func clear() { lock.withLock { storage.resetBytes(in: 0..<storage.count); storage.removeAll(keepingCapacity: false) } }
}
