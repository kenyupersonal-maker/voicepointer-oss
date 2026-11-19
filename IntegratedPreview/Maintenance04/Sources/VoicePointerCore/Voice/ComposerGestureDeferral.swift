import Foundation

/// Waiting never installs/cancels a speech token or mutates the previous editor.
@MainActor
public enum ComposerGestureDeferral {
    public enum Result: Sendable { case ready, timedOut, cancelled }
    public static func wait(maximumMilliseconds: Int = 1000, stillPending: @MainActor () -> Bool) async -> Result {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, min(1000, maximumMilliseconds))) * 1_000_000
        while stillPending() {
            guard !Task.isCancelled else { return .cancelled }
            if DispatchTime.now().uptimeNanoseconds >= deadline { return .timedOut }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return .cancelled }
        }
        return Task.isCancelled ? .cancelled : .ready
    }
}

public enum ComposerConfirmedDeliveryPolicy {
    /// Caret confirmation helps future editing; only exact document confirmation
    /// is evidence for this completed paste. Target safety remains with the caller.
    public static func permitsAction(documentConfirmed: Bool, caretConfirmed: Bool) -> Bool {
        documentConfirmed
    }
}
