import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

public final class OwnedShortcutLease: @unchecked Sendable {
    private let lock = NSLock()
    private var didRelease = false
    private var releaseResult: Bool?
    private var waiters: [@Sendable (Bool) -> Void] = []
    private let manager: KeyboardOwnershipManager
    fileprivate let token: OperationCancellationToken
    fileprivate let modifier: VoiceModifier
    fileprivate let identifier: UInt64

    fileprivate init(manager: KeyboardOwnershipManager, token: OperationCancellationToken, modifier: VoiceModifier, identifier: UInt64) {
        self.manager = manager; self.token = token; self.modifier = modifier; self.identifier = identifier
    }

    /// Idempotent and safe from any thread. The serialized owner submits the
    /// matching up, if the down was owned.
    public func release() { finish(cancelToken: false) }
    public func cancel() {
        token.cancel()
        finish(cancelToken: false)
    }
    /// Completes after the matching up (or toggle stop sequence) has been
    /// submitted. This is intentionally independent of MainActor.
    public func releaseAndWait() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            finish(cancelToken: false) { success in continuation.resume(returning: success) }
        }
    }

    private func finish(cancelToken: Bool = false, completion: (@Sendable (Bool) -> Void)? = nil) {
        lock.lock()
        if didRelease {
            let result = releaseResult
            if let completion, result == nil { waiters.append(completion) }
            lock.unlock()
            if let completion, let result { completion(result) }
            return
        }
        didRelease = true
        releaseResult = nil
        if let completion { waiters.append(completion) }
        lock.unlock()
        if cancelToken { token.cancel() }
        manager.enqueueRelease(identifier: identifier) { success in
            self.lock.lock()
            if success { self.releaseResult = true }
            else { self.didRelease = false; self.releaseResult = false }
            let callbacks = self.waiters; self.waiters.removeAll()
            self.lock.unlock()
            callbacks.forEach { $0(success) }
        }
    }
}

public final class KeyboardOwnershipManager: @unchecked Sendable {
    private struct Record { let lease: OwnedShortcutLease; let modifier: VoiceModifier; var mode: VoiceActivationMode }
    private let queue = DispatchQueue(label: "com.kenyu.VoicePointer.keyboard-ownership")
    private let recordLock = NSLock()
    private var records: [UInt64: Record] = [:]
    private var shutdownRequests = 0
    private var nextID: UInt64 = 1
    private let backend: any KeyboardEventPosting
    private var pendingTokens: [ObjectIdentifier: OperationCancellationToken] = [:]

    public init(backend: any KeyboardEventPosting = CGEventKeyboardPostBackend()) { self.backend = backend }

    /// All state transitions and event submission occur on one private serial
    /// queue. A held physical key is rejected before any synthetic down.
    public func acquire(
        modifier: VoiceModifier,
        mode: VoiceActivationMode,
        cancellationToken: OperationCancellationToken
    ) async -> OwnedShortcutLease? {
        registerPending(cancellationToken)
        return await withCheckedContinuation { (continuation: CheckedContinuation<OwnedShortcutLease?, Never>) in
            queue.async {
                defer { self.unregisterPending(cancellationToken) }
                self.recordLock.lock()
                let unavailable = self.shutdownRequests > 0
                self.recordLock.unlock()
                guard !unavailable else { continuation.resume(returning: nil); return }
                guard !cancellationToken.isCancelled else { continuation.resume(returning: nil); return }
                guard !self.backend.isPhysicalHeld(modifier) else {
                    RuntimeTrace.record("keyboard ownership acquire rejected physicalHeld modifier=\(modifier.rawValue)")
                    continuation.resume(returning: nil); return
                }
                guard self.records.isEmpty else {
                    RuntimeTrace.record("keyboard ownership acquire rejected alreadyOwned")
                    continuation.resume(returning: nil); return
                }
                let id = self.nextID; self.nextID &+= 1
                let result: KeyboardEventPostResult
                if mode == .hold {
                    result = cancellationToken.commitIfValid {
                        self.backend.post(modifier: modifier, isDown: true, marker: Self.marker(for: id))
                    } ?? .rejected(reason: "cancelledBeforeCommit")
                } else {
                    result = cancellationToken.commitIfValid {
                        let down = self.backend.post(modifier: modifier, isDown: true, marker: Self.marker(for: id))
                        guard case .submitted = down else { return down }
                        let up = self.backend.post(modifier: modifier, isDown: false, marker: Self.marker(for: id))
                        if case .submitted = up { return up }
                        // The down was submitted but its paired up failed.
                        // Keep an ownership record so releaseAll/retry can
                        // compensate; never silently return an unowned down.
                        let lease = OwnedShortcutLease(manager: self, token: cancellationToken, modifier: modifier, identifier: id)
                        self.records[id] = Record(lease: lease, modifier: modifier, mode: .hold)
                        self.updateRecordSnapshot()
                        return up
                    } ?? .rejected(reason: "cancelledBeforeCommit")
                }
                guard case .submitted = result else {
                    RuntimeTrace.record("keyboard ownership acquire failed modifier=\(modifier.rawValue) result=\(result)")
                    continuation.resume(returning: nil); return
                }
                let lease = OwnedShortcutLease(manager: self, token: cancellationToken, modifier: modifier, identifier: id)
                self.records[id] = Record(lease: lease, modifier: modifier, mode: mode)
                self.updateRecordSnapshot()
                continuation.resume(returning: lease)
            }
        }
    }

    public func releaseAllOwned() {
        beginShutdown()
        recordLock.lock()
        let leases = Array(recordSnapshot.values).map(\.lease)
        recordLock.unlock()
        cancelPendingTokens()
        leases.forEach { $0.token.cancel() }
        queue.async {
            for (id, record) in self.records {
                if self.submitUp(record, id: id) { self.records.removeValue(forKey: id) }
            }
            self.updateRecordSnapshot()
            self.endShutdown()
        }
    }

