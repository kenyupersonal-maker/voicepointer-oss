import Foundation
import CoreGraphics
@_spi(Testing) import VoicePointerCore

/// Coordinator-only safety checks. All boundaries below are fakes: no AX,
/// hardware, permissions, or real keyboard posting are exercised.
@MainActor
public enum CoordinatorSafetyChecks {
    public static func run() async -> [String] {
        var failures: [String] = []
        await checkEarlyRelease(&failures)
        await checkLateReadyAfterCancel(&failures)
        await checkReleaseFailureBlocksAction(&failures)
        await checkSafetyInvalidation(&failures)
        await checkAdmissionMetadataSurvivesCoordinatorInstall(&failures)
        await checkRepeatedCancel(&failures)
        await checkOutcomeFeedback(&failures)
        checkCloudRouteRequiresAdmission(&failures)
        await checkAliyunFallsBackToLocalWithoutAdmission(&failures)
        checkTargetInvalidationIdentity(&failures)
        await checkPressDuringFailure(&failures)
        return failures
    }
    private static func checkPressDuringFailure(_ failures: inout [String]) async {
        let focus = GateFocusProvider()
        let coordinator = VoicePointerCoordinator(focusEngine: SmartFocusEngine(provider: focus),
            keyboardSender: ProbeKeyboardSender(), composerActionExecutor: ProbeComposer())
        let blocked = try! VoiceInputSelection(mode: .voiceNative, routeID: "groq-v3", language: "zh")
        _ = coordinator.gestureBegan(activation(), settings: VoicePointerSettings(focusMode: .smart), selection: blocked)
        guard case .failed = coordinator.status else { failures.append("F6 fixture must first show failure"); return }
        let accepted = coordinator.gestureBegan(activation(), settings: VoicePointerSettings(focusMode: .smart))
        if !accepted { failures.append("F6 fresh press during failed HUD must begin") }
        if case .resolvingTarget = coordinator.status {} else { failures.append("F6 fresh press must resolve a target") }
        focus.allowSnapshot.signal()
        await coordinator.cancel()
        await coordinator.waitForCancelledResources()
    }

    private static func checkTargetInvalidationIdentity(_ failures: inout [String]) {
        // install(new) cancels old; stale invalidate(old) must not cancel new.
        let safety = VoiceOperationSafety()
        let oldToken = OperationCancellationToken()
        let newToken = OperationCancellationToken()
        safety.install(oldToken)
        safety.install(newToken)
        if !oldToken.isCancelled {
            failures.append("install(new) should cancel the previously installed old token")
        }
        if newToken.isCancelled {
            failures.append("install(new) must not cancel the newly installed token")
        }
        safety.invalidate(token: oldToken)
        if newToken.isCancelled {
            failures.append("stale invalidate(old) must not cancel the installed new token")
        }
        safety.invalidate(token: newToken)
        if !newToken.isCancelled {
            failures.append("matching invalidate(new) must cancel the installed token")
        }
        // Repeat invalidate is harmless and must not resurrect or corrupt state.
        safety.invalidate(token: newToken)
        if !newToken.isCancelled {
            failures.append("repeated matching invalidate must leave the token cancelled")
        }
        safety.invalidate(token: oldToken)
        if !oldToken.isCancelled {
            failures.append("repeated stale invalidate must leave the old token cancelled")
        }
    
        // Native delivery child.cancel must not invalidate the installed parent;
        // invalidate(parent) must invalidate a sibling child.
        let deliverySafety = VoiceOperationSafety()
        let parent = OperationCancellationToken()
        deliverySafety.install(parent)
        let nativeChild = OperationCancellationToken(parent: parent)
        let siblingChild = OperationCancellationToken(parent: parent)
        nativeChild.cancel()
        if !nativeChild.isCancelled {
            failures.append("child.cancel() must cancel the child token itself")
        }
        if parent.isCancelled {
            failures.append("child.cancel() must leave the installed parent token valid")
        }
        deliverySafety.invalidate(token: parent)
        if !parent.isCancelled {
            failures.append("invalidate(parent) must cancel the installed parent token")
        }
        if !siblingChild.isCancelled {
            failures.append("invalidate(parent) must invalidate sibling children of the parent")
        }
    }

