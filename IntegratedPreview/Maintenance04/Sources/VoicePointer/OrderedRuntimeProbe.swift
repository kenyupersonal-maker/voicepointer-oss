import AppKit
@_spi(Testing) import VoicePointerCore

@MainActor
enum OrderedRuntimeProbe {
    static func run() async -> String {
        guard AccessibilityPermission.isTrusted, EventAccessPermission.canListen else {
            return "OrderedRuntimeProbe: FAIL permissions missing"
        }
        let driver = MultitouchDriver()
        let admission = GestureAdmissionAuthority(initial: .init(
            enabled: false, acceptingNewGestures: false, permissionsGranted: false
        ))
        let adapter = GestureMainQueueAdapter(
            admission: admission, maxInFlight: 1,
            executeOnMainActor: { _ in }
        )
        let monitor = OrderedMouseGestureMonitor(
            driver: driver, configuration: .init(), admission: admission,
            eventHandler: { adapter.handle($0) }
        )
        let service = TouchRuntimeService(
            backend: MultitouchDriverBackend(driver: driver),
            quiesce: AppTouchQuiesce(
                monitor: monitor, adapter: adapter,
                safety: VoiceOperationSafety(), keyboard: KeyboardOwnershipManager()
            )
        )
        var completed = 0
        var devices = 0
        for _ in 0..<5 {
            let started = await withCheckedContinuation { continuation in
                service.requestStart { continuation.resume(returning: $0) }
            }
            guard started == .started else { return "OrderedRuntimeProbe: FAIL start=\(started)" }
            let tapStarted = await withCheckedContinuation { continuation in
                monitor.startAsync { continuation.resume(returning: $0 == nil) }
            }
            // Admission stays closed for this entire probe: real ordinary
            // clicks pass through and no voice key or text action is invoked.
            try? await Task.sleep(for: .milliseconds(200))
            for _ in 0..<50 {
                if !service.stateSnapshot.isStale { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let freshSnapshot = service.stateSnapshot
            devices = freshSnapshot.devices.count
            MainActor.assertIsolated()
            let running = monitor.isRunningForTesting
            let stopped = await withCheckedContinuation { continuation in
                service.requestStop { continuation.resume(returning: $0) }
            }
            guard tapStarted, running, stopped == .stopped,
                  !freshSnapshot.isStale, devices > 0,
                  monitor.isIdleForTesting, !monitor.hasLiveBridgeForTesting,
                  service.stateSnapshot.lifecycleState == .idle else {
                return "OrderedRuntimeProbe: FAIL cycle=\(completed + 1) tap=\(tapStarted) stop=\(stopped)"
            }
            completed += 1
        }
        return "OrderedRuntimeProbe: PASS cycles=\(completed) devices=\(devices) gestureAdmission=closed"
    }
}
