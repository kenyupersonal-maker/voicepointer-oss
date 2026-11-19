import Foundation

/// What the coordinator may ask of a dictation backend that also runs the cloud enhancement branch
/// ("用于增强本地识别"). A protocol, so the coordinator never names the concrete backend class.
///
/// Both calls are for the coordinator only and are not part of `SpeechInputBackend`: every other backend
/// simply does not answer them (`activeBackend as? HybridSessionControlling` is nil for those).
@MainActor
@_spi(Testing) public protocol HybridSessionControlling: AnyObject {
    /// The release action, told BEFORE `finish()`: a swipe-down cancel (`.cancel`) must not wait for the cloud.
    func noteReleaseAction(_ action: VoiceReleaseAction)

    /// Stops only the cloud branch (consent withdrawn, key removed, ...). Local dictation and the pending
    /// send intent are untouched.
    func revokeCloud(reason: HybridFinalSelector.CloudEnd)
}
