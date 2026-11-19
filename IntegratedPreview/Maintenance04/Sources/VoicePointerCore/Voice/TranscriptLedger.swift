import Foundation

/// A single observed grapheme cluster with the host time it was first seen.
public struct TranscriptCharacterObservation: Codable, Sendable, Equatable {
    public let character: String
    public let firstObservedMilliseconds: Double
    public let version: Int

    public init(character: String, firstObservedMilliseconds: Double, version: Int) {
        self.character = character
        self.firstObservedMilliseconds = firstObservedMilliseconds
        self.version = version
    }
}

/// An immutable raw transcript version. Corrections never alter these.
public struct TranscriptVersion: Codable, Sendable, Equatable {
    public let revision: Int
    public let observedMilliseconds: Double
    public let text: String
    public let isFinal: Bool
    public let characters: [TranscriptCharacterObservation]

    public init(revision: Int, observedMilliseconds: Double, text: String,
                isFinal: Bool, characters: [TranscriptCharacterObservation]) {
        self.revision = revision
        self.observedMilliseconds = observedMilliseconds
        self.text = text
        self.isFinal = isFinal
        self.characters = characters
    }
}

/// A separate corrected transcript record; never mutates raw versions.
public struct TranscriptCorrection: Codable, Sendable, Equatable {
    public let revision: Int
    public let observedMilliseconds: Double
    public let text: String
    public let lexiconRevision: Int

    public init(revision: Int, observedMilliseconds: Double, text: String, lexiconRevision: Int) {
        self.revision = revision
        self.observedMilliseconds = observedMilliseconds
        self.text = text
        self.lexiconRevision = lexiconRevision
    }
}

/// Immutable export of a ledger. Contains no internal sequencing state.
public struct TranscriptLedgerSnapshot: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let routeID: String
    public let language: String
    public let lexiconRevision: Int
    public let rawVersions: [TranscriptVersion]
    public let corrections: [TranscriptCorrection]
    public let isClosed: Bool

    public init(sessionID: UUID, routeID: String, language: String, lexiconRevision: Int,
                rawVersions: [TranscriptVersion], corrections: [TranscriptCorrection], isClosed: Bool) {
        self.sessionID = sessionID
        self.routeID = routeID
        self.language = language
        self.lexiconRevision = lexiconRevision
        self.rawVersions = rawVersions
        self.corrections = corrections
        self.isClosed = isClosed
    }
}

public enum LedgerError: Error, Equatable {
    case invalidMetadata
    case wrongSession
    case invalidEvent
    case closed
    case capacityExceeded
    case correctionRequiresFinal
}

/// Append-only transcript ledger with raw/corrected isolation.
public struct TranscriptLedger: Sendable, Equatable {
    public static let maxVersions = 2000
    public static let maxTextCharacters = 50_000
    public static let maxTotalCharacters = 2_000_000

    public let sessionID: UUID
    public let routeID: String
    public let language: String
    public let lexiconRevision: Int

    public private(set) var rawVersions: [TranscriptVersion]
    public private(set) var corrections: [TranscriptCorrection]
    public private(set) var isClosed: Bool

    internal private(set) var lastAcceptedEventSequence: UInt64?
    internal private(set) var lastObservedMilliseconds: Double?
    private var hasFinalRawVersion: Bool
    private var totalCharacterCount: Int

    public init(sessionID: UUID, routeID: String, language: String, lexiconRevision: Int) throws {
        if routeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || routeID.count > 128 {
            throw LedgerError.invalidMetadata
        }
        if language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || language.count > 128 {
            throw LedgerError.invalidMetadata
        }
        if lexiconRevision < 0 { throw LedgerError.invalidMetadata }
        self.sessionID = sessionID
        self.routeID = routeID
        self.language = language
        self.lexiconRevision = lexiconRevision
        self.rawVersions = []
        self.corrections = []
        self.isClosed = false
        self.lastAcceptedEventSequence = nil
        self.lastObservedMilliseconds = nil
        self.hasFinalRawVersion = false
        self.totalCharacterCount = 0
    }

    /// Reads-only export snapshot; excludes internal event sequencing.
    public func snapshot() -> TranscriptLedgerSnapshot {
        TranscriptLedgerSnapshot(sessionID: sessionID, routeID: routeID, language: language,
                                 lexiconRevision: lexiconRevision, rawVersions: rawVersions,
                                 corrections: corrections, isClosed: isClosed)
    }

