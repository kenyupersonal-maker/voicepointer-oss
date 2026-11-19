import Foundation

// The one decider of a hybrid dictation's final text (K05): which branch's result becomes the dictation, and
// when. The local branch drafts live; the cloud branch only ever competes for the final. After the release
// the budget runs from the physical release: a cloud final that is here in time wins, a local final is the
// fallback. The budget only bounds waiting for the cloud: once the cloud is out (for any reason, including the
// hard deadline itself) the local branch finishes on its own, as on the local route alone, with no deadline. A
// local failure after the release with no cloud final to take its place reports one incomplete recognition
// (the text already written stays, nothing is sent).
//
// A value type with no clock, no timer, no tasks and no I/O. The caller passes the time with every input and
// performs the returned actions; the only waiting is the single deadline timer the `wake` action asks for.
// So every timeline here can be replayed exactly, in tests and offline against recorded branch timings.
//
// Text travels through `handle` only: the selector keeps the two candidate texts to emit one of them, and
// `HybridCounters` holds counts, lengths, milliseconds and finite reasons, never words.

/// A hybrid dictation's final-text decision.
///
/// Contract for the caller (the hybrid backend):
/// - Feed every input with the current reading of one monotonic clock (`HybridClock.nowMs`). A reading
///   earlier than the previous one is treated as the previous one.
/// - Feed inputs one at a time, and perform the returned actions in the order given before feeding the
///   next input. The selector cannot tell sessions apart: check a branch event's session id first.
/// - After a terminal action (`emitFinal` / `emitFailure`) or `.cancel`, the selector does nothing more:
///   every later input is only counted as dropped.
@_spi(Testing) public struct HybridFinalSelector: Sendable {

    /// Which branch's text became the final.
    public enum Source: String, Sendable {
        case local, cloud
    }

    /// Why the cloud branch left the session. Every reason means the same to the decision (the cloud can no
    /// longer supply a final); the reasons exist for the diagnostics line.
    public enum CloudEnd: String, Sendable {
        /// The cloud branch could not be built or started.
        case startFailed
        /// Any other failure of the stream, including a final while still listening (a stream only carries a
        /// final after it was asked to finish).
        case failed
        /// The account or the model refused the request (403 other than the free-quota code).
        case accessDenied
        /// The free quota is used up or the account owes money: the gate has paused the route persistently.
        case providerPause
        case rateLimited
        /// No network, a timeout or a 5xx.
        case transient
        case credential
        /// The gate withdrew the permit in mid-stream.
        case revoked
        /// The person withdrew the enhancement consent during the dictation.
        case consentWithdrawn
        /// The uplink trailed the captured audio by more than the budget.
        case backlog
        /// The cloud's final was empty: that is no result, so it is never chosen.
        case blankFinal
        /// A local final waited `cloudTailMs` for the cloud.
        case tailTimeout
        /// The hard deadline arrived first.
        case deadline
        /// The release was the swipe-down: nothing is sent, so the cloud is not waited for.
        case discarded
        /// The dictation was cancelled, the local branch failed while listening, or the cloud stopped itself.
        case cancelled

        /// The reason for a cloud backend's `.failed` code (the finite `ALI_*` / `CREDENTIAL_*` vocabulary).
        /// Unknown or missing codes are a plain failure. A cloud `.stopped` event is `.cancelled`.
        public static func forCloudErrorCode(_ code: String?) -> CloudEnd {
            guard let code else { return .failed }
            switch code {
            case "ALI_FREE_QUOTA_EXHAUSTED", "ALI_BALANCE_DUE": return .providerPause
            case "ALI_CLOUD_REVOKED": return .revoked
            case "ALI_RATE_LIMITED": return .rateLimited
            case "ALI_NETWORK_FAILED", "ALI_TIMEOUT", "ALI_SERVICE_UNAVAILABLE": return .transient
            case "ALI_AUTH_FAILED", "ALI_CREDENTIAL_MISSING", "ALI_CREDENTIAL_UNREADABLE",
                 "ALI_CREDENTIAL_INVALID": return .credential
            case "ALI_ACCESS_DENIED", "ALI_MODEL_UNAVAILABLE": return .accessDenied
            default: return code.hasPrefix("CREDENTIAL_") ? .credential : .failed
            }
        }
    }

