import Foundation

/// Run-local counts only: no field text, disk state or relaxed retry authorization.
@_spi(Testing)
public struct ComposerExtraQuietHistory: Sendable {
    public struct RecordingEligibility: Sendable {
        public var sessionIsCurrent, tokenIsCurrent, isCancelled, targetIsValid, observedNonemptySend: Bool
        public init(sessionIsCurrent: Bool, tokenIsCurrent: Bool, isCancelled: Bool,
                    targetIsValid: Bool, observedNonemptySend: Bool) {
            self.sessionIsCurrent = sessionIsCurrent
            self.tokenIsCurrent = tokenIsCurrent
            self.isCancelled = isCancelled
            self.targetIsValid = targetIsValid
            self.observedNonemptySend = observedNonemptySend
        }
        public var allowsRecording: Bool {
            sessionIsCurrent && tokenIsCurrent && !isCancelled && targetIsValid && observedNonemptySend
        }
    }
    private struct Target: Sendable {
        var recent: [Bool] = []
        var following: [Bool]?
        var disabled = false
    }
    private var targets: [pid_t: Target] = [:]
    public init() {}

    /// Missing settle timing is unknown; it cannot authorize a longer quiet window.
    public func shouldExtend(processIdentifier: pid_t, lastChangeMilliseconds: Int?) -> Bool {
        guard let lastChangeMilliseconds, lastChangeMilliseconds > 100,
              let target = targets[processIdentifier],
              !target.disabled else { return false }
        return target.recent.filter { $0 }.count >= 2
    }

    public mutating func record(processIdentifier: pid_t, swallowed: Bool, usedExtraQuiet: Bool,
                                lastChangeMilliseconds: Int? = nil,
                                eligibility: RecordingEligibility) {
        guard eligibility.allowsRecording else { return }
        let lateSwallowed = swallowed && (lastChangeMilliseconds ?? -1) > 100
        var target = targets[processIdentifier] ?? Target()
        target.recent = Array((target.recent + [lateSwallowed]).suffix(6))
        if usedExtraQuiet && target.following == nil {
            target.following = [] // The four sends AFTER the first extended send.
        } else if var following = target.following, following.count < 4 {
            following.append(lateSwallowed)
            target.following = following
            if following.count == 4 && following.filter({ $0 }).count >= 2 { target.disabled = true }
        }
        targets[processIdentifier] = target
    }
}
