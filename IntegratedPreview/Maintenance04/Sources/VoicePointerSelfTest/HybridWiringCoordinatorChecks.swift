import Foundation
import CoreGraphics
@_spi(Testing) import VoicePointerCore

/// The coordinator with "用于增强本地识别", up to the moment its backend starts: what it asks the gate, which
/// backend it builds, and the lines it writes. Hermetic the way CoordinatorSafetyChecks' Aliyun fallback is:
/// this binary has no bundled catalog, so the local recognizer stops at its catalog lookup, before any
/// permission prompt, microphone, worker or network; the hybrid backend starts its local branch first and
/// stops at the same place (CONTRACT §2.2 point 10). Skipped wherever that catalog could be found, so these can
/// never start real recognition. The gate is real, on a temporary state file.
@MainActor
extension HybridWiringChecks {
    static func coordinatorChecks() async -> [String] {
        guard Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Backend") == nil else { return [] }
        var failures: [String] = []
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true
        ).appendingPathComponent("HybridWiringChecks-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return ["hybrid coordinator: temporary directory could not be created"]
        }
        defer { try? FileManager.default.removeItem(at: root.appendingPathComponent("state.json")) }
        let gate = CloudAdmissionGate(store: CloudAdmissionStateStore(fileURL: root.appendingPathComponent("state.json")))
        let credential = CloudEntryCredential(isSaved: true, revision: "hybrid-wiring-\(UUID().uuidString)")
        guard let revision = credential.revision, let identity = try? CloudEntry.makeIdentity(credentialRevision: revision),
              await CloudEntry.confirm(gate: gate, identity: identity) == .confirmed else {
            return ["hybrid coordinator: the confirmed identity fixture could not be created"]
        }
        let fixture = WiringFixture(root: root, gate: gate, credential: credential)
        let enhanced = CloudEntryPreferences(visible: true, routeEnabled: false, uploadConsent: true, enhanceLocal: true)
        let enhanceConsent = enhanced.legacyConsent(merging: [])
        guard enhanceConsent == [CloudEntry.enhanceConsentID] else {
            return ["hybrid coordinator: the enhancement's consent fixture is \(enhanceConsent.sorted())"]
        }
        var written: [String] = []

        // HC-01 Enhancement off: the gate is not asked, no hybrid line, the start line exactly as before.
        let off = await fixture.dictate("off", routeID: "qwen17-rolling", consent: [CloudEntry.provider], switches: enhanced)
        written += off.lines
        failures += expectNoHybridLines(off, "HC-01 off")
        failures += expectStart(off, "speech backend start mode=voiceNative route=qwen17-rolling localHotwords=2", "HC-01 off")
        if off.providerCalls != 0 { failures.append("hybrid coordinator HC-01: the gate was asked without the enhancement") }
        guard let localRejection = off.rejection else {
            return failures + ["hybrid coordinator HC-01: the local backend did not stop at its catalog lookup; skipping the rest"]
        }

        // HC-02 Enhancement on, nothing to admit it with: denied, plain local backend.
        let unconfigured = await fixture.dictate("unconfigured", routeID: "qwen17-rolling", consent: enhanceConsent, switches: nil)
        written += unconfigured.lines
        failures += expectLine(unconfigured, "hybrid admission denied reason=notConfigured fallback=localOnly", "HC-02")
        failures += expectStart(unconfigured, "speech backend start mode=voiceNative route=qwen17-rolling localHotwords=2 hybrid=off", "HC-02")
        failures += expectAbsent(unconfigured, "hybrid admission admitted", "HC-02")

        // HC-02b The route switch left on, the enhancement's switch off: the gate refuses the local purpose.
        let residue = CloudEntryPreferences(visible: true, routeEnabled: true, uploadConsent: true, enhanceLocal: false)
        let routeResidue = await fixture.dictate("residue", routeID: "qwen17-rolling", consent: enhanceConsent, switches: residue)
        written += routeResidue.lines
        failures += expectLine(routeResidue, "hybrid admission denied reason=cloudRouteDisabled fallback=localOnly", "HC-02b")
        failures += expectStart(routeResidue, "speech backend start mode=voiceNative route=qwen17-rolling localHotwords=2 hybrid=off", "HC-02b")

        // HC-05 Nothing to enhance: skipped without asking the gate.
        let yue = await fixture.dictate("yue", routeID: "qwen17-rolling", language: "yue", consent: enhanceConsent, switches: enhanced)
        written += yue.lines
        failures += expectNoHybridLines(yue, "HC-05 yue")
        failures += expectStart(yue, "speech backend start mode=voiceNative route=qwen17-rolling localHotwords=2", "HC-05 yue")
        if yue.providerCalls != 0 { failures.append("hybrid coordinator HC-05: the gate was asked for a language the cloud does not take") }
        let other = await fixture.dictate("sensevoice", routeID: "sensevoice", consent: enhanceConsent, switches: enhanced)
        written += other.lines
        failures += expectNoHybridLines(other, "HC-05 sensevoice")
        failures += expectStart(other, "speech backend start mode=voiceNative route=sensevoice localHotwords=2", "HC-05 sensevoice")
        if other.providerCalls != 0 { failures.append("hybrid coordinator HC-05: the gate was asked for a route that cannot be enhanced") }

