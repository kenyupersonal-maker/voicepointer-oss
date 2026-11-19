import Foundation
import Darwin

@main
struct AliWorkerMain {
    static func main() async {
        guard CommandLine.arguments.count == 1 else { Darwin.exit(1) }
        var io: DuplexLineIO? = nil
        do {
            let active = try DuplexLineIO(readFD: STDIN_FILENO, writeFD: STDOUT_FILENO)
            io = active
            let initial = try await active.readLine(timeout: 10)
            let command = try AliIPC.decodeCommand(initial)
            guard case let .configure(sessionID, endpoint, language, credential, hints, modelID, checkOnly) = command else {
                await active.close()
                Darwin.exit(1)
            }
            let connection = try AliWebSocketConnection(
                endpoint: endpoint,
                credential: credential,
                taskID: sessionID,
                language: language,
                hints: hints,
                modelID: modelID
            )
            let session = AliStreamSession(
                sessionID: sessionID,
                io: active,
                connection: connection,
                checkOnly: checkOnly
            )
            let code = await session.run()
            Darwin.exit(code)
        } catch {
            await io?.close()
            Darwin.exit(1)
        }
    }
}
