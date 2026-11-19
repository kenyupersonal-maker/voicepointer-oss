import Foundation

extension LocalSpeechBackend: SpeechCapturedDurationProviding {
    public var capturedDurationSeconds: Double {
        if terminalEmitted { return finalAudioDurationSeconds }
        guard let pipeline else { return .nan }
        return pipeline.snapshotBuffers().reduce(0) { $0 + Double($1.buffer.frameLength) / $1.buffer.format.sampleRate }
    }
}
import AVFoundation

/// Local microphone speech adapter bridging SpeechInputBackend to the
/// LocalWorkerPool / SegmentedInferenceClient / BetaSession / LiveAudioPipeline
/// stack. Single-use per session: `start` may be called exactly once.
@MainActor
internal final class LocalSpeechBackend: SpeechInputBackend, SpeechCaptureCancellationInvalidating, SpeechCaptureActivityProviding {
    var hasAcceptedCaptureAudio: Bool { !(pipeline?.snapshotBuffers().isEmpty ?? true) }

    private enum Phase {
        case idle
        case starting
        case listening
        case finalizing
        case cleaning
        case done
    }

    private let pool: LocalWorkerPool

    // Injected boundaries. Defaults keep production behavior unchanged;
    // tests substitute fakes so no real microphone or permission prompt is
    // ever touched.
    private let loadProfiles: @MainActor () throws -> [BetaProfile]
    private let requestPermission: @MainActor () async -> Bool
    private let makeCapture: @MainActor () -> any LocalSpeechCapture

    private var phase: Phase = .idle
    private var startUsed = false

    // Lease identity. Never reused across sessions.
    private var leaseID: UUID?

    // Snapshot and callback are captured before any await in start.
    private var snapshot: VoiceInputSnapshot?
    private var callback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?

    private var startedAt: TimeInterval = 0
    private var nextSequence: UInt64 = 0
    private var terminalEmitted = false
    private var finalAudioDurationSeconds = Double.nan
    private var stopRequested = false
    private var startInFlight = false

    // Waiters blocked while start is in flight (cancel/finish during starting).
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    // Owned resources while listening.
    private var session: BetaSession?
    private var pipeline: (any LocalSpeechCapture)?
    private var captureStopTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var preparationTask: Task<BetaSession, Error>?

    // What is noted about this dictation's hot words and timing: counts and numbers only, never text.
    private var hotwordsInUse: [String] = []
    private var echoNoted: Set<String> = []
    private var partialCount = 0
    private var firstPartialComputeMs: Double?

    // Parameters captured from the profile during start.
    private var intervalSeconds: Double = 0.5
    private var initialSeconds: Double = 0.3
    private var streamingKind: String = "rolling"

    // Fixed at 300s regardless of profile.max_seconds: the 30s segment client
    // already respects the profile's per-segment limit; clipping the host at
    // profile.max_seconds would silently truncate 30/60s profiles.
    private var maxSeconds: Int = 300

    init(
        pool: LocalWorkerPool,
        loadProfiles: @escaping @MainActor () throws -> [BetaProfile] = { try BetaCatalog.load() },
        requestPermission: @escaping @MainActor () async -> Bool = {
            await LocalSpeechBackend.requestMicrophonePermission()
        },
        makeCapture: @escaping @MainActor () -> any LocalSpeechCapture = {
            LiveAudioPipeline(
                capacity: 32,
                appleEnabled: false,
                captureByteLimit: 256 * 1024 * 1024,
                captureDurationSeconds: 300,
                gracefulDurationLimit: true
            )
        }
    ) {
        self.pool = pool
        self.loadProfiles = loadProfiles
        self.requestPermission = requestPermission
        self.makeCapture = makeCapture
    }

    // MARK: - Permission

    /// Real microphone permission check. Only requests when notDetermined
    /// (user gesture); other denial states return false. Tests inject a fake
    /// so this is never called automatically.
    internal static func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - SpeechInputBackend

