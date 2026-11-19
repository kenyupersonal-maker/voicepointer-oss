import Foundation
@_spi(Testing) import VoicePointerCore

/// The hybrid backend's glue ("用于增强本地识别", plan §6.2 HM-01…13): one shared capture read by two branches,
/// the selector's actions performed in order, and what the coordinator sees: one `.ready`, the local drafts, and
/// exactly one final (marked with its source) or failure, renumbered, on one monotonic time line.
///
/// Everything is scripted: the real `HybridSpeechBackend` runs with scripted branches, a scripted capture that
/// holds silent PCM made in memory, and a clock the checks move by hand. No microphone, network, worker, key or
/// Application Support is touched.
@MainActor
enum HybridChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        let checks: [(String, @MainActor () async -> [String])] = [
            ("startup order", startupOrderChecks),
            ("cloud draft takeover", cloudDraftChecks),
            ("local start failure", localStartFailureChecks),
            ("start interrupted", startInterruptedChecks),
            ("shared capture", sharedCaptureChecks),
            ("capture failure", captureFailureChecks),
            ("duration limit", durationLimitChecks),
            ("event contract", eventContractChecks),
            ("cloud absorbed", cloudAbsorbedChecks),
            ("cancel", cancelChecks),
            ("concurrent finish", concurrentFinishChecks),
            ("revoke", revokeChecks),
            ("backlog", backlogChecks),
            ("swipe-down", discardChecks),
            ("snapshots", snapshotChecks),
            ("trace privacy", tracePrivacyChecks),
            ("reentrancy", reentrancyChecks),
            ("callback invalidation", invalidationChecks),
            ("line breaks", lineBreakChecks),
            ("local own final", localOwnFinalChecks),
            ("local budget wait", localBudgetWaitChecks),
            ("timer", timerChecks),
            ("session filter", sessionFilterChecks),
            ("late inputs", lateInputChecks),
            ("cloud start failure", cloudStartFailureChecks),
            ("cloud drain", drainChecks),
            ("local alone after the cloud", localAloneChecks),
            ("start windows", startWindowChecks),
            ("quiescence", quiescenceChecks),
            ("pure helpers", helperChecks),
            ("upload decision", uploadDecisionChecks),
        ]
        for (name, check) in checks {
            for failure in await check() {
                failures.append("hybrid glue \(name): \(failure)")
            }
            if !(await until { HybridTestingFactory.cloudDrainOutstanding == 0 }) {
                failures.append("hybrid glue \(name): a cloud branch never finished draining")
            }
        }
        if HybridRig.totalGateRejections != 0 {
            failures.append("hybrid glue: the event gate refused \(HybridRig.totalGateRejections) event(s)")
        }
        if HybridRig.rigsWithSecondTerminal != 0 {
            failures.append("hybrid glue: a dictation reported a second terminal event")
        }
        if stuckCalls != 0 {
            failures.append("hybrid glue: \(stuckCalls) backend call(s) never returned")
        }
        if HybridRig.stoppedEvents != 0 {
            failures.append("hybrid glue: a .stopped event reached the coordinator")
        }
        failures += macOnlyChecks()
        return failures
    }

    // MARK: - Startup (contract §2.2 point 10)

    private static func cloudDraftChecks() async -> [String] {
        var f = Failures()
        guard let rig = f.rig(preferCloudDrafts: true), await rig.start(), let cloud = rig.cloud else { return ["draft fixture"] }
        let trace = await TraceCapture.run {
            rig.local.emitPartial("local first")
            cloud.emitReady()
            cloud.emitPartial("cloud first")
            rig.local.emitPartial("local latest")
            f.expect(rig.events.filter { $0.kind == .partial }.map(\.text) == ["local first", "cloud first"], "cloud owns live draft")
            f.expect(rig.events.last?.transcriptSource == .cloudEnhancement, "cloud draft projection source")
            cloud.emitFailure("ALI_NETWORK_FAILED")
            f.expect(rig.events.last?.text == "local latest" && rig.events.last?.transcriptSource == .local, "drop restores latest local")
            rig.local.emitPartial("local continuing")
            f.expect(rig.events.last?.text == "local continuing", "local continues after drop")
            await rig.cancelAndSettle()
        }
        f.expect(trace.contains("hybrid draft source=cloud") && trace.contains("backToLocal=1"), "draft transitions numeric trace")
        f.expect(!trace.contains("cloud first") && !trace.contains("local latest"), "draft text absent from trace")
        if let finalRig = f.rig(preferCloudDrafts: true), await finalRig.start(), let finalCloud = finalRig.cloud {
            finalCloud.emitReady()
            finalCloud.emitPartial("same final")
            finalRig.local.finishStyle = .final("different local")
            finalCloud.finishStyle = .final("same final")
            let finalTrace = await TraceCapture.run { await finalRig.finishNow(); await settle() }
            f.expect(finalRig.finals.last?.text == "same final", "final selector unchanged")
            f.expect(finalTrace.contains("draftToFinal=0"), "final matches displayed draft bucket")
        }
        return f.all
    }

    private static func startupOrderChecks() async -> [String] {
        var f = Failures()
        guard let rig = f.rig() else { return f.all }
        f.expect(rig.backend.isQuiescent, "a backend that never started is quiet")
        f.expect(rig.session.sourceMakes == 0 && !rig.session.hubExists && rig.permission.calls == 0,
                 "nothing is built or asked before the start")
        f.expect(rig.backend.capabilities == SpeechInputCapabilities(
            deliveryKind: .transcriptStream, supportsPartialText: true, supportsHints: false),
                 "before the start the capabilities are the local backend's pre-start ones")
        let started = await rig.start()
        f.expect(started, "start succeeds")
        f.expect(rig.events.map(\.kind) == [.ready], "the local ready is forwarded before start returns")
        f.expect(rig.events.first?.transcriptSource == nil, "ready carries no transcript source")
        let expectedOrder = ["local.make", "local.start", "permission", "source.make", "source.start",
                             "cloud.make", "cloud.start"]
        f.expect(Array(rig.log.entries.prefix(expectedOrder.count)) == expectedOrder,
                 "local first (permission, then the capture), the cloud only after: \(rig.log.entries)")
        f.expect(rig.permission.calls == 1 && rig.session.permissionRequests == 1,
                 "the person is asked once for both branches (\(rig.permission.calls))")
        f.expect(rig.local.permissionAnswers == [true] && rig.cloud?.permissionAnswers == [true],
                 "both branches got the one answer")
        f.expect(rig.source.startCount == 1 && rig.session.hubPhysicalStarts == 1 && rig.session.sourceMakes == 1,
                 "one physical capture (starts \(rig.source.startCount))")
        f.expect(rig.backend.capabilities == rig.local.capabilities, "capabilities are the local branch's")
        f.expect(!rig.backend.isQuiescent, "listening is not quiet")
        f.expect(rig.session.isMonitoringBacklog, "the uplink is watched while listening")
        await rig.cancelAndSettle()
        return f.all
    }

    private static func localStartFailureChecks() async -> [String] {
        var f = Failures()
        // The self-test binary has no catalog: the local route alone fails before any prompt or microphone.
        if let rig = f.rig() {
            rig.local.startFailure = .beforePermission("LOCAL_CATALOG_UNAVAILABLE")
            let trace = await TraceCapture.run {
                let started = await rig.start()
                f.expect(!started, "start throws")
                f.expect(rig.startError as? HybridTestingError == .scripted("LOCAL_CATALOG_UNAVAILABLE"),
                         "the local error is thrown as it is")
                f.expect(rig.permission.calls == 0 && rig.session.sourceMakes == 0 && rig.source.startCount == 0,
                         "no permission prompt and no capture")
                f.expect(rig.session.cloudMakes == 0 && rig.cloud?.startCount == 0,
                         "the cloud branch was never built")
                f.expect(rig.events.isEmpty, "nothing is reported")
                f.expect(rig.backend.isQuiescent, "quiet once start has thrown")
                await rig.cancelNow()
                f.expect(rig.events.isEmpty && rig.backend.isQuiescent, "the coordinator's cancel afterwards is harmless")
            }
            f.expect(!trace.contains("hybrid cloud ready") && !trace.contains("hybrid cloud upload"),
                     "a start that never reached the cloud records no connection or upload")
        }
        // Permission denied: the local backend reports its start failure, then throws.
        if let rig = f.rig() {
            rig.permission.answer = false
            let started = await rig.start()
            f.expect(!started && rig.startError as? HybridTestingError == .scripted("LOCAL_MIC_PERMISSION_DENIED"),
                     "a refused permission is the local start failure")
            f.expect(rig.events.map(\.kind) == [.failed] && rig.events.first?.errorCode == "LOCAL_START_FAILED",
                     "the local failure event is forwarded once, as on the local route")
            f.expect(rig.gateRejections == 0, "the gate accepts it")
            f.expect(rig.session.sourceMakes == 0 && rig.session.cloudMakes == 0, "no capture, no cloud")
            f.expect(rig.backend.isQuiescent, "quiet")
        }
        // The local start fails after it opened the capture: the hybrid stops the microphone itself.
        if let rig = f.rig() {
            rig.local.startFailure = .afterCapture("LOCAL_WORKER_REFUSED")
            let started = await rig.start()
            f.expect(!started && rig.startError as? HybridTestingError == .scripted("LOCAL_WORKER_REFUSED"),
                     "the late local error is thrown as it is")
            f.expect(rig.source.startCount == 1 && rig.source.stopCount >= 1 && rig.session.hubIsStopped,
                     "the physical capture is stopped")
            f.expect(rig.session.cloudMakes == 0, "the cloud branch was never built")
            f.expect(rig.events.map(\.kind) == [.failed], "one failure event")
            f.expect(rig.backend.isQuiescent, "quiet")
        }
        // The same without a failure event: only the hybrid's own clean-up can stop the microphone.
        if let rig = f.rig() {
            rig.local.startFailure = .afterCaptureSilently("LOCAL_GAVE_UP")
            let started = await rig.start()
            f.expect(!started && rig.startError as? HybridTestingError == .scripted("LOCAL_GAVE_UP"),
                     "a silent local start failure is thrown as it is")
            f.expect(rig.events.isEmpty, "nothing is reported")
            f.expect(rig.source.startCount == 1 && rig.source.stopCount >= 1 && rig.session.hubIsStopped,
                     "the microphone the local branch opened is stopped")
            f.expect(rig.session.phase == .cancelled && rig.local.cancelCount == 1,
                     "the dictation is over and the local branch is told")
            f.expect(rig.session.cloudMakes == 0 && rig.backend.isQuiescent, "no cloud; quiet")
        }
        return f.all
    }

    private static func startInterruptedChecks() async -> [String] {
        var f = Failures()
        for viaCancel in [true, false] {
            let label = viaCancel ? "cancel" : "finish"
            guard let rig = f.rig() else { continue }
            rig.permission.holds = true
            let start = Task { @MainActor in await rig.start() }
            await HybridChecks.settle()
            f.expect(rig.permission.isWaiting, "\(label): the permission is being asked")
            f.expect(!rig.backend.isQuiescent, "\(label): a start in flight is not quiet")
            var stopped = false
            let stop = Task { @MainActor in
                if viaCancel { await rig.backend.cancel() } else { await rig.backend.finish() }
                stopped = true
            }
            await HybridChecks.settle()
            f.expect(!stopped, "\(label): waits for the start to give up, like the local backend")
            rig.permission.release(true)
            let started = await HybridChecks.value(of: start, or: false)
            await HybridChecks.bounded { await stop.value }
            f.expect(!started && rig.startError is CancellationError, "\(label): the start ends cancelled")
            f.expect(rig.events.isEmpty, "\(label): nothing is reported")
            f.expect(rig.session.sourceMakes == 0 && rig.session.cloudMakes == 0, "\(label): no capture, no cloud")
            f.expect(rig.backend.isQuiescent, "\(label): quiet")
            await rig.finishNow()
            f.expect(rig.events.isEmpty, "\(label): a later finish reports nothing")
        }
        return f.all
    }

    // MARK: - HM-01…04: one capture, two readers

    private static func sharedCaptureChecks() async -> [String] {
        var f = Failures()
        guard let rig = f.rig(), await rig.start(), let cloud = rig.cloud else { return f.all + ["no rig"] }
        for _ in 0..<3 { rig.source.appendBuffer(frames: 1024, sampleRate: 48_000) }
        let local = rig.local.snapshotIdentities()
        f.expect(local.count == 3, "three buffers reach the local view (\(local.count))")
        f.expect(local == cloud.snapshotIdentities() && local == rig.session.hubSnapshotIdentities(),
                 "both views return the same buffer objects (HM-01)")
        f.expect(rig.session.hubSampleIndex(ofBufferAt: 0) == 0 && rig.session.hubSampleIndex(ofBufferAt: 1) == 1024
                 && rig.session.hubSampleIndex(ofBufferAt: 2) == 2048 && rig.session.hubSampleIndex(ofBufferAt: 3) == nil,
                 "one sample time line")
        f.expect(rig.session.hubCapturedMilliseconds == 64, "3072 frames at 48 kHz are 64 ms (\(rig.session.hubCapturedMilliseconds))")
        f.expect(rig.source.startCount == 1, "the source starts once")

        // HM-02: a branch that stops its view only leaves; the microphone keeps running.
        await cloud.stopCapture()
        f.expect(rig.source.stopCount == 0 && rig.session.hubIsRunning, "a view's stop never stops the microphone")
        rig.source.appendBuffer(frames: 1024, sampleRate: 48_000)
        f.expect(rig.local.snapshotIdentities().count == 4 && cloud.snapshotIdentities().count == 4,
                 "a detached view still reads the snapshot")

        rig.releaseInBackground()
        await HybridChecks.settle()
        f.expect(rig.source.stopCount == 1 && rig.session.hubIsStopped, "the release stops the microphone once")
        f.expect(rig.local.finishSnapshotIdentities.count == 4, "the local branch finishes on the sealed audio")
        f.expect(!rig.source.appendBuffer(frames: 1024, sampleRate: 48_000)
                 && rig.session.hubSnapshotIdentities().count == 4 && rig.session.hubCapturedMilliseconds == 85,
                 "after the stop the snapshot no longer grows (\(rig.session.hubCapturedMilliseconds))")
        rig.local.completeFinish(final: "本地")
        cloud.completeFinish(final: "云端")
        await HybridChecks.settle()
        f.expect(rig.finals.map(\.text) == ["云端"], "decided")
        await rig.awaitRelease()
        return f.all
    }

    private static func captureFailureChecks() async -> [String] {
        var f = Failures()
        // HM-03: a capture failure reaches every attached view once.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            rig.source.failCapture("AUDIO_CAPTURE_FAILED")
            await HybridChecks.settle()
            f.expect(rig.local.captureFailures == ["AUDIO_CAPTURE_FAILED"]
                     && cloud.captureFailures == ["AUDIO_CAPTURE_FAILED"], "both branches hear the failure once")
            f.expect(rig.events.map(\.kind) == [.ready, .failed] && rig.events.last?.errorCode == "LOCAL_CAPTURE_FAILED",
                     "the local failure fails the dictation, with its own code (\(rig.events.map(\.kind)))")
            f.expect(rig.terminals.count == 1 && rig.gateRejections == 0, "one terminal, accepted")
            f.expect(cloud.cancelCount == 1 && rig.session.counters.cloudEnd == .cancelled,
                     "the cloud branch is cut loose")
            f.expect(rig.source.stopCount >= 1, "the microphone is stopped")
            await rig.cancelNow()
            f.expect(rig.backend.isQuiescent && rig.terminals.count == 1, "the coordinator's cancel is quiet")
        }
        // HM-02: a detached view does not hear it; the attached one does.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            await rig.local.stopCapture()
            rig.source.failCapture("CAPTURE_LIMIT_EXCEEDED")
            await HybridChecks.settle()
            f.expect(rig.local.captureFailures.isEmpty && cloud.captureFailures == ["CAPTURE_LIMIT_EXCEEDED"],
                     "only attached views hear a failure")
            f.expect(rig.events.map(\.kind) == [.ready], "the cloud's own failure is absorbed")
            f.expect(rig.session.counters.cloudEnd == .failed && cloud.cancelCount == 1, "and the cloud leaves")
            await rig.cancelAndSettle()
        }
        return f.all
    }

    private static func durationLimitChecks() async -> [String] {
        var f = Failures()
        // HM-04: the 300 s limit is the release; the branches' own limit callbacks are never called.
        guard let rig = f.rig(), await rig.start(), let cloud = rig.cloud else { return f.all + ["no rig"] }
        rig.source.appendAudio(milliseconds: 500)
        let limitAt = rig.clock.now
        rig.source.reachDurationLimit()
        await HybridChecks.settle()
        f.expect(rig.local.durationLimitCalls == 0 && cloud.durationLimitCalls == 0,
                 "no branch hears the duration limit itself")
        f.expect(rig.session.phase == .finishing(releasedAtMs: limitAt), "the limit starts the finishing")
        f.expect(rig.local.finishCount == 1 && cloud.finishCount == 1, "both branches are finished once")
        f.expect(rig.source.stopCount >= 1, "the microphone is stopped")
        rig.local.completeFinish(final: "本地稿")
        await rig.clock.advance(to: limitAt + 500)
        cloud.completeFinish(final: "云端稿")
        await HybridChecks.settle()
        f.expect(rig.finals.map(\.text) == ["云端稿"] && rig.finals.first?.transcriptSource == .cloudEnhancement,
                 "decided on the cloud final")
        // The coordinator now completes the release (`completeRelease(.stop)`): it must find the decision taken.
        rig.session.noteReleaseAction(.stop)
        await rig.finishNow()
        f.expect(rig.backend.isQuiescent, "finish after the decision returns quiet")
        f.expect(rig.terminals.count == 1 && rig.session.counters.lateDropped == 0,
                 "no second decision and no stray release")
        f.expect(rig.local.finishCount == 1 && cloud.finishCount == 1, "no branch is finished twice")
        return f.all
    }

    // MARK: - HM-05 / HM-06: what the coordinator sees

    private static func eventContractChecks() async -> [String] {
        var f = Failures()
        guard let rig = f.rig(), await rig.start(), let cloud = rig.cloud else { return f.all + ["no rig"] }
        let started = rig.clock.now
        let trace = await TraceCapture.run { await eventContractScript(rig, cloud, started, &f) }
        f.expect(trace.contains("hybrid cloud ready handshakeMs=300 path=system\n"), "handshake line")
        f.expect(trace.contains(
            "hybrid final source=cloud reason=cloudFinal releaseToLocalFinalMs=600 releaseToCloudFinalMs=1400 " +
            "releaseToDecisionMs=1400 localPartials=2 cloudPartials=1 firstLocalPartialMs=300 firstCloudPartialMs=700 " +
            "localUTF16=4 cloudUTF16=6 diffBucket=0 maxBacklogMs=0 lateDropped=0 uplinkMs=0 draftToFinal=1-2\n"),
                 "the decision line, field by field")
        return f.all
    }

    private static func eventContractScript(
        _ rig: HybridRig, _ cloud: HybridTestingBranch, _ started: Int64, _ f: inout Failures
    ) async {
        await rig.clock.advance(to: started + 300)
        rig.local.emitPartial("你")
        cloud.emitReady()
        await rig.clock.advance(to: started + 700)
        rig.local.emitPartial("你好")
        cloud.emitPartial("你")
        await rig.clock.advance(to: started + 1_000)
        let released = rig.clock.now
        rig.releaseInBackground()
        await HybridChecks.settle()
        await rig.clock.advance(to: released + 600)
        rig.local.completeFinish(final: "你好世界")
        await rig.clock.advance(to: released + 1_400)
        cloud.completeFinish(final: "你好，世界。")
        await HybridChecks.settle()
        await rig.awaitRelease()

        f.expect(rig.events.map(\.kind) == [.ready, .partial, .partial, .final], "kinds \(rig.events.map(\.kind))")
        f.expect(rig.events.map(\.sequence) == [0, 1, 2, 3], "renumbered from 0 (\(rig.events.map(\.sequence)))")
        f.expect(rig.events.allSatisfy { $0.sessionID == rig.snapshot.sessionID }, "the dictation's session id")
        f.expect(zip(rig.events, rig.events.dropFirst()).allSatisfy { $0.observedMilliseconds <= $1.observedMilliseconds },
                 "time never goes back")
        f.expect(rig.events.last?.observedMilliseconds == Double(released + 1_400 - started),
                 "the final is stamped at the decision (\(rig.events.last?.observedMilliseconds ?? -1))")
        f.expect(rig.gateRejections == 0, "the event gate accepts every event")
        f.expect(rig.terminals.count == 1, "exactly one terminal")
        f.expect(rig.finals.first?.text == "你好，世界。" && rig.finals.first?.transcriptSource == .cloudEnhancement,
                 "the cloud raw text, marked as the enhancement, lexicon untouched")
        f.expect(rig.events.filter { $0.kind == .partial }.allSatisfy { $0.transcriptSource == .local },
                 "drafts are the local branch's")
        f.expect(rig.events.filter { $0.kind == .partial }.map(\.text) == ["你", "你好"], "the local drafts only")
        let c = rig.session.counters
        f.expect(c.reason == .cloudFinal && rig.session.finalSource == .cloud, "reason cloudFinal")
        f.expect(c.decidedAtMs.map { $0 - released } == 1_400, "decided on the cloud final (T1), not on a timer")
        f.expect(c.localPartials == 2 && c.cloudPartials == 1 && c.cloudReadyAtMs == started + 300, "counted")
        f.expect(rig.backend.isQuiescent, "quiet after finish")
    }

    private static func cloudAbsorbedChecks() async -> [String] {
        var f = Failures()
        // HM-06 while listening: a quota or rate failure never reaches the coordinator.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            let trace = await TraceCapture.run {
                cloud.emitPartial("云")
                cloud.emitFailure("ALI_RATE_LIMITED")
                await HybridChecks.settle()
                f.expect(rig.events.map(\.kind) == [.ready], "the cloud failure is absorbed")
                f.expect(rig.session.counters.cloudEnd == .rateLimited, "and mapped to its reason")
                f.expect(cloud.cancelCount == 1, "a cloud that stopped itself is still cancelled once")
                rig.local.emitPartial("本地继续")
                let released = rig.clock.now
                rig.releaseInBackground()
                await HybridChecks.settle()
                rig.local.completeFinish(final: "本地终稿")
                await HybridChecks.settle()
                await rig.awaitRelease()
                f.expect(rig.events.map(\.kind) == [.ready, .partial, .final], "the local dictation goes on")
                f.expect(rig.finals.first?.transcriptSource == .local && rig.session.counters.reason == .cloudDead,
                         "the local final, at once")
                f.expect(rig.session.counters.decidedAtMs == released, "no waiting for a cloud that left")
            }
            f.expect(trace.contains("hybrid cloud ended phase=listening reason=rateLimited code=ALI_RATE_LIMITED"),
                     "the cloud's end is traced with its finite code")
            f.expect(trace.contains("hybrid final source=local reason=cloudDead"), "the decision is traced")
        }
        // While finishing: the cloud stopping itself is absorbed too.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            rig.releaseInBackground()
            await HybridChecks.settle()
            cloud.emitStopped()
            await HybridChecks.settle()
            f.expect(rig.events.map(\.kind) == [.ready], "a cloud stop is never forwarded")
            rig.local.completeFinish(final: "本地")
            await HybridChecks.settle()
            await rig.awaitRelease()
            f.expect(rig.events.map(\.kind) == [.ready, .final] && rig.session.counters.cloudEnd == .cancelled,
                     "the local final")
        }
        return f.all
    }

    // MARK: - HM-07 / HM-08

    private static func cancelChecks() async -> [String] {
        var f = Failures()
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            rig.local.emitPartial("草稿")
            let before = rig.events.count
            await rig.cancelNow()
            f.expect(rig.events.count == before, "cancel reports nothing")
            f.expect(rig.backend.isQuiescent, "quiet when cancel returns")
            f.expect(rig.session.phase == .cancelled && rig.session.finalSource == nil, "cancelled")
            f.expect(rig.local.cancelCount == 1 && rig.source.stopCount >= 1, "local cancelled, microphone stopped")
            await HybridChecks.settle()
            f.expect(cloud.cancelCount == 1 && cloud.finishCount == 0, "the cloud is cut loose")
            await rig.finishNow()
            f.expect(rig.events.count == before && rig.local.finishCount == 0 && cloud.finishCount == 0,
                     "a finish after the cancel does nothing")
            rig.local.emitPartial("迟到")
            cloud.emitFinal("迟到")
            await HybridChecks.settle()
            f.expect(rig.events.count == before, "nothing after the cancel")
        }
        // A cancel while finishing releases the waiting finish, and still reports nothing.
        if let rig = f.rig(), await rig.start() {
            rig.releaseInBackground()
            await HybridChecks.settle()
            let before = rig.events.count
            await rig.cancelNow()
            await rig.awaitRelease()
            f.expect(rig.events.count == before && rig.backend.isQuiescent, "cancel during finishing is silent")
            f.expect(rig.local.cancelCount == 1, "the finishing local branch is cancelled")
        }
        return f.all
    }

    private static func concurrentFinishChecks() async -> [String] {
        var f = Failures()
        guard let rig = f.rig(), await rig.start(), let cloud = rig.cloud else { return f.all + ["no rig"] }
        var returned = 0
        var quietOnReturn = true
        let first = Task { @MainActor in
            await rig.finishNow()
            returned += 1
            quietOnReturn = quietOnReturn && rig.backend.isQuiescent
        }
        let second = Task { @MainActor in
            await rig.finishNow()
            returned += 1
            quietOnReturn = quietOnReturn && rig.backend.isQuiescent
        }
        await HybridChecks.settle()
        f.expect(returned == 0, "neither finish returns before the decision")
        f.expect(rig.local.finishCount == 1 && cloud.finishCount == 1, "one release")
        rig.local.completeFinish(final: "本地")
        cloud.completeFinish(final: "云端")
        await HybridChecks.bounded { await first.value }
        await HybridChecks.bounded { await second.value }
        f.expect(returned == 2 && quietOnReturn, "both return, quiet")
        f.expect(rig.terminals.count == 1 && rig.finals.first?.text == "云端", "one decision")
        f.expect(rig.session.counters.lateDropped == 0, "no second release")
        return f.all
    }

    // MARK: - HM-09…12

    private static func revokeChecks() async -> [String] {
        var f = Failures()
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            let trace = await TraceCapture.run {
                rig.session.revokeCloud(reason: .consentWithdrawn)
                await HybridChecks.settle()
                f.expect(cloud.cancelCount == 1 && rig.session.counters.cloudEnd == .consentWithdrawn,
                         "only the cloud branch stops")
                f.expect(!rig.session.isMonitoringBacklog, "its uplink is no longer watched")
                rig.local.emitPartial("还在说")
                f.expect(rig.events.last?.text == "还在说", "the local drafts go on")
                rig.releaseInBackground()
                await HybridChecks.settle()
                f.expect(cloud.finishCount == 0, "a withdrawn cloud is not finished")
                rig.local.completeFinish(final: "本地终稿")
                await rig.awaitRelease()
                f.expect(rig.session.finalSource == .local && rig.session.counters.reason == .cloudDead,
                         "the local final")
                rig.session.revokeCloud(reason: .consentWithdrawn)
                f.expect(cloud.cancelCount == 1 && rig.session.counters.lateDropped == 0,
                         "a revoke after the decision is a no-op")
            }
            f.expect(trace.contains("hybrid cloud ended phase=listening reason=consentWithdrawn code=none"),
                     "traced")
        }
        // While finishing: the local final is taken as soon as it comes.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            rig.releaseInBackground()
            await HybridChecks.settle()
            rig.session.revokeCloud(reason: .consentWithdrawn)
            await HybridChecks.settle()
            f.expect(cloud.cancelCount == 1, "the finishing cloud branch is cut loose")
            rig.local.completeFinish(final: "本地")
            await rig.awaitRelease()
            f.expect(rig.finals.first?.transcriptSource == .local, "local final")
        }
        return f.all
    }

    private static func backlogChecks() async -> [String] {
        var f = Failures()
        // HM-10: the uplink never moves; the cloud is dropped at the first check that is more than 2 s behind.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            let origin = rig.clock.now
            let trace = await TraceCapture.run {
                for step in 1...8 {
                    rig.source.appendAudio(milliseconds: 250)
                    await rig.clock.advance(to: origin + Int64(step) * 250)
                }
                f.expect(rig.session.counters.cloudEnd == nil && cloud.cancelCount == 0,
                         "exactly 2000 ms behind is still fine")
                f.expect(rig.session.counters.maxBacklogMs == 2_000, "max backlog \(rig.session.counters.maxBacklogMs)")
                rig.source.appendAudio(milliseconds: 250)
                await rig.clock.advance(to: origin + 9 * 250)
                f.expect(rig.session.counters.cloudEnd == .backlog, "dropped at the 2250 ms check")
                f.expect(rig.session.counters.cloudEndedAtMs == origin + 2_250, "at that check, not later")
                f.expect(cloud.cancelCount == 1 && !rig.session.isMonitoringBacklog, "cut loose, no more checks")
                rig.local.emitPartial("本地不受影响")
                f.expect(rig.events.last?.text == "本地不受影响", "the local branch is untouched")
            }
            f.expect(trace.contains("hybrid cloud ended phase=listening reason=backlog code=none atMs=2250 uplinkMs=0\n"),
                     "traced, field by field")
            await rig.cancelAndSettle()
        }
        // An uplink that keeps up is never dropped, and the checks stop at the release.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            let origin = rig.clock.now
            for step in 1...12 {
                rig.source.appendAudio(milliseconds: 250)
                cloud.uplinkSentMilliseconds = max(0, Int64(step) * 250 - 1_900)
                await rig.clock.advance(to: origin + Int64(step) * 250)
            }
            f.expect(rig.session.counters.cloudEnd == nil && cloud.cancelCount == 0, "a healthy uplink stays")
            rig.releaseInBackground()
            await HybridChecks.settle()
            f.expect(!rig.session.isMonitoringBacklog, "no backlog checks after the release")
            await rig.cancelAndSettle()
        }
        return f.all
    }

    private static func discardChecks() async -> [String] {
        var f = Failures()
        // HM-11: the swipe-down cuts the cloud off at the release.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            rig.session.noteReleaseAction(.cancel)
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            f.expect(cloud.finishCount == 0 && cloud.cancelCount == 1, "the cloud is cancelled, not finished")
            f.expect(rig.session.counters.cloudEnd == .discarded && rig.session.counters.discarded, "as discarded")
            f.expect(rig.local.finishCount == 1, "the local branch finishes")
            await rig.clock.advance(to: released + 600)
            rig.local.completeFinish(final: "本地")
            await rig.awaitRelease()
            f.expect(rig.session.counters.reason == .discard && rig.session.counters.decidedAtMs == released + 600,
                     "the local final at once, no cloud tail")
        }
        // `.send` / `.stop` change nothing: the cloud is finished and waited for.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            rig.session.noteReleaseAction(.send)
            rig.releaseInBackground()
            await HybridChecks.settle()
            f.expect(cloud.finishCount == 1 && cloud.cancelCount == 0, "the cloud is finished")
            await rig.cancelAndSettle()
        }
        return f.all
    }

    private static func snapshotChecks() async -> [String] {
        var f = Failures()
        for language in ["zh", "en", "auto"] {
            guard let rig = f.rig(language: language), await rig.start(), let cloud = rig.cloud else { continue }
            f.expect(rig.local.receivedSnapshot == rig.snapshot, "\(language): the local branch gets the snapshot as is")
            f.expect(rig.local.receivedSnapshot?.localHotwords == ["OpenAI", "Qwen"], "\(language): with its hot words")
            guard let derived = cloud.receivedSnapshot else {
                f.expect(false, "\(language): the cloud got no snapshot")
                continue
            }
            f.expect(derived.sessionID != rig.snapshot.sessionID, "\(language): its own session id")
            f.expect(derived.selection.mode == .voiceNative && derived.selection.routeID == "aliyun"
                     && derived.selection.language == language, "\(language): the Aliyun route, same language")
            f.expect(derived.lexiconRevision == rig.snapshot.lexiconRevision, "\(language): same lexicon revision")
            f.expect(derived.localHotwords.isEmpty, "\(language): no hot words for the cloud")
            f.expect(rig.session.cloudSnapshot == derived && rig.session.localSnapshot == rig.snapshot,
                     "\(language): what the backend keeps")
            await rig.cancelAndSettle()
        }
        // A snapshot the hybrid cannot run is refused before anything starts.
        if let rig = f.rig(), let selection = try? VoiceInputSelection(mode: .voiceNative, routeID: "apple-speech", language: "zh"),
           let snapshot = try? VoiceInputSnapshot(sessionID: UUID(), selection: selection, lexiconRevision: 0) {
            var threw = false
            await HybridChecks.bounded {
                do { try await rig.backend.start(snapshot: snapshot) { _ in } } catch { threw = true }
            }
            f.expect(threw && rig.session.localMakes == 0 && rig.backend.isQuiescent, "an ineligible route throws at once")
        }
        return f.all
    }

    // MARK: - HM-13

    private static func tracePrivacyChecks() async -> [String] {
        var f = Failures()
        let marker = "MKR7F3A"
        var trace = ""
        if let rig = f.rig(hotwords: ["\(marker)-HOT"]), await rig.start(), let cloud = rig.cloud {
            trace = await TraceCapture.run {
                rig.local.emitPartial("\(marker)-LOCAL-PARTIAL 你好")
                cloud.emitReady()
                cloud.emitPartial("\(marker)-CLOUD-PARTIAL")
                rig.releaseInBackground()
                await HybridChecks.settle()
                rig.local.completeFinish(final: "\(marker)-LOCAL-FINAL")
                await rig.clock.advance(to: rig.clock.now + 100)
                cloud.completeFinish(final: "\(marker)-CLOUD-FINAL\r\n第二行")
                await rig.awaitRelease()
                f.expect(rig.finals.first?.text == "\(marker)-CLOUD-FINAL\n第二行", "the cloud final is delivered")
            }
        }
        var failureTrace = ""
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            failureTrace = await TraceCapture.run {
                cloud.emitFailure("\(marker) 秘密 provider text")
                await HybridChecks.settle()
                await rig.cancelAndSettle()
            }
        }
        f.expect(trace.contains("hybrid final source=cloud reason=cloudFinal"), "the decision line is there")
        f.expect(trace.contains("hybrid cloud ready handshakeMs="), "the handshake line is there")
        f.expect(failureTrace.contains("hybrid cloud ended phase=listening reason=failed code=other"),
                 "an unknown code is never copied into the trace")
        for text in [trace, failureTrace] {
            f.expect(!text.contains(marker), "no recognized text, hot word or provider text in the trace")
            f.expect(!text.contains("秘密") && !text.contains("你好") && !text.contains("第二行"), "no text at all")
            f.expect(!text.contains("route=aliyun") && !text.contains("cloud admission admitted"),
                     "nothing that reads as a cloud route start")
        }
        return f.all
    }

    // MARK: - REPORT §⑦

    private static func reentrancyChecks() async -> [String] {
        var f = Failures()
        // §⑦1: an input that arrives while a batch is being performed waits for that batch.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            var endInsideCallback: HybridFinalSelector.CloudEnd?? = .none
            rig.onEvent = { event in
                guard event.kind == .partial else { return }
                rig.session.revokeCloud(reason: .consentWithdrawn)
                endInsideCallback = .some(rig.session.counters.cloudEnd)
            }
            rig.local.emitPartial("一")
            f.expect(endInsideCallback == .some(nil), "the revoke is queued, not handled inside the callback")
            f.expect(rig.session.counters.cloudEnd == .consentWithdrawn, "and handled right after it")
            rig.onEvent = nil
            await HybridChecks.settle()
            f.expect(cloud.cancelCount == 1, "the cloud is cut loose once")
            f.expect(rig.events.map(\.sequence) == [0, 1], "numbering unaffected")
            await rig.cancelAndSettle()
        }
        // A revoke from inside the ready callback lands before the cloud branch is built: it is never built.
        if let rig = f.rig() {
            rig.onEvent = { event in
                if event.kind == .ready { rig.session.revokeCloud(reason: .consentWithdrawn) }
            }
            let started = await rig.start()
            rig.onEvent = nil
            f.expect(started && rig.session.cloudMakes == 0, "no cloud branch after an early revoke")
            f.expect(rig.session.counters.cloudEnd == .consentWithdrawn, "the selector knows")
            rig.releaseInBackground()
            await HybridChecks.settle()
            rig.local.completeFinish(final: "本地")
            await rig.awaitRelease()
            f.expect(rig.session.counters.reason == .cloudDead, "local final at once")
        }
        return f.all
    }

    private static func invalidationChecks() async -> [String] {
        var f = Failures()
        // §⑦2: what a cut-loose cloud says while it is being cancelled is dropped before the selector.
        for report in [HybridTestingBranch.CancelReport.stopped, .cleanupFailure] {
            guard let rig = f.rig(), await rig.start(), let cloud = rig.cloud else { continue }
            cloud.cancelReport = report
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            await rig.clock.advance(to: released + 600)
            rig.local.completeFinish(final: "本地")
            await HybridChecks.settle()
            f.expect(rig.terminals.isEmpty, "\(report): the local final waits for the cloud tail")
            await rig.clock.advance(to: released + 2_600)
            await rig.awaitRelease()
            f.expect(rig.session.counters.reason == .tailTimeout && rig.session.counters.decidedAtMs == released + 2_600,
                     "\(report): the local final after 2 s")
            f.expect(cloud.cancelCount == 1, "\(report): the cloud is cancelled")
            f.expect(rig.session.droppedCloudEvents >= 1, "\(report): its cancel report was dropped")
            f.expect(rig.session.counters.lateDropped == 0, "\(report): nothing of it reached the selector")
            cloud.emitFinal("迟到的云稿")
            await HybridChecks.settle()
            f.expect(rig.terminals.count == 1 && rig.session.counters.lateDropped == 0,
                     "\(report): a cloud final after the decision changes nothing")
            f.expect(rig.events.allSatisfy { $0.kind != .stopped } && rig.events.map(\.kind) == [.ready, .final],
                     "\(report): events \(rig.events.map(\.kind))")
        }
        return f.all
    }

    private static func lineBreakChecks() async -> [String] {
        var f = Failures()
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            rig.releaseInBackground()
            await HybridChecks.settle()
            rig.local.completeFinish(final: "本地")
            cloud.completeFinish(final: "第一行\r\n第二行\r第三行\n第四行")
            await rig.awaitRelease()
            f.expect(rig.finals.first?.text == "第一行\n第二行\n第三行\n第四行", "carriage returns become line feeds")
            f.expect(rig.finals.first?.text?.unicodeScalars.contains("\r") == false, "no carriage return left")
        }
        let cases: [(String, String)] = [
            ("", ""), ("abc", "abc"), ("a\r", "a\n"), ("\r\n\r\n", "\n\n"), ("\n\r", "\n\n"),
            ("x\r\ny", "x\ny"), ("\r\r\n", "\n\n"), ("é\r\nö", "é\nö"),
        ]
        for (raw, expected) in cases {
            f.expect(HybridTestingFactory.normalizedLineBreaks(raw) == expected,
                     "normalize \(raw.unicodeScalars.map { $0.value })")
        }
        return f.all
    }

    private static func localOwnFinalChecks() async -> [String] {
        var f = Failures()
        // §⑦4: the local branch ends itself while listening (its own 300 s timer).
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            let finishedAt = rig.clock.now
            rig.local.emitFinal("本地自己结束")
            await HybridChecks.settle()
            f.expect(rig.source.stopCount >= 1, "the microphone stops")
            f.expect(cloud.finishCount == 1 && rig.local.finishCount == 0, "the cloud is finished; the local ended itself")
            f.expect(rig.terminals.isEmpty, "the local final waits for the cloud tail")
            await rig.clock.advance(to: finishedAt + 300)
            cloud.completeFinish(final: "云端")
            await HybridChecks.settle()
            f.expect(rig.finals.first?.text == "云端", "the cloud final")
            // The coordinator reacts to the final with `completeRelease(.stop)`.
            rig.session.noteReleaseAction(.stop)
            await rig.finishNow()
            f.expect(rig.backend.isQuiescent && rig.local.finishCount == 0, "finish only joins, quiet")
            f.expect(rig.terminals.count == 1 && rig.session.counters.lateDropped == 0, "one decision")
        }
        // And when the cloud never answers: the local final after 2 s.
        if let rig = f.rig(), await rig.start() {
            let finishedAt = rig.clock.now
            rig.local.emitFinal("本地")
            await rig.clock.advance(to: finishedAt + 2_000)
            f.expect(rig.finals.first?.transcriptSource == .local && rig.session.counters.reason == .tailTimeout,
                     "local after the tail")
            await rig.finishNow()
            f.expect(rig.backend.isQuiescent, "quiet")
        }
        return f.all
    }

    private static func localBudgetWaitChecks() async -> [String] {
        var f = Failures()
        // §⑦7 / T4: the cloud final is here, the local branch is stuck; at L it is cancelled, and `finish` returns
        // only once that cancel has completed.
        guard let rig = f.rig(), await rig.start(), let cloud = rig.cloud else { return f.all + ["no rig"] }
        rig.local.holdsCancel = true
        let released = rig.clock.now
        rig.releaseInBackground()
        var secondReturned = false
        let second = Task { @MainActor in
            await rig.finishNow()
            secondReturned = true
        }
        await HybridChecks.settle()
        await rig.clock.advance(to: released + 500)
        cloud.completeFinish(final: "云端")
        await HybridChecks.settle()
        f.expect(rig.terminals.isEmpty, "waits for the local branch until L")
        await rig.clock.advance(to: released + 3_000)
        f.expect(rig.finals.first?.text == "云端" && rig.session.counters.reason == .localBudget, "the cloud at L")
        f.expect(rig.session.counters.decidedAtMs == released + 3_000, "exactly at L")
        f.expect(rig.local.cancelCount == 1 && rig.local.isHoldingCancel, "the local branch is being cancelled")
        f.expect(!rig.releaseReturned && !secondReturned, "finish does not return before the local branch is quiet")
        f.expect(!rig.backend.isQuiescent, "not quiet while the local cancel runs")
        rig.local.releaseCancel()
        await rig.awaitRelease()
        await HybridChecks.bounded { await second.value }
        f.expect(rig.backend.isQuiescent, "quiet once the local branch is")
        return f.all
    }

    private static func timerChecks() async -> [String] {
        var f = Failures()
        // §⑦6 / T3: one timer, replaced by the next moment, gone after the decision.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            f.expect(rig.session.timerArms == 1 && rig.session.hasArmedTimer, "armed for T")
            await rig.clock.advance(to: released + 500)
            cloud.completeFinish(final: "云端")
            await HybridChecks.settle()
            f.expect(rig.session.timerArms == 2, "re-armed for L")
            await rig.clock.advance(to: released + 1_200)
            rig.local.completeFinish(final: "本地")
            await rig.awaitRelease()
            f.expect(rig.session.counters.decidedAtMs == released + 1_200 && rig.session.finalSource == .cloud,
                     "decided when the local final came (T3)")
            f.expect(!rig.session.hasArmedTimer, "no timer after the decision")
            await rig.clock.advance(to: released + 6_000)
            f.expect(rig.session.counters.lateDropped == 0 && rig.terminals.count == 1, "no tick after the decision")
        }
        // A late timer: the tick carries the clock's reading, not the moment it was set for.
        if let rig = f.rig(), await rig.start() {
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            await rig.clock.advance(to: released + 600)
            rig.local.completeFinish(final: "本地")
            await HybridChecks.settle()
            await rig.clock.jump(to: released + 2_700)
            await rig.awaitRelease()
            f.expect(rig.session.counters.reason == .tailTimeout, "tail timeout")
            f.expect(rig.session.counters.decidedAtMs == released + 2_700, "decided at the late reading")
        }
        // Same millisecond: a cloud final exactly at the tail deadline, before its timer fired, is on time.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            await rig.clock.advance(to: released + 600)
            rig.local.completeFinish(final: "本地")
            await HybridChecks.settle()
            rig.clock.set(released + 2_600)
            cloud.completeFinish(final: "云端")
            await rig.awaitRelease()
            f.expect(rig.session.finalSource == .cloud && rig.session.counters.decidedAtMs == released + 2_600,
                     "the input at the deadline wins over the deadline")
            await rig.clock.advance(to: released + 2_600)
            f.expect(rig.terminals.count == 1 && rig.session.counters.lateDropped == 0, "the stale timer is harmless")
        }
        // T10: nothing arrives by T: only the cloud is dropped there. The local branch is not cancelled,
        // finish() keeps waiting for it (as on the local route alone), and its late final is the dictation.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            await rig.clock.advance(to: released + 4_999)
            f.expect(rig.terminals.isEmpty, "nothing before T")
            await rig.clock.advance(to: released + 5_000)
            await HybridChecks.settle()
            f.expect(rig.terminals.isEmpty && !rig.releaseReturned, "T decides nothing while the local branch runs")
            f.expect(rig.local.cancelCount == 0 && cloud.cancelCount == 1 && rig.session.counters.cloudEnd == .deadline,
                     "at T only the cloud is dropped")
            await rig.clock.advance(to: released + 9_000)
            rig.local.completeFinish(final: "本地慢终稿")
            await rig.awaitRelease()
            f.expect(rig.finals.count == 1 && rig.finals.first?.text == "本地慢终稿"
                        && rig.finals.first?.transcriptSource == .local, "the late local final is delivered")
            f.expect(rig.terminals.count == 1 && rig.session.counters.reason == .cloudDead, "one decision, by it")
            f.expect(rig.releaseReturned && rig.backend.isQuiescent, "finish returns, quiet")
        }
        return f.all
    }

    private static func sessionFilterChecks() async -> [String] {
        var f = Failures()
        // §⑦9: branch events are checked against their own session id first.
        guard let rig = f.rig(), await rig.start(), let cloud = rig.cloud,
              let cloudSession = rig.session.cloudSnapshot?.sessionID else { return f.all + ["no rig"] }
        cloud.emitRaw(kind: .final, text: "串台", sessionID: rig.snapshot.sessionID)
        cloud.emitRaw(kind: .failed, text: nil, errorCode: "ALI_TIMEOUT", sessionID: UUID())
        rig.local.emitRaw(kind: .partial, text: "串台", sessionID: cloudSession)
        rig.local.emitRaw(kind: .failed, text: nil, errorCode: "LOCAL_INFERENCE_FAILED", sessionID: UUID())
        await HybridChecks.settle()
        f.expect(rig.session.droppedCloudEvents == 2 && rig.session.droppedLocalEvents == 2, "all four dropped")
        f.expect(rig.session.counters.cloudEnd == nil && rig.session.counters.cloudFinalAtMs == nil,
                 "the cloud is still running")
        f.expect(rig.events.map(\.kind) == [.ready], "nothing forwarded")
        rig.local.emitRaw(kind: .partial, text: "正确", sessionID: rig.snapshot.sessionID)
        f.expect(rig.events.last?.text == "正确" && rig.events.last?.sequence == 1, "the right session gets through")
        await rig.cancelAndSettle()
        return f.all
    }

    private static func lateInputChecks() async -> [String] {
        var f = Failures()
        // §⑦11: a local draft after the release is not shown; inputs after the decision are only counted.
        guard let rig = f.rig(), await rig.start(), let cloud = rig.cloud else { return f.all + ["no rig"] }
        rig.releaseInBackground()
        await HybridChecks.settle()
        rig.local.emitPartial("收尾期草稿")
        f.expect(rig.events.map(\.kind) == [.ready], "no draft after the release")
        f.expect(rig.session.counters.lateDropped == 1, "counted as late")
        rig.local.completeFinish(final: "本地")
        cloud.completeFinish(final: "云端")
        await rig.awaitRelease()
        rig.local.emitFinal("第二个本地终稿")
        f.expect(rig.terminals.count == 1, "one terminal")
        return f.all
    }

    private static func cloudStartFailureChecks() async -> [String] {
        var f = Failures()
        // Building the cloud branch throws (an invalid endpoint): the dictation is simply local.
        if let rig = f.rig(hasCloud: false) {
            let trace = await TraceCapture.run {
                let started = await rig.start()
                f.expect(started && rig.events.map(\.kind) == [.ready], "the start succeeds on the local branch")
                f.expect(rig.session.cloudMakes == 1 && rig.session.counters.cloudEnd == .startFailed, "startFailed")
                f.expect(!rig.session.isMonitoringBacklog, "nothing to watch")
                let released = rig.clock.now
                rig.releaseInBackground()
                await HybridChecks.settle()
                rig.local.completeFinish(final: "本地")
                await rig.awaitRelease()
                f.expect(rig.session.counters.reason == .cloudDead && rig.session.counters.decidedAtMs == released,
                         "local final at once")
            }
            f.expect(trace.contains("hybrid cloud ended phase=listening reason=startFailed code=none"), "traced")
        }
        // The cloud's start throws.
        if let rig = f.rig(), let cloud = rig.cloud {
            cloud.startFailure = .beforePermission("ALI_INVALID")
            let started = await rig.start()
            await HybridChecks.settle()
            f.expect(started && rig.session.counters.cloudEnd == .startFailed, "startFailed")
            f.expect(cloud.cancelCount == 1, "the failed cloud is still cancelled")
            f.expect(rig.events.map(\.kind) == [.ready], "nothing of it forwarded")
            await rig.cancelAndSettle()
        }
        // The cloud's start is still running when the dictation is cancelled.
        if let rig = f.rig(), let cloud = rig.cloud {
            cloud.holdsStart = true
            var startReturned = false
            let start = Task { @MainActor in
                let started = await rig.start()
                startReturned = true
                return started
            }
            await HybridChecks.settle()
            f.expect(cloud.isHoldingStart && rig.events.map(\.kind) == [.ready], "local ready, cloud starting")
            await rig.cancelNow()
            f.expect(rig.backend.isQuiescent, "quiet: a starting cloud is cut loose")
            let started = await HybridChecks.value(of: start, or: false)
            f.expect(startReturned && started, "the start returned at the local ready")
            f.expect(rig.events.map(\.kind) == [.ready], "nothing reported")
            f.expect(cloud.cancelCount == 1, "cancelled once")
        }
        // A release while the cloud's start is still running: the cloud finishes after its start.
        if let rig = f.rig(), let cloud = rig.cloud {
            cloud.holdsStart = true
            let start = Task { @MainActor in await rig.start() }
            await HybridChecks.settle()
            rig.releaseInBackground()
            await HybridChecks.settle()
            f.expect(rig.local.finishCount == 1 && cloud.finishCount == 1, "both asked to finish")
            cloud.releaseStart()
            _ = await HybridChecks.value(of: start, or: false)
            await HybridChecks.settle()
            rig.local.completeFinish(final: "本地")
            cloud.completeFinish(final: "云端")
            await rig.awaitRelease()
            f.expect(rig.finals.first?.text == "云端", "the cloud final still counts")
            f.expect(!rig.session.isMonitoringBacklog, "no backlog watch after the release")
        }
        return f.all
    }

    // MARK: - The 5 s budget only bounds waiting for the cloud

    private static func localAloneChecks() async -> [String] {
        var f = Failures()
        // The cloud leaves while listening; the local final comes 5.5 s after the release: delivered, local.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            rig.local.emitPartial("前半")
            rig.session.revokeCloud(reason: .transient)
            await HybridChecks.settle()
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            f.expect(!rig.session.hasArmedTimer, "no deadline once the cloud is out")
            await rig.clock.advance(to: released + 5_500)
            f.expect(rig.terminals.isEmpty && rig.local.cancelCount == 0, "the local branch is not cut at T")
            rig.local.completeFinish(final: "前半后半")
            await rig.awaitRelease()
            f.expect(rig.finals.count == 1 && rig.finals.first?.text == "前半后半"
                        && rig.finals.first?.transcriptSource == .local, "the slow local final is delivered")
            f.expect(rig.session.finalSource == .local && rig.session.counters.reason == .cloudDead, "decided by it")
            f.expect(cloud.finishCount == 0 && rig.releaseReturned && rig.backend.isQuiescent, "quiet")
        }
        // A local failure after the release with the cloud out: one incomplete recognition.
        if let rig = f.rig(), await rig.start() {
            rig.session.revokeCloud(reason: .consentWithdrawn)
            await HybridChecks.settle()
            rig.releaseInBackground()
            await HybridChecks.settle()
            rig.local.completeFinish(failure: "LOCAL_INFERENCE_FAILED")
            await rig.awaitRelease()
            f.expect(rig.terminals.count == 1 && rig.terminals.first?.kind == .failed
                        && rig.terminals.first?.errorCode == HybridFinalSelector.incompleteCode,
                     "failed(HYBRID_FINAL_INCOMPLETE): \(rig.terminals.map { $0.errorCode ?? "nil" })")
            f.expect(rig.session.counters.reason == .incomplete && rig.backend.isQuiescent, "reason incomplete, quiet")
        }
        // Both fail after the release: the incomplete recognition comes with the second failure.
        if let rig = f.rig(), await rig.start(), let cloud = rig.cloud {
            rig.releaseInBackground()
            await HybridChecks.settle()
            rig.local.completeFinish(failure: "LOCAL_INFERENCE_FAILED")
            await HybridChecks.settle()
            f.expect(rig.terminals.isEmpty, "a local failure waits for the cloud")
            cloud.completeFinish(failure: "ALI_NETWORK_FAILED")
            await rig.awaitRelease()
            f.expect(rig.terminals.map { $0.errorCode } == [HybridFinalSelector.incompleteCode], "incomplete")
        }
        // A local failure while listening keeps its own code, as on the local route alone.
        if let rig = f.rig(), await rig.start() {
            rig.local.emitFailure("LOCAL_INFERENCE_FAILED")
            await HybridChecks.settle()
            f.expect(rig.terminals.map { $0.errorCode } == ["LOCAL_INFERENCE_FAILED"], "the local code while listening")
            await rig.cancelAndSettle()
        }
        // A local finish that returns without a result (nothing bounds the local branch once the cloud is out):
        // counted as a local failure, so finish() returns with the incomplete recognition instead of waiting.
        if let rig = f.rig(), await rig.start() {
            rig.session.revokeCloud(reason: .consentWithdrawn)
            await HybridChecks.settle()
            rig.local.finishStyle = .silent
            rig.releaseInBackground()
            await rig.awaitRelease()
            f.expect(rig.releaseReturned && rig.backend.isQuiescent, "a silent local finish does not hang finish()")
            f.expect(rig.terminals.map { $0.errorCode } == [HybridFinalSelector.incompleteCode], "reported incomplete")
        }
        // The deadline timer runs late: a local final just after T, before the tick, is delivered and finish()
        // returns.
        if let rig = f.rig(), await rig.start() {
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            rig.clock.set(released + 5_010)
            rig.local.completeFinish(final: "本地")
            await HybridChecks.settle()
            f.expect(rig.finals.first?.text == "本地" && rig.releaseReturned, "delivered before the late tick")
            await rig.clock.advance(to: released + 5_010)
            await rig.awaitRelease()
            f.expect(rig.terminals.count == 1 && rig.session.counters.lateDropped == 0, "one decision, nothing late")
            f.expect(rig.session.counters.cloudEnd == .deadline && rig.backend.isQuiescent, "the cloud out, quiet")
        }
        return f.all
    }

    // MARK: - start() returns at the local .ready; the cloud comes up on its own task

    private static func startWindowChecks() async -> [String] {
        var f = Failures()
        // start() does not wait for the cloud's start (the coordinator reads its return as "listening").
        if let rig = f.rig(), let cloud = rig.cloud {
            cloud.holdsStart = true
            let started = await rig.start()
            await HybridChecks.settle()
            f.expect(started && cloud.isHoldingStart, "start returned while the cloud is still starting")
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            rig.local.completeFinish(final: "本地")
            await rig.clock.advance(to: released + 2_000)
            await rig.awaitRelease()
            f.expect(rig.finals.first?.transcriptSource == .local && rig.terminals.count == 1, "the local final")
            f.expect(cloud.cancelCount == 1 && rig.backend.isQuiescent, "the starting cloud is cut loose")
        }
        // A release, a cancel or a withdrawal in the same turn as start() returning, before the cloud's task ran:
        // no cloud branch is ever built, and nothing of this dictation runs after finish()/cancel() return.
        for moment in ["finish", "cancel", "revoke"] {
            guard let rig = f.rig() else { continue }
            let backend = rig.backend
            let snapshot = rig.snapshot
            let session = rig.session
            let seen = StartWindowRecord()
            let run = Task { @MainActor in
                do {
                    try await backend.start(snapshot: snapshot) { seen.kinds.append($0.kind) }
                } catch {
                    return
                }
                switch moment {
                case "finish": await backend.finish()
                case "cancel": await backend.cancel()
                default: session.revokeCloud(reason: .consentWithdrawn)
                }
                seen.returned = true
                seen.cloudMakesAtReturn = session.cloudMakes
                seen.quietAtReturn = backend.isQuiescent
            }
            if moment == "finish" {
                await HybridChecks.settle()
                rig.local.completeFinish(final: "本地")
            }
            await HybridChecks.bounded { await run.value }
            await HybridChecks.settle()
            f.expect(seen.returned, "\(moment): returned")
            f.expect(session.cloudMakes == 0 && seen.cloudMakesAtReturn == 0 && (rig.cloud?.startCount ?? 0) == 0,
                     "\(moment): no cloud branch was built")
            switch moment {
            case "finish":
                f.expect(seen.kinds == [.ready, .final] && session.finalSource == .local, "\(moment): \(seen.kinds)")
                f.expect(session.counters.cloudEnd == .startFailed && seen.quietAtReturn, "\(moment): quiet")
            case "cancel":
                f.expect(seen.kinds == [.ready] && seen.quietAtReturn, "\(moment): silent and quiet \(seen.kinds)")
            default:
                f.expect(session.counters.cloudEnd == .consentWithdrawn, "\(moment): withdrawn")
                await rig.cancelAndSettle()
            }
        }
        // A queued release waits for capture's asynchronous start. The one permission answer serves both branches.
        if let rig = f.rig() {
            let backend = rig.backend
            let snapshot = rig.snapshot
            let seen = StartWindowRecord()
            let start = Task { @MainActor in
                do {
                    try await backend.start(snapshot: snapshot) { seen.kinds.append($0.kind) }
                    seen.returned = true
                } catch {
                    seen.threw = true
                }
            }
            let release = Task { @MainActor in
                await start.value
                await backend.finish()
            }
            await HybridChecks.bounded { await start.value }
            f.expect(seen.returned && !seen.threw && seen.kinds.first == .ready, "the start is not abandoned")
            let released = rig.clock.now
            _ = await HybridChecks.until { rig.local.finishCount == 1 }
            rig.local.completeFinish(final: "本地")
            // The separate release task can let the cloud start first; drain its normal tail deadline.
            await rig.clock.advance(to: released + 2_000)
            await HybridChecks.bounded { await release.value }
            await HybridChecks.settle()
            f.expect(rig.permission.calls == 1 && rig.session.permissionRequests == 1, "one permission question")
            f.expect(seen.kinds == [.ready, .final] && backend.isQuiescent, "the local final, quiet: \(seen.kinds)")
        }
        // A withdrawal while the cloud's start is under way: cut loose, never watched, the local final is used.
        if let rig = f.rig(), let cloud = rig.cloud {
            cloud.holdsStart = true
            let started = await rig.start()
            await HybridChecks.settle()
            rig.session.revokeCloud(reason: .consentWithdrawn)
            await HybridChecks.settle()
            f.expect(started && cloud.cancelCount == 1 && !rig.session.isMonitoringBacklog, "withdrawn while starting")
            rig.releaseInBackground()
            await HybridChecks.settle()
            rig.local.completeFinish(final: "本地")
            await rig.awaitRelease()
            f.expect(rig.finals.first?.transcriptSource == .local && cloud.finishCount == 0, "the local final")
        }
        return f.all
    }

    private static func drainChecks() async -> [String] {
        var f = Failures()
        guard let rig = f.rig(), await rig.start(), let cloud = rig.cloud else { return f.all + ["no rig"] }
        cloud.holdsCancel = true
        let trace = await TraceCapture.run {
            let released = rig.clock.now
            rig.releaseInBackground()
            await HybridChecks.settle()
            rig.local.completeFinish(final: "本地")
            await rig.clock.advance(to: released + 2_000)
            await rig.awaitRelease()
            f.expect(rig.session.counters.reason == .tailTimeout, "the local final after the tail")
            f.expect(rig.backend.isQuiescent, "quiet: the cloud is not waited for")
            f.expect(HybridTestingFactory.cloudDrainOutstanding == 1 && cloud.isHoldingCancel,
                     "the cut-loose cloud is counted while it shuts down")
            cloud.releaseCancel()
            let drained = await until { HybridTestingFactory.cloudDrainOutstanding == 0 }
            f.expect(drained, "and uncounted once it has")
        }
        f.expect(trace.contains("hybrid cloud ended phase=finishing reason=tailTimeout code=none"), "the end is traced")
        f.expect(trace.contains("hybrid drain done ms=") && trace.contains("outstanding=0"), "the drain is traced")
        return f.all
    }

    private static func quiescenceChecks() async -> [String] {
        var f = Failures()
        guard let rig = f.rig() else { return f.all }
        f.expect(rig.backend.isQuiescent, "before start")
        rig.permission.holds = true
        let start = Task { @MainActor in await rig.start() }
        await HybridChecks.settle()
        f.expect(!rig.backend.isQuiescent, "while the local branch starts")
        rig.permission.release(true)
        _ = await HybridChecks.value(of: start, or: false)
        f.expect(!rig.backend.isQuiescent, "while listening")
        rig.releaseInBackground()
        await HybridChecks.settle()
        f.expect(!rig.backend.isQuiescent, "while finishing")
        rig.local.completeFinish(final: "本地")
        rig.cloud?.completeFinish(final: "云端")
        await rig.awaitRelease()
        f.expect(rig.backend.isQuiescent, "after finish")
        await rig.cancelNow()
        f.expect(rig.backend.isQuiescent && rig.terminals.count == 1, "after a cancel that follows")
        return f.all
    }

    private static func uploadDecisionChecks() async -> [String] {
        var f = Failures()
        var budget = HybridBudget(); budget.totalMs = 60_000; budget.localMs = 60_000; budget.cloudTailMs = 300
        var early = HybridFinalSelector(budget: budget)
        _ = early.handle(.release(discard: false), nowMs: 100)
        _ = early.handle(.cloudFinal(text: "云端"), nowMs: 500)
        let corrected = early.handle(.localFinal(text: "本地"), nowMs: 1700)
        f.expect(corrected.contains { if case .emitFinal(_, .cloud) = $0 { return true }; return false }, "early upload corrects after local final")
        var late = HybridFinalSelector(budget: budget)
        _ = late.handle(.release(discard: false), nowMs: 100)
        _ = late.handle(.localFinal(text: "本地"), nowMs: 1700)
        let kept = late.handle(.tick, nowMs: 2000)
        f.expect(kept.contains { if case .emitFinal(_, .local) = $0 { return true }; return false }, "300 ms deadline keeps local")
        f.expect(HybridUploadPolicy.use(localFinalMs: 1700, resultMs: 2100) == .learnOnly, "late upload only learns")
        f.expect(!HybridUploadPolicy.shouldUpload(localText: " \n"), "no local text skips file upload")
        return f.all
    }

    private static func helperChecks() async -> [String] {
        var f = Failures()
        f.expect(HybridTestingFactory.traceSafeCode(nil) == nil, "no code")
        f.expect(HybridTestingFactory.traceSafeCode("ALI_FREE_QUOTA_EXHAUSTED") == "ALI_FREE_QUOTA_EXHAUSTED", "finite code")
        f.expect(HybridTestingFactory.traceSafeCode("CREDENTIAL_MISSING") == "CREDENTIAL_MISSING", "credential code")
        for foreign in ["", "ali_timeout", "ALI TIMEOUT", "秘密", String(repeating: "A", count: 65)] {
            f.expect(HybridTestingFactory.traceSafeCode(foreign) == "other", "foreign code \(foreign.count)")
        }
        f.expect(HybridTestingFactory.nextBacklogCheck(after: 1_000, origin: 1_000, interval: 250) == 1_250, "first check")
        f.expect(HybridTestingFactory.nextBacklogCheck(after: 1_250, origin: 1_000, interval: 250) == 1_500, "next check")
        f.expect(HybridTestingFactory.nextBacklogCheck(after: 1_700, origin: 1_000, interval: 250) == 1_750, "after a late wake")
        f.expect(HybridTestingFactory.nextBacklogCheck(after: 900, origin: 1_000, interval: 250) == 1_250, "clock behind")
        f.expect(HybridTestingFactory.nextBacklogCheck(after: Int64.max - 1, origin: 0, interval: 250) == Int64.max,
                 "saturates")
        // The lexicon rewrites a cloud final's text, never its source (`replacingText`).
        let event = SpeechInputEvent(
            sessionID: UUID(), sequence: 3, observedMilliseconds: 9, kind: .final, text: "我在用 open ai",
            transcriptSource: .cloudEnhancement
        )
        let corrector = DictationCorrector(lexicon: LexiconSnapshot(
            revision: 1, terms: [LexiconTerm(canonical: "OpenAI", variants: ["open ai"])]
        ))
        let corrected = corrector.correct(event, mode: .voiceNative).event
        f.expect(corrected.text == "我在用 OpenAI" && corrected.transcriptSource == .cloudEnhancement,
                 "the source survives the lexicon")
        f.expect(SpeechInputEvent(sessionID: event.sessionID, sequence: 0, observedMilliseconds: 0, kind: .ready)
                    .transcriptSource == nil, "other backends' events carry no source")
        return f.all
    }

    private static func macOnlyChecks() -> [String] {
        var failures: [String] = []
#if canImport(AVFoundation)
        if !HybridTestingFactory.liveSourceMatchesBackendDefaults() {
            failures.append("hybrid glue: the shared capture is not the backends' default capture")
        }
        let shape = HybridTestingFactory.silentBufferShape(frames: 1024, sampleRate: 48_000)
        if shape?.frames != 1024 || shape?.sampleRate != 48_000 {
            failures.append("hybrid glue: the scripted capture's AVAudioPCMBuffer is not 1024 frames at 48 kHz")
        }
#endif
        return failures
    }

    // MARK: - Helpers

    /// Lets the scripted branches, the timer and the monitor run. The clock's sleeps hop through the generic
    /// executor, so a few real milliseconds are part of it.
    static func settle() async {
        for _ in 0..<4 {
            for _ in 0..<50 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Backend calls that did not return within the bound.
    static var stuckCalls = 0

    /// Runs a call on its own task and waits a bounded time for it, so a wrong implementation fails the checks
    /// instead of hanging the self-test.
    @discardableResult
    static func bounded(_ call: @escaping @MainActor () async -> Void) async -> Bool {
        let done = CallFlag()
        Task { @MainActor in
            await call()
            done.isSet = true
        }
        let finished = await until { done.isSet }
        if !finished { stuckCalls += 1 }
        return finished
    }

    /// A task's value, or `fallback` when it did not arrive within the bound.
    static func value<T: Sendable>(of task: Task<T, Never>, or fallback: T) async -> T {
        var result = fallback
        await bounded { result = await task.value }
        return result
    }

    static func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }
}

