//
//  I03T4 — GroqSpeechBackend finish/cancel extension
//  Only finish() and cancel(); class/fields defined in lifecycle base file.
//

import Foundation

@MainActor
extension GroqSpeechBackend {

    func finish() async {
        _ = await startTask?.result
        guard !cancelled else { return }
        if let existing = finishTask {
            await existing.value
            return
        }
        guard phase == .listening, let transport, let snapshot else { return }
        phase = .finishing
        requestCaptureStop()
        let preparation = prepareTask
        finishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.phase == .done { self.captureStopTask = nil } }
            let buffers = await self.stopCapture()
            do {
                try await preparation?.value
                if self.captureError {
                    if let code = self.captureFailureCode { throw TrialCoreError.invalid(code) }
                    throw GroqBackendError.invalid
                }
                try Task.checkCancellation()
                guard !self.cancelled, self.phase == .finishing else { return }
                let converter = try BetaPCMAccumulator(maxSeconds: 300)
                let pcm = try await converter.snapshot(buffers, final: true)
                guard !pcm.clipped else { throw GroqBackendError.invalid }
                try Task.checkCancellation()
                guard !self.cancelled, self.phase == .finishing else { return }
                let wav = try GroqWAVEncoder.encode(pcm16Mono16K: pcm.data)
                let result = try await transport.transcribe(wav: wav)
                self.requestMilliseconds = Int64(min(45_000, max(0, result.requestMilliseconds)))
                try Task.checkCancellation()
                guard !self.cancelled, self.phase == .finishing else { return }
                guard result.sessionID == snapshot.sessionID else {
                    throw GroqBackendError.invalid
                }
                await transport.cancel()
                let quiet = await transport.isQuiescent()
                guard !self.cancelled, self.phase == .finishing else { return }
                if quiet {
                    self.transport = nil
                    self.phase = .done
                    self.emit(.final, text: result.text)
                } else {
                    self.phase = .cleaning
                    self.emit(.failed, errorCode: "GROQ_CLEANUP")
                }
            } catch {
                await transport.cancel()
                let quiet = await transport.isQuiescent()
                guard !self.cancelled, self.phase == .finishing else { return }
                self.phase = quiet ? .done : .cleaning
                if quiet { self.transport = nil }
                self.emit(.failed, errorCode: quiet ? SpeechFailureDiagnostics.code(for: error) : "GROQ_CLEANUP")
            }
        }
        await finishTask?.value
    }

    func invalidateCaptureForCancellation() {
        cancelled = true
        phase = .cleaning
        requestCaptureStop()
        startTask?.cancel()
        prepareTask?.cancel()
        observerTask?.cancel()
        finishTask?.cancel()
    }

    func cancel() async {
        invalidateCaptureForCancellation()
        let start = startTask
        let prep = prepareTask
        let observer = observerTask
        let finisher = finishTask
        let client = transport
        _ = await stopCapture()
        start?.cancel()
        prep?.cancel()
        observer?.cancel()
        finisher?.cancel()
        await client?.cancel()
        _ = await start?.result
        _ = await prep?.result
        await observer?.value
        await finisher?.value
        let quiet = await client?.isQuiescent() ?? true
        if quiet {
            startTask = nil
            prepareTask = nil
            observerTask = nil
            finishTask = nil
            transport = nil
            phase = .done
            captureStopTask = nil
            emit(.stopped)
        } else {
            phase = .cleaning
            emit(.failed, errorCode: "GROQ_CLEANUP")
        }
    }
}