    /// Why a still-running local branch is cancelled.
    public enum LocalCancel: String, Sendable {
        /// A cloud final was here and the local branch had `localMs` since the release to finish.
        case budget
        /// Not used any more: at the hard deadline only the cloud branch is dropped.
        case deadline
        /// The dictation was cancelled.
        case cancelled
    }

    /// What settled the decision, for the diagnostics line.
    public enum Reason: String, Sendable {
        /// A cloud final was chosen once the local branch had ended on its own (final or failure).
        case cloudFinal
        /// The local final was chosen because the cloud had already left the session.
        case cloudDead
        /// The local final was chosen after waiting `cloudTailMs` for the cloud.
        case tailTimeout
        /// The local final was chosen at the hard deadline, having waited there for the cloud.
        case deadline
        /// The cloud final was chosen and the local branch cancelled after `localMs`.
        case localBudget
        /// The local final was chosen because the swipe-down had cut the cloud off.
        case discard
        /// The local branch failed after the release and the cloud had no final to take its place (it had left,
        /// or was dropped at the hard deadline): `incompleteCode` is reported.
        case incomplete
        /// The local branch failed while listening; its own code is reported, as on the local route alone.
        case localFailed
    }

    /// What the backend tells the selector.
    public enum Input: Sendable, Equatable {
        case localReady
        /// A local draft; forwarded while listening, ignored after the release.
        case localPartial(text: String)
        /// While listening, this is the local backend ending the dictation itself (its 300 s timer): it
        /// counts as the release, with the local result already in hand.
        case localFinal(text: String)
        case localFailed(code: String)
        case cloudReady
        /// Cloud drafts are only counted; they are never shown (K05 rule 2).
        case cloudPartial
        case cloudFinal(text: String)
        /// The cloud branch is gone, by itself or because the backend removed it (see `CloudEnd`).
        case cloudEnded(CloudEnd)
        /// The physical release, a tap to end, or the capture's duration limit. `discard`: the release
        /// action is the swipe-down, so the cloud does not take part.
        case release(discard: Bool)
        /// The uplink monitor's reading while listening.
        case backlog(capturedMs: Int64, consumedMs: Int64)
        /// The dictation is abandoned (Esc, cancel, disconnect). Nothing is emitted afterwards.
        case cancel
        /// The deadline timer fired.
        case tick
    }

    /// What the backend must do, in the order returned. Within one batch the order is always: `stopCapture`,
    /// `finishLocal`, `cancelLocal`, `finishCloud` / `cancelCloud`, `wake`, and a terminal emit last.
    public enum Action: Sendable, Equatable {
        /// Forward the one `.ready` (from the local branch; the cloud never gates the start).
        case emitReady
        /// Forward a `.partial` with this text. Only while listening.
        case emitPartial(text: String)
        /// Forward the one `.final`, marked with its source. Terminal: stop the deadline timer and let
        /// `finish()` return once the local branch is quiet.
        case emitFinal(text: String, source: Source)
        /// Forward the one `.failed` with this code. Terminal, as above.
        case emitFailure(code: String)
        /// Stop the physical microphone now, before the rest of the batch, so both branches read the same
        /// sealed audio.
        case stopCapture
        /// Start the local branch's finish (in a task the backend awaits before it reports quiescence).
        case finishLocal
        /// Start the cloud branch's finish: the end of stream goes out, a final may follow.
        case finishCloud
        /// Cancel the still-running local branch. It emits nothing afterwards; await its cleanup.
        case cancelLocal(LocalCancel)
        /// The cloud branch is out of this session: drop its callback first, then cancel it in the
        /// background (harmless when it already stopped itself). At most once per session.
        case cancelCloud(CloudEnd)
        /// Arm the single deadline timer for this moment, replacing any earlier one. When it fires, feed
        /// `.tick` with the clock's reading, unless a decision came first. Only emitted when the moment
        /// changes, and always later than the time of the input that asked for it.
        case wake(atMs: Int64)
    }

