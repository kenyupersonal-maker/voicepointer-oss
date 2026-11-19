@preconcurrency import AVFoundation
import Foundation

actor BetaPCMAccumulator {
    let maxBytes: Int
    private var converter: PersistentPCMConverter?
    private var framesSeen = 0
    private var acceptedBuffers: [OwnedPCMBuffer] = []
    private var sourceFormat: AVAudioFormat?
    private var data = Data()
    private var clipped = false
    private var finished = false

    init(maxSeconds: Int = 60) throws {
        guard (1...300).contains(maxSeconds) else { throw TrialCoreError.invalid("INVALID_MAX_SECONDS") }
        maxBytes = maxSeconds * 32_000
    }

    func snapshot(_ source: [OwnedPCMBuffer], final: Bool) throws -> (data: Data, clipped: Bool) {
        guard !finished else { throw TrialCoreError.invalid("PCM_FINAL_ALREADY_RECEIVED") }
        guard source.count >= acceptedBuffers.count else { throw TrialCoreError.invalid("PCM_SNAPSHOT_SHRANK") }
        for index in acceptedBuffers.indices {
            guard source[index] === acceptedBuffers[index] else {
                throw TrialCoreError.invalid("PCM_SNAPSHOT_BUFFER_CHANGED")
            }
        }
        let total = source.reduce(0) { $0 + Int($1.buffer.frameLength) }
        guard total >= framesSeen else { throw TrialCoreError.invalid("PCM_SNAPSHOT_SHRANK") }
        if let first = source.first {
            if let format = sourceFormat {
                guard format.sampleRate == first.buffer.format.sampleRate,
                      format.channelCount == first.buffer.format.channelCount else {
                    throw TrialCoreError.invalid("SOURCE_FORMAT_CHANGED")
                }
            } else {
                guard first.buffer.format.sampleRate.isFinite else { throw TrialCoreError.invalid("INVALID_SAMPLE_RATE") }
                sourceFormat = first.buffer.format
                let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
                converter = PersistentPCMConverter(source: first.buffer.format, target: target)
                guard converter != nil else { throw TrialCoreError.invalid("AUDIO_CONVERTER_UNAVAILABLE") }
            }
        }
        var skip = framesSeen
        for owned in source {
            let count = Int(owned.buffer.frameLength)
            if skip >= count { skip -= count; continue }
            guard skip == 0 else { throw TrialCoreError.invalid("PCM_SNAPSHOT_BUFFER_CHANGED") }
            guard let converter else { throw TrialCoreError.invalid("AUDIO_CONVERTER_UNAVAILABLE") }
            try append(try converter.convert(owned))
            framesSeen += count
        }
        if final {
            if let converter { try append(try converter.flush()) }
            finished = true
        }
        acceptedBuffers = source
        return (data, clipped)
    }

    private func append(_ outputs: [OwnedPCMBuffer]) throws {
        for owned in outputs {
            let list = UnsafeMutableAudioBufferListPointer(owned.buffer.mutableAudioBufferList)
            for buffer in list {
                guard let bytes = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize)
                guard count >= 0 else { throw TrialCoreError.invalid("AUDIO_LAYOUT_INVALID") }
                let room = maxBytes - data.count
                if count > room { if room > 0 { data.append(Data(bytes: bytes, count: room)) }; clipped = true; return }
                data.append(Data(bytes: bytes, count: count))
            }
        }
    }
    // T8: A one-shot offline caller releases raw buffers/converter immediately after the final PCM conversion.
    func releaseFinalInputMemory() {
        guard finished else { return }
        acceptedBuffers = []; sourceFormat = nil; converter = nil; data = Data()
    }
}

struct BetaEvent: Codable, Sendable {
    let session_id: String
    let revision: Int
    let text: String
    let final: Bool
    let wall_ms: Double
    let audio_ms: Double
    let compute_ms: Double
    let clipped: Bool
    var committed_text: String? = nil
    var draft_text: String? = nil
    var segment_count: Int? = nil
    var model_confidence: Double? = nil
    var model_confidence_source: String? = nil
    var model_confidence_token_count: Int? = nil

