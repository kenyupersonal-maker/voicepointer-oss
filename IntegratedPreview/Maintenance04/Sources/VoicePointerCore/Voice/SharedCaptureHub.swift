import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

// "用于增强本地识别": one physical capture for two recognizers. The hub owns the only `LiveAudioPipeline` of a
// hybrid dictation (one native capture, one `CaptureLevelBus` announcement); each branch reads it through its own
// `SharedCaptureView`, which is what the branch's `makeCapture` returns. Both backends only ever read the
// append-only accumulated snapshot, so both see the very same `OwnedPCMBuffer` objects in the same order (the
// accumulators' `===` prefix check holds) and no audio is copied for the second reader.
//
// Nothing here is started by the hybrid backend itself: the first branch that starts its view starts the
// capture. The local branch starts first and only after its catalog and permission checks, so a hybrid dictation
// that cannot start locally never opens the microphone, exactly like the local route alone.

@MainActor
final class SharedCaptureHub {
    enum Branch: Hashable, Sendable {
        case local, cloud
    }

    private struct WeakView {
        weak var view: SharedCaptureView?
    }

    private let makeSource: @MainActor () -> any LocalSpeechCapture
    private var source: (any LocalSpeechCapture)?
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?
    private var stopRequested = false
    private var attached: [Branch: WeakView] = [:]
    private var durationLimitNoted = false
    // Incremental duration of the snapshot: the buffers are append-only, so only the new tail is summed.
    private var countedBuffers = 0
    private var countedFrames: Int64 = 0
    private var countedSampleRate: Double = 0

    /// The capture's 300 s limit. Only the hybrid backend hears it (as the release); the branches' own
    /// `onDurationLimitReached` is never called, so they cannot each finish on their own.
    var onDurationLimit: (@MainActor () -> Void)?

    private(set) var isRunning = false
    private(set) var isStopped = false
    /// How many times the physical capture was started: at most once.
    private(set) var physicalStarts = 0

    init(makeSource: @escaping @MainActor () -> any LocalSpeechCapture) {
        self.makeSource = makeSource
    }

    /// Exactly the capture `LocalSpeechBackend` and `AliSpeechBackend` build for themselves by default.
    static func liveSource() -> any LocalSpeechCapture {
        LiveAudioPipeline(
            capacity: 32,
            appleEnabled: false,
            captureByteLimit: 256 * 1024 * 1024,
            captureDurationSeconds: 300,
            gracefulDurationLimit: true
        )
    }

    func makeView(_ branch: Branch, allowSealedSnapshot: Bool = false) -> SharedCaptureView {
        SharedCaptureView(branch: branch, hub: self, allowSealedSnapshot: allowSealedSnapshot)
    }

    /// Starts the physical capture once; later calls change nothing. Throws once the hub has stopped, or when
    /// the source cannot start (the hub then counts as stopped).
    func start() async throws {
        guard !stopRequested else { throw TrialCoreError.invalid("SHARED_CAPTURE_NOT_RUNNING") }
        guard !isRunning else { return }
        if let startTask {
            try await startTask.value
            guard !stopRequested else { throw CancellationError() }
            return
        }
        let source = makeSource()
        self.source = source
        source.onCaptureFailure = { [weak self] code in
            Task { @MainActor [weak self] in self?.forwardCaptureFailure(code) }
        }
        source.onDurationLimitReached = { [weak self] in
            Task { @MainActor [weak self] in self?.noteDurationLimit() }
        }
        physicalStarts += 1
        let task = Task { @MainActor in try await source.start(streamingToApple: false) }
        startTask = task
        do {
            try await task.value
            try Task.checkCancellation()
            guard !stopRequested else { throw CancellationError() }
        } catch {
            await stop()
            throw error
        }
        isRunning = true
    }

    /// Stops the physical capture; idempotent. The snapshot is sealed afterwards, so every branch that finishes
    /// after this reads the same audio.
    func requestStop() {
        guard !stopRequested else { return }
        stopRequested = true
        isRunning = false
        guard let source else { isStopped = true; return }
        stopTask = Task { @MainActor [weak self] in
            await source.stop()
            self?.isStopped = true
        }
    }

    func stop() async {
        requestStop()
        await stopTask?.value
    }

    func snapshot() -> [OwnedPCMBuffer] {
        source?.snapshotBuffers() ?? []
    }

