import AppKit
import SwiftUI
import VoicePointerCore

/// A window-scoped final-result destination. It never makes this app an AX target.
@MainActor
final class FirstRunPracticeBuffer: ObservableObject {
    @Published var text = ""
    var active = false
    var focused = false {
        didSet { if oldValue && !focused { revokeLease() } }
    }
    weak var window: NSWindow?
    private var epoch = UUID()
    private var cancellation: (@MainActor () -> Void)?

    func watch(token: OperationCancellationToken, coordinator: VoicePointerCoordinator) {
        cancellation = { [weak coordinator] in
            token.cancel()
            Task { await coordinator?.cancelPracticeSession(cancellationToken: token) }
        }
    }

    func revokeLease() {
        epoch = UUID()
        let cancel = cancellation
        cancellation = nil
        cancel?()
    }

    func invalidate() {
        active = false
        focused = false
        revokeLease()
    }

    func captureSink() -> (@MainActor @Sendable (UUID, String) -> Void)? {
        guard active, focused, window?.isKeyWindow == true, NSApp.isActive else { return nil }
        let capturedEpoch = epoch
        return { [weak self] _, final in
            guard let self, self.epoch == capturedEpoch, self.active, self.focused,
                  self.window?.isKeyWindow == true, NSApp.isActive else { return }
            self.cancellation = nil
            self.text += final
        }
    }
}
