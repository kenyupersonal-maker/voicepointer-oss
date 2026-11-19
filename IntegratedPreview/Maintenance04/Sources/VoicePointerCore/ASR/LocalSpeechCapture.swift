import Foundation

/// Injectable boundary over the live audio pipeline so tests can substitute
/// a fake capture without touching the real microphone. Mirrors the subset of
/// LiveAudioPipeline's API that LocalSpeechBackend uses.
@MainActor
internal protocol LocalSpeechCapture: AnyObject {
    var onCaptureFailure: (@Sendable (String) -> Void)? { get set }
    var onDurationLimitReached: (@Sendable () -> Void)? { get set }
    var captureFailure: TrialCoreError? { get }
    var didReachDurationLimit: Bool { get }
    func snapshotBuffers() -> [OwnedPCMBuffer]
    func start(streamingToApple: Bool) async throws
    /// A physical owner must drain its tail and seal the snapshot before returning.
    /// Shared views detach only; their owner stops the common input before either branch finalizes.
    func stop() async
}

extension LocalSpeechCapture {
    var onDurationLimitReached: (@Sendable () -> Void)? {
        get { nil }
        set {}
    }

    var didReachDurationLimit: Bool { false }
}

extension LiveAudioPipeline: LocalSpeechCapture {
    var captureFailure: TrialCoreError? { captured.failure }

    var didReachDurationLimit: Bool { captured.didReachDurationLimit }

    func snapshotBuffers() -> [OwnedPCMBuffer] { captured.snapshot() }
}
