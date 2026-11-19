import AppKit
import Foundation
import VoicePointerCore

private final class HangProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MainThreadHangWatchdog.Event] = []
    private var samples = 0

    func record(_ event: MainThreadHangWatchdog.Event) {
        lock.withLock { events.append(event) }
    }

    func recordSample() {
        lock.withLock { samples += 1 }
    }

    func snapshot() -> ([MainThreadHangWatchdog.Event], Int) {
        lock.withLock { (events, samples) }
    }
}

/// Controlled main-queue stall. The injected sampler never runs /usr/bin/sample
/// and the probe never starts microphone, AX, gestures, or the production app.
@MainActor
enum MainThreadHangWatchdogProbe {
    static func run() async -> String {
        let recorder = HangProbeRecorder()
        MainHangStateStore.shared.setPhase("listening")
        MainHangStateStore.shared.setRouteID("doubao")
        MainHangStateStore.shared.setTargetBundleID("org.example.editor")
        let watchdog = MainThreadHangWatchdog(
            onEvent: { recorder.record($0) },
            sample: { _ in recorder.recordSample() }
        )
        watchdog.start()
        try? await Task.sleep(for: .milliseconds(350))
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: 3.7)
        }
        try? await Task.sleep(for: .seconds(4.5))
        let (events, samples) = recorder.snapshot()
        watchdog.stop()
        let begins = events.compactMap { event -> MainHangState? in
            if case .began(_, let state) = event { return state }
            return nil
        }
        let slows = events.compactMap { event -> UInt64? in
            if case .slow(let elapsedMs, _) = event { return elapsedMs }
            return nil
        }
        let requests = events.filter {
            if case .sampleRequested = $0 { return true }
            return false
        }
        let ends = events.compactMap { event -> UInt64? in
            if case .ended(let elapsedMs) = event { return elapsedMs }
            return nil
        }
        let passed = slows.count == 1 && (slows.first ?? 0) >= 250 &&
            begins.count == 1 && requests.count == 1 && samples == 1 &&
            ends.count == 1 && (ends.first ?? 0) >= 3_000 &&
            begins.first?.phase == "listening" && begins.first?.routeID == "doubao"
        return "MainHangWatchdogProbe: \(passed ? "PASS" : "FAIL") " +
            "slows=\(slows.count) begins=\(begins.count) requests=\(requests.count) samples=\(samples) " +
            "ends=\(ends.count) elapsedMs=\(ends.first ?? 0)"
    }
}
