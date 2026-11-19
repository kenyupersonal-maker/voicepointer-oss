import Foundation

@MainActor
extension AliSpeechBackend {

    func waitForAudibleCapture() async throws {
        while true {
            try Task.checkCancellation()
            guard !cancelled, !captureError else { throw AliBackendError.invalid }
            if let code = capture?.captureFailure?.description {
                captureError = true
                if MicrophoneSilenceGate.isSilenceCode(code) { failureCode = code }
                throw AliBackendError.invalid
            }
            if captureHasAudio || !(capture?.snapshotBuffers().isEmpty ?? true) {
                captureHasAudio = true
                return
            }
            // A stop may still be delivering the ring's tail. Let that final audio satisfy the audible gate.
            guard phase == .starting || phase == .listening ||
                  (phase == .finishing && captureStopTask != nil && capture != nil) else {
                throw AliBackendError.invalid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func pump(_ buffers: [OwnedPCMBuffer], final: Bool) async throws {
        if buffers.isEmpty && !final { return }
        guard let converter, let transport,
              phase == .listening || phase == .finishing,
              !cancelled else { throw AliBackendError.invalid }
        let pcm = try await converter.snapshot(buffers, final: final)
        try Task.checkCancellation()
        guard !pcm.clipped, pcm.data.count >= sentBytes, !cancelled,
              phase == .listening || phase == .finishing else { throw AliBackendError.invalid }
        while sentBytes < pcm.data.count {
            try Task.checkCancellation()
            guard phase == .listening || phase == .finishing, !cancelled else { throw AliBackendError.invalid }
            let end = min(sentBytes + Self.admissionFrameBytes, pcm.data.count)
            // K06: the gate must still recognise this stream's permit before every frame (<= 100 ms
            // of audio) leaves the host. A refusal has already cancelled the stream.
            guard await frameMayForward() else { throw AliBackendError.invalid }
            let chunk = Data(pcm.data[sentBytes..<end])
            try await transport.sendPCM(chunk)
            try Task.checkCancellation()
            guard !cancelled else { return }
            sentBytes = end
        }
    }

    func runSender() async {
        do {
            try await prepareTask?.value
            while !Task.isCancelled && !cancelled && phase == .listening {
                guard let capture else { break }
                try await pump(capture.snapshotBuffers(), final: false)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            recordFailure(error)
            await pauseIfConfirmed(by: error)
            if !cancelled && phase == .listening {
                captureError = true
                await transport?.cancel()
            }
        }
    }

    func runSupervisor() async {
        guard let transport, let snapshot else { return }
        var finalText: String? = nil
        var failed = false
        do {
            try await prepareTask?.value
            try Task.checkCancellation()
            guard !cancelled else { throw AliBackendError.invalid }
            emit(.ready)
            receiveLoop: while true {
                let out = try await transport.nextEvent()
                try Task.checkCancellation()
                guard !cancelled else { throw AliBackendError.invalid }
                guard out.sessionID == snapshot.sessionID else { throw AliBackendError.invalid }
                switch out.kind {
                case "partial":
                    guard await eventMayDeliver() else { throw AliBackendError.invalid }
                    emit(.partial, text: out.text)
                case "final":
                    guard finishSent, !captureError, phase == .finishing else {
                        throw AliBackendError.invalid
                    }
                    guard await eventMayDeliver() else { throw AliBackendError.invalid }
                    finalText = out.text ?? ""
                    break receiveLoop
                case "failed":
                    throw AliServiceFailure(
                        AliServiceFailure.Code(rawValue: out.errorCode ?? "") ?? .streamFailed,
                        evidence: out.failureEvidence
                    )
                default:
                    throw AliBackendError.invalid
                }
            }
        } catch {
            recordFailure(error)
            await pauseIfConfirmed(by: error)
            failed = true
        }
        if cancelled { return }
        phase = .cleaning
        _ = await stopCapture()
        senderTask?.cancel()
        await transport.cancel()
        await senderTask?.value
        let quiet = await transport.isQuiescent()
        guard !cancelled else { return }
        phase = quiet ? .done : .cleaning
        if quiet {
            self.transport = nil
            converter = nil
            // A normal finisher still owns its final buffers until it joins this supervisor.
            if finishTask == nil { captureStopTask = nil }
        }
        if quiet, !failed, !captureError, let finalText, textMayDeliverNow() {
            emit(.final, text: finalText)
        } else if quiet {
            emit(.failed, errorCode: failureCode ?? (arbiter?.isRevoked == true ? "ALI_CLOUD_REVOKED" : "ALI_STREAM_FAILED"))
        } else {
            emit(.failed, errorCode: "ALI_CLEANUP")
        }
    }
}
