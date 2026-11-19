// L1C3: fake-based self-test checks for InlineDraftPump.
// Synthetic in-memory fixtures only. No AX, no hardware, no network.

import Foundation
@_spi(Testing) import VoicePointerCore

@MainActor
enum InlineDraftPumpChecks {

    // MARK: - Fake deliverer (records sequence/text, gates first call)

    @MainActor
    private final class FakeDraftDeliverer: InlineTranscriptDelivering, Sendable {
        private(set) var receivedSequences: [UInt64] = []
        private(set) var receivedTexts: [String] = []
        private(set) var inFlight = 0
        private(set) var maxConcurrent = 0
        private(set) var updatesCount = 0
        private(set) var receivedTimes: [TimeInterval] = []
        var outcome: InlineDraftUpdateOutcome = .updated
        private var gateArmed = false
        private var firstGate: CheckedContinuation<Void, Never>?

        func armGate() { gateArmed = true }

        /// Idempotent: resuming a nil gate is a no-op, so callers may defer it.
        func releaseFirst() {
            firstGate?.resume()
            firstGate = nil
        }

        func updateDraft(
            text: String,
            sequence: UInt64,
            session: ComposerActionSession?
        ) async -> InlineDraftUpdateOutcome {
            receivedSequences.append(sequence)
            receivedTimes.append(ProcessInfo.processInfo.systemUptime)
            receivedTexts.append(text)
            updatesCount += 1
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
            if gateArmed {
                gateArmed = false
                // Cancellation is deliberately ignored here until released.
                await withCheckedContinuation { cont in firstGate = cont }
            }
            inFlight -= 1
            return outcome
        }

        func deliver(
            text: String,
            action: VoiceReleaseAction,
            session: ComposerActionSession?
        ) async -> ComposerActionOutcome {
            .kept // unused by these checks
        }
    }

    // MARK: - Helpers

    private static func event(
        _ seq: UInt64,
        _ text: String?,
        speech: UUID,
        sessionID: UUID? = nil,
        kind: SpeechInputEvent.Kind = .partial
    ) -> SpeechInputEvent {
        SpeechInputEvent(
            sessionID: sessionID ?? speech,
            sequence: seq,
            observedMilliseconds: 0,
            kind: kind,
            text: text
        )
    }