    public enum Phase: Sendable, Equatable {
        case listening
        case finishing(releasedAtMs: Int64)
        /// The final was emitted from this source, or a failure was reported (nil).
        case decided(Source?)
        case cancelled
    }

    /// The failure reported when the local branch failed after the release and the cloud had no final to take
    /// its place. Never reported while the local branch is still running: that one is waited for.
    public static let incompleteCode = "HYBRID_FINAL_INCOMPLETE"

    public private(set) var phase: Phase = .listening
    public private(set) var counters = HybridCounters()

    /// True after the terminal emit or the cancel.
    public var isTerminal: Bool {
        switch phase {
        case .decided, .cancelled: true
        case .listening, .finishing: false
        }
    }

    private enum LocalState: Sendable {
        case running
        case final(String)
        case failed(String)
    }

    private enum CloudState: Sendable {
        case running
        case final(String)
        case ended
    }

    private let budget: HybridBudget
    private let totalMs: Int64
    private let localMs: Int64
    private let cloudTailMs: Int64
    private var local: LocalState = .running
    private var cloud: CloudState = .running
    private var captureRunning = true
    private var readyEmitted = false
    private var armedWakeMs: Int64?
    private var lastNowMs = Int64.min

    public init(budget: HybridBudget = .init()) {
        self.budget = budget
        totalMs = max(budget.totalMs, 0)
        localMs = min(max(budget.localMs, 0), max(budget.totalMs, 0))
        cloudTailMs = max(budget.cloudTailMs, 0)
    }

    public mutating func handle(_ input: Input, nowMs: Int64) -> [Action] {
        let now = max(nowMs, lastNowMs)
        lastNowMs = now
        switch phase {
        case .decided, .cancelled:
            counters.lateDropped += 1
            return []
        case .listening:
            return whileListening(input, now: now)
        case .finishing(let releasedAtMs):
            return whileFinishing(input, now: now, releasedAtMs: releasedAtMs)
        }
    }

    // MARK: - Listening

    private mutating func whileListening(_ input: Input, now: Int64) -> [Action] {
        switch input {
        case .localReady:
            if readyEmitted { return dropped() }
            readyEmitted = true
            return [.emitReady]
        case .localPartial(let text):
            counters.localPartials += 1
            if counters.firstLocalPartialAtMs == nil { counters.firstLocalPartialAtMs = now }
            return [.emitPartial(text: text)]
        case .localFinal(let text):
            var actions = beginFinishing(now: now, discard: false, localFinished: true)
            recordLocalFinal(text, now: now)
            actions += evaluate(now: now)
            return actions
        case .localFailed(let code):
            // No cloud route is verified for live drafting yet, so a local failure while listening fails the
            // dictation as it does on the local route alone (K05, local branch failure).
            local = .failed(code)
            counters.localFailedAtMs = now
            var actions: [Action] = []
            if captureRunning {
                captureRunning = false
                actions.append(.stopCapture)
            }
            if case .running = cloud { actions += endCloud(.cancelled, now: now) }
            actions.append(decide(.emitFailure(code: code), source: nil, reason: .localFailed, now: now))
            return actions
        case .cloudReady, .cloudPartial:
            return noteCloudProgress(input, now: now)
        case .cloudFinal:
            guard case .running = cloud else { return dropped() }
            return endCloud(.failed, now: now)
        case .cloudEnded(let reason):
            guard case .running = cloud else { return dropped() }
            return endCloud(reason, now: now)
        case .release(let discard):
            var actions = beginFinishing(now: now, discard: discard, localFinished: false)
            actions += evaluate(now: now)
            return actions
        case .backlog(let capturedMs, let consumedMs):
            guard case .running = cloud else { return [] }
            let lag = FanoutBacklogPolicy.backlogMs(capturedMs: capturedMs, consumedMs: consumedMs)
            counters.maxBacklogMs = max(counters.maxBacklogMs, lag)
            guard FanoutBacklogPolicy.isOverflowing(
                capturedMs: capturedMs, consumedMs: consumedMs, budget: budget) else { return [] }
            return endCloud(.backlog, now: now)
        case .cancel:
            return cancelAll()
        case .tick:
            // No timer is armed while listening; a stray tick changes nothing.
            return []
        }
    }

