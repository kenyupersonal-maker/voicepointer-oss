import Foundation
@_spi(Testing) import VoicePointerCore

/// The pure parts of "用于增强本地识别": the final-text decision and its K05 budget, replayed on the scripted
/// timelines T1–T17 and on a thousand shuffled ones; the budget and backlog values; the lexicon guard for cloud
/// finals; which routes can be enhanced; and that a final of another length replaces only this dictation's
/// own span of the field.
///
/// The timelines replay the selector the way the hybrid backend runs it: inputs in time order, one deadline
/// timer, a new `wake` replacing the armed one, and a `.tick` when the timer fires unless a decision came first.
/// Every expected line is written down from K05 and the plan's timeline table, not read back from the code.
enum HybridPureChecks {
    typealias Selector = HybridFinalSelector
    typealias Input = HybridFinalSelector.Input
    typealias Action = HybridFinalSelector.Action

    static func run() -> [String] {
        tally().failures
    }

    /// The failures and how many expectations ran.
    static func tally() -> Tally {
        var tally = Tally()
        tally.merge(timelineChecks())
        tally.merge(extraTimelineChecks())
        tally.merge(propertyChecks())
        tally.merge(budgetAndBacklogChecks())
        tally.merge(projectionGuardChecks())
        tally.merge(routeChecks())
        tally.merge(diffBucketChecks())
        tally.merge(inlineDraftChecks())
        return tally
    }

    struct Tally {
        var checks = 0
        var failures: [String] = []

        mutating func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
            checks += 1
            if !condition { failures.append("hybrid: " + label()) }
        }

