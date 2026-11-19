import AppKit
import ApplicationServices
import Foundation

public struct FocusCandidate: Sendable, Equatable {
    public let identifier: String
    public let fingerprint: String
    public let role: String
    public let subrole: String?
    public let label: String
    public let frame: CGRect
    public let windowFrame: CGRect
    public let isEnabled: Bool
    public let isHidden: Bool
    public let isSecure: Bool
    public let isEditable: Bool
    public let isMultiline: Bool
    public let isPointerInside: Bool
    public let isCurrentlyFocused: Bool
    public let isCachedTarget: Bool
    public let isInsideToolbar: Bool
    public let isInsideSidebar: Bool
    public let isInsideDialog: Bool

    public init(
        identifier: String,
        fingerprint: String? = nil,
        role: String,
        subrole: String? = nil,
        label: String = "",
        frame: CGRect,
        windowFrame: CGRect = .zero,
        isEnabled: Bool = true,
        isHidden: Bool = false,
        isSecure: Bool = false,
        isEditable: Bool = true,
        isMultiline: Bool = false,
        isPointerInside: Bool = false,
        isCurrentlyFocused: Bool = false,
        isCachedTarget: Bool = false,
        isInsideToolbar: Bool = false,
        isInsideSidebar: Bool = false,
        isInsideDialog: Bool = false
    ) {
        self.identifier = identifier
        self.fingerprint = fingerprint ?? identifier
        self.role = role
        self.subrole = subrole
        self.label = label
        self.frame = frame
        self.windowFrame = windowFrame
        self.isEnabled = isEnabled
        self.isHidden = isHidden
        self.isSecure = isSecure
        self.isEditable = isEditable
        self.isMultiline = isMultiline
        self.isPointerInside = isPointerInside
        self.isCurrentlyFocused = isCurrentlyFocused
        self.isCachedTarget = isCachedTarget
        self.isInsideToolbar = isInsideToolbar
        self.isInsideSidebar = isInsideSidebar
        self.isInsideDialog = isInsideDialog
    }

    fileprivate func markingCached(_ cached: Bool) -> FocusCandidate {
        FocusCandidate(
            identifier: identifier,
            fingerprint: fingerprint,
            role: role,
            subrole: subrole,
            label: label,
            frame: frame,
            windowFrame: windowFrame,
            isEnabled: isEnabled,
            isHidden: isHidden,
            isSecure: isSecure,
            isEditable: isEditable,
            isMultiline: isMultiline,
            isPointerInside: isPointerInside,
            isCurrentlyFocused: isCurrentlyFocused,
            isCachedTarget: cached,
            isInsideToolbar: isInsideToolbar,
            isInsideSidebar: isInsideSidebar,
            isInsideDialog: isInsideDialog
        )
    }
}

public struct FocusScore: Sendable, Equatable {
    public let candidate: FocusCandidate
    public let value: Double
}

public struct SmartFocusScoring: Sendable {
    public init() {}

    public func score(_ candidate: FocusCandidate, at point: CGPoint) -> Double? {
        guard candidate.isEditable,
              candidate.isEnabled,
              !candidate.isHidden,
              (!candidate.isSecure || candidate.isCurrentlyFocused || candidate.isPointerInside),
              candidate.frame.width >= 8,
              candidate.frame.height >= 8 else {
            return nil
        }

        let role = candidate.role.lowercased()
        let text = "\(candidate.label) \(candidate.subrole ?? "") \(role)".lowercased()
        var score = 0.0

        if role.contains("textarea") { score += 52 }
        else if role.contains("textfield") { score += 40 }
        else if role.contains("combobox") { score += 24 }
        else { score += 12 }

        if candidate.isPointerInside || candidate.frame.contains(point) { score += 72 }
        if candidate.isCurrentlyFocused { score += 58 }
        if candidate.isCachedTarget { score += 46 }
        if candidate.isMultiline { score += 22 }
        if candidate.isInsideDialog { score += 16 }

        if candidate.frame.width >= 260 { score += 12 }
        if candidate.frame.height >= 64 { score += 12 }
        if candidate.frame.width < 160 || candidate.frame.height < 24 { score -= 12 }

        if !candidate.windowFrame.isEmpty {
            let relativeBottom = candidate.windowFrame.maxY - candidate.frame.midY
            if relativeBottom <= candidate.windowFrame.height * 0.34 { score += 16 }
        }

        let center = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
        let distance = hypot(center.x - point.x, center.y - point.y)
        score += max(0, 20 - distance / 45)

        // A field that already has focus AND sits under the pointer is an explicit choice (for example
        // the browser's address bar after the user clicked it or pressed Cmd-L). The penalties below
        // only guard against a toolbar/address/search field winning while the user points elsewhere.
        let explicitTarget = candidate.isCurrentlyFocused && (candidate.isPointerInside || candidate.frame.contains(point))
        if !explicitTarget {
            if candidate.isInsideToolbar { score -= 90 }
            if candidate.isInsideSidebar { score -= 45 }
            if text.contains("address") || text.contains("location") || text.contains("url") { score -= 85 }
            if text.contains("search") || text.contains("搜索") { score -= 60 }
            if text.contains("rename") || text.contains("重命名") { score -= 25 }
        }
        if text.contains("message") || text.contains("prompt") || text.contains("消息") || text.contains("输入") {
            score += 22
        }
        return score
    }

