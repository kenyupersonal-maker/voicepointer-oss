@preconcurrency import AVFoundation
import Foundation
import Speech

enum JSONValue: Encodable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct LiveEvent: Encodable, Sendable {
    let event_type: String
    let session_id: String
    let segment_id: String?
    let revision: Int
    let partial: Bool
    let segment_final: Bool
    let session_finished: Bool
    let text: String?
    let error: String?
    let timestamp_ms: Double
    let monotonic_ms: Double
    let metadata: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case event_type, session_id, segment_id, revision, partial, segment_final
        case session_finished, text, error, timestamp_ms, monotonic_ms, metadata
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event_type, forKey: .event_type)
        try container.encode(session_id, forKey: .session_id)
        try container.encode(segment_id, forKey: .segment_id)
        try container.encode(revision, forKey: .revision)
        try container.encode(partial, forKey: .partial)
        try container.encode(segment_final, forKey: .segment_final)
        try container.encode(session_finished, forKey: .session_finished)
        try container.encode(text, forKey: .text)
        try container.encode(error, forKey: .error)
        try container.encode(timestamp_ms, forKey: .timestamp_ms)
        try container.encode(monotonic_ms, forKey: .monotonic_ms)
        try container.encode(metadata, forKey: .metadata)
    }
}

final class SessionEventGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

actor JSONLWriter {
    private let sessionID: String
    private let startedUptime: Double
    private var closed = false

    init(sessionID: String, startedUptime: Double = ProcessInfo.processInfo.systemUptime) {
        self.sessionID = sessionID
        self.startedUptime = startedUptime
    }

    func emit(
        _ type: String,
        text: String? = nil,
        revision: Int = 0,
        error: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        guard !closed else { return }
        let event = LiveEvent(
            event_type: type,
            session_id: sessionID,
            segment_id: type == "partial" || type == "segment_final" ? "transcript" : nil,
            revision: revision,
            partial: type == "partial",
            segment_final: type == "segment_final",
            session_finished: type == "session_finished",
            text: text,
            error: error,
            timestamp_ms: Date().timeIntervalSince1970 * 1000,
            monotonic_ms: (ProcessInfo.processInfo.systemUptime - startedUptime) * 1000,
            metadata: metadata
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(event)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            Darwin.exit(74)
        }
        if type == "session_finished" || type == "error" { closed = true }
    }

    func emit(_ event: LiveEvent) {
        guard !closed else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(event)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            Darwin.exit(74)
        }
        if event.event_type == "session_finished" || event.event_type == "error" {
            closed = true
        }
    }
}

enum TrialState: Equatable, Sendable {
    case idle, requesting, recording, finalizing, finished, cancelled
    case failed(String)
}

struct TrialStateMachine: Sendable {
    private(set) var state: TrialState = .idle
    private(set) var generation: UInt64 = 0

    mutating func beginRequest() throws {
        guard state == .idle || state == .finished || state == .cancelled || isFailed else {
            throw TrialCoreError.invalid("SESSION_ALREADY_ACTIVE")
        }
        generation &+= 1
        state = .requesting
    }

    mutating func beginRecording() throws {
        guard state == .requesting else { throw TrialCoreError.invalid("INVALID_RECORDING_TRANSITION") }
        state = .recording
    }

    mutating func beginFinalizing() throws {
        guard state == .recording else { throw TrialCoreError.invalid("INVALID_FINALIZE_TRANSITION") }
        state = .finalizing
    }

    mutating func finish() throws {
        guard state == .finalizing else { throw TrialCoreError.invalid("INVALID_FINISH_TRANSITION") }
        state = .finished
    }

    mutating func cancel() { state = .cancelled }
    mutating func fail(_ error: String) { state = .failed(error) }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

enum TrialCoreError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalid(String)
    var description: String {
        if case .invalid(let value) = self { return value }
        return "UNKNOWN"
    }
}

struct NativeAssembly: Sendable {
    struct Part: Sendable, Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    private(set) var finals: [Part] = []
    private(set) var volatile: Part?

