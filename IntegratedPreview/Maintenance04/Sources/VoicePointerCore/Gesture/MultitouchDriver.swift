import CMultitouchSupport
import Foundation

public enum TouchDeviceKind: String, Sendable {
    case unknown
    case builtInTrackpad
    case magicMouse
    case externalTrackpad
}

public struct TouchDeviceInfo: Sendable, Equatable {
    public let token: UInt
    public let kind: TouchDeviceKind
    public let familyID: Int32
    public let sensorRows: Int32
    public let sensorColumns: Int32
    public let touchCount: Int32
    public let lastFrameAgeSeconds: Double
    public let callbackCount: UInt64
    public let rawTouchCount: Int32
    public let stageMask: UInt32
    public let directionalDisplacement: CGPoint
    public var minDensity: Float = 0
    /// Read-only ID from the IORegistry service belonging to this MT device.
    /// Zero means unavailable; haptics must use the system fallback.
    public let deviceID: UInt64

    init(token: UInt, kind: TouchDeviceKind, familyID: Int32, sensorRows: Int32,
         sensorColumns: Int32, touchCount: Int32, lastFrameAgeSeconds: Double,
         callbackCount: UInt64, rawTouchCount: Int32, stageMask: UInt32,
         directionalDisplacement: CGPoint, minDensity: Float = 0, deviceID: UInt64 = 0) {
        self.token = token; self.kind = kind; self.familyID = familyID
        self.sensorRows = sensorRows; self.sensorColumns = sensorColumns
        self.touchCount = touchCount; self.lastFrameAgeSeconds = lastFrameAgeSeconds
        self.callbackCount = callbackCount; self.rawTouchCount = rawTouchCount
        self.stageMask = stageMask; self.directionalDisplacement = directionalDisplacement
        self.minDensity = minDensity; self.deviceID = deviceID
    }
}

public struct GestureMatch: Sendable, Equatable {
    public let deviceToken: UInt
    public let deviceKind: TouchDeviceKind
    public let touchCount: Int
    public let newestTouchAgeSeconds: Double
    public let oldestTouchAgeSeconds: Double
    public let maximumMovement: Float

    public init(
        deviceToken: UInt,
        deviceKind: TouchDeviceKind,
        touchCount: Int,
        newestTouchAgeSeconds: Double,
        oldestTouchAgeSeconds: Double? = nil,
        maximumMovement: Float
    ) {
        self.deviceToken = deviceToken
        self.deviceKind = deviceKind
        self.touchCount = touchCount
        self.newestTouchAgeSeconds = newestTouchAgeSeconds
        self.oldestTouchAgeSeconds = oldestTouchAgeSeconds ?? newestTouchAgeSeconds
        self.maximumMovement = maximumMovement
    }
}

public final class MultitouchDriver: @unchecked Sendable {
    public var magicMousePresent: Bool { devices.contains { $0.kind == .magicMouse } }
    private let decisionLock = NSLock()
    private var pendingMouseDecision: TouchSampleDecisionFrame?

    public var mouseDecisionTrace: String {
        decisionLock.withLock {
            guard let d = pendingMouseDecision?.decision else { return "need=-1 skewMs=-1 reason=touchCount edge=0" }
            let reason: String
            switch d.reason {
            case .passed: reason = "none"
            case .landingSkew: reason = "skew"
            case .freshWindow, .frameExpired: reason = "fresh"
            case .density: reason = "density"
            case .movement: reason = "movement"
            case .touchCount: reason = "touchCount"
            }
            let skew = d.skewSeconds.map { $0 * 1000 } ?? -1
            let edge = pendingMouseDecision?.snapshot.points.filter { $0.stage == 4 && $0.edge == true }.count ?? 0
            return "need=\(d.threshold.isFinite ? d.threshold : -1) skewMs=\(skew.isFinite ? skew : -1) reason=\(reason) edge=\(edge)"
        }
    }

    /// A down callback consumes the frozen gate result once, without another
    /// evaluation or a subsequent read of current contacts. No history I/O.
    public func takeLatestMouseDecision() -> TouchSampleDecisionFrame? {
        decisionLock.withLock {
            defer { pendingMouseDecision = nil }
            return pendingMouseDecision
        }
    }

    public func recordLatestMouseDown(button: PhysicalMouseButton, configuration: GestureConfiguration,
                                      recorder: TouchSampleRecorder) {
        guard let frame = takeLatestMouseDecision() else { return }
        recorder.updateDecision(frame.decision, snapshot: frame.snapshot)
        recorder.recordDown(button: button, frame: frame, configuration: configuration)
    }

