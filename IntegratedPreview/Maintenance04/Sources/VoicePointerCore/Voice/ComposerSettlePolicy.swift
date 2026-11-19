import Foundation

/// Pure settle decision shared by the composer and offline tests. A missing
/// AX value never counts as a stable observation.
@_spi(Testing)
public struct ComposerSettlePolicy: Sendable, Equatable {
    public let minimumSample: Int
    public private(set) var maximumSamples: Int
    public private(set) var isFinished = false
    public private(set) var usedExtraQuietFallback = false
    private let extendChangingSend: Bool
    private let requiresFirstTextChange: Bool
    private let initialText: String?
    public private(set) var firstTextChangeSeen = false
    private let minimumMilliseconds: Int
    private var ordinaryDeadlineMilliseconds: Int
    private var requiredStableSamples = 6
    private var previousValue: String?
    private var stableSamples = 0
    private var stableSinceMilliseconds = 0
    private var previousMilliseconds = -1
    private var observedReadableChange = false
    private var extended = false

    public init(minimumMilliseconds: Int, extendChangingSend: Bool = false,
                requiresFirstTextChange: Bool = false, initialText: String? = nil) {
        self.minimumMilliseconds = max(0, minimumMilliseconds)
        self.extendChangingSend = extendChangingSend
        self.requiresFirstTextChange = requiresFirstTextChange
        self.initialText = initialText
        minimumSample = max(0, minimumMilliseconds / 50 - 1)
        // Keep a bounded 650ms observation tail: send uses 1000ms minimum
        // and therefore has a 1600ms total settle ceiling.
        ordinaryDeadlineMilliseconds = (minimumSample + 13) * 50
        maximumSamples = extendChangingSend ? 80 : minimumSample + 13
    }

    public mutating func extendQuietWindow() {
        requiredStableSamples = 15 // 750 ms; the 1000 ms floor is unchanged.
        ordinaryDeadlineMilliseconds = max(ordinaryDeadlineMilliseconds, 2_200)
        maximumSamples = max(maximumSamples, 44)
    }

    /// Live sends supply monotonic elapsed time from the original settle start.
    /// The nominal 50ms clock is only the compatibility path for pure fixtures.
    public mutating func observe(sample: Int, value: String?, elapsedMilliseconds: Int? = nil) -> Bool {
        guard !isFinished else { return false }
        let elapsed = elapsedMilliseconds ?? (sample + 1) * 50
        guard elapsed >= 0, elapsed >= previousMilliseconds else {
            isFinished = true
            return false
        }
        previousMilliseconds = elapsed
        if value != nil, value == previousValue {
            stableSamples += 1
        } else {
            if value != nil, previousValue != nil {
                observedReadableChange = true
            } else {
                observedReadableChange = false
            }
            stableSamples = 0
            stableSinceMilliseconds = elapsed
            previousValue = value
        }
        // Doubao: the text that was already in the editor before speech is not a new landing.
        // Do not accept a quiet, unchanged baseline as permission to post Return.
        if requiresFirstTextChange && !firstTextChangeSeen {
            if let value, value != initialText,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstTextChangeSeen = true
            } else {
                if elapsed >= 4_000 { isFinished = true }
                return false
            }
        }
        let ordinaryReady = sample >= minimumSample && value != nil && stableSamples >= requiredStableSamples
        guard extendChangingSend else { return ordinaryReady }
        guard elapsed <= 4_000 else {
            isFinished = true
            return false
        }
        let nonempty = value.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        // Preserve ordinary settling until its genuine deadline. The extended
        // phase needs readable, nonempty text and a continuous 300ms quiet gap.
        if !extended, elapsed < ordinaryDeadlineMilliseconds {
            if ordinaryReady && elapsed >= minimumMilliseconds { isFinished = true; return true }
            return false
        }
        let quietReady = nonempty && elapsed >= minimumMilliseconds && elapsed - stableSinceMilliseconds >= 300
        if quietReady {
            usedExtraQuietFallback = requiredStableSamples > 6 && stableSamples < requiredStableSamples
            isFinished = true
            return true
        }
        // A first readable IME commit after a nil AXValue gap is a genuine landing,
        // although no two readable snapshots existed to mark observedReadableChange.
        guard nonempty, (observedReadableChange || (requiresFirstTextChange && firstTextChangeSeen)),
              elapsed < 4_000 else {
            // Idle, unreadable or baseline-only evidence cannot extend a send.
            isFinished = true
            return false
        }
        extended = true
        return false
    }
}
