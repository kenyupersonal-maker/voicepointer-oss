import Foundation

/// One monotonic release clock for observed changes, settle and send timings.
/// Missing release evidence stays unknown instead of inventing a new origin.
@_spi(Testing)
public final class ComposerReleaseTiming: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private var releasedAt: UInt64?
    // One authorized second swipe can wake only its original pending send.
    private var pendingExternalSend = false
    private var expeditedRequested = false
    private var expeditedConsumed = false
    private var firstReturnPostedAt: UInt64?

    public init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    public func noteRelease() {
        lock.withLock { if releasedAt == nil { releasedAt = now() } }
    }

    public func beginExternalSend() {
        lock.withLock {
            guard releasedAt != nil, !pendingExternalSend else { return }
            pendingExternalSend = true
            expeditedRequested = false
            expeditedConsumed = false
        }
    }

    /// Main-actor input admission never waits for the AX worker.
    @discardableResult
    public func requestExpeditedSend() -> Bool {
        lock.withLock {
            guard pendingExternalSend, !expeditedRequested, !expeditedConsumed else { return false }
            expeditedRequested = true
            return true
        }
    }

    public func takeExpeditedSend() -> Bool {
        lock.withLock {
            guard pendingExternalSend, expeditedRequested, !expeditedConsumed else { return false }
            expeditedConsumed = true
            return true
        }
    }

    public func finishExternalSend() {
        lock.withLock { pendingExternalSend = false; expeditedRequested = false }
    }

    public func noteReturnPosted(at timestamp: UInt64) {
        lock.withLock {
            if firstReturnPostedAt == nil { firstReturnPostedAt = timestamp }
        }
    }

    public var firstReturnMilliseconds: Int? {
        let values = lock.withLock { (releasedAt, firstReturnPostedAt) }
        guard let release = values.0, let posted = values.1, posted >= release else { return nil }
        return Int((posted - release) / 1_000_000)
    }

    public var nowNanoseconds: UInt64 { now() }

    public func elapsedMilliseconds(at timestamp: UInt64? = nil) -> Int {
        guard let release = lock.withLock({ releasedAt }) else { return -1 }
        let timestamp = timestamp ?? now()
        guard timestamp >= release else { return -1 }
        return Int((timestamp - release) / 1_000_000)
    }
}

/// Numeric evidence only: the first readable, nonblank value is a baseline,
/// never a change. Zero means that observed baseline has stayed unchanged;
/// -1 means no baseline or a gap whose commit time was not observed.
@_spi(Testing)
public struct ComposerSettleTiming: Sendable {
    private let clock: ComposerReleaseTiming
    private var previousValue: String?
    private var hadObservationGap = false
    public private(set) var lastChangeMilliseconds = -1
    public private(set) var changesMilliseconds: [Int] = []

    public init(clock: ComposerReleaseTiming) { self.clock = clock }

    public var settledMilliseconds: Int { clock.elapsedMilliseconds() }
    public var late: Int { Self.lateFlag(lastChangeMilliseconds: lastChangeMilliseconds) }

    /// Same numeric evidence for a settled sample and an exhausted observation
    /// window. `settledMs` is elapsed release time, not a claim of success.
    public var traceMessage: String {
        "composer settle timing lastChangeMs=\(lastChangeMilliseconds) settledMs=\(settledMilliseconds) " +
        "changesMs=[\(changesMilliseconds.map(String.init).joined(separator: ","))]"
    }

    public static func lateFlag(lastChangeMilliseconds: Int) -> Int {
        lastChangeMilliseconds < 0 ? -1 : (lastChangeMilliseconds > 100 ? 1 : 0)
    }

    /// Returns true only for a change between consecutive readable samples.
    @discardableResult
    public mutating func observe(value: String?) -> Bool {
        let elapsed = clock.elapsedMilliseconds()
        guard elapsed >= 0, let value else {
            previousValue = nil
            hadObservationGap = true
            lastChangeMilliseconds = -1
            return false
        }
        guard let previousValue else {
            // An initially blank field can be the IME's pre-commit gap. The
            // first later text establishes a baseline, not a timed change.
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hadObservationGap = true
            } else {
                self.previousValue = value
                lastChangeMilliseconds = hadObservationGap ? -1 : 0
            }
            return false
        }
        self.previousValue = value
        guard value != previousValue else { return false }
        lastChangeMilliseconds = elapsed
        if changesMilliseconds.count < 8 { changesMilliseconds.append(elapsed) }
        return true
    }
}
