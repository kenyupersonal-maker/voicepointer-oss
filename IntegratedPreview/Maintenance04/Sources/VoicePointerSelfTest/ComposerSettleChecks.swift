import Foundation
@_spi(Testing) import VoicePointerCore

/// Pure settle-policy checks; no AX, keyboard, permissions, or UI involved.
public enum ComposerSettleChecks {
    public static func run() -> [String] {
        var failures: [String] = []
        var nilThenText = ComposerSettlePolicy(minimumMilliseconds: 1_000)
        for sample in 0..<nilThenText.maximumSamples {
            let value = sample < 19 ? nil : "稳定文本"
            if nilThenText.observe(sample: sample, value: value) && sample < 25 {
                failures.append("nil AX value settled too early")
            }
        }

        var changing = ComposerSettlePolicy(minimumMilliseconds: 0)
        let observations: [String?] = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let settled = observations.enumerated().compactMap { sample, value in
            changing.observe(sample: sample, value: value) ? sample : nil
        }
        if !settled.isEmpty { failures.append("continuous value changes settled") }

        var delayedAfterGap = ComposerSettlePolicy(minimumMilliseconds: 0)
        let gapObservations: [String?] = ["a", "a", "a", "a", nil, "b", "b", "b", "b", "b", "b", "b"]
        let gapSettled = gapObservations.enumerated().compactMap { sample, value in
            delayedAfterGap.observe(sample: sample, value: value) ? sample : nil
        }
        if gapSettled != [11] { failures.append("mid-stream nil did not reset settle window") }

        var unreadable = ComposerSettlePolicy(minimumMilliseconds: 0)
        let unreadableResults = (0..<unreadable.maximumSamples).map {
            unreadable.observe(sample: $0, value: nil)
        }
        if unreadableResults.contains(true) { failures.append("nil AX value was accepted as settled") }
        print("COMPOSER_SETTLE_BASELINE assertions=4 failures=\(failures.count) ax=0")
        return failures + runTiming() + runSupplemental()
    }

    /// C-M2: injected monotonic time and fixture text only, no AX or sleeps.
    public static func runTiming() -> [String] {
        var failures: [String] = []
        var history = ComposerExtraQuietHistory()
        let eligible = ComposerExtraQuietHistory.RecordingEligibility(
            sessionIsCurrent: true, tokenIsCurrent: true, isCancelled: false,
            targetIsValid: true, observedNonemptySend: true)
        history.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
        history.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)

