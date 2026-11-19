import Foundation

/// Non-secret preference, separate from credentials and K06 confirmation. Invalid
/// drafts are never persisted. Revision also changes when an edit is cancelled,
/// so changing away and back cannot revive an old verification callback.
@MainActor
public final class CloudModelCatalogEndpointStore {
    public struct Snapshot: Sendable, Equatable {
        public let endpoint: CloudModelCatalogEndpoint?
        public let revision: UUID
    }
    public static let preferenceKey = "cloud.catalog.modelsURL"
    private let read: () -> String?
    private let write: (String) -> Void
    private var revision = UUID()
    public init(read: @escaping () -> String?, write: @escaping (String) -> Void) {
        self.read = read; self.write = write
    }
    public convenience init(defaults: UserDefaults = .standard) {
        self.init(read: { defaults.string(forKey: Self.preferenceKey) },
                  write: { defaults.set($0, forKey: Self.preferenceKey) })
    }
    public var snapshot: Snapshot {
        Snapshot(endpoint: read().flatMap { CloudModelCatalogEndpoint(address: $0) }, revision: revision)
    }
    @discardableResult
    public func save(address: String) -> Snapshot? {
        guard let endpoint = CloudModelCatalogEndpoint(address: address) else { return nil }
        invalidate()
        write(endpoint.modelsURL.absoluteString)
        return snapshot.endpoint == endpoint ? snapshot : nil
    }
    public func invalidate() { revision = UUID() }
    public func isCurrent(_ value: Snapshot) -> Bool { value == snapshot }
}

/// The gate actor reads this fence without hopping back to the UI actor. A
/// cancelled/edited/hidden setup cannot leave a queued confirmation behind.
public final class CloudCatalogAuthorizationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = UUID()
    public init() {}
    public var ticket: UUID { lock.withLock { revision } }
    public func invalidate() { lock.withLock { revision = UUID() } }
    public func isCurrent(_ ticket: UUID) -> Bool { lock.withLock { revision == ticket } }
    public func whileCurrent<T>(_ ticket: UUID, _ action: () -> T) -> T? {
        lock.withLock { revision == ticket && !Task.isCancelled ? action() : nil }
    }
}

extension CloudAdmissionGate {
    public func confirmCatalogSetup(identity: CloudAdmissionIdentity,
                                    fence: CloudCatalogAuthorizationFence, ticket: UUID) -> CloudEntryConfirmation {
        // Same K06 operations/eligibility, now executed atomically on its actor.
        // No credential/UI lock is acquired from inside this synchronous action.
        fence.whileCurrent(ticket) { CloudEntry.confirmOnGate(gate: self, identity: identity) } ?? .failed
    }
}
