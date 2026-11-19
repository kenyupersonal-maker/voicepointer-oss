import Foundation

private final class MainActorTimerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    func begin() -> Bool {
        lock.withLock {
            guard !pending else { return false }
            pending = true
            return true
        }
    }
    func end() { lock.withLock { pending = false } }
}

/// Schedules repeated work on a run loop without exposing an actor-isolated
/// method as an Objective-C selector. The timer callback first creates a task
/// on MainActor, so Foundation never invokes Swift's @objc actor thunk directly.
@MainActor
func scheduleMainActorTimer(
    every interval: TimeInterval,
    mode: RunLoop.Mode = .default,
    action: @escaping @MainActor @Sendable () -> Void
) -> Timer {
    let gate = MainActorTimerGate()
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
        guard gate.begin() else { return }
        Task { @MainActor in
            defer { gate.end() }
            action()
        }
    }
    RunLoop.main.add(timer, forMode: mode)
    return timer
}