    mutating func update(start: Double, end: Double, text: String, isFinal: Bool) throws {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else {
            throw TrialCoreError.invalid("INVALID_NATIVE_AUDIO_RANGE")
        }
        if isFinal {
            if let duplicate = finals.first(where: {
                abs($0.start - start) < 0.00001 && abs($0.end - end) < 0.00001
            }) {
                guard duplicate.text == text else { throw TrialCoreError.invalid("CONFLICTING_NATIVE_FINAL") }
                return
            }
            guard !finals.contains(where: {
                start < $0.end - 0.00001 && end > $0.start + 0.00001
            }) else { throw TrialCoreError.invalid("OVERLAPPING_NATIVE_FINAL") }
            finals.append(Part(start: start, end: end, text: text))
            finals.sort { $0.start < $1.start }
            // Apple may tighten a volatile range when it publishes its final.
            // Match the current segment by its start, not by containment; a
            // later segment with another start must remain volatile.
            if let current = volatile, abs(current.start - start) < 0.00001 {
                volatile = nil
            }
        } else {
            guard !finals.contains(where: {
                start < $0.end - 0.00001 && end > $0.start + 0.00001
            }) else { throw TrialCoreError.invalid("PARTIAL_OVERLAPS_NATIVE_FINAL") }
            volatile = Part(start: start, end: end, text: text)
        }
    }

    var preview: String { finals.map(\.text).joined() + (volatile?.text ?? "") }

    func finished() throws -> String {
        guard volatile == nil else { throw TrialCoreError.invalid("NATIVE_STREAM_ENDED_WITH_PARTIAL") }
        return finals.map(\.text).joined()
    }
}

private final class ConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer?
    private let endOfStream: Bool
    private var used = false
    private let lock = NSLock()

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer; endOfStream = false }
    init(endOfStream: Bool) { buffer = nil; self.endOfStream = endOfStream }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        if used {
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        used = true
        if let buffer { status.pointee = .haveData; return buffer }
        status.pointee = .endOfStream
        return nil
    }
}

final class PersistentPCMConverter: @unchecked Sendable {
    let sourceFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var didFlush = false

    init?(source: AVAudioFormat, target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        sourceFormat = source
        targetFormat = target
        self.converter = converter
    }

    func convert(_ input: OwnedPCMBuffer) throws -> [OwnedPCMBuffer] {
        guard !didFlush else { throw TrialCoreError.invalid("CONVERTER_USED_AFTER_FLUSH") }
        guard sameFormat(input.buffer.format, sourceFormat) else {
            throw TrialCoreError.invalid("SOURCE_FORMAT_CHANGED")
        }
        let ratio = max(0.01, targetFormat.sampleRate / sourceFormat.sampleRate)
        let expectedOutputFrames = Double(input.buffer.frameLength) * ratio
        let requiredIterations = Int(ceil(expectedOutputFrames / 1024.0)) + 32
        return try drain(callback: ConverterInput(buffer: input.buffer),
                          maximumIterations: max(64, requiredIterations))
    }

    func flush() throws -> [OwnedPCMBuffer] {
        guard !didFlush else { return [] }
        didFlush = true
        return try drain(callback: ConverterInput(endOfStream: true), maximumIterations: 4096)
    }

    private func drain(callback: ConverterInput, maximumIterations: Int) throws -> [OwnedPCMBuffer] {
        var outputs: [OwnedPCMBuffer] = []
        var iterations = 0
        while iterations < maximumIterations {
            iterations += 1
            let ratio = max(0.01, targetFormat.sampleRate / sourceFormat.sampleRate)
            let estimated = Int(ceil(Double(max(1, sourceFormat.sampleRate > 0 ? 2048 : 1)) * ratio))
            let capacity = max(1024, estimated + 4096)
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(capacity)
            ) else { throw TrialCoreError.invalid("AUDIO_ALLOCATION_FAILED") }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                callback.next(state)
            }
            if let conversionError { throw conversionError }
            if status == .error { throw TrialCoreError.invalid("AUDIO_CONVERSION_FAILED") }
            if output.frameLength > 0 {
                guard let owned = OwnedPCMBuffer(output) else {
                    throw TrialCoreError.invalid("AUDIO_ALLOCATION_FAILED")
                }
                outputs.append(owned)
            }
            if status == .endOfStream || status == .inputRanDry {
                return outputs
            }
        }
        throw TrialCoreError.invalid("AUDIO_CONVERSION_DRAIN_LIMIT")
    }

    private func sameFormat(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        abs(lhs.sampleRate - rhs.sampleRate) < 0.000001 && lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat && lhs.isInterleaved == rhs.isInterleaved
    }
}

