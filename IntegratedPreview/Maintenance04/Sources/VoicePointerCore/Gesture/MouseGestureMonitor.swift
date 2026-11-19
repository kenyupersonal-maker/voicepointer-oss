import CoreGraphics
import Foundation

/// Marks pointer events synthesized by VoicePointer itself so the global Event
/// Tap cannot mistake a focus-fallback click for the user's physical release.
public let voicePointerSyntheticEventUserData: Int64 = 0x5650_5452

public enum PhysicalMouseButton: Sendable, Equatable {
    case left
    case right
}

public struct GestureActivation: Sendable, Equatable {
    public let location: CGPoint
    public let button: PhysicalMouseButton
    public let match: GestureMatch

    public init(location: CGPoint, button: PhysicalMouseButton, match: GestureMatch) {
        self.location = location
        self.button = button
        self.match = match
    }
}

public enum MouseGestureMonitorError: LocalizedError {
    case eventTapUnavailable

    public var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            return "无法创建全局鼠标事件监听，请开启辅助功能权限。"
        }
    }
}

private func voicePointerMouseTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MouseGestureMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

// MARK: - Recognition core

/// Shared physical-event recognition used by both monitor flavors. Keeps the
/// original gesture thresholds, touch-count eligibility and trackpad
/// displacement math unchanged; owns the swallowed-down/up pairing including
/// the rule that a canceled gesture must still consume its physical mouse-up
/// while the tap keeps listening, so no orphan release ever reaches the
/// target application.
///
/// Synchronization invariant for `@unchecked Sendable`: every mutable field
/// (`configuration`, `isEnabled`, `activeButton`, `activeContext`,
/// `lastTrackpadLocation`, `tracedMovementMask`, `pendingUnpairedButtons`,
/// `trackpadTrackingTimer`) is accessed only while holding `lock`. The
/// injected `emit` closure is invoked while `lock` is held so emissions from
/// the tap thread and the trackpad timer queue are strictly ordered; emit
/// handlers must therefore never call back into this core. `claimBegin` is
/// invoked without holding `lock`. All other injected closures are read-only
/// snapshot providers (multitouch driver reads, tracing) and may be called
/// with `lock` held; the driver's C shim serializes its own state, and the
/// driver never calls back into this core.
final class GestureRecognitionCore: @unchecked Sendable {
    enum GestureEmission: Sendable {
        case began(GestureActivation)
        case moved(CGPoint)
        case ended(CGPoint)
        case canceled
        case tapFailed
    }

    private struct ActiveGestureContext: Sendable {
        let activation: GestureActivation
        let touchBaseline: CGPoint
    }

    static let trackpadPointsPerNormalizedUnit: CGFloat = 520
    // AppKit gesture event raw types are not named in CGEventType, but they
    // can still appear at a Quartz event tap. Cover rotate/begin/end/gesture/
    // magnify/swipe/smart-magnify in addition to scrollWheel.
    static let systemGestureEventRawTypes: Set<UInt32> = [18, 19, 20, 29, 30, 31, 32]

    private let lock = NSLock()
    private var configuration: GestureConfiguration
    private var isEnabled = true
    private var activeButton: PhysicalMouseButton?
    private var activeContext: ActiveGestureContext?
    private var lastTrackpadLocation: CGPoint?
    private var tracedMovementMask: UInt8 = 0
    private var pendingUnpairedButtons: Set<PhysicalMouseButton> = []
    private var trackpadTrackingTimer: DispatchSourceTimer?

    private let timerQueue: DispatchQueue
    private let touchDevices: @Sendable () -> [TouchDeviceInfo]
    private let consumeEligibleGesture: @Sendable (GestureConfiguration) -> GestureMatch?
    private let directionalDisplacement: @Sendable (UInt) -> CGPoint?
    private let claimBegin: @Sendable (GestureActivation) -> Bool
    private let emit: @Sendable (GestureEmission) -> Bool
    private let trace: @Sendable (String) -> Void
    private let recordDown: @Sendable (PhysicalMouseButton, GestureConfiguration) -> Void
    private let recordUp: @Sendable (PhysicalMouseButton) -> Void
    private let configureRecording: @Sendable (GestureConfiguration) -> Void
    private let decisionTrace: @Sendable () -> String