    private mutating func beginFinishing(now: Int64, discard: Bool, localFinished: Bool) -> [Action] {
        phase = .finishing(releasedAtMs: now)
        counters.releasedAtMs = now
        var actions: [Action] = []
        if captureRunning {
            captureRunning = false
            actions.append(.stopCapture)
        }
        if !localFinished { actions.append(.finishLocal) }
        if discard { counters.discarded = true }
        if case .running = cloud {
            if discard {
                actions += endCloud(.discarded, now: now)
            } else {
                actions.append(.finishCloud)
            }
        }
        return actions
    }

    // MARK: - Finishing

    private mutating func whileFinishing(_ input: Input, now: Int64, releasedAtMs: Int64) -> [Action] {
        if case .cancel = input { return cancelAll() }
        if let deadline = pendingDeadline(releasedAtMs: releasedAtMs), now > deadline {
            // The deadline passed before this input could be looked at (the timer ran late): the budget
            // decides as it would have on time, and the input is too late to take part. Past the hard deadline
            // with the local branch still running, only the cloud is dropped: a local result is never too late,
            // so the input is then looked at as usual (a cloud result is dropped there).
            armedWakeMs = nil
            let actions = evaluate(now: now)
            if !isTerminal, pendingDeadline(releasedAtMs: releasedAtMs) == nil {
                return actions + whileFinishing(input, now: now, releasedAtMs: releasedAtMs)
            }
            if case .tick = input {} else { counters.lateDropped += 1 }
            return actions
        }
        var actions: [Action] = []
        switch input {
        case .localReady, .localPartial:
            // The local branch does not draft after its finish; nothing it says now can be shown.
            return dropped()
        case .localFinal(let text):
            guard case .running = local else { return dropped() }
            recordLocalFinal(text, now: now)
        case .localFailed(let code):
            guard case .running = local else { return dropped() }
            local = .failed(code)
            counters.localFailedAtMs = now
        case .cloudReady, .cloudPartial:
            return noteCloudProgress(input, now: now)
        case .cloudFinal(let text):
            guard case .running = cloud else { return dropped() }
            if Self.isBlank(text) {
                actions += endCloud(.blankFinal, now: now)
            } else {
                cloud = .final(text)
                counters.cloudFinalAtMs = now
                counters.cloudUTF16 = text.utf16.count
            }
        case .cloudEnded(let reason):
            guard case .running = cloud else { return dropped() }
            actions += endCloud(reason, now: now)
        case .release(let discard):
            // A second release changes nothing, except that a swipe-down still cuts off a cloud that has not
            // answered (the local branch's own 300 s finish may have started the finishing before the person
            // let go).
            if discard {
                counters.discarded = true
                if case .running = cloud { actions += endCloud(.discarded, now: now) }
            }
        case .backlog:
            // The uplink is only measured while listening: after the release the budget bounds the wait.
            return []
        case .tick:
            armedWakeMs = nil
        case .cancel:
            return cancelAll()
        }
        actions += evaluate(now: now)
        return actions
    }

    /// The moment the budget decides if nothing else does first, or nil when nothing is waited for: the state
    /// decides at once, or only the local branch is left (the cloud is out), which ends the dictation by itself
    /// with no deadline, as on the local route alone.
    private func pendingDeadline(releasedAtMs: Int64) -> Int64? {
        let hardDeadline = Self.adding(releasedAtMs, totalMs)
        switch (local, cloud) {
        case (.final, .running):
            return min(Self.adding(counters.localFinalAtMs ?? releasedAtMs, cloudTailMs), hardDeadline)
        case (.running, .final):
            return Self.adding(releasedAtMs, localMs)
        case (.failed, .running), (.running, .running):
            return hardDeadline
        case (.running, .ended):
            return nil
        case (.final, .final), (.final, .ended), (.failed, .final), (.failed, .ended):
            return nil
        }
    }