    public func ranked(_ candidates: [FocusCandidate], at point: CGPoint) -> [FocusScore] {
        candidates.compactMap { candidate in
            score(candidate, at: point).map { FocusScore(candidate: candidate, value: $0) }
        }.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.candidate.identifier < rhs.candidate.identifier }
            return lhs.value > rhs.value
        }
    }

    public func acceptedBest(
        _ candidates: [FocusCandidate],
        at point: CGPoint,
        minimumScore: Double,
        minimumLead: Double
    ) -> FocusScore? {
        let ranked = ranked(candidates, at: point)
        guard let best = ranked.first, best.value >= minimumScore else { return nil }
        let hasStrongIntent = best.candidate.isPointerInside ||
            best.candidate.isCurrentlyFocused ||
            best.candidate.isCachedTarget
        if let second = ranked.dropFirst().first,
           best.value - second.value < minimumLead,
           !hasStrongIntent {
            return nil
        }
        return best
    }
}

public struct SmartFocusConfiguration: Sendable {
    public var maxDepth: Int
    public var maxNodes: Int
    public var timeBudgetNanoseconds: UInt64
    public var minimumScore: Double
    public var minimumLead: Double
    public var synthesizeClickFallback: Bool

    public init(
        maxDepth: Int = 12,
        maxNodes: Int = 900,
        timeBudgetNanoseconds: UInt64 = 120_000_000,
        minimumScore: Double = 80,
        minimumLead: Double = 18,
        synthesizeClickFallback: Bool = false
    ) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.timeBudgetNanoseconds = timeBudgetNanoseconds
        self.minimumScore = minimumScore
        self.minimumLead = minimumLead
        self.synthesizeClickFallback = synthesizeClickFallback
    }
}

/// Chromium and Electron apps keep their web accessibility tree switched off
/// until an assistive client asks for it, and Chromium may switch it off again
/// after a quiet period. Until then the page's text fields are missing from AX.
public enum WebEngineKind: String, Sendable {
    case none
    case electron
    case chromium
}

public struct FocusSnapshot: Sendable {
    public let contextIdentifier: String
    public let bundleIdentifier: String?
    public let candidates: [FocusCandidate]
    public let processIdentifier: pid_t?
    public let webEngine: WebEngineKind
    public let traversedCount: Int

    public init(
        contextIdentifier: String,
        bundleIdentifier: String?,
        candidates: [FocusCandidate],
        processIdentifier: pid_t? = nil,
        webEngine: WebEngineKind = .none,
        traversedCount: Int = 0
    ) {
        self.contextIdentifier = contextIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.candidates = candidates
        self.processIdentifier = processIdentifier
        self.webEngine = webEngine
        self.traversedCount = traversedCount
    }
}

/// Providers that can ask a Chromium or Electron app to build its web
/// accessibility tree. Returns true when a short retry is worthwhile.
/// Where AX focus ended up shortly after VoicePointer focused an input itself.
public enum FocusSettle: Sendable {
    case stable(milliseconds: Int)
    case moved(FrozenInputTarget, role: String, milliseconds: Int)
    case unavailable
}

/// Electron/ProseMirror editors can hand AX focus to another element ~100-200 ms after a
/// programmatic focus. A provider that can watch the app's focused element reports where focus
/// settled, so the composer binds to the element keyboard input actually goes to.
public protocol FocusSettleProviding: Sendable {
    func settleFocus(afterFocusing candidateIdentifier: String, until deadline: UInt64,
                     scope: FocusOperationScope) -> FocusSettle
}

public protocol WebAccessibilityWarming: Sendable {
    func warmWebAccessibility(processIdentifier: pid_t, engine: WebEngineKind, scope: FocusOperationScope) -> Bool
}

public protocol FocusProviding: Sendable {
    func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot?
    func setFocused(candidateIdentifier: String) -> Bool
    func isFocused(candidateIdentifier: String) -> Bool
    func synthesizeClick(candidateIdentifier: String) -> Bool
}

public struct FocusOperationScope: Sendable {
    public let cancellationToken: OperationCancellationToken?
    public let deadline: UInt64
    public let shouldContinue: @Sendable () -> Bool
    public init(cancellationToken: OperationCancellationToken? = nil, deadline: UInt64,
                shouldContinue: @escaping @Sendable () -> Bool = { true }) {
        self.cancellationToken = cancellationToken; self.deadline = deadline
        self.shouldContinue = shouldContinue
    }
    public var isValid: Bool {
        cancellationToken?.isCancelled != true && shouldContinue() && DispatchTime.now().uptimeNanoseconds < deadline
    }
}

public protocol ScopedFocusProviding: FocusProviding {
    func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration, scope: FocusOperationScope) -> FocusSnapshot?
    func setFocused(candidateIdentifier: String, scope: FocusOperationScope) -> Bool
    func isFocused(candidateIdentifier: String, scope: FocusOperationScope) -> Bool
    func synthesizeClick(candidateIdentifier: String, scope: FocusOperationScope) -> Bool
}

public struct SmartFocusResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case focused
        case alreadyFocused
        case fallbackClicked
        case voiceOnly
        case unavailable
        case cancelled
        case excluded
        case ambiguous
        case rejected
    }

    public let outcome: Outcome
    public let candidate: FocusCandidate?
    public let score: Double?
    public let target: FrozenInputTarget?

    public init(outcome: Outcome, candidate: FocusCandidate? = nil, score: Double? = nil, target: FrozenInputTarget? = nil) {
        self.outcome = outcome
        self.candidate = candidate
        self.score = score
        self.target = target
    }
}