    init(
        configuration: GestureConfiguration,
        timerQueue: DispatchQueue,
        touchDevices: @escaping @Sendable () -> [TouchDeviceInfo],
        consumeEligibleGesture: @escaping @Sendable (GestureConfiguration) -> GestureMatch?,
        directionalDisplacement: @escaping @Sendable (UInt) -> CGPoint?,
        claimBegin: @escaping @Sendable (GestureActivation) -> Bool,
        emit: @escaping @Sendable (GestureEmission) -> Bool,
        trace: @escaping @Sendable (String) -> Void,
        recordDown: @escaping @Sendable (PhysicalMouseButton, GestureConfiguration) -> Void = { _, _ in },
        recordUp: @escaping @Sendable (PhysicalMouseButton) -> Void = { _ in },
        configureRecording: @escaping @Sendable (GestureConfiguration) -> Void = { _ in },
        decisionTrace: @escaping @Sendable () -> String = { "" }
    ) {
        self.configuration = configuration
        self.timerQueue = timerQueue
        self.touchDevices = touchDevices
        self.consumeEligibleGesture = consumeEligibleGesture
        self.directionalDisplacement = directionalDisplacement
        self.claimBegin = claimBegin
        self.emit = emit
        self.trace = trace
        self.recordDown = recordDown
        self.recordUp = recordUp
        self.configureRecording = configureRecording
        self.decisionTrace = decisionTrace
        configureRecording(configuration)
    }

    deinit {
        trackpadTrackingTimer?.cancel()
    }

    func update(configuration: GestureConfiguration) {
        lock.withLock { self.configuration = configuration }
        configureRecording(configuration)
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        let hadActive = activeButton != nil
        if !enabled, hadActive {
            let button = activeButton
            clearActiveStateLocked()
            if let button { pendingUnpairedButtons.insert(button) }
            _ = emit(.canceled)
        }
        lock.unlock()
    }

    func cancelActiveGesture() {
        lock.lock()
        guard let button = activeButton else {
            lock.unlock()
            return
        }
        clearActiveStateLocked()
        pendingUnpairedButtons.insert(button)
        _ = emit(.canceled)
        lock.unlock()
    }

    /// Processes one tap event. Returns nil when the event is claimed
    /// (swallowed or rewritten for pass-through, callers rewrite in place).
    func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let result = processGesture(type: type, event: event)
        CaretMovementIntentClock.shared.observe(type: type, passedThrough: result != nil,
            syntheticMarker: event.getIntegerValueField(.eventSourceUserData),
            keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        if result != nil,
           EditingIntentClock.shouldAdvance(
               type: type, passedThrough: true,
               syntheticMarker: event.getIntegerValueField(.eventSourceUserData)
           ) {
            EditingIntentClock.shared.advance()
        }
        return result
    }

    private func processGesture(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == voicePointerSyntheticEventUserData {
            return .passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A disabled tap is a permission/runtime failure. Re-enabling from
            // inside the callback can spin WindowServer indefinitely. Let the
            // application own the one serialized stop path.
            cancelActiveGesture()
            _ = emit(.tapFailed)
            return .passUnretained(event)
        }

        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            cancelActiveGesture()
            return .passUnretained(event)
        }

        // macOS may translate a three-finger trackpad motion into system
        // gestures (Mission Control, Spaces, window overview). Once this
        // monitor has accepted the physical chord, those derived events
        // belong to VoicePointer and must not reach the system. Unmatched
        // trackpad gestures continue through normally.
        if type == .scrollWheel || Self.systemGestureEventRawTypes.contains(type.rawValue) {
            let shouldSuppress = lock.withLock {
                activeContext?.activation.match.deviceKind.isTrackpad == true
            }
            if shouldSuppress { return nil }
        }

        // Some macOS/device combinations report movement as mouseMoved after
        // the initiating mouseDown has been suppressed by this Event Tap.
        // Observe that fallback so the radial HUD still tracks the gesture,
        // while passing it through to preserve normal cursor movement.
        if type == .mouseMoved {
            return lock.withLock { () -> Unmanaged<CGEvent>? in
                guard activeButton != nil else { return .passUnretained(event) }
                let shouldTrace = tracedMovementMask & 0x1 == 0
                tracedMovementMask |= 0x1
                if let context = activeContext {
                    if shouldTrace {
                        trace(
                            "mouseMove active type=mouseMoved x=\(Int(event.location.x)) y=\(Int(event.location.y))"
                        )
                    }
                    if !context.activation.match.deviceKind.isTrackpad {
                        _ = emit(.moved(event.location))
                    }
                }
                return .passUnretained(event)
            }
        }

