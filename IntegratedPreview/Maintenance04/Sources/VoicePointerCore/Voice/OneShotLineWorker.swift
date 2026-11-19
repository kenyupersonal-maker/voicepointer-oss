import Foundation
import Darwin

internal struct LineWorkerError: Error, Sendable { let code: String }

internal actor OneShotLineWorker {
    private enum Phase { case idle, starting, ready, finishing, closing, closed }

    private enum Constants {
        static let maxInitial = 8192
        static let maxFinal = 14 * 1024 * 1024
        static let maxOutput = 1024 * 1024
        static let maxBuffer = maxOutput + maxInitial
        static let pollNs: UInt64 = 5_000_000
    }

    private let command: [String]
    private let timeout: TimeInterval
    private var phase: Phase = .idle
    private var launchUsed = false
    private var process: Process?
    private var stdinWrite: FileHandle?
    private var stdoutRead: FileHandle?
    private var pending = Data()
    private var cleanupTask: Task<Void, Never>?

    init(command: [String], timeout: TimeInterval = 45) {
        self.command = command
        self.timeout = timeout
    }

    func isQuiescent() -> Bool {
        phase == .idle || (phase == .closed && process == nil)
    }

    func launch(initialLine: Data) async throws -> Data {
        guard phase == .idle, !launchUsed else {
            throw LineWorkerError(code: (phase == .closed || phase == .closing) ? "LINE_WORKER_CLOSED" : "LINE_WORKER_BUSY")
        }
        launchUsed = true
        phase = .starting
        do {
            try Task.checkCancellation()
            try validateCommand()
            try validateLine(initialLine, initial: true)
            try spawn()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let out = try await exchange(line: initialLine, expectedPhase: .starting, deadline: deadline)
            guard phase == .starting else { throw LineWorkerError(code: "LINE_WORKER_CLOSED") }
            phase = .ready
            return out
        } catch {
            await shutdown()
            throw error
        }
    }

    func finish(finalLine: Data) async throws -> Data {
        guard phase == .ready else {
            throw LineWorkerError(code: (phase == .closed || phase == .closing) ? "LINE_WORKER_CLOSED" : "LINE_WORKER_BUSY")
        }
        phase = .finishing
        do {
            try Task.checkCancellation()
            try validateLine(finalLine, initial: false)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let out = try await exchange(line: finalLine, expectedPhase: .finishing, deadline: deadline)
            await shutdown()
            try Task.checkCancellation()
            guard isQuiescent() else { throw LineWorkerError(code: "LINE_WORKER_CLOSED") }
            return out
        } catch {
            await shutdown()
            throw error
        }
    }

    func shutdown() async {
        if let t = cleanupTask { await t.value; return }
        if phase == .closed { return }
        phase = .closing
        let t = Task { await self.performCleanup(); return }
        cleanupTask = t
        await t.value
    }

    private func performCleanup() async {
        if let sw = stdinWrite { try? sw.close(); stdinWrite = nil }
        guard let p = process else {
            if let sr = stdoutRead { try? sr.close(); stdoutRead = nil }
            pending.removeAll()
            phase = .closed
            cleanupTask = nil
            return
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGTERM)
            if !(await pollExit(p, limitNs: 250_000_000)) {
                kill(p.processIdentifier, SIGKILL)
                _ = await pollExit(p, limitNs: 500_000_000)
            }
        }
        if p.isRunning {
            cleanupTask = nil
            return
        }
        if let sr = stdoutRead { try? sr.close(); stdoutRead = nil }
        pending.removeAll()
        process = nil
        phase = .closed
        cleanupTask = nil
    }

    private func pollExit(_ p: Process, limitNs: UInt64) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(limitNs) / 1_000_000_000
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !p.isRunning { return true }
            try? await Task.sleep(nanoseconds: Constants.pollNs)
        }
        return !p.isRunning
    }

    private func validateCommand() throws {
        guard !command.isEmpty, command[0].hasPrefix("/"),
              timeout.isFinite, timeout > 0, timeout <= 60
        else { throw LineWorkerError(code: "LINE_WORKER_LAUNCH") }
    }

    private func validateLine(_ line: Data, initial: Bool) throws {
        let limit = initial ? Constants.maxInitial : Constants.maxFinal
        guard !line.isEmpty, line.last == UInt8(ascii: "\n"), line.count <= limit else {
            throw LineWorkerError(code: line.count > limit ? "LINE_WORKER_OVERSIZE" : "LINE_WORKER_INVALID")
        }
    }

    private func spawn() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst())
        p.environment = ["PATH": "/usr/bin:/bin", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        p.standardError = FileHandle.nullDevice
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        stdinWrite = inPipe.fileHandleForWriting
        stdoutRead = outPipe.fileHandleForReading
        process = p
        defer {
            try? inPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
        }
        do { try p.run() } catch { throw LineWorkerError(code: "LINE_WORKER_LAUNCH") }
        try setNonBlocking(inPipe.fileHandleForWriting.fileDescriptor)
        try setNonBlocking(outPipe.fileHandleForReading.fileDescriptor)
        guard fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw LineWorkerError(code: "LINE_WORKER_IO")
        }
    }

    private func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LineWorkerError(code: "LINE_WORKER_IO")
        }
    }

    private func checkPhase(_ expected: Phase, deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard phase == expected else { throw LineWorkerError(code: "LINE_WORKER_CLOSED") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw LineWorkerError(code: "LINE_WORKER_TIMEOUT") }
    }

    private func exchange(line: Data, expectedPhase: Phase, deadline: TimeInterval) async throws -> Data {
        guard let sw = stdinWrite else { throw LineWorkerError(code: "LINE_WORKER_CLOSED") }
        let bytes = [UInt8](line)
        var offset = 0
        while offset < bytes.count {
            try checkPhase(expectedPhase, deadline: deadline)
            let n = bytes[offset...].withUnsafeBufferPointer { buf in
                Darwin.write(sw.fileDescriptor, buf.baseAddress, buf.count)
            }
            if n > 0 { offset += n; continue }
            if n == 0 { throw LineWorkerError(code: "LINE_WORKER_IO") }
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK || e == EINTR {
                try? await Task.sleep(nanoseconds: Constants.pollNs)
                continue
            }
            throw LineWorkerError(code: "LINE_WORKER_IO")
        }
        return try await readLine(expectedPhase: expectedPhase, deadline: deadline)
    }

    private func readLine(expectedPhase: Phase, deadline: TimeInterval) async throws -> Data {
        guard let sr = stdoutRead else { throw LineWorkerError(code: "LINE_WORKER_CLOSED") }
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            try checkPhase(expectedPhase, deadline: deadline)
            if let idx = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let slice = pending[pending.startIndex..<idx]
                if slice.count > Constants.maxOutput { throw LineWorkerError(code: "LINE_WORKER_OVERSIZE") }
                let result = Data(slice)
                pending.removeSubrange(pending.startIndex...idx)
                return result
            }
            if pending.count > Constants.maxBuffer {
                throw LineWorkerError(code: "LINE_WORKER_OVERSIZE")
            }
            try checkPhase(expectedPhase, deadline: deadline)
            let n = Darwin.read(sr.fileDescriptor, &chunk, chunk.count)
            if n > 0 {
                guard pending.count + n <= Constants.maxBuffer else { throw LineWorkerError(code: "LINE_WORKER_OVERSIZE") }
                pending.append(contentsOf: chunk[0..<n]); continue
            }
            if n == 0 { throw LineWorkerError(code: "LINE_WORKER_IO") }
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK || e == EINTR {
                try? await Task.sleep(nanoseconds: Constants.pollNs)
                continue
            }
            throw LineWorkerError(code: "LINE_WORKER_IO")
        }
    }
}