@available(macOS 26.0, *)
private struct AnalyzerBufferSequence: AsyncSequence, @unchecked Sendable {
    typealias Element = AnalyzerInput

    struct AsyncIterator: AsyncIteratorProtocol, @unchecked Sendable {
        var input: AsyncThrowingStream<OwnedPCMBuffer, Error>.Iterator
        var pending: [OwnedPCMBuffer] = []
        let converter: PersistentPCMConverter
        let onInputStarted: @Sendable () async throws -> Void
        let onInputFinished: @Sendable () async throws -> Void
        var first: OwnedPCMBuffer?
        var flushed = false
        var inputFinished = false
        var inputStarted = false

        mutating func next() async throws -> AnalyzerInput? {
            try Task.checkCancellation()
            while pending.isEmpty {
                if let first {
                    self.first = nil
                    pending = try converter.convert(first)
                    continue
                }
                if !flushed {
                    guard let next = try await input.next() else {
                        try Task.checkCancellation()
                        flushed = true
                        pending = try converter.flush()
                        try Task.checkCancellation()
                        if !inputFinished {
                            inputFinished = true
                            try await onInputFinished()
                        }
                        continue
                    }
                    try Task.checkCancellation()
                    pending = try converter.convert(next)
                    continue
                }
                return nil
            }
            let owned = pending.removeFirst()
            try Task.checkCancellation()
            if !inputStarted {
                inputStarted = true
                try await onInputStarted()
            }
            try Task.checkCancellation()
            return AnalyzerInput(buffer: owned.buffer)
        }
    }

    let input: AsyncThrowingStream<OwnedPCMBuffer, Error>.Iterator
    let first: OwnedPCMBuffer
    let converter: PersistentPCMConverter
    let onInputStarted: @Sendable () async throws -> Void
    let onInputFinished: @Sendable () async throws -> Void

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(input: input, converter: converter,
                       onInputStarted: onInputStarted, onInputFinished: onInputFinished, first: first)
    }
}

@MainActor
@available(macOS 26.0, *)
final class Recognizer {
    typealias EventHandler = @Sendable (LiveEvent) async -> Void
    private var activeAnalyzer: SpeechAnalyzer?

