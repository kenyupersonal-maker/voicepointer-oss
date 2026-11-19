import Foundation

@MainActor
extension AliSpeechBackend {

    func finish() async {
        _ = await startTask?.result
        guard !cancelled else { return }
        if let existing = finishTask {
            await existing.value
            return
        }
        guard phase == .listening, let client = transport else { return }

        phase = .finishing
        requestCaptureStop()
        let preparation = prepareTask
        let sender = senderTask
        let supervisor = supervisorTask

        finishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.phase == .done { self.captureStopTask = nil } }
            let buffers = await self.stopCapture()
            do {
                // Let in-flight audio acks settle; do NOT cancel the sender here.
                await sender?.value
                try await preparation?.value
                try Task.checkCancellation()
                guard !self.cancelled, self.phase == .finishing else { return }
                guard !self.captureError else { throw AliBackendError.invalid }

                try await self.pump(buffers, final: true)
                try Task.checkCancellation()
                guard !self.cancelled, self.phase == .finishing else { return }

                // Mark as sent before awaiting: the final event can arrive immediately.
                self.finishSent = true
                try await client.finishInput()
                await supervisor?.value
            } catch {
                // Only the finishing phase is ours to fail; once cleaning/done the
                // supervisor owns the accepted final and we must not resend.
                if !self.cancelled, self.phase == .finishing {
                    self.captureError = true
                    await client.cancel()
                    await supervisor?.value
                }
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
        senderTask?.cancel()
        supervisorTask?.cancel()
        finishTask?.cancel()
    }

    func cancel() async {
        invalidateCaptureForCancellation()

        let start = startTask
        let preparation = prepareTask
        let sender = senderTask
        let supervisor = supervisorTask
        let finisher = finishTask
        let client = transport

        _ = await stopCapture()

        start?.cancel()
        preparation?.cancel()
        sender?.cancel()
        supervisor?.cancel()
        finisher?.cancel()

        // Interrupt any network/pipe waits so joins below cannot hang.
        await client?.cancel()

        _ = await start?.result
        _ = await preparation?.result
        await sender?.value
        await supervisor?.value
        await finisher?.value

        let quiet = await client?.isQuiescent() ?? true
        if quiet {
            startTask = nil
            prepareTask = nil
            senderTask = nil
            supervisorTask = nil
            finishTask = nil
            transport = nil
            converter = nil
            phase = .done
            captureStopTask = nil
            emit(.stopped, text: nil, errorCode: nil)
        } else {
            phase = .cleaning
            emit(.failed, text: nil, errorCode: "ALI_CLEANUP")
        }
    }
}