/// What a check that drives `start()` itself saw.
@MainActor
private final class StartWindowRecord {
    var kinds: [SpeechInputEvent.Kind] = []
    var returned = false
    var threw = false
    var cloudMakesAtReturn = -1
    var quietAtReturn = false
}

@MainActor
private final class CallFlag {
    var isSet = false
}

/// Collects failures and builds rigs; a rig that cannot be built is itself a failure.
@MainActor
private struct Failures {
    private(set) var all: [String] = []

    mutating func expect(_ condition: Bool, _ label: @autoclosure () -> String) {
        if !condition { all.append(label()) }
    }

    mutating func rig(
        hasCloud: Bool = true, language: String = "zh", hotwords: [String] = ["OpenAI", "Qwen"], preferCloudDrafts: Bool = false
    ) -> HybridRig? {
        do {
            return try HybridRig(hasCloud: hasCloud, language: language, hotwords: hotwords, preferCloudDrafts: preferCloudDrafts)
        } catch {
            all.append("rig could not be built")
            return nil
        }
    }
}

/// The permission prompt, scripted: counts, answers, and can hold its answer.
@MainActor
private final class PermissionScript {
    let log: HybridTestingLog
    var answer = true
    var holds = false
    private(set) var calls = 0
    private var waiting: CheckedContinuation<Bool, Never>?

