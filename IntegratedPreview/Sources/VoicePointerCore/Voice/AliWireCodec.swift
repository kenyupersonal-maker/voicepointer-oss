import Foundation

public enum AliWireError: Error {
    case invalid
    case taskFailed
}

public struct AliWord: Sendable, Equatable {
    public let text: String
    public let punctuation: String
    public let beginMilliseconds: Double?
    public let endMilliseconds: Double?

    init(text: String, punctuation: String, beginMilliseconds: Double?, endMilliseconds: Double?) {
        self.text = text
        self.punctuation = punctuation
        self.beginMilliseconds = beginMilliseconds
        self.endMilliseconds = endMilliseconds
    }
}

public struct AliSentence: Sendable, Equatable {
    public let id: Int
    public let text: String
    public let isFinal: Bool
    public let beginMilliseconds: Double?
    public let endMilliseconds: Double?
    public let words: [AliWord]

    init(id: Int, text: String, isFinal: Bool, beginMilliseconds: Double?, endMilliseconds: Double?, words: [AliWord]) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.beginMilliseconds = beginMilliseconds
        self.endMilliseconds = endMilliseconds
        self.words = words
    }
}

public enum AliWireEvent: Sendable, Equatable {
    case started
    case heartbeat
    case finished
    case sentence(AliSentence)
}

public struct AliWireCodec: Sendable {
    public static let legacyModelID = "qwen-audio-3.0-asr-flash-streaming"
    public static let supportedModelIDs: Set<String> = [legacyModelID, "qwen-audio-3.1-asr-flash-streaming", "fun-asr-realtime", "fun-asr-realtime-2026-02-28", "paraformer-realtime-v2", "paraformer-realtime-v1"]
    public let taskID: UUID
    public let modelID: String
    let language: String
    let hints: AliRecognitionHints?

    public init(taskID: UUID, language: String, hints: AliRecognitionHints? = nil, modelID: String = AliWireCodec.legacyModelID) throws {
        guard (language == "zh" || language == "en" || language == "auto"), Self.supportedModelIDs.contains(modelID) else {
            throw AliWireError.invalid
        }
        self.taskID = taskID
        self.modelID = modelID
        self.language = language
        self.hints = hints
    }