    public func touchSnapshot(deviceIndex: Int) -> TouchSurfaceSnapshot? {
        var raw = VPTouchSnapshot()
        guard VPCopyTouchSnapshot(Int32(deviceIndex), &raw) else { return nil }
        return Self.surfaceSnapshot(raw)
    }
    private static func surfaceSnapshot(_ raw: VPTouchSnapshot) -> TouchSurfaceSnapshot {
        let points = withUnsafeBytes(of: raw.points) { bytes in
            Array(bytes.bindMemory(to: VPTouchSnapshotPoint.self).prefix(max(0, min(6, Int(raw.count))))).map {
                func finite(_ f: Float) -> Float { f.isFinite ? f : 0 }
                return TouchSamplePoint(stage: max(0, min(31, Int($0.stage))), x: min(1, max(0, finite($0.x))), y: min(1, max(0, finite($0.y))),
                    major: max(0, finite($0.major)), minor: max(0, finite($0.minor)), size: max(0, finite($0.size)), density: finite($0.density), edge: $0.edge)
            }
        }
        return TouchSurfaceSnapshot(deviceToken: raw.deviceToken, points: points,
            frameAgeSeconds: raw.frameAgeSeconds, newestTouchAgeSeconds: raw.newestTouchAgeSeconds,
            oldestTouchAgeSeconds: raw.oldestTouchAgeSeconds, maximumMovement: raw.maximumMovement)
    }
    public var magicMouseSnapshot: TouchSurfaceSnapshot? {
        guard let index = devices.firstIndex(where: { $0.kind == .magicMouse }) else { return nil }
        return touchSnapshot(deviceIndex: index)
    }
    private enum LifecycleState {
        case stopped
        case starting
        case started
        case stopping
        case reloading

        var isTransitioning: Bool {
            switch self {
            case .starting, .stopping, .reloading: return true
            case .stopped, .started: return false
            }
        }
    }

    private let lifecycle = NSCondition()
    private var lifecycleState: LifecycleState = .stopped
    private var testState = false
    public var isTestingTouchState: Bool { lifecycle.withLock { testState } }
    private let transitionWaitSeconds: TimeInterval = 2

    /// A wedged private-framework call retains the transition lease. Do not
    /// start another C call on top of it; callers fail closed after the bound.
    private func waitForTransition() -> Bool {
        let deadline = Date().addingTimeInterval(transitionWaitSeconds)
        while lifecycleState.isTransitioning {
            guard lifecycle.wait(until: deadline) else {
                RuntimeTrace.record("touch lifecycle wait timed out")
                return false
            }
        }
        return true
    }

    public init() {
        let defaults = GestureConfiguration()
        VPSetMagicMouseEdgeFilter(defaults.magicMouseEdgeMargin, defaults.magicMouseEdgeMaxMinor)
    }

    @discardableResult
    public func start() -> Bool {
        lifecycle.lock()
        guard waitForTransition() else { lifecycle.unlock(); return false }
        guard lifecycleState != .started else {
            lifecycle.unlock()
            return true
        }
        lifecycleState = .starting
        lifecycle.unlock()
        var result = false
        defer {
            lifecycle.lock()
            lifecycleState = result ? .started : .stopped
            lifecycle.broadcast()
            lifecycle.unlock()
        }

        // MultitouchSupport may synchronously drain a callback. Never hold the
        // Swift lifecycle lock while entering the private framework.
        result = VPStartTouchDriver()
        return result
    }

    public func stop() {
        lifecycle.lock()
        guard waitForTransition() else { lifecycle.unlock(); return }
        guard lifecycleState == .started else {
            lifecycle.unlock()
            return
        }
        lifecycleState = .stopping
        lifecycle.unlock()
        defer {
            lifecycle.lock()
            lifecycleState = .stopped
            lifecycle.broadcast()
            lifecycle.unlock()
        }

        VPStopTouchDriver()
    }

    @discardableResult
    public func reload() -> Bool {
        lifecycle.lock()
        guard waitForTransition() else { lifecycle.unlock(); return false }
        guard lifecycleState == .started else {
            lifecycle.unlock()
            return false
        }
        lifecycleState = .reloading
        lifecycle.unlock()
        var result = false
        defer {
            lifecycle.lock()
            lifecycleState = result ? .started : .stopped
            lifecycle.broadcast()
            lifecycle.unlock()
        }

        result = VPReloadTouchDevices()
        return result
    }