    /// Attempts each currently owned lease once and reports whether every
    /// matching release was submitted. Failed ownership remains for an
    /// explicit later retry; this method never loops or retries indefinitely.
    public func releaseAllOwnedAndWait() async -> Bool {
        beginShutdown()
        cancelPendingTokens()
        return await withCheckedContinuation { continuation in
            queue.async {
                var allSucceeded = true
                for (id, record) in self.records {
                    if self.submitUp(record, id: id) { self.records.removeValue(forKey: id) }
                    else { allSucceeded = false }
                }
                self.updateRecordSnapshot()
                self.endShutdown()
                continuation.resume(returning: allSucceeded)
            }
        }
    }

    fileprivate func enqueueRelease(identifier: UInt64, completion: (@Sendable (Bool) -> Void)? = nil) {
        queue.async {
            guard let record = self.records[identifier] else { completion?(true); return }
            let success = self.submitUp(record, id: identifier)
            if success { self.records.removeValue(forKey: identifier) }
            self.updateRecordSnapshot()
            completion?(success)
        }
    }

    private func submitUp(_ record: Record, id: UInt64) -> Bool {
        let result: KeyboardEventPostResult
        if record.mode == .hold {
            result = backend.post(modifier: record.modifier, isDown: false, marker: Self.marker(for: id))
        } else {
            let down = backend.post(modifier: record.modifier, isDown: true, marker: Self.marker(for: id))
            if case .submitted = down {
                result = backend.post(modifier: record.modifier, isDown: false, marker: Self.marker(for: id))
                if case .submitted = result {} else {
                    // A retry must only complete this pair, never tap the
                    // toggle again and accidentally restart dictation.
                    records[id]?.mode = .hold
                }
            } else {
                result = down
            }
        }
        if case .submitted = result {
            RuntimeTrace.record("keyboard ownership release submitted modifier=\(record.modifier.rawValue) marker=\(Self.marker(for: id))")
            return true
        } else {
            RuntimeTrace.record("keyboard ownership release failed modifier=\(record.modifier.rawValue) result=\(result)")
            return false
        }
    }

    private func submitToggle(modifier: VoiceModifier, id: UInt64) -> KeyboardEventPostResult {
        let down = backend.post(modifier: modifier, isDown: true, marker: Self.marker(for: id))
        guard case .submitted = down else { return down }
        return backend.post(modifier: modifier, isDown: false, marker: Self.marker(for: id))
    }

    private func updateRecordSnapshot() {
        recordLock.lock(); defer { recordLock.unlock() }
        // Snapshot exists only to make releaseAllOwned immediate without
        // coupling callers to the serial queue.
        recordSnapshot = records
    }
    private func beginShutdown() {
        recordLock.lock(); shutdownRequests += 1; recordLock.unlock()
    }

    private func registerPending(_ token: OperationCancellationToken) {
        recordLock.lock()
        pendingTokens[ObjectIdentifier(token)] = token
        let reject = shutdownRequests > 0
        recordLock.unlock()
        if reject { token.cancel() }
    }
    private func unregisterPending(_ token: OperationCancellationToken) {
        recordLock.lock(); pendingTokens.removeValue(forKey: ObjectIdentifier(token)); recordLock.unlock()
    }
    private func cancelPendingTokens() {
        recordLock.lock()
        let tokens = Array(pendingTokens.values) + recordSnapshot.values.map { $0.lease.token }
        recordLock.unlock()
        tokens.forEach { $0.cancel() }
    }
    private func endShutdown() {
        recordLock.lock(); shutdownRequests = max(0, shutdownRequests - 1); recordLock.unlock()
    }
    private var recordSnapshot: [UInt64: Record] = [:]

    private static let markerPrefix: UInt64 = 0x56504B4F00000000
    private static func marker(for id: UInt64) -> UInt64 { markerPrefix | (id & 0x00000000FFFFFFFF) }

    #if canImport(CoreGraphics)
    public static func observePhysicalEvent(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }
        let marker = UInt64(bitPattern: event.getIntegerValueField(.eventSourceUserData))
        guard marker & 0xFFFFFFFF00000000 != markerPrefix else { return }
        PhysicalModifierState.observe(keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags)
    }
    #endif

}

private enum PhysicalModifierState {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: Set<VoiceModifier> = []

    static func isHeld(_ modifier: VoiceModifier) -> Bool { lock.lock(); defer { lock.unlock() }; return held.contains(modifier) }

    #if canImport(CoreGraphics)
    static func observe(keyCode: CGKeyCode, flags _: CGEventFlags) {
        guard let modifier = VoiceModifier(keyCode: keyCode) else { return }
        lock.lock(); defer { lock.unlock() }
        // flagsChanged carries an aggregate class bit (Option/Command/etc.),
        // so its value cannot distinguish left/right keys when both are held.
        // For an unmarked physical key stream, each exact keycode event is a
        // transition; tracking that transition preserves the opposite key.
        if held.contains(modifier) { held.remove(modifier) } else { held.insert(modifier) }
    }
    #endif
}

#if canImport(CoreGraphics)
private extension VoiceModifier {
    init?(keyCode: CGKeyCode) {
        switch keyCode { case 63: self = .fn; case 58: self = .leftOption; case 61: self = .rightOption; case 55: self = .leftCommand; case 54: self = .rightCommand; case 59: self = .leftControl; case 62: self = .rightControl; case 56: self = .leftShift; case 60: self = .rightShift; default: return nil }
    }
}
#endif