    init(log: HybridTestingLog) {
        self.log = log
    }

    var isWaiting: Bool { waiting != nil }

    func ask() async -> Bool {
        calls += 1
        log.note("permission")
        guard holds else { return answer }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiting = continuation
        }
    }

    func release(_ granted: Bool) {
        waiting?.resume(returning: granted)
        waiting = nil
    }
}

/// One scripted hybrid dictation and the coordinator's side of it: the events it received, run through the
/// same `SpeechSessionEventGate` the coordinator uses.
@MainActor
private final class HybridRig {
    let log: HybridTestingLog
    let clock: HybridManualClock
    let source: HybridTestingSource
    let local: HybridTestingBranch
    let cloud: HybridTestingBranch?
    let permission: PermissionScript
    let session: HybridTestingSession
    let snapshot: VoiceInputSnapshot
    private(set) var events: [SpeechInputEvent] = []
    private(set) var gateRejections = 0
    private(set) var startError: (any Error)?
    private(set) var releaseReturned = false
    var onEvent: ((SpeechInputEvent) -> Void)?
    private var gate: SpeechSessionEventGate
    private var releaseTask: Task<Void, Never>?

    init(hasCloud: Bool, language: String, hotwords: [String], preferCloudDrafts: Bool = false) throws {
        let log = HybridTestingLog()
        let clock = HybridManualClock()
        let source = HybridTestingSource(log: log)
        let local = HybridTestingBranch(role: .local, log: log)
        let cloud = hasCloud ? HybridTestingBranch(role: .cloud, log: log) : nil
        let permission = PermissionScript(log: log)
        self.log = log
        self.clock = clock
        self.source = source
        self.local = local
        self.cloud = cloud
        self.permission = permission
        session = HybridTestingFactory.make(
            clock: clock.clock, source: source, local: local, cloud: cloud, log: log,
            permission: { await permission.ask() }, preferCloudDrafts: preferCloudDrafts
        )
        let selection = try VoiceInputSelection(mode: .voiceNative, routeID: "qwen17-rolling", language: language)
        snapshot = try VoiceInputSnapshot(
            sessionID: UUID(), selection: selection, lexiconRevision: 7, localHotwords: hotwords
        )
        gate = try SpeechSessionEventGate(snapshot: snapshot)
    }