        // HC-06 The Aliyun route with the enhancement's id in the set: the route's own path, unchanged, no hybrid line.
        let aliyun = await fixture.dictate(
            "aliyun", routeID: CloudEntry.routeID, consent: [CloudEntry.provider, CloudEntry.enhanceConsentID], switches: nil)
        written += aliyun.lines
        failures += expectNoHybridLines(aliyun, "HC-06 aliyun")
        failures += expectLine(aliyun, "cloud admission denied reason=notConfigured fallback=local", "HC-06 aliyun")
        failures += expectStart(aliyun, "speech backend start mode=voiceNative route=qwen17-rolling localHotwords=2", "HC-06 aliyun")

        // HC-04 Withdrawn while the gate is being asked: admitted, but no cloud branch is built, and the dictation
        // itself goes on (neither invalidated nor cancelled: its backend still starts).
        let withdrawn = await fixture.dictate(
            "withdrawn", routeID: "qwen17-rolling", consent: enhanceConsent, switches: enhanced, withdrawWhileAsking: true)
        written += withdrawn.lines
        failures += expectPrefix(withdrawn, "hybrid admission admitted epoch=", "HC-04")
        failures += expectLine(withdrawn, "hybrid skipped reason=consentWithdrawn", "HC-04")
        failures += expectStart(withdrawn, "speech backend start mode=voiceNative route=qwen17-rolling localHotwords=2 hybrid=off", "HC-04")
        if withdrawn.rejection == nil { failures.append("hybrid coordinator HC-04: the withdrawal stopped the dictation itself") }

        // HC-03 Admitted: the hybrid backend is built, keeps the hot words for its local branch, and stops at the
        // same place as the plain local backend. Last, so a cloud branch left draining cannot skew the others.
        let admitted = await fixture.dictate("admitted", routeID: "qwen17-rolling", consent: enhanceConsent, switches: enhanced)
        written += admitted.lines
        failures += expectPrefix(admitted, "hybrid admission admitted epoch=", "HC-03")
        failures += expectAbsent(admitted, "hybrid skipped", "HC-03")
        failures += expectStart(admitted, "speech backend start mode=voiceNative route=qwen17-rolling localHotwords=2 hybrid=aliyun", "HC-03")
        if admitted.providerCalls != 1 { failures.append("hybrid coordinator HC-03: the gate was asked \(admitted.providerCalls) times, expected once") }
        if admitted.rejection != localRejection {
            failures.append("hybrid coordinator HC-03: the hybrid backend stopped at \(admitted.rejection ?? "nothing"), not where the local one does (\(localRejection))")
        }

        // HC-10 Nothing this wiring writes looks like a cloud route started without a permit.
        for line in written where line.hasPrefix("hybrid ") || line.hasPrefix("speech backend start mode=") {
            if line.contains("route=aliyun") || line.contains("cloud admission admitted") {
                failures.append("hybrid coordinator HC-10: \(line)")
            }
        }
        return failures
    }

    private static func expectLine(_ run: WiringRun, _ line: String, _ name: String) -> [String] {
        run.lines.contains(line) ? [] : ["hybrid coordinator \(name): no line \(line.debugDescription) in \(run.lines)"]
    }

    private static func expectPrefix(_ run: WiringRun, _ prefix: String, _ name: String) -> [String] {
        run.lines.contains { $0.hasPrefix(prefix) } ? [] : ["hybrid coordinator \(name): no line starting \(prefix.debugDescription) in \(run.lines)"]
    }

    private static func expectAbsent(_ run: WiringRun, _ prefix: String, _ name: String) -> [String] {
        run.lines.contains { $0.hasPrefix(prefix) } ? ["hybrid coordinator \(name): unexpected \(prefix.debugDescription) in \(run.lines)"] : []
    }

    private static func expectNoHybridLines(_ run: WiringRun, _ name: String) -> [String] {
        let hybrid = run.lines.filter { $0.hasPrefix("hybrid ") || $0.contains(" hybrid=") }
        return hybrid.isEmpty ? [] : ["hybrid coordinator \(name): hybrid lines without the enhancement: \(hybrid)"]
    }

    /// The start line, exactly: nothing may follow what is expected.
    private static func expectStart(_ run: WiringRun, _ line: String, _ name: String) -> [String] {
        let starts = run.lines.filter { $0.hasPrefix("speech backend start mode=") }
        return starts == [line] ? [] : ["hybrid coordinator \(name): start lines \(starts), expected [\(line)]"]
    }
}

/// What one dictation wrote before its backend stopped at the catalog lookup.
private struct WiringRun {
    var lines: [String]
    var providerCalls: Int
    /// The `speech backend start rejected …` line, nil when the backend never started.
    var rejection: String?
}

