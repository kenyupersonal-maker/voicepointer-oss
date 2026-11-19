import Foundation
@_spi(Testing) import VoicePointerCore

@MainActor
enum ComposerDeliveryHotfixChecks {
    private final class FakeAX {
        var values: [String?]
        var reads = 0
        var returnCount = 0
        var pending = true
        var cancelled = false
        init(_ values: [String?]) { self.values = values }
        func read() -> String? { defer { reads += 1 }; return values[min(reads, values.count - 1)] }
        func repairCaret() -> Bool { false }
    }
    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("D " + label) } }
        let valid = FakeAX(["abcdefXY", "abcdefXY"])
        var proof = ComposerDeliveryObservation(expected: "abcdXYef", original: "abcdef", inserted: "XY", expectedInsertionLocation: 4)
        expect(!proof.observe(valid.read()), "first shifted read alone cannot confirm")
        let confirmed = proof.observe(valid.read())
        expect(confirmed && proof.matchedInsertionLocation == 6, "caret two units early accepts exact insertion")
        if ComposerConfirmedDeliveryPolicy.permitsAction(documentConfirmed: confirmed, caretConfirmed: valid.repairCaret()) { valid.returnCount += 1 }
        expect(valid.returnCount == 1, "confirmed paste still sends when caret repair fails")
        let invalid = FakeAX(["abcZefXY", "abcZefXY"])
        var rejected = ComposerDeliveryObservation(expected: "abcdXYef", original: "abcdef", inserted: "XY", expectedInsertionLocation: 4)
        _ = rejected.observe(invalid.read())
        let invalidConfirmed = rejected.observe(invalid.read())
        if ComposerConfirmedDeliveryPolicy.permitsAction(documentConfirmed: invalidConfirmed, caretConfirmed: true) { invalid.returnCount += 1 }
        expect(!invalidConfirmed && invalid.returnCount == 0, "same length and present substring are not proof")
        let completion = Task { @MainActor in try? await Task.sleep(for: .milliseconds(5)); valid.pending = false }
        let ready = await ComposerGestureDeferral.wait(maximumMilliseconds: 50) { valid.pending }
        await completion.value
        expect(ready == .ready && !valid.cancelled && valid.returnCount == 1, "queued new press waits without cancelling previous confirmed write")
        let timeout = await ComposerGestureDeferral.wait(maximumMilliseconds: 20) { invalid.pending }
        expect(timeout == .timedOut && invalid.pending && !invalid.cancelled, "bounded wait leaves old confirmation alive")
        let uncertainty = ComposerActionFeedback(outcome: .deliveryUnconfirmed, action: .send)
        expect(uncertainty.message == "没能确认文字写进去，这次没发送，请看一眼输入框" && uncertainty.presentation?.code != .sendPreempted, "honest unconfirmed send hint")
        expect(ComposerActionFeedback(outcome: .targetChanged, action: .send).message == "输入框换了，这次没发送", "honest target-change hint")
        return failures
    }
}
