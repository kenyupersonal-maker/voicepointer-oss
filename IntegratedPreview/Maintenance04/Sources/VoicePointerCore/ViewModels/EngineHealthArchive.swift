import Foundation

public enum EngineHealthSource: String, Codable, Sendable { case check, dictation, cache }
public struct EngineHealthRecord: Codable, Sendable {
    public enum Result: String, Codable, Sendable { case available, unavailable, notConfigured }
    public let result: Result
    public let reason: HealthFailureReason?
    public let detail: HealthDetail?
    public let date: Date
    public let source: EngineHealthSource
    public let configuration: String
    public let lastDictation: Date?
    public var state: EngineHealthState {
        switch result {
        case .available: .passed(detail: lastDictation == nil ? (detail ?? .providerVerified) : .dictationSucceeded)
        case .unavailable: .failed(reason: reason ?? .unavailable, nextAction: (reason ?? .unavailable).nextAction)
        case .notConfigured: .idle
        }
    }
    public init(state: EngineHealthState, date: Date, source: EngineHealthSource, configuration: String, lastDictation: Date? = nil) {
        switch state {
        case .passed(let value): result = .available; detail = value; reason = nil
        case .failed(.modelNotDownloaded, _):
            result = source == .dictation ? .unavailable : .notConfigured; detail = nil; reason = .modelNotDownloaded
        case .failed(.noKey, _), .idle, .checking,
             .failed(.notNetworkVerified, _): result = .notConfigured; detail = nil; reason = nil
        case .failed(let value, _): result = .unavailable; detail = nil; reason = value
        }
        self.date = date; self.source = source; self.configuration = configuration; self.lastDictation = lastDictation
    }
}

/// A bounded, non-secret record per engine. No transcripts, endpoints or credentials enter this API.
@MainActor public final class EngineHealthArchive {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public func read(_ slot: String, configuration: String) -> EngineHealthRecord? {
        guard Self.slots.contains(slot), let data = defaults.data(forKey: "engine.health.v1." + slot), data.count < 4096,
              let record = try? JSONDecoder().decode(EngineHealthRecord.self, from: data),
              record.configuration == configuration, record.date.timeIntervalSince1970.isFinite else { return nil }
        return record
    }
    public func write(_ record: EngineHealthRecord, slot: String) {
        guard Self.slots.contains(slot), let data = try? JSONEncoder().encode(record), data.count < 4096 else { return }
        defaults.set(data, forKey: "engine.health.v1." + slot)
    }
    public func invalidate(_ slot: String) {
        guard Self.slots.contains(slot) else { return }
        defaults.removeObject(forKey: "engine.health.v1." + slot)
    }
    public static let slots: Set<String> = ["doubao", "online", "qwen06-rolling", "qwen17-rolling"]
}
