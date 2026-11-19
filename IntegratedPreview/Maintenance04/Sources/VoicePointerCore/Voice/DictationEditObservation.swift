import Foundation

/// The receipt of a dictation the executor has just left in a field: what the field held once the dictation
/// had settled, and where in it the dictation sits. Everything the learning-from-corrections feature needs to
/// tell later on which part of the field is still the dictation. Held in memory only; never logged (the log
/// gets lengths).
public struct KeptDictationBaseline: Sendable, Equatable {
    public let id: UUID
    public let processIdentifier: pid_t
    /// The whole field as the executor read it (`ComposerTextNormalizer` applied), UTF-16 exact.
    public let document: String
    /// Where the dictation sits in `document`, in UTF-16 units.
    public let spanLocation: Int
    public let spanLength: Int
    /// The text that was delivered.
    public let delivered: String
    /// Values that mean "the field is empty" in this app (its hint text), besides blank.
    public let emptyStateValues: [String]
    /// `EditingIntentClock`'s count when the dictation settled: key and mouse presses after it are the
    /// person's.
    public let editingGeneration: UInt64
    /// "inline" (written while speaking) or "paste" (written once, at the end). For the log.
    public let path: String
    /// Texts the dictation's place in the field held before, or that the dictation itself once was (the
    /// selection it replaced, its earlier drafts): the dictation reading like one of them again means Undo.
    public let revertTexts: [String]
    public init(id: UUID, processIdentifier: pid_t, document: String, spanLocation: Int, spanLength: Int,
                delivered: String, emptyStateValues: [String], editingGeneration: UInt64, path: String, revertTexts: [String]) {
        self.id = id; self.processIdentifier = processIdentifier; self.document = document
        self.spanLocation = spanLocation; self.spanLength = spanLength; self.delivered = delivered
        self.emptyStateValues = emptyStateValues; self.editingGeneration = editingGeneration
        self.path = path; self.revertTexts = revertTexts
    }
}

/// What the field held when the next gesture began in the same field as a kept dictation: the text the
/// executor had to read anyway to start that gesture, so the look costs nothing extra.
public struct FieldRevisitSample: Sendable, Equatable {
    /// The `KeptDictationBaseline` this sample belongs to.
    public let baselineID: UUID
    /// The field's text; "" when the field is empty (blank, phantom line break, hint); nil when unreadable.
    public let document: String?
    /// `EditingIntentClock`'s count at that moment.
    public let editingGeneration: UInt64
    public let caretAtEnd: Bool
    public init(baselineID: UUID, document: String?, editingGeneration: UInt64, caretAtEnd: Bool = false) {
        self.baselineID = baselineID; self.document = document; self.editingGeneration = editingGeneration
        self.caretAtEnd = caretAtEnd
    }
}

/// The executor's side of learning from corrections: two one-slot mailboxes, no Accessibility work behind
/// either call. Filled on the executor's worker, emptied by the coordinator.
public protocol KeptDeliveryReporting: Sendable {
    /// The receipt of the delivery that just ended `.kept` in `session`, once.
    func takeKeptBaseline(for session: ComposerActionSession?) -> KeptDictationBaseline?
    /// The look at the field that `session`'s start took, when the field is the one the last kept dictation
    /// went to, once.
    func takeRevisit(for session: ComposerActionSession?) -> FieldRevisitSample?
}

/// The app's side: told when a dictation was kept and when the next gesture began.
@MainActor
public protocol DictationEditObserving: AnyObject {
    func configureTeacherRecheck(recognize: @escaping TeacherLearningRuntime.Recognizer, cancel: @escaping @Sendable () async -> Void)
    func cancelTeacherRecheck()
    func pauseTeacherRecheck()
    func resumeTeacherRecheck()
    func waitForTeacherCancellation() async
    func teacherDictationDelivered(roundID: UUID)
    /// All qualified final teacher transcripts, even if the local branch has no candidate.
    /// Implementations may persist only salted fragment digests, never whole sentences.
    func teacherFinalObserved(text: String, roundID: UUID, source: EnhancementComparison.Source)
    func teacherFinalReceiver() -> (@MainActor @Sendable (UUID, String) -> Void)?
    /// Receiver for results already produced by a hybrid session. No additional reads or recognition.
    func enhancementReceiver() -> (@MainActor @Sendable (EnhancementComparison) -> Void)?
    func doubaoEnhancementCompared(_ comparison: EnhancementComparison, baseline: KeptDictationBaseline)
    /// A gesture's composer session began; `revisit` is the look at the field when it is the field the last
    /// kept dictation went to.
    func sessionBegan(revisit: FieldRevisitSample?)
    /// A dictation was delivered and left in the field.
    func dictationKept(_ record: DictationRecord, baseline: KeptDictationBaseline)
}

public extension DictationEditObserving {
    func configureTeacherRecheck(recognize: @escaping TeacherLearningRuntime.Recognizer, cancel: @escaping @Sendable () async -> Void) {}
    func cancelTeacherRecheck() {}
    func pauseTeacherRecheck() {}
    func resumeTeacherRecheck() {}
    func waitForTeacherCancellation() async {}
    func teacherDictationDelivered(roundID: UUID) {}
    func teacherFinalObserved(text: String, roundID: UUID, source: EnhancementComparison.Source) {}
    func teacherFinalReceiver() -> (@MainActor @Sendable (UUID, String) -> Void)? { nil }
    func enhancementReceiver() -> (@MainActor @Sendable (EnhancementComparison) -> Void)? { nil }
    func doubaoEnhancementCompared(_ comparison: EnhancementComparison, baseline: KeptDictationBaseline) {}
}
