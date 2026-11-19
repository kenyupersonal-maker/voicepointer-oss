import Foundation
import VoicePointerCore

enum VoiceIssuePresentationChecks {
    static func runSettleTimeout() -> [String] {
        var failures: [String] = []
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() { failures.append("S3 presentation: " + message) }
        }
        let timeout = ComposerActionFeedback(outcome: .dictationNotSettled, action: .send)
        expect(VoiceIssuePresentationPolicy.dictationNotSettledMessage == "文字还在变，这次没自动发送；看一眼没问题就按回车。",
               "central constant preserves the exact approved HUD copy")
        expect(timeout.message == VoiceIssuePresentationPolicy.dictationNotSettledMessage,
               "composer timeout uses the central copy")
        expect(timeout.presentation?.code == .dictationNotSettled && timeout.kind == .warning,
               "settle timeout retains its own typed warning")
        expect(timeout.shouldPresent && timeout.statusChannelOwnsToast,
               "timeout reaches the HUD through the central status channel")
        if let presentation = timeout.presentation {
            expect(VoiceIssuePresentationPolicy.runtimeStatus(for: presentation, isPresentationAllowed: true)
                == .failed(VoiceIssuePresentationPolicy.dictationNotSettledMessage),
                   "HUD status preserves the timeout message")
            var gate = VoiceIssuePresentationGate()
            let session = UUID()
            let first = gate.shouldPresent(presentation, sessionID: session)
            let duplicate = gate.shouldPresent(presentation, sessionID: session)
            expect(first && !duplicate, "timeout is announced once per session")
        }
        let recognition = VoiceIssuePresentationPolicy.resolve(code: .recognitionFailed, stage: .backend, safeAction: .retryManually)
        expect(recognition.message != timeout.message && recognition.code == .recognitionFailed,
               "generic recognition failure does not claim that composer text is changing")
        for outcome in [ComposerActionOutcome.targetChanged, .cancelUnconfirmed, .unsafeToCancel, .eventPostFailed, .sendUnconfirmed] {
            let action: VoiceReleaseAction = outcome == .cancelUnconfirmed || outcome == .unsafeToCancel ? .cancel : .send
            let feedback = ComposerActionFeedback(outcome: outcome, action: action)
            expect(feedback.message != timeout.message && feedback.presentation?.code != .dictationNotSettled,
                   "\(outcome.rawValue) keeps its distinct failure presentation")
        }
        print("S3_TIMEOUT_PRESENTATION assertions=\(assertions) failures=\(failures.count) runtime=0")
        return failures
    }

    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append("VoiceIssuePresentation: " + message) }
        }

        let delivered = VoiceIssuePresentationPolicy.resolve(
            code: .deliveryFailed,
            stage: .delivery,
            safeAction: .refocusInput
        )
        let repeatedDeliveryCode = VoiceIssuePresentationPolicy.resolve(
            code: .deliveryFailed,
            stage: .send,
            safeAction: .retryManually
        )
        expect(delivered.code == .deliveryFailed, "policy preserves the typed failure code")
        expect(delivered.stage == .delivery && delivered.safeAction == .refocusInput,
               "policy preserves stage and safe action")
        expect(delivered.message == "文字写入失败，请重新点选输入框", "delivery code has its single approved copy")
        expect(repeatedDeliveryCode.message == delivered.message,
               "copy is selected by code, not by the supplied Chinese text or stage")
        expect(delivered.disposition == .toast && delivered.deduplicatesWithinSession,
               "deterministic delivery failure is a deduplicated toast")

        let silentOutcomes: [ComposerActionOutcome] = [
            .sendUnconfirmed, .cancelUnconfirmed,
            .kept, .removedCurrentDictation, .clearedCurrentInput
        ]
        for outcome in silentOutcomes {
            let feedback = ComposerActionFeedback(outcome: outcome, action: .send)
            expect(!feedback.shouldPresent,
                   "\(outcome.rawValue) remains silent and cannot become a failure toast")
            expect(feedback.presentation?.disposition == .silent,
                   "\(outcome.rawValue) maps to a typed silent disposition")
        }
        for outcome in [ComposerActionOutcome.deliveryUnconfirmed, .targetChanged] {
            expect(ComposerActionFeedback(outcome: outcome, action: .send).presentation?.code != .sendPreempted,
                   "D3 uncertainty is not reported as gesture preemption")
            expect(ComposerActionFeedback(outcome: outcome, action: .send).shouldPresent,
                   "send blocked before Return is visible")
            expect(!ComposerActionFeedback(outcome: outcome, action: .stop).shouldPresent,
                   "stop retains existing silent uncertainty policy")
        }

        let postFailure = ComposerActionFeedback(outcome: .eventPostFailed, action: .send)
        expect(postFailure.presentation?.code == .eventPostFailed,
               "event post failure has a stable code")
        expect(postFailure.presentation?.stage == .send,
               "event post failure records the send stage")
        expect(postFailure.message == "操作未能完成，请重试", "keyboard post copy follows 03 §4")
        expect(postFailure.statusChannelOwnsToast,
               "actionable warning toast is owned by the Coordinator status channel")

        let sendStillPresent = ComposerActionFeedback(outcome: .sendStillPresent, action: .send)
        expect(sendStillPresent.presentation?.disposition == .toast,
               "retained text after send is surfaced as a deterministic warning")
        expect(sendStillPresent.presentation?.safeAction == VoiceIssueSafeAction.none,
               "retained text does not imply that sending again is safe")

        let clearArmed = ComposerActionFeedback(outcome: .clearArmed, action: .cancel)
        let unsafeCancel = ComposerActionFeedback(outcome: .unsafeToCancel, action: .cancel)
        expect(unsafeCancel.message == "没删掉，请手动删一下",
               "downward-cancel hint preserves the existing product wording")
        expect(unsafeCancel.shouldPresent && !unsafeCancel.statusChannelOwnsToast,
               "downward-cancel hint remains visible through the completion HUD")
        expect(clearArmed.presentation?.disposition == .gestureHint && clearArmed.shouldPresent
            && !clearArmed.statusChannelOwnsToast && clearArmed.message == "再下滑清空",
               "arming the second swipe shows only a light disc hint")
        expect(unsafeCancel.presentation?.disposition == .gestureHint,
               "unsafe cancel remains a gesture hint, not a send failure")

        var gate = VoiceIssuePresentationGate()
        let firstSession = UUID()
        let nextSession = UUID()
        let firstIssueAllowed = gate.shouldPresent(delivered, sessionID: firstSession)
        expect(firstIssueAllowed,
               "first issue in a session is presented")
        let duplicateIssueAllowed = gate.shouldPresent(repeatedDeliveryCode, sessionID: firstSession)
        expect(!duplicateIssueAllowed,
               "same issue code is presented at most once per session")
        let nextSessionAllowed = gate.shouldPresent(delivered, sessionID: nextSession)
        expect(nextSessionAllowed,
               "same issue can be presented again in the next session")
        let sendUnknown = VoiceIssuePresentationPolicy.forComposerOutcome(.sendUnconfirmed, action: .send)
        let silentIssueAllowed = gate.shouldPresent(sendUnknown, sessionID: nextSession)
        expect(!silentIssueAllowed,
               "silent uncertainty never creates a toast")

        expect(VoiceIssuePresentationPolicy.runtimeStatus(for: delivered, isPresentationAllowed: firstIssueAllowed)
                   == .failed(delivered.message),
               "an allowed toast becomes a failed HUD status")
        expect(VoiceIssuePresentationPolicy.runtimeStatus(for: delivered, isPresentationAllowed: duplicateIssueAllowed)
                   == .idle,
               "a deduplicated toast clears stale failed/listening status")
        expect(VoiceIssuePresentationPolicy.runtimeStatus(
            for: sendUnknown,
            isPresentationAllowed: silentIssueAllowed
        ) == .idle, "silent uncertainty ends the listening state")
        expect(VoiceIssuePresentationPolicy.runtimeStatus(
            for: unsafeCancel.presentation!,
            isPresentationAllowed: true
        ) == .idle, "gesture hints stay with completion HUD instead of duplicating through status")

        // "用于增强本地识别": the hybrid backend's own failure keeps its own words instead of collapsing into the
        // generic recognition failure, and the allow-list stays exact around it.
        let incomplete = VoiceIssuePresentationPolicy.forBackendCode("HYBRID_FINAL_INCOMPLETE")
        expect(incomplete.code == .recognitionIncomplete, "the hybrid incomplete code is allow-listed and typed")
        expect(incomplete.stage == .backend && incomplete.safeAction == .retryManually,
               "an incomplete hybrid dictation is a backend issue the person can retry")
        expect(incomplete.disposition == .toast && incomplete.tone == .warning && incomplete.deduplicatesWithinSession,
               "an incomplete hybrid dictation is a deduplicated warning toast")
        expect(incomplete.message == "识别没完成，没有发送，请重试",
               "an incomplete hybrid dictation says that nothing was sent, whether or not any text was written")
        expect(incomplete.message != VoiceIssuePresentationPolicy.resolve(
            code: .recognitionFailed, stage: .backend, safeAction: .retryManually).message,
               "an incomplete hybrid dictation is not worded as a plain recognition failure")
        expect(VoiceIssuePresentationPolicy.runtimeStatus(for: incomplete, isPresentationAllowed: true)
                   == .failed(incomplete.message),
               "an allowed incomplete-dictation toast becomes a failed HUD status")
        expect(incomplete == VoiceIssuePresentationPolicy.resolve(
            code: .recognitionIncomplete, stage: .backend, safeAction: .retryManually),
               "the backend code maps onto the same presentation as the typed code")
        for near in ["hybrid_final_incomplete", "HYBRID_FINAL_INCOMPLETE ", "HYBRID_FINAL", "HYBRID_CLOUD_BACKLOG"] {
            expect(VoiceIssuePresentationPolicy.forBackendCode(near).code == .recognitionFailed,
                   "an unknown code near the hybrid one (\(near)) stays the generic failure")
        }

        let aliIssues: [(SpeechFailureDiagnostics.AliCode, VoiceIssueCode, VoiceIssueSafeAction)] = [
            (.authFailed, .apiKeyInvalid, .openSettings),
            (.accessDenied, .accessDenied, .openSettings),
            (.freeQuotaExhausted, .freeQuotaExhausted, .viewQuota),
            (.balanceDue, .balanceDue, .viewQuota),
            (.rateLimited, .rateLimited, .retryManually),
            (.modelUnavailable, .modelUnavailable, .switchProvider),
            (.networkFailed, .networkFailed, .retryManually),
            (.timeout, .responseTimeout, .retryManually),
            (.workerFailed, .localWorkerFailed, .retryManually),
            (.taskStartFailed, .recognitionStartFailed, .retryManually),
            (.streamFailed, .recognitionFailed, .retryManually),
        ]
        for (code, issue, action) in aliIssues {
            let shown = VoiceIssuePresentationPolicy.forBackendCode(code.rawValue)
            expect(shown.code == issue && shown.safeAction == action, "Ali typed issue/action \(code.rawValue)")
            expect(shown.message == SpeechFailureDiagnostics.AliDiagnostic(code: code).message,
                   "Ali production copy follows the F4 contract \(code.rawValue)")
            expect(shown.disposition == .toast && shown.tone == .warning && shown.deduplicatesWithinSession,
                   "Ali failures remain deduplicated warning toasts \(code.rawValue)")
        }
        var aliGate = VoiceIssuePresentationGate()
        for code in ["ALI_FREE_QUOTA_EXHAUSTED", "ALI_BALANCE_DUE", "ALI_MODEL_UNAVAILABLE"] {
            expect(aliGate.shouldPresent(VoiceIssuePresentationPolicy.forBackendCode(code), sessionID: firstSession),
                   "quota, debt and model failures do not suppress each other")
        }

        return failures + runSettleTimeout()
    }
}