    func run(
        input: AsyncThrowingStream<OwnedPCMBuffer, Error>,
        sessionID: String,
        locale: Locale,
        mode: String,
        sourceHash: String? = nil,
        sourceDuration: Double? = nil,
        sessionStartUptime: Double? = nil,
        onEvent: @escaping EventHandler,
        eventGate: SessionEventGate? = nil,
        timeout: Duration = .seconds(90)
    ) async throws {
        let sessionClock = sessionStartUptime ?? ProcessInfo.processInfo.systemUptime
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.perform(input: input, sessionID: sessionID, locale: locale,
                                       mode: mode, sourceHash: sourceHash, sourceDuration: sourceDuration,
                                       startedUptime: sessionClock, onEvent: onEvent, eventGate: eventGate)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TrialCoreError.invalid("RECOGNITION_TIMEOUT")
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                await cancelActiveAnalyzer()
                throw error
            }
        }
    }

    private func perform(
        input: AsyncThrowingStream<OwnedPCMBuffer, Error>,
        sessionID: String,
        locale requestedLocale: Locale,
        mode: String,
        sourceHash: String?,
        sourceDuration: Double?,
        startedUptime: Double,
        onEvent: @escaping EventHandler,
        eventGate: SessionEventGate?
    ) async throws {
        let emit: @Sendable (LiveEvent) async throws -> Void = { event in
            try Task.checkCancellation()
            guard eventGate?.isOpen ?? true else { throw CancellationError() }
            await onEvent(event)
            try Task.checkCancellation()
            guard eventGate?.isOpen ?? true else { throw CancellationError() }
        }

        try Task.checkCancellation()
        var iterator = input.makeAsyncIterator()
        guard let first = try await iterator.next() else {
            throw TrialCoreError.invalid("EMPTY_INPUT_STREAM")
        }
        try Task.checkCancellation()
        guard first.buffer.frameLength > 0, first.buffer.format.sampleRate > 0,
              first.buffer.format.channelCount > 0 else {
            throw TrialCoreError.invalid("INPUT_DEVICE_FORMAT_UNAVAILABLE")
        }
        guard SpeechTranscriber.isAvailable else {
            throw TrialCoreError.invalid("BLOCKED:APPLE_DEVICE_UNAVAILABLE")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TrialCoreError.invalid("BLOCKED:APPLE_LOCALE_UNSUPPORTED")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            throw TrialCoreError.invalid("BLOCKED:APPLE_ASSETS_" + String(describing: status))
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TrialCoreError.invalid("BLOCKED:APPLE_AUDIO_FORMAT_UNAVAILABLE")
        }
        guard let converter = PersistentPCMConverter(source: first.buffer.format, target: target) else {
            throw TrialCoreError.invalid("AUDIO_CONVERTER_UNAVAILABLE")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        activeAnalyzer = analyzer
        defer { activeAnalyzer = nil }
        try await analyzer.prepareToAnalyze(in: target)
        try Task.checkCancellation()
        let resultTask = Task { @MainActor () throws -> (String, Int) in
            var assembly = NativeAssembly()
            var revision = 0
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let raw = String(result.text.characters)
                try assembly.update(start: result.range.start.seconds, end: result.range.end.seconds,
                                    text: raw, isFinal: result.isFinal)
                revision += 1
                try await emit(LiveEvent(event_type: "partial", session_id: sessionID,
                                        segment_id: "transcript", revision: revision,
                                        partial: true, segment_final: false,
                                        session_finished: false, text: assembly.preview,
                                        error: nil,
                                        timestamp_ms: Date().timeIntervalSince1970 * 1000,
                                        monotonic_ms: (ProcessInfo.processInfo.systemUptime - startedUptime) * 1000,
                                        metadata: [
                                            "native_segment_final": .bool(result.isFinal),
                                            "native_range_start": .number(result.range.start.seconds),
                                            "native_range_end": .number(result.range.end.seconds)
                                        ]))
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            return (try assembly.finished(), revision)
        }

        do {
            let sequence = AnalyzerBufferSequence(
                input: iterator, first: first, converter: converter,
                onInputStarted: {
                    let elapsed = (ProcessInfo.processInfo.systemUptime - startedUptime) * 1000
                    try await emit(LiveEvent(event_type: "metadata", session_id: sessionID, segment_id: nil,
                                            revision: 0, partial: false, segment_final: false,
                                            session_finished: false, text: nil, error: nil,
                                            timestamp_ms: Date().timeIntervalSince1970 * 1000,
                                            monotonic_ms: elapsed,
                                            metadata: [
                                                "backend_id": .string("apple"),
                                                "model_id": .string("SpeechTranscriber"),
                                                "locale": .string(locale.identifier),
                                                "mode": .string(mode),
                                                "sourcehash": sourceHash.map(JSONValue.string) ?? .null,
                                                "source_audio_sha256": sourceHash.map(JSONValue.string) ?? .null,
                                                "source_format": .string(first.buffer.format.description),
                                                "input_format": .string(target.description),
                                                "input_started": .bool(true),
                                                "input_started_ms": .number(elapsed),
                                                "setup_ms": .number(elapsed),
                                                "audio_duration_ms": sourceDuration.map { .number($0 * 1000) } ?? .null,
                                                "phase": .string("input_started")
                                            ]))
                },
                onInputFinished: {
                    try await emit(LiveEvent(event_type: "input_finished", session_id: sessionID, segment_id: nil,
                                            revision: 0, partial: false, segment_final: false,
                                            session_finished: false, text: nil, error: nil,
                                            timestamp_ms: Date().timeIntervalSince1970 * 1000,
                                            monotonic_ms: (ProcessInfo.processInfo.systemUptime - startedUptime) * 1000,
                                            metadata: ["input_finished": .bool(true),
                                                       "input_eof_ms": .number((ProcessInfo.processInfo.systemUptime - startedUptime) * 1000),
                                                       "phase": .string("input_finished")]))
                })
            try Task.checkCancellation()
            guard let end = try await analyzer.analyzeSequence(sequence) else {
                throw TrialCoreError.invalid("EMPTY_ANALYZER_INPUT")
            }
            try Task.checkCancellation()
            try await analyzer.finalizeAndFinish(through: end)
            try Task.checkCancellation()
            let (text, revision) = try await resultTask.value
            try await emit(LiveEvent(event_type: "segment_final", session_id: sessionID,
                                    segment_id: "transcript", revision: revision + 1,
                                    partial: false, segment_final: true,
                                    session_finished: false, text: text, error: nil,
                                    timestamp_ms: Date().timeIntervalSince1970 * 1000,
                                    monotonic_ms: (ProcessInfo.processInfo.systemUptime - startedUptime) * 1000,
                                    metadata: ["recognized": .bool(!text.isEmpty)]))
            try await emit(LiveEvent(event_type: "session_finished", session_id: sessionID,
                                    segment_id: nil, revision: 0, partial: false,
                                    segment_final: false, session_finished: true,
                                    text: nil, error: nil,
                                    timestamp_ms: Date().timeIntervalSince1970 * 1000,
                                    monotonic_ms: (ProcessInfo.processInfo.systemUptime - startedUptime) * 1000,
                                    metadata: ["session_finished_ms": .number((ProcessInfo.processInfo.systemUptime - startedUptime) * 1000)]))
        } catch {
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            _ = try? await resultTask.value
            throw error
        }
    }

    private func cancelActiveAnalyzer() async {
        if let activeAnalyzer { await activeAnalyzer.cancelAndFinishNow() }
    }
}

