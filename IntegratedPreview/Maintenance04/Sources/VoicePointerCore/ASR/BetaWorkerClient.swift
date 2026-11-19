import Foundation
import Darwin

struct BetaStageEvent: Codable, Sendable {
    let kind: String
    let offset_ms: Double
    let text: String?
    let audio_start_sample: Int
    let audio_end_sample: Int
    let segment_index: Int?
}

struct BetaMossSegment: Codable, Sendable {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

struct BetaWorkerResult: Codable, Sendable {
    let type: String
    var session_id: String? = nil
    var revision: Int? = nil
    var text: String? = nil
    var final: Bool? = nil
    var compute_ms: Double? = nil
    var error: String? = nil
    var load_ms: Double? = nil
    var warmup_ms: Double? = nil
    var worker_pid: Int32? = nil
    var profile_id: String? = nil
    var max_seconds: Int? = nil
    var committed_text: String? = nil
    var draft_text: String? = nil
    var segment_count: Int? = nil
    var stage_events: [BetaStageEvent]? = nil
    var resource_usage: [String: Double]? = nil
    var runtime_versions: [String: String]? = nil
    // MOSS fields are intentionally distinct from the existing TwoPass
    // `segments` payload.  CompareRunner journals this whole response before
    // feeding only `text` into the host character tracker.
    var raw_transcript: String? = nil
    var moss_segments: [BetaMossSegment]? = nil
    var model_confidence: Double? = nil
    var model_confidence_source: String? = nil
    var model_confidence_token_count: Int? = nil

    var confidenceEvidence: LocalModelConfidence? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LocalModelConfidence(probability: model_confidence, source: model_confidence_source,
                                    tokenCount: model_confidence_token_count)
    }
}

protocol BetaInferenceClient: Sendable {
    func prepareBackgroundPriority() async
    func start() async throws
    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool) async throws -> BetaWorkerResult
    /// `context` (the personal lexicon's hot words) belongs to the whole worker session, not to one request.
    /// No default implementation on purpose: a conformer whose signature drifts must fail to compile, not
    /// quietly refuse every request that carries a context.
    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool, context: BetaRecognitionContext?) async throws -> BetaWorkerResult
    func shutdown() async
}
extension BetaInferenceClient {
    func prepareBackgroundPriority() async {}
}

struct BetaWorkerTransportError: Error, Sendable, CustomStringConvertible {
    let description: String
}