    /// Groq stays hard-blocked at gesture start. Aliyun is decided per dictation by the admission gate
    /// (see checkAliyunFallsBackToLocalWithoutAdmission).
    private static func checkCloudRouteRequiresAdmission(_ failures: inout [String]) {
        for routeID in ["groq-v3", "groq-turbo"] {
            let focus = GateFocusProvider()
            let composer = ProbeComposer()
            let keyboard = ProbeKeyboardSender()
            let coordinator = VoicePointerCoordinator(
                focusEngine: SmartFocusEngine(provider: focus), keyboardSender: keyboard,
                composerActionExecutor: composer)
            guard let selection = try? VoiceInputSelection(mode: .voiceNative, routeID: routeID, language: "zh") else {
                failures.append("cloud admission: invalid fixture \(routeID)"); continue
            }
            let started = coordinator.gestureBegan(
                activation(), settings: VoicePointerSettings(focusMode: .smart),
                selection: selection, cloudConsent: ["groq", "aliyun-beijing"])
            guard started, case .failed = coordinator.status,
                  focus.snapshotStarted.wait(timeout: .now()) == .timedOut,
                  composer.performCount == 0, keyboard.events.isEmpty else {
                failures.append("cloud admission: legacy consent opened \(routeID)")
                focus.allowSnapshot.signal()
                continue
            }
        }
    }

