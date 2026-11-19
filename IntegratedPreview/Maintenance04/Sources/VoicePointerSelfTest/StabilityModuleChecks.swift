import Foundation
@_spi(Testing) import VoicePointerCore

/// VP-D regression checks for the small stability modules.
///
/// These run inside the hardware-free self-test binary. They exercise pure
/// state (the production microphone intent gate) and the touch shim's
/// in-memory test hooks only: the private framework is never loaded,
/// `VPStartTouchDriver`/`VPStopTouchDriver` are never called, and no audio
/// hardware, system permission, or global input is touched.
enum StabilityModuleChecks {
    static func runAll() -> [String] {
        var failures: [String] = []
        checkMicrophoneIntentGate(&failures)
        checkTouchDriverShimPureData(&failures)
        return failures
    }

    private static func expect(
        _ failures: inout [String],
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { failures.append(message) }
    }

    // MARK: - Microphone intent gate (shared production type)

    private static func checkMicrophoneIntentGate(_ failures: inout [String]) {
        // Request authorization, stop, then receive the allow: the stale
        // answer must not resurrect the monitor.
        var stale = MicrophoneIntentGate()
        expect(
            &failures,
            stale.beginIntent() == .requestPermission(requestGeneration: 1),
            "first start with undetermined permission must request exactly once"
        )
        expect(&failures, stale.isRequestPending, "request must be pending while awaiting the system answer")
        expect(
            &failures,
            stale.endIntent() == .none,
            "stopping before the engine ever started must not emit closeEngine"
        )
        expect(&failures, !stale.desiredRunning, "stop must clear the running intent")
        stale.setPermission(.granted)
        expect(
            &failures,
            stale.permissionRequestResolved(requestGeneration: 1, granted: true) == .none,
            "a late allow for an ended intent must not start the engine"
        )
        expect(&failures, !stale.isEngineRunning, "a late allow must leave the engine stopped")

        // A fresh intent after the late allow starts, exactly once.
        expect(
            &failures,
            stale.beginIntent() == .openEngine,
            "a new intent with granted permission must open the engine"
        )
        expect(&failures, stale.isEngineRunning, "the engine must be marked running after openEngine")
        expect(
            &failures,
            stale.beginIntent() == .none,
            "a repeated start while running must not install a second tap"
        )

        // Stop, start again, then the old request's allow arrives: the still
        // active new intent is served by exactly one open.
        var resumed = MicrophoneIntentGate()
        expect(
            &failures,
            resumed.beginIntent() == .requestPermission(requestGeneration: 1),
            "the resumed fixture must request permission first"
        )
        expect(
            &failures,
            resumed.endIntent() == .none,
            "stop must invalidate the in-flight request without engine work"
        )
        expect(
            &failures,
            resumed.beginIntent() == .requestPermission(requestGeneration: 3),
            "a new intent after stop must mint a fresh permission request"
        )
        resumed.setPermission(.granted)
        expect(
            &failures,
            resumed.permissionRequestResolved(requestGeneration: 1, granted: true) == .none,
            "an expired permission answer must not restart the engine"
        )
        expect(&failures, !resumed.isEngineRunning, "the expired answer must leave the engine stopped")
        expect(&failures, resumed.isRequestPending, "old permission answer must not clear the newer pending request")
        expect(&failures, resumed.beginIntent() == .none, "repeated start must wait for the current permission answer")
        expect(&failures, resumed.permissionRequestResolved(requestGeneration: 3, granted: true) == .openEngine,
               "current permission answer must still start exactly once")

        // Denial never starts the engine and never re-requests.
        var denied = MicrophoneIntentGate()
        expect(
            &failures,
            denied.beginIntent() == .requestPermission(requestGeneration: 1),
            "the denial fixture must request permission first"
        )
        denied.setPermission(.denied)
        expect(
            &failures,
            denied.permissionRequestResolved(requestGeneration: 1, granted: false) == .none,
            "denial must not start the engine"
        )
        expect(&failures, denied.beginIntent() == .denied, "start after denial must report the denied state")
        expect(&failures, !denied.isRequestPending, "the denied path must not leave a request pending")
        expect(
            &failures,
            denied.permissionGeneration == 1,
            "the denied path must not mint new request generations"
        )

        // Repeated start/stop cycles stay balanced.
        var cycling = MicrophoneIntentGate(permission: .granted)
        expect(&failures, cycling.beginIntent() == .openEngine, "a granted start must open the engine")
        expect(&failures, cycling.endIntent() == .closeEngine, "stopping a running engine must close it")
        expect(&failures, cycling.endIntent() == .none, "a repeated stop must be idempotent")
        expect(&failures, cycling.beginIntent() == .openEngine, "restarting after a balanced stop must open again")
        expect(&failures, cycling.beginIntent() == .none, "the restart must not double-open")

        // A failed engine start rolls back so a later intent can retry.
        var failing = MicrophoneIntentGate(permission: .granted)
        expect(&failures, failing.beginIntent() == .openEngine, "the failure fixture must open once")
        failing.engineDidFailToStart()
        expect(&failures, !failing.isEngineRunning, "a failed start must leave the engine stopped")
        expect(
            &failures,
            failing.beginIntent() == .none,
            "the same failed start intent must not reopen the engine"
        )
        _ = failing.endIntent()
        expect(&failures, failing.beginIntent() == .openEngine, "a new intent after stop may retry")

        // Generation bookkeeping: stale answers are ignored, current ones win.
        var generations = MicrophoneIntentGate()
        expect(
            &failures,
            generations.beginIntent() == .requestPermission(requestGeneration: 1),
            "the first request must use generation 1"
        )
        _ = generations.endIntent()
        expect(
            &failures,
            generations.permissionGeneration == 2,
            "stop must invalidate the in-flight request generation"
        )
        generations.setPermission(.granted)
        expect(
            &failures,
            generations.beginIntent() == .openEngine,
            "a fresh intent with granted permission must open once"
        )
        expect(
            &failures,
            generations.permissionRequestResolved(requestGeneration: 1, granted: true) == .none,
            "a stale allow must not restart the engine"
        )
        expect(&failures, generations.endIntent() == .closeEngine, "the running engine must close on stop")
        generations.setPermission(.undetermined)
        expect(
            &failures,
            generations.beginIntent() == .requestPermission(requestGeneration: 4),
            "the next request must mint the following generation (1 request + 2 stops)"
        )
        generations.setPermission(.granted)
        expect(
            &failures,
            generations.permissionRequestResolved(requestGeneration: 4, granted: true) == .openEngine,
            "the current generation's allow must start the engine"
        )
        expect(&failures, generations.isEngineRunning, "the engine must be running after the current allow")
    }