    /// Decides when the evidence allows it, otherwise makes sure the timer is armed for the pending deadline.
    private mutating func evaluate(now: Int64) -> [Action] {
        guard case .finishing(let releasedAtMs) = phase else { return [] }
        let hardDeadline = Self.adding(releasedAtMs, totalMs)
        let deadline = pendingDeadline(releasedAtMs: releasedAtMs)
        let due = deadline.map { now >= $0 } ?? true
        switch (local, cloud) {
        case (.final(let localText), .final(let cloudText)):
            // Both finals are in hand: how far apart they are goes into the diagnostics line (a bucket, no words).
            counters.diffBucket = HybridTextDifference.bucket(localText, cloudText)
            return [decide(.emitFinal(text: cloudText, source: .cloud), source: .cloud, reason: .cloudFinal, now: now)]
        case (.failed, .final(let cloudText)):
            return [decide(.emitFinal(text: cloudText, source: .cloud), source: .cloud, reason: .cloudFinal, now: now)]
        case (.final(let localText), .ended):
            let reason: Reason = counters.cloudEnd == .discarded ? .discard : .cloudDead
            return [decide(.emitFinal(text: localText, source: .local), source: .local, reason: reason, now: now)]
        case (.failed, .ended):
            // The local branch failed after the release and the cloud has no final: one incomplete recognition.
            return [decide(.emitFailure(code: Self.incompleteCode), source: nil, reason: .incomplete, now: now)]
        case (.final(let localText), .running):
            guard due, let deadline else { return rearm(deadline) }
            let byTail = deadline < hardDeadline
            var actions = endCloud(byTail ? .tailTimeout : .deadline, now: now)
            actions.append(decide(
                .emitFinal(text: localText, source: .local), source: .local,
                reason: byTail ? .tailTimeout : .deadline, now: now))
            return actions
        case (.failed, .running):
            guard due else { return rearm(deadline) }
            var actions = endCloud(.deadline, now: now)
            actions.append(decide(.emitFailure(code: Self.incompleteCode), source: nil, reason: .incomplete, now: now))
            return actions
        case (.running, .final(let cloudText)):
            guard due else { return rearm(deadline) }
            return [
                .cancelLocal(.budget),
                decide(.emitFinal(text: cloudText, source: .cloud), source: .cloud, reason: .localBudget, now: now),
            ]
        case (.running, .ended):
            // Only the local branch is left: its own final or failure decides, with no deadline.
            return []
        case (.running, .running):
            guard due else { return rearm(deadline) }
            // At the hard deadline only the cloud is dropped; the local branch then finishes on its own.
            return endCloud(.deadline, now: now)
        }
    }

    // MARK: - Shared steps

    private mutating func recordLocalFinal(_ text: String, now: Int64) {
        local = .final(text)
        counters.localFinalAtMs = now
        counters.localUTF16 = text.utf16.count
    }

    private mutating func noteCloudProgress(_ input: Input, now: Int64) -> [Action] {
        guard case .running = cloud else { return dropped() }
        if case .cloudReady = input {
            if counters.cloudReadyAtMs != nil { return dropped() }
            counters.cloudReadyAtMs = now
        } else {
            counters.cloudPartials += 1
            if counters.firstCloudPartialAtMs == nil { counters.firstCloudPartialAtMs = now }
        }
        return []
    }

    private mutating func endCloud(_ reason: CloudEnd, now: Int64) -> [Action] {
        cloud = .ended
        counters.cloudEnd = reason
        counters.cloudEndedAtMs = now
        return [.cancelCloud(reason)]
    }

    private mutating func decide(_ terminal: Action, source: Source?, reason: Reason, now: Int64) -> Action {
        phase = .decided(source)
        counters.decidedAtMs = now
        counters.reason = reason
        armedWakeMs = nil
        return terminal
    }

    private mutating func rearm(_ deadline: Int64?) -> [Action] {
        guard let deadline, armedWakeMs != deadline else { return [] }
        armedWakeMs = deadline
        return [.wake(atMs: deadline)]
    }

    private mutating func cancelAll() -> [Action] {
        var actions: [Action] = []
        if captureRunning {
            captureRunning = false
            actions.append(.stopCapture)
        }
        if case .running = local { actions.append(.cancelLocal(.cancelled)) }
        if case .running = cloud {
            cloud = .ended
            counters.cloudEnd = .cancelled
            actions.append(.cancelCloud(.cancelled))
        }
        phase = .cancelled
        armedWakeMs = nil
        return actions
    }

