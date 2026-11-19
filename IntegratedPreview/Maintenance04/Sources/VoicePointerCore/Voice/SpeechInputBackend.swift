import Foundation

@MainActor public protocol SpeechPartialActivityProviding: AnyObject {
    var partialCount: Int { get }
}

public struct SpeechInputCapabilities: Sendable, Equatable {
    public let deliveryKind: SpeechDeliveryKind
    public let supportsPartialText: Bool
    public let supportsHints: Bool

    public init(deliveryKind: SpeechDeliveryKind, supportsPartialText: Bool, supportsHints: Bool) {
        self.deliveryKind = deliveryKind
        self.supportsPartialText = supportsPartialText
        self.supportsHints = supportsHints
    }
}

/// Which recognizer wrote an event's text. Only the hybrid backend ("用于增强本地识别") sets it: its drafts and a
/// final it keeps from the local branch are `.local`, a final the cloud branch supplied is `.cloudEnhancement`.
/// Every other backend leaves it nil, so its events are unchanged.
public enum SpeechTranscriptSource: String, Sendable, Equatable {
    case local, cloudEnhancement
}

public struct SpeechInputEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case ready, partial, final, stopped, failed
    }

    public let sessionID: UUID
    public let sequence: UInt64
    public let observedMilliseconds: Double
    public let kind: Kind
    public let text: String?
    public let errorCode: String?
    public let transcriptSource: SpeechTranscriptSource?
    /// The model's selected-token probability, not calibrated transcript correctness. Missing fails closed.
    public let modelConfidence: Double?
    public let confidenceEvidence: LocalModelConfidence?

    public init(sessionID: UUID, sequence: UInt64, observedMilliseconds: Double,
                kind: Kind, text: String? = nil, errorCode: String? = nil,
                transcriptSource: SpeechTranscriptSource? = nil, modelConfidence: Double? = nil,
                confidenceEvidence: LocalModelConfidence? = nil) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.observedMilliseconds = observedMilliseconds
        self.kind = kind
        self.text = text
        self.errorCode = errorCode
        self.transcriptSource = transcriptSource
        self.modelConfidence = confidenceEvidence?.probability ?? modelConfidence
        self.confidenceEvidence = confidenceEvidence
    }
}

@MainActor public protocol SpeechCapturedDurationProviding: AnyObject {
    var capturedDurationSeconds: Double { get }
}

/// Bounded speech backend contract. Implementations own audio capture when
/// needed; externalEditor delivery never invents raw transcript text. No
/// provider SDK, AX, or credentials belong in this protocol.
@MainActor
public protocol SpeechInputBackend: AnyObject {
    var isQuiescent: Bool { get }
    var capabilities: SpeechInputCapabilities { get }
    func start(snapshot: VoiceInputSnapshot,
               onEvent: @escaping @MainActor @Sendable (SpeechInputEvent) -> Void) async throws
    func finish() async
    func cancel() async
}

/// Closes capture and output admission before asynchronous owner cleanup can suspend.
/// The same backend still owns its lease until cancel() has drained it.
@MainActor
public protocol SpeechCaptureCancellationInvalidating: AnyObject {
    func invalidateCaptureForCancellation()
}

@MainActor public protocol SpeechCaptureActivityProviding: AnyObject {
    var hasAcceptedCaptureAudio: Bool { get }
}

/// Pure validator enforcing session event contracts against a frozen snapshot.
/// Delivery mapping: .voiceNative routes are transcript streams; .doubao
/// routes deliver into an external editor.
public struct SpeechSessionEventGate: Sendable {
    public enum GateError: Error, Equatable {
        case invalidSelection(String)
    }

    private let frozenSnapshot: VoiceInputSnapshot
    private var lastSequence: UInt64?
    private var lastMilliseconds: Double?
    private var isClosed = false
    private var isInvalidated = false

    /// The frozen snapshot this gate validates against (read-only).
    public var snapshot: VoiceInputSnapshot { frozenSnapshot }

    public init(snapshot: VoiceInputSnapshot) throws {
        let selection = snapshot.selection
        func isBlank(_ value: String) -> Bool {
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Defensive: selection fields are publicly mutable, so re-validate here.
        guard !isBlank(selection.routeID) else { throw GateError.invalidSelection("routeID") }
        guard !isBlank(selection.language) else { throw GateError.invalidSelection("language") }
        guard snapshot.lexiconRevision >= 0 else { throw GateError.invalidSelection("lexiconRevision") }
        frozenSnapshot = snapshot
    }

    /// Permanently rejects all further events.
    public mutating func invalidate() { isInvalidated = true }

    /// Validates and records an event. Rejections never advance gate state.
    public mutating func accept(_ event: SpeechInputEvent) -> Bool {
        if isInvalidated || isClosed { return false }
        guard event.sessionID == frozenSnapshot.sessionID else { return false }
        if let last = lastSequence, event.sequence <= last { return false }
        let ms = event.observedMilliseconds
        guard ms.isFinite, ms >= 0 else { return false }
        if let last = lastMilliseconds, ms < last { return false }
        let isTranscriptStream = frozenSnapshot.selection.mode == .voiceNative
        switch event.kind {
        case .partial, .final:
            guard isTranscriptStream, event.text != nil else { return false }
        case .ready, .stopped, .failed:
            break
        }
        lastSequence = event.sequence
        lastMilliseconds = ms
        switch event.kind {
        case .final, .stopped, .failed:
            isClosed = true
        default:
            break
        }
        return true
    }
}