        let now = TestClock()
        let release = ComposerReleaseTiming(now: { now.read() })
        release.noteRelease()
        var timing = ComposerSettleTiming(clock: release)
        now.advance(milliseconds: 600)
        release.noteRelease() // Repeated callers must keep the first release origin.
        let initialChanged = timing.observe(value: "fixture-A")
        now.advance(milliseconds: 450)
        let unchangedChanged = timing.observe(value: "fixture-A")
        if initialChanged || unchangedChanged || timing.lastChangeMilliseconds != 0
            || timing.late != 0 || !timing.changesMilliseconds.isEmpty
            || timing.settledMilliseconds != 1_050
            || history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: timing.lastChangeMilliseconds) {
            failures.append("C-M2 delayed unchanged baseline invented a late change or used nominal settle time")
        }

        now.advance(milliseconds: 70)
        let laterChanged = timing.observe(value: "fixture-B")
        now.advance(milliseconds: 355)
        if !laterChanged || timing.lastChangeMilliseconds != 1_120
            || timing.changesMilliseconds != [1_120] || timing.late != 1
            || timing.settledMilliseconds != 1_475
            || !history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: timing.lastChangeMilliseconds) {
            failures.append("C-M2 true later change and settled time must share the injected release clock")
        }

        let missingRelease = ComposerReleaseTiming(now: { now.read() })
        var missing = ComposerSettleTiming(clock: missingRelease)
        let missingChanged = missing.observe(value: "fixture-A")
        var native = ComposerSettleTiming(clock: release) // No observer on native delivery.
        if missingChanged || missing.settledMilliseconds != -1 || missing.lastChangeMilliseconds != -1
            || native.lastChangeMilliseconds != -1 || native.late != -1
            || !native.changesMilliseconds.isEmpty
            || history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: native.lastChangeMilliseconds) {
            failures.append("C-M2 missing release or native observation must stay unknown without C4")
        }

        let nilChanged = native.observe(value: nil)
        let blankChanged = native.observe(value: " \n")
        let firstAfterGapChanged = native.observe(value: "fixture-A")
        let unchangedAfterGapChanged = native.observe(value: "fixture-A")
        if nilChanged || blankChanged || firstAfterGapChanged || unchangedAfterGapChanged
            || native.lastChangeMilliseconds != -1 || native.late != -1
            || !native.changesMilliseconds.isEmpty
            || history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: native.lastChangeMilliseconds) {
            failures.append("C-M2 initial unreadable/blank gap must not invent a timed commit or C4")
        }

        // A gap after real changes invalidates the latest-change classification.
        let gapChanged = timing.observe(value: nil)
        let recoveredChanged = timing.observe(value: "fixture-C")
        if gapChanged || recoveredChanged || timing.lastChangeMilliseconds != -1 || timing.late != -1
            || timing.changesMilliseconds != [1_120]
            || history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: timing.lastChangeMilliseconds) {
            failures.append("C-M2 missing observation must reset late evidence, retaining only proven changes")
        }

        // Retain the existing numeric eight-entry cap while keeping the real last change.
        for index in 0..<9 {
            now.advance(milliseconds: 50)
            timing.observe(value: "fixture-\(index)")
        }
        if timing.changesMilliseconds.count != 8 || timing.lastChangeMilliseconds != 1_925
            || timing.changesMilliseconds.last != 1_825 {
            failures.append("C-M2 changesMs cap must not truncate lastChangeMs")
        }
        print("C_M2_TIMING assertions=6 failures=\(failures.count) injected_clock=1 ax=0 sleep=0")
        return failures + runTimeoutTiming()
    }

    /// S3: synthetic samples and a numeric logger; never reads a real target or log.
    public static func runTimeoutTiming(logURL: URL? = nil) -> [String] {
        var failures: [String] = []
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() { failures.append("S3 timing: " + message) }
        }
        let now = TestClock()
        let release = ComposerReleaseTiming(now: { now.read() })
        release.noteRelease()
        var changing = ComposerSettleTiming(clock: release)
        changing.observe(value: "synthetic-baseline")
        for index in 1...80 {
            now.advance(milliseconds: 50)
            changing.observe(value: "synthetic-change-\(index)")
        }
        let timeoutLine = changing.traceMessage
        expect(timeoutLine == "composer settle timing lastChangeMs=4000 settledMs=4000 changesMs=[50,100,150,200,250,300,350,400]",
               "exhausted changing observations retain elapsed deadline and eight proven changes")
        expect(changing.lastChangeMilliseconds == 4_000 && changing.changesMilliseconds.count == 8,
               "eight-entry log cap does not truncate the latest change")
        expect(!timeoutLine.contains("synthetic") && !timeoutLine.contains("target") && !timeoutLine.contains("text="),
               "timing payload excludes fixture text and target identity")

        var unreadable = ComposerSettleTiming(clock: release)
        unreadable.observe(value: nil)
        expect(unreadable.traceMessage == "composer settle timing lastChangeMs=-1 settledMs=4000 changesMs=[]",
               "unreadable timeout stays unknown instead of reporting no changes")
        var noRelease = ComposerSettleTiming(clock: ComposerReleaseTiming(now: { now.read() }))
        noRelease.observe(value: "synthetic-no-release")
        expect(noRelease.traceMessage == "composer settle timing lastChangeMs=-1 settledMs=-1 changesMs=[]",
               "missing release time remains -1")
        changing.observe(value: nil)
        expect(changing.traceMessage == "composer settle timing lastChangeMs=-1 settledMs=4000 changesMs=[50,100,150,200,250,300,350,400]",
               "a final observation gap invalidates latest-change evidence but retains proven samples")

        if let logURL {
            RuntimeTrace.configureForTesting(fileURL: logURL)
            defer { RuntimeTrace.resetTestingConfiguration() }
            RuntimeTrace.record(timeoutLine)
            RuntimeTrace.record(unreadable.traceMessage)
            RuntimeTrace.record(noRelease.traceMessage)
            RuntimeTrace.flush()
            do {
                let log = try String(contentsOf: logURL, encoding: .utf8)
                let timingLines = log.split(separator: "\n").compactMap { line -> String? in
                    guard let range = line.range(of: "composer settle timing ") else { return nil }
                    return String(line[range.lowerBound...])
                }
                expect(timingLines == [timeoutLine, unreadable.traceMessage, noRelease.traceMessage],
                       "fake logger writes all three timing payloads unchanged and in order")
                expect(!log.contains("synthetic"), "fake logger contains no sampled text")
            } catch {
                expect(false, "fake logger could not read its explicit test file")
            }
        }
        print("S3_TIMEOUT_TIMING assertions=\(assertions) failures=\(failures.count) samples=81 changes_cap=8 fake_logger=\(logURL == nil ? 0 : 1) ax=0 sleep=0")
        return failures
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64 = 10_000_000_000
        func read() -> UInt64 { lock.withLock { nanoseconds } }
        func advance(milliseconds: UInt64) {
            lock.withLock { nanoseconds += milliseconds * 1_000_000 }
        }
    }

    /// S1/S2/S4: real pure policy, synthetic values/time and an in-memory send
    /// counter. Target validity and cancellation are injected, never AX calls.
    public static func runSupplemental() -> [String] {
        var failures: [String] = []
        var assertions = 0
        func expect(_ condition: Bool, _ message: String) {
            assertions += 1
            if !condition { failures.append(message) }
        }
        let late = sequence { $0 < 2_000 ? "fixture-\($0)" : "fixture-final" }
        expect(late.sentAt == 2_300 && late.sends == 1 && !late.fallback,
               "S4 late final commit must send once after 300ms quiet at 2300ms")
        let changing = sequence { "fixture-\($0)" }
        expect(changing.sends == 0 && changing.observedAt == 4_000,
               "S4 changing through the absolute 4000ms ceiling must not send")
        let extra = sequence(extraQuiet: true) { $0 < 1_900 ? "fixture-\($0)" : "fixture-final" }
        expect(extra.sentAt == 2_200 && extra.sends == 1 && extra.fallback,
               "S4 extra quiet must fall back at 2200ms when only 300ms quiet is available")
        let ordinary = sequence { _ in "fixture-steady" }
        expect(ordinary.sentAt == 1_000 && ordinary.sends == 1,
               "S1 ordinary initial settle must retain the 1000ms floor")
        let ordinaryExtra = sequence(extraQuiet: true) { $0 < 800 ? "fixture-\($0)" : "fixture-final" }
        expect(ordinaryExtra.sentAt == 1_550 && !ordinaryExtra.fallback,
               "S2 ordinary 750ms extra quiet must remain eligible before its deadline")
        let lastInstant = sequence { $0 < 3_700 ? "fixture-\($0)" : "fixture-final" }
        expect(lastInstant.sentAt == 4_000 && lastInstant.sends == 1,
               "S1 exactly 300ms quiet at 4000ms may send once")
        let shortQuiet = sequence { $0 < 3_750 ? "fixture-\($0)" : "fixture-final" }
        expect(shortQuiet.sends == 0, "S1 250ms quiet at 4000ms must not send a partial sentence")
        let noRead = sequence { _ in nil }
        expect(noRead.sends == 0 && noRead.observedAt == 1_600,
               "S1 unreadable idle observations must not extend or send")
        let failedRead = sequence { $0 < 2_000 ? "fixture-\($0)" : nil }
        expect(failedRead.sends == 0 && failedRead.observedAt == 2_000,
               "S1 extended read failure must end without sending")
        let blank = sequence { $0 < 2_000 ? "fixture-\($0)" : " \n" }
        expect(blank.sends == 0, "S1 extended blank observations must not send")
        let cancelled = sequence(mayContinue: { $0 < 2_200 }) {
            $0 < 2_000 ? "fixture-\($0)" : "fixture-final"
        }
        expect(cancelled.sends == 0, "S4 cancellation during extended quiet must not send")
        let invalid = sequence(mayContinue: { $0 < 2_300 }) {
            $0 < 2_000 ? "fixture-\($0)" : "fixture-final"
        }
        expect(invalid.sends == 0, "S4 invalid target at the ready observation must not send")
        let jitter = sequence(timestamps: Array(stride(from: 100, through: 4_100, by: 100))) {
            $0 < 2_000 ? "fixture-\($0)" : "fixture-final"
        }
        expect(jitter.sentAt == 2_300, "S1 extended quiet must use real injected elapsed time, not six nominal samples")
        let overshoot = sequence(timestamps: Array(stride(from: 50, through: 3_950, by: 50)) + [4_001]) {
            $0 < 3_750 ? "fixture-\($0)" : "fixture-final"
        }
        expect(overshoot.sends == 0, "S1 late reads after 4000ms cannot authorize Return")
        var cancellationPolicy = ComposerSettlePolicy(minimumMilliseconds: 800)
        let cancellationSamples = cancellationPolicy.maximumSamples
        let cancellationResults = (0..<cancellationSamples).map {
            cancellationPolicy.observe(sample: $0, value: "fixture-\($0)")
        }
        expect(cancellationSamples == 28 && !cancellationResults.contains(true),
               "S1 non-send settle ceiling and changing-text refusal must remain unchanged")
        let now = TestClock()
        let release = ComposerReleaseTiming(now: { now.read() })
        release.noteRelease()
        var timing = ComposerSettleTiming(clock: release)
        timing.observe(value: "fixture-steady")
        now.advance(milliseconds: 1_000)
        timing.observe(value: "fixture-steady")
        var history = ComposerExtraQuietHistory()
        let eligible = ComposerExtraQuietHistory.RecordingEligibility(
            sessionIsCurrent: true, tokenIsCurrent: true, isCancelled: false,
            targetIsValid: true, observedNonemptySend: true)
        for _ in 0..<2 {
            history.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false,
                           lastChangeMilliseconds: timing.lastChangeMilliseconds, eligibility: eligible)
        }
        expect(timing.lastChangeMilliseconds == 0 && timing.changesMilliseconds.isEmpty
               && !history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 500),
               "S4 genuine steady swallowed observations must not seed C4")
        print("S1_S2_S4_SEQUENCES assertions=\(assertions) failures=\(failures.count) lateSendMs=\(late.sentAt ?? -1) fallbackSendMs=\(extra.sentAt ?? -1) changingStopMs=\(changing.observedAt) ax=0 keys=0 sleep=0")
        return failures
    }

    private static func sequence(
        extraQuiet: Bool = false,
        timestamps: [Int] = (1...80).map { $0 * 50 },
        mayContinue: (Int) -> Bool = { _ in true },
        value: (Int) -> String?
    ) -> (sentAt: Int?, sends: Int, fallback: Bool, observedAt: Int) {
        var policy = ComposerSettlePolicy(minimumMilliseconds: 1_000, extendChangingSend: true)
        if extraQuiet { policy.extendQuietWindow() }
        let token = OperationCancellationToken()
        var observedAt = 0
        for (sample, elapsed) in timestamps.enumerated() {
            if !mayContinue(elapsed) { token.cancel() }
            guard !token.isCancelled else { break }
            observedAt = elapsed
            if policy.observe(sample: sample, value: value(elapsed), elapsedMilliseconds: elapsed) {
                let sends = token.commitIfValid { 1 } ?? 0
                return (elapsed, sends, policy.usedExtraQuietFallback, observedAt)
            }
            if policy.isFinished { break }
        }
        return (nil, 0, false, observedAt)
    }
}
