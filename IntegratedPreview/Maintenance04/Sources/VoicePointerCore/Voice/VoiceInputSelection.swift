import Foundation

/// I00 selection contract for the VoicePointer integrated preview.
/// Pure data: selecting settings never starts speech, audio, or UI side effects.

public enum VoiceInputMode: String, Codable, Sendable {
    case doubao
    case voiceNative
}

public enum SpeechDeliveryKind: String, Codable, Sendable {
    case externalEditor
    case transcriptStream
}

public enum VoiceInputSelectionError: Error, Sendable {
    case emptyField(String)
    case negativeLexiconRevision(Int)
}

public struct VoiceInputSelection: Codable, Sendable, Equatable {
    public var mode: VoiceInputMode
    public var routeID: String
    public var language: String
    /// HTTP providers may auto-detect a local language they do not expose as a request field.
    static func isBoundedLanguageTag(_ value: String) -> Bool {
        (1...32).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }

    /// Throwing so programmatic construction enforces the same invariants as decoding.
    public init(mode: VoiceInputMode = .doubao,
                routeID: String = "qwen17-rolling",
                language: String = "zh") throws {
        guard !routeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceInputSelectionError.emptyField("routeID")
        }
        guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceInputSelectionError.emptyField("language")
        }
        self.mode = mode
        self.routeID = routeID
        self.language = language
    }

    public var deliveryKind: SpeechDeliveryKind {
        mode == .doubao ? .externalEditor : .transcriptStream
    }

    public enum CodingKeys: String, CodingKey {
        case mode, routeID, language
    }

    /// Absent fields migrate to defaults; wrong types and unknown enum values throw.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode: VoiceInputMode
        if let raw = try c.decodeIfPresent(String.self, forKey: .mode) {
            guard let decoded = VoiceInputMode(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mode, in: c,
                    debugDescription: "Unknown VoiceInputMode rawValue: \(raw)")
            }
            mode = decoded
        } else {
            mode = .doubao
        }
        let routeID = try c.decodeIfPresent(String.self, forKey: .routeID) ?? "qwen17-rolling"
        let language = try c.decodeIfPresent(String.self, forKey: .language) ?? "zh"
        try self.init(mode: mode, routeID: routeID, language: language)
    }
}

/// Pure selection transition used by settings UI. An unavailable external
/// input method must not replace the user's current route.
public enum VoiceInputSelectionTransition {
    public static func selectingDoubao(
        from current: VoiceInputSelection,
        isInstalled: Bool
    ) -> VoiceInputSelection? {
        guard isInstalled else { return nil }
        var selection = current
        selection.mode = .doubao
        return selection
    }
}

/// Immutable value capture of a selection at a point in time.
public struct VoiceInputSnapshot: Sendable, Equatable {
    public let sessionID: UUID
    public let selection: VoiceInputSelection
    public let lexiconRevision: Int
    /// Words of the personal lexicon the recognizer on this Mac may be told to listen for, already chosen and
    /// limited by the caller. Only the local recognizer reads them: a cloud route never does, and the local
    /// route a cloud dictation falls back to carries them along.
    public let localHotwords: [String]
    public let localContext: RecognitionContextPlan?
    public let contextAppKey: String
    public let onlineAPIConfiguration: OnlineAPIConfiguration?

    public init(
        sessionID: UUID, selection: VoiceInputSelection, lexiconRevision: Int, localHotwords: [String] = [], onlineAPIConfiguration: OnlineAPIConfiguration? = nil,
        localContext: RecognitionContextPlan? = nil, contextAppKey: String = ""
    ) throws {
        guard lexiconRevision >= 0 else {
            throw VoiceInputSelectionError.negativeLexiconRevision(lexiconRevision)
        }
        self.init(validated: sessionID, selection: selection, lexiconRevision: lexiconRevision, localHotwords: localHotwords, onlineAPIConfiguration: onlineAPIConfiguration, localContext: localContext, contextAppKey: contextAppKey)
    }

    private init(validated sessionID: UUID, selection: VoiceInputSelection, lexiconRevision: Int, localHotwords: [String], onlineAPIConfiguration: OnlineAPIConfiguration?, localContext: RecognitionContextPlan?, contextAppKey: String) {
        self.sessionID = sessionID
        self.selection = selection
        self.lexiconRevision = lexiconRevision
        self.localHotwords = localHotwords
        self.localContext = localContext
        self.contextAppKey = contextAppKey
        self.onlineAPIConfiguration = onlineAPIConfiguration
    }

    /// The same capture without the hot words: what any backend that is not the local recognizer is given.
    public func withoutLocalHotwords() -> VoiceInputSnapshot {
        VoiceInputSnapshot(validated: sessionID, selection: selection, lexiconRevision: lexiconRevision, localHotwords: [], onlineAPIConfiguration: onlineAPIConfiguration, localContext: nil, contextAppKey: "")
    }

    /// The cached foreground app may differ from the editor found asynchronously.
    /// In that case discard recent sentences without consulting live memory again.
    public func confirmedContextTarget(_ appKey: String?) -> VoiceInputSnapshot {
        guard let localContext, !localContext.recent.isEmpty, appKey != contextAppKey else { return self }
        let plan = RecognitionContextPlanner.plan(selectedTerms: localContext.terms, memory: [], appKey: "",
            now: Date(), destination: .local, options: .init(recentEnabled: false))
        return VoiceInputSnapshot(validated: sessionID, selection: selection, lexiconRevision: lexiconRevision,
            localHotwords: localHotwords, onlineAPIConfiguration: onlineAPIConfiguration, localContext: plan, contextAppKey: "")
    }
}
