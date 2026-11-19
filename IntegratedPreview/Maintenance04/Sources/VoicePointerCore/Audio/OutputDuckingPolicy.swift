import Foundation

/// A readable, reversible output-volume snapshot. Channels are normalized to 0...1.
public struct OutputDuckingReading: Codable, Equatable, Sendable {
    public var levels: [Double]
    public var muted: Bool

    public init(levels: [Double], muted: Bool) {
        self.levels = levels
        self.muted = muted
    }
}

public enum OutputDuckingTransport: String, Codable, Sendable {
    case builtin, bluetooth, usb, hdmi, virtual, aggregate, other
}

public enum OutputDuckingControl: String, Codable, Sendable {
    case virtualMain, scalar, channels, mute, none
}

/// Only this record may contain the private device UID. Never pass it to a diagnostic logger.
public struct OutputDuckingRecoveryRecord: Codable, Equatable, Sendable {
    public let uid: String
    public let transport: OutputDuckingTransport
    public let control: OutputDuckingControl
    public let original: OutputDuckingReading
    public let ducked: OutputDuckingReading
    public let recordedAt: TimeInterval

    public init(uid: String, transport: OutputDuckingTransport, control: OutputDuckingControl,
                original: OutputDuckingReading, ducked: OutputDuckingReading, recordedAt: TimeInterval) {
        self.uid = uid
        self.transport = transport
        self.control = control
        self.original = original
        self.ducked = ducked
        self.recordedAt = recordedAt
    }
}

/// Injected into the pure policy; the production implementation is the CoreAudio adapter.
@MainActor public protocol OutputDuckingDevice: AnyObject {
    var uid: String { get }
    var transport: OutputDuckingTransport { get }
    var control: OutputDuckingControl { get }
    var canMute: Bool { get }
    var isConnected: Bool { get }
    func read() -> OutputDuckingReading?
    func write(_ reading: OutputDuckingReading) -> Bool
}

/// A virtual scheduler makes every ramp, timeout and delayed callback deterministic in replay.
@MainActor public protocol OutputDuckingScheduling: AnyObject {
    var now: TimeInterval { get }       // monotonic, for relative deadlines
    var wallTime: TimeInterval { get }  // Unix time, for post-crash recovery only
    func after(seconds: TimeInterval, perform: @escaping @MainActor () -> Void)
}

/// Sole owner of original volume, timing, generation guards and restore decisions.
/// No AppKit, CoreAudio, device names, real user text, disk or network dependency.
@MainActor public final class OutputDuckingPolicy {
    private struct Session {
        let device: any OutputDuckingDevice
        let original: OutputDuckingReading
        var target: OutputDuckingReading
        var ratio: Double
        let startedAt: TimeInterval
        let recordedAt: TimeInterval // Original wall clock, retained across nearby gestures.
        var usingMute: Bool
        var expected: OutputDuckingReading
        var rampFrom: OutputDuckingReading
        var held = true
        var beginLogged = false
    }

    private let scheduler: any OutputDuckingScheduling
    private let trace: @MainActor (String) -> Void
    private let persist: @MainActor (OutputDuckingRecoveryRecord?) -> Void
    private let unsupported: @MainActor () -> Void
    private var session: Session?
    private var generation: UInt64 = 0
    private var fusedUIDs = Set<String>()
    private var notifiedUIDs = Set<String>()

    public init(scheduler: any OutputDuckingScheduling,
                trace: @escaping @MainActor (String) -> Void,
                persist: @escaping @MainActor (OutputDuckingRecoveryRecord?) -> Void,
                unsupported: @escaping @MainActor () -> Void) {
        self.scheduler = scheduler
        self.trace = trace
        self.persist = persist
        self.unsupported = unsupported
    }

    public var isActive: Bool { session != nil }