        let incomingButton: PhysicalMouseButton?
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: incomingButton = .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: incomingButton = .right
        default: incomingButton = nil
        }
        guard let incomingButton else { return .passUnretained(event) }

        if type == .leftMouseUp || type == .rightMouseUp {
            recordUp(incomingButton)
            return lock.withLock { () -> Unmanaged<CGEvent>? in
                if activeButton == incomingButton {
                    var resolvedLocation = event.location
                    if let context = activeContext {
                        var location = effectiveLocationLocked(
                            for: context,
                            physicalLocation: event.location
                        )
                        if context.activation.match.deviceKind.isTrackpad,
                           let tracked = lastTrackpadLocation {
                            location = tracked
                        }
                        resolvedLocation = location
                    }
                    trace(
                        "mouseUp matched button=\(incomingButton.traceName) " +
                        "physical=\(Int(event.location.x)),\(Int(event.location.y)) " +
                        "resolved=\(Int(resolvedLocation.x)),\(Int(resolvedLocation.y))"
                    )
                    clearActiveStateLocked()
                    _ = emit(.ended(resolvedLocation))
                    return nil
                }
                if pendingUnpairedButtons.remove(incomingButton) != nil {
                    // A down we swallowed was canceled earlier; consume its up
                    // so the target application never sees an orphan release.
                    return nil
                }
                return .passUnretained(event)
            }
        }

        if type == .leftMouseDragged || type == .rightMouseDragged {
            return lock.withLock { () -> Unmanaged<CGEvent>? in
                guard activeButton == incomingButton else {
                    return .passUnretained(event)
                }
                let shouldTrace = tracedMovementMask & 0x2 == 0
                tracedMovementMask |= 0x2
                if shouldTrace {
                    trace(
                        "mouseMove active type=\(type == .leftMouseDragged ? "leftDragged" : "rightDragged") " +
                        "x=\(Int(event.location.x)) y=\(Int(event.location.y))"
                    )
                }
                if let context = activeContext,
                   !context.activation.match.deviceKind.isTrackpad {
                    _ = emit(.moved(event.location))
                }
                // Keep the cursor moving, but strip drag semantics so the target
                // application cannot select text or drag UI behind the HUD.
                event.type = .mouseMoved
                return .passUnretained(event)
            }
        }

        // mouseDown: a fresh physical down cancels any pairing debt for that
        // button (downs and ups alternate, so the earlier up already happened).
        lock.lock()
        pendingUnpairedButtons.remove(incomingButton)
        let settings: GestureConfiguration?
        if isEnabled, activeButton == nil {
            settings = configuration
        } else {
            settings = nil
        }
        lock.unlock()
        guard let settings else {
            recordDown(incomingButton, lock.withLock { configuration })
            trace("mouseDown ignored monitor-disabled")
            return .passUnretained(event)
        }
        let devices = touchDevices()
        let candidate = consumeEligibleGesture(settings)
        trace(
            "mouseDown button=\(incomingButton.traceName) " +
            devices.map(\.traceSummary).joined(separator: " | ") + " " + decisionTrace()
        )
        recordDown(incomingButton, settings)
        guard let match = candidate else {
            trace("gesture rejected no-eligible-touch-state")
            return .passUnretained(event)
        }
        let activation = GestureActivation(location: event.location, button: incomingButton, match: match)
        let touchBaseline = directionalDisplacement(match.deviceToken) ?? .zero
        lock.lock()
        let accepted: Bool
        if isEnabled, activeButton == nil {
            activeButton = incomingButton
            activeContext = ActiveGestureContext(
                activation: activation,
                touchBaseline: touchBaseline
            )
            lastTrackpadLocation = nil
            tracedMovementMask = 0
            accepted = true
        } else {
            accepted = false
        }
        lock.unlock()
        guard accepted else { return .passUnretained(event) }
        trace(
            "gesture accepted device=\(match.deviceKind.rawValue) touches=\(match.touchCount) " +
            "ageRange=\(String(format: "%.4f", match.newestTouchAgeSeconds))-" +
            "\(String(format: "%.4f", match.oldestTouchAgeSeconds)) " +
            "preMovement=\(String(format: "%.4f", match.maximumMovement))"
        )
        let claimed = claimBegin(activation)
        guard claimed else {
            lock.lock()
            if activeButton == incomingButton { activeButton = nil }
            activeContext = nil
            lastTrackpadLocation = nil
            tracedMovementMask = 0
            lock.unlock()
            trace("gesture rejected consumer-busy")
            return .passUnretained(event)
        }
        lock.lock()
        if !emit(.began(activation)) {
            // Overflow revoked the gesture before it existed for the
            // consumer: release the physical down instead of swallowing it.
            clearActiveStateLocked()
            lock.unlock()
            return .passUnretained(event)
        }
        lock.unlock()
        startTrackpadTrackingIfNeeded()
        return nil
    }

    /// Exercises the trackpad polling path without waiting for the 16 ms timer.
    func emitTrackpadMovement() {
        lock.lock()
        defer { lock.unlock() }
        guard let context = activeContext,
              context.activation.match.deviceKind.isTrackpad else { return }
        let location = effectiveLocationLocked(
            for: context,
            physicalLocation: context.activation.location
        )
        guard let active = activeContext,
              active.activation.match.deviceToken == context.activation.match.deviceToken else {
            return
        }
        if let previous = lastTrackpadLocation,
           hypot(previous.x - location.x, previous.y - location.y) < 0.5 {
            return
        }
        lastTrackpadLocation = location
        _ = emit(.moved(location))
    }

    // MARK: - Internals

    private func clearActiveStateLocked() {
        activeButton = nil
        activeContext = nil
        lastTrackpadLocation = nil
        if let timer = trackpadTrackingTimer {
            timer.cancel()
            trackpadTrackingTimer = nil
        }
        tracedMovementMask = 0
    }

    private func effectiveLocationLocked(
        for context: ActiveGestureContext,
        physicalLocation: CGPoint
    ) -> CGPoint {
        guard context.activation.match.deviceKind.isTrackpad,
              let current = directionalDisplacement(
                  context.activation.match.deviceToken
              ) else { return physicalLocation }
        let delta = CGPoint(
            x: current.x - context.touchBaseline.x,
            y: current.y - context.touchBaseline.y
        )
        return CGPoint(
            x: context.activation.location.x + delta.x * Self.trackpadPointsPerNormalizedUnit,
            y: context.activation.location.y - delta.y * Self.trackpadPointsPerNormalizedUnit
        )
    }

    private func startTrackpadTrackingIfNeeded() {
        let shouldStart = lock.withLock {
            activeContext?.activation.match.deviceKind.isTrackpad == true && trackpadTrackingTimer == nil
        }
        guard shouldStart else { return }

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.emitTrackpadMovement() }
        let installed = lock.withLock { () -> Bool in
            guard activeContext?.activation.match.deviceKind.isTrackpad == true,
                  trackpadTrackingTimer == nil else { return false }
            trackpadTrackingTimer = timer
            return true
        }
        if installed { timer.resume() }
        else { timer.cancel() }
    }
}

