// T8 2026-10-02: Production meter/ring/sidecar/worker-pool paths with RAM and scripted boundaries only.
@preconcurrency import AVFoundation
import Foundation
import Darwin
import CAudioMeterSupport

private final class DoubaoProbeCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func increment(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
    func value(_ key: String) -> Int { lock.withLock { values[key, default: 0] } }
}
private struct DoubaoProbeAudio: DoubaoLearningAudioProviding {
    let result: DoubaoLearningAudioResult
    let counts: DoubaoProbeCounts
    private let ring = DoubaoLearningAudioRing()
    func arm() {
        counts.increment("arm")
        if case .audio = result { ring.arm(); ring.appendMeterBuffer(DoubaoLearningTesting.buffer(), rawPeak: 0.25) }
    }
    func take() -> DoubaoLearningAudioResult {
        counts.increment("take")
        if case .audio = result { return ring.take() }; return result
    }
    func clear() { ring.clear(); if case .audio(let value) = result { value.clear() }; counts.increment("clear") }
}
private actor DoubaoProbeTransport: ShortcutTransport {
    private(set) var acquires = 0, releases = 0
    func acquire(_ token: OperationCancellationToken) async -> Bool { acquires += 1; return !token.isCancelled }
    func release() async -> Bool { releases += 1; return true }
}
private actor DoubaoProbeClient: BetaInferenceClient {
    private(set) var requests = 0, starts = 0, stops = 0, priority = 0
    let score: LocalModelConfidence?
    var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(score: LocalModelConfidence?, held: Bool = false) { self.score = score; self.held = held }
    func prepareBackgroundPriority() { priority += 1 }
    func start() { starts += 1 }
    func shutdown() { stops += 1; continuation?.resume(); continuation = nil }
    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool) async throws -> BetaWorkerResult {
        try await infer(sessionID: sessionID, revision: revision, pcm: pcm, final: final, context: nil)
    }
    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool, context: BetaRecognitionContext?) async throws -> BetaWorkerResult {
        requests += 1
        guard final, !pcm.isEmpty, context == nil else { throw TrialCoreError.invalid("DOUBAO_PROBE_CONTRACT") }
        if held { await withCheckedContinuation { continuation = $0 } }
        return BetaWorkerResult(type: "result", session_id: sessionID, revision: revision,
            text: "use open ai for drafting notes", final: final, compute_ms: 1,
            model_confidence: score?.probability, model_confidence_source: score?.source.rawValue,
            model_confidence_token_count: score?.tokenCount)
    }
}
private actor DoubaoProbeBarrier {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

@_spi(Testing) @MainActor public enum DoubaoLearningTesting {
    nonisolated private static let referenceText = "use OpenAI for drafting notes"
    nonisolated private static let localText = "use open ai for drafting notes"
    nonisolated private static let date = Date(timeIntervalSince1970: 1_000)
    nonisolated private static var score: LocalModelConfidence {
        LocalModelConfidence(probability: 0.99, source: LocalModelConfidence.Source.qwenSelectedTokenMinimum.rawValue, tokenCount: 5)!
    }
    nonisolated private static func selection(_ mode: VoiceInputMode = .doubao) throws -> VoiceInputSelection {
        try VoiceInputSelection(mode: mode, routeID: "qwen17-rolling", language: "zh")
    }
    nonisolated private static func snapshot(_ selection: VoiceInputSelection) -> VoiceInputSnapshot {
        try! VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 0)
    }
    nonisolated private static func reference() -> DoubaoLearningReference {
        .init(baseline: .init(id: UUID(), processIdentifier: 0, document: referenceText, spanLocation: 0,
            spanLength: referenceText.utf16.count, delivered: referenceText, emptyStateValues: [],
            editingGeneration: 0, path: "doubao", revertTexts: []), observedAt: date)
    }
    nonisolated fileprivate static func buffer(peak: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)!
        buffer.frameLength = 320
        for i in 0..<320 { buffer.floatChannelData![0][i] = peak }
        return buffer
    }
    nonisolated private static func packet() -> DoubaoLearningAudio {
        DoubaoLearningAudio([try! OwnedPCMBuffer(copying: buffer())])
    }
    public static func run() async -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) { if !ok { failures.append("doubao learning: " + label) } }
        check(VPCAudioMeterRunPCMOutletProbe(), "same-tap gate never dispatches disabled/unsupported buffers")
        let ring = DoubaoLearningAudioRing(bufferLimit: 2)
        ring.appendMeterBuffer(buffer(), rawPeak: 0.25)
        check(ring.retainedBufferCount == 0, "unarmed ring copies nothing")
        ring.arm(); ring.appendMeterBuffer(buffer(peak: 0), rawPeak: 0)
        if case .silent = ring.take() {} else { check(false, "T1 gate skips zero PCM") }
        ring.arm()
        if case .missing = ring.take() {} else { check(false, "missing PCM skips") }
        ring.arm()
        for _ in 0..<3 { ring.appendMeterBuffer(buffer(), rawPeak: 0.25) }
        check(ring.retainedBufferCount == 2, "ring stays bounded")
        if case .clipped = ring.take() {} else { check(false, "clipped tail cannot align with complete reference") }
        ring.arm(); let borrowed = buffer(); ring.appendMeterBuffer(borrowed, rawPeak: 0.25)
        borrowed.floatChannelData![0][0] = 0
        if case .audio(let audio) = ring.take() {
            let copied = audio.takeBuffers()
            check(copied.first?.buffer.floatChannelData?[0][0] == 0.25, "borrowed tap buffer copied before reuse")
            check(audio.retainedBufferCount == 0 && ring.retainedBufferCount == 0, "one-shot drain releases outlet ownership")
        } else { check(false, "audible ring exports once") }
        ring.arm(); ring.appendMeterBuffer(buffer(), rawPeak: 0.25); ring.clear()
        check(!ring.isArmed && ring.retainedBufferCount == 0, "close immediately clears RAM")
        for (before, range, after, expected) in [
            ("", NSRange(location: 0, length: 0), "synthetic", "synthetic"),
            ("prefix suffix", NSRange(location: 7, length: 0), "prefix synthetic suffix", "synthetic "),
            ("prefix old suffix", NSRange(location: 7, length: 3), "prefix new suffix", "new")
        ] {
            check(DoubaoReferenceDifference.span(before: before, selection: range, after: after)?.text == expected,
                  "caret/selection reference difference")
        }
        for (before, range, after) in [
            ("prefix suffix", NSRange(location: 7, length: 0), "changed prefix suffix"),
            ("same", NSRange(location: 4, length: 0), "same"),
            ("😀", NSRange(location: 1, length: 0), "😀new"),
            ("same", NSRange(location: Int.max, length: 1), "same changed")
        ] {
            check(DoubaoReferenceDifference.span(before: before, selection: range, after: after) == nil,
                  "ambiguous/misaligned/no difference reference rejected")
        }
        check(DoubaoReferenceDifference.span(before: nil, selection: .init(location: 0, length: 0), after: "synthetic") == nil,
              "unreadable start snapshot fails closed")

        do {
            let doubao = try selection(), other = try selection(.voiceNative)
            var transportCounts: [[Int]] = []
            for (enabled, chosen) in [(false, doubao), (true, other), (true, doubao)] {
                let calls = DoubaoProbeCounts(), captured = packet()
                let provider = DoubaoProbeAudio(result: .audio(captured), counts: calls)
                let runtime = DoubaoLearningRuntime(audio: provider, recognize: { value, _ in
                    calls.increment("infer"); value.clear(); return .init(text: localText, confidence: score)
                }, receive: { _, _ in calls.increment("receive") })
                runtime.authorize(isDoubao: chosen.mode == .doubao, learningEnabled: enabled)
                let transport = DoubaoProbeTransport(), backend = DoubaoSpeechBackend(transport: transport)
                let frozen = snapshot(doubao)
                runtime.begin(snapshot(chosen))
                var kinds: [SpeechInputEvent.Kind] = []
                try await backend.start(snapshot: frozen) { kinds.append($0.kind) }
                await backend.finish()
                runtime.finish(reference: { calls.increment("reference"); return reference() })
                await runtime.waitForWork()
                let wanted = enabled && chosen.mode == .doubao ? 1 : 0
                check(calls.value("take") == wanted && calls.value("infer") == wanted && calls.value("reference") == wanted,
                      "exactly one eligible outlet/reference/local call, zero when off/other route")
                check(kinds == [.ready, .stopped], "sidecar does not alter Doubao event chain")
                transportCounts.append([await transport.acquires, await transport.releases])
                check(runtime.retainedAudioBuffers == 0, "runtime releases synthetic audio after use")
                runtime.cancel()
            }
            check(transportCounts == [[1, 1], [1, 1], [1, 1]], "original shortcut acquire/release unchanged")
            for (result, wanted) in [(DoubaoLearningAudioResult.missing, DoubaoLearningDecision.missingAudio),
                                     (.silent, .silent), (.clipped, .clipped)] {
                let calls = DoubaoProbeCounts()
                let runtime = DoubaoLearningRuntime(audio: DoubaoProbeAudio(result: result, counts: calls),
                    recognize: { _, _ in calls.increment("infer"); return nil }, receive: { _, _ in calls.increment("receive") })
                runtime.authorize(isDoubao: true, learningEnabled: true); runtime.begin(snapshot(doubao))
                runtime.finish(reference: { calls.increment("reference"); return reference() }); await runtime.waitForWork()
                check(runtime.decision == wanted && calls.value("infer") == 0 && calls.value("reference") == 0,
                      "missing/silent/clipped skips without reference/inference/retry")
            }
            for readable in [false, true] {
                let calls = DoubaoProbeCounts(), audio = packet()
                let runtime = DoubaoLearningRuntime(audio: DoubaoProbeAudio(result: .audio(audio), counts: calls),
                    recognize: { _, _ in calls.increment("infer"); return .init(text: localText, confidence: nil) },
                    receive: { _, _ in calls.increment("receive") })
                runtime.authorize(isDoubao: true, learningEnabled: true); runtime.begin(snapshot(doubao))
                runtime.finish(reference: { calls.increment("reference"); return readable ? reference() : nil })
                await runtime.waitForWork()
                check(calls.value("infer") == (readable ? 1 : 0) && calls.value("receive") == (readable ? 1 : 0),
                      "AX unreadable fails closed; unknown confidence can reach local recheck")
                check(audio.retainedBufferCount == 0, "skip also releases RAM")
            }
            failures += await cancellationChecks(selection: doubao)
            failures += await workerChecks(selection: doubao)
            failures += await learningChecks()
        } catch { check(false, "synthetic Doubao setup failed") }
        let probePath = FileManager.default.currentDirectoryPath + "/.cache/doubao-private-read-probe"
        let writer = open(probePath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        check(writer >= 0, "synthetic private-read decoy created")
        if writer >= 0 { var value: UInt8 = 1; _ = write(writer, &value, 1); close(writer) }
        let reader = open(probePath, O_RDONLY)
        check(reader < 0 && (errno == EPERM || errno == EACCES), "sandbox denies synthetic provider-private read")
        if reader >= 0 { close(reader) }
        for decision in [DoubaoLearningDecision.disabled, .silent, .unreadable, .compared, .unknownConfidence] {
            check(DoubaoLearningRuntime.isSafeLog("event=doubao_learning decision=\(decision.rawValue) outlets=1 requests=1"), "log whitelist")
        }
        check(!DoubaoLearningRuntime.isSafeLog("event=doubao_learning decision=compared outlets=1 requests=1 text=synthetic"),
              "text/free keys refused")
        print("event=doubao_learning_checks failures=\(failures.count) synthetic=1 extra_capture=0 cloud_requests=0")
        return failures
    }

    private static func cancellationChecks(selection: VoiceInputSelection) async -> [String] {
        var failures: [String] = []
        for changeRoute in [false, true] {
            let calls = DoubaoProbeCounts(), barrier = DoubaoProbeBarrier()
            var logs: [String] = []
            let runtime = DoubaoLearningRuntime(audio: DoubaoProbeAudio(result: .audio(packet()), counts: calls),
                recognize: { _, _ in calls.increment("infer"); return .init(text: localText, confidence: score) },
                trace: { logs.append($0) }, receive: { _, _ in calls.increment("receive") })
            runtime.authorize(isDoubao: true, learningEnabled: true); runtime.begin(snapshot(selection))
            runtime.finish(reference: { await barrier.wait(); return reference() })
            for _ in 0..<100 {
                if await barrier.entered { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            if !(await barrier.entered) { failures.append("doubao learning: reference barrier did not start") }
            runtime.authorize(isDoubao: !changeRoute, learningEnabled: changeRoute)
            if runtime.retainedAudioBuffers != 0 { failures.append("doubao learning: withdrawal must release pending RAM") }
            await barrier.resume()
            await runtime.waitForCancellation()
            // Let the resumed, cancelled reference unwind; its generation cannot become eligible again.
            for _ in 0..<5 { await Task.yield() }
            if calls.value("infer") != 0 || calls.value("receive") != 0 {
                failures.append("doubao learning: late reference must not recognize or learn")
            }
            if !logs.allSatisfy(DoubaoLearningRuntime.isSafeLog) { failures.append("doubao learning: runtime log whitelist") }
        }
        return failures
    }

    private static func workerChecks(selection: VoiceInputSelection) async -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) { if !ok { failures.append("doubao offline: " + label) } }
        let profile = BetaProfile(id: "qwen17-rolling", label: "Synthetic", summary: "Synthetic", backend: "qwen",
            host: nil, correction: "none", streaming_kind: "rolling", max_seconds: 30, initial_seconds: 0.3,
            interval_seconds: 0.5, experimental: false, required_files: [], languages: ["zh"])
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cache/maintenance04-build/doubao-ram-checks-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
            for proof in [score, nil] {
                let worker = DoubaoProbeClient(score: proof)
                let pool = LocalWorkerPool(factory: { _, _ in worker })
                let recognizer = DoubaoOfflineRecognizer(pool: pool, loadProfiles: { [profile] })
                let audio = packet()
                let result = try await recognizer.recognize(audio, selection: selection)
                check(result?.confidence == proof && result?.text == localText, "real converter/segment final preserves evidence or unknown")
                check(await worker.requests == 1, "one existing final local worker request")
                let lifecycle = (await worker.priority, await worker.starts, await worker.stops)
                check(lifecycle == (1, 1, 0),
                      "utility preparation, single start, worker retained warm")
                check(audio.retainedBufferCount == 0, "offline conversion releases raw RAM")
                await pool.shutdownAll()
            }
            let busyWorker = DoubaoProbeClient(score: score), busyPool = LocalWorkerPool(factory: { _, _ in busyWorker })
            let foreground = UUID()
            _ = try await busyPool.acquire(id: foreground, profileID: profile.id, language: "zh")
            let refused = DoubaoOfflineRecognizer(pool: busyPool, loadProfiles: { [profile] })
            do { _ = try await refused.recognize(packet(), selection: selection); check(false, "busy foreground must refuse background") }
            catch {
                let state = (await busyWorker.requests, await busyWorker.priority, await busyWorker.stops)
                check(state == (0, 0, 0), "busy background does not alter foreground lease")
            }
            await busyPool.release(id: foreground, discard: true)
            let heldWorker = DoubaoProbeClient(score: score, held: true)
            let heldPool = LocalWorkerPool(factory: { _, _ in heldWorker })
            let held = DoubaoOfflineRecognizer(pool: heldPool, loadProfiles: { [profile] })
            let audio = packet()
            let work = Task { try await held.recognize(audio, selection: selection) }
            for _ in 0..<100 {
                if await heldWorker.requests > 0 { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            check(await heldWorker.requests == 1, "offline request reached cancellation barrier")
            await held.cancel()
            do { _ = try await work.value; check(false, "late local result must cancel") } catch {}
            let stops = await heldWorker.stops
            check(audio.retainedBufferCount == 0 && stops > 0, "preemption frees RAM/worker")
            let next = UUID()
            _ = try await heldPool.acquire(id: next, profileID: profile.id, language: "zh")
            await heldPool.release(id: next, discard: true)
            let after = try FileManager.default.contentsOfDirectory(atPath: root.path)
            check(before == after && after.isEmpty, "audio file list remains empty before/after RAM inference")
        } catch { failures.append("doubao offline: synthetic worker execution failed") }
        print("event=doubao_offline_probe synthetic=1 capture_starts=0 cloud_requests=0 local_requests=1 audio_files=0")
        return failures
    }

    private static func learningChecks() async -> [String] {
        var failures: [String] = [], saved = 0
        let learning = EnhancementLearningRuntime(terms: { [] }, now: { date },
            persist: { _, permit, epoch in permit.withAuthorization(epoch) { saved += 1; return true } ?? false })
        learning.authorize(onlineEnabled: false, learningEnabled: true, doubaoEnabled: true)
        if learning.enhancementReceiver() != nil || learning.doubaoEnhancementReceiver() == nil {
            failures.append("doubao learning: source authorization must not require or enable online")
        }
        for _ in 0..<3 {
            let receipt = reference()
            let comparison = EnhancementComparison(roundID: UUID(), localText: localText, referenceText: referenceText,
                localAt: date, referenceAt: date, localConfidence: score.probability, source: .doubao)
            learning.doubaoEnhancementReceiver()?(comparison)
            learning.dictationKept(.init(rawText: referenceText, text: referenceText, hits: [], routeID: "doubao"), baseline: receipt.baseline)
            learning.sessionBegan(revisit: .init(baselineID: receipt.baseline.id, document: referenceText, editingGeneration: 0))
        }
        await learning.waitForPendingWrites()
        if saved != 1 { failures.append("doubao learning: cross-round pipeline must promote without cloud permission") }
        let old = learning.doubaoEnhancementReceiver()
        learning.authorize(onlineEnabled: false, learningEnabled: false, doubaoEnabled: true)
        old?(.init(roundID: UUID(), localText: localText, referenceText: referenceText,
            localAt: date, referenceAt: date, localConfidence: score.probability, source: .doubao))
        if learning.hasObservation || learning.candidateCount != 0 { failures.append("doubao learning: closing revokes late learning") }
        return failures
    }
}
