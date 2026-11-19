import Foundation

private actor ConfidenceSegmentClient: BetaInferenceClient {
    private let results: [(String, LocalModelConfidence?)]
    private(set) var calls = 0
    init(_ results: [(String, LocalModelConfidence?)]) { self.results = results }
    func start() async throws {}
    func shutdown() async {}
    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool) async throws -> BetaWorkerResult {
        try await infer(sessionID: sessionID, revision: revision, pcm: pcm, final: final, context: nil)
    }
    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool, context: BetaRecognitionContext?) async throws -> BetaWorkerResult {
        guard calls < results.count else { throw TrialCoreError.invalid("CONFIDENCE_PROBE_EXCESS_CALL") }
        let (text, score) = results[calls]; calls += 1
        return BetaWorkerResult(type: "result", session_id: sessionID, revision: revision, text: text,
                                final: final, compute_ms: 1, model_confidence: score?.probability,
                                model_confidence_source: score?.source.rawValue,
                                model_confidence_token_count: score?.tokenCount)
    }
}

/// Production segment reconstruction and event contracts, with in-memory synthetic PCM/results only.
@_spi(Testing) public enum LocalConfidenceTesting {
    public static func run() async -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) { if !condition { failures.append("local confidence: " + label) } }
        let source = LocalModelConfidence.Source.qwenSelectedTokenMinimum.rawValue
        let high = LocalModelConfidence(probability: 0.99, source: source, tokenCount: 5)!
        let lower = LocalModelConfidence(probability: 0.92, source: source, tokenCount: 8)!
        for value in [Double.nan, .infinity, -0.1, 1.1] {
            check(LocalModelConfidence(probability: value, source: source, tokenCount: 1) == nil, "invalid probability missing")
        }
        check(LocalModelConfidence(probability: 0.9, source: "unknown", tokenCount: 1) == nil, "unknown source missing")
        check(LocalModelConfidence(probability: 0.9, source: source, tokenCount: 0) == nil, "empty token set missing")
        check(LocalModelConfidence.minimum([high, nil]) == nil, "one missing segment invalidates aggregation")
        let full = LocalModelConfidence(probability: 1, source: source, tokenCount: 1_000_000)!
        check(LocalModelConfidence.minimum([full, high]) == nil, "aggregate count bounded")
        let legacy = try? JSONDecoder().decode(BetaWorkerResult.self, from: Data(#"{"type":"result","text":"SYNTHETIC"}"#.utf8))
        check(legacy?.confidenceEvidence == nil, "old worker remains compatible and missing")
        let clipped = BetaEvent(session_id: "synthetic", revision: 1, text: "SYNTHETIC", final: true,
                                wall_ms: 1, audio_ms: 1, compute_ms: 1, clipped: true,
                                model_confidence: high.probability, model_confidence_source: source,
                                model_confidence_token_count: high.tokenCount)
        check(clipped.confidenceEvidence == nil, "clipped input cannot provide learning evidence")
        do {
            // Draft -> cached unchanged -> finalized same segment. Cache must preserve evidence without a call.
            let base = ConfidenceSegmentClient([("SYNTHETIC", high), ("SYNTHETIC", lower)])
            let client = try SegmentedInferenceClient(base: base, segmentSeconds: 1)
            let pcm = Data(repeating: 1, count: 16000)
            let draft = try await client.infer(sessionID: "synthetic", revision: 1, pcm: pcm, final: false)
            let cached = try await client.infer(sessionID: "synthetic", revision: 2, pcm: pcm, final: false)
            check(draft.confidenceEvidence == high && cached.confidenceEvidence == high, "draft and cache preserve score")
            let cachedCalls = await base.calls
            check(cachedCalls == 1 && cached.compute_ms == 0, "cached score adds no inference")
            let final = try await client.infer(sessionID: "synthetic", revision: 3, pcm: pcm, final: true)
            let finalCalls = await base.calls
            check(final.confidenceEvidence == lower && finalCalls == 2, "finalized score replaces draft")
            await client.shutdown()
            let cases: [[(String, LocalModelConfidence?)]] = [
                [("SYNTHETIC_A", high), ("SYNTHETIC_B", lower)],
                [("SYNTHETIC_A", high), ("SYNTHETIC_B", nil)],
                [("", nil), ("SYNTHETIC_B", lower)]
            ]
            for (index, results) in cases.enumerated() {
                let base = ConfidenceSegmentClient(results)
                let client = try SegmentedInferenceClient(base: base, segmentSeconds: 1)
                let result = try await client.infer(sessionID: "synthetic", revision: 1,
                                                    pcm: Data(repeating: 1, count: 64000), final: true)
                let expected = index == 0 ? LocalModelConfidence.minimum([high, lower]) : (index == 1 ? nil : lower)
                check(result.confidenceEvidence == expected, "nonempty segment minimum or missing")
                check(await base.calls == 2, "two segments keep two original inference calls")
                await client.shutdown()
            }
        } catch { failures.append("local confidence: synthetic segment execution failed") }
        print("event=local_confidence_checks failures=\(failures.count) additional_inference=0 synthetic=1")
        return failures
    }
}
