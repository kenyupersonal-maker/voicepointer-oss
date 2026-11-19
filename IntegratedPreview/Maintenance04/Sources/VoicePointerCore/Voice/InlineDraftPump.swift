import Foundation

/// One writer per session. Keeps only the newest partial while AX is busy.
@MainActor
public final class InlineDraftPump: Sendable {
    private let deliverer: any InlineTranscriptDelivering
    private let session: ComposerActionSession
    private let speechSessionID: UUID
    private var pending: SpeechInputEvent?
    private var task: Task<Void, Never>?
    private var finished = false
    private var finalOnly = false
    private var lastSequence: UInt64?
    private var lastWriteAt: TimeInterval?
    private var lastDeliveredText: String?
    private var delayTask: Task<Void, any Error>?
    private let minimumInterval: TimeInterval

    public var isUpdating: Bool { task != nil }

    public init(deliverer: any InlineTranscriptDelivering, session: ComposerActionSession, speechSessionID: UUID,
                minimumIntervalMilliseconds: Int = 300) {
        self.deliverer = deliverer
        self.session = session
        self.speechSessionID = speechSessionID
        minimumInterval = Double(max(0, minimumIntervalMilliseconds)) / 1000
    }

    public func enqueue(_ event: SpeechInputEvent) {
        guard !finished, !finalOnly, !session.isCancelled,
              event.sessionID == speechSessionID, event.kind == .partial,
              let text = event.text, InlineWritePolicy.acceptsPartial(text), event.sequence != UInt64.max else { return }
        if let lastSequence, event.sequence <= lastSequence { return }
        lastSequence = event.sequence
        pending = event
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { delayTask?.cancel(); delayTask = nil; task = nil }
        while !finished, !finalOnly, !Task.isCancelled, !session.isCancelled,
              pending != nil {
            if let lastWriteAt {
                let delay = minimumInterval - (ProcessInfo.processInfo.systemUptime - lastWriteAt)
                if delay > 0 {
                    let sleeper = Task { try await Task.sleep(for: .seconds(delay)) }
                    delayTask = sleeper
                    do { try await sleeper.value } catch { break }
                    delayTask = nil
                }
            }
            guard !finished, !finalOnly, !Task.isCancelled, !session.isCancelled, let event = pending else { break }
            pending = nil
            let text = event.text ?? ""
            if let lastDeliveredText, text.utf16.elementsEqual(lastDeliveredText.utf16) { continue }
            let outcome = await deliverer.updateDraft(
                text: text, sequence: event.sequence, session: session)
            lastWriteAt = ProcessInfo.processInfo.systemUptime
            switch outcome {
            case .updated, .unchanged:
                lastDeliveredText = text
                continue
            case .pending:
                continue // The next newest partial must prove its owned range before any write.
            case .unsupported, .abandoned, .unconfirmed:
                finalOnly = true
                pending = nil
            }
        }
    }

    public func finish() async {
        finished = true
        pending = nil
        delayTask?.cancel()
        if let task { await task.value }
    }

    public func cancel() {
        session.cancelDraftUpdates()
        finished = true
        pending = nil
        delayTask?.cancel()
        task?.cancel()
    }
}
