import Foundation
@_spi(Testing) import VoicePointerCore

public enum ComposerExtraQuietChecks {
    public static func run() -> [String] {
        var failures: [String] = []
        let eligible = ComposerExtraQuietHistory.RecordingEligibility(
            sessionIsCurrent: true, tokenIsCurrent: true, isCancelled: false,
            targetIsValid: true, observedNonemptySend: true)
        var trigger = ComposerExtraQuietHistory()
        trigger.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
        trigger.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
        if !trigger.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 101) {
            failures.append("extra quiet two swallowed plus late should trigger")
        }
        var noTrigger = ComposerExtraQuietHistory()
        noTrigger.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
        if noTrigger.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 101)
            || trigger.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 100)
            || trigger.shouldExtend(processIdentifier: 8, lastChangeMilliseconds: 500) {
            failures.append("extra quiet must require both run-local target history and late change")
        }
        trigger.record(processIdentifier: 7, swallowed: false, usedExtraQuiet: true, eligibility: eligible)
        for swallowed in [true, false, true, false] {
            trigger.record(processIdentifier: 7, swallowed: swallowed, usedExtraQuiet: true, lastChangeMilliseconds: 250, eligibility: eligible)
        }
        if trigger.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 500) {
            failures.append("extra quiet still swallowed twice in following four should disable")
        }
        var agedRetries = ComposerExtraQuietHistory()
        for pid in [pid_t(7), pid_t(8)] {
            agedRetries.record(processIdentifier: pid, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
            agedRetries.record(processIdentifier: pid, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
        }
        for _ in 0..<6 {
            // Confirmed native sends have no legacy settle observation or retry permission.
            agedRetries.record(processIdentifier: 7, swallowed: false, usedExtraQuiet: false, eligibility: eligible)
        }
        let legacyWouldExtend = agedRetries.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 101)
        agedRetries.record(processIdentifier: 7, swallowed: false, usedExtraQuiet: legacyWouldExtend, eligibility: eligible)
        if legacyWouldExtend
            || !agedRetries.shouldExtend(processIdentifier: 8, lastChangeMilliseconds: 101)
            || agedRetries.shouldExtend(processIdentifier: 8, lastChangeMilliseconds: nil) {
            failures.append("six native successes must age this pid's retries; unknown timing cannot authorize extra quiet")
        }

        var completedFollowup = ComposerExtraQuietHistory()
        completedFollowup.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
        completedFollowup.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
        completedFollowup.record(processIdentifier: 7, swallowed: false, usedExtraQuiet: true, eligibility: eligible)
        for _ in 0..<4 {
            completedFollowup.record(processIdentifier: 7, swallowed: false, usedExtraQuiet: false, eligibility: eligible)
        }
        // These later legacy sends must not leak into the already completed four-send window.
        for swallowed in [true, false, true, false] {
            completedFollowup.record(processIdentifier: 7, swallowed: swallowed, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
        }
        if !completedFollowup.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 101) {
            failures.append("four native sends must close followup window without stale disablement")
        }
        let currentToken = OperationCancellationToken()
        let cancelledToken = OperationCancellationToken()
        cancelledToken.cancel()
        var cancelled = eligible
        cancelled.isCancelled = cancelledToken.isCancelled
        var empty = eligible
        empty.observedNonemptySend = false
        let oldToken = OperationCancellationToken()
        var supersededToken = eligible
        supersededToken.tokenIsCurrent = oldToken === currentToken
        var inactiveSession = eligible
        inactiveSession.sessionIsCurrent = false
        var targetInvalid = eligible
        targetInvalid.targetIsValid = false
        let rejected = [("cancelled", cancelled), ("empty", empty), ("supersededToken", supersededToken),
                        ("inactiveSession", inactiveSession), ("targetInvalid", targetInvalid)]
        for (name, eligibility) in rejected {
            var history = ComposerExtraQuietHistory()
            for _ in 0..<2 {
                history.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
            }
            for _ in 0..<6 {
                history.record(processIdentifier: 7, swallowed: false, usedExtraQuiet: false, eligibility: eligibility)
            }
            if !history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 101) {
                failures.append("\(name) sends must not age the recent-six window")
            }
            history.record(processIdentifier: 7, swallowed: false, usedExtraQuiet: true, eligibility: eligible)
            for _ in 0..<4 {
                history.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: true, lastChangeMilliseconds: 250, eligibility: eligibility)
            }
            for _ in 0..<4 {
                history.record(processIdentifier: 7, swallowed: false, usedExtraQuiet: false, eligibility: eligible)
            }
            for swallowed in [true, false, true, false] {
                history.record(processIdentifier: 7, swallowed: swallowed, usedExtraQuiet: false, lastChangeMilliseconds: 250, eligibility: eligible)
            }
            if !history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 101) {
                failures.append("\(name) sends must not advance or disable the following-four window")
            }
        }
        print("C4_SEQUENCES assertions=15 failures=\(failures.count) pure_memory=1 eligibility_cases=5 rejected_records=50")
        return failures + runLateOnly()
    }

    private static func runLateOnly() -> [String] {
        var failures: [String] = []
        var assertions = 0
        let eligible = ComposerExtraQuietHistory.RecordingEligibility(
            sessionIsCurrent: true, tokenIsCurrent: true, isCancelled: false,
            targetIsValid: true, observedNonemptySend: true)
        for lastChange: Int? in [0, 100, -1, nil] {
            var history = ComposerExtraQuietHistory()
            for _ in 0..<2 {
                history.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false,
                               lastChangeMilliseconds: lastChange, eligibility: eligible)
            }
            assertions += 1
            if history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 500) {
                failures.append("S2 steady, early or unknown swallowed sends must not seed C4")
            }
            for _ in 0..<2 {
                history.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false,
                               lastChangeMilliseconds: 101, eligibility: eligible)
            }
            assertions += 1
            if !history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 500) {
                failures.append("S2 two valid late swallowed sends must seed C4 independently of earlier exclusions")
            }
            history.record(processIdentifier: 7, swallowed: false, usedExtraQuiet: true, eligibility: eligible)
            for _ in 0..<4 {
                history.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: true,
                               lastChangeMilliseconds: lastChange, eligibility: eligible)
            }
            for _ in 0..<2 {
                history.record(processIdentifier: 7, swallowed: true, usedExtraQuiet: false,
                               lastChangeMilliseconds: 101, eligibility: eligible)
            }
            assertions += 1
            if !history.shouldExtend(processIdentifier: 7, lastChangeMilliseconds: 500) {
                failures.append("S2 non-late swallowed followups must not disable C4")
            }
        }
        print("S2_LATE_ONLY assertions=\(assertions) failures=\(failures.count) history_text=0 disk=0")
        return failures
    }
}