@MainActor
private final class WiringProbe {
    weak var coordinator: VoicePointerCoordinator?
    var providerCalls = 0
}

@MainActor
private struct WiringFixture {
    let root: URL
    let gate: CloudAdmissionGate
    let credential: CloudEntryCredential

    /// One dictation begun with `consent` (the set the app passes to `gestureBegan`). `switches` are what the
    /// app's provider would read from the settings (nil: no provider, as when the entry is off); with
    /// `withdrawWhileAsking` the provider withdraws every consent before it answers, as unticking the box while
    /// the gate is being asked would.
    func dictate(
        _ name: String,
        routeID: String,
        language: String = "zh",
        consent: Set<String>,
        switches: CloudEntryPreferences?,
        withdrawWhileAsking: Bool = false
    ) async -> WiringRun {
        guard let selection = try? VoiceInputSelection(mode: .voiceNative, routeID: routeID, language: language) else {
            return WiringRun(lines: ["fixture: invalid selection"], providerCalls: 0, rejection: nil)
        }
        let traceURL = root.appendingPathComponent("trace-\(name)-\(UUID().uuidString).log")
        RuntimeTrace.configureForTesting(fileURL: traceURL)
        let probe = WiringProbe()
        let gate = self.gate
        let credential = self.credential
        let provider: CloudAdmissionInputsProvider?
        if let preferences = switches {
            provider = { snapshot in
                probe.providerCalls += 1
                if withdrawWhileAsking { probe.coordinator?.cloudAuthorizationChanged([]) }
                return CloudEntry.inputs(
                    preferences: preferences, gate: gate, credential: credential,
                    purpose: CloudEntryPurpose(routeID: snapshot.selection.routeID)
                )
            }
        } else {
            provider = nil
        }
        let coordinator = VoicePointerCoordinator(
            focusEngine: SmartFocusEngine(provider: WiringFocusProvider()),
            keyboardOwnership: KeyboardOwnershipManager(backend: WiringFailingKeyboard()),
            composerActionExecutor: WiringComposer(),
            cloudAdmissionInputs: provider
        )
        probe.coordinator = coordinator
        coordinator.gestureBegan(
            Self.activation(), settings: VoicePointerSettings(focusMode: .smart),
            selection: selection, cloudConsent: consent, localHotwords: ["OpenAI", "Qwen"])
        var trace = ""
        for _ in 0..<150 {
            RuntimeTrace.flush()
            trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
            if trace.contains("speech backend start rejected") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await coordinator.cancel()
        RuntimeTrace.flush()
        trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? trace
        let lines = Self.messages(trace)
        return WiringRun(
            lines: lines, providerCalls: probe.providerCalls,
            rejection: lines.first { $0.hasPrefix("speech backend start rejected") }
        )
    }

    /// The message part of each trace line (after `session=<id> `); the session header is skipped.
    private static func messages(_ trace: String) -> [String] {
        trace.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#"), let marker = line.range(of: " session=") else { return nil }
            let rest = line[marker.upperBound...]
            guard let space = rest.firstIndex(of: " ") else { return nil }
            return String(rest[rest.index(after: space)...])
        }
    }

    private static func activation() -> GestureActivation {
        GestureActivation(
            location: CGPoint(x: 20, y: 20), button: .left,
            match: GestureMatch(deviceToken: 1, deviceKind: .magicMouse,
                                touchCount: 2, newestTouchAgeSeconds: 0.01,
                                maximumMovement: 0.001)
        )
    }
}

private final class WiringFocusProvider: FocusProviding, @unchecked Sendable {
    private let candidate = FocusCandidate(identifier: "fake", role: "AXTextArea", frame: CGRect(x: 0, y: 0, width: 100, height: 40))
    func snapshot(at _: CGPoint, configuration _: SmartFocusConfiguration) -> FocusSnapshot? {
        FocusSnapshot(contextIdentifier: "fake", bundleIdentifier: nil, candidates: [candidate])
    }
    func setFocused(candidateIdentifier _: String) -> Bool { true }
    func isFocused(candidateIdentifier _: String) -> Bool { true }
    func synthesizeClick(candidateIdentifier _: String) -> Bool { true }
}

private final class WiringComposer: @unchecked Sendable, ComposerActionExecuting {
    func beginSession(cancellationToken: OperationCancellationToken) async -> ComposerSessionStartResult {
        .ready(ComposerActionSession(cancellationToken: cancellationToken))
    }
    func perform(_ action: VoiceReleaseAction, session: ComposerActionSession?) async -> ComposerActionOutcome { .kept }
    func cancel(session: ComposerActionSession?) {}
}

/// Never reaches a real keyboard; the native route does not post keys at all.
private final class WiringFailingKeyboard: KeyboardEventPosting, @unchecked Sendable {
    func post(modifier _: VoiceModifier, isDown _: Bool, marker _: UInt64) -> KeyboardEventPostResult {
        .failed(reason: "hybridWiringProbe")
    }
}