    /// An admitted gesture may begin a new session or reuse the earliest original volume.
    @discardableResult
    public func begin(device: (any OutputDuckingDevice)?, enabled: Bool, ratio requestedRatio: Double) -> Bool {
        guard enabled else {
            if session != nil { restoreImmediately(reason: "restored") } // Finish an earlier sentence safely.
            return false // Do not inspect or change the current device when switched off.
        }
        let ratio = requestedRatio.isFinite ? min(0.8, max(0, requestedRatio)) : 0.5
        guard let device else {
            trace("output duck begin transport=other control=none ratio=\(ratioText(ratio)) from=0.00 to=0.00 result=skipped")
            return false
        }
        if fusedUIDs.contains(device.uid) {
            traceBegin(device: device, control: device.control, ratio: ratio, from: 0, to: 0, result: "skipped")
            return false
        }
        if var previous = session, previous.device.uid == device.uid {
            guard device.isConnected else { restoreImmediately(reason: "deviceGone"); return false }
            if userRaised(device: device, expected: previous.expected) {
                userChanged()
                return false
            }
            generation &+= 1 // Cancels an earlier ramp, grace period and Bluetooth recheck.
            // A slider change applies to this sentence, without ever multiplying a reduced value.
            let oldTarget = previous.target
            previous.ratio = ratio
            previous.usingMute = (ratio == 0 && device.canMute) || device.control == .mute
            previous.target = .init(
                levels: previous.usingMute ? previous.original.levels : previous.original.levels.map { $0 * ratio },
                muted: previous.usingMute ? true : previous.original.muted
            )
            // Recovery must describe the next target while retaining the first original/time.
            if previous.target != oldTarget {
                persist(.init(uid: device.uid, transport: device.transport,
                              control: previous.usingMute ? .mute : device.control,
                              original: previous.original, ducked: previous.target,
                              recordedAt: previous.recordedAt))
            }
            let alreadyDucked = near(previous.expected, previous.target, tolerance: 0.02)
            previous.held = true
            previous.rampFrom = previous.expected
            session = previous
            if !alreadyDucked { startRampDown() } // No repeated multiplier or property writes in the grace window.
            scheduleHardDeadline()
            return true
        }
        if session != nil {
            // A default-output change during an active/grace session restores only the old output.
            // This new output is never ducked during the same gesture.
            restoreImmediately(reason: "deviceChanged")
            return false
        }
        guard device.isConnected, device.control != .none else {
            if notifiedUIDs.insert(device.uid).inserted { unsupported() }
            traceBegin(device: device, control: .none, ratio: ratio, from: 0, to: 0, result: "notSettable")
            return false
        }
        guard let original = device.read() else {
            traceBegin(device: device, control: device.control, ratio: ratio, from: 0, to: 0, result: "notSettable")
            return false
        }
        let volume = representative(original)
        guard !original.muted, original.levels.isEmpty || volume > 0.02 else {
            traceBegin(device: device, control: device.control, ratio: ratio, from: volume, to: volume, result: "skipped")
            return false
        }
        let useMute = (ratio == 0 && device.canMute) || device.control == .mute
        let target = OutputDuckingReading(
            levels: useMute ? original.levels : original.levels.map { min(1, max(0, $0 * ratio)) },
            muted: useMute ? true : original.muted
        )
        guard target != original else {
            traceBegin(device: device, control: device.control, ratio: ratio, from: volume, to: volume, result: "skipped")
            return false
        }
        let actualControl: OutputDuckingControl = useMute ? .mute : device.control
        let recordedAt = scheduler.wallTime
        persist(.init(uid: device.uid, transport: device.transport, control: actualControl,
                      original: original, ducked: target, recordedAt: recordedAt))
        generation &+= 1
        session = Session(device: device, original: original, target: target, ratio: ratio,
                          startedAt: scheduler.now, recordedAt: recordedAt, usingMute: useMute,
                          expected: original, rampFrom: original)
        startRampDown()
        scheduleHardDeadline()
        return session != nil
    }

    /// A neutral stop/keep gets an 0.8 s reuse window before a 0.2 s restore.
    public func release() {
        guard var current = session else { return }
        current.held = false
        session = current
        generation &+= 1
        let token = generation
        scheduler.after(seconds: 0.8) { [weak self] in
            guard let self, self.generation == token, var current = self.session, !current.held else { return }
            current.rampFrom = current.expected
            self.session = current
            for step in 1...5 {
                self.scheduler.after(seconds: Double(step) * 0.04) { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.restoreStep(step)
                }
            }
        }
    }

    /// The audio cue must not start until this immediate write attempt has returned.
    public func restoreForCue() { restoreImmediately(reason: "restored") }
    public func forceRestore() { restoreImmediately(reason: "restored") }
    public func defaultOutputChanged() { restoreImmediately(reason: "deviceChanged") }

