import Foundation

internal struct GroqWireError: Error, Sendable { let code: String }

internal struct GroqWireResult: Sendable {
    let sessionID: UUID
    let text: String
    let hostMilliseconds: Double
    let requestMilliseconds: Double
}

internal struct GroqWireProtocol: Sendable {
    let sessionID: UUID
    let routeID: String
    let language: String
    let provider: OnlineAPIProvider
    let modelID: String?

    init(sessionID: UUID, routeID: String, language: String, provider: OnlineAPIProvider = .groq, modelID: String? = nil) throws {
        let routes: Set<String> = provider == .groq ? ["groq-v3", "groq-turbo"] : provider == .openai ? ["openai-transcribe", "openai-mini-transcribe"] : provider == .siliconflow ? ["siliconflow-sensevoice"] : []
        guard routes.contains(routeID) else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        guard VoiceInputSelection.isBoundedLanguageTag(language), modelID.map(provider.modelIDs.contains) ?? true else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        self.sessionID = sessionID
        self.routeID = routeID
        self.language = language
        self.provider = provider
        self.modelID = modelID
    }

    func configurationLine(credential: Data) throws -> Data {
        let key = try Self.validatedCredential(credential)
        var object: [String: String] = [
            "op": "configure", "session_id": sessionID.uuidString,
            "route": routeID, "language": provider == .groq && !["zh", "en"].contains(language) ? "auto" : language, "key": key,
        ]
        if let modelID, provider != .groq { object["model"] = modelID }
        return try Self.encodeLine(object, limit: 8192)
    }

    func transcriptionLine(wav: Data) throws -> Data {
        guard wav.count >= 44 && wav.count <= 10 * 1024 * 1024 else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        guard wav.starts(with: Data("RIFF".utf8)), wav.dropFirst(8).prefix(4) == Data("WAVE".utf8) else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        return try Self.encodeLine([
            "op": "transcribe", "session_id": sessionID.uuidString,
            "wav_base64": wav.base64EncodedString(),
        ], limit: 14 * 1024 * 1024)
    }

    func parseReady(_ line: Data) throws -> Double {
        let r = try Self.decodeResponse(line)
        guard Self.matches(r, sessionID: sessionID, expectedSequence: 0) else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        guard let h = r.host_ms, h.isFinite, h >= 0 else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        if r.type == "ready" {
            return h
        }
        if r.type == "failed" { throw failure(r) }
        throw GroqWireError(code: "GROQ_WIRE_INVALID")
    }

    func parseFinal(_ line: Data, readyHostMilliseconds: Double) throws -> GroqWireResult {
        guard readyHostMilliseconds.isFinite, readyHostMilliseconds >= 0 else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        let r = try Self.decodeResponse(line)
        guard Self.matches(r, sessionID: sessionID, expectedSequence: 1) else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        guard let host = r.host_ms, host.isFinite, host >= 0, host >= readyHostMilliseconds else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        if r.type == "failed" { throw failure(r) }
        guard r.type == "final", let text = r.text else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        guard text.count <= 50000, let utf8 = text.data(using: .utf8), utf8.count <= 1024 * 1024 else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        guard r.mode == "file_after_stop" else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        guard let requestMS = r.request_ms, requestMS.isFinite, requestMS >= 0 else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        return GroqWireResult(sessionID: sessionID, text: text, hostMilliseconds: host, requestMilliseconds: requestMS)
    }

    private struct Response: Decodable, Sendable {
        let type: String
        let session_id: String?
        let sequence: Int?
        let host_ms: Double?
        let text: String?
        let mode: String?
        let request_ms: Double?
        let error_code: String?
    }

    private static let allowedErrorCodes: Set<String> = [
        "config_invalid", "command_invalid", "audio_invalid", "response_invalid",
        "request_failed", "http_401", "http_403", "http_413", "http_429", "http_5xx", "http_insufficient_quota",
    ]

    private static func validatedCredential(_ data: Data) throws -> String {
        guard data.count >= 16 && data.count <= 4096 else { throw GroqWireError(code: "GROQ_CREDENTIAL_INVALID") }
        guard data.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw GroqWireError(code: "GROQ_CREDENTIAL_INVALID") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeLine(_ payload: [String: String], limit: Int) throws -> Data {
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoded = try encoder.encode(payload)
        } catch { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        var line = encoded
        line.append(0x0A)
        guard line.count <= limit else { throw GroqWireError(code: "GROQ_WIRE_OVERSIZE") }
        return line
    }

    private static func decodeResponse(_ line: Data) throws -> Response {
        guard line.count <= 1024 * 1024 else { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
        do { return try JSONDecoder().decode(Response.self, from: line) }
        catch { throw GroqWireError(code: "GROQ_WIRE_INVALID") }
    }

    private static func matches(_ r: Response, sessionID: UUID, expectedSequence: Int) -> Bool {
        guard let sid = r.session_id, let uuid = UUID(uuidString: sid), uuid == sessionID else { return false }
        return r.sequence == expectedSequence
    }

    private func failure(_ r: Response) -> GroqWireError {
        guard let code = r.error_code, Self.allowedErrorCodes.contains(code), provider == .openai || code != "http_insufficient_quota" else { return GroqWireError(code: "GROQ_WORKER_FAILED") }
        return GroqWireError(code: provider == .openai ? SpeechFailureDiagnostics.openAICode(code) : code)
    }
}