    var confidenceEvidence: LocalModelConfidence? {
        guard !clipped, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LocalModelConfidence(probability: model_confidence, source: model_confidence_source,
                                    tokenCount: model_confidence_token_count)
    }
}

/// Shared by the microphone UI, paced file playback and fake-worker regression.
/// There is one conversion/inference job and at most one pending audio snapshot.
@MainActor
final class BetaSession {
    private struct Request {
        let revision: Int
        let buffers: [OwnedPCMBuffer]
        let final: Bool
    }
    let id: String
    let startedAt: TimeInterval
    private let client: any BetaInferenceClient
    private var nextRevision = 0
    private var pending: Request?
    private var task: Task<Void, Never>?
    private var closing = false
    private let accumulator: BetaPCMAccumulator
    private var completed: Result<BetaEvent, Error>?
    private var waiter: CheckedContinuation<BetaEvent, Error>?
    private(set) var events: [BetaEvent] = []
    private(set) var skippedRequests = 0
    func throwIfFailed() throws {
        if case .failure(let error) = completed { throw error }
    }
    var onEvent: ((BetaEvent) -> Void)?
    var onCompletion: ((Result<BetaEvent, Error>) -> Void)?

    init(client: any BetaInferenceClient, maxSeconds: Int = 60, id: String = UUID().uuidString,
         startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.client = client
        self.id = id
        self.startedAt = startedAt
        precondition((1...300).contains(maxSeconds))
        self.accumulator = try! BetaPCMAccumulator(maxSeconds: maxSeconds)
    }

    func offer(_ buffers: [OwnedPCMBuffer], final: Bool = false) {
        guard completed == nil, !closing else { return }
        if final { closing = true }
        nextRevision += 1
        let request = Request(revision: nextRevision, buffers: buffers, final: final)
        if task != nil {
            if pending != nil { skippedRequests += 1 }
            pending = request // no draft can arrive once final sets closing
        } else {
            launch(request)
        }
    }