    /// NSEvent subtype 8 (volume up/down/mute): the user owns their setting immediately.
    public func userChanged() {
        guard let current = session else { generation &+= 1; return }
        generation &+= 1
        session = nil
        persist(nil)
        traceRestore("userChanged", session: current, recheck: false)
    }

    /// If the old device is unavailable, leave the record for a safe reconnect within ten minutes.
    @discardableResult
    public func recover(_ record: OutputDuckingRecoveryRecord, on device: (any OutputDuckingDevice)?) -> Bool {
        let age = scheduler.wallTime - record.recordedAt
        guard age.isFinite, age >= 0, age <= 600 else {
            persist(nil)
            trace("output duck restore result=skipped heldMs=0 recheck=0")
            return false
        }
        guard let device, device.isConnected, device.uid == record.uid else { return false }
        guard let current = device.read(), near(current, record.ducked, tolerance: 0.02) else {
            persist(nil)
            trace("output duck restore result=userChanged heldMs=\(Int(age * 1000)) recheck=0")
            return false
        }
        guard writeChecked(device: device, target: record.original) else { return false }
        persist(nil)
        generation &+= 1
        trace("output duck restore result=recovered heldMs=\(Int(age * 1000)) recheck=0")
        scheduleBluetoothRecheck(device: device, original: record.original, ducked: record.ducked,
                                 since: scheduler.now - age)
        return true
    }

    private func startRampDown() {
        guard let s = session else { return }
        let token = generation
        if s.usingMute {
            downStep(5)
        } else {
            downStep(1)
            for step in 2...5 {
                scheduler.after(seconds: Double(step - 1) * 0.025) { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.downStep(step)
                }
            }
        }
    }

    private func downStep(_ step: Int) {
        guard var current = session, current.held else { return }
        let device = current.device
        guard device.isConnected else { restoreImmediately(reason: "deviceGone"); return }
        if userRaised(device: device, expected: current.expected) { userChanged(); return }
        let next = interpolate(current.rampFrom, current.target, fraction: Double(step) / 5)
        guard device.write(next) else { failDucking("notSettable", session: current); return }
        guard let readback = device.read(), near(readback, next, tolerance: 0.02) else {
            failDucking("notEffective", session: current); return
        }
        current.expected = next
        if step == 5, !current.beginLogged {
            current.beginLogged = true
            traceBegin(device: device, control: current.usingMute ? .mute : device.control,
                       ratio: current.ratio, from: representative(current.original),
                       to: representative(current.target), result: "ok")
        }
        session = current
    }

    private func failDucking(_ result: String, session failed: Session) {
        fusedUIDs.insert(failed.device.uid)
        generation &+= 1
        session = nil
        // A late or ineffective step must never leave behind a knowingly reduced volume.
        let restored = writeChecked(device: failed.device, target: failed.original)
        if restored { persist(nil) }
        traceBegin(device: failed.device, control: failed.usingMute ? .mute : failed.device.control,
                   ratio: failed.ratio, from: representative(failed.original),
                   to: representative(failed.target), result: result)
        traceRestore(restored ? "restored" : "skipped", session: failed, recheck: false)
    }

    private func scheduleHardDeadline() {
        guard let current = session, current.held else { return }
        let token = generation
        let remaining = max(0, 120 - (scheduler.now - current.startedAt))
        scheduler.after(seconds: remaining) { [weak self] in
            guard let self, self.generation == token else { return }
            self.restoreImmediately(reason: "restored")
        }
    }

    private func restoreStep(_ step: Int) {
        guard var current = session, !current.held else { return }
        guard current.device.isConnected else { restoreImmediately(reason: "deviceGone"); return }
        if userRaised(device: current.device, expected: current.expected) { userChanged(); return }
        let next = interpolate(current.rampFrom, current.original, fraction: Double(step) / 5)
        guard writeChecked(device: current.device, target: next) else {
            // The failed write may have partly raised the volume. It was our write,
            // not a user change: attempt the original directly, without takeover inference.
            let restored = writeChecked(device: current.device, target: current.original)
            if restored {
                finishRestore(current, reason: "restored")
            } else {
                generation &+= 1; session = nil // Keep recovery record for reconnect/startup.
                traceRestore(current.device.isConnected ? "skipped" : "deviceGone", session: current, recheck: false)
            }
            return
        }
        current.expected = next
        session = current
        if step == 5 { finishRestore(current, reason: "restored") }
    }