    public var status: String {
        var buffer = [CChar](repeating: 0, count: 256)
        let copied = buffer.withUnsafeMutableBufferPointer { rawBuffer in
            VPCopyTouchDriverStatus(rawBuffer.baseAddress, rawBuffer.count)
        }
        guard copied else {
            return "Touch driver unavailable"
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public var devices: [TouchDeviceInfo] {
        let count = max(0, Int(VPGetTouchDeviceCount()))
        return (0..<count).compactMap { index in
            var raw = VPDeviceInfo()
            guard VPCopyTouchDeviceInfo(Int32(index), &raw) else { return nil }
            return TouchDeviceByRaw.info(raw)
        }
    }

    public var connectedServiceCount: Int {
        Int(VPGetConnectedMultitouchServiceCount())
    }

    public func consumeEligibleGesture(
        configuration: GestureConfiguration,
        maximumFrameAgeSeconds: Double = 0.15,
        consume: Bool = true
    ) -> GestureMatch? {
        var raw = VPGestureMatch()
        VPSetMagicMouseEdgeFilter(configuration.magicMouseEdgeMargin, configuration.magicMouseEdgeMaxMinor)
        var decision = VPMouseDecision()
        let passed = VPConsumeEligibleGesture(
            Int32(configuration.magicMouseFingerCount),
            Int32(configuration.trackpadFingerCount),
            Double(configuration.freshChordWindowMilliseconds) / 1_000,
            Double(configuration.magicMouseFreshChordWindowMilliseconds) / 1_000,
            configuration.maximumTouchMovement,
            maximumFrameAgeSeconds,
            configuration.trackpadEnabled,
            configuration.magicMouseMinDensity,
            Double(configuration.magicMouseMaxLandingSkewMilliseconds) / 1_000,
            Double(configuration.magicMouseFastLandingMilliseconds) / 1_000,
            configuration.magicMouseSlowMinDensity,
            consume,
            &raw,
            &decision
        )
        let frame: TouchSampleDecisionFrame? = decision.deviceIndex >= 0 ? .init(
            decision: .init(reason: TouchSampleDecision(rawValue: Int(decision.reason.rawValue)) ?? .touchCount,
                minDensity: decision.minDensity, threshold: decision.requiredDensity,
                skewSeconds: decision.skewSeconds, oldestAgeSeconds: decision.oldestAgeSeconds,
                retriedWithoutLift: decision.retriedWithoutLift),
            snapshot: Self.surfaceSnapshot(decision.snapshot)) : nil
        decisionLock.withLock { pendingMouseDecision = frame }
        guard passed else { return nil }
        return GestureMatch(
            deviceToken: raw.deviceToken,
            deviceKind: TouchDeviceByRaw.kind(raw.deviceKind),
            touchCount: Int(raw.touchCount),
            newestTouchAgeSeconds: raw.newestTouchAgeSeconds,
            oldestTouchAgeSeconds: raw.oldestTouchAgeSeconds,
            maximumMovement: raw.maximumMovement
        )
    }

    /// Normalized surface displacement for the active/most recently released
    /// chord. Positive Y follows the device surface toward the display.
    public func directionalDisplacement(deviceToken: UInt) -> CGPoint? {
        devices.first(where: { $0.token == deviceToken })?.directionalDisplacement
    }

    @_spi(Testing)
    @discardableResult
    public func resetTestTouchState() -> Bool {
        let result = VPTestResetTouchState()
        if result { lifecycle.withLock { testState = true } }
        return result
    }

    @_spi(Testing)
    public func injectTestTouchState(
        kind: TouchDeviceKind,
        touchCount: Int,
        frameAgeSeconds: Double,
        newestTouchAgeSeconds: Double = 0,
        oldestTouchAgeSeconds: Double? = nil,
        maximumMovement: Float = 0,
        minDensity: Float = 2
    ) {
        VPTestInjectTouchState(
            TouchDeviceByRaw.rawKind(kind),
            Int32(touchCount),
            frameAgeSeconds,
            newestTouchAgeSeconds,
            oldestTouchAgeSeconds ?? newestTouchAgeSeconds,
            maximumMovement,
            minDensity
        )
    }
    @_spi(Testing)
    public func setTestMinDensity(_ value: Float) -> Bool { VPTestSetMinDensity(value) }

    @_spi(Testing)
    @discardableResult
    public func injectTestTouchDisplacement(
        kind: TouchDeviceKind,
        x: Float,
        y: Float
    ) -> Bool {
        VPTestSetTouchDisplacement(TouchDeviceByRaw.rawKind(kind), x, y)
    }
}

private enum TouchDeviceByRaw {
    static func kind(_ raw: VPDeviceKind) -> TouchDeviceKind {
        switch raw {
        case VPDeviceKindBuiltInTrackpad: return .builtInTrackpad
        case VPDeviceKindMagicMouse: return .magicMouse
        case VPDeviceKindExternalTrackpad: return .externalTrackpad
        default: return .unknown
        }
    }

    static func rawKind(_ kind: TouchDeviceKind) -> VPDeviceKind {
        switch kind {
        case .builtInTrackpad: return VPDeviceKindBuiltInTrackpad
        case .magicMouse: return VPDeviceKindMagicMouse
        case .externalTrackpad: return VPDeviceKindExternalTrackpad
        case .unknown: return VPDeviceKindUnknown
        }
    }

    static func info(_ raw: VPDeviceInfo) -> TouchDeviceInfo {
        TouchDeviceInfo(
            token: raw.token,
            kind: kind(raw.kind),
            familyID: raw.familyID,
            sensorRows: raw.sensorRows,
            sensorColumns: raw.sensorColumns,
            touchCount: raw.touchCount,
            lastFrameAgeSeconds: raw.lastFrameAgeSeconds,
            callbackCount: raw.callbackCount,
            rawTouchCount: raw.rawTouchCount,
            stageMask: raw.stageMask,
            directionalDisplacement: CGPoint(
                x: CGFloat(raw.directionalDisplacementX),
                y: CGFloat(raw.directionalDisplacementY)
            ), minDensity: raw.minDensity, deviceID: raw.deviceID
        )
    }
}
