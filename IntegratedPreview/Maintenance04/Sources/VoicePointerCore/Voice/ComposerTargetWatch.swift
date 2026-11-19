import AppKit
import ApplicationServices
import Foundation

/// Watches an already-frozen composer target app for focus changes.
/// Any focused-element/window change or app switch cancels the token
/// irreversibly. Performs no AX writes, keyboard, mic, or activation.
internal final class ComposerTargetWatch: @unchecked Sendable {

    /// Immutable callback context handed to AX via refcon.
    /// Holds the frozen identity, token, shared gate, and invalidation
    /// closure; never references the watcher (no retain cycle).
    private final class Context: @unchecked Sendable {
        let token: OperationCancellationToken
        let pid: pid_t
        let targetElement: AXUIElement
        let targetWindow: AXUIElement
        let gate: ComposerFocusEventGate
        let onInvalidated: @Sendable () -> Void
        init(token: OperationCancellationToken, pid: pid_t,
             targetElement: AXUIElement, targetWindow: AXUIElement,
             gate: ComposerFocusEventGate,
             onInvalidated: @escaping @Sendable () -> Void) {
            self.token = token
            self.pid = pid
            self.targetElement = targetElement
            self.targetWindow = targetWindow
            self.gate = gate
            self.onInvalidated = onInvalidated
        }

        /// Matches a notification element against the frozen identity.
        /// Focus-element notifications compare against the frozen element;
        /// focus-window notifications compare against the frozen window;
        /// anything else is conservatively non-matching.
        func matchesFrozenIdentity(kind: String, element: CFTypeRef?) -> Bool {
            switch kind {
            case "focusElement":
                guard let element = element else { return false }
                return CFEqual(element, targetElement as CFTypeRef)
            case "focusWindow":
                guard let element = element else { return false }
                return CFEqual(element, targetWindow as CFTypeRef)
            default:
                return false
            }
        }

        /// Applies one notification through the shared gate: cancel the token
        /// and notify invalidation exactly once, only when this is the first
        /// genuine identity mismatch. No AX reads, no keyboard, no lock held
        /// across callbacks.
        func applyNotification(kind: String, matchesFrozenIdentity: Bool) {
            let alreadyCancelled = token.isCancelled
            let didInvalidate = gate.shouldInvalidate(
                matchesFrozenIdentity: matchesFrozenIdentity, kind: kind
            )
            // Cancellation still revokes every future write. If Return has
            // already committed, focus loss belongs to receipt observation,
            // not to pre-send target-resolution failure. Token cancellation
            // waits for that short key commit, including its phase marker.
            if didInvalidate { token.cancel() }
            let afterReturn = gate.hasPostedReturn
            RuntimeTrace.record(
                "composer target watch notification=\(kind) " +
                "matchesFrozenIdentity=\(matchesFrozenIdentity) " +
                "didInvalidate=\(didInvalidate) " +
                "alreadyCancelled=\(alreadyCancelled) phase=\(afterReturn ? "afterReturn" : "beforeReturn")"
            )
            if didInvalidate && !afterReturn {
                onInvalidated()
            }
        }
    }

    /// Box for detached cleanup resources (Swift 6 non-Sendable capture).
    private final class CleanupBox: @unchecked Sendable {
        let observer: AXObserver?
        let application: AXUIElement
        let refcon: Unmanaged<Context>?
        let pid: pid_t

        init(observer: AXObserver?, application: AXUIElement,
             refcon: Unmanaged<Context>?, pid: pid_t) {
            self.observer = observer
            self.application = application
            self.refcon = refcon
            self.pid = pid
        }
    }

