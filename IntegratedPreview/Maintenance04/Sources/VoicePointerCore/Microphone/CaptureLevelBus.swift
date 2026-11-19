import Foundation

/// The level of the audio a speech recognizer is actually receiving, published for the HUD ripple.
///
/// Recognition routes use this bus for both HUD and gesture silence decisions,
/// without opening another audio engine. Doubao alone owns a dedicated meter.
public final class CaptureLevelBus: @unchecked Sendable {
    public static let shared = CaptureLevelBus()

    private let lock = NSLock()
    private var level: Float = 0
    private var publishedAt: UInt64 = 0 // 0 = nothing published (or invalidated)
    private var published: UInt64 = 0
    private var captures = 0

    public init() {}

    /// Called from the capture callback for every buffer. `now` is `DispatchTime` uptime nanoseconds.
    public func publish(_ newLevel: Float, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard newLevel.isFinite else { return }
        lock.lock()
        level = min(max(newLevel, 0), 1)
        publishedAt = max(now, 1)
        published &+= 1
        lock.unlock()
        GestureSpeechActivity.shared.recordCapture(peakLevel: min(max(newLevel, 0), 1))
    }

    /// The latest level when a capture published within `maxAgeNanoseconds`; nil when no recognizer is
    /// listening (nothing published, invalidated, too old, or from the future).
    public func recent(
        maxAgeNanoseconds: UInt64 = 300_000_000,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        guard publishedAt != 0, now >= publishedAt, now - publishedAt <= maxAgeNanoseconds else { return nil }
        return level
    }

    /// How many levels have been published (never decreases); lets a poller see that data is flowing.
    public func sampleCount() -> UInt64 { lock.withLock { published } }

    /// Forget the last reading: a new gesture must not start with the previous one's level.
    public func invalidate() {
        lock.lock()
        level = 0
        publishedAt = 0
        lock.unlock()
    }

    /// A recognizer opened / closed its capture. Never goes below zero.
    public func captureBegan() { lock.withLock { captures += 1 } }
    public func captureEnded() { lock.withLock { captures = max(0, captures - 1) } }

    /// Recognizer captures open right now; while there is one the meter does not need to be restarted.
    public var activeCaptures: Int { lock.withLock { captures } }
}
