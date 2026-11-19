// T8 2026-10-02: Passive Doubao reference + one low-priority local RAM comparison, never cloud/capture/file I/O.
import Foundation

public struct DoubaoLearningReference: Sendable {
    public let baseline: KeptDictationBaseline
    public let observedAt: Date
    public init(baseline: KeptDictationBaseline, observedAt: Date) { self.baseline = baseline; self.observedAt = observedAt }
}

/// Reuses the executor's frozen start snapshot and its target AX reader. No Doubao access belongs here.
public protocol DoubaoLearningReferenceProviding: Sendable {
    func observeDoubaoReference(for session: ComposerActionSession?) async -> DoubaoLearningReference?
}

public struct DoubaoOfflineResult: Sendable {
    public let text: String
    public let confidence: LocalModelConfidence?
    public init(text: String, confidence: LocalModelConfidence?) { self.text = text; self.confidence = confidence }
}

public enum DoubaoLearningDecision: String, Sendable {
    case disabled, cancelled, missingAudio, silent, clipped, unreadable, noDifference, modelUnavailable,
         busy, unknownConfidence, compared, failed
}

/// Exact original selection replacement, with unchanged surrounding text. Ambiguous rewrites fail closed.
public enum DoubaoReferenceDifference {
    public static func span(before: String?, selection: NSRange?, after: String?) -> (location: Int, text: String)? {
        guard let before, let after, let selection, selection.location >= 0, selection.length >= 0,
              before.utf16.count <= EditSpanTracker.maximumDocumentUTF16,
              after.utf16.count <= EditSpanTracker.maximumDocumentUTF16,
              selection.location <= before.utf16.count, selection.length <= before.utf16.count - selection.location else { return nil }
        let old = before as NSString, new = after as NSString
        let prefix = old.substring(to: selection.location), suffix = old.substring(from: NSMaxRange(selection))
        guard after.hasPrefix(prefix), after.hasSuffix(suffix), new.length > prefix.utf16.count + suffix.utf16.count else { return nil }
        let range = NSRange(location: prefix.utf16.count, length: new.length - prefix.utf16.count - suffix.utf16.count)
        guard let swiftRange = Range(range, in: after) else { return nil }
        let text = String(after[swiftRange])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, before != after else { return nil }
        return (range.location, text)
    }
}

@MainActor public final class DoubaoLearningRuntime {
    public typealias Recognizer = @Sendable (DoubaoLearningAudio, VoiceInputSelection) async throws -> DoubaoOfflineResult?
    private let audio: any DoubaoLearningAudioProviding
    private let recognize: Recognizer
    private let cancelRecognition: @Sendable () async -> Void
    private let receive: @MainActor (EnhancementComparison, KeptDictationBaseline) -> Void
    private let trace: @MainActor (String) -> Void
    private var generation: UInt64 = 0
    private var enabled = false
    private var snapshot: VoiceInputSnapshot?
    private var task: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var packet: DoubaoLearningAudio?
    private var deadline: Task<Void, Never>?
    public private(set) var decision: DoubaoLearningDecision = .disabled
    public private(set) var outletCalls = 0
    public private(set) var inferenceCalls = 0
    public var retainedAudioBuffers: Int { packet?.retainedBufferCount ?? 0 }
    public init(audio: any DoubaoLearningAudioProviding, recognize: @escaping Recognizer,
                cancelRecognition: @escaping @Sendable () async -> Void = {},
                trace: @escaping @MainActor (String) -> Void = { _ in },
                receive: @escaping @MainActor (EnhancementComparison, KeptDictationBaseline) -> Void) {
        self.audio = audio; self.recognize = recognize; self.cancelRecognition = cancelRecognition
        self.trace = trace; self.receive = receive
    }
    public func authorize(isDoubao: Bool, learningEnabled: Bool) {
        let next = isDoubao && learningEnabled
        guard next != enabled else { return }
        enabled = next
        cancel()
        if !next { note(.disabled) }
    }
    /// Called before any new foreground session. Old background results and RAM are invalidated synchronously.
    public func cancel() {
        generation &+= 1; snapshot = nil; audio.clear(); packet?.clear(); packet = nil
        let hadTask = task != nil
        task?.cancel(); task = nil
        deadline?.cancel(); deadline = nil
        if hadTask {
            let prior = drain, cancel = cancelRecognition
            drain = Task { await prior?.value; await cancel() }
        }
        note(.cancelled)
    }
    public func waitForCancellation() async { await drain?.value; drain = nil }
    public func begin(_ snapshot: VoiceInputSnapshot) {
        guard enabled, snapshot.selection.mode == .doubao else { return }
        self.snapshot = snapshot; audio.arm()
    }
    /// Seals the already-running meter first. Missing/silent audio never asks AX or a recognizer anything.
    public func finish(reference: @escaping @Sendable () async -> DoubaoLearningReference?) {
        guard enabled, let snapshot, snapshot.selection.mode == .doubao else { return }
        self.snapshot = nil
        outletCalls += 1
        let value: DoubaoLearningAudio
        switch audio.take() {
        case .missing: note(.missingAudio); return
        case .silent: note(.silent); return
        case .clipped: note(.clipped); return
        case .audio(let captured): value = captured
        }
        packet = value
        let epoch = generation, recognize = self.recognize
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.generation == epoch else { return }
            self.cancel()
        }
        task = Task(priority: .utility) { [weak self] in
            guard let self else { value.clear(); return }
            defer { value.clear(); if self.generation == epoch { self.packet = nil; self.task = nil;self.deadline?.cancel();self.deadline=nil } }
            guard !Task.isCancelled, self.enabled, self.generation == epoch else { return }
            let receipt = await reference()
            guard !Task.isCancelled, self.enabled, self.generation == epoch else { return }
            guard let receipt else { self.note(.unreadable); return }
            self.inferenceCalls += 1
            // One RAM-only decode of the same captured segment; no second hotword recheck.
            // The surrounding defer clears the original PCM on success, timeout or cancellation.
            do {
                let result = try await recognize(value, snapshot.selection)
                guard !Task.isCancelled, self.enabled, self.generation == epoch else { return }
                guard let result else { self.note(.modelUnavailable); return }
                // Both texts describe the same captured interval. Inference duration is not timestamp alignment evidence.
                let comparison = EnhancementComparison(roundID: snapshot.sessionID, localText: result.text,
                    referenceText: receipt.baseline.delivered, localAt: receipt.observedAt, referenceAt: receipt.observedAt,
                    localConfidence: result.confidence?.probability, source: .doubao,
                    audio: nil, snapshot: snapshot)
                self.receive(comparison, receipt.baseline); self.note(.compared)
            } catch {
                guard !Task.isCancelled, self.generation == epoch else { return }
                self.note(.failed)
            }
        }
    }
    public func waitForWork() async { await task?.value }
    private func note(_ value: DoubaoLearningDecision) {
        decision = value
        let line = "event=doubao_learning decision=\(value.rawValue) outlets=\(outletCalls) requests=\(inferenceCalls)"
        precondition(Self.isSafeLog(line)); trace(line)
    }
    public static func isSafeLog(_ line: String) -> Bool {
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count == 4, fields[0] == "event=doubao_learning", fields[1].hasPrefix("decision="),
              DoubaoLearningDecision(rawValue: String(fields[1].dropFirst(9))) != nil else { return false }
        return zip(fields.suffix(2), ["outlets=", "requests="]).allSatisfy { field, prefix in
            field.hasPrefix(prefix) && !field.dropFirst(prefix.count).isEmpty
                && field.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}
