import Foundation

/// Thread-safe scalar audio level storage. A generation makes callbacks from a
/// stopped engine unable to contaminate a later capture session.
public final class AudioLevelBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var nextGeneration: UInt64 = 0
    private var storedLevel: Float = 0
    private var storedSampleCount: UInt64 = 0

    public init() {}

    @discardableResult
    public func beginCapture() -> UInt64 {
        lock.lock()
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        generation = nextGeneration
        storedLevel = 0
        let result = nextGeneration
        lock.unlock()
        return result
    }

    public func endCapture() {
        lock.lock()
        generation = 0
        storedLevel = 0
        lock.unlock()
    }

    @discardableResult
    public func invalidate(generation expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard expected != 0, generation == expected else { return false }
        generation = 0
        storedLevel = 0
        return true
    }

    public func set(_ level: Float, generation expected: UInt64) {
        guard level.isFinite else { return }
        lock.lock()
        guard expected != 0, generation == expected else { lock.unlock(); return }
        storedLevel = min(max(level, 0), 1)
        storedSampleCount &+= 1
        lock.unlock()
    }

    public func get() -> Float { lock.withLock { storedLevel } }
    public func sampleCount() -> UInt64 { lock.withLock { storedSampleCount } }
}
