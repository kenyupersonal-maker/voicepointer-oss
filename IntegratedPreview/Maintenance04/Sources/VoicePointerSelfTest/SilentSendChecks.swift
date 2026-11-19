import CoreGraphics
import Foundation
@_spi(Testing) import VoicePointerCore

@MainActor enum SilentSendChecks {
    private final class Focus: FocusProviding, @unchecked Sendable {
        func snapshot(at: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? { nil }
        func setFocused(candidateIdentifier: String) -> Bool { false }
        func isFocused(candidateIdentifier: String) -> Bool { false }
        func synthesizeClick(candidateIdentifier: String) -> Bool { false }
    }
    private final class Composer: ComposerActionExecuting, TranscriptDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var counts = (sends: 0, units: 0)
        var sent: Int { lock.withLock { counts.sends } }
        var units: Int { lock.withLock { counts.units } }
        func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
            .ready(.init(testIdentifier: 1, cancellationToken: cancellationToken))
        }
        func perform(_ action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome { .kept }
        func deliver(text: String, action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome {
            guard session?.isCancelled == false else { return .targetChanged }
            lock.withLock { counts.sends += action == .send ? 1 : 0; counts.units = text.utf16.count }
            return action == .send ? .sent : .kept
        }
        func cancel(session: ComposerActionSession?) {}
    }
    private final class Backend: SpeechInputBackend, SpeechCaptureActivityProviding {
        var hasAcceptedCaptureAudio = true // real room noise also opens the capture gate.
        let capabilities = SpeechInputCapabilities(deliveryKind: .transcriptStream, supportsPartialText: true, supportsHints: false)
        var isQuiescent = true
        var finishes = 0, cancels = 0, finishing = false
        var delayMilliseconds = 120
        private var snapshot: VoiceInputSnapshot?
        private var receiver: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
        private var sequence: UInt64 = 0
        func start(snapshot: VoiceInputSnapshot, onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void) async throws {
            self.snapshot = snapshot; receiver = onEvent; isQuiescent = false; emit(.ready)
        }
        func emit(_ kind: SpeechInputEvent.Kind, code: String? = nil) {
            guard let snapshot else { return }
            sequence += 1
            receiver?(.init(sessionID: snapshot.sessionID, sequence: sequence, observedMilliseconds: Double(sequence),
                kind: kind, text: kind == .partial || kind == .final ? "synthetic" : nil, errorCode: code))
        }
        func finish() async {
            finishes += 1; finishing = true
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            emit(.final); isQuiescent = true
        }
        func cancel() async { cancels += 1; isQuiescent = true }
    }
    private static func wait(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("S \(label)") } }
        expect(SilentSendPolicy.qualifies(partials: 0, peak: nil) && SilentSendPolicy.qualifies(partials: 0, peak: 0), "no callbacks and zeros qualify")
        expect(SilentSendPolicy.qualifies(partials: 0, peak: 0.0079), "room noise qualifies")
        expect(!SilentSendPolicy.qualifies(partials: 1, peak: 0) && !SilentSendPolicy.qualifies(partials: 0, peak: 0.008), "partial and threshold preserve finalization")
        expect(!SilentSendPolicy.qualifies(partials: 0, peak: .nan), "nonfinite reading fails closed")
        expect(SilentSendPolicy.externalSettleMilliseconds(action: .send, heard: .silence) == 250 &&
            SilentSendPolicy.externalSettleMilliseconds(action: .send, heard: .speech) == 1000 &&
            SilentSendPolicy.externalSettleMilliseconds(action: .send, heard: .unknown) == 1000, "Doubao silence-only 250ms")
        expect(ComposerSendLandingPolicy.decide(expected: "fixture", original: "", current: "", elapsedMilliseconds: 0) == .wait, "Codex empty read waits")
        expect(ComposerSendLandingPolicy.decide(expected: "fixture", original: "", current: "fixture", elapsedMilliseconds: 400) == .ready, "late paste then Return")
        expect(ComposerSendLandingPolicy.decide(expected: "fixture", original: "", current: "", elapsedMilliseconds: 800) == .stop, "landing deadline prevents Return")
        expect(ComposerSendLandingPolicy.decide(expected: "fixture", original: "", current: "unrelated", elapsedMilliseconds: 100) == .stop, "unrelated edit never submits")
        let selection = try! VoiceInputSelection(mode: .voiceNative, routeID: "qwen06-rolling", language: "zh")
        let activation = GestureActivation(location: .init(x: 20, y: 20), button: .left,
            match: .init(deviceToken: 1, deviceKind: .magicMouse, touchCount: 2, newestTouchAgeSeconds: 0.01, maximumMovement: 0.001))
        for scenario in 0..<5 {
            let backend = Backend(), composer = Composer()
            var preempted = false
            let coordinator = VoicePointerCoordinator(focusEngine: .init(provider: Focus()), composerActionExecutor: composer,
                outcomeHandler: { outcome, _, feedback in if outcome == .sendPreempted { preempted = feedback.shouldPresent } },
                statusHandler: { _, _ in })
            coordinator.setSpeechBackendFactoryForTesting { _ in backend }
            expect(coordinator.gestureBegan(activation, settings: VoicePointerSettings(), selection: selection), "begin")
            expect(await wait { coordinator.status == .listening }, "ready")
            if scenario == 1 || scenario == 4 { backend.emit(.partial) }
            if scenario == 2 { GestureSpeechActivity.shared.recordCapture(peakLevel: 0.008) }
            if scenario == 3 { backend.emit(.failed, code: "MICROPHONE_NO_SOUND") }
            let started = DispatchTime.now().uptimeNanoseconds
            if scenario == 4 {
                backend.delayMilliseconds = 300
                let release = Task { await coordinator.gestureEnded(action: .send) }
                expect(await wait { backend.finishing }, "pending final")
                coordinator.preemptPendingSend()
                await release.value
                expect(preempted && composer.sent == 0, "preemption visibly fails with no later send")
            } else {
                await coordinator.gestureEnded(action: .send)
                let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                if scenario == 0 || scenario == 3 {
                    expect(backend.finishes == 0 && composer.sent == 1 && composer.units == 0 && milliseconds < 300,
                        "silence bypasses final and every ASR failure")
                } else {
                    expect(backend.finishes == 1 && composer.sent == 1 && composer.units > 0 && milliseconds >= 100,
                        "partial or audible reading waits for actual final")
                }
            }
            await coordinator.applicationWillTerminate()
        }
        return failures
    }
}
