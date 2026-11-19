import ApplicationServices
import Foundation

/// An immutable, retained AXUIElement reference captured at focus-resolution
/// time. The element is never exposed publicly; identity is compared with
/// CFEqual (a pure reference comparison that performs no AX IPC).
public final class FrozenInputTarget: @unchecked Sendable, Equatable {
    internal let element: AXUIElement

    internal init(element: AXUIElement) {
        self.element = element
    }

    public static func == (lhs: FrozenInputTarget, rhs: FrozenInputTarget) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

public protocol FocusTargetProviding: Sendable {
    /// Retains an immutable cached element reference for the given candidate.
    /// Performs no AX IPC and holds no queues.
    func frozenTarget(candidateIdentifier: String) -> FrozenInputTarget?
}