    var isQuiescent: Bool {
        // Quiescent only when nothing is owned or in flight; `cleaning` keeps
        // us non-quiescent until pool release completes.
        phase == .idle || phase == .done
    }

    var capabilities: SpeechInputCapabilities {
        // Partial text is delivered for streaming/rolling kinds; offline profiles
        // only produce a final result.
        let supportsPartial = streamingKind != "offline"
        return SpeechInputCapabilities(
            deliveryKind: .transcriptStream,
            supportsPartialText: supportsPartial,
            supportsHints: snapshot.map { BetaRecognitionContext.supports(profileID: $0.selection.routeID) } ?? false
        )
    }

    func start(snapshot: VoiceInputSnapshot,
               onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void) async throws {
        guard !startUsed else {
            throw BetaWorkerTransportError(description: "LOCAL_ALREADY_STARTED")
        }
        startUsed = true

        // Validate mode/profile before touching state.
        guard snapshot.selection.mode == .voiceNative else {
            throw BetaWorkerTransportError(description: "LOCAL_UNSUPPORTED_MODE")
        }
        let routeID = snapshot.selection.routeID
        let language = snapshot.selection.language

        let profiles: [BetaProfile]
        do {
            profiles = try loadProfiles()
        } catch {
            throw BetaWorkerTransportError(description: "LOCAL_CATALOG_UNAVAILABLE")
        }
        guard let profile = profiles.first(where: { $0.id == routeID }) else {
            throw BetaWorkerTransportError(description: "LOCAL_UNKNOWN_ROUTE")
        }
        guard !profile.isApple else {
            throw BetaWorkerTransportError(description: "LOCAL_APPLE_ROUTE_REFUSED")
        }
        guard profile.missingFiles.isEmpty else {
            throw BetaWorkerTransportError(description: "LOCAL_MODEL_FILES_MISSING")
        }
        guard profile.languages.contains(language) else {
            throw BetaWorkerTransportError(description: "LOCAL_LANGUAGE_UNSUPPORTED")
        }

        // Capture state before any await so cancel/finish can find it.
        let lease = UUID()
        leaseID = lease
        self.snapshot = snapshot
        callback = onEvent
        phase = .starting
        startInFlight = true
        intervalSeconds = profile.interval_seconds
        initialSeconds = profile.initial_seconds
        streamingKind = profile.streaming_kind
        maxSeconds = 300

        do {
            try Task.checkCancellation()

            let granted = await requestPermission()
            try Task.checkCancellation()
            if stopRequested { throw CancellationError() }
            guard granted else {
                throw BetaWorkerTransportError(description: "LOCAL_MIC_PERMISSION_DENIED")
            }

            // Start capture immediately so first words are never lost while
            // the model warms up in the background.
            let pipeline = makeCapture()
            self.pipeline = pipeline
            pipeline.onDurationLimitReached = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.phase == .listening, !self.stopRequested else { return }
                    await self.finish()
                }
            }
            pipeline.onCaptureFailure = { [weak self] code in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.phase == .listening, !self.stopRequested else { return }
                    self.preparationTask?.cancel()
                    self.failAndCleanup(code: SpeechFailureDiagnostics.localCode(code))
                }
            }
            try await pipeline.start(streamingToApple: false)
            try Task.checkCancellation()
            if stopRequested { throw CancellationError() }
            startedAt = ProcessInfo.processInfo.systemUptime

            let context = Self.recognitionContext(plan: snapshot.localContext, hotwords: snapshot.localHotwords, profileID: routeID)
            hotwordsInUse = context == nil ? [] : snapshot.localContext?.terms ?? RecognitionHotwords.clean(snapshot.localHotwords)
            recentInUse = context == nil ? 0 : snapshot.localContext?.recent.count ?? 0
            contextBytesInUse = context?.text.utf8.count ?? 0
            preparationTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.prepareSession(
                    lease: lease,
                    profileID: routeID,
                    language: language,
                    sessionID: snapshot.sessionID.uuidString,
                    context: context
                )
            }

            phase = .listening
            startInFlight = false
            resumeStartWaiters()

            emit(.ready)

            if streamingKind != "offline" {
                pollTask = Task { [weak self] in
                    guard let self else { return }
                    await self.runPolling()
                }
            }

            let limit = maxSeconds
            timerTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(limit) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.finish()
            }
        } catch {
            let wasCancellation = error is CancellationError
            await startCleanup(discard: true)
            if !stopRequested, !Task.isCancelled, !terminalEmitted {
                emit(.failed, errorCode: SpeechFailureDiagnostics.localCode(for: error))
            }
            if wasCancellation || Task.isCancelled {
                throw CancellationError()
            }
            if let transport = error as? BetaWorkerTransportError {
                throw transport
            }
            throw BetaWorkerTransportError(description: SpeechFailureDiagnostics.localCode(for: error))
        }
    }

    // MARK: - Hot words

    private var recentInUse = 0
    private var contextBytesInUse = 0

    static func recognitionContext(plan: RecognitionContextPlan?, hotwords: [String], profileID: String) -> BetaRecognitionContext? {
        guard let plan else { return recognitionContext(hotwords: hotwords, profileID: profileID) }
        guard BetaRecognitionContext.supports(profileID: profileID) else {
            RuntimeTrace.record("local context skipped reason=routeUnsupported")
            return nil
        }
        guard let text = plan.localText, let context = try? BetaRecognitionContext(text: text) else {
            RuntimeTrace.record("local context skipped reason=nothingUsable")
            return nil
        }
        RuntimeTrace.record("local context terms=\(plan.terms.count) recent=\(plan.recent.count) bytes=\(text.utf8.count)")
        if !plan.recent.isEmpty { RuntimeTrace.record("recognition memory used recent=\(plan.recent.count) bytes=\(text.utf8.count)") }
        return context
    }

    /// The personal lexicon's hot words as the one line of context a local Qwen worker takes. Nil when there
    /// are none or the route cannot use them; a list that turns out unusable never stops a dictation, the
    /// dictation just runs without it. The trace records how many words and bytes, never the words.
    static func recognitionContext(hotwords: [String], profileID: String) -> BetaRecognitionContext? {
        guard !hotwords.isEmpty else { return nil }
        guard BetaRecognitionContext.supports(profileID: profileID) else {
            RuntimeTrace.record("local hotwords skipped reason=routeUnsupported")
            return nil
        }
        guard let line = RecognitionHotwords.line(for: hotwords),
              let context = try? BetaRecognitionContext(text: line) else {
            RuntimeTrace.record("local hotwords skipped reason=nothingUsable")
            return nil
        }
        RuntimeTrace.record(
            "local hotwords terms=\(RecognitionHotwords.clean(hotwords).count) bytes=\(line.utf8.count)"
        )
        return context
    }

    /// Observation only: a transcript made of nothing but hot words may be the recognizer echoing its hint (over
    /// silence, say), or a dictation that really was one hot word. Noted once per kind per dictation, as a
    /// count; nothing is dropped or changed.
    private func noteHotwordEcho(kind: String, text: String) {
        guard !hotwordsInUse.isEmpty, !echoNoted.contains(kind) else { return }
        let echoed = RecognitionHotwords.echoedWordCount(in: text, words: hotwordsInUse)
        guard echoed > 0 else { return }
        echoNoted.insert(kind)
        RuntimeTrace.record("local hotwords echo kind=\(kind) words=\(echoed) utf16=\(text.utf16.count)")
    }

    /// One line of numbers per dictation, so dictations with and without hot words can be compared.
    private func noteSessionTiming(final event: BetaEvent) {
        let first = firstPartialComputeMs.map { String(Int($0.rounded())) } ?? "none"
        RuntimeTrace.record(
            "local timing hotwords=\(hotwordsInUse.count) recent=\(recentInUse) ctxBytes=\(contextBytesInUse) partials=\(partialCount) firstComputeMs=\(first) " +
            "finalAudioMs=\(Int(event.audio_ms.rounded())) finalComputeMs=\(Int(event.compute_ms.rounded()))"
        )
    }

    // MARK: - Warmup

    /// Loads the worker and builds the session while capture is already
    /// running. Errors are surfaced via a separately scheduled failure task;
    /// this task itself never awaits backend cleanup (no self-await).
    private func prepareSession(
        lease: UUID, profileID: String, language: String, sessionID: String, context: BetaRecognitionContext?
    ) async throws -> BetaSession {
        do {
            let client = try await pool.acquire(id: lease, profileID: profileID, language: language)
            try Task.checkCancellation()
            guard !stopRequested, leaseID == lease else { throw CancellationError() }

            let segmented = try SegmentedInferenceClient(base: client, segmentSeconds: 30, context: context)
            let session = BetaSession(
                client: segmented,
                maxSeconds: 300,
                id: sessionID,
                startedAt: startedAt
            )

            session.onEvent = { [weak self] event in
                guard let self else { return }
                guard self.phase == .listening, !self.stopRequested else { return }
                if !event.final {
                    self.noteHotwordEcho(kind: "partial", text: event.text)
                    self.partialCount += 1
                    if self.firstPartialComputeMs == nil { self.firstPartialComputeMs = event.compute_ms }
                    self.emit(.partial, text: event.text)
                }
            }

            session.onCompletion = { [weak self] result in
                guard let self else { return }
                guard self.phase == .listening, !self.stopRequested else { return }
                if case .failure = result {
                    self.failAndCleanup(code: "LOCAL_INFERENCE_FAILED")
                }
            }

            if leaseID == lease, phase == .listening || phase == .finalizing {
                self.session = session
            }
            return session
        } catch {
            if phase == .listening, !stopRequested, !(error is CancellationError) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.failAndCleanup(code: "LOCAL_INFERENCE_FAILED")
                }
            }
            throw error
        }
    }

    // MARK: - Polling

    private func runPolling() async {
        // The model may still be warming up; wait for the session before
        // offering buffers. Preparation errors are handled by the prep task.
        if let prep = preparationTask {
            _ = try? await prep.value
            guard !Task.isCancelled else { return }
        }
        let initial = max(initialSeconds, 0.1)
        try? await Task.sleep(nanoseconds: UInt64(initial * 1_000_000_000))
        while !Task.isCancelled {
            // self is non-optional here: runPolling is a method invoked with a
            // strong self from the polling task.
            guard phase == .listening, !stopRequested, let session = self.session, let pipeline = self.pipeline else {
                // Backend moved on; stop polling.
                return
            }
            let buffers = pipeline.snapshotBuffers()
            // The physical startup gate holds all PCM until it hears audio.
            // Offering an empty snapshot would still start an inference job.
            if !buffers.isEmpty { session.offer(buffers, final: false) }
            let interval = max(intervalSeconds, 0.2)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    // MARK: - Finish / Cancel

    func finish() async {
        if startInFlight {
            stopRequested = true
            callback = nil
            requestCaptureStop()
            await waitForStartCleanup()
            return
        }
        switch phase {
        case .idle, .done:
            return
        case .starting:
            stopRequested = true
            callback = nil
            await waitForStartCleanup()
            return
        case .finalizing, .cleaning:
            // Share the in-flight finishing task.
            if let task = finishTask {
                await task.value
            }
            return
        case .listening:
            break
        }

        // Cancel the timer (and poll) from the caller BEFORE spawning the
        // finalization task. Cancelling the caller task is fine: the new Task
        // inherits priority, not cancellation.
        timerTask?.cancel()
        timerTask = nil
        pollTask?.cancel()
        pollTask = nil
        requestCaptureStop()

        // Synchronously claim finalization before creating the task so a
        // concurrent finish/cancel cannot spawn a second finalizer or a
        // second waitForFinal continuation.
        phase = .finalizing
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finalize(dueToCancel: false)
        }
        finishTask = task
        await task.value
    }

    private func finalize(dueToCancel cancelled: Bool) async {
        // Only the finalizing phase is accepted; the synchronous claim in
        // finish/cancel/failAndCleanup guarantees a single cleanup run.
        guard phase == .finalizing else { return }

        let pipeline = self.pipeline
        await stopCapture()

        // The model may still be warming; observe the preparation result so
        // the lease is never released while an acquire is still pending.
        if let prep = preparationTask {
            _ = try? await prep.value
            preparationTask = nil
        }

        let session = self.session

        if let session {
            if cancelled || stopRequested {
                session.cancel()
                // Cancelled path: session.cancel first, then cleanup releases
                // the lease (discard) so it can never leak.
                await cleanup(discard: true)
            } else {
                // Observe capture failure before the final offer: a capture
                // failure can be enqueued after pipeline.stop (e.g. the 300s
                // timer racing the buffer limit). Report the real failure
                // instead of offering partial buffers and faking a PASS.
                if pipeline?.captureFailure != nil {
                    if !terminalEmitted {
                        let code = pipeline?.captureFailure?.description ?? "LOCAL_CAPTURE_FAILED"
                        emit(.failed, errorCode: SpeechFailureDiagnostics.localCode(code))
                    }
                    await cleanup(discard: true)
                    return
                }
                let buffers = pipeline?.snapshotBuffers() ?? []
                session.offer(buffers, final: true)
                do {
                    let event = try await session.waitForFinal()
                    // Stale/cancel check after await. Final text is non-optional.
                    if !stopRequested, !terminalEmitted {
                        noteHotwordEcho(kind: "final", text: event.text)
                        noteSessionTiming(final: event)
            emit(.final, text: event.text, confidenceEvidence: event.confidenceEvidence)
                    }
                    await cleanup(discard: stopRequested)
                } catch {
                    if !stopRequested, !Task.isCancelled, !terminalEmitted {
                        emit(.failed, errorCode: "LOCAL_INFERENCE_FAILED")
                    }
                    await cleanup(discard: true)
                }
            }
        } else {
            if !cancelled, !stopRequested, !terminalEmitted {
                emit(.failed, errorCode: "LOCAL_INFERENCE_FAILED")
            }
            await cleanup(discard: true)
        }
    }

    func invalidateCaptureForCancellation() {
        // Invalidate callback first; never wait before invalidating.
        callback = nil
        stopRequested = true

        pollTask?.cancel()
        pollTask = nil
        timerTask?.cancel()
        timerTask = nil
        preparationTask?.cancel()

        // Invalidate events now; release the physical input on its background control queue.
        requestCaptureStop()
        session?.cancel()
    }

    func cancel() async {
        invalidateCaptureForCancellation()

        if startInFlight {
            await waitForStartCleanup()
            return
        }
        switch phase {
        case .idle, .done:
            return
        case .starting:
            // Start owns cleanup while in flight; wait for its waiters even if
            // the phase has already moved into cleaning.
            await waitForStartCleanup()
        case .listening:
            timerTask?.cancel()
            timerTask = nil
            // Synchronous claim before spawning the finalizer.
            phase = .finalizing
            let task = Task { [weak self] in
                guard let self else { return }
                await self.finalize(dueToCancel: true)
            }
            finishTask = task
            await task.value
        case .finalizing, .cleaning:
            if let task = finishTask {
                await task.value
            }
        }
    }

    // MARK: - Cleanup

    private func requestCaptureStop() {
        guard captureStopTask == nil, let pipeline else { return }
        captureStopTask = Task { @MainActor in await pipeline.stop() }
    }

    private func stopCapture() async {
        requestCaptureStop()
        await captureStopTask?.value
    }

    /// Cleanup for the start path: releases our lease, clears owned resources,
    /// resumes start waiters. Idempotent per lease. Never awaits self-owned
    /// finish tasks (no self-await deadlock) and never calls base.shutdown;
    /// only pool release. The warmed worker intentionally stays alive.
    private func startCleanup(discard: Bool) async {
        guard let lease = leaseID else {
            await stopCapture()
            phase = .done
            captureStopTask = nil
            startInFlight = false
            resumeStartWaiters()
            return
        }
        if phase != .done { phase = .cleaning }
        await stopCapture()
        session?.cancel()
        session?.onEvent = nil
        session?.onCompletion = nil
        session?.cancel()
        session = nil
        pipeline?.onDurationLimitReached = nil
        pipeline?.onCaptureFailure = nil
        pipeline = nil
        pollTask?.cancel(); pollTask = nil
        timerTask?.cancel(); timerTask = nil
        preparationTask?.cancel()
        if let prep = preparationTask {
            _ = try? await prep.value
            preparationTask = nil
        }
        await pool.release(id: lease, discard: discard)
        leaseID = nil
        finishTask = nil
        phase = .done
        captureStopTask = nil
        startInFlight = false
        resumeStartWaiters()
    }

    /// Cleanup from finalize: the single place that releases the lease after a
    /// final/failed/cancelled outcome.
    ///
    /// Reentrancy note: `cancel` may arrive while `pool.release` is awaited.
    /// The lease is claimed (nil'd) before the await, so it can never be
    /// released twice, and a cancel after a discard:false release never
    /// shuts down the already-completed warmed worker — it simply stays warm
    /// with the callback disabled. No code path calls base.shutdown.
    private func cleanup(discard: Bool) async {
        guard phase == .finalizing else { return }
        phase = .cleaning
        let lease = leaseID
        leaseID = nil
        await stopCapture()
        pollTask?.cancel(); pollTask = nil
        timerTask?.cancel(); timerTask = nil
        session?.onEvent = nil
        session?.onCompletion = nil
        session?.cancel()
        session = nil
        pipeline?.onDurationLimitReached = nil
        pipeline?.onCaptureFailure = nil
        pipeline = nil
        if let prep = preparationTask {
            _ = try? await prep.value
            preparationTask = nil
        }
        if let lease {
            await pool.release(id: lease, discard: discard)
        }
        finishTask = nil
        phase = .done
        captureStopTask = nil
        startInFlight = false
        resumeStartWaiters()
    }

    private func failAndCleanup(code: String) {
        guard phase == .listening, !stopRequested, !terminalEmitted else { return }
        // Synchronous claim before spawning the finalizer.
        phase = .finalizing
        let task = Task { [weak self] in
            guard let self else { return }
            self.emit(.failed, errorCode: code)
            await self.finalize(dueToCancel: true)
        }
        finishTask = task
    }

    private func waitForStartCleanup() async {
        // Wait while start is in flight even if the phase has already moved
        // into cleaning, so callers cannot return before start's cleanup ends.
        while startInFlight {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                startWaiters.append(cont)
            }
        }
    }

    private func resumeStartWaiters() {
        let waiters = startWaiters
        startWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    // MARK: - Emission

    private func emit(_ kind: SpeechInputEvent.Kind, text: String? = nil, errorCode: String? = nil,
                      confidenceEvidence: LocalModelConfidence? = nil) {
        guard let callback, let snapshot else { return }
        switch kind {
        case .ready, .partial:
            if terminalEmitted { return }
        case .final, .failed, .stopped:
            if terminalEmitted { return }
            finalAudioDurationSeconds = capturedDurationSeconds
            terminalEmitted = true
        }
        let sequence = nextSequence
        nextSequence += 1
        var ms = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        if ms < 0 { ms = 0 }
        let event = SpeechInputEvent(
            sessionID: snapshot.sessionID,
            sequence: sequence,
            observedMilliseconds: ms,
            kind: kind,
            text: text,
            errorCode: errorCode,
            confidenceEvidence: confidenceEvidence
        )
        callback(event)
    }
}
