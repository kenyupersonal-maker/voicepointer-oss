import Foundation

/// Thin injectable shortcut transport owned by the Doubao backend.
public protocol ShortcutTransport: Sendable {
    func acquire(_ token: OperationCancellationToken) async -> Bool
    func release() async -> Bool
}

/// Production transport wrapping KeyboardOwnershipManager. No direct CGEvent.
@MainActor
public final class KeyboardShortcutTransport: ShortcutTransport, @unchecked Sendable {
    private let manager: KeyboardOwnershipManager
    private let modifier: VoiceModifier
    private let mode: VoiceActivationMode
    private var lease: OwnedShortcutLease?
    private var blocked = false
    private let safety: VoiceOperationSafety?

    public init(manager: KeyboardOwnershipManager, modifier: VoiceModifier = .leftOption, mode: VoiceActivationMode = .hold, safety: VoiceOperationSafety? = nil) {
        self.manager = manager
        self.modifier = modifier
        self.mode = mode
        self.safety = safety
    }

    public func acquire(_ token: OperationCancellationToken) async -> Bool {
        guard !blocked, lease == nil else { return false }
        guard let held = await manager.acquire(modifier: modifier, mode: mode, cancellationToken: token) else {
            if await manager.releaseAllOwnedAndWait() == false { blocked = true }
            return false
        }
        lease = held
        if let safety {
            // Install the held lease for the acquire token immediately so the
            // existing out-of-actor interlock can cancel before MainActor catches up.
            safety.install(held, for: token)
        }
        return true
    }

    public func release() async -> Bool {
        if let held = lease {
            guard await held.releaseAndWait() else {
                blocked = true // lease retained for retry
                return false
            }
            lease = nil
            blocked = false
            return true
        }
        guard blocked else { return true }
        let cleaned = await manager.releaseAllOwnedAndWait()
        blocked = !cleaned
        return cleaned
    }
}

public enum DoubaoBackendError: Error, Equatable {
    case busy
    case unsupportedMode
    case blocked
    case cancelled
}

@MainActor
public final class DoubaoSpeechBackend: SpeechInputBackend {
    private enum State { case idle, acquiring, listening, stopping, blocked }

    public var isQuiescent: Bool { state == .idle }

    public let capabilities = SpeechInputCapabilities(deliveryKind: .externalEditor, supportsPartialText: false, supportsHints: false)
    private let transport: any ShortcutTransport
    private let clock = ContinuousClock()
    private var state: State = .idle
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var sessionID = UUID()
    private var origin: ContinuousClock.Instant?
    private var token: OperationCancellationToken?
    private var callback: (@MainActor @Sendable (SpeechInputEvent) -> Void)?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingFinish = false
    private let externalToken: OperationCancellationToken?

    public init(transport: any ShortcutTransport, externalToken: OperationCancellationToken? = nil) {
        self.transport = transport
        self.externalToken = externalToken
    }

    public convenience init(manager: KeyboardOwnershipManager, modifier: VoiceModifier = .leftOption, mode: VoiceActivationMode = .hold, externalToken: OperationCancellationToken? = nil, safety: VoiceOperationSafety? = nil) {
        self.init(transport: KeyboardShortcutTransport(manager: manager, modifier: modifier, mode: mode, safety: safety), externalToken: externalToken)
    }

    public func start(snapshot: VoiceInputSnapshot, onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void) async throws {
        guard snapshot.selection.mode == .doubao else { throw DoubaoBackendError.unsupportedMode }
        guard state == .idle else { throw state == .blocked ? DoubaoBackendError.blocked : DoubaoBackendError.busy }
        if let externalToken, externalToken.isCancelled { throw DoubaoBackendError.cancelled }
        generation &+= 1
        let gen = generation
        sessionID = snapshot.sessionID
        origin = clock.now // clock initialized before first sample
        let token = externalToken ?? OperationCancellationToken()
        self.token = token
        callback = onEvent
        pendingFinish = false
        state = .acquiring
        let acquired = await transport.acquire(token)
        guard gen == generation else {
            if acquired { _ = await transport.release() }
            return
        }
        if !acquired || token.isCancelled || pendingFinish {
            if acquired {
                state = .stopping
                let ok = await transport.release()
                if pendingFinish, callback != nil {
                    emit(ok ? .stopped : .failed, errorCode: ok ? nil : "shortcut_release_failed")
                }
                if ok { clearSession() } else { stateBlocked() }
            } else {
                let cleaned = await transport.release() // resolve any pending manager cleanup
                if callback != nil, !token.isCancelled { emit(.failed, errorCode: "shortcut_acquire_failed") }
                if cleaned { clearSession() } else { stateBlocked() }
            }
            resumeWaiters()
            return
        }
        state = .listening
        emit(.ready)
    }

    public func finish() async {
        switch state {
        case .listening:
            await performFinish()
        case .acquiring:
            pendingFinish = true
            token?.cancel()
            await waitDrained()
        case .stopping:
            await waitDrained()
        case .blocked, .idle:
            break
        }
    }

    public func cancel() async {
        // Invalidate callback and token before any await, for all states.
        callback = nil
        token?.cancel()
        token = nil
        switch state {
        case .listening:
            state = .stopping
            if await transport.release() {
                clearSession()
            } else {
                stateBlocked()
            }
            resumeWaiters()
        case .acquiring:
            state = .stopping
            // Do not resume finish waiters here; start() resumes them once
            // late-acquire cleanup really finishes.
        case .blocked:
            if await transport.release() {
                state = .idle
                resumeWaiters()
            }
        case .stopping, .idle:
            break
        }
    }

    private func performFinish() async {
        guard state == .listening else { resumeWaiters(); return }
        state = .stopping
        if await transport.release() {
            emit(.stopped) // shortcut released only; recognition not settled
            clearSession()
        } else {
            emit(.failed, errorCode: "shortcut_release_failed")
            stateBlocked()
        }
        resumeWaiters()
    }

    private func waitDrained() async {
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    private func clearSession() {
        state = .idle
        token = nil
        callback = nil
        pendingFinish = false
    }

    private func stateBlocked() {
        state = .blocked
        token = nil
        callback = nil
        pendingFinish = false
    }

    private func resumeWaiters() {
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func emit(_ kind: SpeechInputEvent.Kind, text: String? = nil, errorCode: String? = nil) {
        guard let callback else { return }
        sequence &+= 1
        let elapsed = origin.map { $0.duration(to: clock.now) } ?? .zero
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        callback(SpeechInputEvent(sessionID: sessionID, sequence: sequence, observedMilliseconds: ms, kind: kind, text: text, errorCode: errorCode))
    }
}