        mutating func merge(_ other: Tally) {
            checks += other.checks
            failures += other.failures
        }
    }

    // MARK: - Scripted driver

    /// One input with the actions it produced; `fromTimer` marks the tick the deadline timer delivered.
    struct Line: Equatable {
        let atMs: Int64
        let input: Input
        let actions: [Action]
        let fromTimer: Bool
    }

    struct Run {
        var lines: [Line] = []
        var phaseAfter: [Selector.Phase] = []
        var lateDroppedAfter: [Int] = []
        var armedAfter: [Int64?] = []
        var selector: Selector
        var overran = false
    }

    /// Feeds the script in time order (script order at equal times, and before a timer due at the same moment)
    /// and plays the backend's timer: one at a time, replaced by each `wake`, dropped at the decision, and
    /// delivering `.tick` `timerLateMs` after its moment.
    static func drive(_ script: [(Int64, Input)], budget: HybridBudget = .init(), timerLateMs: Int64 = 0) -> Run {
        let ordered = script.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }
            .map(\.element)
        var run = Run(selector: Selector(budget: budget))
        var armed: Int64?
        var next = 0
        for _ in 0..<10_000 {
            let inputAt: Int64? = next < ordered.count ? ordered[next].0 : nil
            let timerAt: Int64? = armed.map { saturating($0, timerLateMs) }
            let useTimer: Bool
            switch (inputAt, timerAt) {
            case (nil, nil): return run
            case (nil, .some): useTimer = true
            case (.some, nil): useTimer = false
            case (.some(let input), .some(let timer)): useTimer = timer < input
            }
            let at: Int64
            let input: Input
            if useTimer, let timerAt {
                at = timerAt
                input = .tick
                armed = nil
            } else {
                at = ordered[next].0
                input = ordered[next].1
                next += 1
            }
            let actions = run.selector.handle(input, nowMs: at)
            for case .wake(let moment) in actions { armed = moment }
            if run.selector.isTerminal { armed = nil }
            run.lines.append(Line(atMs: at, input: input, actions: actions, fromTimer: useTimer))
            run.phaseAfter.append(run.selector.phase)
            run.lateDroppedAfter.append(run.selector.counters.lateDropped)
            run.armedAfter.append(armed)
        }
        run.overran = true
        return run
    }

    static func line(_ atMs: Int64, _ input: Input, _ actions: [Action] = []) -> Line {
        Line(atMs: atMs, input: input, actions: actions, fromTimer: false)
    }

    static func timer(_ atMs: Int64, _ actions: [Action]) -> Line {
        Line(atMs: atMs, input: .tick, actions: actions, fromTimer: true)
    }

    /// Replays the non-timer lines and compares every line produced (timer ticks included) with `expected`.
    static func replay(
        _ id: String, _ expected: [Line], budget: HybridBudget = .init(), timerLateMs: Int64 = 0
    ) -> (Run, [String]) {
        let script = expected.filter { !$0.fromTimer }.map { ($0.atMs, $0.input) }
        let run = drive(script, budget: budget, timerLateMs: timerLateMs)
        var problems: [String] = []
        if run.lines.count != expected.count {
            problems.append("hybrid: \(id): \(run.lines.count) lines, expected \(expected.count): "
                + run.lines.map(describe).joined(separator: " | "))
        }
        for (index, pair) in zip(run.lines, expected).enumerated() where pair.0 != pair.1 {
            problems.append("hybrid: \(id) line \(index): got \(describe(pair.0)), expected \(describe(pair.1))")
            break
        }
        return (run, problems)
    }

    static func describe(_ line: Line) -> String {
        "\(line.atMs)\(line.fromTimer ? " timer" : "") \(line.input) -> \(line.actions)"
    }

    static func terminal(of run: Run) -> Action? {
        for line in run.lines {
            if let last = line.actions.last, isTerminal(last) { return last }
        }
        return nil
    }

    static func isTerminal(_ action: Action) -> Bool {
        switch action {
        case .emitFinal, .emitFailure: true
        default: false
        }
    }

    static func saturating(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? Int64.max : Int64.min) : sum
    }

    // MARK: - HP-01…17: the plan's timelines (release at r)

    static func timelineChecks() -> Tally {
        var t = Tally()
        func replay(_ id: String, _ lines: [Line], budget: HybridBudget = .init()) -> Run {
            let (run, problems) = HybridPureChecks.replay(id, lines, budget: budget)
            t.checks += 1
            t.failures += problems
            return run
        }
        func decided(_ run: Run, _ id: String, at: Int64, _ phase: Selector.Phase, _ reason: Selector.Reason) {
            let c = run.selector.counters
            t.expect(run.selector.phase == phase, "\(id): phase \(run.selector.phase), expected \(phase)")
            t.expect(c.decidedAtMs == at, "\(id): decided at \(c.decidedAtMs.map(String.init) ?? "nil"), expected \(at)")
            t.expect(c.reason == reason, "\(id): reason \(c.reason.map { $0.rawValue } ?? "nil"), expected \(reason)")
        }
        let r: Int64 = 10_000
        let local = "本地终稿"
        let cloud = "云端终稿"
        let failure = "LOCAL_WORKER_FAILED"
        let released: [Action] = [.stopCapture, .finishLocal, .finishCloud, .wake(atMs: r + 5_000)]

        // T1: the local final first, the cloud's inside the tail: decided by the cloud's arrival, no timer.
        let t1 = replay("HP-01 T1", [
            line(2_000, .localReady, [.emitReady]),
            line(2_300, .cloudReady),
            line(4_000, .localPartial(text: "本地"), [.emitPartial(text: "本地")]),
            line(4_200, .cloudPartial),
            line(5_000, .backlog(capturedMs: 5_000, consumedMs: 4_800)),
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: local), [.wake(atMs: r + 2_600)]),
            line(r + 1_400, .cloudFinal(text: cloud), [.emitFinal(text: cloud, source: .cloud)]),
        ])
        decided(t1, "HP-01 T1", at: r + 1_400, .decided(.cloud), .cloudFinal)
        let c1 = t1.selector.counters
        t.expect(
            c1.localPartials == 1 && c1.cloudPartials == 1 && c1.cloudReadyAtMs == 2_300
                && c1.firstLocalPartialAtMs == 4_000 && c1.firstCloudPartialAtMs == 4_200,
            "HP-01 T1 draft counters")
        t.expect(
            c1.maxBacklogMs == 200 && c1.lateDropped == 0 && c1.localUTF16 == 4 && c1.cloudUTF16 == 4
                && c1.releasedAtMs == r && c1.localFinalAtMs == r + 600 && c1.cloudFinalAtMs == r + 1_400
                && c1.cloudEnd == nil && !c1.discarded,
            "HP-01 T1 moments and lengths")

        // T2: the cloud never answers: the local final waits exactly cloudTailMs.
        let t2 = replay("HP-02 T2", [
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: local), [.wake(atMs: r + 2_600)]),
            timer(r + 2_600, [.cancelCloud(.tailTimeout), .emitFinal(text: local, source: .local)]),
        ])
        decided(t2, "HP-02 T2", at: r + 2_600, .decided(.local), .tailTimeout)
        t.expect(t2.selector.counters.cloudEnd == .tailTimeout, "HP-02 T2 the cloud ends by the tail timeout")

        // T3: the cloud first; the local finishes inside localMs, then the cloud wins at once.
        let t3 = replay("HP-03 T3", [
            line(r, .release(discard: false), released),
            line(r + 500, .cloudFinal(text: cloud), [.wake(atMs: r + 3_000)]),
            line(r + 1_200, .localFinal(text: local), [.emitFinal(text: cloud, source: .cloud)]),
        ])
        decided(t3, "HP-03 T3", at: r + 1_200, .decided(.cloud), .cloudFinal)

        // T4: the local is stuck: at release+localMs it is cancelled and the cloud wins.
        let t4 = replay("HP-04 T4", [
            line(r, .release(discard: false), released),
            line(r + 500, .cloudFinal(text: cloud), [.wake(atMs: r + 3_000)]),
            timer(r + 3_000, [.cancelLocal(.budget), .emitFinal(text: cloud, source: .cloud)]),
        ])
        decided(t4, "HP-04 T4", at: r + 3_000, .decided(.cloud), .localBudget)

        // T5: a late local final: the cloud's tail is cut by the hard deadline (no new wake: T is armed).
        let t5 = replay("HP-05 T5", [
            line(r, .release(discard: false), released),
            line(r + 3_500, .localFinal(text: local)),
            timer(r + 5_000, [.cancelCloud(.deadline), .emitFinal(text: local, source: .local)]),
        ])
        decided(t5, "HP-05 T5", at: r + 5_000, .decided(.local), .deadline)

        // T6: the cloud after the deadline is dropped.
        let t6 = replay("HP-06 T6", [
            line(r, .release(discard: false), released),
            line(r + 4_000, .localFinal(text: local)),
            timer(r + 5_000, [.cancelCloud(.deadline), .emitFinal(text: local, source: .local)]),
            line(r + 5_100, .cloudFinal(text: cloud)),
        ])
        decided(t6, "HP-06 T6", at: r + 5_000, .decided(.local), .deadline)
        t.expect(
            t6.selector.counters.lateDropped == 1 && t6.selector.counters.cloudFinalAtMs == nil,
            "HP-06 T6 the late cloud final is counted and ignored")

        // T7: the quota runs out while listening: the local keeps drafting, the release does not wait, and with
        // the cloud out there is no deadline at all (the local branch ends the dictation as on its own route).
        let t7 = replay("HP-07 T7", [
            line(r - 1_000, .cloudEnded(.providerPause), [.cancelCloud(.providerPause)]),
            line(r - 500, .localPartial(text: "继续"), [.emitPartial(text: "继续")]),
            line(r, .release(discard: false), [.stopCapture, .finishLocal]),
            line(r + 700, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ])
        decided(t7, "HP-07 T7", at: r + 700, .decided(.local), .cloudDead)
        t.expect(t7.selector.counters.cloudEnd == .providerPause, "HP-07 T7 the cloud end is the provider pause")

        // T8: the local fails while finishing; a valid cloud final is still chosen.
        let t8 = replay("HP-08 T8", [
            line(r, .release(discard: false), released),
            line(r + 800, .localFailed(code: failure)),
            line(r + 1_500, .cloudFinal(text: cloud), [.emitFinal(text: cloud, source: .cloud)]),
        ])
        decided(t8, "HP-08 T8", at: r + 1_500, .decided(.cloud), .cloudFinal)

        // T9: both fail after the release: one incomplete recognition, reported at the second failure.
        let t9 = replay("HP-09 T9", [
            line(r, .release(discard: false), released),
            line(r + 800, .localFailed(code: failure)),
            line(r + 900, .cloudEnded(.transient), [
                .cancelCloud(.transient), .emitFailure(code: Selector.incompleteCode),
            ]),
        ])
        decided(t9, "HP-09 T9", at: r + 900, .decided(nil), .incomplete)

        // T10: nothing by the deadline: at T only the cloud is dropped; the local branch is not cancelled and
        // its final, however late, is the dictation (the 5 s budget only bounds waiting for the cloud).
        let t10 = replay("HP-10 T10", [
            line(r, .release(discard: false), released),
            timer(r + 5_000, [.cancelCloud(.deadline)]),
            line(r + 5_600, .cloudFinal(text: cloud)),
            line(r + 9_000, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ])
        decided(t10, "HP-10 T10", at: r + 9_000, .decided(.local), .cloudDead)
        t.expect(
            t10.selector.counters.cloudEnd == .deadline && t10.selector.counters.lateDropped == 1
                && t10.selector.counters.cloudFinalAtMs == nil,
            "HP-10 T10 the cloud is out at T and its late final is dropped")
        t.expect(Selector.incompleteCode == "HYBRID_FINAL_INCOMPLETE", "HP-10 the incomplete code")
        // ...and a local failure after the deadline is the one incomplete recognition.
        let t10b = replay("HP-10 T10 local failure after the deadline", [
            line(r, .release(discard: false), released),
            timer(r + 5_000, [.cancelCloud(.deadline)]),
            line(r + 6_000, .localFailed(code: failure), [.emitFailure(code: Selector.incompleteCode)]),
        ])
        decided(t10b, "HP-10 T10 local failure after the deadline", at: r + 6_000, .decided(nil), .incomplete)
        // The local branch failed first and the cloud never answers: incomplete at T, the cloud dropped there.
        let t10c = replay("HP-10 T10 local failure, cloud silent until T", [
            line(r, .release(discard: false), released),
            line(r + 1_000, .localFailed(code: failure)),
            timer(r + 5_000, [.cancelCloud(.deadline), .emitFailure(code: Selector.incompleteCode)]),
        ])
        decided(t10c, "HP-10 T10 local failure, cloud silent until T", at: r + 5_000, .decided(nil), .incomplete)
        // A late timer: the local final just after T, before the tick, is still the dictation.
        let (t10d, t10dProblems) = HybridPureChecks.replay("HP-10 T10 late timer, local final just after T", [
            line(r, .release(discard: false), released),
            line(r + 5_010, .localFinal(text: local), [.cancelCloud(.deadline), .emitFinal(text: local, source: .local)]),
        ], timerLateMs: 300)
        t.checks += 1
        t.failures += t10dProblems
        decided(t10d, "HP-10 T10 late timer, local final just after T", at: r + 5_010, .decided(.local), .cloudDead)
        t.expect(t10d.selector.counters.lateDropped == 0, "HP-10 T10 a local final past T is never too late")

        // T11: an empty cloud final is no result; the local final is chosen at once.
        let t11 = replay("HP-11 T11", [
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: local), [.wake(atMs: r + 2_600)]),
            line(r + 900, .cloudFinal(text: ""), [.cancelCloud(.blankFinal), .emitFinal(text: local, source: .local)]),
        ])
        decided(t11, "HP-11 T11", at: r + 900, .decided(.local), .cloudDead)
        let t11b = replay("HP-11 T11 blank cloud before the local", [
            line(r, .release(discard: false), released),
            line(r + 300, .cloudFinal(text: " \n\u{3000}"), [.cancelCloud(.blankFinal)]),
            line(r + 600, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ])
        decided(t11b, "HP-11 T11 blank cloud before the local", at: r + 600, .decided(.local), .cloudDead)
        let t11c = replay("HP-11 T11 blank cloud after a local failure", [
            line(r, .release(discard: false), released),
            line(r + 400, .localFailed(code: failure)),
            line(r + 700, .cloudFinal(text: ""), [.cancelCloud(.blankFinal), .emitFailure(code: Selector.incompleteCode)]),
        ])
        decided(t11c, "HP-11 T11 blank cloud after a local failure", at: r + 700, .decided(nil), .incomplete)

        // T12: the swipe-down: the cloud is cut off at the release and cannot come back.
        let t12 = replay("HP-12 T12", [
            line(r, .release(discard: true), [
                .stopCapture, .finishLocal, .cancelCloud(.discarded),
            ]),
            line(r + 400, .cloudFinal(text: cloud)),
            line(r + 600, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ])
        decided(t12, "HP-12 T12", at: r + 600, .decided(.local), .discard)
        t.expect(
            t12.selector.counters.discarded && t12.selector.counters.lateDropped == 1,
            "HP-12 T12 the swipe-down is on record and the cloud's answer is dropped")

        // T13: cancel: both branches cancelled, nothing emitted, nothing later counts.
        let t13 = replay("HP-13 T13", [
            line(r, .release(discard: false), released),
            line(r + 300, .cancel, [.cancelLocal(.cancelled), .cancelCloud(.cancelled)]),
            line(r + 600, .localFinal(text: local)),
        ])
        t.expect(t13.selector.phase == .cancelled && terminal(of: t13) == nil, "HP-13 T13 cancelled without an event")
        t.expect(
            t13.selector.counters.lateDropped == 1 && t13.selector.counters.decidedAtMs == nil,
            "HP-13 T13 the local final after the cancel is dropped")
        let t13b = replay("HP-13 T13 cancel while listening", [
            line(1_000, .localReady, [.emitReady]),
            line(2_000, .cancel, [.stopCapture, .cancelLocal(.cancelled), .cancelCloud(.cancelled)]),
            line(r, .release(discard: false)),
        ])
        t.expect(t13b.selector.phase == .cancelled && terminal(of: t13b) == nil, "HP-13 T13 cancel while listening")
        let t13c = replay("HP-13 T13 cancel after the cloud left", [
            line(1_000, .cloudEnded(.transient), [.cancelCloud(.transient)]),
            line(2_000, .cancel, [.stopCapture, .cancelLocal(.cancelled)]),
        ])
        t.expect(t13c.selector.phase == .cancelled, "HP-13 T13 cancel after the cloud left")

        // T14: repeats and late callbacks never change the decision; each is counted.
        let t14 = replay("HP-14 T14", [
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: local), [.wake(atMs: r + 2_600)]),
            line(r + 1_400, .cloudFinal(text: cloud), [.emitFinal(text: cloud, source: .cloud)]),
            line(r + 1_500, .cloudFinal(text: "重复的云")),
            line(r + 1_600, .localFinal(text: "重复的本地")),
        ])
        decided(t14, "HP-14 T14", at: r + 1_400, .decided(.cloud), .cloudFinal)
        t.expect(t14.selector.counters.lateDropped == 2, "HP-14 T14 two repeats counted as dropped")
        let t14b = replay("HP-14 T14 repeat before the decision", [
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: local), [.wake(atMs: r + 2_600)]),
            line(r + 700, .localFinal(text: "第二个本地")),
            timer(r + 2_600, [.cancelCloud(.tailTimeout), .emitFinal(text: local, source: .local)]),
        ])
        t.expect(t14b.selector.counters.lateDropped == 1, "HP-14 T14 a repeat before the decision is dropped")

        // T15: the local fails while listening: the dictation fails at once, as on the local route alone.
        let t15 = replay("HP-15 T15", [
            line(r - 3_000, .localReady, [.emitReady]),
            line(r - 2_000, .localPartial(text: "半句"), [.emitPartial(text: "半句")]),
            line(r - 500, .localFailed(code: "LOCAL_CAPTURE_FAILED"), [
                .stopCapture, .cancelCloud(.cancelled), .emitFailure(code: "LOCAL_CAPTURE_FAILED"),
            ]),
            line(r, .release(discard: false)),
            line(r + 500, .cloudFinal(text: cloud)),
        ])
        decided(t15, "HP-15 T15", at: r - 500, .decided(nil), .localFailed)
        t.expect(t15.selector.counters.lateDropped == 2, "HP-15 T15 the release and the cloud after it are dropped")

        // T16: the 300 s limit. (a) The capture's limit is fed as the release.
        let limit: Int64 = 300_000
        let t16 = replay("HP-16 T16 duration limit", [
            line(limit, .release(discard: false), [
                .stopCapture, .finishLocal, .finishCloud, .wake(atMs: limit + 5_000),
            ]),
            line(limit + 600, .localFinal(text: local), [.wake(atMs: limit + 2_600)]),
            line(limit + 1_400, .cloudFinal(text: cloud), [.emitFinal(text: cloud, source: .cloud)]),
        ])
        decided(t16, "HP-16 T16 duration limit", at: limit + 1_400, .decided(.cloud), .cloudFinal)
        // (b) The local backend's own 300 s finish while listening is the release, with the local result in hand;
        // the Coordinator's later release changes nothing.
        let t16b = replay("HP-16 T16 local final while listening", [
            line(limit, .localFinal(text: local), [.stopCapture, .finishCloud, .wake(atMs: limit + 2_000)]),
            line(limit + 50, .release(discard: false)),
            line(limit + 900, .cloudFinal(text: cloud), [.emitFinal(text: cloud, source: .cloud)]),
        ])
        decided(t16b, "HP-16 T16 local final while listening", at: limit + 900, .decided(.cloud), .cloudFinal)
        t.expect(
            t16b.selector.counters.releasedAtMs == limit && t16b.selector.counters.lateDropped == 0,
            "HP-16 T16 the finishing starts at the local final; the later release is not a drop")
        let t16c = replay("HP-16 T16 local final while listening, no cloud", [
            line(limit, .localFinal(text: local), [.stopCapture, .finishCloud, .wake(atMs: limit + 2_000)]),
            timer(limit + 2_000, [.cancelCloud(.tailTimeout), .emitFinal(text: local, source: .local)]),
        ])
        decided(t16c, "HP-16 T16 local final while listening, no cloud", at: limit + 2_000, .decided(.local), .tailTimeout)
        let t16d = replay("HP-16 T16 local final while listening, then the swipe-down", [
            line(limit, .localFinal(text: local), [.stopCapture, .finishCloud, .wake(atMs: limit + 2_000)]),
            line(limit + 500, .release(discard: true), [
                .cancelCloud(.discarded), .emitFinal(text: local, source: .local),
            ]),
        ])
        decided(t16d, "HP-16 T16 swipe-down after the local's own finish", at: limit + 500, .decided(.local), .discard)
        let t16e = replay("HP-16 T16 local final while listening, cloud already gone", [
            line(limit - 1_000, .cloudEnded(.transient), [.cancelCloud(.transient)]),
            line(limit, .localFinal(text: local), [.stopCapture, .emitFinal(text: local, source: .local)]),
        ])
        decided(t16e, "HP-16 T16 local final, cloud gone", at: limit, .decided(.local), .cloudDead)

        // T17: the uplink never moves: dropped at the first 250 ms check that is more than 2000 ms behind.
        var t17Lines: [Line] = []
        for moment in stride(from: Int64(250), through: 2_000, by: 250) {
            t17Lines.append(line(moment, .backlog(capturedMs: moment, consumedMs: 0)))
        }
        t17Lines += [
            line(2_250, .backlog(capturedMs: 2_250, consumedMs: 0), [.cancelCloud(.backlog)]),
            line(2_500, .backlog(capturedMs: 2_500, consumedMs: 0)),
            line(2_600, .localPartial(text: "仍在出字"), [.emitPartial(text: "仍在出字")]),
            line(3_000, .release(discard: false), [.stopCapture, .finishLocal]),
            line(3_600, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ]
        let t17 = replay("HP-17 T17", t17Lines)
        decided(t17, "HP-17 T17", at: 3_600, .decided(.local), .cloudDead)
        let c17 = t17.selector.counters
        t.expect(
            c17.maxBacklogMs == 2_250 && c17.cloudEnd == .backlog && c17.cloudEndedAtMs == 2_250 && c17.lateDropped == 0,
            "HP-17 T17 backlog on record")
        var keepingUp: [Line] = []
        for moment in stride(from: Int64(2_250), through: 6_000, by: 250) {
            keepingUp.append(line(moment, .backlog(capturedMs: moment, consumedMs: moment - 2_000)))
        }
        let t17b = replay("HP-17 T17 an uplink exactly 2000 ms behind is kept", keepingUp)
        t.expect(t17b.selector.counters.cloudEnd == nil, "HP-17 T17 2000 ms behind is not dropped")
        return t
    }

    // MARK: - The situations the plan's table adds to the timelines

    static func extraTimelineChecks() -> Tally {
        var t = Tally()
        func replay(_ id: String, _ lines: [Line], budget: HybridBudget = .init(), timerLateMs: Int64 = 0) -> Run {
            let (run, problems) = HybridPureChecks.replay(id, lines, budget: budget, timerLateMs: timerLateMs)
            t.checks += 1
            t.failures += problems
            return run
        }
        let r: Int64 = 10_000
        let local = "本地终稿"
        let cloud = "云端终稿"
        let released: [Action] = [.stopCapture, .finishLocal, .finishCloud, .wake(atMs: r + 5_000)]

        // The cloud leaves while finishing: decide again at once.
        let e1 = replay("HP-X1 cloud ends after the local final", [
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: local), [.wake(atMs: r + 2_600)]),
            line(r + 1_000, .cloudEnded(.rateLimited), [
                .cancelCloud(.rateLimited), .emitFinal(text: local, source: .local),
            ]),
        ])
        t.expect(e1.selector.counters.decidedAtMs == r + 1_000, "HP-X1 decided when the cloud ended")
        let e2 = replay("HP-X2 cloud ends before the local final", [
            line(r, .release(discard: false), released),
            line(r + 1_000, .cloudEnded(.transient), [.cancelCloud(.transient)]),
            line(r + 2_000, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ])
        t.expect(e2.selector.counters.reason == .cloudDead, "HP-X2 the local final is taken as soon as it comes")
        let e3 = replay("HP-X3 cloud ends and the local finishes long after the deadline", [
            line(r, .release(discard: false), released),
            line(r + 1_000, .cloudEnded(.transient), [.cancelCloud(.transient)]),
            timer(r + 5_000, []),
            line(r + 20_000, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ])
        t.expect(
            e3.selector.counters.reason == .cloudDead && e3.selector.counters.decidedAtMs == r + 20_000,
            "HP-X3 no deadline once the cloud is out: the local final is the dictation")
        let e3b = replay("HP-X3 cloud ends, the local fails after the deadline", [
            line(r, .release(discard: false), released),
            line(r + 1_000, .cloudEnded(.transient), [.cancelCloud(.transient)]),
            timer(r + 5_000, []),
            line(r + 7_000, .localFailed(code: "LOCAL_WORKER_FAILED"), [.emitFailure(code: Selector.incompleteCode)]),
        ])
        t.expect(e3b.selector.counters.reason == .incomplete, "HP-X3 the local failure is the incomplete recognition")

        // A cloud final with the local still finishing, after localMs: cancel the local and take the cloud now.
        let e4 = replay("HP-X4 cloud final after localMs", [
            line(r, .release(discard: false), released),
            line(r + 3_500, .cloudFinal(text: cloud), [.cancelLocal(.budget), .emitFinal(text: cloud, source: .cloud)]),
        ])
        t.expect(e4.selector.counters.reason == .localBudget, "HP-X4 the local budget ran out")
        _ = replay("HP-X5 cloud final exactly at localMs", [
            line(r, .release(discard: false), released),
            line(r + 3_000, .cloudFinal(text: cloud), [.cancelLocal(.budget), .emitFinal(text: cloud, source: .cloud)]),
        ])

        // Consent withdrawn: while listening the cloud goes and the release does not wait; while finishing a
        // local final in hand is taken at once.
        _ = replay("HP-X6 consent withdrawn while listening", [
            line(r - 2_000, .cloudEnded(.consentWithdrawn), [.cancelCloud(.consentWithdrawn)]),
            line(r, .release(discard: false), [.stopCapture, .finishLocal]),
            line(r + 800, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ])
        _ = replay("HP-X7 consent withdrawn while finishing", [
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: local), [.wake(atMs: r + 2_600)]),
            line(r + 700, .cloudEnded(.consentWithdrawn), [
                .cancelCloud(.consentWithdrawn), .emitFinal(text: local, source: .local),
            ]),
        ])

        // The timer runs 300 ms late: the deadline still decides, the cloud final after it is dropped.
        let e8 = replay("HP-X8 overdue deadline", [
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: local), [.wake(atMs: r + 2_600)]),
            line(r + 2_700, .cloudFinal(text: cloud), [.cancelCloud(.tailTimeout), .emitFinal(text: local, source: .local)]),
        ], timerLateMs: 300)
        t.expect(
            e8.selector.counters.lateDropped == 1 && e8.selector.counters.cloudFinalAtMs == nil,
            "HP-X8 the cloud final after the overdue deadline is dropped")
        let e8b = replay("HP-X8 overdue deadline, input on the deadline itself still counts", [
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: local), [.wake(atMs: r + 2_600)]),
            line(r + 2_600, .cloudFinal(text: cloud), [.emitFinal(text: cloud, source: .cloud)]),
        ], timerLateMs: 300)
        t.expect(e8b.selector.counters.reason == .cloudFinal, "HP-X8 a final at the deadline's own moment is in time")

        // A tick before the deadline (a timer that returned early) re-arms the same deadline.
        _ = replay("HP-X9 early tick", [
            line(r, .release(discard: false), released),
            line(r + 1_000, .tick, [.wake(atMs: r + 5_000)]),
            line(r + 1_200, .localFinal(text: local), [.wake(atMs: r + 3_200)]),
            timer(r + 3_200, [.cancelCloud(.tailTimeout), .emitFinal(text: local, source: .local)]),
        ])

        // A clock reading that goes back is taken as the previous one: no wake before the release.
        var backwards = Selector()
        let releaseActions = backwards.handle(.release(discard: false), nowMs: r)
        let backActions = backwards.handle(.localFinal(text: local), nowMs: r - 100)
        t.expect(
            releaseActions == released && backActions == [.wake(atMs: r + 2_000)]
                && backwards.counters.localFinalAtMs == r,
            "HP-X10 a clock going back is clamped: \(backActions)")

        // A cloud final while listening breaks the stream's contract: the cloud is out.
        _ = replay("HP-X11 cloud final while listening", [
            line(r - 100, .cloudFinal(text: cloud), [.cancelCloud(.failed)]),
            line(r, .release(discard: false), [.stopCapture, .finishLocal]),
            line(r + 500, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ])

        // The cloud's error vocabulary.
        typealias End = Selector.CloudEnd
        let mapping: [(String?, End)] = [
            ("ALI_FREE_QUOTA_EXHAUSTED", .providerPause), ("ALI_BALANCE_DUE", .providerPause),
            ("ALI_CLOUD_REVOKED", .revoked), ("ALI_RATE_LIMITED", .rateLimited),
            ("ALI_NETWORK_FAILED", .transient), ("ALI_TIMEOUT", .transient), ("ALI_SERVICE_UNAVAILABLE", .transient),
            ("ALI_AUTH_FAILED", .credential), ("CREDENTIAL_MISSING", .credential), ("CREDENTIAL_INVALID", .credential),
            ("ALI_ACCESS_DENIED", .accessDenied), ("ALI_MODEL_UNAVAILABLE", .accessDenied),
            ("ALI_STREAM_FAILED", .failed), ("ALI_CLEANUP", .failed), ("ALI_INVALID_REQUEST", .failed),
            ("SOMETHING_NEW", .failed), (nil, .failed),
        ]
        for (code, end) in mapping {
            t.expect(End.forCloudErrorCode(code) == end, "HP-X12 \(code ?? "nil") maps to \(end)")
        }

        // Budgets out of shape: localMs is bounded by totalMs; a zero total drops the cloud at the release and
        // leaves the decision to the local branch.
        var short = HybridBudget()
        short.totalMs = 4_000
        short.localMs = 6_000
        _ = replay("HP-X13 localMs beyond totalMs", [
            line(r, .release(discard: false), [.stopCapture, .finishLocal, .finishCloud, .wake(atMs: r + 4_000)]),
            line(r + 500, .cloudFinal(text: cloud)),
            timer(r + 4_000, [.cancelLocal(.budget), .emitFinal(text: cloud, source: .cloud)]),
        ], budget: short)
        var zero = HybridBudget()
        zero.totalMs = 0
        _ = replay("HP-X13 zero total", [
            line(r, .release(discard: false), [.stopCapture, .finishLocal, .finishCloud, .cancelCloud(.deadline)]),
            line(r + 400, .localFinal(text: local), [.emitFinal(text: local, source: .local)]),
        ], budget: zero)

        // After the decision even a cancel is only a drop; an empty local final is still the local result.
        let e14 = replay("HP-X14 cancel after the decision", [
            line(r, .release(discard: false), released),
            line(r + 600, .localFinal(text: ""), [.wake(atMs: r + 2_600)]),
            timer(r + 2_600, [.cancelCloud(.tailTimeout), .emitFinal(text: "", source: .local)]),
            line(r + 3_000, .cancel),
            line(r + 3_100, .tick),
        ])
        t.expect(
            e14.selector.phase == .decided(.local) && e14.selector.counters.lateDropped == 2,
            "HP-X14 the decision stands after a cancel")
        return t
    }

    // MARK: - HP-18: a thousand shuffled timelines

    struct SplitMix64 {
        private(set) var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }

        mutating func between(_ low: Int64, _ high: Int64) -> Int64 {
            low + Int64(next() % UInt64(high - low + 1))
        }

        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    }

    static func randomCase(_ rng: inout SplitMix64) -> (HybridBudget, [(Int64, Input)]) {
        var budget = HybridBudget()
        switch rng.below(10) {
        case 0:
            budget.totalMs = rng.between(0, 8_000)
            budget.localMs = rng.between(0, 9_000)
            budget.cloudTailMs = rng.between(0, 4_000)
            budget.backlogMs = rng.between(0, 3_000)
        case 1:
            budget.totalMs = .max
            budget.localMs = .max
            budget.cloudTailMs = .max
        case 2:
            budget.totalMs = -5
            budget.localMs = -1
            budget.cloudTailMs = -3
            budget.backlogMs = -1
        default:
            break
        }
        let base = rng.pick([Int64(0), 1_000_000, Int64.max - 40_000, -50_000])
        let texts = ["甲", "乙乙", "hello world", "3 个 not `x`", "云端", "本地", "", " \n"]
        let codes = ["LOCAL_WORKER_FAILED", "LOCAL_CAPTURE_FAILED", "LOCAL_START_FAILED"]
        let ends: [Selector.CloudEnd] = [
            .startFailed, .failed, .providerPause, .transient, .credential, .revoked, .consentWithdrawn, .cancelled,
        ]
        var script: [(Int64, Input)] = []
        for _ in 0..<rng.between(0, 16) {
            let at = base + rng.between(0, 9_000)
            let input: Input
            switch rng.below(100) {
            case 0..<6: input = .localReady
            case 6..<18: input = .localPartial(text: rng.pick(texts))
            case 18..<32: input = .localFinal(text: rng.pick(texts))
            case 32..<38: input = .localFailed(code: rng.pick(codes))
            case 38..<42: input = .cloudReady
            case 42..<50: input = .cloudPartial
            case 50..<66: input = .cloudFinal(text: rng.pick(texts))
            case 66..<74: input = .cloudEnded(rng.pick(ends))
            case 74..<88: input = .release(discard: rng.below(5) == 0)
            case 88..<94: input = .backlog(capturedMs: rng.between(0, 5_000), consumedMs: rng.between(0, 5_000))
            case 94..<97: input = .tick
            default: input = .cancel
            }
            script.append((at, input))
        }
        return (budget, script)
    }

    /// Within a batch: stopCapture, the finishes, the cancels, then a wake or an emit.
    static func rank(_ action: Action) -> Int {
        switch action {
        case .stopCapture: 0
        case .finishLocal, .finishCloud: 1
        case .cancelLocal, .cancelCloud: 2
        case .wake: 3
        case .emitReady, .emitPartial, .emitFinal, .emitFailure: 4
        }
    }

    static func kind(_ action: Action) -> String {
        switch action {
        case .emitReady: "emitReady"
        case .emitPartial: "emitPartial"
        case .emitFinal, .emitFailure: "terminal"
        case .stopCapture: "stopCapture"
        case .finishLocal: "finishLocal"
        case .finishCloud: "finishCloud"
        case .cancelLocal: "cancelLocal"
        case .cancelCloud: "cancelCloud"
        case .wake: "wake"
        }
    }

    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    /// Everything that must hold for any input sequence. `timerOnTime`: the driver's timer fired at its moment.
    static func violations(of run: Run, budget: HybridBudget, timerOnTime: Bool = true) -> [String] {
        var problems: [String] = []
        if run.overran { problems.append("the driver did not come to rest") }
        let c = run.selector.counters
        let total = max(budget.totalMs, 0)
        let localBudget = min(max(budget.localMs, 0), total)
        let tail = max(budget.cloudTailMs, 0)
        var deadlines: Set<Int64> = []
        if let t0 = c.releasedAtMs {
            let hard = saturating(t0, total)
            deadlines = [hard, saturating(t0, localBudget)]
            if let tl = c.localFinalAtMs { deadlines.insert(min(saturating(tl, tail), hard)) }
        }
        var totals: [String: Int] = [:]
        var terminalLine: Int?
        var localCancelled = false
        var cloudCancelled = false
        var firstLocalResult: Input?
        var cloudFinalsWhileFinishing: [String] = []
        for (index, line) in run.lines.enumerated() {
            let before: Selector.Phase = index == 0 ? .listening : run.phaseAfter[index - 1]
            let wasTerminal: Bool
            switch before {
            case .decided, .cancelled: wasTerminal = true
            case .listening, .finishing: wasTerminal = false
            }
            if wasTerminal {
                if !line.actions.isEmpty { problems.append("line \(index): actions after the end \(line.actions)") }
                if run.lateDroppedAfter[index] != run.lateDroppedAfter[index - 1] + 1 {
                    problems.append("line \(index): an input after the end was not counted")
                }
            } else {
                switch line.input {
                case .localFinal, .localFailed:
                    if firstLocalResult == nil { firstLocalResult = line.input }
                case .cloudFinal(let text):
                    if case .finishing = before { cloudFinalsWhileFinishing.append(text) }
                default:
                    break
                }
            }
            var lastRank = -1
            for (position, action) in line.actions.enumerated() {
                if rank(action) < lastRank { problems.append("line \(index): out of order \(line.actions)") }
                lastRank = rank(action)
                totals[kind(action), default: 0] += 1
                switch action {
                case .wake(let moment):
                    if moment <= line.atMs { problems.append("line \(index): wake \(moment) not after \(line.atMs)") }
                    if !deadlines.contains(moment) { problems.append("line \(index): wake \(moment) is no deadline") }
                    if line.actions.contains(where: isTerminal) { problems.append("line \(index): wake with a decision") }
                case .emitFinal, .emitFailure:
                    if position != line.actions.count - 1 { problems.append("line \(index): the decision is not last") }
                    terminalLine = index
                case .emitPartial:
                    if before != .listening { problems.append("line \(index): a draft after the release") }
                case .cancelLocal:
                    localCancelled = true
                case .cancelCloud:
                    cloudCancelled = true
                case .emitReady, .stopCapture, .finishLocal, .finishCloud:
                    break
                }
            }
            // No timer while finishing only once the cloud is out: then the local branch alone decides.
            if case .finishing = run.phaseAfter[index], run.armedAfter[index] == nil, !cloudCancelled {
                problems.append("line \(index): finishing with no timer armed")
            }
        }
        for kind in ["terminal", "stopCapture", "finishLocal", "finishCloud", "cancelLocal", "cancelCloud", "emitReady"] {
            if let count = totals[kind], count > 1 { problems.append("\(kind) \(count) times") }
        }
        if case .finishing = run.selector.phase,
           !cloudCancelled || c.localFinalAtMs != nil || c.localFailedAtMs != nil || localCancelled {
            problems.append("the run ended while finishing, not waiting for the local branch alone")
        }
        if let index = terminalLine, let action = run.lines[index].actions.last {
            let line = run.lines[index]
            if timerOnTime, case .tick = line.input, !deadlines.contains(line.atMs) {
                problems.append("decided by a tick at \(line.atMs), which is no deadline")
            }
            // After the hard deadline only a local result decides, and only once the cloud is out.
            if timerOnTime, let t0 = c.releasedAtMs, line.atMs > saturating(t0, total) {
                let localResult: Bool
                switch line.input {
                case .localFinal, .localFailed: localResult = true
                default: localResult = false
                }
                if !localResult || !cloudCancelled { problems.append("decided after the hard deadline") }
            }
            if c.decidedAtMs != line.atMs { problems.append("decidedAtMs differs from the deciding line") }
            switch action {
            case .emitFinal(let text, .local):
                if firstLocalResult != .localFinal(text: text) { problems.append("local final is not the first local result") }
                if c.cloudFinalAtMs != nil { problems.append("a usable cloud final lost to the local") }
                if c.cloudEnd == nil { problems.append("local chosen while the cloud was still in") }
            case .emitFinal(let text, .cloud):
                if isBlank(text) { problems.append("a blank cloud final was chosen") }
                if !cloudFinalsWhileFinishing.contains(text) { problems.append("cloud text never came while finishing") }
                if c.cloudFinalAtMs == nil { problems.append("cloud chosen without a cloud final on record") }
            case .emitFailure(let code):
                if code != Selector.incompleteCode && firstLocalResult != .localFailed(code: code) {
                    problems.append("failure code \(code) came from nowhere")
                }
                if c.cloudFinalAtMs != nil { problems.append("a usable cloud final was thrown away") }
                if code == Selector.incompleteCode && c.localFinalAtMs != nil { problems.append("incomplete with a local final") }
                if code == Selector.incompleteCode, c.releasedAtMs == nil || c.localFailedAtMs == nil {
                    problems.append("incomplete without a local failure after the release")
                }
                if code != Selector.incompleteCode, c.releasedAtMs != nil {
                    problems.append("the local code reported after the release")
                }
            default:
                problems.append("unexpected terminal \(action)")
            }
        }
        if localCancelled, !(run.selector.isTerminal && (c.reason == .localBudget || c.reason == nil)) {
            problems.append("the local branch was cancelled other than by the cloud's budget or a cancel")
        }
        if run.selector.isTerminal {
            let localClosed = c.localFinalAtMs != nil || c.localFailedAtMs != nil || localCancelled
            let cloudClosed = c.cloudFinalAtMs != nil || cloudCancelled
            if !localClosed || !cloudClosed {
                problems.append("a branch was left running at the end (local \(localClosed), cloud \(cloudClosed))")
            }
        }
        return problems
    }

    static func propertyChecks() -> Tally {
        var t = Tally()
        var rng = SplitMix64(seed: 0x7131_3000_5EED_0001)
        var outcomes: [String: Int] = [:]
        for index in 0..<1_000 {
            let (budget, script) = randomCase(&rng)
            let run = drive(script, budget: budget)
            let problems = violations(of: run, budget: budget)
            t.expect(problems.isEmpty, "HP-18 case \(index): \(problems.prefix(2)) in \(run.lines.map(describe))")
            let again = drive(script, budget: budget)
            t.expect(again.lines == run.lines, "HP-18 case \(index): the same script gave other actions")
            let hasCancel = script.contains { if case .cancel = $0.1 { true } else { false } }
            if !hasCancel {
                let late = drive(script, budget: budget, timerLateMs: rng.between(1, 900))
                let lateProblems = violations(of: late, budget: budget, timerOnTime: false)
                t.expect(lateProblems.isEmpty, "HP-18 case \(index) late timer: \(lateProblems.prefix(2))")
                t.expect(
                    terminal(of: late) == terminal(of: run) && late.selector.phase == run.selector.phase,
                    "HP-18 case \(index): a late timer changed the decision")
            }
            switch run.selector.phase {
            case .decided(.cloud?): outcomes["cloud", default: 0] += 1
            case .decided(.local?): outcomes["local", default: 0] += 1
            case .decided(nil): outcomes["failure", default: 0] += 1
            case .cancelled: outcomes["cancelled", default: 0] += 1
            case .listening, .finishing: outcomes["open", default: 0] += 1
            }
        }
        t.expect(
            outcomes["cloud", default: 0] >= 50 && outcomes["local", default: 0] >= 50
                && outcomes["failure", default: 0] >= 50 && outcomes["cancelled", default: 0] >= 20,
            "HP-18 the shuffled cases reach every outcome: \(outcomes)")
        return t
    }

    // MARK: - HP-19/20: budget, backlog, clock

    static func budgetAndBacklogChecks() -> Tally {
        var t = Tally()
        let budget = HybridBudget()
        t.expect(
            budget.totalMs == 5_000 && budget.localMs == 3_000 && budget.cloudTailMs == 2_000 && budget.backlogMs == 2_000,
            "HP-19 budget defaults 5000/3000/2000/2000")
        t.expect(!FanoutBacklogPolicy.isOverflowing(capturedMs: 2_000, consumedMs: 0, budget: budget), "HP-20 2000 behind is within")
        t.expect(FanoutBacklogPolicy.isOverflowing(capturedMs: 2_001, consumedMs: 0, budget: budget), "HP-20 2001 behind overflows")
        t.expect(!FanoutBacklogPolicy.isOverflowing(capturedMs: 12_000, consumedMs: 10_000, budget: budget), "HP-20 relative 2000")
        t.expect(FanoutBacklogPolicy.isOverflowing(capturedMs: 12_001, consumedMs: 10_000, budget: budget), "HP-20 relative 2001")
        t.expect(FanoutBacklogPolicy.backlogMs(capturedMs: 100, consumedMs: 300) == 0, "HP-20 an uplink ahead has no backlog")
        t.expect(
            FanoutBacklogPolicy.isOverflowing(capturedMs: .max, consumedMs: .min, budget: budget)
                && !FanoutBacklogPolicy.isOverflowing(capturedMs: .min, consumedMs: .max, budget: budget)
                && FanoutBacklogPolicy.backlogMs(capturedMs: .max, consumedMs: -1) == .max,
            "HP-20 extreme readings saturate instead of trapping")
        let first = HybridClock.live.nowMs()
        let second = HybridClock.live.nowMs()
        t.expect(first >= 0 && second >= first, "HP-19 the live clock does not go back")
        let scripted = HybridClock(nowMs: { 42 }, sleepUntilMs: { _ in })
        t.expect(scripted.nowMs() == 42, "HP-19 a scripted clock is what it says")
        return t
    }

    // MARK: - HP-21…25: the lexicon guard for cloud finals

    static func projectionGuardChecks() -> Tally {
        var t = Tally()
        func accepted(_ raw: String, _ projected: String) -> Bool {
            HybridProjectionGuard.check(raw: raw, projected: projected) == .accepted
        }
        func rejected(_ raw: String, _ projected: String, _ reason: HybridProjectionGuard.Reason) -> Bool {
            HybridProjectionGuard.check(raw: raw, projected: projected) == .rejected(reason)
        }
        // Numbers.
        t.expect(rejected("我有3个苹果", "我有4个苹果", .digits), "HP-21 an ASCII digit changed")
        t.expect(rejected("第１版", "第2版", .digits), "HP-21 a full-width digit changed")
        t.expect(rejected("第１版", "第1版", .digits), "HP-21 a full-width digit turned ASCII")
        t.expect(rejected("第１版", "第２版", .digits), "HP-21 a full-width digit changed to another full-width digit")
        t.expect(rejected("共３个", "共个", .digits), "HP-21 a full-width digit dropped")
        t.expect(rejected("三个人", "四个人", .digits), "HP-21 a Chinese numeral changed")
        t.expect(rejected("两千块", "两块", .digits), "HP-21 a Chinese numeral dropped")
        t.expect(rejected("约会", "约5会", .digits), "HP-21 a digit added")
        t.expect(rejected("版本 12", "版本 1 2", .digits), "HP-21 a number split")
        t.expect(accepted("用 cloud code 跑 3 次", "用 Claude Code 跑 3 次"), "HP-21 numbers kept, spelling fixed")
        // Negation.
        t.expect(rejected("我不想去", "我想去", .negation), "HP-22 不 dropped")
        t.expect(rejected("没问题", "有问题", .negation), "HP-22 没 replaced")
        t.expect(rejected("还未完成", "还已完成", .negation), "HP-22 未 replaced")
        t.expect(rejected("别走", "走", .negation), "HP-22 别 dropped")
        t.expect(rejected("我去", "我不去", .negation), "HP-22 a negation added")
        t.expect(rejected("I don't know", "I do know", .negation), "HP-22 n't dropped")
        t.expect(rejected("I don\u{2019}t know", "I do know", .negation), "HP-22 n't with a curly apostrophe")
        t.expect(rejected("this is not ok", "this is ok", .negation), "HP-22 not dropped")
        t.expect(rejected("never mind", "ever mind", .negation), "HP-22 never dropped")
        t.expect(rejected("I cannot go", "I can go", .negation), "HP-22 cannot dropped")
        t.expect(accepted("I can't use cloud code", "I can't use Claude Code"), "HP-22 negation kept, spelling fixed")
        t.expect(accepted("NOT a notebook", "not a notebook"), "HP-22 case is ignored and notebook is no negation")
        t.expect(rejected("未来科技", "蔚来科技", .negation), "HP-22 known cost: a fix that removes 未 is refused")
        // Code.
        t.expect(rejected("run `git push` now", "run `git pull` now", .code), "HP-23 backtick span changed")
        t.expect(rejected("`unclosed code", "`unclosed Code", .code), "HP-23 an unclosed backtick runs to the end")
        t.expect(rejected("打开 ~/Downloads/a.txt", "打开 ~/Download/a.txt", .code), "HP-23 path changed")
        t.expect(rejected("改 config.json 文件", "改 config.yaml 文件", .code), "HP-23 dotted file name changed")
        t.expect(rejected("see https://example.com/a", "see https://example.org/a", .code), "HP-23 URL changed")
        t.expect(rejected("mail a@b.cn", "mail a@b.com", .code), "HP-23 e-mail changed")
        t.expect(rejected("call foo_bar", "call fooBar", .code), "HP-23 identifier with an underscore changed")
        t.expect(rejected("use std::vector", "use std::Vector", .code), "HP-23 :: changed")
        t.expect(rejected("a->b", "a->c", .code), "HP-23 -> changed")
        t.expect(accepted("open github", "open GitHub"), "HP-23 CamelCase GitHub is no code")
        t.expect(accepted("open ai 的模型", "OpenAI 的模型"), "HP-23 CamelCase OpenAI is no code")
        t.expect(accepted("看 config.json 里的 cloud code", "看 config.json 里的 Claude Code"), "HP-23 code kept, spelling fixed")
        // The ordinary rule, and nothing changed.
        t.expect(accepted("cloud code", "Claude Code"), "HP-24 cloud code → Claude Code passes")
        t.expect(accepted("用 cloud code 写代码", "用 Claude Code 写代码"), "HP-24 inside Chinese")
        t.expect(accepted("", ""), "HP-25 empty and unchanged")
        t.expect(accepted("我不想改 3 个 `a.b` 文件", "我不想改 3 个 `a.b` 文件"), "HP-25 unchanged with protected tokens")
        t.expect(
            HybridProjectionGuard.check(raw: "不 3", projected: "4") == .rejected(.digits),
            "HP-25 digits are checked first")
        return t
    }

    // MARK: - HP-26: which routes can be enhanced

    static func routeChecks() -> Tally {
        var t = Tally()
        let locals = ["qwen17-rolling", "qwen06-rolling", "qwen06-incremental"]
        let languages = ["zh", "en", "auto"]
        for id in locals {
            for language in languages {
                let route = HybridSpeechRoute.resolve(isVoiceNative: true, localRouteID: id, language: language)
                t.expect(route?.localRouteID == id && route?.language == language, "HP-26 \(id) \(language) can be enhanced")
                t.expect(
                    HybridSpeechRoute.resolve(isVoiceNative: false, localRouteID: id, language: language) == nil,
                    "HP-26 \(id) \(language) outside voiceNative cannot")
            }
            for language in ["yue", "ja", "", "ZH", " zh"] {
                t.expect(
                    HybridSpeechRoute.resolve(isVoiceNative: true, localRouteID: id, language: language) == nil,
                    "HP-26 \(id) language '\(language)' cannot")
            }
        }
        for id in ["apple-speech", "doubao", "aliyun", "groq-v3", "sensevoice", "", "QWEN17-ROLLING", "qwen17-rolling "] {
            for language in languages {
                t.expect(
                    HybridSpeechRoute.resolve(isVoiceNative: true, localRouteID: id, language: language) == nil,
                    "HP-26 route '\(id)' \(language) cannot")
            }
        }
        t.expect(HybridSpeechRoute.cloudRouteID == "aliyun", "HP-26 the cloud branch runs as aliyun")
        return t
    }

    // MARK: - HP-30: how far the two finals were apart (the decision line's diffBucket)

    static func diffBucketChecks() -> Tally {
        var t = Tally()
        typealias Diff = HybridTextDifference
        // Only punctuation, spacing, symbols or case apart: the same words.
        t.expect(Diff.bucket("你好世界", "你好，世界。") == .same, "HP-30 punctuation only is 0")
        t.expect(Diff.bucket("Claude Code", "claude  code.") == .same, "HP-30 case and spacing only is 0")
        t.expect(Diff.bucket("a+b=c", "abc") == .same, "HP-30 symbols are not words")
        t.expect(Diff.bucket("", "") == .same && Diff.bucket("，。", " ") == .same, "HP-30 nothing left on both sides is 0")
        // Real differences.
        t.expect(Diff.bucket("本地终稿", "云端终稿") == .oneOrTwo, "HP-30 two replaced characters is 1-2")
        t.expect(Diff.bucket("你好世界", "你好世") == .oneOrTwo, "HP-30 one missing character is 1-2")
        t.expect(Diff.bucket("kitten", "sitting") == .threeToFive, "HP-30 kitten/sitting is 3")
        t.expect(Diff.bucket("ab", "ba") == .oneOrTwo, "HP-30 a swap costs two")
        // The edges of every bucket: k characters against nothing.
        let bars: [(Int, Diff.Bucket)] = [
            (0, .same), (1, .oneOrTwo), (2, .oneOrTwo), (3, .threeToFive), (5, .threeToFive), (6, .sixToTen),
            (10, .sixToTen), (11, .elevenOrMore), (600, .elevenOrMore),
        ]
        for (count, expected) in bars {
            let got = Diff.bucket(String(repeating: "甲", count: count), "")
            t.expect(got == expected, "HP-30 \(count) characters against none is \(expected.rawValue), got \(got.rawValue)")
            t.expect(Diff.bucket(forDistance: count) == expected, "HP-30 distance \(count) is \(expected.rawValue)")
        }
        t.expect(Diff.bucket(forDistance: -4) == .same && Diff.bucket(forDistance: .max) == .elevenOrMore,
                 "HP-30 out-of-range distances stay in a bucket")
        // Too long to measure: not measured, and the same either way round.
        let long = String(repeating: "乙", count: 601)
        t.expect(Diff.bucket(long, "") == .unavailable && Diff.bucket("", long) == .unavailable
                    && Diff.bucket(long, long) == .unavailable, "HP-30 601 characters are not measured")
        t.expect(Diff.bucket(String(repeating: "乙", count: 600), String(repeating: "乙", count: 600)) == .same,
                 "HP-30 600 characters are measured")
        t.expect(Diff.bucket(String(repeating: "，", count: 5_000) + "你好", "你好") == .same,
                 "HP-30 the length limit counts what is left after the clean-up")
        t.expect(Diff.Bucket.unavailable.rawValue == "na" && Diff.Bucket.elevenOrMore.rawValue == "11+"
                    && Diff.Bucket.oneOrTwo.rawValue == "1-2" && Diff.Bucket.threeToFive.rawValue == "3-5"
                    && Diff.Bucket.sixToTen.rawValue == "6-10" && Diff.Bucket.same.rawValue == "0",
                 "HP-30 the labels are the finite ones of the diagnostics line")

        // A separately written reference (the full matrix, on the cleaned text) agrees on random pairs, and the
        // distance does not depend on which text comes first.
        func cleaned(_ text: String) -> [Character] {
            var out: [Character] = []
            for ch in text.lowercased() where !(ch.isWhitespace || ch.isPunctuation || ch.isSymbol) { out.append(ch) }
            return out
        }
        func reference(_ a: [Character], _ b: [Character]) -> Int {
            var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in 0...a.count { d[i][0] = i }
            for j in 0...b.count { d[0][j] = j }
            if a.isEmpty || b.isEmpty { return d[a.count][b.count] }
            for i in 1...a.count {
                for j in 1...b.count {
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
            return d[a.count][b.count]
        }
        let alphabet: [String] = ["你", "好", "世", "界", "A", "b", "C", "1", "2", "，", "。", " ", "-", "é", "e"]
        var rng = SplitMix64(seed: 0x00D1_FFB0_C4E7)
        var agreed = 0
        for _ in 0..<600 {
            let a = (0..<rng.below(14)).map { _ in rng.pick(alphabet) }.joined()
            let b = (0..<rng.below(14)).map { _ in rng.pick(alphabet) }.joined()
            let expected = Diff.bucket(forDistance: reference(cleaned(a), cleaned(b)))
            if Diff.bucket(a, b) == expected, Diff.bucket(b, a) == expected { agreed += 1 }
        }
        t.expect(agreed == 600, "HP-30 600 random pairs agree with the reference in both orders (\(agreed))")

        // In the decision: the bucket is set only when both finals exist, and only words-free data is kept.
        let r: Int64 = 10_000
        let marker = "独特标记甲乙丙"
        func bucket(_ script: [(Int64, Input)]) -> (Diff.Bucket, HybridCounters) {
            let run = drive(script)
            return (run.selector.counters.diffBucket, run.selector.counters)
        }
        let release: (Int64, Input) = (r, .release(discard: false))
        let both = bucket([release, (r + 600, .localFinal(text: "你好世界")), (r + 1_400, .cloudFinal(text: "你好，世界。"))])
        t.expect(both.0 == .same, "HP-30 both finals in the tail: the bucket is set (\(both.0.rawValue))")
        let cloudFirst = bucket([release, (r + 500, .cloudFinal(text: "云端终稿")), (r + 1_200, .localFinal(text: "本地终稿"))])
        t.expect(cloudFirst.0 == .oneOrTwo, "HP-30 cloud first, local inside its time: the bucket is set (\(cloudFirst.0.rawValue))")
        let stuck = bucket([release, (r + 500, .cloudFinal(text: "云端终稿"))])
        t.expect(stuck.0 == .unavailable, "HP-30 the local branch cancelled at its budget: na")
        let tail = bucket([release, (r + 600, .localFinal(text: "本地终稿"))])
        t.expect(tail.0 == .unavailable, "HP-30 no cloud final (the tail ran out): na")
        let localFailed = bucket([release, (r + 400, .localFailed(code: "LOCAL_INFERENCE_FAILED")), (r + 900, .cloudFinal(text: "云端终稿"))])
        t.expect(localFailed.0 == .unavailable, "HP-30 the local branch failed and the cloud answered: na")
        let early = bucket([(r - 500, .localPartial(text: "你"))])
        t.expect(early.0 == .unavailable, "HP-30 before a decision: na")
        let withMarker = bucket([release, (r + 600, .localFinal(text: marker + "甲")), (r + 900, .cloudFinal(text: marker + "乙"))])
        t.expect(withMarker.0 == .oneOrTwo, "HP-30 texts with a marker: the bucket is set")
        t.expect(!String(describing: withMarker.1).contains(marker) && !String(reflecting: withMarker.1).contains("独特"),
                 "HP-30 the counters keep no words")
        return t
    }

    // MARK: - HP-27: a final of another length replaces only this dictation's span

    static func inlineDraftChecks() -> Tally {
        var t = Tally()
        struct Field {
            var document: String
            var selection: NSRange
        }
        /// The editor applies a plan as asked; the splice is computed here from the range, not taken from the plan.
        func write(
            _ text: String, sequence: UInt64, draft: inout InlineDraftTransaction, field: inout Field, label: String
        ) -> InlineDraftTransaction.Decision {
            let decision = draft.prepare(
                text: text, sequence: sequence, currentDocument: field.document, currentSelection: field.selection)
            guard case .replace(let plan) = decision else { return decision }
            var units = Array(field.document.utf16)
            let range = plan.replaceRange
            units.replaceSubrange(range.location..<(range.location + range.length), with: Array(text.utf16))
            field.document = String(decoding: units, as: UTF16.self)
            field.selection = NSRange(location: range.location + text.utf16.count, length: 0)
            t.expect(
                draft.confirm(planID: plan.id, observedDocument: field.document, observedSelection: field.selection),
                "\(label): the editor's result confirms the plan")
            return decision
        }
        let contexts: [(name: String, document: String, selection: NSRange)] = [
            ("empty field", "", NSRange(location: 0, length: 0)),
            ("selection mid-text", "前文👍🏽ABC后文", NSRange(location: "前文👍🏽".utf16.count, length: 3)),
            ("end of text", "已有正文。", NSRange(location: "已有正文。".utf16.count, length: 0)),
        ]
        let lastLocalDraft = "本地草稿caf\u{E9}"
        let finals: [(name: String, text: String)] = [
            ("longer", "本地草稿被云端修订成更长的一句话。"),
            ("shorter", "短"),
            ("emoji", "好的👍🏽👨‍👩‍👧"),
            ("combining marks, canonically equal to the draft", "本地草稿cafe\u{301}"),
            ("line feed", "第一行\n第二行"),
        ]
        for context in contexts {
            let units = Array(context.document.utf16)
            let head = Array(units[..<context.selection.location])
            let tail = Array(units[(context.selection.location + context.selection.length)...])
            for final in finals {
                let label = "HP-27 \(context.name), \(final.name)"
                guard var draft = InlineDraftTransaction(originalText: context.document, selection: context.selection) else {
                    t.expect(false, "\(label): no transaction")
                    continue
                }
                var field = Field(document: context.document, selection: context.selection)
                _ = write("本地", sequence: 1, draft: &draft, field: &field, label: label)
                _ = write(lastLocalDraft, sequence: 2, draft: &draft, field: &field, label: label)
                let decision = write(final.text, sequence: UInt64.max, draft: &draft, field: &field, label: label)
                guard case .replace = decision else {
                    t.expect(false, "\(label): the final was not written (\(decision))")
                    continue
                }
                let now = Array(field.document.utf16)
                let finalUnits = Array(final.text.utf16)
                t.expect(
                    now.count == head.count + finalUnits.count + tail.count
                        && Array(now.prefix(head.count)) == head && Array(now.suffix(tail.count)) == tail,
                    "\(label): the text around this dictation is unchanged")
                t.expect(
                    Array(now[head.count..<(head.count + finalUnits.count)]) == finalUnits,
                    "\(label): the dictation's span holds the final, code unit for code unit")
                let caret = NSRange(location: head.count + finalUnits.count, length: 0)
                t.expect(
                    field.selection == caret && draft.expectedSelection == caret && field.selection.length == 0,
                    "\(label): the caret is at the end of the final with nothing selected")
                t.expect(
                    draft.writtenRange == NSRange(location: head.count, length: finalUnits.count),
                    "\(label): the dictation owns exactly the final")
                t.expect(
                    draft.prepare(
                        text: "本地草稿", sequence: 3, currentDocument: field.document, currentSelection: field.selection
                    ) == .stale,
                    "\(label): a later local draft cannot come back over the final")
            }
            // The same code units as the last draft: nothing to write, the caret stays at the end.
            if var draft = InlineDraftTransaction(originalText: context.document, selection: context.selection) {
                var field = Field(document: context.document, selection: context.selection)
                _ = write(lastLocalDraft, sequence: 1, draft: &draft, field: &field, label: "HP-27 \(context.name) same")
                let before = field
                let decision = write(lastLocalDraft, sequence: UInt64.max, draft: &draft, field: &field, label: "same")
                t.expect(
                    decision == .unchanged && field.document.utf16.elementsEqual(before.document.utf16)
                        && field.selection == before.selection,
                    "HP-27 \(context.name): a final equal to the draft changes nothing")
            }
            // CR is refused by the transaction: a CRLF final abandons the round and leaves the local draft in place.
            // The hybrid backend must turn CRLF / CR into LF before it feeds the cloud final.
            if var draft = InlineDraftTransaction(originalText: context.document, selection: context.selection) {
                var field = Field(document: context.document, selection: context.selection)
                _ = write(lastLocalDraft, sequence: 1, draft: &draft, field: &field, label: "HP-27 \(context.name) CRLF")
                let before = field
                let decision = write("第一行\r\n第二行", sequence: UInt64.max, draft: &draft, field: &field, label: "CRLF")
                t.expect(
                    decision == .abandoned && draft.isAbandoned
                        && field.document.utf16.elementsEqual(before.document.utf16)
                        && draft.lastDraft.utf16.elementsEqual(lastLocalDraft.utf16),
                    "HP-27 \(context.name): a CRLF final is refused and the local draft stays (\(decision))")
            }
        }
        return t
    }
}