public final class SmartFocusEngine: @unchecked Sendable {
    /// Electron may take longer than Chromium to expose its web page after AX
    /// is enabled. Keep the total focus operation below the coordinator's
    /// 1.7-second ceiling so a stale result cannot act on a later gesture.
    static let chromiumWarmupNanoseconds: UInt64 = 900_000_000
    static let electronWarmupNanoseconds: UInt64 = 1_350_000_000
    static let focusOperationCeilingNanoseconds: UInt64 = 1_550_000_000
    /// Below this many visited nodes a browser window has no page content yet.
    static let sparseTreeNodeCount = 60

    private let provider: any FocusProviding
    private let scoring: SmartFocusScoring
    private let lock = NSLock()
    private var cachedFingerprints: [String: String] = [:]

    public init(provider: any FocusProviding, scoring: SmartFocusScoring = .init()) {
        self.provider = provider
        self.scoring = scoring
    }

    public func focus(
        at point: CGPoint,
        mode: FocusMode,
        configuration: SmartFocusConfiguration = .init(),
        excludedBundleIdentifiers: Set<String> = [],
        cancellationToken: OperationCancellationToken? = nil,
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) -> SmartFocusResult {
        if mode == .voiceOnly { return .init(outcome: .voiceOnly) }
        let focusStarted = DispatchTime.now().uptimeNanoseconds
        var operationDeadline = focusStarted + 600_000_000
        func withinBudget() -> Bool {
            cancellationToken?.isCancelled != true && shouldContinue() && DispatchTime.now().uptimeNanoseconds < operationDeadline
        }
        guard withinBudget() else { return .init(outcome: .cancelled) }
        var scope = FocusOperationScope(cancellationToken: cancellationToken, deadline: operationDeadline, shouldContinue: shouldContinue)
        func takeSnapshot(_ scope: FocusOperationScope) -> FocusSnapshot? {
            if let scoped = provider as? any ScopedFocusProviding {
                return scoped.snapshot(at: point, configuration: configuration, scope: scope)
            }
            return provider.snapshot(at: point, configuration: configuration)
        }
        guard var snapshot = takeSnapshot(scope) else {
            return .init(outcome: .unavailable)
        }
        guard withinBudget() else { return .init(outcome: .cancelled) }
        if let bundleIdentifier = snapshot.bundleIdentifier,
           excludedBundleIdentifiers.contains(bundleIdentifier) {
            return .init(outcome: .excluded)
        }

        func eligibleCandidates(in snapshot: FocusSnapshot) -> [FocusCandidate] {
            let cachedFingerprint = lock.withLock { cachedFingerprints[snapshot.contextIdentifier] }
            var candidates = snapshot.candidates.map {
                $0.markingCached($0.fingerprint == cachedFingerprint)
            }
            if mode == .currentOnly {
                candidates = candidates.filter(\.isCurrentlyFocused)
            }
            return candidates
        }
        func best(_ candidates: [FocusCandidate]) -> FocusScore? {
            scoring.acceptedBest(
                candidates,
                at: point,
                minimumScore: configuration.minimumScore,
                minimumLead: configuration.minimumLead
            )
        }
        var candidates = eligibleCandidates(in: snapshot)
        var selection = best(candidates)

        // Chromium and Electron may not have built the page's accessibility
        // tree yet (Chrome, Claude, Slack...). Ask for it once, then look again
        // for the engine-specific warm-up window before giving up.
        if selection == nil,
           snapshot.webEngine != .none,
           let pid = snapshot.processIdentifier,
           let warmer = provider as? any WebAccessibilityWarming {
            let warmupNanoseconds = snapshot.webEngine == .electron
                ? Self.electronWarmupNanoseconds : Self.chromiumWarmupNanoseconds
            let warmDeadline = min(
                DispatchTime.now().uptimeNanoseconds + warmupNanoseconds,
                focusStarted + Self.focusOperationCeilingNanoseconds
            )
            let warmScope = FocusOperationScope(
                cancellationToken: cancellationToken,
                deadline: warmDeadline,
                shouldContinue: shouldContinue
            )
            let requested = warmer.warmWebAccessibility(
                processIdentifier: pid,
                engine: snapshot.webEngine,
                scope: warmScope
            )
            if requested || snapshot.traversedCount < Self.sparseTreeNodeCount {
                operationDeadline = max(operationDeadline, warmDeadline)
                scope = warmScope
                var attempts = 0
                while selection == nil, withinBudget() {
                    Thread.sleep(forTimeInterval: 0.12)
                    guard withinBudget(), let retry = takeSnapshot(scope) else { break }
                    attempts += 1
                    snapshot = retry
                    candidates = eligibleCandidates(in: retry)
                    selection = best(candidates)
                }
                RuntimeTrace.record(
                    "focus web tree engine=\(snapshot.webEngine.rawValue) requested=\(requested) " +
                    "retries=\(attempts) found=\(selection != nil) traversed=\(snapshot.traversedCount)"
                )
                if selection == nil, cancellationToken?.isCancelled == true || !shouldContinue() {
                    return .init(outcome: .cancelled)
                }
            }
        }

        guard let selected = selection else {
            let top = scoring.ranked(candidates, at: point).prefix(3).map {
                "\($0.candidate.role):\(Int($0.value))"
            }.joined(separator: ",")
            RuntimeTrace.record("focus candidates rejected count=\(candidates.count) top=\(top)")
            return .init(outcome: candidates.isEmpty ? .rejected : .ambiguous)
        }
        guard withinBudget() else { return .init(outcome: .cancelled) }
        RuntimeTrace.record(
            "focus selected role=\(selected.candidate.role) score=\(Int(selected.value)) " +
            "direct=attempt"
        )
        // Freeze the exact element before any success return. If a provider
        // conforms to FocusTargetProviding but cannot retain the element, the
        // result cannot be bound to a physical target and must be rejected.
        let frozenTarget = (provider as? any FocusTargetProviding)?.frozenTarget(
            candidateIdentifier: selected.candidate.identifier
        )
        if provider is any FocusTargetProviding, frozenTarget == nil {
            RuntimeTrace.record("focus selected candidate has no frozen target")
            return .init(outcome: .rejected, candidate: selected.candidate, score: selected.value)
        }
        if ((provider as? any ScopedFocusProviding)?.setFocused(candidateIdentifier: selected.candidate.identifier, scope: scope)
            ?? provider.setFocused(candidateIdentifier: selected.candidate.identifier)),
           verifyFocused(selected.candidate.identifier, scope: scope) {
            var settledTarget = frozenTarget
            // 2026-09-30: after VoicePointer focused a Claude-app composer itself, the app moved AX
            // focus to another element ~130 ms later; the composer watch then cancelled the dictation
            // while the HUD kept listening (one 19-second dictation lost, then four failed retries).
            // Watch briefly and bind to where focus settles; a non-editable result is rejected by the
            // composer session at once, so the user sees "请点一下输入框" instead of talking into nothing.
            if !selected.candidate.isCurrentlyFocused,
               let settler = provider as? any FocusSettleProviding {
                let now = DispatchTime.now().uptimeNanoseconds
                let settleDeadline = min(operationDeadline &- 30_000_000, now &+ 450_000_000)
                if settleDeadline > now {
                    switch settler.settleFocus(afterFocusing: selected.candidate.identifier,
                                               until: settleDeadline, scope: scope) {
                    case .stable(let milliseconds):
                        RuntimeTrace.record("focus settle result=stable ms=\(milliseconds)")
                    case .moved(let moved, let role, let milliseconds):
                        RuntimeTrace.record("focus settle result=moved role=\(role) ms=\(milliseconds)")
                        settledTarget = moved
                    case .unavailable:
                        RuntimeTrace.record("focus settle result=unavailable")
                    }
                }
            }
            remember(selected.candidate, context: snapshot.contextIdentifier)
            return .init(
                outcome: selected.candidate.isCurrentlyFocused ? .alreadyFocused : .focused,
                candidate: selected.candidate,
                score: selected.value,
                target: settledTarget
            )
        }
        guard withinBudget() else { return .init(outcome: .cancelled) }
        if configuration.synthesizeClickFallback,
           ((provider as? any ScopedFocusProviding)?.synthesizeClick(candidateIdentifier: selected.candidate.identifier, scope: scope)
            ?? provider.synthesizeClick(candidateIdentifier: selected.candidate.identifier)),
           verifyFocused(selected.candidate.identifier, scope: scope) {
            RuntimeTrace.record("focus fallback click succeeded")
            remember(selected.candidate, context: snapshot.contextIdentifier)
            return .init(outcome: .fallbackClicked, candidate: selected.candidate, score: selected.value, target: frozenTarget)
        }
        RuntimeTrace.record(
            "focus selected candidate rejected clickFallback=\(configuration.synthesizeClickFallback)"
        )
        return .init(outcome: .rejected, candidate: selected.candidate, score: selected.value)
    }