    private static let axCallbackImpl: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon = refcon else { return }
        let context = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()
        // Finite, content-free notification classification for diagnostics.
        let notificationKind: String
        if notification == kAXFocusedUIElementChangedNotification as CFString {
            notificationKind = "focusElement"
        } else if notification == kAXFocusedWindowChangedNotification as CFString {
            notificationKind = "focusWindow"
        } else {
            notificationKind = "other"
        }
        // Identity comparison only; no AX reads, no keyboard. Same target
        // focus notifications are silent; a real mismatch invalidates once.
        let matches = context.matchesFrozenIdentity(kind: notificationKind, element: element)
        context.applyNotification(kind: notificationKind, matchesFrozenIdentity: matches)
    }

    private var lock = NSLock()
    private var stopped = false
    private var workspaceObserverToken: (any NSObjectProtocol)?
    private var cleanupBox: CleanupBox?
    private let gate = ComposerFocusEventGate()

    func noteReturnPosted() { gate.noteReturnPosted() }
    var postReturnInvalidation: String? { gate.postReturnInvalidation }

    func replayInvalidate(kind: String, token: OperationCancellationToken) {
        if gate.shouldInvalidate(matchesFrozenIdentity: false, kind: kind) { token.cancel() }
    }

    private init() {}
    /// An inert watcher for the explicit synthetic executor seam; no observer or workspace read.
    static func replayOnly() -> ComposerTargetWatch { ComposerTargetWatch() }

    static func start(processIdentifier pid: pid_t,
                      targetElement: AXUIElement,
                      targetWindow: AXUIElement,
                      cancellationToken token: OperationCancellationToken,
                      onInvalidated: @escaping @Sendable () -> Void = {}) -> ComposerTargetWatch? {
        guard pid > 0, pid != getpid() else { return nil }
        if token.isCancelled { return nil }

        let watch = ComposerTargetWatch()

        // One shared gate across AX and workspace callbacks: invalidation
        // happens exactly once even under concurrent notifications.
        let gate = watch.gate
        let context = Context(
            token: token, pid: pid,
            targetElement: targetElement, targetWindow: targetWindow,
            gate: gate, onInvalidated: onInvalidated
        )

        // 1. Workspace observer FIRST; caller revalidates after start to close
        //    the acquisition race.
        let wsContext = context
        watch.workspaceObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { note in
            // Strong context capture: safe during concurrent callback.
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                // Unknown app: conservatively invalidate through the gate.
                wsContext.applyNotification(
                    kind: "workspace", matchesFrozenIdentity: false
                )
                return
            }
            if app.processIdentifier != wsContext.pid {
                wsContext.applyNotification(
                    kind: "workspace", matchesFrozenIdentity: false
                )
            } else {
                // Same frozen app re-activated: not an identity change.
                wsContext.applyNotification(
                    kind: "workspace", matchesFrozenIdentity: true
                )
            }
        }

        // 2. AX observer + application element; fail closed on any error.
        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallbackImpl, &observer) == .success,
              let axObserver = observer else {
            watch.stop()
            return nil
        }

        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let refcon = Unmanaged.passRetained(context)

        watch.cleanupBox = CleanupBox(observer: axObserver, application: application,
                                      refcon: refcon, pid: pid)
        let opaque = refcon.toOpaque()
        guard AXObserverAddNotification(
            axObserver, application,
            kAXFocusedUIElementChangedNotification as CFString,
            opaque) == .success else {
            watch.stop()
            return nil
        }
        guard AXObserverAddNotification(
            axObserver, application,
            kAXFocusedWindowChangedNotification as CFString,
            opaque) == .success else {
            watch.stop()
            return nil
        }

        // 3. Attach runloop source to main runloop in common modes.
        let runLoopSource = AXObserverGetRunLoopSource(axObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        if token.isCancelled {
            watch.stop()
            return nil
        }

        return watch
    }

    /// Idempotent stop. Detaches resources atomically under lock, then performs
    /// source removal on the main queue, then AX IPC on a background queue.
    /// Removing the run-loop source before releasing refcon means an in-flight
    /// main-runloop callback cannot race a freed context. A slow target app
    /// must never hold the VoicePointer menu bar or HUD.
    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let box = cleanupBox
        cleanupBox = nil
        let wsToken = workspaceObserverToken
        workspaceObserverToken = nil
        lock.unlock()

        if let wsToken = wsToken {
            NSWorkspace.shared.notificationCenter.removeObserver(wsToken)
        }

        guard let box = box else { return }

        DispatchQueue.main.async {
            if let observer = box.observer {
                MainHangStateStore.shared.withOperation(.axObserverRemove) {
                    let source = AXObserverGetRunLoopSource(observer)
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                }
            }
            DispatchQueue.global(qos: .utility).async {
                defer { box.refcon?.release() }
                guard let observer = box.observer else { return }
                let started = DispatchTime.now().uptimeNanoseconds
                AXObserverRemoveNotification(
                    observer, box.application,
                    kAXFocusedUIElementChangedNotification as CFString)
                AXObserverRemoveNotification(
                    observer, box.application,
                    kAXFocusedWindowChangedNotification as CFString)
                let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                if elapsedMs >= 200 {
                    RuntimeTrace.record("composer target watch removal slow elapsedMs=\(elapsedMs)")
                }
            }
        }
    }

    deinit {
        stop()
    }
}