    private func restoreImmediately(reason: String) {
        guard let current = session else { return }
        if !current.device.isConnected {
            generation &+= 1; session = nil
            traceRestore("deviceGone", session: current, recheck: false)
            return // Keep crash/reconnect recovery record.
        }
        if userRaised(device: current.device, expected: current.expected) {
            userChanged()
            return
        }
        let restored = writeChecked(device: current.device, target: current.original)
        if restored {
            finishRestore(current, reason: reason)
        } else {
            generation &+= 1; session = nil
            traceRestore("skipped", session: current, recheck: false)
        }
    }

    private func finishRestore(_ current: Session, reason: String) {
        if !current.beginLogged {
            traceBegin(device: current.device, control: current.usingMute ? .mute : current.device.control,
                       ratio: current.ratio, from: representative(current.original),
                       to: representative(current.target), result: "ok")
        }
        generation &+= 1
        session = nil
        persist(nil)
        traceRestore(reason, session: current, recheck: false)
        scheduleBluetoothRecheck(device: current.device, original: current.original,
                                 ducked: current.target, since: current.startedAt)
    }

    private func scheduleBluetoothRecheck(device: any OutputDuckingDevice, original: OutputDuckingReading,
                                          ducked: OutputDuckingReading, since: TimeInterval) {
        guard device.transport == .bluetooth else { return }
        let token = generation
        scheduler.after(seconds: 1) { [weak self] in
            guard let self, self.generation == token, device.isConnected,
                  let current = device.read(), self.near(current, ducked, tolerance: 0.02) else { return }
            _ = self.writeChecked(device: device, target: original) // Exactly one corrective attempt.
            self.trace("output duck restore result=recovered heldMs=\(self.heldMilliseconds(since)) recheck=1")
        }
    }

    private func writeChecked(device: any OutputDuckingDevice, target: OutputDuckingReading) -> Bool {
        guard device.isConnected, device.write(target), let actual = device.read() else { return false }
        return near(actual, target, tolerance: 0.02)
    }

    private func near(_ lhs: OutputDuckingReading, _ rhs: OutputDuckingReading, tolerance: Double) -> Bool {
        lhs.muted == rhs.muted && lhs.levels.count == rhs.levels.count &&
            zip(lhs.levels, rhs.levels).allSatisfy { abs($0.0 - $0.1) <= tolerance }
    }

    private func userRaised(device: any OutputDuckingDevice, expected: OutputDuckingReading) -> Bool {
        guard let actual = device.read() else { return false }
        if device.canMute && actual.muted != expected.muted { return true }
        guard actual.levels.count == expected.levels.count else { return false }
        return zip(actual.levels, expected.levels).contains { $0.0 > $0.1 + 0.05 }
    }

    private func interpolate(_ from: OutputDuckingReading, _ to: OutputDuckingReading,
                             fraction: Double) -> OutputDuckingReading {
        let t = min(1, max(0, fraction))
        let values = zip(from.levels, to.levels).map { $0.0 + ($0.1 - $0.0) * t }
        return .init(levels: values, muted: t >= 1 ? to.muted : from.muted)
    }

    private func representative(_ reading: OutputDuckingReading) -> Double {
        if reading.muted { return 0 }
        guard !reading.levels.isEmpty else { return 1 }
        return reading.levels.reduce(0, +) / Double(reading.levels.count)
    }

    private func ratioText(_ ratio: Double) -> String { String(format: "%.1f", ratio) }
    private func heldMilliseconds(_ started: TimeInterval) -> Int {
        Int(max(0, scheduler.now - started) * 1000)
    }
    private func traceBegin(device: any OutputDuckingDevice, control: OutputDuckingControl,
                            ratio: Double, from: Double, to: Double, result: String) {
        trace("output duck begin transport=\(device.transport.rawValue) control=\(control.rawValue) ratio=\(ratioText(ratio)) from=\(String(format: "%.2f", from)) to=\(String(format: "%.2f", to)) result=\(result)")
    }
    private func traceRestore(_ result: String, session current: Session, recheck: Bool) {
        trace("output duck restore result=\(result) heldMs=\(heldMilliseconds(current.startedAt)) recheck=\(recheck ? 1 : 0)")
    }
}
