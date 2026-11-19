import AppKit
import Darwin
import Foundation

public enum HapticStrength: String, CaseIterable, Codable, Sendable {
    case standard, strong, max
}

public enum HapticZone: String, Sendable {
    case send, center, cancel
}

public struct HapticPulse: Equatable, Sendable {
    public let id: Int32
    public let delayMilliseconds: Int
}

public enum HapticPulsePlan {
    /// ID zero means the system levelChange pattern. Delays are relative to
    /// the first pulse, so the final max/cancel pulse falls at 90 ms.
    public static func pulses(zone: HapticZone, strength: HapticStrength, privatePath: Bool) -> [HapticPulse] {
        func pulse(_ id: Int32, _ ms: Int = 0) -> HapticPulse { .init(id: id, delayMilliseconds: ms) }
        guard strength != .standard else { return [pulse(0)] }
        if !privatePath {
            if zone == .center { return [pulse(0)] }
            return strength == .strong ? [pulse(0), pulse(0, 45)] : [pulse(0), pulse(0, 40), pulse(0, 80)]
        }
        switch (strength, zone) {
        case (.strong, .send): return [pulse(6)]
        case (.strong, .center): return [pulse(1)]
        case (.strong, .cancel): return [pulse(6), pulse(6, 60)]
        case (.max, .send): return [pulse(6), pulse(2, 35)]
        case (.max, .center): return [pulse(4)]
        case (.max, .cancel): return [pulse(6), pulse(6, 45), pulse(2, 90)]
        case (.standard, _): return [pulse(0)]
        }
    }
}

/// Read by the private queue immediately before entering Actuate. No framework
/// call occurs while its small cancellation lock is held.
public final class HapticPulseLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
}

@MainActor
public protocol HapticActuatorPerforming: AnyObject {
    func open(deviceID: UInt64, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func actuate(id: Int32, lease: HapticPulseLease, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func close()
}

/// All private framework calls, including symbol loading, occur on one serial
/// queue. The five-symbol bundle is all-or-nothing; incomplete ABI is fallback.
@MainActor
public final class PrivateHapticActuator: HapticActuatorPerforming {
    private let worker: HapticActuatorWorker
    public init() { worker = HapticActuatorWorker() }
    // Internal injection exercises the queue/return-code paths without loading
    // the framework or touching hardware. Production resolves all five symbols.
    init(symbols: HapticActuatorWorker.Symbols) { worker = HapticActuatorWorker(symbols: symbols) }
    public func open(deviceID: UInt64, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        worker.open(deviceID: deviceID, completion: completion)
    }
    public func actuate(id: Int32, lease: HapticPulseLease, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        worker.actuate(id: id, lease: lease, completion: completion)
    }
    public func close() { worker.close() }
}

final class HapticActuatorWorker: @unchecked Sendable {
    private typealias Create = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias Open = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias Actuate = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    private typealias Close = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias IsOpen = @convention(c) (UnsafeMutableRawPointer) -> Bool
    struct Symbols {
        let create: (UInt64) -> UnsafeMutableRawPointer?
        let open: (UnsafeMutableRawPointer) -> Int32
        let actuate: (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
        let close: (UnsafeMutableRawPointer) -> Int32
        let isOpen: (UnsafeMutableRawPointer) -> Bool
    }
    private let queue = DispatchQueue(label: "com.kenyu.voicepointer.haptic-actuator", qos: .userInteractive)
    private var framework: UnsafeMutableRawPointer?
    private var symbols: Symbols?
    private var loaded = false
    private var actuator: UnsafeMutableRawPointer?

    init(symbols: Symbols? = nil) {
        self.symbols = symbols
        loaded = symbols != nil
    }

    private func loadSymbols() -> Symbols? {
        if loaded { return symbols }
        loaded = true
        let paths = [
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport",
            "/System/Library/PrivateFrameworks/MultitouchSupportPrivate.framework/MultitouchSupportPrivate",
            "/System/Library/PrivateFrameworks/MultitouchSupportPrivate.framework/Versions/A/MultitouchSupportPrivate"
        ]
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) { framework = handle; break }
        }
        guard let framework,
              let create = dlsym(framework, "MTActuatorCreateFromDeviceID"),
              let open = dlsym(framework, "MTActuatorOpen"),
              let actuate = dlsym(framework, "MTActuatorActuate"),
              let close = dlsym(framework, "MTActuatorClose"),
              let isOpen = dlsym(framework, "MTActuatorIsOpen") else { return nil }
        let result = Symbols(create: unsafeBitCast(create, to: Create.self),
            open: unsafeBitCast(open, to: Open.self), actuate: unsafeBitCast(actuate, to: Actuate.self),
            close: unsafeBitCast(close, to: Close.self), isOpen: unsafeBitCast(isOpen, to: IsOpen.self))
        symbols = result
        return result
    }
    private func closeOnQueue() {
        guard let actuator else { return }
        if let symbols { _ = symbols.close(actuator) }
        Unmanaged<AnyObject>.fromOpaque(actuator).release()
        self.actuator = nil
    }
    func open(deviceID: UInt64, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            closeOnQueue()
            var success = false
            if deviceID != 0, let symbols = loadSymbols(), let handle = symbols.create(deviceID) {
                actuator = handle
                success = symbols.open(handle) == 0 && symbols.isOpen(handle)
                if !success { closeOnQueue() }
            }
            Task { @MainActor in completion(success) }
        }
    }
    func actuate(id: Int32, lease: HapticPulseLease, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard !lease.isCancelled else { Task { @MainActor in completion(false) }; return }
            let success: Bool
            if let actuator, let symbols, symbols.isOpen(actuator) {
                success = symbols.actuate(actuator, id, 0, 0, 0) == 0
            } else { success = false }
            Task { @MainActor in completion(success) }
        }
    }
    func close() { queue.async { [self] in closeOnQueue() } }
}