    private mutating func dropped() -> [Action] {
        counters.lateDropped += 1
        return []
    }

    /// An empty or white-space-only final is no result: choosing it would present "nothing was said" as a
    /// complete recognition.
    private static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    private static func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        if overflow { return b > 0 ? Int64.max : Int64.min }
        return sum
    }
}

/// What a hybrid dictation did, for the one diagnostics line: counts, UTF-16 lengths, milliseconds on the
/// caller's clock, and finite reasons. Never text.
@_spi(Testing) public struct HybridCounters: Sendable, Equatable {
    /// Local drafts forwarded while listening.
    public internal(set) var localPartials = 0
    /// Cloud drafts seen (never shown).
    public internal(set) var cloudPartials = 0
    /// Inputs that could not take part: anything after the decision or the cancel, a branch speaking again
    /// after its own end, local drafts after the release, and results that came after an overdue deadline (a
    /// local final or failure past the hard deadline still takes part while nothing is decided).
    public internal(set) var lateDropped = 0
    public internal(set) var firstLocalPartialAtMs: Int64?
    public internal(set) var firstCloudPartialAtMs: Int64?
    public internal(set) var cloudReadyAtMs: Int64?
    /// When the finishing began: the release, or the local branch's own final while listening.
    public internal(set) var releasedAtMs: Int64?
    /// The release was the swipe-down.
    public internal(set) var discarded = false
    public internal(set) var localFinalAtMs: Int64?
    public internal(set) var localFailedAtMs: Int64?
    /// When a usable cloud final arrived.
    public internal(set) var cloudFinalAtMs: Int64?
    /// Why the cloud left the session, if it did before or at the decision.
    public internal(set) var cloudEnd: HybridFinalSelector.CloudEnd?
    public internal(set) var cloudEndedAtMs: Int64?
    /// The largest uplink trail seen while listening.
    public internal(set) var maxBacklogMs: Int64 = 0
    public internal(set) var localUTF16: Int?
    public internal(set) var cloudUTF16: Int?
    /// How far the two finals were apart (punctuation, spacing and case ignored) when both existed at the
    /// decision; `.unavailable` otherwise. A bucket, never words.
    public internal(set) var diffBucket: HybridTextDifference.Bucket = .unavailable
    public internal(set) var decidedAtMs: Int64?
    public internal(set) var reason: HybridFinalSelector.Reason?
}

/// How different two finals are, as a bucket for the diagnostics line. The number is the edit distance between
/// the two texts with punctuation, white space, symbols and letter case taken out: what is left is the words
/// the two recognizers heard, so a comma or a full stop the cloud adds does not count. Only the bucket leaves
/// this type, never a word; a text that is too long is not measured (the work stays small and bounded).
@_spi(Testing) public enum HybridTextDifference {
    /// The finite labels of the diagnostics line (`diffBucket=`).
    public enum Bucket: String, Sendable {
        case same = "0"
        case oneOrTwo = "1-2"
        case threeToFive = "3-5"
        case sixToTen = "6-10"
        case elevenOrMore = "11+"
        /// One of the texts did not exist at the decision, or one was too long to measure.
        case unavailable = "na"
    }

    /// The longest text, in characters once the clean-up is done, that is measured.
    public static let maxCharacters = 600

    public static func bucket(_ first: String, _ second: String) -> Bucket {
        let a = comparable(first)
        let b = comparable(second)
        guard a.count <= maxCharacters, b.count <= maxCharacters else { return .unavailable }
        return bucket(forDistance: editDistance(a, b))
    }

    public static func bucket(forDistance distance: Int) -> Bucket {
        switch distance {
        case ..<1: .same
        case 1...2: .oneOrTwo
        case 3...5: .threeToFive
        case 6...10: .sixToTen
        default: .elevenOrMore
        }
    }

    /// The characters that carry the words: no white space, punctuation or symbols, and lower case.
    static func comparable(_ text: String) -> [Character] {
        Array(text.lowercased().filter { !($0.isWhitespace || $0.isPunctuation || $0.isSymbol) })
    }

    /// The Levenshtein distance over characters (insert, delete, replace: one each), in two rows.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let replace = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(replace, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
