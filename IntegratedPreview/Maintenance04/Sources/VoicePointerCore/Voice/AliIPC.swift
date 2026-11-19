import Foundation
import CoreFoundation

// Pure child/parent IPC wire protocol for the Ali realtime stream.
// No IO, networking, logging, or file access in this file.

internal enum AliIPCError: Error {
    case invalid
    case oversize
}

internal struct AliHostReadyTiming: Sendable {
    let workerMs: Double
    let connectMs: Double?
    let taskStartMs: Double?
    var path: String = "system"
}

internal enum AliIPCCommand: Sendable {
    case configure(sessionID: UUID, endpoint: AliEndpoint, language: String, credential: Data, modelID: String = AliIPC.legacyModelID, checkOnly: Bool = false)
    case pcm(Data)
    case finish
    case cancel
}

internal struct AliIPCOutput: Codable, Sendable, Equatable {
    struct ReadyTiming: Codable, Sendable, Equatable {
        let connectMs: Double
        let taskStartMs: Double
        let path: String?
        init(connectMs: Double, taskStartMs: Double, path: String? = nil) {
            self.connectMs = connectMs; self.taskStartMs = taskStartMs; self.path = path
        }
        var isValid: Bool {
            (path == nil || path == "direct" || path == "system")
                && [connectMs, taskStartMs].allSatisfy { $0.isFinite && (0...30_000).contains($0) }
        }
    }
    let sessionID: UUID
    let sequence: UInt64
    let observedMilliseconds: Double
    let kind: String
    let text: String?
    let errorCode: String?
    let failureEvidence: AliFailureEvidence?
    let readyTiming: ReadyTiming?

    init(sessionID: UUID, sequence: UInt64, observedMilliseconds: Double,
         kind: String, text: String?, errorCode: String?,
         failureEvidence: AliFailureEvidence? = nil, readyTiming: ReadyTiming? = nil) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.observedMilliseconds = observedMilliseconds
        self.kind = kind
        self.text = text
        self.errorCode = errorCode
        self.failureEvidence = failureEvidence
        self.readyTiming = readyTiming
    }
}

internal enum AliIPC {

    static let legacyModelID = "qwen-audio-3.0-asr-flash-streaming"
    static let supportedModelIDs: Set<String> = [legacyModelID, "qwen-audio-3.1-asr-flash-streaming", "fun-asr-realtime", "fun-asr-realtime-2026-02-28", "paraformer-realtime-v2", "paraformer-realtime-v1"]

    private static let configureKeys: Set<String> = ["type", "session_id", "endpoint", "language", "key"]
    private static let pcmKeys: Set<String> = ["type", "pcm_base64"]
    private static let plainKeys: Set<String> = ["type"]
    private static let languages: Set<String> = ["zh", "en", "auto"]
    private static let kinds: Set<String> = ["ready", "partial", "final", "stopped", "failed", "checked"]