    func cancel() {
        guard completed == nil else { return }
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func waitForFinal() async throws -> BetaEvent {
        if let completed { return try completed.get() }
        guard waiter == nil else { throw TrialCoreError.invalid("DUPLICATE_FINAL_WAITER") }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    private func launch(_ request: Request) {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let converted = try await self.accumulator.snapshot(request.buffers, final: request.final)
                guard self.completed == nil else { return }
                try Task.checkCancellation()
                let response = try await self.client.infer(
                    sessionID: self.id, revision: request.revision, pcm: converted.data, final: request.final
                )
                guard self.completed == nil else { return }
                try Task.checkCancellation()
                guard response.type == "result", response.session_id == self.id,
                      response.revision == request.revision, response.final == request.final,
                      let text = response.text, let compute = response.compute_ms,
                      compute.isFinite, compute >= 0 else {
                    throw TrialCoreError.invalid("SESSION_RESPONSE_MISMATCH")
                }
                let event = BetaEvent(
                    session_id: self.id, revision: request.revision, text: text, final: request.final,
                    wall_ms: (ProcessInfo.processInfo.systemUptime - self.startedAt) * 1000,
                    audio_ms: Double(converted.data.count) / 32, compute_ms: compute,
                    clipped: converted.clipped, committed_text: response.committed_text,
                    draft_text: response.draft_text, segment_count: response.segment_count,
                    model_confidence: converted.clipped ? nil : response.confidenceEvidence?.probability,
                    model_confidence_source: converted.clipped ? nil : response.confidenceEvidence?.source.rawValue,
                    model_confidence_token_count: converted.clipped ? nil : response.confidenceEvidence?.tokenCount
                )
                self.events.append(event)
                if self.events.count > 512 { self.events.removeFirst(self.events.count - 512) }
                self.onEvent?(event)
                if request.final {
                    self.finish(.success(event))
                } else {
                    self.task = nil
                    if let next = self.pending {
                        self.pending = nil
                        self.launch(next)
                    }
                }
            } catch {
                guard self.completed == nil else { return }
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<BetaEvent, Error>) {
        guard completed == nil else { return }
        completed = result
        pending = nil
        task = nil
        waiter?.resume(with: result)
        waiter = nil
        onCompletion?(result)
    }
}

struct RollingFileAudio: Sendable {
    let buffers: [OwnedPCMBuffer]
    let rate: Double
    let frames: Int64
    var duration: Double { Double(frames) / rate }

    nonisolated static func load(_ path: String, maxSeconds: Int = 60) throws -> RollingFileAudio {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, (8_000...96_000).contains(format.sampleRate),
              (1...2).contains(Int(format.channelCount)), file.length >= 0,
              Double(file.length) / format.sampleRate <= Double(maxSeconds) else {
            throw TrialCoreError.invalid("FILE_REQUIRE_MONO_OR_STEREO_AT_MOST_\(maxSeconds)_SECONDS")
        }
        let blockSize = AVAudioFrameCount(max(1, Int(format.sampleRate / 50)))
        var buffers: [OwnedPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else {
                throw TrialCoreError.invalid("AUDIO_ALLOCATION_FAILED")
            }
            try file.read(into: buffer, frameCount: blockSize)
            guard buffer.frameLength > 0 else { throw TrialCoreError.invalid("FILE_UNEXPECTED_EOF") }
            buffers.append(try OwnedPCMBuffer(copying: buffer))
        }
        return RollingFileAudio(buffers: buffers, rate: format.sampleRate, frames: file.length)
    }
}

struct RollingFileReport: Codable, Sendable {
    let file: String
    let session_id: String
    let strategy: String
    let duration_s: Double
    let first_nonempty_ms: Double?
    let eof_ms: Double
    let eof_to_final_ms: Double
    let skipped_requests: Int
    let events: [BetaEvent]
}

@MainActor
enum RollingFileRunner {
    static func run(path: String, client: any BetaInferenceClient) async throws -> RollingFileReport {
        let audio = try await Task.detached { try RollingFileAudio.load(path) }.value
        try await client.start()
        let started = ProcessInfo.processInfo.systemUptime
        let session = BetaSession(client: client, startedAt: started)
        let captured = CapturedPCMStore()
        var frames: Int64 = 0
        var nextTick = 1.5
        for buffer in audio.buffers {
            try session.throwIfFailed()
            frames += Int64(buffer.buffer.frameLength)
            let elapsedAudio = Double(frames) / audio.rate
            let due = started + elapsedAudio
            while ProcessInfo.processInfo.systemUptime < due {
                let left = due - ProcessInfo.processInfo.systemUptime
                if left > 0 { try await Task.sleep(for: .seconds(left)) }
            }
            guard captured.append(buffer) else { throw TrialCoreError.invalid("FILE_CAPTURE_FAILED") }
            if elapsedAudio >= nextTick {
                session.offer(captured.snapshot())
                while nextTick <= elapsedAudio { nextTick += 0.5 }
            }
        }
        let eof = (ProcessInfo.processInfo.systemUptime - started) * 1000
        captured.seal()
        session.offer(captured.snapshot(), final: true)
        let final = try await session.waitForFinal()
        return RollingFileReport(
            file: path, session_id: session.id, strategy: "rolling_full_prefix_experiment",
            duration_s: audio.duration,
            first_nonempty_ms: session.events.first(where: { !$0.text.isEmpty })?.wall_ms,
            eof_ms: eof, eof_to_final_ms: final.wall_ms - eof,
            skipped_requests: session.skippedRequests, events: session.events
        )
    }
}