struct TrialSelfTests {
    static func run() throws {
        var assembly = NativeAssembly()
        try assembly.update(start: 0, end: 1, text: "你", isFinal: false)
        try assembly.update(start: 0, end: 2, text: "你好", isFinal: false)
        guard assembly.preview == "你好" else { throw TrialCoreError.invalid("PARTIAL_REVISION_FAILED") }
        try assembly.update(start: 0, end: 2, text: "你好。", isFinal: true)
        try assembly.update(start: 2, end: 3, text: "第二句", isFinal: false)
        guard assembly.preview == "你好。第二句" else { throw TrialCoreError.invalid("FINAL_ASSEMBLY_FAILED") }
        do {
            _ = try assembly.finished()
            throw TrialCoreError.invalid("UNFINISHED_PARTIAL_ACCEPTED")
        } catch let error as TrialCoreError where error.description == "NATIVE_STREAM_ENDED_WITH_PARTIAL" {
        }
        try assembly.update(start: 2, end: 3, text: "第二句。", isFinal: true)
        guard try assembly.finished() == "你好。第二句。" else {
            throw TrialCoreError.invalid("MULTI_FINAL_FAILED")
        }
        try assembly.update(start: 2, end: 3, text: "第二句。", isFinal: true)
        do {
            try assembly.update(start: 0, end: 2, text: "篡改", isFinal: true)
            throw TrialCoreError.invalid("CONFLICTING_FINAL_ACCEPTED")
        } catch let error as TrialCoreError where error.description == "CONFLICTING_NATIVE_FINAL" {
        }

        var tightened = NativeAssembly()
        try tightened.update(start: 0, end: 7.152, text: "英文全文", isFinal: false)
        try tightened.update(start: 0, end: 6.84, text: "英文全文", isFinal: true)
        guard try tightened.finished() == "英文全文" else {
            throw TrialCoreError.invalid("TIGHTENED_FINAL_RANGE_FAILED")
        }
        try tightened.update(start: 6.84, end: 8.1, text: "下一句", isFinal: false)
        try tightened.update(start: 0, end: 6.84, text: "英文全文", isFinal: true)
        do {
            _ = try tightened.finished()
            throw TrialCoreError.invalid("LATE_NEXT_SEGMENT_WAS_DROPPED")
        } catch let error as TrialCoreError where error.description == "NATIVE_STREAM_ENDED_WITH_PARTIAL" {
        }

        var state = TrialStateMachine()
        try state.beginRequest()
        let firstGeneration = state.generation
        try state.beginRecording()
        try state.beginFinalizing()
        try state.finish()
        try state.beginRequest()
        guard state.generation == firstGeneration + 1 else {
            throw TrialCoreError.invalid("GENERATION_NOT_INCREMENTED")
        }
        state.cancel()
        guard state.state == .cancelled else { throw TrialCoreError.invalid("CANCEL_STATE_FAILED") }
        guard TrialCoreError.invalid("RECOGNITION_TIMEOUT").description == "RECOGNITION_TIMEOUT" else {
            throw TrialCoreError.invalid("TIMEOUT_STATE_FAILED")
        }
        let eventGate = SessionEventGate()
        guard eventGate.isOpen else { throw TrialCoreError.invalid("EVENT_GATE_OPEN_FAILED") }
        eventGate.close()
        guard !eventGate.isOpen else { throw TrialCoreError.invalid("EVENT_GATE_CLOSE_FAILED") }
        let empty = NativeAssembly()
        guard try empty.finished().isEmpty else { throw TrialCoreError.invalid("EMPTY_RESULT_TEST_FAILED") }

        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let firstBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 800),
              let secondBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 800),
              let thirdBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 800),
              let converter = PersistentPCMConverter(source: pcmFormat, target: pcmFormat) else {
            throw TrialCoreError.invalid("CONVERTER_SELF_TEST_SETUP_FAILED")
        }
        firstBuffer.frameLength = 800
        secondBuffer.frameLength = 800
        thirdBuffer.frameLength = 800
        guard let firstOwned = OwnedPCMBuffer(firstBuffer),
              let secondOwned = OwnedPCMBuffer(secondBuffer),
              let thirdOwned = OwnedPCMBuffer(thirdBuffer) else {
            throw TrialCoreError.invalid("CONVERTER_SELF_TEST_COPY_FAILED")
        }
        var convertedFrames = 0
        convertedFrames += try converter.convert(firstOwned).reduce(0) { $0 + Int($1.buffer.frameLength) }
        convertedFrames += try converter.convert(secondOwned).reduce(0) { $0 + Int($1.buffer.frameLength) }
        convertedFrames += try converter.convert(thirdOwned).reduce(0) { $0 + Int($1.buffer.frameLength) }
        convertedFrames += try converter.flush().reduce(0) { $0 + Int($1.buffer.frameLength) }
        guard convertedFrames > 0, abs(convertedFrames - 2_400) <= 4_096 else {
            throw TrialCoreError.invalid("CONVERTER_FRAME_LOSS")
        }

        let bounded = BoundedPCMStream(capacity: 1)
        guard let overflowA = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 32),
              let overflowB = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 32) else {
            throw TrialCoreError.invalid("BOUNDED_QUEUE_OVERFLOW_TEST_FAILED")
        }
        overflowA.frameLength = 32
        overflowB.frameLength = 32
        guard let ownedA = OwnedPCMBuffer(overflowA), let ownedB = OwnedPCMBuffer(overflowB),
              bounded.yield(ownedA), !bounded.yield(ownedB) else {
            throw TrialCoreError.invalid("BOUNDED_QUEUE_OVERFLOW_TEST_FAILED")
        }

        guard let limitFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                              channels: 1, interleaved: true),
              let limitBuffer = AVAudioPCMBuffer(pcmFormat: limitFormat, frameCapacity: 960_001) else {
            throw TrialCoreError.invalid("CAPTURE_LIMIT_SELF_TEST_SETUP_FAILED")
        }
        limitBuffer.frameLength = 960_001
        let limitStore = CapturedPCMStore()
        do {
            _ = try limitStore.append(copying: limitBuffer)
            throw TrialCoreError.invalid("CAPTURE_LIMIT_NOT_ENFORCED")
        } catch let error as TrialCoreError where error.description == "CAPTURE_LIMIT_EXCEEDED" {
        }
        guard limitStore.failure?.description == "CAPTURE_LIMIT_EXCEEDED" else {
            throw TrialCoreError.invalid("CAPTURE_LIMIT_NOT_SEALED")
        }
        guard !limitStore.append(OwnedPCMBuffer(firstBuffer)!) else {
            throw TrialCoreError.invalid("CAPTURE_LIMIT_ACCEPTED_AFTER_FAILURE")
        }

        let sealedStore = CapturedPCMStore()
        sealedStore.seal()
        guard !sealedStore.append(OwnedPCMBuffer(firstBuffer)!) else {
            throw TrialCoreError.invalid("SEALED_STORE_ACCEPTED_BUFFER")
        }

        guard let alternateFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000,
                                                   channels: 1, interleaved: true),
              let alternateBuffer = AVAudioPCMBuffer(pcmFormat: alternateFormat, frameCapacity: 800) else {
            throw TrialCoreError.invalid("SOURCE_FORMAT_SELF_TEST_SETUP_FAILED")
        }
        alternateBuffer.frameLength = 800
        let formatStore = CapturedPCMStore()
        _ = try formatStore.append(copying: firstBuffer)
        do {
            _ = try formatStore.append(copying: alternateBuffer)
            throw TrialCoreError.invalid("SOURCE_FORMAT_CHANGE_ACCEPTED")
        } catch let error as TrialCoreError where error.description == "SOURCE_FORMAT_CHANGED" {
        }

        let sinkStore = CapturedPCMStore()
        let sinkInput = BoundedPCMStream(capacity: 1)
        let sink = CaptureSink(store: sinkStore, input: sinkInput)
        sink.disableAppleStreaming()
        sink.ingest(firstBuffer)
        sink.ingest(secondBuffer)
        guard sinkStore.snapshot().count == 2 else {
            throw TrialCoreError.invalid("APPLE_SINK_CLOSED_STORE_WRITE_FAILED")
        }
        guard !sinkInput.yield(OwnedPCMBuffer(thirdBuffer)!) else {
            throw TrialCoreError.invalid("APPLE_SINK_INPUT_NOT_CLOSED")
        }

        let overflowStore = CapturedPCMStore()
        let overflowInput = BoundedPCMStream(capacity: 1)
        let overflowSink = CaptureSink(store: overflowStore, input: overflowInput)
        overflowSink.ingest(firstBuffer)
        overflowSink.ingest(secondBuffer)
        overflowSink.ingest(thirdBuffer)
        guard overflowStore.snapshot().count == 3, overflowInput.enqueuedCount == 1 else {
            throw TrialCoreError.invalid("APPLE_OVERFLOW_DAMAGED_RAW_STORE")
        }
        overflowSink.finish()
        overflowSink.ingest(firstBuffer)
        guard overflowStore.snapshot().count == 3 else {
            throw TrialCoreError.invalid("FINISHED_SINK_ACCEPTED_BUFFER")
        }

        let finishStore = CapturedPCMStore()
        let finishInput = BoundedPCMStream(capacity: 2)
        let finishSink = CaptureSink(store: finishStore, input: finishInput)
        finishSink.ingest(firstBuffer)
        finishSink.finish()
        guard finishStore.snapshot().count == 1, finishInput.enqueuedCount == 1,
              !finishInput.yield(OwnedPCMBuffer(thirdBuffer)!) else {
            throw TrialCoreError.invalid("SINK_FINISH_BARRIER_FAILED")
        }

        guard let exact = AVAudioPCMBuffer(pcmFormat: limitFormat, frameCapacity: 960_000) else {
            throw TrialCoreError.invalid("PCM_LIMIT_SELF_TEST_SETUP_FAILED")
        }
        exact.frameLength = 960_000
        guard let exactOwned = OwnedPCMBuffer(exact) else {
            throw TrialCoreError.invalid("PCM_LIMIT_SELF_TEST_COPY_FAILED")
        }
        let exactPCM = try PCM16MemoryBridge.make(from: [exactOwned])
        guard exactPCM.data.count == 1_920_000 else {
            throw TrialCoreError.invalid("PCM_EXACT_LIMIT_FAILED")
        }
        guard let over = AVAudioPCMBuffer(pcmFormat: limitFormat, frameCapacity: 960_001) else {
            throw TrialCoreError.invalid("PCM_OVER_LIMIT_SELF_TEST_SETUP_FAILED")
        }
        over.frameLength = 960_001
        do {
            _ = try PCM16MemoryBridge.make(from: [OwnedPCMBuffer(over)!])
            throw TrialCoreError.invalid("PCM_LIMIT_NOT_ENFORCED")
        } catch let error as TrialCoreError where error.description == "PCM_MEMORY_LIMIT_EXCEEDED" {
        }
    }
}
