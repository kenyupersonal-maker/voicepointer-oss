import Foundation

/// Cloud first, then local on the same append-only RAM audio. The owner alone stops the physical source.
@MainActor
final class CloudOnlyFallbackBackend: SpeechInputBackend, SpeechCaptureCancellationInvalidating, SpeechCaptureActivityProviding, SpeechCapturedDurationProviding {
    private var finalAudioDurationSeconds: Double?
    var capturedDurationSeconds: Double {
        guard usingLocal else { return .nan }
        return finalAudioDurationSeconds ?? (Double(hub.capturedMilliseconds()) / 1000)
    }
    private let hub: SharedCaptureHub
    private let primary: any SpeechInputBackend
    private let local: any SpeechInputBackend
    private let localSnapshot: VoiceInputSnapshot
    private var callback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
    private var transition: Task<Void, Never>?
    private var used = false, cancelled = false, terminal = false, usingLocal = false, ready = false, cloudFinal = false
    private var finishRequested = false
    private var sequence: UInt64 = 0
    private var startedAt: TimeInterval = 0
    private var primarySelection: VoiceInputSelection?

    init(hub: SharedCaptureHub, primary: any SpeechInputBackend, local: any SpeechInputBackend,
         localSnapshot: VoiceInputSnapshot) {
        self.hub = hub; self.primary = primary; self.local = local; self.localSnapshot = localSnapshot
        hub.onDurationLimit = { [weak self] in Task { @MainActor in await self?.finish() } }
    }

    var isQuiescent: Bool {
        !used || (hub.isStopped && transition == nil && primary.isQuiescent && local.isQuiescent)
    }
    var hasAcceptedCaptureAudio: Bool { !hub.snapshot().isEmpty }
    var cloudAudioUploaded: Bool { ((primary as? any CloudUplinkReporting)?.uplinkSentMilliseconds ?? 0) > 0 }
    let capabilities = SpeechInputCapabilities(deliveryKind: .transcriptStream, supportsPartialText: true, supportsHints: false)

    func start(snapshot: VoiceInputSnapshot,
               onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void) async throws {
        guard !used, !cancelled else { throw CancellationError() }
        used = true; callback = onEvent; startedAt = ProcessInfo.processInfo.systemUptime
        primarySelection = snapshot.selection
        do {
            try await primary.start(snapshot: snapshot.withoutLocalHotwords()) { [weak self] in self?.receive($0, local: false) }
        } catch {
            if error is CancellationError || cancelled { await cancel(); throw CancellationError() }
            let permissionFailure: Bool
            if let ali = error as? AliBackendError, case .permission = ali { permissionFailure = true }
            else if let http = error as? GroqBackendError, case .permission = http { permissionFailure = true }
            else { permissionFailure = false }
            if permissionFailure || hub.failure != nil || (hub.isStopped && !finishRequested && hub.physicalStarts > 0) {
                await cancel()
                throw error // Preserve the existing permission/device diagnostic instead of retrying the microphone.
            }
            recover()
        }
        if let transition { await transition.value }
    }

    private func receive(_ event: SpeechInputEvent, local isLocal: Bool) {
        guard !cancelled, !terminal, isLocal == usingLocal else { return }
        if let selection = isLocal ? localSnapshot.selection : primarySelection {
            if event.kind == .final, !(event.text ?? "").isEmpty { DictationHealthObservation.success(selection) }
            if event.kind == .failed { DictationHealthObservation.failure(selection, code: event.errorCode) }
        }
        if event.kind == .failed || event.kind == .stopped, !isLocal, !cloudFinal, hub.failure == nil,
           event.errorCode?.contains("MIC") != true, event.errorCode?.hasPrefix("INPUT_DEVICE") != true {
            recover()
            return
        }
        if event.kind == .final, !isLocal { cloudFinal = true }
        if event.kind == .ready {
            guard !ready else { return }
            ready = true
        }
        if event.kind == .stopped || event.kind == .failed {
            terminal = true
            hub.requestStop()
        }
        emit(event.kind, text: event.text, code: event.errorCode,
             source: isLocal ? .local : event.transcriptSource, confidence: event.confidenceEvidence)
    }

    private func recover() {
        guard !cancelled, !terminal, !usingLocal else { return }
        usingLocal = true // Reject every late cloud event before cancellation can suspend.
        RuntimeTrace.record("cloud fallback state=local")
        transition = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.transition = nil }
            await self.primary.cancel()
            guard !self.cancelled, !Task.isCancelled else { return }
            do {
                try await self.local.start(snapshot: self.localSnapshot) { [weak self] in self?.receive($0, local: true) }
            } catch {
                guard !self.cancelled, !(error is CancellationError) else { return }
                self.terminal = true
                await self.hub.stop()
                self.emit(.failed, code: "LOCAL_START_FAILED", source: .local)
                await self.local.cancel()
                self.hub.discardSnapshot()
            }
        }
    }

    private func emit(_ kind: SpeechInputEvent.Kind, text: String? = nil, code: String? = nil,
                      source: SpeechTranscriptSource? = nil, confidence: LocalModelConfidence? = nil) {
        if kind == .final { finalAudioDurationSeconds = capturedDurationSeconds }
        sequence &+= 1
        callback?(.init(sessionID: localSnapshot.sessionID, sequence: sequence,
            observedMilliseconds: max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
            kind: kind, text: text, errorCode: code, transcriptSource: source, confidenceEvidence: confidence))
    }

    func finish() async {
        guard used, !cancelled else { return }
        finishRequested = true
        await hub.stop()
        guard !cancelled else { return }
        if !usingLocal { await primary.finish() }
        if let transition { await transition.value }
        if usingLocal, !cancelled { await local.finish() }
        if primary.isQuiescent && local.isQuiescent { hub.discardSnapshot() }
    }

    func invalidateCaptureForCancellation() {
        cancelled = true
        callback = nil
        transition?.cancel()
        hub.requestStop()
        (primary as? any SpeechCaptureCancellationInvalidating)?.invalidateCaptureForCancellation()
        (local as? any SpeechCaptureCancellationInvalidating)?.invalidateCaptureForCancellation()
    }
    func cancel() async {
        invalidateCaptureForCancellation()
        await hub.stop()
        await primary.cancel()
        await local.cancel()
        if let transition { await transition.value }
        hub.discardSnapshot()
    }
}
