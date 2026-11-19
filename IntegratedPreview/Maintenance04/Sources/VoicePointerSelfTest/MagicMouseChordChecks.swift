import Foundation
import CoreGraphics
@_spi(Testing) import VoicePointerCore

/// Pure regression checks for the Magic Mouse false-activation gate.
/// No private framework, permissions, app input, or running application is used.
enum MagicMouseChordChecks {
    static func runAll() -> [String] {
        let driver = MultitouchDriver()
        guard driver.resetTestTouchState() else {
            return ["magic-mouse chord fixtures must not run with the real touch framework loaded"]
        }

        var configuration = GestureConfiguration(trackpadEnabled: true)
        configuration.magicMouseMinDensity = 1
        configuration.magicMouseSlowMinDensity = 1
        configuration.magicMouseFastLandingMilliseconds = 150
        configuration.magicMouseMaxLandingSkewMilliseconds = 150
        var failures: [String] = []
        var cases = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            cases += 1
            if !condition() { failures.append(message) }
        }

        func consumeMagic(newest: Double, oldest: Double, frameAge: Double = 0.01) -> GestureMatch? {
            _ = driver.resetTestTouchState()
            driver.injectTestTouchState(
                kind: .magicMouse,
                touchCount: 2,
                frameAgeSeconds: frameAge,
                newestTouchAgeSeconds: newest,
                oldestTouchAgeSeconds: oldest
            )
            return driver.consumeEligibleGesture(configuration: configuration)
        }

        expect(
            consumeMagic(newest: 0.020, oldest: 0.169) != nil,
            "149ms Magic Mouse landing skew must remain eligible"
        )
        expect(
            consumeMagic(newest: 0.020, oldest: 0.170) != nil,
            "150ms Magic Mouse landing skew must remain eligible"
        )
        expect(
            consumeMagic(newest: 0.020, oldest: 0.171) == nil,
            "151ms Magic Mouse landing skew must be rejected"
        )
        expect(
            consumeMagic(newest: 0.020, oldest: 0.200) == nil,
            "a late second finger must not convert an ordinary click into a chord"
        )
        expect(
            consumeMagic(newest: 0.020, oldest: 0.100, frameAge: 0.151) == nil,
            "a stale Magic Mouse frame must remain rejected"
        )

