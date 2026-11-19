import Foundation

/// Pure decision state for the microphone monitor's start intent and
/// permission-request generations.
///
/// Extracted from `MicrophoneLevelMonitor` (VP-D) so the production monitor
/// and the self-test drive the exact same gate logic: tests inject the
/// permission value and inspect the returned effects instead of duplicating
/// the decision tree or touching AVFoundation. The type owns no engine, no
/// clock, and no logging; the monitor maps each `Effect` onto real work.
public struct MicrophoneIntentGate: Equatable, Sendable {
    public enum Permission: Equatable, Sendable {
        case undetermined
        case granted
        case denied
    }

    /// The monitor-side work a gate transition requires. `openEngine` covers
    /// tap installation plus `AVAudioEngine.start()`; `closeEngine` covers
    /// engine stop and tap removal.
    public enum Effect: Equatable, Sendable {
        case none
        case denied
        case requestPermission(requestGeneration: UInt64)
        case openEngine
        case closeEngine
    }

    public private(set) var desiredRunning = false
    public private(set) var isEngineRunning = false
    public private(set) var isRequestPending = false
    public private(set) var permissionGeneration: UInt64 = 0
    public private(set) var permission: Permission = .undetermined
    private var failedIntent = false

    public init() {}

    public init(permission: Permission) {
        self.permission = permission
    }

    /// Mirrors the system permission read the monitor performs before each
    /// decision point.
    public mutating func setPermission(_ newPermission: Permission) {
        permission = newPermission
    }

    /// Rolls back the optimistic `isEngineRunning` set by `beginIntent` when
    /// the engine failed to start. Repeated starts are latched off until the
    /// current intent ends; a route failure must not create a retry loop.
    public mutating func engineDidFailToStart() {
        isEngineRunning = false
        failedIntent = true
    }

    /// Mirrors `MicrophoneLevelMonitor.start()`: expresses the running intent
    /// and decides what the monitor must do next. `openEngine` is emitted
    /// exactly once per engine transition, so repeated starts while running
    /// or while a request is pending cannot install a second tap.
    public mutating func beginIntent() -> Effect {
        desiredRunning = true
        guard !isEngineRunning, !isRequestPending, !failedIntent else { return .none }
        switch permission {
        case .granted:
            isEngineRunning = true
            return .openEngine
        case .undetermined:
            isRequestPending = true
            permissionGeneration &+= 1
            return .requestPermission(requestGeneration: permissionGeneration)
        case .denied:
            return .denied
        }
    }

    /// Mirrors `MicrophoneLevelMonitor.stop()`: the intent ends and any
    /// in-flight permission request is invalidated immediately, so a late
    /// allow can only serve a still-active newer intent.
    public mutating func endIntent() -> Effect {
        desiredRunning = false
        failedIntent = false
        isRequestPending = false
        permissionGeneration &+= 1
        guard isEngineRunning else { return .none }
        isEngineRunning = false
        return .closeEngine
    }

    /// Mirrors the asynchronous `AVAudioApplication.requestRecordPermission`
    /// completion. The request generation identifies which pending request
    /// the system answered; answers for invalidated generations never start
    /// the engine on their own.
    public mutating func permissionRequestResolved(
        requestGeneration: UInt64,
        granted: Bool
    ) -> Effect {
        guard requestGeneration == permissionGeneration else {
            return .none
        }
        isRequestPending = false
        if granted, desiredRunning {
            return beginIntent()
        }
        return .none
    }
}
