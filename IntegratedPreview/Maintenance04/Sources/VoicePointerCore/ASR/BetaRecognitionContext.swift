import Foundation

/// The recognition context a local worker accepts with a request: one line of text (the personal lexicon's
/// hot words), checked here the way the worker checks it, so a request the worker would refuse is never sent.
internal struct BetaRecognitionContext: Sendable, Equatable {
    let text: String

    static let maximumBytes = 1024

    /// Only the Qwen profiles take a context.
    static func supports(profileID: String) -> Bool {
        ["qwen06-rolling", "qwen17-rolling", "qwen06-incremental"].contains(profileID)
    }

    init(text: String) throws {
        guard text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.utf8.count <= Self.maximumBytes,
              !text.unicodeScalars.contains(where: { scalar in
                  scalar.value == 0x7F || (scalar.value < 0x20 && scalar != "\n" && scalar != "\t")
              })
        else { throw BetaRecognitionContextError.invalid }
        self.text = text
    }
}

internal enum BetaRecognitionContextError: Error {
    case invalid
}
