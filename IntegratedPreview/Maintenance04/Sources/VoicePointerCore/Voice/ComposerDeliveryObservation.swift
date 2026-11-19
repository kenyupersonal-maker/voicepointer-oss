import Foundation

/// Tracks consecutive exact post-paste observations of the composer text.
/// Pure bookkeeping only: no AX, clipboard, keyboard, or text content beyond
/// the expected string needed for exact comparison is involved.
@_spi(Testing)
public struct ComposerDeliveryObservation: Sendable, Equatable {
    public let expected: String
    /// A second exact document that also proves delivery: an empty Chromium composer whose
    /// phantom line break is replaced by the paste (see `ComposerTextNormalizer.isPhantomEmpty`).
    /// Nil for ordinary fields.
    public let alternate: String?
    public private(set) var consecutiveExactCount: Int
    /// True when the current run of exact observations matched `alternate`.
    public private(set) var matchedAlternate: Bool
    public private(set) var matchedInsertionLocation: Int?
    private let original: String?
    private let inserted: String?
    private let expectedInsertionLocation: Int
    private var lastAccepted: String?

    public init(expected: String, alternate: String? = nil, original: String? = nil,
                inserted: String? = nil, expectedInsertionLocation: Int = 0) {
        self.expected = expected
        self.alternate = alternate == expected ? nil : alternate
        self.consecutiveExactCount = 0
        self.matchedAlternate = false
        self.original = original; self.inserted = inserted
        self.expectedInsertionLocation = expectedInsertionLocation
        self.matchedInsertionLocation = nil; self.lastAccepted = nil
    }

    /// Records one observation. Returns true only when this observation is
    /// the second (or later) consecutive observation exactly equal to the
    /// same accepted document (`expected`, or `alternate` when given). Nil,
    /// partial, punctuation-, or whitespace-different observations reset the
    /// count, and a primary and an alternate observation never pair up. No
    /// fuzzy, trimmed, or substring matching is performed.
    public mutating func observe(_ observed: String?) -> Bool {
        guard let observed else {
            consecutiveExactCount = 0
            lastAccepted = nil; matchedInsertionLocation = nil
            return false
        }
        let isPrimary = observed == expected
        let isAlternate = !isPrimary && alternate.map { observed == $0 } == true
        let location = !isPrimary && !isAlternate ? Self.exactInsertionLocation(
            observed: observed, original: original, inserted: inserted, preferred: expectedInsertionLocation) : nil
        guard isPrimary || isAlternate || location != nil else {
            consecutiveExactCount = 0
            lastAccepted = nil; matchedInsertionLocation = nil
            return false
        }
        if let lastAccepted, !observed.utf16.elementsEqual(lastAccepted.utf16) {
            consecutiveExactCount = 0
        }
        matchedAlternate = isAlternate
        matchedInsertionLocation = location; lastAccepted = observed
        consecutiveExactCount += 1
        return consecutiveExactCount >= 2
    }
    /// Exact UTF-16 deletion proof, not substring or length-only confirmation.
    /// Prefix/suffix bounds keep the search linear even for repetitive documents.
    public static func exactInsertionLocation(observed: String, original: String?, inserted: String?, preferred: Int) -> Int? {
        guard let original, let inserted, !inserted.isEmpty else { return nil }
        let old = Array(original.utf16), current = Array(observed.utf16), addition = Array(inserted.utf16)
        guard current.count == old.count + addition.count else { return nil }
        var prefix = 0, suffix = 0
        while prefix < old.count && current[prefix] == old[prefix] { prefix += 1 }
        while suffix < old.count && current[current.count - 1 - suffix] == old[old.count - 1 - suffix] { suffix += 1 }
        let lower = old.count - suffix, upper = prefix
        guard lower <= upper else { return nil }
        let preferred = min(upper, max(lower, preferred))
        if current[preferred..<(preferred + addition.count)].elementsEqual(addition) { return preferred }
        let match = (observed as NSString).range(of: inserted, options: .literal,
            range: NSRange(location: lower, length: upper - lower + addition.count))
        return match.location != NSNotFound && match.location <= upper ? match.location : nil
    }

    public static func mismatchCounts(expected: String, observed: String, insertionLocation: Int) -> String {
        let lhs = Array(expected.utf16), rhs = Array(observed.utf16)
        var counts = [Int](repeating: 0, count: 8), first: Int?
        func category(_ code: UInt16) -> Int {
            switch code {
            case 0xA, 0xD: return 1
            case 0xA0: return 2
            case 0x9, 0x20: return 0
            case 0xD800...0xDFFF: return 6
            case 0x3400...0x9FFF: return 4
            case 0x41...0x5A, 0x61...0x7A: return 5
            default:
                if let scalar = UnicodeScalar(code), CharacterSet.punctuationCharacters.contains(scalar) { return 3 }
                return 7
            }
        }
        for index in 0..<max(lhs.count, rhs.count) {
            if index < lhs.count && index < rhs.count && lhs[index] == rhs[index] { continue }
            if first == nil { first = index }
            if index < lhs.count { counts[category(lhs[index])] += 1 }
            if index < rhs.count { counts[category(rhs[index])] += 1 }
        }
        return "distance=\((first ?? insertionLocation) - insertionLocation) space=\(counts[0]) newline=\(counts[1]) nbsp=\(counts[2]) punctuation=\(counts[3]) han=\(counts[4]) latin=\(counts[5]) surrogate=\(counts[6]) other=\(counts[7])"
    }
}
