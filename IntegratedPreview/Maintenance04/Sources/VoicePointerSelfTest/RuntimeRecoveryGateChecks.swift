import VoicePointerCore

enum RuntimeRecoveryGateChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        var gate = RuntimeRecoveryGate()
        expect(gate.mayAutomaticallyArm(permissionsGranted: true), "initial arm")
        gate.observeSystemSettingsFrontmost(true)
        expect(!gate.mayAutomaticallyArm(permissionsGranted: true), "settings pause")
        expect(!gate.authorizeManualRecovery(permissionsGranted: true), "cannot override settings pause")
        gate.observeSystemSettingsFrontmost(false)
        expect(gate.mayAutomaticallyArm(permissionsGranted: true), "resume after settings")
        expect(!gate.mayAutomaticallyArm(permissionsGranted: false), "still requires permissions")

        for reason in [BlockReason.permissionLost, .eventTapStartFailed] {
            var blocked = RuntimeRecoveryGate()
            blocked.latch(reason)
            blocked.observeSystemSettingsFrontmost(true)
            blocked.observeSystemSettingsFrontmost(false)
            expect(blocked.blockedReason == reason, "settings must preserve hard failure")
            expect(!blocked.recoverTransientInterruption(permissionsGranted: true, now: 0), "hard failure needs manual recovery")
            expect(!blocked.authorizeManualRecovery(permissionsGranted: false), "permission denial preserved")
            expect(blocked.authorizeManualRecovery(permissionsGranted: true), "explicit recovery")
        }

        for reason in [BlockReason.inputSessionInvalidated, .eventTapDisabled] {
            var transient = RuntimeRecoveryGate()
            transient.latch(reason)
            expect(!transient.recoverTransientInterruption(permissionsGranted: false, now: 0), "no restart without permissions")
            transient.observeSystemSettingsFrontmost(true)
            expect(!transient.recoverTransientInterruption(permissionsGranted: true, now: 0), "no restart in settings")
            transient.observeSystemSettingsFrontmost(false)
            for second in 0..<3 {
                transient.latch(reason)
                expect(transient.recoverTransientInterruption(permissionsGranted: true, now: Double(second)), "bounded transient recovery")
                expect(transient.mayAutomaticallyArm(permissionsGranted: true), "recovery opens new session admission")
            }
            transient.latch(reason)
            expect(!transient.recoverTransientInterruption(permissionsGranted: true, now: 3), "restart storm bounded")
            expect(transient.requiresManualRecovery, "exhausted budget remains visibly paused")
            expect(transient.recoverTransientInterruption(permissionsGranted: true, now: 31), "later isolated interruption recoverable")
        }
        return failures
    }
}
