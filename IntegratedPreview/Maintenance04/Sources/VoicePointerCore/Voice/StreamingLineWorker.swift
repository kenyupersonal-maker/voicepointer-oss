//
//  StreamingLineWorker.swift
//  VoicePointerCore (IntegratedPreview)
//
//  Owned streaming child process. Executestrusted constructor command directly
//  (no shell). Credentialmaterial only crosses the opaque initial line.
//

import Foundation
import Darwin

internal enum StreamingWorkerError: Error {
    case invalid
    case state
    case launch
    case cleanup
}

internal actor StreamingLineWorker {

    private enum Phase {
        case idle
        case starting
        case active
        case closing
        case closed
    }

    private let command: [String]
    private var phase: Phase = .idle
    private var used = false
    private var process: Process?
    private var io: DuplexLineIO?
    private var cleanupTask: Task<Void, Never>?
    private var sending = false
    private var receiving = false

    internal init(command: [String]) {
        self.command = command
    }

    internal func isQuiescent() -> Bool {
        phase == .idle || (phase == .closed && process == nil)
    }

    internal func launch(initialLine: Data) async throws -> Data {
        guard phase == .idle && !used else { throw StreamingWorkerError.invalid }
        used = true
        guard !command.isEmpty, command[0].hasPrefix("/") else {
            throw StreamingWorkerError.invalid
        }
        guard initialLine.count >= 1, initialLine.count <= 8193,
              initialLine.last == 0x0A else {
            throw StreamingWorkerError.invalid
        }
        do {
            phase = .starting
            try Task.checkCancellation()
            let duplex: DuplexLineIO
            do {
            let inPipe = Pipe()
            let outPipe = Pipe()
            defer {
                try? inPipe.fileHandleForReading.close()
                try? inPipe.fileHandleForWriting.close()
                try? outPipe.fileHandleForReading.close()
                try? outPipe.fileHandleForWriting.close()
            }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: command[0])
            child.arguments = Array(command.dropFirst())
            child.environment = ["PATH": "/usr/bin:/bin"]
            child.currentDirectoryURL = URL(fileURLWithPath: "/")
            child.standardError = FileHandle.nullDevice
            child.standardInput = inPipe
            child.standardOutput = outPipe
            // Own the process reference before spawning so every failure path
            // (including DuplexLineIO init) still routes through cleanup.
            process = child
            do {
                try child.run()
            } catch {
                throw StreamingWorkerError.launch
            }
            // The child retains its own descriptors; DuplexLineIO owns the
            // duplicated parent ends. Close all four original parent handles
            // only after the run and duplication have happened.
            duplex = try DuplexLineIO(
                readFD: outPipe.fileHandleForReading.fileDescriptor,
                writeFD: inPipe.fileHandleForWriting.fileDescriptor)
            io = duplex
            }
            try await duplex.writeLine(initialLine, timeout: 5)
            try Task.checkCancellation()
            guard phase == .starting else { throw StreamingWorkerError.state }
            let ready = try await duplex.readLine(timeout: 15)
            try Task.checkCancellation()
            guard phase == .starting else { throw StreamingWorkerError.state }
            phase = .active
            return ready
        } catch {
            await shutdown()
            throw error
        }
    }

    internal func sendLine(_ data: Data) async throws {
        // Busy does not kill a legitimate in-flight operation.
        guard phase == .active && !sending, let io else {
            throw StreamingWorkerError.state
        }
        sending = true
        defer { sending = false }
        do {
            try await io.writeLine(data, timeout: 10)
            try Task.checkCancellation()
            guard phase == .active else { throw StreamingWorkerError.state }
        } catch {
            await shutdown()
            throw error
        }
    }

    internal func readLine(timeout: TimeInterval = 35) async throws -> Data {
        guard phase == .active && !receiving, let io else {
            throw StreamingWorkerError.state
        }
        receiving = true
        defer { receiving = false }
        do {
            let line = try await io.readLine(timeout: timeout)
            try Task.checkCancellation()
            guard phase == .active else { throw StreamingWorkerError.state }
            return line
        } catch {
            await shutdown()
            throw error
        }
    }

    internal func shutdown() async {
        if let existing = cleanupTask {
            await existing.value
            return
        }
        if phase == .closed { return }
        phase = .closing
        let task = Task<Void, Never> { await self.performCleanup() }
        cleanupTask = task
        await task.value
    }

    private func performCleanup() async {
        await io?.close()
        io = nil
        guard let child = process else {
            phase = .closed
            cleanupTask = nil
            return
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGTERM)
            if !(await pollExit(child, seconds: 0.25)) {
                kill(child.processIdentifier, SIGKILL)
                _ = await pollExit(child, seconds: 0.5)
            }
        }
        if !child.isRunning {
            process = nil
            phase = .closed
        } else {
            // Still alive: retain the process so a later shutdown can retry
            // cleanup. Never report quiescent while an owned process runs.
            phase = .closing
        }
        cleanupTask = nil
    }

    private func pollExit(_ child: Process, seconds: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while child.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}