    var backend: any SpeechInputBackend { session.backend }

    var terminals: [SpeechInputEvent] {
        events.filter { $0.kind == .final || $0.kind == .failed || $0.kind == .stopped }
    }

    var finals: [SpeechInputEvent] { events.filter { $0.kind == .final } }

    func start() async -> Bool {
        var started = false
        let backend = self.backend
        let snapshot = self.snapshot
        let returned = await HybridChecks.bounded { [weak self] in
            do {
                try await backend.start(snapshot: snapshot) { [weak self] event in
                    self?.receive(event)
                }
                started = true
            } catch {
                self?.startError = error
            }
        }
        if returned && started {
            _ = await HybridChecks.until { self.session.cloudMakes > 0 }
            await HybridChecks.settle()
        }
        return returned && started
    }

    func finishNow() async {
        let backend = self.backend
        await HybridChecks.bounded { await backend.finish() }
    }

    func cancelNow() async {
        let backend = self.backend
        await HybridChecks.bounded { await backend.cancel() }
    }

    private func receive(_ event: SpeechInputEvent) {
        events.append(event)
        if !gate.accept(event) {
            gateRejections += 1
            Self.totalGateRejections += 1
        }
        if terminals.count > 1 { Self.rigsWithSecondTerminal += 1 }
        if event.kind == .stopped { Self.stoppedEvents += 1 }
        onEvent?(event)
    }

