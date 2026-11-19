import Foundation

/// Synthetic boundaries around the production adapter; no microphone, worker process or audio files.
@_spi(Testing) @MainActor
public enum LocalCancellationProbe {
    private final class Capture: LocalSpeechCapture {
        var onCaptureFailure: (@Sendable (String) -> Void)?
        var captureFailure: TrialCoreError?
        var stopped = true, stops = 0, offers = 0
        private var stopWaiters: [CheckedContinuation<Void, Never>] = []
        func start(streamingToApple: Bool) throws { stopped = false }
        func stop() {
            if !stopped { stops += 1; stopped = true }
            let waiters = stopWaiters; stopWaiters = []
            waiters.forEach { $0.resume() }
        }
        func waitForStop() async {
            if !stopped { await withCheckedContinuation { stopWaiters.append($0) } }
        }
        func snapshotBuffers() -> [OwnedPCMBuffer] { [] }
        func offer() { if !stopped { offers += 1 } }
    }
    private actor Client: BetaInferenceClient {
        private var release: CheckedContinuation<Void, Never>?
        private var started: [CheckedContinuation<Void, Never>] = []
        var waiting: Bool { release != nil }
        var shutdowns = 0, inferences = 0
        func start() async throws {
            await withCheckedContinuation { continuation in
                release = continuation
                let listeners = started; started = []
                listeners.forEach { $0.resume() }
            }
        }
        func waitForStart() async {
            if release == nil { await withCheckedContinuation { started.append($0) } }
        }
        func resume() { release?.resume(); release = nil }
        func shutdown() async { shutdowns += 1 }
        func infer(sessionID: String, revision: Int, pcm: Data, final: Bool) async throws -> BetaWorkerResult {
            try await infer(sessionID: sessionID, revision: revision, pcm: pcm, final: final, context: nil)
        }
        func infer(sessionID: String, revision: Int, pcm: Data, final: Bool, context: BetaRecognitionContext?) async throws -> BetaWorkerResult {
            inferences += 1
            throw CancellationError()
        }
    }
    public static func run() async -> [String] {
        var failures: [String] = [], cases = 0
        func check(_ result: Bool, _ code: String) {
            cases += 1
            if !result { failures.append("event=local_cancel_probe,state=failed,case=" + code) }
        }
        let capture = Capture(), client = Client(), pool = LocalWorkerPool(factory: { _, _ in client })
        let profile = BetaProfile(id: "qwen06-rolling", label: "synthetic", summary: "synthetic",
            backend: "qwen", host: nil, correction: "none", streaming_kind: "rolling", max_seconds: 30,
            initial_seconds: 300, interval_seconds: 300, experimental: false, required_files: [], languages: ["zh"])
        let backend = LocalSpeechBackend(pool: pool, loadProfiles: { [profile] },
            requestPermission: { true }, makeCapture: { capture })
        var events: [SpeechInputEvent.Kind] = []
        do {
            let selection = try VoiceInputSelection(mode: .voiceNative, routeID: profile.id, language: "zh")
            let snapshot = try VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 0)
            try await backend.start(snapshot: snapshot) { events.append($0.kind) }
            await client.waitForStart()
            check(events == [.ready] && !backend.isQuiescent, "ready_with_owned_lease")
            capture.offer(); check(capture.offers == 1, "capture_admission_before_cancel")
            backend.invalidateCaptureForCancellation()
            await capture.waitForStop()
            capture.offer()
            check(capture.stopped && capture.stops == 1 && capture.offers == 1, "capture_closed_before_lease_cleanup")
            let waiting = await client.waiting
            check(!backend.isQuiescent && waiting, "lease_retained_during_slow_cleanup")
            capture.onCaptureFailure?("LOCAL_CAPTURE_FAILED")
            backend.invalidateCaptureForCancellation()
            check(capture.stops == 1, "invalidation_idempotent")
            let cleanup = Task { @MainActor in await backend.cancel() }
            await client.resume(); await cleanup.value
            check(backend.isQuiescent, "owned_cleanup_drained")
            check(events == [.ready], "late_failure_and_final_discarded")
            let shutdowns = await client.shutdowns, inferences = await client.inferences
            check(shutdowns == 1 && inferences == 0, "one_lease_release_no_inference")
            await backend.cancel()
            let finalShutdowns = await client.shutdowns
            check(capture.stops == 1 && finalShutdowns == 1, "cancel_idempotent")
        } catch { check(false, "fixture_start") }
        await pool.shutdownAll()
        print("event=local_cancel_probe,state=\(failures.isEmpty ? "passed" : "failed"),cases=\(cases),physical_capture=0,pcm_after_cancel=0")
        return failures
    }
}