    private func remember(_ candidate: FocusCandidate, context: String) {
        lock.withLock { cachedFingerprints[context] = candidate.fingerprint }
    }

    private func verifyFocused(
        _ identifier: String,
        scope: FocusOperationScope
    ) -> Bool {
        for attempt in 0..<10 {
            guard scope.isValid else { return false }
            let focused = (provider as? any ScopedFocusProviding)?.isFocused(candidateIdentifier: identifier, scope: scope)
                ?? provider.isFocused(candidateIdentifier: identifier)
            if focused { return scope.isValid }
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.010) }
        }
        return false
    }
}

public final class MacOSAccessibilityProvider: @unchecked Sendable, ScopedFocusProviding, FocusTargetProviding, WebAccessibilityWarming, FocusSettleProviding {
    private let lock = NSLock()
    // Web-engine kind per app bundle path; guarded by `lock`.
    private var webEngineByBundlePath: [String: WebEngineKind] = [:]
    // Chromium processes whose AXEnhancedUserInterface this provider switched
    // on, with the last time a snapshot used them. Only touched on axQueue.
    private var enhancedInterfaceLastUse: [pid_t: UInt64] = [:]
    private static let enhancedInterfaceIdleNanoseconds: UInt64 = 120_000_000_000
    /// All AX references and messaging remain on this private serial context.
    /// The provider's public API is synchronous for compatibility, but callers
    /// must invoke it from their bounded worker task (SmartFocus does not own
    /// the UI actor).
    private let axQueue = DispatchQueue(label: "com.voicepointer.ax.focus", qos: .userInitiated)
    private var elementsByIdentifier: [String: AXUIElement] = [:]
    // Only read or written inside axQueue. A scope spans every IPC in one
    // provider call, including late returns from AXIsAttributeSettable.
    private var currentScope: FocusOperationScope?
    private var mayProceed: Bool { currentScope?.isValid == true }

