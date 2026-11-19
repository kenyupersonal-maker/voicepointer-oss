import Foundation

struct SegmentObservation: Sendable {
    let parentID: String
    let segmentIndex: Int
    let startSample: Int
    let endSample: Int
    let response: BetaWorkerResult
    let hostReceivedMilliseconds: Double
}

actor SegmentedInferenceClient: BetaInferenceClient {
    private let base: any BetaInferenceClient
    private let segmentBytes: Int
    /// Every segment is its own worker session, and the worker refuses a session whose context changes, so
    /// each one is given the same context.
    private let context: BetaRecognitionContext?
    private let maxPCM = 300 * 32000
    private var epoch = 0
    private var closed = false
    private var busy = false
    private var parentID: String? = nil
    private var priorPCM = Data()
    private var lastRevision: Int? = nil
    private var committedBytes = 0
    private var segmentIndex = 0
    private var committedTexts: [String] = []
    private var draftText: String? = nil
    private var committedConfidences: [LocalModelConfidence?] = []
    private var draftConfidence: LocalModelConfidence? = nil
    private(set) var observations: [SegmentObservation] = []

    init(base: any BetaInferenceClient, segmentSeconds: Int = 30, context: BetaRecognitionContext? = nil) throws {
        guard (1...30).contains(segmentSeconds) else {
            throw BetaWorkerTransportError(description: "segmentSeconds out of range 1...30")
        }
        self.base = base
        self.segmentBytes = segmentSeconds * 32000
        self.context = context
    }

    private func fail(_ msg: String) -> BetaWorkerTransportError {
        BetaWorkerTransportError(description: msg)
    }

    func start() async throws {
        if closed { throw fail("client closed") }
        try await base.start()
    }

    func shutdown() async {
        epoch += 1
        closed = true
        await base.shutdown()
    }

    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool) async throws -> BetaWorkerResult {
        if closed { throw fail("client closed") }
        if busy { throw fail("client busy") }
        busy = true
        let epoch0 = epoch
        defer { if epoch == epoch0 { busy = false } }
        do {
            try validate(sessionID: sessionID, revision: revision, pcm: pcm)
            let unchangedPartial = lastRevision != nil && pcm == priorPCM && !final
            if parentID == nil { parentID = sessionID; lastRevision = revision; priorPCM = pcm }
            else { lastRevision = revision; priorPCM = pcm }
            if unchangedPartial {
                return combinedResponse(parent: sessionID, revision: revision, final: false, computeMS: 0)
            }
            return try await runSegments(epoch0: epoch0, parent: sessionID, parentRevision: revision, pcm: pcm, final: final)
        } catch {
            guard epoch == epoch0 else { throw error }
            epoch += 1
            closed = true
            busy = false
            await base.shutdown()
            throw error
        }
    }

    /// The context of a segmented client is fixed when it is made (every segment is its own worker session, and
    /// the worker refuses a session whose context changes): a request may repeat it or leave it out.
    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool, context: BetaRecognitionContext?) async throws -> BetaWorkerResult {
        guard context == nil || context == self.context else { throw fail("context differs from the client's") }
        return try await infer(sessionID: sessionID, revision: revision, pcm: pcm, final: final)
    }

    private func validate(sessionID: String, revision: Int, pcm: Data) throws {
        guard !sessionID.isEmpty, sessionID.count <= 100,
              sessionID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) })
        else { throw fail("invalid session id") }
        guard pcm.count % 2 == 0 else { throw fail("odd pcm byte count") }
        guard pcm.count <= maxPCM else { throw fail("pcm exceeds 300s max") }
        if let last = lastRevision {
            guard revision > last else { throw fail("revision must increase") }
        } else {
            guard revision >= 0 else { throw fail("negative revision") }
        }
        if let p = parentID, p != sessionID { throw fail("parent session mismatch") }
        guard pcm.count >= priorPCM.count, pcm.prefix(priorPCM.count) == priorPCM else {
            throw fail("pcm prefix shrank or was rewritten")
        }
    }

    private func runSegments(epoch0: Int, parent: String, parentRevision: Int, pcm: Data, final: Bool) async throws -> BetaWorkerResult {
        var computeMS = 0.0
        while committedBytes < pcm.count {
            if observations.count >= 1000 { throw fail("observation limit exceeded") }
            let n = min(segmentBytes, pcm.count - committedBytes)
            let isSegmentFinal = (n == segmentBytes) || final
            let subID = parent + ".s" + String(segmentIndex)
            let subData = pcm.subdata(in: committedBytes..<(committedBytes + n))
            let resp = try await base.infer(sessionID: subID, revision: parentRevision, pcm: subData, final: isSegmentFinal, context: self.context)
            if Task.isCancelled { throw CancellationError() }
            guard epoch == epoch0 else { throw fail("epoch changed during inference") }
            guard resp.type == "result",
                  resp.session_id == subID,
                  resp.revision == parentRevision,
                  resp.final == isSegmentFinal,
                  let text = resp.text else {
                throw fail("invalid base response for \(subID)")
            }
            guard let c = resp.compute_ms, c.isFinite, c >= 0, (computeMS + c).isFinite else {
                throw fail("invalid compute_ms")
            }
            computeMS += c
            observations.append(SegmentObservation(
                parentID: parent, segmentIndex: segmentIndex,
                startSample: committedBytes / 2, endSample: (committedBytes + n) / 2,
                response: resp, hostReceivedMilliseconds: ProcessInfo.processInfo.systemUptime * 1000))
            if isSegmentFinal {
                committedTexts.append(text)
                committedConfidences.append(resp.confidenceEvidence)
                committedBytes += n
                segmentIndex += 1
                draftText = nil
                draftConfidence = nil
            } else {
                draftText = text
                draftConfidence = resp.confidenceEvidence
                break
            }
        }
        if final { closed = true }
        return combinedResponse(parent: parent, revision: parentRevision, final: final, computeMS: computeMS)
    }

    private func combinedResponse(parent: String, revision: Int, final: Bool, computeMS: Double) -> BetaWorkerResult {
        var parts = committedTexts
        var confidences: [LocalModelConfidence?] = []
        for (text, evidence) in zip(committedTexts, committedConfidences) {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { confidences.append(evidence) }
        }
        if let draftText, !draftText.isEmpty {
            parts.append(draftText)
            if !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { confidences.append(draftConfidence) }
        }
        let evidence = LocalModelConfidence.minimum(confidences)
        return BetaWorkerResult(type: "result", session_id: parent, revision: revision,
                                text: parts.joined(separator: "\n"), final: final, compute_ms: computeMS,
                                model_confidence: evidence?.probability,
                                model_confidence_source: evidence?.source.rawValue,
                                model_confidence_token_count: evidence?.tokenCount)
    }
}