        _ = driver.resetTestTouchState()
        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            newestTouchAgeSeconds: 0.020,
            oldestTouchAgeSeconds: 0.171
        )
        expect(
            driver.consumeEligibleGesture(configuration: configuration) == nil,
            "ordinary rejected Magic Mouse click must not become eligible"
        )
        driver.injectTestTouchState(
            kind: .builtInTrackpad,
            touchCount: 3,
            frameAgeSeconds: 0.01,
            newestTouchAgeSeconds: 0.020,
            oldestTouchAgeSeconds: 0.300
        )
        expect(
            driver.consumeEligibleGesture(configuration: configuration) != nil,
            "trackpad three-finger recognition must not inherit Magic Mouse skew"
        )

        _ = driver.resetTestTouchState()
        driver.injectTestTouchState(
            kind: .unknown,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            newestTouchAgeSeconds: 0.020,
            oldestTouchAgeSeconds: 0.040
        )
        expect(
            driver.consumeEligibleGesture(configuration: configuration) == nil,
            "an unknown device must not be interpreted as a Magic Mouse"
        )

        _ = driver.resetTestTouchState()
        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            newestTouchAgeSeconds: 0.020,
            oldestTouchAgeSeconds: 0.099
        )
        expect(
            driver.consumeEligibleGesture(configuration: configuration) != nil,
            "an earlier rejected Magic Mouse state must not block a later valid state"
        )

        for density: Float in [1, 0.99, .nan, .infinity] {
            _ = driver.resetTestTouchState()
            driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01, minDensity: density)
            expect((driver.consumeEligibleGesture(configuration: configuration) != nil) == (density == 1), "density boundary/nonfinite gate")
        }
        _ = driver.resetTestTouchState()
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01, minDensity: 0.99)
        expect(driver.consumeEligibleGesture(configuration: configuration) == nil, "density reject")
        let monitor = MouseGestureMonitor(driver: driver, configuration: configuration,
            onBegin: { _ in true }, onEnd: { _ in }, onCancel: {})
        if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left) {
            expect(!monitor.processEventForTesting(type: .leftMouseDown, event: event), "density rejected down returns original event")
        } else { failures.append("synthetic mouse event allocation") }
        expect(driver.setTestMinDensity(1.2), "same state density update")
        expect(driver.consumeEligibleGesture(configuration: configuration) != nil, "density reject must not consume state")
        _ = driver.resetTestTouchState()
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01,
            newestTouchAgeSeconds: 0.01, oldestTouchAgeSeconds: 0.10, minDensity: 0)
        var relaxed = configuration
        relaxed.magicMouseMinDensity = 0
        relaxed.magicMouseMaxLandingSkewMilliseconds = 100
        expect(driver.consumeEligibleGesture(configuration: relaxed) != nil, "density disabled plus configurable 90ms skew")
        expect(driver.touchSnapshot(deviceIndex: 0)?.points.count == 2, "snapshot exact count")
        _ = driver.resetTestTouchState()
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 8, frameAgeSeconds: 0.01)
        expect(driver.touchSnapshot(deviceIndex: 0)?.points.count == 6, "snapshot bounds six")
        _ = driver.resetTestTouchState()
        driver.injectTestTouchState(kind: .builtInTrackpad, touchCount: 3, frameAgeSeconds: 0.01, minDensity: 0)
        expect(driver.consumeEligibleGesture(configuration: configuration) != nil, "trackpad ignores density")
        let oldJSON = Data(#"{"magicMouseFingerCount":2,"trackpadFingerCount":3,"freshChordWindowMilliseconds":411,"maximumTouchMovement":0.07,"trackpadEnabled":false}"#.utf8)
        if let old = try? JSONDecoder().decode(GestureConfiguration.self, from: oldJSON) {
            expect(old.magicMouseMinDensity == 0.9 && old.magicMouseMaxLandingSkewMilliseconds == 600 && old.touchSampleRecordingEnabled, "old config new defaults")
            expect(old.freshChordWindowMilliseconds == 411 && old.magicMouseFreshChordWindowMilliseconds == 411 && !old.trackpadEnabled && old.maximumTouchMovement == 0.07, "old config preserves fields")
            expect((try? JSONDecoder().decode(GestureConfiguration.self, from: JSONEncoder().encode(relaxed))) == relaxed, "new config roundtrip")
        } else { failures.append("old configuration decode") }
        let balanced = GestureConfiguration(trackpadEnabled: true)
        func modernGate(_ skew: Double, _ density: Float, _ c: GestureConfiguration = GestureConfiguration()) -> Bool {
            _ = driver.resetTestTouchState()
            driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: 0.01,
                newestTouchAgeSeconds: 0.02, oldestTouchAgeSeconds: 0.02 + skew / 1000, minDensity: density)
            return driver.consumeEligibleGesture(configuration: c) != nil
        }
        for (skew, density, passes) in [(60.0, Float(0.92), true), (150, 1.05, false),
                                      (150, 1.12, true), (700, 1.5, false), (0, 0.89, false)] {
            expect(modernGate(skew, density) == passes, "two-stage density fixture")
        }
        for feel in MagicMouseFeel.allCases {
            let c = feel.applying(to: configuration)
            expect(c.magicMouseMinDensity == feel.density && c.magicMouseSlowMinDensity == 1.1 &&
                c.magicMouseFastLandingMilliseconds == 100 && c.magicMouseMaxLandingSkewMilliseconds == 600 &&
                MagicMouseFeel.selected(in: c) == feel, "preset writes all four fields")
        }
        for skew in [80, 150] {
            let data = Data("{\"magicMouseMinDensity\":1,\"magicMouseMaxLandingSkewMilliseconds\":\(skew)}".utf8)
            let c = try? JSONDecoder().decode(GestureConfiguration.self, from: data)
            expect(c == GestureConfiguration(), "old default migration to balanced")
        }
        let custom = try? JSONDecoder().decode(GestureConfiguration.self,
            from: Data(#"{"magicMouseMinDensity":1.8,"magicMouseMaxLandingSkewMilliseconds":210}"#.utf8))
        expect(custom?.magicMouseMinDensity == 1.8 && custom?.magicMouseSlowMinDensity == 1.8 &&
               custom?.magicMouseMaxLandingSkewMilliseconds == 210, "custom values remain unchanged")
        // Deterministic pseudo-random fixtures exercise the actual C shim and the
        // Swift preview without loading the real touch framework.
        var seed: UInt64 = 58
        for _ in 0..<200 {
            seed = seed &* 6364136223846793005 &+ 1
            let skew = Double((seed >> 32) % 790)
            seed = seed &* 6364136223846793005 &+ 1
            let density = Float((seed >> 32) % 180) / 100
            let data = Data("{\"t\":0,\"b\":\"L\",\"dec\":0,\"n\":2,\"hover\":0,\"points\":[{\"stage\":4,\"x\":0.3,\"y\":0.5,\"major\":8,\"minor\":8,\"size\":1,\"density\":\(density)},{\"stage\":4,\"x\":0.7,\"y\":0.5,\"major\":8,\"minor\":8,\"size\":1,\"density\":\(density)}],\"holdMS\":600,\"threshold\":0.9,\"skewLimitMS\":600,\"freshLimitMS\":1200,\"movementLimit\":0.08,\"frameAgeMS\":10,\"newestAgeMS\":20,\"oldestAgeMS\":\(20 + skew),\"movement\":0,\"label\":\"real\",\"gateMinDensity\":\(density),\"skewMS\":\(skew)}".utf8)
            if let row = try? JSONDecoder().decode(TouchSample.self, from: data) {
                expect(row.wouldTrigger(configuration: balanced) == modernGate(skew, density, balanced), "C/Swift preview agreement")
            } else { failures.append("numeric touch fixture decode") }
        }
        for kind: TouchDeviceKind in [.builtInTrackpad, .externalTrackpad] {
            _ = driver.resetTestTouchState()
            driver.injectTestTouchState(kind: kind, touchCount: 3, frameAgeSeconds: 0.01,
                newestTouchAgeSeconds: 0.02, oldestTouchAgeSeconds: 0.3, minDensity: 0)
            expect(driver.consumeEligibleGesture(configuration: balanced) != nil, "trackpad unchanged by modern mouse density rule")
        }
        _ = driver.resetTestTouchState()
        print("event=t145_chord,cases=\(cases),failures=\(failures.count),real_framework=0")
        return failures
    }
}
