import Foundation

public enum AliAssemblyError: Error {
    case invalidState
    case invalidSentence
    case capacityExceeded
}

public struct AliTranscriptAssembler: Sendable {
    public init() {}

    public private(set) var currentText = ""
    public private(set) var isFinished = false
    private var started = false
    private var records: [Int: AliSentence] = [:]

    public var sentences: [AliSentence] {
        records.values.sorted { $0.id < $1.id }
    }

    public mutating func accept(_ event: AliWireEvent) throws -> String? {
        switch event {
        case .started:
            guard !started && !isFinished else { throw AliAssemblyError.invalidState }
            started = true
            return nil
        case .heartbeat:
            guard started && !isFinished else { throw AliAssemblyError.invalidState }
            return nil
        case .sentence(let sentence):
            guard started && !isFinished else { throw AliAssemblyError.invalidState }
            var next = self
            let previousText = next.currentText
            try next.apply(sentence)
            self = next
            return next.currentText == previousText ? nil : next.currentText
        case .finished:
            guard started && !isFinished else { throw AliAssemblyError.invalidState }
            for record in records.values where !record.text.isEmpty && !record.isFinal {
                throw AliAssemblyError.invalidSentence
            }
            isFinished = true
            return currentText
        }
    }

    private mutating func apply(_ incoming: AliSentence) throws {
        let sentence = try normalized(incoming)
        guard (1...1000).contains(sentence.id),
              sentence.words.count <= 20000
        else { throw AliAssemblyError.invalidSentence }

        if let existing = records[sentence.id], existing.isFinal {
            // A finalized sentence may only receive updated alignment metadata.
            guard sentence.isFinal, sentence.text == existing.text else {
                throw AliAssemblyError.invalidSentence
            }
        } else if records[sentence.id] == nil {
            let nextId = (records.keys.max() ?? 0) + 1
            guard sentence.id == nextId else { throw AliAssemblyError.invalidSentence }
            if let prior = records[sentence.id - 1],
               !prior.text.isEmpty, !prior.isFinal {
                throw AliAssemblyError.invalidSentence
            }
        }

        var candidate = records
        candidate[sentence.id] = sentence
        let joined = candidate.values
            .sorted { $0.id < $1.id }
            .reduce(into: "") { $0 += $1.text }
        guard joined.count <= 50000,
              joined.utf8.count <= 1_048_576,
              candidate.values.reduce(0, { $0 + $1.words.count }) <= 50000
        else { throw AliAssemblyError.capacityExceeded }

        records = candidate
        currentText = joined
    }

    // Paraformer identifies each revision by begin_time rather than sentence_id.
    private func normalized(_ sentence: AliSentence) throws -> AliSentence {
        guard sentence.id == 0 else { return sentence }
        guard let begin = sentence.beginMilliseconds,
              begin.isFinite, (0...360_000).contains(begin) else {
            throw AliAssemblyError.invalidSentence
        }
        let id: Int
        if let existing = records.values.first(where: { $0.beginMilliseconds == begin }) {
            id = existing.id
        } else if let latest = records.values.max(by: { $0.id < $1.id }) {
            guard latest.isFinal, let previousBegin = latest.beginMilliseconds, begin > previousBegin else {
                throw AliAssemblyError.invalidSentence
            }
            id = latest.id + 1
        } else {
            id = 1
        }
        return AliSentence(id: id, text: sentence.text, isFinal: sentence.isFinal,
                           beginMilliseconds: begin, endMilliseconds: sentence.endMilliseconds, words: sentence.words)
    }
}
