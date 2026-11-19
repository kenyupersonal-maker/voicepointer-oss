import Foundation

// "用于增强本地识别": the same speech also goes to the Aliyun streaming recognizer while the local Qwen route
// keeps drafting. This file holds the parts of that mode that are plain values: which local routes may be
// enhanced, the finishing budget from K05, the one clock the hybrid backend reads, and the backlog rule.
//
// Pure Foundation. Nothing here admits a dictation to the cloud: that stays with `CloudAdmissionGate`, asked
// once per dictation. A route that resolves here is only one the hybrid backend knows how to run.

/// A local route the cloud may enhance, and the language both branches are asked for.
///
/// The person's choice stays the local route: the hybrid mode is a per-session modifier, never a route of its
/// own, so route identity (K01) and the saved selection are untouched. The cloud branch runs on a derived
/// snapshot with `cloudRouteID`, its own session id and no hot words.
@_spi(Testing) public struct HybridSpeechRoute: Sendable, Equatable {
    /// The cloud branch's route id (equals `CloudEntry.routeID`).
    public static let cloudRouteID = "aliyun"
    /// The bundled Qwen routes. Apple speech, Doubao (it writes into the editor itself) and the cloud routes
    /// have no local draft this mode could revise.
    public static let localRouteIDs: Set<String> = ["qwen17-rolling", "qwen06-rolling", "qwen06-incremental"]
    /// What the Aliyun backend accepts (it refuses any other language before it opens a stream).
    public static let cloudLanguages: Set<String> = ["zh", "en", "auto"]

    public let localRouteID: String
    public let language: String

    /// The route, or nil when this dictation cannot be enhanced. Ids are compared exactly: an unknown or
    /// differently spelled id resolves to nil, which keeps the dictation purely local.
    public static func resolve(isVoiceNative: Bool, localRouteID: String, language: String,
                               cloudProvider: OnlineAPIProvider = .aliyunBailian) -> HybridSpeechRoute? {
        guard isVoiceNative,
              localRouteIDs.contains(localRouteID),
              (cloudProvider.isAliyun ? cloudLanguages.contains(language) : VoiceInputSelection.isBoundedLanguageTag(language)) else { return nil }
        return HybridSpeechRoute(localRouteID: localRouteID, language: language)
    }

    private init(localRouteID: String, language: String) {
        self.localRouteID = localRouteID
        self.language = language
    }
}

/// The K05 finishing budget, in milliseconds. These are upper bounds, never sleeps: a decision is taken the
/// moment the evidence allows it, and only the single deadline timer waits.
@_spi(Testing) public struct HybridBudget: Sendable, Equatable {
    /// Hard deadline from the physical release: nothing that arrives after it can become the final text.
    public var totalMs: Int64 = 5_000
    /// How long a cloud final that is already here waits for the local branch to finish on its own (a local
    /// worker that finishes keeps its model warm; one that is cancelled does not). Bounded by `totalMs`.
    public var localMs: Int64 = 3_000
    /// How long a local final waits for the cloud. Bounded by `totalMs`.
    public var cloudTailMs: Int64 = 2_000
    /// Captured audio the cloud uplink may trail by before the cloud branch is dropped.
    public var backlogMs: Int64 = 2_000

    public init() {}
}

/// The one clock the hybrid backend reads. Monotonic milliseconds, and one way to wait until a moment: the
/// deadline timer is the only waiting the mode does. Tests pass a scripted clock.
@_spi(Testing) public struct HybridClock: Sendable {
    /// Monotonic milliseconds; only differences are meaningful.
    public let nowMs: @Sendable () -> Int64
    /// Returns once `nowMs()` has reached the given moment (at once if it already has). Throws when the
    /// waiting task is cancelled, which is how a superseded timer ends.
    public let sleepUntilMs: @Sendable (Int64) async throws -> Void

    public init(
        nowMs: @escaping @Sendable () -> Int64,
        sleepUntilMs: @escaping @Sendable (Int64) async throws -> Void
    ) {
        self.nowMs = nowMs
        self.sleepUntilMs = sleepUntilMs
    }

    /// System uptime, which never goes backwards (wall-clock changes do not move it).
    public static let live = HybridClock(
        nowMs: { liveNowMs() },
        sleepUntilMs: { target in
            // Sleeps in bounded slices and re-reads the clock, so an early wake-up never passes for the
            // deadline and a far target never overflows the nanosecond count.
            while true {
                let now = liveNowMs()
                if now >= target { return }
                let slice = min(target - now, 60_000)
                try await Task.sleep(nanoseconds: UInt64(slice) * 1_000_000)
            }
        })

    private static func liveNowMs() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1_000).rounded(.down))
    }
}

/// K05's bounded fan-out: a branch that falls more than `backlogMs` behind the captured audio is dropped
/// rather than queued. Only the cloud uplink is measured. The local branch never queues (it always reads the
/// newest snapshot), so it is never dropped for lag: lag there only makes a draft older, and the finishing
/// budget already bounds that.
@_spi(Testing) public enum FanoutBacklogPolicy {
    /// How far `consumedMs` trails `capturedMs`; never negative, and saturating instead of trapping.
    public static func backlogMs(capturedMs: Int64, consumedMs: Int64) -> Int64 {
        let (lag, overflow) = capturedMs.subtractingReportingOverflow(consumedMs)
        if overflow { return capturedMs > consumedMs ? Int64.max : 0 }
        return max(lag, 0)
    }

    /// True once the trail is strictly longer than the budget: exactly `backlogMs` behind is still fine.
    public static func isOverflowing(capturedMs: Int64, consumedMs: Int64, budget: HybridBudget) -> Bool {
        backlogMs(capturedMs: capturedMs, consumedMs: consumedMs) > max(budget.backlogMs, 0)
    }
}