    /// Over every rig of the run: the coordinator's gate never refused an event, no dictation reported a second
    /// terminal, and no `.stopped` ever reached the coordinator.
    static var totalGateRejections = 0
    static var rigsWithSecondTerminal = 0
    static var stoppedEvents = 0

    /// The coordinator's release: `finish()` on its own task, as `releaseActiveVoice` does.
    func releaseInBackground() {
        guard releaseTask == nil else { return }
        let backend = self.backend
        releaseTask = Task { @MainActor [weak self] in
            await backend.finish()
            self?.releaseReturned = true
        }
    }

    func awaitRelease() async {
        if let releaseTask { await HybridChecks.bounded { await releaseTask.value } }
        await HybridChecks.settle()
    }

    func cancelAndSettle() async {
        await cancelNow()
        if let releaseTask { await HybridChecks.bounded { await releaseTask.value } }
        await HybridChecks.settle()
    }
}

/// A clock the checks move by hand. Sleepers wake in time order, each seeing its own moment on the clock.
@MainActor
final class HybridManualClock {
    private final class Reading: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64

        init(_ value: Int64) {
            self.value = value
        }

        var now: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: Int64) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        private var returnCount = 0

        /// Sleeps that have come back to the caller's side of the clock closure.
        var returns: Int {
            lock.lock()
            defer { lock.unlock() }
            return returnCount
        }

        func noteReturn() {
            lock.lock()
            returnCount += 1
            lock.unlock()
        }
    }

    private struct Sleeper {
        let id: Int
        let target: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let reading = Reading(10_000)
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    var now: Int64 { reading.now }

    var clock: HybridClock {
        let reading = self.reading
        return HybridClock(
            nowMs: { reading.now },
            sleepUntilMs: { [self] target in
                try await self.sleep(until: target)
                reading.noteReturn()
            }
        )
    }

    private func sleep(until target: Int64) async throws {
        if reading.now >= target { return }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append(Sleeper(id: id, target: target, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelSleeper(id) }
        }
    }

    private func cancelSleeper(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func nextDue(by target: Int64) -> Int? {
        var best: Int?
        for index in sleepers.indices where sleepers[index].target <= target {
            if let current = best {
                let a = sleepers[index], b = sleepers[current]
                if a.target < b.target || (a.target == b.target && a.id < b.id) { best = index }
            } else {
                best = index
            }
        }
        return best
    }

    /// Moves the clock to `target`, waking every sleeper due by then in time order, each at its own moment.
    func advance(to target: Int64) async {
        while let index = nextDue(by: target) {
            let sleeper = sleepers.remove(at: index)
            if sleeper.target > reading.now { reading.set(sleeper.target) }
            await wake(sleeper)
        }
        if target > reading.now { reading.set(target) }
        await HybridChecks.settle()
    }

    /// A late wake-up: the reading jumps first, then the sleepers due by then wake, all seeing the late reading.
    func jump(to target: Int64) async {
        if target > reading.now { reading.set(target) }
        while let index = nextDue(by: target) {
            await wake(sleepers.remove(at: index))
        }
    }

    /// The woken sleep leaves through the generic executor (the clock's closure is nonisolated), so wait until
    /// it is back on the caller's side before letting the main actor run what it triggers.
    private func wake(_ sleeper: Sleeper) async {
        let expected = reading.returns + 1
        sleeper.continuation.resume()
        let reading = self.reading
        _ = await HybridChecks.until { reading.returns >= expected }
        await HybridChecks.settle()
    }

    /// Moves the reading without waking anyone: an input that arrives exactly at a deadline, before its timer.
    func set(_ value: Int64) {
        reading.set(value)
    }
}

/// Runs a block and returns what it wrote to `RuntimeTrace`. One trace file per run, read from where the block
/// began (the checks run one after another, so nothing else writes in between).
@MainActor
private enum TraceCapture {
    private static var url: URL?

    static func run(_ body: @MainActor () async -> Void) async -> String {
        let url = self.url ?? {
            let url = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
                isDirectory: true
            ).appendingPathComponent("HybridChecks-\(UUID().uuidString).log")
            RuntimeTrace.configureForTesting(fileURL: url)
            self.url = url
            return url
        }()
        RuntimeTrace.flush()
        let before = (try? Data(contentsOf: url))?.count ?? 0
        await body()
        _ = await HybridChecks.until { HybridTestingFactory.cloudDrainOutstanding == 0 }
        await HybridChecks.settle()
        RuntimeTrace.flush()
        let written = (try? Data(contentsOf: url)) ?? Data()
        return String(decoding: written.dropFirst(before), as: UTF8.self)
    }
}
