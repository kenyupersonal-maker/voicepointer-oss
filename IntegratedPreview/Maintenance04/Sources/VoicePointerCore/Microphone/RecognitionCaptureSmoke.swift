import Foundation

/// Explicit installed-app probe only. Uses the production tap, retaining no PCM and invoking no recognizer.
@_spi(Testing) @MainActor public final class RecognitionCaptureSmoke {
    private let pipeline = LiveAudioPipeline(appleEnabled: false, diagnosticsOnly: true)
    private var onlineHub: SharedCaptureHub?
    private var onlineView: (any LocalSpeechCapture)?
    private var lastCaptureDeviceID: UInt32 = 0
    public private(set) var failure: String?
    public init(online: Bool = false) {
        if online {
            let hub = SharedCaptureHub(makeSource: { SharedCaptureHub.liveSource() })
            onlineHub = hub; onlineView = hub.makeView(.cloud)
        }
    }
    public func start() async throws {
        if let view = onlineView {
            view.onCaptureFailure = { [weak self] code in Task { @MainActor [weak self] in self?.failure = SpeechFailureDiagnostics.safeCode(code) } }
            try await view.start(streamingToApple: false); return
        }
        pipeline.onCaptureFailure = { [weak self] code in
            Task { @MainActor [weak self] in self?.failure = SpeechFailureDiagnostics.safeCode(code) }
        }
        try await pipeline.start(streamingToApple: false)
    }
    public func stop() async -> (callbacks: Int, nonzero: Int, reopens: Int, ignored: Int) {
        if let hub = onlineHub {
            await hub.stop(); lastCaptureDeviceID = hub.smokeDeviceID
            let numbers = hub.smokeNumbers; hub.discardSnapshot()
            return numbers
        }
        await pipeline.stop()
        lastCaptureDeviceID = pipeline.smokeDeviceID
        return pipeline.smokeNumbers
    }
    public func matchesDeviceHash(_ expected: String) -> Bool {
        InputDeviceInventory.read().devices.first { $0.id == lastCaptureDeviceID }?.key == expected
    }
}
