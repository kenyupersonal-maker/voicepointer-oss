import Foundation

public enum InputRouteResumePolicy {
    public static func canResume(oldDevice: UInt32, newDevice: UInt32,
        oldRate: Double, newRate: Double, oldChannels: UInt32, newChannels: UInt32,
        oldLayout: UInt, newLayout: UInt, oldInterleaved: Bool, newInterleaved: Bool) -> Bool {
        oldDevice != 0 && oldDevice == newDevice && oldRate.isFinite && oldRate > 0 &&
        abs(oldRate - newRate) < 0.000001 && oldChannels > 0 && oldChannels == newChannels &&
        oldLayout == newLayout && oldInterleaved == newInterleaved
    }
}
