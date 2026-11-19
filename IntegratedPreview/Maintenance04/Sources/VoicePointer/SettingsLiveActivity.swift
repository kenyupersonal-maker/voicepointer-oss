import Foundation

/// Synchronous main-actor admission: previews stop before the real HUD starts drawing.
/// Separate owners prevent a hidden/disposed HUD from resuming another HUD's previews.
@MainActor final class SettingsLiveActivity {
    struct Snapshot: Equatable, Sendable {
        var gestureActive: Bool
        var hudVisible: Bool
        var pausesMouseRefresh: Bool { gestureActive || hudVisible }
        var pausesSkinPreviews: Bool { hudVisible }
    }

    static let shared = SettingsLiveActivity()
    private var gestures: Set<UUID> = []
    private var huds: Set<UUID> = []
    private var observers: [UUID: @MainActor (Snapshot) -> Void] = [:]
    var snapshot: Snapshot { .init(gestureActive: !gestures.isEmpty, hudVisible: !huds.isEmpty) }

    func observe(_ changed: @escaping @MainActor (Snapshot) -> Void) -> UUID {
        let token = UUID()
        observers[token] = changed
        return token
    }
    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }
    func setGestureActive(_ active: Bool, owner: UUID) {
        let before = snapshot
        if active { gestures.insert(owner) } else { gestures.remove(owner) }
        notify(after: before)
    }
    func setHUDVisible(_ visible: Bool, owner: UUID) {
        let before = snapshot
        if visible { huds.insert(owner) } else { huds.remove(owner) }
        notify(after: before)
    }
    func removeOwner(_ owner: UUID) {
        let before = snapshot
        gestures.remove(owner); huds.remove(owner)
        notify(after: before)
    }
    private func notify(after before: Snapshot) {
        let next = snapshot
        guard next != before else { return }
        for changed in Array(observers.values) { changed(next) }
    }
}

@MainActor final class SettingsLiveActivityLease {
    private let activity: SettingsLiveActivity
    private let owner = UUID()
    init(activity: SettingsLiveActivity = .shared) { self.activity = activity }
    func gesture(_ active: Bool) { activity.setGestureActive(active, owner: owner) }
    func hud(_ visible: Bool) { activity.setHUDVisible(visible, owner: owner) }
    deinit {
        let activity = activity, owner = owner
        Task { @MainActor in activity.removeOwner(owner) }
    }
}

/// Screen trials share the same synchronous HUD admission boundary as thumbnails.
/// Cancellation does not restart a trial; the user must explicitly request another.
@MainActor final class SettingsHUDTrialGate {
    private let activity: SettingsLiveActivity
    private let cancel: @MainActor () -> Void
    private var token: UUID?
    var allowsStart: Bool { !activity.snapshot.pausesSkinPreviews }
    init(activity: SettingsLiveActivity = .shared, cancel: @escaping @MainActor () -> Void) {
        self.activity = activity; self.cancel = cancel
        token = activity.observe { [weak self] snapshot in
            if snapshot.pausesSkinPreviews { self?.cancel() }
        }
    }
    deinit {
        let activity = activity, token = token
        Task { @MainActor in if let token { activity.removeObserver(token) } }
    }
}