    private static let maxCommandBytes = 65_536
    private static let maxConfigureBytes = 8_192
    private static let maxOutputBytes = 1_048_576
    private static let maxPCMBytes = 32_000
    private static let writing: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]

    // MARK: - Commands

    static func encodeCommand(_ command: AliIPCCommand) throws -> Data {
        var object: [String: Any]
        let cap: Int
        switch command {
        case .finish:
            object = ["type": "finish"]
            cap = maxCommandBytes
        case .cancel:
            object = ["type": "cancel"]
            cap = maxCommandBytes
        case let .pcm(data):
            guard data.count >= 2, data.count <= maxPCMBytes, data.count % 2 == 0 else { throw AliIPCError.invalid }
            object = ["type": "pcm", "pcm_base64": data.base64EncodedString()]
            cap = maxCommandBytes
        case let .configure(sessionID, endpoint, language, credential, modelID, checkOnly):
            let key = try keyString(from: credential)
            guard languages.contains(language), supportedModelIDs.contains(modelID) else { throw AliIPCError.invalid }
            object = ["type": "configure", "session_id": sessionID.uuidString,
                      "endpoint": try validatedAbsoluteURL(of: endpoint),
                      "language": language, "key": key]
            if modelID != legacyModelID { object["model_id"] = modelID }
            if checkOnly { object["check_only"] = true }
            cap = maxConfigureBytes
        }
        let line = try serialize(object)
        guard line.count <= cap else { throw AliIPCError.oversize }
        return line + Data("\n".utf8)
    }

    static func decodeCommand(_ line: Data) throws -> AliIPCCommand {
        guard line.count <= maxCommandBytes else { throw AliIPCError.oversize }
        guard !containsNewline(line) else { throw AliIPCError.invalid }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: line) }
        catch { throw AliIPCError.invalid }
        guard let dict = root as? [String: Any], let type = dict["type"] as? String else { throw AliIPCError.invalid }
        switch type {
        case "finish", "cancel":
            guard Set(dict.keys) == plainKeys else { throw AliIPCError.invalid }
            return type == "finish" ? .finish : .cancel
        case "pcm":
            guard Set(dict.keys) == pcmKeys, let encoded = dict["pcm_base64"] as? String,
                  let data = Data(base64Encoded: encoded) else { throw AliIPCError.invalid }
            guard data.count >= 2, data.count <= maxPCMBytes, data.count % 2 == 0 else { throw AliIPCError.invalid }
            return .pcm(data)
        case "configure":
            guard configureKeys.isSubset(of: Set(dict.keys)), Set(dict.keys).isSubset(of: configureKeys.union(["model_id", "check_only"])) else { throw AliIPCError.invalid }
            guard line.count <= maxConfigureBytes else { throw AliIPCError.oversize }
            guard let session = dict["session_id"] as? String, let sessionID = UUID(uuidString: session),
                  let endpointRaw = dict["endpoint"] as? String, let language = dict["language"] as? String,
                  let key = dict["key"] as? String, languages.contains(language) else { throw AliIPCError.invalid }
            let endpoint: AliEndpoint
            do { endpoint = try AliEndpoint(endpointRaw) } catch { throw AliIPCError.invalid }
            let modelID = dict["model_id"] as? String ?? legacyModelID
            guard (dict["model_id"] == nil || dict["model_id"] is String), supportedModelIDs.contains(modelID) else { throw AliIPCError.invalid }
            var checkOnly = false
            if let value = dict["check_only"] {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw AliIPCError.invalid }
                checkOnly = flag.boolValue
            }
            return .configure(sessionID: sessionID, endpoint: endpoint,
                              language: language, credential: try credentialData(fromKey: key), modelID: modelID, checkOnly: checkOnly)
        default:
            throw AliIPCError.invalid
        }
    }

    // MARK: - Outputs

    static func encodeOutput(_ output: AliIPCOutput) throws -> Data {
        try validate(output)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line: Data
        do { line = try encoder.encode(output) }
        catch { throw AliIPCError.invalid }
        guard line.count <= maxOutputBytes else { throw AliIPCError.oversize }
        return line + Data("\n".utf8)
    }

    static func decodeOutput(_ line: Data) throws -> AliIPCOutput {
        let payload = line
        guard !containsNewline(payload) else { throw AliIPCError.invalid }
        guard payload.count <= maxOutputBytes else { throw AliIPCError.oversize }
        let output: AliIPCOutput
        do { output = try JSONDecoder().decode(AliIPCOutput.self, from: payload) }
        catch { throw AliIPCError.invalid }
        try validate(output)
        return output
    }

    // MARK: - Validation

    private static func validate(_ output: AliIPCOutput) throws {
        guard kinds.contains(output.kind) else { throw AliIPCError.invalid }
        if let timing = output.readyTiming {
            guard output.kind == "ready", timing.isValid else { throw AliIPCError.invalid }
        }
        guard output.kind == "failed" || output.failureEvidence == nil else { throw AliIPCError.invalid }
        guard output.observedMilliseconds.isFinite, output.observedMilliseconds >= 0,
              output.observedMilliseconds <= 400_000, output.sequence <= 100_000 else { throw AliIPCError.invalid }
        switch output.kind {
        case "partial", "final":
            guard let text = output.text, text.count <= 50_000,
                  text.utf8.count <= maxOutputBytes, output.errorCode == nil else { throw AliIPCError.invalid }
        case "failed":
            guard output.text == nil, let code = output.errorCode,
                  AliServiceFailure.Code(rawValue: code) != nil else { throw AliIPCError.invalid }
        default:
            guard output.text == nil, output.errorCode == nil else { throw AliIPCError.invalid }
        }
    }

    // MARK: - Helpers

    private static func keyString(from credential: Data) throws -> String {
        guard credential.count >= 16, credential.count <= 4096,
              credential.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              let key = String(data: credential, encoding: .ascii) else { throw AliIPCError.invalid }
        return key
    }

    private static func credentialData(fromKey key: String) throws -> Data {
        guard key.count >= 16, key.count <= 4096,
              key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 33 && $0.value <= 126 }),
              let data = key.data(using: .ascii) else { throw AliIPCError.invalid }
        return data
    }

    private static func validatedAbsoluteURL(of endpoint: AliEndpoint) throws -> String {
        let absolute = endpoint.url.absoluteString
        do { _ = try AliEndpoint(absolute) } catch { throw AliIPCError.invalid }
        return absolute
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        do { return try JSONSerialization.data(withJSONObject: object, options: writing) }
        catch { throw AliIPCError.invalid }
    }

    private static func containsNewline(_ data: Data) -> Bool {
        data.contains { $0 == 0x0A || $0 == 0x0D }
    }

}
