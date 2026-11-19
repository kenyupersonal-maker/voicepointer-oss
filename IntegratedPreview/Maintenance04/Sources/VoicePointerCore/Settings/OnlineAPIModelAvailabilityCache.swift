import Foundation

/// Capability metadata only. A probe never changes the saved model, credential, or upload switches.
@MainActor public enum OnlineAPIModelAvailabilityCache {
    private struct Receipt: Codable { var passed: [String]; var failed: [String] }
    private static let defaults = UserDefaults(suiteName: "com.kenyu.voicepointer.mac") ?? .standard
    private static func key(_ configuration: OnlineAPIConfiguration) -> String? {
        guard !configuration.credentialRevision.isEmpty, configuration.credentialRevision.utf8.count <= 128 else { return nil }
        return "onlineModelAvailability.v1." + configuration.provider.rawValue + "." + configuration.credentialRevision
    }
    public static func record(configuration: OnlineAPIConfiguration, modelID: String, passed: Bool) {
        guard configuration.provider.modelIDs.contains(modelID), let key = key(configuration) else { return }
        var receipt = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
            ?? Receipt(passed: [], failed: [])
        receipt.passed.removeAll { $0 == modelID }; receipt.failed.removeAll { $0 == modelID }
        if passed { receipt.passed.append(modelID) } else { receipt.failed.append(modelID) }
        if let data = try? JSONEncoder().encode(receipt) { defaults.set(data, forKey: key) }
    }
    public static func models(configuration: OnlineAPIConfiguration, existing: [String]) -> [String] {
        guard let key = key(configuration), let data = defaults.data(forKey: key),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return existing }
        let allowed = Set(existing).union(receipt.passed).subtracting(receipt.failed)
        return configuration.provider.modelIDs.filter { allowed.contains($0) }
    }
}