    private func commandJSON(action: String, parameters: [String: Any]?, includeParameters: Bool) throws -> Data {
        var payload: [String: Any] = ["task_group": "audio", "task": "asr", "function": "recognition", "model": modelID, "input": [String: Any]()]
        if includeParameters, let parameters = parameters {
            payload["parameters"] = parameters
            if [Self.legacyModelID, "qwen-audio-3.1-asr-flash-streaming", "fun-asr-realtime"].contains(modelID), let hints, !hints.recentTexts.isEmpty {
                payload["input"] = ["context": hints.recentTexts.map { text in
                    ["role": "user", "content": [["type": "input_text", "text": text]]] as [String: Any]
                }]
            }
        } else if includeParameters {
            throw AliWireError.invalid
        } else {
            payload = ["input": [String: Any]()]
        }
        let message: [String: Any] = [
            "header": [
                "action": action,
                "task_id": taskID.uuidString,
                "streaming": "duplex"
            ],
            "payload": payload
        ]
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw AliWireError.invalid
        }
        return data
    }

    public func startCommand() throws -> Data {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
            "heartbeat": true
        ]
        // Family-specific VAD fields; keep service defaults and the existing 16 kHz capture.
        if modelID == "paraformer-realtime-v1" { parameters.removeValue(forKey: "heartbeat") }
        if modelID == "qwen-audio-3.1-asr-flash-streaming" {
            parameters["vad_model"] = "far_field_meeting_16k"
        } else if modelID != "paraformer-realtime-v1" {
            parameters["max_sentence_silence"] = 1300
        }
        if language != "auto" {
            parameters["language_hints"] = [language]
        }
        if [Self.legacyModelID, "qwen-audio-3.1-asr-flash-streaming"].contains(modelID), let hints, !hints.termTexts.isEmpty {
            parameters["vocabulary"] = Dictionary(uniqueKeysWithValues: hints.termTexts.map { ($0, 2) })
        }
        return try commandJSON(action: "run-task", parameters: parameters, includeParameters: true)
    }

    public func finishCommand() throws -> Data {
        return try commandJSON(action: "finish-task", parameters: nil, includeParameters: false)
    }

    public func parse(_ data: Data) throws -> AliWireEvent {
        guard data.count <= 1_048_576 else { throw AliWireError.invalid }
        let envelope: WireEnvelope
        do {
            envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            throw AliWireError.invalid
        }
        guard let receivedTaskID = UUID(uuidString: envelope.header.taskID),
              receivedTaskID == taskID else {
            throw AliWireError.invalid
        }
        switch envelope.header.event {
        case "task-started":
            return .started
        case "task-finished":
            return .finished
        case "task-failed":
            throw AliServiceFailure.fromServiceCode(envelope.header.errorCode)
        case "result-generated":
            guard let sentence = envelope.payload?.output?.sentence else {
                throw AliWireError.invalid
            }
            return try parseSentence(sentence)
        default:
            throw AliWireError.invalid
        }
    }

    private func parseSentence(_ wire: WireSentence) throws -> AliWireEvent {
        if wire.heartbeat == true { return .heartbeat }
        let isParaformer = modelID == "paraformer-realtime-v2" || modelID == "paraformer-realtime-v1"
        let sentenceID: Int
        if isParaformer, wire.sentenceID == nil || wire.sentenceID == 0 {
            guard wire.beginTime != nil else { throw AliWireError.invalid }
            sentenceID = 0
        } else {
            guard let id = wire.sentenceID, (1...10_000).contains(id) else { throw AliWireError.invalid }
            sentenceID = id
        }
        guard wire.text.count <= 50_000,
              wire.text.utf8.count <= 1_048_576 else {
            throw AliWireError.invalid
        }
        var begin: Double?
        var end: Double?
        if let b = wire.beginTime { begin = try validateTime(b) }
        if let e = wire.endTime { end = try validateTime(e) }
        if let b = begin, let e = end, e < b { throw AliWireError.invalid }
        var words: [AliWord] = []
        if let wireWords = wire.words {
            guard wireWords.count <= 20_000 else { throw AliWireError.invalid }
            words = try wireWords.map { try parseWord($0) }
        }
        return .sentence(AliSentence(id: sentenceID, text: wire.text, isFinal: wire.sentenceEnd, beginMilliseconds: begin, endMilliseconds: end, words: words))
    }

    private func parseWord(_ wire: WireWord) throws -> AliWord {
        guard wire.text.count <= 128,
              (wire.punctuation ?? "").count <= 32 else {
            throw AliWireError.invalid
        }
        var begin: Double?
        var end: Double?
        if let b = wire.beginTime { begin = try validateTime(b) }
        if let e = wire.endTime { end = try validateTime(e) }
        if let b = begin, let e = end, e < b { throw AliWireError.invalid }
        return AliWord(text: wire.text, punctuation: wire.punctuation ?? "", beginMilliseconds: begin, endMilliseconds: end)
    }

    private func validateTime(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0, value <= 360_000 else { throw AliWireError.invalid }
        return value
    }
}

private struct WireEnvelope: Decodable {
    let header: WireHeader
    let payload: WirePayload?
}

private struct WireHeader: Decodable {
    let taskID: String
    let event: String
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case event
        case errorCode = "error_code"
    }
}

private struct WirePayload: Decodable {
    let output: WireOutput?
}

private struct WireOutput: Decodable {
    let sentence: WireSentence?
}

private struct WireSentence: Decodable {
    let sentenceID: Int?
    let text: String
    let sentenceEnd: Bool
    let beginTime: Double?
    let endTime: Double?
    let words: [WireWord]?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let heartbeat = try c.decodeIfPresent(Bool.self, forKey: .heartbeat)
        if heartbeat == true {
            self.heartbeat = true
            self.sentenceID = 0
            self.text = ""
            self.sentenceEnd = false
            self.beginTime = nil
            self.endTime = nil
            self.words = nil
            return
        }
        self.heartbeat = heartbeat
        self.sentenceID = try c.decodeIfPresent(Int.self, forKey: .sentenceID)
        self.text = try c.decode(String.self, forKey: .text)
        self.sentenceEnd = try c.decode(Bool.self, forKey: .sentenceEnd)
        self.beginTime = try c.decodeIfPresent(Double.self, forKey: .beginTime)
        self.endTime = try c.decodeIfPresent(Double.self, forKey: .endTime)
        self.words = try c.decodeIfPresent([WireWord].self, forKey: .words)
    }

    let heartbeat: Bool?

    enum CodingKeys: String, CodingKey {
        case sentenceID = "sentence_id"
        case text
        case sentenceEnd = "sentence_end"
        case beginTime = "begin_time"
        case endTime = "end_time"
        case words
        case heartbeat
    }
}

private struct WireWord: Decodable {
    let text: String
    let punctuation: String?
    let beginTime: Double?
    let endTime: Double?

    enum CodingKeys: String, CodingKey {
        case text
        case punctuation
        case beginTime = "begin_time"
        case endTime = "end_time"
    }
}
