import Foundation

// MARK: - Transport / Connection protocols

internal protocol AliLineTransport: Sendable {
    func readLine(timeout: TimeInterval) async throws -> Data
    func writeLine(_ data: Data, timeout: TimeInterval) async throws
    func close() async
}

extension DuplexLineIO: AliLineTransport {}

internal protocol AliRealtimeConnection: Sendable {
    func readinessTiming() async -> AliIPCOutput.ReadyTiming?
    func start() async throws
    func sendPCM(_ data: Data) async throws
    func finish() async throws
    func receive() async throws -> AliWireEvent
    func cancel() async
}

extension AliRealtimeConnection {
    func readinessTiming() async -> AliIPCOutput.ReadyTiming? { nil }
}

extension AliWebSocketConnection: AliRealtimeConnection {}

// MARK: - Terminal

internal enum Terminal: Sendable {
    case final(String)
    case cancelled
    case failed(AliServiceFailure = AliServiceFailure(.streamFailed))
}

// MARK: - OutputWriter

private actor OutputWriter {
    private let sessionID: UUID
    private let io: any AliLineTransport
    private let startClock: TimeInterval
    private var sequence: UInt64 = 0

    init(sessionID: UUID, io: any AliLineTransport, startClock: TimeInterval) {
        self.sessionID = sessionID
        self.io = io
        self.startClock = startClock
    }

    func emit(kind: String, text: String?, failure: AliServiceFailure? = nil,
              readyTiming: AliIPCOutput.ReadyTiming? = nil) async throws {
        let elapsed = (ProcessInfo.processInfo.systemUptime - startClock) * 1000.0
        let output = AliIPCOutput(
            sessionID: sessionID,
            sequence: sequence,
            observedMilliseconds: elapsed,
            kind: kind,
            text: text,
            errorCode: kind == "failed" ? (failure?.code.rawValue ?? AliServiceFailure.Code.streamFailed.rawValue) : nil,
            failureEvidence: kind == "failed" ? failure?.evidence : nil,
            readyTiming: readyTiming
        )
        let data = try AliIPC.encodeOutput(output)
        try await io.writeLine(data, timeout: 5)
        sequence += 1
    }
}

// MARK: - AliStreamSession

internal actor AliStreamSession {
    private let sessionID: UUID
    private let io: any AliLineTransport
    private let connection: any AliRealtimeConnection
    private let checkOnly: Bool
    private var used = false

    init(sessionID: UUID, io: any AliLineTransport, connection: any AliRealtimeConnection, checkOnly: Bool = false) {
        self.sessionID = sessionID
        self.io = io
        self.connection = connection
        self.checkOnly = checkOnly
    }

    func run() async -> Int32 {
        guard !used else { return 1 }
        used = true
        let startClock = ProcessInfo.processInfo.systemUptime
        let writer = OutputWriter(sessionID: sessionID, io: io, startClock: startClock)
        do {
            try await connection.start()
            try Task.checkCancellation()
            try await writer.emit(kind: "ready", text: nil, readyTiming: await connection.readinessTiming())

            if checkOnly {
                // No input/receiver loops: this mode cannot send PCM or a transcript.
                // Ack only after finish-task's WebSocket send and socket cancellation.
                try await connection.finish()
                await connection.cancel()
                try await writer.emit(kind: "checked", text: nil)
                await io.close()
                return 0
            }

            let io = self.io
            let connection = self.connection
            let result: Terminal = await withTaskGroup(of: Terminal.self) { group in
                group.addTask { await Self.inputLoop(io: io, connection: connection) }
                group.addTask { await Self.receiverLoop(connection: connection, writer: writer) }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: 345_000_000_000)
                        return .failed(AliServiceFailure(.timeout))
                    } catch {
                        return .cancelled
                    }
                }
                let first = await group.next() ?? .failed()
                group.cancelAll()
                await connection.cancel()
                while await group.next() != nil {}
                return first
            }

            switch result {
            case .final(let text):
                try await writer.emit(kind: "final", text: text)
                await io.close()
                return 0
            case .cancelled:
                try await writer.emit(kind: "stopped", text: nil)
                await io.close()
                return 0
            case .failed(let failure):
                try await writer.emit(kind: "failed", text: nil, failure: failure)
                await io.close()
                return 1
            }
        } catch is CancellationError {
            await connection.cancel()
            try? await writer.emit(kind: "stopped", text: nil)
            await io.close()
            return 0
        } catch let failure as AliServiceFailure {
            await connection.cancel()
            try? await writer.emit(kind: "failed", text: nil, failure: failure)
            await io.close()
            return 1
        } catch {
            let failure = AliServiceFailure.transport(error)
            await connection.cancel()
            try? await writer.emit(kind: "failed", text: nil, failure: failure)
            await io.close()
            return 1
        }
    }

    // MARK: Input

    private static func inputLoop(io: any AliLineTransport, connection: any AliRealtimeConnection) async -> Terminal {
        var finishing = false
        var totalPCM = 0
        var packets = 0
        while true {
            do {
                try Task.checkCancellation()
                let line = try await io.readLine(timeout: finishing ? 30 : 330)
                try Task.checkCancellation()
                let command = try AliIPC.decodeCommand(line)
                switch command {
                case .pcm(let data):
                    guard !finishing else { return .failed(AliServiceFailure(.invalidRequest)) }
                    guard totalPCM + data.count <= 9_600_000, packets < 50_000 else { return .failed(AliServiceFailure(.invalidRequest)) }
                    try await connection.sendPCM(data)
                    try Task.checkCancellation()
                    totalPCM += data.count
                    packets += 1
                case .finish:
                    guard !finishing else { return .failed(AliServiceFailure(.invalidRequest)) }
                    finishing = true
                    try await connection.finish()
                    try Task.checkCancellation()
                case .cancel:
                    return .cancelled
                case .configure:
                    return .failed(AliServiceFailure(.invalidRequest))
                }
            } catch is CancellationError {
                return .cancelled
            } catch let failure as AliServiceFailure {
                return .failed(failure)
            } catch let urlError as URLError {
                return .failed(AliServiceFailure.transport(urlError))
            } catch {
                return .failed(AliServiceFailure(.streamFailed))
            }
        }
    }

    // MARK: - Receiver

    private static func receiverLoop(connection: any AliRealtimeConnection, writer: OutputWriter) async -> Terminal {
        var assembler = AliTranscriptAssembler()
        do {
            _ = try assembler.accept(.started)
            var events = 0
            while true {
                try Task.checkCancellation()
                let event = try await connection.receive()
                try Task.checkCancellation()
                events += 1
                if events > 100_000 { return .failed(AliServiceFailure(.streamFailed)) }
                if case .finished = event {
                    let text = try assembler.accept(event) ?? assembler.currentText
                    return .final(text)
                }
                if let whole = try assembler.accept(event) {
                    try await writer.emit(kind: "partial", text: whole)
                }
            }
        } catch is CancellationError {
            return .cancelled
        } catch let failure as AliServiceFailure {
            return .failed(failure)
        } catch {
            return .failed(AliServiceFailure.transport(error))
        }
    }
}
