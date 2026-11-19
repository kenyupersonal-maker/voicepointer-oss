import CoreGraphics
import Foundation
import VoicePointerCore

/// Chromium and Electron pages expose their text field only after the
/// provider asks for the web accessibility tree (Chrome search box, Claude).
public enum WebFocusWarmupChecks {
    public static func run() -> [String] {
        var failures: [String] = []
        let point = CGPoint(x: 50, y: 50)

        let cold = WebWarmupFake(engine: .chromium, readyAfterWarm: true)
        let coldResult = SmartFocusEngine(provider: cold).focus(at: point, mode: .smart)
        if coldResult.outcome != .alreadyFocused || cold.warmCalls != 1 || cold.reads < 2 {
            failures.append(
                "cold web page was not retried after warming " +
                "(outcome=\(coldResult.outcome) warm=\(cold.warmCalls) reads=\(cold.reads))"
            )
        }

        // Nine 120 ms retries exceed the old 0.9 s limit. The Electron-only
        // extension must resolve this cold page without changing native apps.
        let slowElectron = WebWarmupFake(engine: .electron, readyAfterWarm: true, readyAfterReads: 10)
        let slowResult = SmartFocusEngine(provider: slowElectron).focus(at: point, mode: .smart)
        if slowResult.outcome != .alreadyFocused || slowElectron.warmCalls != 1 || slowElectron.reads < 10 {
            failures.append("slow Electron page was rejected before its field appeared")
        }

        let native = WebWarmupFake(engine: .none, readyAfterWarm: true)
        let nativeResult = SmartFocusEngine(provider: native).focus(at: point, mode: .smart)
        if nativeResult.outcome != .rejected || native.warmCalls != 0 || native.reads != 1 {
            failures.append("native app without a text field was retried")
        }

        let fullPage = WebWarmupFake(engine: .chromium, readyAfterWarm: false, warmResult: false, traversed: 400)
        let fullPageResult = SmartFocusEngine(provider: fullPage).focus(at: point, mode: .smart)
        if fullPageResult.outcome != .rejected || fullPage.reads != 1 {
            failures.append("complete web tree without a text field waited for a retry")
        }

        let token = OperationCancellationToken()
        let cancelled = WebWarmupFake(engine: .electron, readyAfterWarm: false, cancelOnWarm: token)
        let cancelledResult = SmartFocusEngine(provider: cancelled).focus(
            at: point,
            mode: .smart,
            cancellationToken: token
        )
        if cancelledResult.outcome != .cancelled {
            failures.append("cancel during web warm-up reported \(cancelledResult.outcome)")
        }
        return failures
    }
}

/// Synchronous test-owned fake; never shared concurrently.
private final class WebWarmupFake: ScopedFocusProviding, WebAccessibilityWarming, @unchecked Sendable {
    let engine: WebEngineKind
    let readyAfterWarm: Bool
    let readyAfterReads: Int
    let warmResult: Bool
    let traversed: Int
    let cancelOnWarm: OperationCancellationToken?
    var reads = 0
    var warmCalls = 0
    private var warmed = false

    init(
        engine: WebEngineKind,
        readyAfterWarm: Bool,
        readyAfterReads: Int = 2,
        warmResult: Bool = true,
        traversed: Int = 16,
        cancelOnWarm: OperationCancellationToken? = nil
    ) {
        self.engine = engine
        self.readyAfterWarm = readyAfterWarm
        self.readyAfterReads = readyAfterReads
        self.warmResult = warmResult
        self.traversed = traversed
        self.cancelOnWarm = cancelOnWarm
    }

    private func sample() -> FocusSnapshot {
        let ready = warmed && readyAfterWarm && reads >= readyAfterReads
        let field = FocusCandidate(
            identifier: "search",
            role: "AXTextArea",
            frame: CGRect(x: 0, y: 0, width: 400, height: 60),
            isPointerInside: true,
            isCurrentlyFocused: true
        )
        return FocusSnapshot(
            contextIdentifier: "web",
            bundleIdentifier: "test.web",
            candidates: ready ? [field] : [],
            processIdentifier: 4242,
            webEngine: engine,
            traversedCount: ready ? 180 : traversed
        )
    }

    func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration, scope: FocusOperationScope) -> FocusSnapshot? {
        guard scope.isValid else { return nil }
        reads += 1
        return sample()
    }

    func warmWebAccessibility(processIdentifier: pid_t, engine: WebEngineKind, scope: FocusOperationScope) -> Bool {
        warmCalls += 1
        warmed = true
        cancelOnWarm?.cancel()
        return warmResult
    }

    func setFocused(candidateIdentifier: String, scope: FocusOperationScope) -> Bool { scope.isValid }
    func isFocused(candidateIdentifier: String, scope: FocusOperationScope) -> Bool { scope.isValid }
    func synthesizeClick(candidateIdentifier: String, scope: FocusOperationScope) -> Bool { false }
    func snapshot(at point: CGPoint, configuration: SmartFocusConfiguration) -> FocusSnapshot? { reads += 1; return sample() }
    func setFocused(candidateIdentifier: String) -> Bool { true }
    func isFocused(candidateIdentifier: String) -> Bool { true }
    func synthesizeClick(candidateIdentifier: String) -> Bool { false }
}