@MainActor
public final class ZoneHapticFeedback {
    public typealias Schedule = @MainActor (Int, @escaping @MainActor @Sendable () -> Void) -> Void
    private let actuator: any HapticActuatorPerforming
    private let schedule: Schedule
    private let systemPerform: @MainActor () -> Void
    private let log: @MainActor (String) -> Void
    private var gestureID = UUID()
    private var lease = HapticPulseLease()
    private var trackpad = false
    private var privateReady = false
    private var report: Report?
    @MainActor private final class Report {
        let zone: HapticZone
        let strength: HapticStrength
        let path: String
        var ids: [Int32] = []
        var ok = true
        var logged = false
        var pending = 0
        var ended = false
        init(zone: HapticZone, strength: HapticStrength, path: String) {
            self.zone = zone; self.strength = strength; self.path = path
        }
    }

    public init(actuator: (any HapticActuatorPerforming)? = nil,
        schedule: Schedule? = nil,
        systemPerform: @escaping @MainActor () -> Void = {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }, log: @escaping @MainActor (String) -> Void = { RuntimeTrace.record($0) }) {
        self.actuator = actuator ?? PrivateHapticActuator()
        self.schedule = schedule ?? { milliseconds, action in
            Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(milliseconds)) }
                catch { return }
                action()
            }
        }
        self.systemPerform = systemPerform
        self.log = log
    }

    public func begin(deviceKind: TouchDeviceKind, deviceID: UInt64?) {
        end()
        trackpad = deviceKind == .builtInTrackpad || deviceKind == .externalTrackpad
        guard trackpad, let deviceID, deviceID != 0 else { return }
        let gesture = gestureID
        actuator.open(deviceID: deviceID) { [weak self] opened in
            guard let self, self.gestureID == gesture, self.trackpad else { return }
            self.privateReady = opened
        }
    }
    public func cancelPending() {
        lease.cancel()
        lease = HapticPulseLease()
        if let report { report.ended = true; finishReport(report) }
        report = nil
    }
    public func end() {
        cancelPending()
        gestureID = UUID()
        trackpad = false
        privateReady = false
        actuator.close()
    }
    public func trigger(zone: HapticZone, strength: HapticStrength) {
        cancelPending()
        guard trackpad else { return }
        let privatePath = strength != .standard && privateReady
        let pulses = HapticPulsePlan.pulses(zone: zone, strength: strength, privatePath: privatePath)
        let report = Report(zone: zone, strength: strength,
            path: strength == .standard ? "system" : (privatePath ? "private" : "fallback"))
        self.report = report
        let currentLease = lease
        let gesture = gestureID
        for (index, pulse) in pulses.enumerated() {
            let perform: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, self.gestureID == gesture,
                      self.lease === currentLease, !currentLease.isCancelled else { return }
                report.ids.append(pulse.id)
                if pulse.id == 0 {
                    self.systemPerform()
                } else {
                    report.pending += 1
                    self.actuator.actuate(id: pulse.id, lease: currentLease) { [weak self] ok in
                        report.pending -= 1
                        report.ok = report.ok && ok
                        guard let self else { return }
                        // A false result may also be an already cancelled
                        // queue item. Only the active zone may downgrade/replay.
                        if !ok, self.gestureID == gesture, self.trackpad,
                           self.lease === currentLease, !currentLease.isCancelled,
                           self.report === report {
                            self.privateReady = false
                            self.cancelPending()
                            self.actuator.close()
                            self.trigger(zone: report.zone, strength: report.strength)
                        }
                        self.finishReport(report)
                    }
                }
                if index == pulses.count - 1 { report.ended = true }
                self.finishReport(report)
            }
            if pulse.delayMilliseconds == 0 { perform() }
            else { schedule(pulse.delayMilliseconds, perform) }
        }
    }
    private func finishReport(_ report: Report) {
        guard report.ended, report.pending == 0, !report.logged else { return }
        report.logged = true
        let ids = report.ids.map(String.init).joined(separator: ",")
        log("hud haptic zone=\(report.zone.rawValue) level=\(report.strength.rawValue) path=\(report.path) ids=\(ids) ok=\(report.ok)")
    }
}
