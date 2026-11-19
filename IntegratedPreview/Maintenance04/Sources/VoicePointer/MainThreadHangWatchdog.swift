import Foundation
import Darwin
import VoicePointerCore

/// Observes main-queue progress without ever waiting for it. It diagnoses a
/// stall; it does not cancel a session, resend text, or restart the listener.
final class MainThreadHangWatchdog: @unchecked Sendable {
    enum Event: Sendable {
        case slow(elapsedMs: UInt64, state: MainHangState)
        case began(elapsedMs: UInt64, state: MainHangState)
        case sampleRequested(elapsedMs: UInt64)
        case ended(elapsedMs: UInt64)
    }

    private let queue = DispatchQueue(label: "com.kenyu.VoicePointer.main-hang", qos: .utility)
    private let samplingQueue = DispatchQueue(label: "com.kenyu.VoicePointer.main-hang-sample", qos: .utility)
    private let onEvent: @Sendable (Event) -> Void
    private let sample: @Sendable (MainHangState) -> Void
    private let onRecovered: @Sendable () -> Void
    private var timer: DispatchSourceTimer? // queue-confined
    private var pendingSinceNs: UInt64? // queue-confined
    private var pingID: UInt64 = 0 // queue-confined
    private var reported = false // queue-confined
    private var slowReported = false // queue-confined
    private var sampled = false // queue-confined
    private var sampleInFlight = false // queue-confined
    private var sampleAttempts = 0 // queue-confined
    private static let maxSampleAttemptsPerLaunch = 16
    private var pausedForSleep = false // queue-confined

    init(
        onEvent: @escaping @Sendable (Event) -> Void = MainThreadHangWatchdog.record,
        sample: @escaping @Sendable (MainHangState) -> Void = MainThreadHangWatchdog.captureSample,
        onRecovered: @escaping @Sendable () -> Void = {}
    ) {
        self.onEvent = onEvent
        self.sample = sample
        self.onRecovered = onRecovered
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            resetPending()
        }
    }

    func suspendForSleep() {
        queue.async { [self] in
            pausedForSleep = true
            resetPending()
        }
    }

    func resumeAfterWake() {
        queue.async { [self] in
            resetPending()
            pausedForSleep = false
        }
    }

    private func resetPending() {
        pingID &+= 1
        pendingSinceNs = nil
        reported = false
        slowReported = false
        sampled = false
    }

    private func tick() {
        guard !pausedForSleep, timer != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard let pendingSinceNs else {
            pingID &+= 1
            let sentID = pingID
            self.pendingSinceNs = now
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.queue.async { [self] in acknowledge(sentID) }
            }
            return
        }
        let elapsedMs = (now - pendingSinceNs) / 1_000_000
        if elapsedMs >= 250 && !slowReported {
            slowReported = true
            onEvent(.slow(elapsedMs: elapsedMs, state: MainHangStateStore.shared.snapshot()))
        }
        if elapsedMs >= 2_000 && !reported {
            reported = true
            onEvent(.began(elapsedMs: elapsedMs, state: MainHangStateStore.shared.snapshot()))
        }
        // Sample after 1 s, not after the 3 s it used to wait: the 3.1 s stall of 2026-09-30 had
        // already ended when the sample started, so it showed only an idle main thread.
        if elapsedMs >= 1_000 && !sampled {
            sampled = true
            if sampleInFlight {
                RuntimeTrace.record("main stall sample skipped reason=inFlight")
            } else if sampleAttempts >= Self.maxSampleAttemptsPerLaunch {
                RuntimeTrace.record("main stall sample skipped reason=launchBudget")
            } else {
                sampleInFlight = true
                sampleAttempts += 1
                let state = MainHangStateStore.shared.snapshot()
                onEvent(.sampleRequested(elapsedMs: elapsedMs))
                samplingQueue.async { [self] in
                    sample(state)
                    queue.async { [self] in sampleInFlight = false }
                }
            }
        }
    }

    private func acknowledge(_ receivedID: UInt64) {
        guard receivedID == pingID, let pendingSinceNs else { return }
        if reported {
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - pendingSinceNs) / 1_000_000
            onEvent(.ended(elapsedMs: elapsedMs))
            DispatchQueue.main.async { [onRecovered] in onRecovered() }
        }
        self.pendingSinceNs = nil
        reported = false
        slowReported = false
        sampled = false
    }

    private static func record(_ event: Event) {
        switch event {
        case .slow(let elapsedMs, let state):
            RuntimeTrace.record(
                "main slow elapsedMs=\(elapsedMs) phase=\(state.phase) " +
                "route=\(state.routeID) targetBundleID=\(state.targetBundleID) " +
                "operation=\(state.operation)"
            )
        case .began(let elapsedMs, let state):
            RuntimeTrace.record(
                "main stall begin elapsedMs=\(elapsedMs) phase=\(state.phase) " +
                "route=\(state.routeID) targetBundleID=\(state.targetBundleID) " +
                "operation=\(state.operation)"
            )
        case .sampleRequested(let elapsedMs):
            RuntimeTrace.record("main stall sample requested elapsedMs=\(elapsedMs)")
        case .ended(let elapsedMs):
            RuntimeTrace.record("main stall end elapsedMs=\(elapsedMs)")
        }
    }

    private static func captureSample(_ state: MainHangState) {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePointer", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "hang-\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)"
            let reportURL = folder.appendingPathComponent(name + ".sample.txt")
            let stateURL = folder.appendingPathComponent(name + ".state.txt")
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let stateText = "version=\(version) pid=\(ProcessInfo.processInfo.processIdentifier) " +
                "phase=\(state.phase) route=\(state.routeID) " +
                "targetBundleID=\(state.targetBundleID) operation=\(state.operation)\n"
            try stateText.write(to: stateURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", reportURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + .seconds(8)) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGTERM)
                if finished.wait(timeout: .now() + .seconds(2)) == .timedOut {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + .seconds(1))
                }
                RuntimeTrace.record("main stall sample timed out file=\(reportURL.lastPathComponent)")
                return
            }
            RuntimeTrace.record(
                "main stall sample finished exitCode=\(process.terminationStatus) file=\(reportURL.lastPathComponent)"
            )
        } catch {
            RuntimeTrace.record("main stall sample unavailable")
        }
    }
}
