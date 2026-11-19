import Foundation
import CMultitouchSupport
import VoicePointerCore

enum MagicMouseEdgeChecks {
    static func run() -> [String] {
        var failures: [String] = []
        let c = GestureConfiguration()
        let driver = MultitouchDriver()
        func point(_ x: Float, _ minor: Float) -> VPTouchSnapshotPoint {
            .init(stage: 4, x: x, y: 0.5, major: 8, minor: minor, size: 1, density: 1.2, edge: false)
        }
        let index = point(0.3, 7.8), middle = point(0.7, 7.8), edge = point(0.995, 4.54)
        for (points, expected) in [([index, edge], false), ([index, middle, edge], true), ([point(0.06, 7.8), middle], true)] {
            guard VPTestResetTouchState(), VPTestInjectTouchState(VPDeviceKindMagicMouse, 0, 0, 0, 0, 0, 0),
                  points.withUnsafeBufferPointer({ VPTestInjectTouchFrame(VPDeviceKindMagicMouse, $0.baseAddress, Int32($0.count)) }) else {
                failures.append("mouse edge: injection"); continue
            }
            let match = driver.consumeEligibleGesture(configuration: c)
            if (match != nil) != expected { failures.append("mouse edge: live contact count") }
            if expected && match?.touchCount != 2 { failures.append("mouse edge: exactly two fingers") }
        }
        if VPMagicMouseIsEdge(0.06, 7.8, c.magicMouseEdgeMargin, c.magicMouseEdgeMaxMinor) {
            failures.append("mouse edge: ordinary left finger")
        }
        _ = VPTestResetTouchState()
        return failures
    }
}