actor BetaWorkerClient: BetaInferenceClient {
    private var backgroundPriority = false
    func prepareBackgroundPriority() { if process == nil { backgroundPriority = true } }
    private var process: Process?
    // Keep the owning FileHandles alive, and close them only through FileHandle.
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var stderrPipe: Pipe?
    private var inputFD: Int32 = -1
    private var outputFD: Int32 = -1
    private var stderrFD: Int32 = -1
    private var readBuffer = Data()
    private var stderrTail = Data()
    private var epoch: UInt64 = 0
    private var ready = false
    private var requestInFlight = false
    private let command: [String]
    private let timeout: TimeInterval
    private let profileID: String
    private let maxLine = 2_600_000
    private(set) var startup: BetaWorkerResult?
    private(set) var lastErrorResponse: BetaWorkerResult?

    nonisolated static func pythonPath(root: String, profileID: String) -> String {
        let environment = profileID == "moss-transcribe-diarize" ? "moss-transcribe" : "voicenative-beta"
        return root + "/.cache/venvs/\(environment)/bin/python"
    }

    init(profileID: String = "qwen17-rolling", language: String = "auto", command: [String]? = nil, timeout: TimeInterval = 120) {
        let root = IntegratedRuntimePaths.dataRoot.path
        if let resources = IntegratedRuntimePaths.backendResources,
           let assets = IntegratedRuntimePaths.assetRoot {
            let launcher = resources.appendingPathComponent("launch-local-worker.sh").path
            let python = Self.pythonPath(root: assets.path, profileID: profileID)
            self.command = command ?? [
                launcher, root, python, "--profile", profileID, "--language", language
            ]
        } else {
            self.command = command ?? []
        }
        self.timeout = timeout
        self.profileID = profileID
    }

    func start() async throws {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 120 else { throw failure("WORKER_INVALID_TIMEOUT") }
        if let process {
            guard ready, process.isRunning else { throw failure("WORKER_BUSY_OR_NOT_READY") }
            return
        }
        guard !command.isEmpty else { throw failure("WORKER_RESOURCE_MISSING") }
        let p = Process()
        if backgroundPriority { p.qualityOfService = .utility }
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = command
        p.environment = [
            "PATH": "/usr/bin:/bin",
            "TMPDIR": IntegratedRuntimePaths.dataRoot.appendingPathComponent(".cache/tmp/").path,
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1"
        ]
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        epoch &+= 1
        let operationEpoch = epoch
        stderrTail.removeAll(keepingCapacity: false)
        lastErrorResponse = nil
        do {
            try p.run()
            process = p
            inputPipe = inPipe; outputPipe = outPipe; stderrPipe = errPipe
            inputFD = inPipe.fileHandleForWriting.fileDescriptor
            outputFD = outPipe.fileHandleForReading.fileDescriptor
            stderrFD = errPipe.fileHandleForReading.fileDescriptor
            for fd in [inputFD, outputFD, stderrFD] {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw failure("WORKER_NONBLOCK_FAILED")
                }
            }
            guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 else {
                throw failure("WORKER_SIGPIPE_GUARD_FAILED")
            }
            let message = try await readLine(epoch: operationEpoch, deadline: now + timeout)
            guard message.type == "ready" else { throw failure("WORKER_NOT_READY:" + (message.error ?? "unknown")) }
            guard message.profile_id == profileID,
                  let maxSeconds = message.max_seconds, (1...60).contains(maxSeconds),
                  let load = message.load_ms, load.isFinite, load >= 0,
                  let warm = message.warmup_ms, warm.isFinite, warm >= 0 else {
                throw failure("WORKER_READY_MISMATCH")
            }
            // The production launcher is exec-only. A changed topology is not silently accepted.
            if message.worker_pid != p.processIdentifier {
                throw failure("WORKER_UNEXPECTED_PROCESS_TOPOLOGY")
            }
            startup = message
            ready = true
        } catch {
            await invalidateAndReap(expectedEpoch: operationEpoch)
            throw error
        }
    }

    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool) async throws -> BetaWorkerResult {
        try await infer(sessionID: sessionID, revision: revision, pcm: pcm, final: final, context: nil)
    }

    func infer(sessionID: String, revision: Int, pcm: Data, final: Bool, context: BetaRecognitionContext?) async throws -> BetaWorkerResult {
        guard context == nil || BetaRecognitionContext.supports(profileID: profileID) else {
            throw failure("WORKER_CONTEXT_UNSUPPORTED")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard !sessionID.isEmpty, sessionID.utf8.count <= 128,
              sessionID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              (0...1_000_000).contains(revision), pcm.count <= 1_920_000, pcm.count % 2 == 0 else {
            throw failure("WORKER_INVALID_REQUEST")
        }
        try await start()
        guard let limit = startup?.max_seconds, pcm.count <= limit * 32000 else {
            throw failure("WORKER_PROFILE_AUDIO_LIMIT")
        }
        guard !requestInFlight else { throw failure("WORKER_REQUEST_ALREADY_IN_FLIGHT") }
        requestInFlight = true
        let operationEpoch = epoch
        defer { if epoch == operationEpoch { requestInFlight = false } }
        do {
            var object: [String: Any] = [
                "op": "infer", "session_id": sessionID, "revision": revision,
                "pcm16_b64": pcm.base64EncodedString(), "final": final
            ]
            if let context { object["context"] = context.text }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) + Data([10])
            guard data.count <= maxLine else { throw failure("WORKER_REQUEST_TOO_LARGE") }
            let deadline = now + timeout
            try await writeAll(data, epoch: operationEpoch, deadline: deadline)
            let result = try await readLine(epoch: operationEpoch, deadline: deadline)
            guard result.type == "result" || result.type == "error" else {
                throw failure("WORKER_UNEXPECTED_MESSAGE")
            }
            guard result.session_id == sessionID, result.revision == revision else {
                throw failure("WORKER_RESPONSE_ID_MISMATCH")
            }
            if result.type == "error" {
                lastErrorResponse = result
                throw failure("WORKER_REJECTED:" + (result.error ?? "unknown"))
            }
            guard result.profile_id == profileID, result.final == final, result.text != nil,
                  let compute = result.compute_ms, compute.isFinite, compute >= 0 else {
                throw failure("WORKER_INVALID_RESULT")
            }
            return result
        } catch {
            await invalidateAndReap(expectedEpoch: operationEpoch)
            throw error
        }
    }

    func shutdown() async {
        // No graceful write may interleave with a partially written audio request.
        await invalidateAndReap(expectedEpoch: epoch)
    }

    func diagnostics() -> (pid: Int32?, ready: Bool, stderrBytes: Int, bufferedBytes: Int) {
        (process?.processIdentifier, ready, stderrTail.count, readBuffer.count)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func checkOperation(_ expectedEpoch: UInt64, deadline: TimeInterval, timeoutCode: String) throws {
        guard epoch == expectedEpoch else { throw failure("WORKER_EPOCH_INVALID") }
        try Task.checkCancellation()
        guard now < deadline else { throw failure(timeoutCode) }
    }

    private func writeAll(_ data: Data, epoch operationEpoch: UInt64, deadline: TimeInterval) async throws {
        var offset = 0
        while offset < data.count {
            try checkOperation(operationEpoch, deadline: deadline, timeoutCode: "WORKER_WRITE_TIMEOUT")
            guard inputFD >= 0 else { throw failure("WORKER_INPUT_CLOSED") }
            drainStderr()
            let n = data.withUnsafeBytes { ptr in
                Darwin.write(inputFD, ptr.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n > 0 { offset += n; continue }
            guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw failure("WORKER_WRITE_FAILED_\(errno)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func readLine(epoch operationEpoch: UInt64, deadline: TimeInterval) async throws -> BetaWorkerResult {
        while true {
            try checkOperation(operationEpoch, deadline: deadline, timeoutCode: "WORKER_TIMEOUT")
            if let newline = readBuffer.firstIndex(of: 10) {
                guard newline <= maxLine else { throw failure("WORKER_RESPONSE_TOO_LARGE") }
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                do { return try JSONDecoder().decode(BetaWorkerResult.self, from: line) }
                catch { throw failure("WORKER_INVALID_JSON") }
            }
            guard readBuffer.count <= maxLine else { throw failure("WORKER_RESPONSE_TOO_LARGE") }
            guard outputFD >= 0 else { throw failure("WORKER_OUTPUT_CLOSED") }
            drainStderr()
            var bytes = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(outputFD, &bytes, bytes.count)
            if n > 0 { readBuffer.append(contentsOf: bytes[0..<n]); continue }
            if n == 0 { throw failure("WORKER_EOF") }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw failure("WORKER_READ_FAILED_\(errno)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func drainStderr() {
        guard stderrFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Bound work per turn even if a broken child continuously writes stderr.
        for _ in 0..<4 {
            let n = Darwin.read(stderrFD, &bytes, bytes.count)
            guard n > 0 else { return }
            stderrTail.append(contentsOf: bytes[0..<n])
            if stderrTail.count > 8192 { stderrTail.removeFirst(stderrTail.count - 8192) }
        }
    }

    private func invalidateAndReap(expectedEpoch: UInt64) async {
        guard epoch == expectedEpoch else { return }
        epoch &+= 1
        ready = false
        requestInFlight = false
        startup = nil
        try? inputPipe?.fileHandleForWriting.close()
        inputFD = -1
        if let p = process {
            if p.isRunning { _ = kill(p.processIdentifier, SIGTERM) }
            let deadline = now + 0.25
            while p.isRunning && now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            if p.isRunning { _ = kill(p.processIdentifier, SIGKILL) }
            // Foundation already owns waitpid/reaping. waitUntilExit can hang
            // on its run-loop bookkeeping when called after an actor hop.
            // Bound cleanup and allow its termination source to reap the child.
            let killDeadline = now + 0.5
            while p.isRunning && now < killDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            if p.isRunning { return } // Retain ownership; start() must not launch a replacement.
        }
        try? outputPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        outputFD = -1; stderrFD = -1
        inputPipe = nil; outputPipe = nil; stderrPipe = nil; process = nil
        readBuffer.removeAll(keepingCapacity: false)
    }

    private func failure(_ message: String) -> BetaWorkerTransportError {
        let tail = String(decoding: stderrTail.suffix(2000), as: UTF8.self)
        return BetaWorkerTransportError(description: tail.isEmpty ? message : message + " | stderr: " + tail)
    }
}
