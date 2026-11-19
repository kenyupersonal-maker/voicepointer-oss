import Foundation

/// Upload providers share the existing file worker; their late result cannot revise delivered text.
@_spi(Testing) public enum HybridUploadPolicy {
    public enum Use: String, Sendable { case correct, learnOnly, failed }
    public static func shouldUpload(localText: String?) -> Bool {
        !(localText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    public static func use(localFinalMs: Int64, resultMs: Int64) -> Use {
        resultMs <= localFinalMs || resultMs - localFinalMs <= 300 ? .correct : .learnOnly
    }
    /// Convert only when the local reference already uses simplified characters. No general rewrite.
    public static func text(_ cloud: String, matching local: String) -> String {
        let hans = StringTransform("Hant-Hans")
        guard let localHans = local.applyingTransform(hans, reverse: false), localHans == local,
              let localHant = local.applyingTransform(StringTransform("Hans-Hant"), reverse: false), localHant != local
        else { return cloud }
        return cloud.applyingTransform(hans, reverse: false) ?? cloud
    }
}

/// One bounded upload may finish for learning after delivery. New speech or withdrawn consent cancels it.
@MainActor enum HybridUploadWork {
    static private var cancelAction: (() -> Void)?
    static private var identity: UUID?
    static func retain(id: UUID, cancel: @escaping () -> Void) {
        cancelOutstanding(); identity = id; cancelAction = cancel
    }
    static func finished(id: UUID) {
        guard identity == id else { return }; cancelAction = nil; identity = nil
    }
    static func cancelOutstanding() {
        let action = cancelAction; cancelAction = nil; identity = nil; action?()
    }
}

extension GroqSpeechBackend: CloudUplinkReporting {
    var uplinkSentMilliseconds: Int64 { 0 } // Upload mode never uses the streaming backlog gate.
}