// MARK: - Legacy monitor (compat interface, dedicated tap worker)

/// Original monitor interface preserved for diagnostics. Production uses
/// OrderedMouseGestureMonitor; neither path installs a tap on the main loop.
public final class MouseGestureMonitor: @unchecked Sendable {
    private final class TapHandle: @unchecked Sendable {
        let tap: CFMachPort
        init(_ tap: CFMachPort) { self.tap = tap }
    }
    /// Return true when the gesture was accepted and its mouse events should
    /// be claimed; false leaves the physical click untouched.
    public typealias BeginHandler = @Sendable (GestureActivation) -> Bool
    public typealias MoveHandler = @Sendable (CGPoint) -> Void
    public typealias EndHandler = @Sendable (CGPoint) -> Void
    public typealias CancelHandler = @Sendable () -> Void
    public typealias FailureHandler = @Sendable () -> Void

    private let core: GestureRecognitionCore
    private var worker: EventTapWorker?

    public init(
        driver: MultitouchDriver,
        configuration: GestureConfiguration,
        onBegin: @escaping BeginHandler,
        onMove: @escaping MoveHandler = { _ in },
        onEnd: @escaping EndHandler,
        onCancel: @escaping CancelHandler,
        onFailure: @escaping FailureHandler = {}
    ) {
        self.core = GestureRecognitionCore(
            configuration: configuration,
            timerQueue: .main,
            touchDevices: { driver.devices },
            consumeEligibleGesture: { configuration in
                driver.consumeEligibleGesture(configuration: configuration)
            },
            directionalDisplacement: { token in
                driver.directionalDisplacement(deviceToken: token)
            },
            claimBegin: onBegin,
            emit: { emission in
                switch emission {
                case .began:
                    // onBegin already ran synchronously as the claim decision.
                    break
                case .moved(let location):
                    onMove(location)
                case .ended(let location):
                    onEnd(location)
                case .canceled:
                    onCancel()
                case .tapFailed:
                    DispatchQueue.main.async { onFailure() }
                }
                return true
            },
            trace: { RuntimeTrace.record($0) },
            recordDown: { button, c in
                guard !driver.isTestingTouchState else { return }
                driver.recordLatestMouseDown(button: button, configuration: c, recorder: TouchSampleRecorder.shared)
            },
            recordUp: { button in
                guard !driver.isTestingTouchState else { return }
                TouchSampleRecorder.shared.recordUp(button: button)
            },
            configureRecording: {
                guard !driver.isTestingTouchState else { return }
                TouchSampleRecorder.shared.configure($0)
            },
            decisionTrace: { driver.mouseDecisionTrace }
        )
    }