    /// Only the fallback owner calls this after both recognizers have drained.
    func discardSnapshot() {
        guard isStopped else { return }
        source = nil
        startTask = nil
        stopTask = nil
        attached.removeAll()
    }

    var failure: TrialCoreError? { source?.captureFailure }
    var smokeNumbers: (callbacks: Int, nonzero: Int, reopens: Int, ignored: Int) {
        (source as? LiveAudioPipeline)?.smokeNumbers ?? (0, 0, 0, 0)
    }

    var smokeDeviceID: UInt32 { (source as? LiveAudioPipeline)?.smokeDeviceID ?? 0 }

    var didReachDurationLimit: Bool { source?.didReachDurationLimit ?? false }

    /// Milliseconds of audio captured so far (the backlog monitor's "captured" side).
    func capturedMilliseconds() -> Int64 {
        let buffers = snapshot()
        if buffers.count < countedBuffers {
            countedBuffers = 0
            countedFrames = 0
            countedSampleRate = 0
        }
        while countedBuffers < buffers.count {
            let buffer = buffers[countedBuffers].buffer
            if countedSampleRate <= 0 { countedSampleRate = buffer.format.sampleRate }
            countedFrames += Int64(buffer.frameLength)
            countedBuffers += 1
        }
        guard countedSampleRate.isFinite, countedSampleRate > 0 else { return 0 }
        let ms = Double(countedFrames) * 1_000 / countedSampleRate
        guard ms.isFinite, ms < Double(Int64.max) else { return Int64.max }
        return Int64(ms.rounded(.down))
    }

    /// The first sample of the buffer at `index` on the shared time line (K05's sample index); nil past the end.
    func sampleIndex(ofBufferAt index: Int) -> Int64? {
        let buffers = snapshot()
        guard index >= 0, index < buffers.count else { return nil }
        return buffers[..<index].reduce(Int64(0)) { $0 + Int64($1.buffer.frameLength) }
    }

    fileprivate func attach(_ view: SharedCaptureView) async throws {
        if !stopRequested { try await start() }
        else {
            guard view.allowSealedSnapshot else { throw TrialCoreError.invalid("SHARED_CAPTURE_NOT_RUNNING") }
            await stop()
        }
        attached[view.branch] = WeakView(view: view)
    }

    fileprivate func detach(_ view: SharedCaptureView) {
        guard attached[view.branch]?.view === view else { return }
        attached[view.branch] = nil
    }

    /// Both branches take their own failure path (the local one fails the dictation, the cloud one only leaves).
    private func forwardCaptureFailure(_ code: String) {
        for branch in [Branch.local, Branch.cloud] {
            attached[branch]?.view?.onCaptureFailure?(code)
        }
    }

    private func noteDurationLimit() {
        guard !durationLimitNoted else { return }
        durationLimitNoted = true
        onDurationLimit?()
    }
}

/// One branch's read-only window on the shared capture. Stopping it only takes this branch off the capture;
/// the microphone stops when the hybrid backend stops the hub.
@MainActor
final class SharedCaptureView: LocalSpeechCapture {
    let branch: SharedCaptureHub.Branch
    private let hub: SharedCaptureHub
    fileprivate let allowSealedSnapshot: Bool

    var onCaptureFailure: (@Sendable (String) -> Void)?
    /// Kept but never called: the hub reports the duration limit to the hybrid backend only.
    var onDurationLimitReached: (@Sendable () -> Void)?

    fileprivate init(branch: SharedCaptureHub.Branch, hub: SharedCaptureHub, allowSealedSnapshot: Bool = false) {
        self.branch = branch
        self.hub = hub
        self.allowSealedSnapshot = allowSealedSnapshot
    }

    var captureFailure: TrialCoreError? { hub.failure }

    var didReachDurationLimit: Bool { hub.didReachDurationLimit }

    func snapshotBuffers() -> [OwnedPCMBuffer] { hub.snapshot() }

    /// Joins the shared capture, starting it if this is the first branch to ask.
    func start(streamingToApple: Bool) async throws {
        guard !streamingToApple else { throw TrialCoreError.invalid("SHARED_CAPTURE_APPLE_UNSUPPORTED") }
        try await hub.attach(self)
    }

    func stop() async {
        hub.detach(self)
    }
}
