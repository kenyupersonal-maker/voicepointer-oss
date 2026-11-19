import Foundation

public enum InputConfigurationPolicy {
    public enum Action: String, Sendable { case selfInflicted, sameDevice, restartInPlace, routeChanged }
    public static func shouldSetDevice(chosen: UInt32, systemDefault: UInt32) -> Bool {
        chosen != 0 && chosen != systemDefault
    }
    public static func validFormat(rate: Double, nominal: Double, channels: UInt32) -> Bool {
        rate.isFinite && nominal.isFinite && rate > 0 && rate <= 768_000 && channels > 0 && nominal > 0 && abs(rate - nominal) < 1
    }
    public static func captureDevice(configured: UInt32, followsDefault: Bool, systemDefault: UInt32, configuredAvailable: Bool) -> UInt32 {
        followsDefault ? systemDefault : (configuredAvailable ? configured : 0)
    }
    public static func action(sameDeviceAndFormat: Bool, running: Bool, observedAt: UInt64, ownChangeAt: UInt64) -> Action {
        if ownChangeAt > 0, observedAt >= ownChangeAt, observedAt - ownChangeAt < 500_000_000 { return .selfInflicted }
        if sameDeviceAndFormat { return running ? .sameDevice : .restartInPlace }
        return .routeChanged
    }
}