    // MARK: - Touch shim pure-data checks (no private framework, no devices)

    private static func checkTouchDriverShimPureData(_ failures: inout [String]) {
        let driver = MultitouchDriver()
        guard driver.resetTestTouchState() else {
            failures.append("pure-data fixture reset refused real framework state")
            return
        }

        // Status copy takes the shim lock and must return a usable string.
        expect(&failures, !driver.status.isEmpty, "driver status copy must return a non-empty string")

        // The shim starts with no devices in a fresh self-test process.
        let magicMouseBaseline = driver.devices.filter { $0.kind == .magicMouse }.count
        if magicMouseBaseline == 0 {
            expect(
                &failures,
                !driver.injectTestTouchDisplacement(kind: .magicMouse, x: 0.1, y: 0),
                "a displacement update on an absent magic mouse must be rejected"
            )
        }

        // Invalid test injections must be rejected without mutating state.
        let countBeforeInvalid = driver.devices.count
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 21, frameAgeSeconds: 0.01)
        driver.injectTestTouchState(kind: .magicMouse, touchCount: 2, frameAgeSeconds: -1)
        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            newestTouchAgeSeconds: 0.5,
            oldestTouchAgeSeconds: 0.1
        )
        expect(
            &failures,
            driver.devices.count == countBeforeInvalid,
            "invalid test injections must not add devices"
        )

        // A valid injection must round-trip every reported field.
        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            maximumMovement: 0.02
        )
        let devices = driver.devices
        expect(
            &failures,
            devices.count == countBeforeInvalid + 1,
            "one valid injection must add exactly one device"
        )
        guard let injected = devices.last else { return }
        expect(&failures, injected.kind == .magicMouse, "the injected device must report its kind")
        expect(&failures, injected.touchCount == 2, "the injected device must report its touch count")
        expect(
            &failures,
            injected.callbackCount == 1,
            "the injected device must report one synthetic callback"
        )
        expect(&failures, injected.rawTouchCount == 2, "the injected device must report its raw touch count")
        expect(&failures, injected.stageMask == 1 << 4, "the injected device must report the active stage bit")
        expect(
            &failures,
            injected.lastFrameAgeSeconds >= 0.01 && injected.lastFrameAgeSeconds < 5,
            "the injected frame age must be preserved"
        )
        expect(
            &failures,
            injected.sensorRows == 0 && injected.sensorColumns == 0,
            "synthetic devices carry no sensor dimensions"
        )
        expect(&failures, injected.token != 0, "the injected device must expose a non-zero token")

        // Consume gate: eligibility, one-shot consumption, movement and
        // freshness windows — through the same locked pure-data path the
        // gesture monitor uses. Runs before the displacement update so the
        // movement gate keeps the chord eligible.
        let configuration = GestureConfiguration(
            magicMouseFingerCount: 2,
            trackpadFingerCount: 3,
            freshChordWindowMilliseconds: 350,
            magicMouseFreshChordWindowMilliseconds: 350,
            maximumTouchMovement: 0.08,
            trackpadEnabled: false
        )
        guard let match = driver.consumeEligibleGesture(configuration: configuration) else {
            expect(&failures, false, "a fresh two-finger magic mouse chord must be consumable")
            return
        }
        expect(
            &failures,
            match.deviceKind == .magicMouse && match.touchCount == 2,
            "the consumed match must describe the injected chord"
        )
        expect(
            &failures,
            driver.consumeEligibleGesture(configuration: configuration) == nil,
            "a consumed chord must not be handed out twice"
        )

        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            maximumMovement: 0.9
        )
        expect(
            &failures,
            driver.consumeEligibleGesture(configuration: configuration) == nil,
            "a chord that already moved past the movement gate must stay ineligible"
        )

        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.01,
            newestTouchAgeSeconds: 0.05,
            oldestTouchAgeSeconds: 0.6
        )
        expect(
            &failures,
            driver.consumeEligibleGesture(configuration: configuration) == nil,
            "a chord older than the freshness window must stay ineligible"
        )

        driver.injectTestTouchState(
            kind: .magicMouse,
            touchCount: 2,
            frameAgeSeconds: 0.5
        )
        expect(
            &failures,
            driver.consumeEligibleGesture(configuration: configuration) == nil,
            "a chord with a stale frame must stay ineligible"
        )

        // Trackpads respect the enable gate.
        driver.injectTestTouchState(kind: .builtInTrackpad, touchCount: 3, frameAgeSeconds: 0.01)
        expect(
            &failures,
            driver.consumeEligibleGesture(configuration: configuration) == nil,
            "a disabled trackpad chord must stay ineligible"
        )
        var trackpadConfiguration = configuration
        trackpadConfiguration.trackpadEnabled = true
        guard let trackpadMatch = driver.consumeEligibleGesture(configuration: trackpadConfiguration) else {
            expect(&failures, false, "an enabled fresh three-finger trackpad chord must be consumable")
            return
        }
        expect(
            &failures,
            trackpadMatch.deviceKind == .builtInTrackpad && trackpadMatch.touchCount == 3,
            "the enabled trackpad chord must be consumable"
        )

        // Displacement updates flow through the same locked state. Placed
        // after the consume checks because a displacement raises maximum
        // movement and would otherwise flip the eligibility gates above.
        expect(
            &failures,
            driver.injectTestTouchDisplacement(kind: .magicMouse, x: 0.3, y: -0.4),
            "a displacement update on the injected device must succeed"
        )
        // VPTestSetTouchDisplacement updates the most recent device of the
        // kind, so read the same device back (the trackpad injected above is
        // the array's last entry).
        guard let displaced = driver.devices.last(where: { $0.kind == .magicMouse }) else { return }
        expect(
            &failures,
            abs(displaced.directionalDisplacement.x - 0.3) < 0.0001
                && abs(displaced.directionalDisplacement.y + 0.4) < 0.0001,
            "the displacement update must be observable in device info"
        )
        // maximumMovement is internal to the shim state and not exposed on
        // TouchDeviceInfo; its consume-side effect is covered by the
        // movement-gate assertion above.
    }
}