    private func withScope<T>(_ scope: FocusOperationScope, _ body: () -> T) -> T {
        axQueue.sync {
            currentScope = scope
            defer { currentScope = nil }
            return body()
        }
    }

    private var defaultScope: FocusOperationScope {
        .init(deadline: DispatchTime.now().uptimeNanoseconds + 600_000_000)
    }

    public init() {}

    /// FocusTargetProviding: retains the cached element under the provider
    /// lock only. No AX calls and no axQueue acquisition; the element was
    /// already captured during snapshot.
    public func frozenTarget(candidateIdentifier: String) -> FrozenInputTarget? {
        lock.withLock {
            elementsByIdentifier[candidateIdentifier].map(FrozenInputTarget.init)
        }
    }

    public func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration, scope: FocusOperationScope) -> FocusSnapshot? {
        withScope(scope) { snapshotOnAXQueue(at: point, configuration: configuration) }
    }
    public func setFocused(candidateIdentifier: String, scope: FocusOperationScope) -> Bool {
        withScope(scope) { setFocusedOnAXQueue(candidateIdentifier: candidateIdentifier) }
    }
    public func isFocused(candidateIdentifier: String, scope: FocusOperationScope) -> Bool {
        withScope(scope) { isFocusedOnAXQueue(candidateIdentifier: candidateIdentifier) }
    }
    public func synthesizeClick(candidateIdentifier: String, scope: FocusOperationScope) -> Bool {
        withScope(scope) { synthesizeClickOnAXQueue(candidateIdentifier: candidateIdentifier) }
    }

    public func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? {
        snapshot(at: point, configuration: configuration, scope: defaultScope)
    }

    private func snapshotOnAXQueue(at point: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? {
        guard mayProceed, AccessibilityPermission.isTrusted else { return nil }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        AXUIElementSetMessagingTimeout(system, 0.15)
        guard mayProceed else { return nil }
        _ = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        if let hit {
            var hitPID: pid_t = 0
            guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID != getpid() else { return nil }
        }
        var windowElement = hit.flatMap { window(of: $0) }

        // Browser canvases and transient blank regions can return no useful AX
        // hit even though the user is pointing at the frontmost page. Fall
        // back to that app's focused/main window, then search its full tree.
        if windowElement == nil,
           let application = NSWorkspace.shared.frontmostApplication {
            let app = AXUIElementCreateApplication(application.processIdentifier)
            windowElement = elementAttribute(app, kAXFocusedWindowAttribute as CFString)
                ?? elementAttribute(app, kAXMainWindowAttribute as CFString)
            if hit == nil { hit = windowElement }
        }
        guard let windowElement else { return nil }
        let resolvedHit = hit ?? windowElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(windowElement, &pid) == .success, pid != getpid() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let windowFrame = frame(of: windowElement) ?? .zero
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let windowTitle = stringAttribute(windowElement, kAXTitleAttribute as CFString) ?? ""
        let contextIdentifier = "\(pid)|\(windowTitle)|\(Int(windowFrame.minX)),\(Int(windowFrame.minY))"
        let focused = elementAttribute(app, kAXFocusedUIElementAttribute as CFString)
        let focusedInWindow = focused.flatMap { focusedElement -> AXUIElement? in
            guard let focusedWindow = window(of: focusedElement), CFEqual(focusedWindow, windowElement) else { return nil }
            return focusedElement
        }

        var orderedElements: [AXUIElement] = []
        var seen = Set<CFHashCode>()
        func appendUnique(_ element: AXUIElement) {
            let hash = CFHash(element)
            if seen.insert(hash).inserted { orderedElements.append(element) }
        }
        var cursor: AXUIElement? = resolvedHit
        for _ in 0..<10 {
            guard let element = cursor else { break }
            appendUnique(element)
            if CFEqual(element, windowElement) { break }
            cursor = elementAttribute(element, kAXParentAttribute as CFString)
        }
        if let focusedInWindow { appendUnique(focusedInWindow) }
        // The app's focused field under the pointer counts even when another window of the same app
        // covers that spot: Chrome's address-bar dropdown is a separate popup window, so the hit test
        // lands in the popup and the focused omnibox was never considered (2026-09-30, "浏览器的输入框").
        var focusedUnderPointer: AXUIElement?
        if focusedInWindow == nil, let focused, let focusedFrame = frame(of: focused), focusedFrame.contains(point) {
            focusedUnderPointer = focused
            appendUnique(focused)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        var queue: [(AXUIElement, Int)] = [(windowElement, 0)]
        var queueIndex = 0
        var traversed = 0
        while queueIndex < queue.count && traversed < configuration.maxNodes {
            guard mayProceed else { break }
            if DispatchTime.now().uptimeNanoseconds - start >= configuration.timeBudgetNanoseconds { break }
            let (element, depth) = queue[queueIndex]
            queueIndex += 1
            traversed += 1
            appendUnique(element)
            if depth < configuration.maxDepth {
                queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
            }
        }
        let budgetExpired = queueIndex < queue.count

        // The pointer often lands on a composer's container (its padding or placeholder row) rather
        // than on the text element, and in Electron the walk from the window root stops at the web
        // area (about 22 nodes), so the composer was never seen: 2026-09-30 the Claude app logged
        // hitRole=AXGroup focusedRole=AXWebArea and rejected until the user clicked the input. Look
        // through a small subtree around the hit element (its own subtree, then two levels up; 120 nodes).
        if let hitElement = hit, !CFEqual(hitElement, windowElement) {
            var visited = Set<CFHashCode>()
            func walk(from root: AXUIElement, maxDepth: Int, maxNodes: Int) {
                var local: [(AXUIElement, Int)] = [(root, 0)]
                var index = 0
                var count = 0
                while index < local.count && count < maxNodes {
                    guard mayProceed else { return }
                    if DispatchTime.now().uptimeNanoseconds - start >= configuration.timeBudgetNanoseconds { return }
                    let (element, depth) = local[index]
                    index += 1
                    guard visited.insert(CFHash(element)).inserted else { continue }
                    count += 1
                    appendUnique(element)
                    if depth < maxDepth {
                        local.append(contentsOf: children(of: element).map { ($0, depth + 1) })
                    }
                }
            }
            // First the hit element's own subtree, then the neighbourhood two levels up.
            walk(from: hitElement, maxDepth: 5, maxNodes: 50)
            var ancestor: AXUIElement? = hitElement
            for _ in 0..<2 {
                guard let next = ancestor.flatMap({ elementAttribute($0, kAXParentAttribute as CFString) }),
                      !CFEqual(next, windowElement) else { break }
                ancestor = next
            }
            if let ancestor, !CFEqual(ancestor, hitElement) {
                walk(from: ancestor, maxDepth: 4, maxNodes: 70)
            }
        }

        var elementMap: [String: AXUIElement] = [:]
        let candidates = orderedElements.compactMap { element -> FocusCandidate? in
            guard mayProceed else { return nil }
            guard let candidate = candidate(
                from: element,
                pointer: point,
                windowFrame: windowFrame,
                focused: focusedInWindow ?? focusedUnderPointer
            ) else { return nil }
            elementMap[candidate.identifier] = element
            return candidate
        }
        lock.withLock {
            if elementsByIdentifier.count > 1_000 { elementsByIdentifier.removeAll(keepingCapacity: true) }
            elementsByIdentifier.merge(elementMap) { _, new in new }
        }
        let webEngine = webEngineKind(ofProcess: pid)
        if webEngine == .chromium { noteEnhancedInterfaceUse(pid) }
        RuntimeTrace.record(
            "focus snapshot pid=\(pid) candidates=\(candidates.count) " +
            "traversed=\(traversed) budgetExpired=\(budgetExpired) web=\(webEngine.rawValue)"
        )
        if candidates.isEmpty {
            // T19 diagnostics (roles only, never values): tells an unbuilt web tree (hit lands on a
            // generic container, nothing focused) apart from a pointer that is simply not over an input.
            let role = { (element: AXUIElement?) -> String in
                element.flatMap { self.stringAttribute($0, kAXRoleAttribute as CFString) } ?? "none"
            }
            RuntimeTrace.record(
                "focus snapshot empty hitRole=\(role(hit)) focusedRole=\(role(focused)) " +
                "focusedInWindow=\(focusedInWindow != nil)"
            )
        }
        return FocusSnapshot(
            contextIdentifier: contextIdentifier,
            bundleIdentifier: bundleIdentifier,
            candidates: candidates,
            processIdentifier: pid,
            webEngine: webEngine,
            traversedCount: traversed
        )
    }

    public func warmWebAccessibility(processIdentifier pid: pid_t, engine: WebEngineKind, scope: FocusOperationScope) -> Bool {
        withScope(scope) { warmWebAccessibilityOnAXQueue(pid: pid, engine: engine) }
    }

    private func warmWebAccessibilityOnAXQueue(pid: pid_t, engine: WebEngineKind) -> Bool {
        guard mayProceed, engine != .none, pid != getpid() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        // Electron's own switch has no side effects, so it is simply turned on.
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            RuntimeTrace.record("focus web tree manual accessibility on pid=\(pid)")
            return true
        }
        guard engine == .chromium, mayProceed else { return false }
        // Chromium browsers only answer the screen-reader switch. It can slow
        // window animations, so it is left alone while VoiceOver runs or when
        // someone else already turned it on, and released after two idle minutes.
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return false }
        if enhancedInterfaceLastUse[pid] != nil { return true }
        if boolAttribute(app, "AXEnhancedUserInterface" as CFString, default: false) { return false }
        guard mayProceed,
              AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success
        else { return false }
        enhancedInterfaceLastUse[pid] = DispatchTime.now().uptimeNanoseconds
        scheduleEnhancedInterfaceRelease(pid)
        RuntimeTrace.record("focus web tree enhanced interface on pid=\(pid)")
        return true
    }

    private func noteEnhancedInterfaceUse(_ pid: pid_t) {
        if enhancedInterfaceLastUse[pid] != nil {
            enhancedInterfaceLastUse[pid] = DispatchTime.now().uptimeNanoseconds
        }
    }

    private func scheduleEnhancedInterfaceRelease(_ pid: pid_t) {
        axQueue.asyncAfter(deadline: .now() + .seconds(120)) { [weak self] in
            self?.releaseEnhancedInterfaceIfIdle(pid)
        }
    }

    /// Runs on axQueue outside any focus operation, so it calls AX directly
    /// instead of through the scope-checked helpers.
    private func releaseEnhancedInterfaceIfIdle(_ pid: pid_t) {
        guard let lastUse = enhancedInterfaceLastUse[pid] else { return }
        let idle = DispatchTime.now().uptimeNanoseconds &- lastUse
        guard idle >= Self.enhancedInterfaceIdleNanoseconds else {
            scheduleEnhancedInterfaceRelease(pid)
            return
        }
        enhancedInterfaceLastUse[pid] = nil
        guard NSRunningApplication(processIdentifier: pid) != nil,
              !NSWorkspace.shared.isVoiceOverEnabled else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        RuntimeTrace.record("focus web tree enhanced interface off pid=\(pid)")
    }

    private func webEngineKind(ofProcess pid: pid_t) -> WebEngineKind {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return .none }
        let key = bundleURL.path
        if let cached = lock.withLock({ webEngineByBundlePath[key] }) { return cached }
        let kind = Self.detectWebEngine(bundleURL: bundleURL)
        lock.withLock { webEngineByBundlePath[key] = kind }
        return kind
    }

    /// Electron apps ship "Electron Framework"; Chromium browsers ship a
    /// framework whose Helpers folder holds a "... Helper (Renderer).app".
    private static func detectWebEngine(bundleURL: URL) -> WebEngineKind {
        let fileManager = FileManager.default
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        if fileManager.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path) {
            return .electron
        }
        guard let items = try? fileManager.contentsOfDirectory(atPath: frameworks.path) else { return .none }
        func hasRenderer(_ folder: URL) -> Bool {
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.contains { $0.hasSuffix("Helper (Renderer).app") }
        }
        for item in items where item.hasSuffix(".framework") {
            if item == "Chromium Embedded Framework.framework" { return .chromium }
            let framework = frameworks.appendingPathComponent(item, isDirectory: true)
            if hasRenderer(framework.appendingPathComponent("Helpers", isDirectory: true)) ||
                hasRenderer(framework.appendingPathComponent("Versions/Current/Helpers", isDirectory: true)) {
                return .chromium
            }
        }
        // Other Chromium embedders keep the renderer helper beside their
        // frameworks; only the side-effect-free switch is tried for them.
        return hasRenderer(frameworks) ? .electron : .none
    }

    public func setFocused(candidateIdentifier: String) -> Bool {
        setFocused(candidateIdentifier: candidateIdentifier, scope: defaultScope)
    }

    public func settleFocus(afterFocusing candidateIdentifier: String, until deadline: UInt64,
                            scope: FocusOperationScope) -> FocusSettle {
        withScope(scope) { settleFocusOnAXQueue(candidateIdentifier: candidateIdentifier, until: deadline) }
    }

    /// Polls the app's focused element every 30 ms: at least 300 ms, and until a moved focus has
    /// stayed put for 90 ms, never past `deadline`. Reads only; never writes AX or posts events.
    private func settleFocusOnAXQueue(candidateIdentifier: String, until deadline: UInt64) -> FocusSettle {
        guard mayProceed, let element = lock.withLock({ elementsByIdentifier[candidateIdentifier] }) else {
            return .unavailable
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return .unavailable }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        let start = DispatchTime.now().uptimeNanoseconds
        var current = element
        var lastChange = start
        while mayProceed {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline || (now &- start >= 300_000_000 && now &- lastChange >= 90_000_000) { break }
            Thread.sleep(forTimeInterval: 0.03)
            guard mayProceed else { break }
            if let focused = elementAttribute(app, kAXFocusedUIElementAttribute as CFString),
               !CFEqual(focused, current) {
                current = focused
                lastChange = DispatchTime.now().uptimeNanoseconds
            }
        }
        let milliseconds = Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
        if CFEqual(current, element) { return .stable(milliseconds: milliseconds) }
        let role = stringAttribute(current, kAXRoleAttribute as CFString) ?? "none"
        return .moved(FrozenInputTarget(element: current), role: role, milliseconds: milliseconds)
    }

    private func setFocusedOnAXQueue(candidateIdentifier: String) -> Bool {
        guard mayProceed, let element = lock.withLock({ elementsByIdentifier[candidateIdentifier] }) else { return false }
        guard activateWindow(containing: element) else { return false }
        var settable = DarwinBoolean(false)
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard mayProceed else { return false }
        guard AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        guard mayProceed else { return false }
        return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    public func isFocused(candidateIdentifier: String) -> Bool {
        isFocused(candidateIdentifier: candidateIdentifier, scope: defaultScope)
    }

    private func isFocusedOnAXQueue(candidateIdentifier: String) -> Bool {
        guard let element = lock.withLock({ elementsByIdentifier[candidateIdentifier] }) else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        let app = AXUIElementCreateApplication(pid)
        guard boolAttribute(app, kAXFrontmostAttribute as CFString, default: false),
              let focused = elementAttribute(app, kAXFocusedUIElementAttribute as CFString) else {
            return false
        }
        return CFEqual(focused, element)
    }

    public func synthesizeClick(candidateIdentifier: String) -> Bool {
        synthesizeClick(candidateIdentifier: candidateIdentifier, scope: defaultScope)
    }

    private func synthesizeClickOnAXQueue(candidateIdentifier: String) -> Bool {
        guard mayProceed, EventAccessPermission.canPost,
              let element = lock.withLock({ elementsByIdentifier[candidateIdentifier] }),
              activateWindow(containing: element),
              let frame = frame(of: element) else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        down.setIntegerValueField(.eventSourceUserData, value: voicePointerSyntheticEventUserData)
        up.setIntegerValueField(.eventSourceUserData, value: voicePointerSyntheticEventUserData)
        guard mayProceed, let scope = currentScope else { return false }
        let commit: () -> Bool = {
            // Do not call scope.shouldContinue here: it may inspect the same
            // token whose short commit lock is currently held.
            guard DispatchTime.now().uptimeNanoseconds < scope.deadline else { return false }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }
        if let token = scope.cancellationToken { return token.commitIfValid(commit) ?? false }
        return commit()
    }

    private func activateWindow(containing element: AXUIElement) -> Bool {
        guard mayProceed, let targetWindow = window(of: element) else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(targetWindow, &pid) == .success else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        AXUIElementSetMessagingTimeout(targetWindow, 0.15)
        guard mayProceed else { return false }
        let frontmostResult = AXUIElementSetAttributeValue(
            app,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        guard mayProceed else { return false }
        let raiseResult = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        return frontmostResult == .success || raiseResult == .success
    }

    private func candidate(
        from element: AXUIElement,
        pointer: CGPoint,
        windowFrame: CGRect,
        focused: AXUIElement?
    ) -> FocusCandidate? {
        guard let role = stringAttribute(element, kAXRoleAttribute as CFString) else { return nil }
        let normalizedRole = role.lowercased()
        let roleLooksEditable = normalizedRole.contains("textfield") ||
            normalizedRole.contains("textarea") ||
            normalizedRole.contains("combobox")
        let editable = boolAttribute(element, "AXEditable" as CFString, default: roleLooksEditable)
        guard roleLooksEditable || editable else { return nil }
        guard let elementFrame = frame(of: element) else { return nil }

        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)
        let labelParts = [
            stringAttribute(element, kAXTitleAttribute as CFString),
            stringAttribute(element, kAXDescriptionAttribute as CFString),
            stringAttribute(element, "AXPlaceholderValue" as CFString),
            stringAttribute(element, kAXIdentifierAttribute as CFString),
        ].compactMap { $0 }.filter { !$0.isEmpty }
        let label = labelParts.joined(separator: " ")
        let secure = (subrole ?? "").localizedCaseInsensitiveContains("secure") ||
            normalizedRole.contains("secure")
        let ancestorRoles = rolesOfAncestors(element, limit: 8).map { $0.lowercased() }
        let hash = CFHash(element)
        let rawIdentifier = stringAttribute(element, kAXIdentifierAttribute as CFString) ?? String(hash)
        let fingerprint = "\(role)|\(rawIdentifier)|\(label)|\(Int(elementFrame.minX)),\(Int(elementFrame.minY)),\(Int(elementFrame.width)),\(Int(elementFrame.height))"
        return FocusCandidate(
            identifier: "\(hash)",
            fingerprint: fingerprint,
            role: role,
            subrole: subrole,
            label: label,
            frame: elementFrame,
            windowFrame: windowFrame,
            isEnabled: boolAttribute(element, kAXEnabledAttribute as CFString, default: true),
            isHidden: boolAttribute(element, kAXHiddenAttribute as CFString, default: false),
            isSecure: secure,
            isEditable: editable,
            isMultiline: normalizedRole.contains("textarea") || boolAttribute(element, "AXMultiline" as CFString, default: false),
            isPointerInside: elementFrame.contains(pointer),
            isCurrentlyFocused: focused.map { CFEqual($0, element) } ?? false,
            isCachedTarget: false,
            isInsideToolbar: ancestorRoles.contains { $0.contains("toolbar") },
            isInsideSidebar: ancestorRoles.contains { $0.contains("outline") || $0.contains("sidebar") },
            isInsideDialog: ancestorRoles.contains { $0.contains("dialog") || $0.contains("sheet") }
        )
    }

    private func window(of element: AXUIElement) -> AXUIElement? {
        if stringAttribute(element, kAXRoleAttribute as CFString) == (kAXWindowRole as String) { return element }
        if let direct = elementAttribute(element, kAXWindowAttribute as CFString) { return direct }
        var cursor: AXUIElement? = element
        for _ in 0..<14 {
            guard let current = cursor,
                  let parent = elementAttribute(current, kAXParentAttribute as CFString) else { return nil }
            if stringAttribute(parent, kAXRoleAttribute as CFString) == (kAXWindowRole as String) { return parent }
            cursor = parent
        }
        return nil
    }

    private func rolesOfAncestors(_ element: AXUIElement, limit: Int) -> [String] {
        var result: [String] = []
        var cursor: AXUIElement? = element
        for _ in 0..<limit {
            guard let current = cursor,
                  let parent = elementAttribute(current, kAXParentAttribute as CFString) else { break }
            if let role = stringAttribute(parent, kAXRoleAttribute as CFString) { result.append(role) }
            cursor = parent
        }
        return result
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyAttribute(element, kAXChildrenAttribute as CFString),
              CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString, default fallback: Bool) -> Bool {
        guard let raw = copyAttribute(element, attribute) else { return fallback }
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.boolValue }
        return fallback
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRaw = copyAttribute(element, kAXPositionAttribute as CFString),
              let sizeRaw = copyAttribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(positionRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeDowncast(positionRaw, to: AXValue.self)
        let sizeValue = unsafeDowncast(sizeRaw, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        guard mayProceed else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }
}
