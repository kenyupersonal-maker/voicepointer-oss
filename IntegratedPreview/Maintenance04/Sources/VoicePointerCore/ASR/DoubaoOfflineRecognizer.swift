// T8 2026-10-02: The selected local worker/pool/converter; one final RAM request, no recording or network.
import Foundation

internal actor DoubaoOfflineRecognizer {
    private let pool: LocalWorkerPool
    private var leaseID: UUID?
    private var epoch: UInt64 = 0
    private let loadProfiles: @Sendable () throws -> [BetaProfile]
    init(pool: LocalWorkerPool, loadProfiles: @escaping @Sendable () throws -> [BetaProfile]) {
        self.pool = pool; self.loadProfiles = loadProfiles
    }
    func cancel() async {
        epoch &+= 1
        if let id = leaseID { leaseID = nil; await pool.release(id: id, discard: true) }
    }
    func recognize(_ audio: DoubaoLearningAudio, selection: VoiceInputSelection,
                   hotwords: [String] = [], context: RecognitionContextPlan? = nil) async throws -> DoubaoOfflineResult? {
        defer { audio.clear() }
        let profiles = try loadProfiles()
        let selected = profiles.first(where: { $0.id == selection.routeID })
        let profile = selected.flatMap { !($0.isApple) && $0.missingFiles.isEmpty ? $0 : nil }
            ?? (selection.mode == .doubao ? profiles.first(where: {
                $0.id == "qwen06-rolling" && $0.missingFiles.isEmpty && $0.languages.contains(selection.language)
            }) : nil)
        guard leaseID == nil, let profile,
              !profile.isApple, profile.missingFiles.isEmpty, profile.languages.contains(selection.language) else { return nil }
        let id = UUID(), generation = epoch
        leaseID = id
        do {
            let startAt = DispatchTime.now().uptimeNanoseconds
            let client = try await pool.acquireBackground(id: id, profileID: profile.id, language: selection.language)
            let startMs = (DispatchTime.now().uptimeNanoseconds - startAt) / 1_000_000
            guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
            var buffers = audio.takeBuffers()
            let accumulator = try BetaPCMAccumulator(maxSeconds: 300)
            let converted = try await accumulator.snapshot(buffers, final: true)
            buffers.removeAll(); audio.clear()
            await accumulator.releaseFinalInputMemory()
            guard !converted.clipped, !converted.data.isEmpty else {
                await pool.release(id: id, discard: true); leaseID = nil; return nil
            }
            let words=RecognitionHotwords.clean(hotwords)
            let prompt=([words.isEmpty ? nil : words.joined(separator: ", ")].compactMap { $0 } + (context?.recent ?? []))
                .joined(separator: "\n")
            var bounded=prompt
            while bounded.utf8.count > BetaRecognitionContext.maximumBytes { bounded.removeLast() }
            let hint=BetaRecognitionContext.supports(profileID: profile.id) ? try? BetaRecognitionContext(text: bounded) : nil
            let segmented = try SegmentedInferenceClient(base: client, segmentSeconds: 30, context: hint)
            let decodeAt = DispatchTime.now().uptimeNanoseconds
            let response = try await segmented.infer(sessionID: id.uuidString, revision: 0, pcm: converted.data, final: true)
            let decodeMs = (DispatchTime.now().uptimeNanoseconds - decodeAt) / 1_000_000
            guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
            await pool.release(id: id, discard: false)
            RuntimeTrace.record("learn recheck startMs=\(startMs) decodeMs=\(decodeMs)")
            if leaseID == id { leaseID = nil }
            guard let text = response.text else { return nil }
            return DoubaoOfflineResult(text: text, confidence: response.confidenceEvidence)
        } catch {
            await pool.release(id: id, discard: true)
            if leaseID == id { leaseID = nil }
            throw error
        }
    }
}
