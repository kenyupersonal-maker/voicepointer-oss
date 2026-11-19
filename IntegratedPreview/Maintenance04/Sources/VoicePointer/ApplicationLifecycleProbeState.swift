import Foundation

/// Shared only to verify cleanup ordering from the nonisolated AppKit callback.
final class ApplicationLifecycleProbeState: @unchecked Sendable {
    static let shared = ApplicationLifecycleProbeState()
    private let lock = NSLock()
    private var count = 0
    private var storedPhase = "initial"
    func mark(_ phase: String) { lock.withLock { storedPhase = phase } }
    var phase: String { lock.withLock { storedPhase } }

    func didCleanup() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var cleanupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