    @discardableResult
    private static func waitUntil(
        timeoutMs: Int = 500,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    private static func makePump(
        _ deliverer: FakeDraftDeliverer,
        speech: UUID
    ) -> InlineDraftPump {
        InlineDraftPump(
            deliverer: deliverer,
            session: ComposerActionSession(testIdentifier: 1),
            speechSessionID: speech, minimumIntervalMilliseconds: 0
        )
    }

    private static func freshDeliverer() -> FakeDraftDeliverer {
        FakeDraftDeliverer()
    }

    // MARK: - Checks

    static func run() async -> [String] {
        var failures: [String] = []
        let speech = UUID()
        await checkCoalescing(&failures, speech: speech)
        await checkFinishWhileGated(&failures, speech: speech)
        await checkCancelWhileGated(&failures, speech: speech)
        await checkTerminalOutcomes(&failures, speech: speech)
        await checkNoInitialCandidate(&failures, speech: speech)
        await checkRateLimit(&failures, speech: speech)
        return failures
    }

    private static func checkRateLimit(_ failures: inout [String], speech: UUID) async {
        let deliverer = freshDeliverer()
        let pump = InlineDraftPump(deliverer: deliverer, session: ComposerActionSession(testIdentifier: 1), speechSessionID: speech)
        pump.enqueue(event(0, "synthetic first", speech: speech))
        guard await waitUntil({ deliverer.updatesCount == 1 && !pump.isUpdating }) else { failures.append("rate first"); return }
        for seq in 1...10 { pump.enqueue(event(UInt64(seq), "synthetic latest", speech: speech)) }
        guard await waitUntil(timeoutMs: 1000, { !pump.isUpdating }) else { failures.append("rate drain"); return }
        if deliverer.receivedSequences != [0, 10] { failures.append("rate must coalesce") }
        if deliverer.receivedTimes.count == 2, deliverer.receivedTimes[1] - deliverer.receivedTimes[0] < 0.295 { failures.append("rate under 300ms") }
        pump.enqueue(event(11, "must not write after finish", speech: speech))
        let began = ProcessInfo.processInfo.systemUptime
        await pump.finish()
        if ProcessInfo.processInfo.systemUptime - began > 0.1 { failures.append("finish unnecessarily waits throttle") }
        if deliverer.updatesCount != 2 { failures.append("late throttled write after finish") }
    }

    private static func checkCoalescing(_ failures: inout [String], speech: UUID) async {
        let deliverer = freshDeliverer()
        defer { deliverer.releaseFirst() }
        deliverer.armGate()
        let pump = makePump(deliverer, speech: speech)
        pump.enqueue(event(0, "zero", speech: speech))
        guard await waitUntil({ deliverer.updatesCount == 1 }) else {
            failures.append("C1: first updateDraft never started")
            return
        }
        pump.enqueue(event(1, "one", speech: speech))
        pump.enqueue(event(2, "two", speech: speech))
        pump.enqueue(event(2, "two-dup", speech: speech))
        pump.enqueue(event(1, "old", speech: speech))
        pump.enqueue(event(99, "wrong-uuid", speech: speech, sessionID: UUID()))
        pump.enqueue(event(3, "final", speech: speech, kind: .final))
        pump.enqueue(event(4, nil, speech: speech))
        deliverer.releaseFirst()
        guard await waitUntil({ !pump.isUpdating }) else {
            failures.append("C1: pump never drained to idle")
            return
        }
        if deliverer.receivedSequences != [0, 2] {
            failures.append("C1: sequences \(deliverer.receivedSequences) != [0, 2]")
        }
        if deliverer.receivedTexts != ["zero", "two"] {
            failures.append("C1: texts \(deliverer.receivedTexts) != [zero, two]")
        }
        if deliverer.maxConcurrent != 1 {
            failures.append("C1: maxConcurrent \(deliverer.maxConcurrent) != 1")
        }
    }

    private static func checkFinishWhileGated(_ failures: inout [String], speech: UUID) async {
        let deliverer = freshDeliverer()
        defer { deliverer.releaseFirst() }
        deliverer.armGate()
        let pump = makePump(deliverer, speech: speech)
        pump.enqueue(event(0, "zero", speech: speech))
        guard await waitUntil({ deliverer.updatesCount == 1 }) else {
            failures.append("C2: first updateDraft never started")
            return
        }
        pump.enqueue(event(1, "one", speech: speech))
        let box = FinishFlag()
        let finishTask = Task { await pump.finish(); box.value = true }
        try? await Task.sleep(nanoseconds: 1_000_000)
        if box.value { failures.append("C2: finish returned while first still gated") }
        deliverer.releaseFirst()
        await finishTask.value
        if !box.value { failures.append("C2: finish never completed after release") }
        if deliverer.receivedSequences != [0] {
            failures.append("C2: sequences \(deliverer.receivedSequences) != [0]")
        }
        pump.enqueue(event(2, "two", speech: speech))
        try? await Task.sleep(nanoseconds: 2_000_000)
        if deliverer.updatesCount != 1 {
            failures.append("C2: enqueue after finish was not ignored")
        }
    }

    private static func checkCancelWhileGated(_ failures: inout [String], speech: UUID) async {
        let deliverer = freshDeliverer()
        defer { deliverer.releaseFirst() }
        deliverer.armGate()
        let pump = makePump(deliverer, speech: speech)
        pump.enqueue(event(0, "zero", speech: speech))
        guard await waitUntil({ deliverer.updatesCount == 1 }) else {
            failures.append("C3: first updateDraft never started")
            return
        }
        pump.enqueue(event(1, "one", speech: speech))
        pump.cancel()
        pump.enqueue(event(2, "two", speech: speech))
        deliverer.releaseFirst()
        guard await waitUntil({ !pump.isUpdating }) else {
            failures.append("C3: pump never went idle after cancel")
            return
        }
        if deliverer.receivedSequences != [0] {
            failures.append("C3: sequences \(deliverer.receivedSequences) != [0]")
        }
    }

    private static func checkTerminalOutcomes(_ failures: inout [String], speech: UUID) async {
        for outcome in [InlineDraftUpdateOutcome.unsupported, .abandoned, .unconfirmed] {
            let deliverer = freshDeliverer()
            deliverer.outcome = outcome
            let pump = makePump(deliverer, speech: speech)
            pump.enqueue(event(0, "zero", speech: speech))
            guard await waitUntil({ deliverer.updatesCount == 1 && !pump.isUpdating }) else {
                failures.append("C4(\(outcome)): first update never completed")
                continue
            }
            pump.enqueue(event(1, "one", speech: speech))
            try? await Task.sleep(nanoseconds: 5_000_000)
            if deliverer.updatesCount != 1 {
                failures.append("C4(\(outcome)): later draft was not stopped")
            }
        }
    }

    private static func checkNoInitialCandidate(_ failures: inout [String], speech: UUID) async {
        let deliverer = freshDeliverer()
        defer { deliverer.releaseFirst() }
        let pump = makePump(deliverer, speech: speech)
        pump.enqueue(event(9, "wrong-uuid", speech: speech, sessionID: UUID()))
        pump.enqueue(event(1, "ready", speech: speech, kind: .ready))
        pump.enqueue(event(2, "final", speech: speech, kind: .final))
        pump.enqueue(event(3, nil, speech: speech))
        pump.enqueue(event(UInt64.max, "max", speech: speech))
        try? await Task.sleep(nanoseconds: 2_000_000)
        if deliverer.updatesCount != 0 {
            failures.append("C5: ineligible events produced an updateDraft")
        }
        pump.enqueue(event(0, "zero", speech: speech))
        guard await waitUntil({ deliverer.updatesCount == 1 }) else {
            failures.append("C5: valid seq0 rejected after ineligible events")
            return
        }
        if deliverer.receivedSequences != [0] {
            failures.append("C5: sequences \(deliverer.receivedSequences) != [0]")
        }
    }
}

@MainActor
private final class FinishFlag {
    var value = false
}
