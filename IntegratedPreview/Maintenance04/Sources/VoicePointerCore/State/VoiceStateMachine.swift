import Foundation

public enum VoicePointerState: String, Sendable, Equatable {
    case idle = "IDLE"
    case arming = "ARMING"
    case resolvingTarget = "RESOLVING_TARGET"
    case listening = "LISTENING"
    case stopping = "STOPPING"
}

public enum VoiceStateEvent: Sendable, Equatable {
    case gestureBegan
    case resolutionStarted
    case targetResolved
    case targetResolutionFailed
    case gestureEnded
    case stopCompleted
    case escape
    case disconnect
    case cancel
    case watchdog
    case applicationWillTerminate
}

public enum VoiceStateAction: Sendable, Equatable {
    case resolveTarget(activationID: UInt64)
    case startVoice
    case stopVoice
    case cancelResolution
}

/// Pure transition model. Side effects are returned to the coordinator so a
/// missing release, late AX result, or duplicate cancellation cannot leave a
/// modifier held down.
public struct VoiceStateMachine: Sendable {
    public private(set) var state: VoicePointerState = .idle
    public private(set) var activationID: UInt64 = 0
    public private(set) var physicalPressHeld = false
    public let mode: VoiceActivationMode

    public init(mode: VoiceActivationMode = .hold) {
        self.mode = mode
    }

    public mutating func handle(_ event: VoiceStateEvent) -> [VoiceStateAction] {
        switch event {
        case .gestureBegan:
            if mode == .toggle, state == .listening {
                state = .stopping
                return [.stopVoice]
            }
            guard state == .idle else { return [] }
            activationID &+= 1
            physicalPressHeld = true
            state = .arming
            return [.resolveTarget(activationID: activationID)]

        case .resolutionStarted:
            guard state == .arming else { return [] }
            state = .resolvingTarget
            return []

        case .targetResolved:
            guard state == .arming || state == .resolvingTarget else { return [] }
            guard mode == .toggle || physicalPressHeld else {
                state = .idle
                return [.cancelResolution]
            }
            state = .listening
            return [.startVoice]

        case .targetResolutionFailed:
            guard state == .arming || state == .resolvingTarget else { return [] }
            physicalPressHeld = false
            state = .idle
            return []

        case .gestureEnded:
            physicalPressHeld = false
            guard mode == .hold else { return [] }
            switch state {
            case .arming, .resolvingTarget:
                activationID &+= 1
                state = .idle
                return [.cancelResolution]
            case .listening:
                state = .stopping
                return [.stopVoice]
            default:
                return []
            }

        case .stopCompleted:
            guard state == .stopping else { return [] }
            state = .idle
            return []

        case .escape, .disconnect, .cancel, .watchdog, .applicationWillTerminate:
            physicalPressHeld = false
            switch state {
            case .arming, .resolvingTarget:
                activationID &+= 1
                state = .idle
                return [.cancelResolution]
            case .listening:
                activationID &+= 1
                state = .stopping
                return [.stopVoice]
            case .stopping, .idle:
                return []
            }
        }
    }
}