    deinit { stop() }

    public func update(configuration: GestureConfiguration) {
        core.update(configuration: configuration)
    }

    public func setEnabled(_ enabled: Bool) {
        core.setEnabled(enabled)
    }

    public func start() throws {
        guard worker == nil else { return }
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .mouseMoved,
            .scrollWheel,
            .keyDown,
        ]
        let namedMask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let mask = GestureRecognitionCore.systemGestureEventRawTypes.reduce(namedMask) {
            $0 | (CGEventMask(1) << $1)
        }
        let candidate = EventTapWorker(
            installer: { _, callback, userInfo in
                guard let tap = CGEvent.tapCreate(
                    tap: .cghidEventTap,
                    place: .headInsertEventTap,
                    options: .defaultTap,
                    eventsOfInterest: mask,
                    callback: callback,
                    userInfo: userInfo
                ) else { return nil }
                guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                    CFMachPortInvalidate(tap)
                    return nil
                }
                let handle = TapHandle(tap)
                return EventTapInstallation(
                    source: source,
                    enable: { CGEvent.tapEnable(tap: handle.tap, enable: true) },
                    disable: { CGEvent.tapEnable(tap: handle.tap, enable: false) },
                    teardown: { CFMachPortInvalidate(handle.tap) }
                )
            },
            eventHandler: { [weak self] type, event in
                self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
            }
        )
        worker = candidate
        do { try candidate.start(bootstrapTimeout: 0.5) }
        catch {
            candidate.stop()
            worker = nil
            throw error
        }
    }

    public func stop() {
        core.cancelActiveGesture()
        worker?.stop()
        worker = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        core.process(type: type, event: event)
    }

    /// Exercises the same suppression and pairing path without posting a
    /// synthetic click into the user's active application.
    @_spi(Testing)
    public func processEventForTesting(type: CGEventType, event: CGEvent) -> Bool {
        handle(type: type, event: event) == nil
    }

    @_spi(Testing)
    public func processTrackpadMotionForTesting() {
        core.emitTrackpadMovement()
    }
}

extension TouchDeviceKind {
    var isTrackpad: Bool {
        self == .builtInTrackpad || self == .externalTrackpad
    }
}

extension PhysicalMouseButton {
    var traceName: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        }
    }
}

extension TouchDeviceInfo {
    var traceSummary: String {
        "\(kind.rawValue):active=\(touchCount),raw=\(rawTouchCount)," +
        "callbacks=\(callbackCount),stages=0x\(String(stageMask, radix: 16))," +
        "frameAge=\(String(format: "%.4f", lastFrameAgeSeconds)),minDensity=\(String(format: "%.2f", minDensity))"
    }
}