    @discardableResult
    public mutating func append(event: SpeechInputEvent) throws -> Bool {
        if isClosed { throw LedgerError.closed }
        if event.sessionID != sessionID { throw LedgerError.wrongSession }
        guard event.observedMilliseconds.isFinite, event.observedMilliseconds >= 0 else {
            throw LedgerError.invalidEvent
        }
        if let lastTime = lastObservedMilliseconds, event.observedMilliseconds < lastTime {
            throw LedgerError.invalidEvent
        }
        if let lastSeq = lastAcceptedEventSequence, event.sequence <= lastSeq {
            throw LedgerError.invalidEvent
        }

        switch event.kind {
        case .ready:
            lastAcceptedEventSequence = event.sequence
            lastObservedMilliseconds = event.observedMilliseconds
            return false
        case .partial, .final:
            guard let text = event.text else { throw LedgerError.invalidEvent }
            if text.count > Self.maxTextCharacters { throw LedgerError.capacityExceeded }
            if rawVersions.count >= Self.maxVersions { throw LedgerError.capacityExceeded }
            if totalCharacterCount + text.count > Self.maxTotalCharacters {
                throw LedgerError.capacityExceeded
            }
            let version = makeVersion(text: text, observedMilliseconds: event.observedMilliseconds,
                                      isFinal: event.kind == .final)
            rawVersions.append(version)
            totalCharacterCount += text.count
            if event.kind == .final {
                hasFinalRawVersion = true
                isClosed = true
            }
            lastAcceptedEventSequence = event.sequence
            lastObservedMilliseconds = event.observedMilliseconds
            return true
        case .stopped, .failed:
            lastAcceptedEventSequence = event.sequence
            lastObservedMilliseconds = event.observedMilliseconds
            isClosed = true
            return false
        }
    }

    /// Append a separate corrected transcript. Requires a successful final raw version.
    public mutating func appendCorrection(text: String, observedMilliseconds: Double,
                                          lexiconRevision: Int) throws {
        if !hasFinalRawVersion { throw LedgerError.correctionRequiresFinal }
        guard observedMilliseconds.isFinite, observedMilliseconds >= 0,
              lexiconRevision >= 0 else { throw LedgerError.invalidEvent }
        if let lastRaw = rawVersions.last, observedMilliseconds < lastRaw.observedMilliseconds {
            throw LedgerError.invalidEvent
        }
        if let lastCorrection = corrections.last,
           observedMilliseconds < lastCorrection.observedMilliseconds {
            throw LedgerError.invalidEvent
        }
        if text.count > Self.maxTextCharacters { throw LedgerError.capacityExceeded }
        if corrections.count >= Self.maxVersions { throw LedgerError.capacityExceeded }
        if totalCharacterCount + text.count > Self.maxTotalCharacters {
            throw LedgerError.capacityExceeded
        }
        corrections.append(TranscriptCorrection(revision: corrections.count,
                                                observedMilliseconds: observedMilliseconds,
                                                text: text, lexiconRevision: lexiconRevision))
        totalCharacterCount += text.count
    }

    /// Builds a raw version using longest common grapheme-cluster prefix
    /// against the previous raw version. Suffix characters (including any
    /// characters after a changed prefix, even if identical) get the current
    /// event time and revision. No LCS-based identity guessing.
    private func makeVersion(text: String, observedMilliseconds: Double, isFinal: Bool) -> TranscriptVersion {
        let revision = rawVersions.count
        let newCharacters = Array(text)
        let previousCharacters: [TranscriptCharacterObservation] =
            rawVersions.last?.characters ?? []
        let prefixCount = commonPrefixCount(newCharacters,
                                            previous: previousCharacters.map { $0.character })
        var observations: [TranscriptCharacterObservation] = []
        observations.reserveCapacity(newCharacters.count)
        for index in 0..<prefixCount {
            observations.append(previousCharacters[index])
        }
        for index in prefixCount..<newCharacters.count {
            observations.append(TranscriptCharacterObservation(
                character: String(newCharacters[index]),
                firstObservedMilliseconds: observedMilliseconds,
                version: revision))
        }
        return TranscriptVersion(revision: revision,
                                 observedMilliseconds: observedMilliseconds,
                                 text: text, isFinal: isFinal, characters: observations)
    }

    private func commonPrefixCount(_ chars: [Character], previous: [String]) -> Int {
        let limit = min(chars.count, previous.count)
        var count = 0
        while count < limit && String(chars[count]) == previous[count] {
            count += 1
        }
        return count
    }
}