    /// No admission inputs are supplied (the app's state today), so an aliyun selection must be denied and
    /// run on the local route: never a cloud backend. Hermetic: the fallback's LocalSpeechBackend stops at
    /// its bundled-catalog lookup, which this binary lacks, before any permission prompt, microphone or
    /// worker. Skipped wherever that catalog could be found, so this can never start real recognition.
    private static func checkAliyunFallsBackToLocalWithoutAdmission(_ failures: inout [String]) async {
        guard Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Backend") == nil else { return }
        guard let selection = try? VoiceInputSelection(mode: .voiceNative, routeID: "aliyun", language: "zh") else {
            failures.append("aliyun fallback: invalid fixture"); return
        }
        let traceURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true
        ).appendingPathComponent("AliyunFallbackChecks-\(UUID().uuidString).log")
        RuntimeTrace.configureForTesting(fileURL: traceURL)
        let coordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: ImmediateFocusProvider()),
            keyboardOwnership: KeyboardOwnershipManager(backend: FailingUpBackend()),
            composerActionExecutor: ProbeComposer()
        )
        coordinator.gestureBegan(
            activation(), settings: VoicePointerSettings(focusMode: .smart),
            selection: selection, cloudConsent: ["aliyun-beijing"], localHotwords: ["OpenAI", "Qwen"])
        var trace = ""
        for _ in 0..<150 {
            RuntimeTrace.flush()
            trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
            if trace.contains("speech backend start rejected") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await coordinator.cancel()
        await coordinator.waitForCancelledResources()
        if !trace.contains("cloud admission denied reason=notConfigured fallback=local") {
            failures.append("aliyun fallback: denial without admission inputs was not recorded")
        }
        if !trace.contains("speech backend start mode=voiceNative route=qwen17-rolling") {
            failures.append("aliyun fallback: dictation did not run on the local route")
        }
        if !trace.contains("speech backend start mode=voiceNative route=qwen17-rolling localHotwords=2") {
            failures.append("aliyun fallback: the local fallback did not carry the hot words")
        }
        if trace.contains("route=aliyun") || trace.contains("cloud admission admitted") {
            failures.append("aliyun fallback: a cloud backend was started without an admitted permit")
        }
    }

    private static func checkEarlyRelease(_ failures: inout [String]) async {
        let focus = GateFocusProvider()
        let composer = ProbeComposer()
        let keyboard = ProbeKeyboardSender()
        let coordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: focus),
            keyboardSender: keyboard,
            composerActionExecutor: composer
        )
        coordinator.gestureBegan(activation(), settings: VoicePointerSettings(focusMode: .smart))
        guard await asyncWait(focus.snapshotStarted) else {
            failures.append("early release: focus snapshot did not start")
            return
        }
        await coordinator.gestureEnded(action: .send)
        focus.allowSnapshot.signal()
        _ = await asyncWait(focus.snapshotFinished)
        failures += keyboard.events.isEmpty ? [] : ["early release injected keyboard event"]
        failures += composer.performCount == 0 ? [] : ["early release performed composer action"]
    }

    private static func checkLateReadyAfterCancel(_ failures: inout [String]) async {
        let composer = GateComposer()
        let coordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: ImmediateFocusProvider()),
            keyboardSender: ProbeKeyboardSender(),
            composerActionExecutor: composer
        )
        coordinator.gestureBegan(activation(), settings: VoicePointerSettings(focusMode: .smart))
        guard await asyncWait(composer.beginStarted) else {
            failures.append("late ready: begin did not start")
            return
        }
        await coordinator.cancel()
        await coordinator.waitForCancelledResources()
        composer.allowBegin.signal()
        _ = await asyncWait(composer.beginFinished)
        guard coordinator.status == .idle else { failures.append("late ready changed cancelled coordinator state") ; return }
        guard composer.performCount == 0 else { failures.append("late ready performed action") ; return }
    }

    private static func checkReleaseFailureBlocksAction(_ failures: inout [String]) async {
        let backend = FailingUpBackend()
        let composer = ProbeComposer()
        let coordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: ImmediateFocusProvider()),
            keyboardOwnership: KeyboardOwnershipManager(backend: backend),
            composerActionExecutor: composer
        )
        coordinator.gestureBegan(activation(), settings: VoicePointerSettings(focusMode: .smart))
        guard await asyncWait(backend.downSubmitted) else {
            failures.append("release failure: ownership down did not submit")
            return
        }
        var listening = false
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if coordinator.status == .listening { listening = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard listening else {
            failures.append("release failure: coordinator did not reach listening")
            return
        }
        await coordinator.gestureEnded(action: .send)
        guard await asyncWait(backend.upAttempted) else {
            failures.append("release failure: ownership up was not attempted")
            return
        }
        guard composer.performCount == 0 else { failures.append("release failure allowed composer action") ; return }
    }

    private static func checkSafetyInvalidation(_ failures: inout [String]) async {
        let safety = VoiceOperationSafety()
        let token = OperationCancellationToken()
        safety.install(token)
        safety.invalidate()
        guard token.isCancelled else { failures.append("operationSafety did not invalidate token") ; return }
    }

    private static func checkOutcomeFeedback(_ failures: inout [String]) async {
        let outcomes: [ComposerActionOutcome] = [
            .kept, .sent, .nothingToSend, .removedCurrentDictation,
            .clearedCurrentInput, .clearArmed, .nothingToCancel,
            .targetChanged, .unsafeToCancel, .eventPostFailed,
            .sendUnconfirmed, .sendStillPresent, .cancelUnconfirmed, .dictationNotSettled,
        ]
        for outcome in outcomes {
            let composer = FixedOutcomeComposer(outcome: outcome)
            var returned: [ComposerActionOutcome] = []
            var statuses: [VoicePointerRuntimeStatus] = []
            let coordinator = VoicePointerCoordinator(
                focusEngine: SmartFocusEngine(provider: ImmediateFocusProvider()),
                keyboardSender: ProbeKeyboardSender(),
                composerActionExecutor: composer,
                outcomeHandler: { result, _, _ in returned.append(result) },
                statusHandler: { status, _ in statuses.append(status) }
            )
            coordinator.gestureBegan(activation(), settings: VoicePointerSettings(focusMode: .smart))
            for _ in 0..<200 {
                if coordinator.status == .listening { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard coordinator.status == .listening else {
                failures.append("feedback \(outcome.rawValue): no listening session")
                await coordinator.cancel()
                await coordinator.waitForCancelledResources()
                continue
            }
            await coordinator.gestureEnded(action: .send)
            let feedback = ComposerActionFeedback(outcome: outcome, action: .send)
            let expected: VoicePointerRuntimeStatus
            if let presentation = feedback.presentation {
                expected = VoiceIssuePresentationPolicy.runtimeStatus(
                    for: presentation,
                    isPresentationAllowed: feedback.shouldPresent
                )
            } else {
                expected = feedback.shouldPresent && feedback.kind == .warning
                    ? .failed(feedback.message) : .idle
            }
            if returned != [outcome] || coordinator.status != expected || composer.performCount != 1 {
                failures.append("feedback \(outcome.rawValue): outcome/status/one-action mismatch")
            }
            if statuses.contains(where: { $0.title.contains("已保留文字") }) {
                failures.append("feedback \(outcome.rawValue): unsupported retention claim")
            }
            await coordinator.cancel()
            await coordinator.waitForCancelledResources()
        }
    }

    private static func checkRepeatedCancel(_ failures: inout [String]) async {
        let coordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: ImmediateFocusProvider()),
            keyboardSender: ProbeKeyboardSender(),
            composerActionExecutor: ProbeComposer()
        )
        coordinator.gestureBegan(activation(), settings: VoicePointerSettings(focusMode: .smart))
        await coordinator.cancel()
        await coordinator.cancel()
        await coordinator.waitForCancelledResources()
        guard coordinator.status == .idle else { failures.append("repeated cancel did not settle idle") ; return }
    }

    private static func checkAdmissionMetadataSurvivesCoordinatorInstall(_ failures: inout [String]) async {
        let coordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: ImmediateFocusProvider()),
            keyboardSender: ProbeKeyboardSender(),
            composerActionExecutor: ProbeComposer()
        )
        let token = OperationCancellationToken()
        // Match the App call order: bind admission metadata first, then the
        // coordinator re-installs this same token without metadata.
        coordinator.operationSafety.install(token, generation: 7, gestureID: 701)
        let accepted = coordinator.gestureBegan(
            activation(), settings: VoicePointerSettings(focusMode: .smart), cancellationToken: token
        )
        if !accepted { failures.append("metadata preservation: coordinator rejected fresh begin") }
        coordinator.operationSafety.invalidate(olderThanGeneration: 7)
        if token.isCancelled { failures.append("metadata preservation: same-generation invalidation cancelled current operation") }
        coordinator.operationSafety.invalidate(gestureID: 701)
        if !token.isCancelled { failures.append("metadata preservation: matching dropped gesture did not cancel its operation") }
        await coordinator.cancel()
        await coordinator.waitForCancelledResources()
    }

    private static func activation() -> GestureActivation {
        GestureActivation(
            location: CGPoint(x: 20, y: 20), button: .left,
            match: GestureMatch(deviceToken: 1, deviceKind: .magicMouse,
                                touchCount: 2, newestTouchAgeSeconds: 0.01,
                                maximumMovement: 0.001)
        )
    }
}

private func blockingWait(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}

private func asyncWait(_ semaphore: DispatchSemaphore) async -> Bool {
    await Task.detached { blockingWait(semaphore) }.value
}

private class ImmediateFocusProvider: FocusProviding, @unchecked Sendable {
    private let candidate = FocusCandidate(identifier: "fake", role: "AXTextArea", frame: CGRect(x: 0, y: 0, width: 100, height: 40))
    func snapshot(at _: CGPoint, configuration _: SmartFocusConfiguration) -> FocusSnapshot? { FocusSnapshot(contextIdentifier: "fake", bundleIdentifier: nil, candidates: [candidate]) }
    func setFocused(candidateIdentifier _: String) -> Bool { true }
    func isFocused(candidateIdentifier _: String) -> Bool { true }
    func synthesizeClick(candidateIdentifier _: String) -> Bool { true }
}

private final class GateFocusProvider: ImmediateFocusProvider, @unchecked Sendable {
    let snapshotStarted = DispatchSemaphore(value: 0)
    let allowSnapshot = DispatchSemaphore(value: 0)
    let snapshotFinished = DispatchSemaphore(value: 0)
    override func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? {
        snapshotStarted.signal(); _ = blockingWait(allowSnapshot); snapshotFinished.signal()
        return super.snapshot(at: point, configuration: configuration)
    }
}

private class ProbeComposer: @unchecked Sendable, ComposerActionExecuting {
    private let lock = NSLock()
    private(set) var performCount = 0
    func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult { .ready(ComposerActionSession(cancellationToken: cancellationToken)) }
    func perform(_ action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome { lock.withLock { performCount += 1 }; return .kept }
    func cancel(session: ComposerActionSession?) {}
}

private final class GateComposer: ProbeComposer, @unchecked Sendable {
    let beginStarted = DispatchSemaphore(value: 0)
    let allowBegin = DispatchSemaphore(value: 0)
    let beginFinished = DispatchSemaphore(value: 0)
    override func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
        beginStarted.signal(); _ = await asyncWait(allowBegin); beginFinished.signal()
        return .ready(ComposerActionSession(cancellationToken: cancellationToken))
    }
}

private final class FixedOutcomeComposer: ProbeComposer, @unchecked Sendable {
    private let outcome: ComposerActionOutcome
    init(outcome: ComposerActionOutcome) { self.outcome = outcome }
    override func perform(_ action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
        _ = await super.perform(action, session: session)
        return outcome
    }
}

private final class ProbeKeyboardSender: KeyboardEventSending, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []
    func keyDown(_ modifier: VoiceModifier) async { lock.withLock { events.append("down:\(modifier.rawValue)") } }
    func keyUp(_ modifier: VoiceModifier) async { lock.withLock { events.append("up:\(modifier.rawValue)") } }
    func tap(_ modifier: VoiceModifier) async { lock.withLock { events.append("tap:\(modifier.rawValue)") } }
}

private final class FailingUpBackend: KeyboardEventPosting, @unchecked Sendable {
    let downSubmitted = DispatchSemaphore(value: 0)
    let upAttempted = DispatchSemaphore(value: 0)
    func post(modifier _: VoiceModifier, isDown: Bool, marker _: UInt64) -> KeyboardEventPostResult {
        if isDown { downSubmitted.signal(); return .submitted }
        upAttempted.signal(); return .failed(reason: "probeUpFailure")
    }
}
