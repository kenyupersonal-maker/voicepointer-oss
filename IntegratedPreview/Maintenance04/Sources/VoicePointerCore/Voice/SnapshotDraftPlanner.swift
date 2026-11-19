import Foundation

/// Sentence-owned Chromium paste ranges. AXValue and AXSelectedTextRange have different
/// coordinate systems in rich editors. Common unchanged text bounds the value middle;
/// the frozen AX insertion point and submitted draft length bound the editor selection.
public struct SnapshotDraftPlanner: Sendable {
    public struct Location: Sendable, Equatable {
        public let range: NSRange
        public let valueRange: NSRange
        public let draft: String
        public let caret: NSRange
    }
    public struct Plan: Sendable {
        public let range: NSRange
        public let replacement: String
        public let draft: String
        public let insertionEnd: Int
        public let selectedText: String?
        public var initialInsertion = false
    }
    public enum FinalDecision: Sendable, Equatable {
        case owned(Location), original(NSRange), clipboard
    }
    public let original: String
    public let selection: NSRange
    public private(set) var submitted: [String] = []
    public private(set) var lastSequence: UInt64?
    private let originalUnits: [UInt16]
    private let originalEnd: Int
    private let selectedOriginal: String?
    private var locatedValueStart: Int?
    private static let maximumDocument = 200_000
    private static let maximumDraft = 50_000
    private static let maximumVersions = 24
    private static let maximumTail = 64

    public init?(original: String, selection: NSRange, selectedOriginal: String? = nil) {
        let units = Array(original.utf16)
        guard units.count <= Self.maximumDocument, Self.validAX(selection),
              selection.location <= units.count + Self.maximumTail,
              let end = Self.contentEnd(units, minimum: 0) else { return nil }
        self.original = original; self.selection = selection
        originalUnits = units; originalEnd = end
        self.selectedOriginal = selectedOriginal
    }

    public static func validDraft(_ text: String) -> Bool {
        text.utf16.count <= maximumDraft && !text.unicodeScalars.contains {
            ($0.value < 0x20 && $0.value != 9 && $0.value != 10) || $0.value == 0x7f
        }
    }

    public static func equal(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }
    public static func equivalentDraft(_ lhs: String, _ rhs: String) -> Bool {
        equal(lhs.trimmingCharacters(in: .whitespacesAndNewlines), rhs.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Records only after a content event was accepted. A rejected attempt grants no ownership.
    public mutating func noteSubmitted(_ text: String, sequence: UInt64) {
        guard Self.validDraft(text) else { return }
        submitted.removeAll { Self.equal($0, text) }
        submitted.append(text)
        if submitted.count > Self.maximumVersions { submitted.removeFirst() }
        lastSequence = sequence
    }

    public mutating func noteLocated(_ location: Location) { locatedValueStart = location.valueRange.location }

    public func locate(document: String, caret: NSRange, requireCaret: Bool = true) -> Location? {
        let units = Array(document.utf16)
        guard units.count <= Self.maximumDocument, Self.validAX(caret), caret.length == 0,
              let end = Self.contentEnd(units, minimum: 0) else { return nil }
        let removed: [UInt16]
        if selection.length == 0 { removed = [] }
        else {
            // The AX selected-text witness, not AXValue[AXRange], identifies the replaced original.
            guard let selectedOriginal, selectedOriginal.utf16.count == selection.length else { return nil }
            removed = Array(selectedOriginal.utf16)
        }
        var prefix = 0
        while prefix < min(originalEnd, end), originalUnits[prefix] == units[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(originalEnd, end), originalUnits[originalEnd - suffix - 1] == units[end - suffix - 1] { suffix += 1 }
        let middleLength = end - originalEnd + removed.count
        guard middleLength >= 0, middleLength <= Self.maximumDraft + Self.maximumTail else { return nil }
        var found: Location?
        var inspected = 0
        for version in submitted.reversed() {
            let axRange = NSRange(location: selection.location, length: version.utf16.count)
            guard Self.validAX(axRange) else { continue }
            if requireCaret {
                guard caret.location >= NSMaxRange(axRange),
                      caret.location - NSMaxRange(axRange) <= units.count - end else { continue }
            }
            // Restoring the selected original (empty for insertion) proves cancellation.
            // Reuse the previously located value point, never search repeated original text.
            if Self.equal(version, selectedOriginal ?? ""), middleLength == removed.count, let point = locatedValueStart,
               point <= units.count, removed.count <= units.count - point,
               originalUnits.prefix(originalEnd).elementsEqual(units.prefix(end)) {
                return Location(range: axRange, valueRange: NSRange(location: point, length: removed.count), draft: version, caret: caret)
            }
            let lower = max(0, originalEnd - removed.count - suffix)
            let upper = min(prefix, originalEnd - removed.count, end - middleLength)
            guard lower <= upper else { continue }
            guard upper - lower <= Self.maximumTail else { return nil }
            for start in lower...upper {
                inspected += 1
                guard inspected <= Self.maximumVersions * (Self.maximumTail + 1) else { return nil }
                guard Self.boundary(originalUnits, start), Self.boundary(units, start),
                      originalUnits[start..<(start + removed.count)].elementsEqual(removed) else { continue }
                let range = NSRange(location: start, length: middleLength)
                guard Self.valid(range, in: units) else { continue }
                let middle = String(decoding: units[start..<(start + middleLength)], as: UTF16.self)
                guard Self.equivalentDraft(middle, version) else { continue }
                let valueRange = Self.trimmedRange(range, units: units)
                let location = Location(range: axRange, valueRange: valueRange, draft: version, caret: caret)
                if let found, found.valueRange != valueRange || found.range != axRange { return nil } // Repeated text has no unique owned middle.
                if found == nil { found = location }
            }
        }
        return found
    }

    /// Live updates may start on the unchanged original only before a content submission.
    public func plan(text: String, document: String, caret: NSRange, allowOriginal: Bool = false) -> Plan? {
        guard Self.validDraft(text) else { return nil }
        if let own = locate(document: document, caret: caret) {
            let changed = InlineDraftTransaction.changedSpan(previous: own.draft, next: text, location: own.range.location)
            let previousRange = NSRange(location: changed.range.location - own.range.location, length: changed.range.length)
            return Plan(range: changed.range, replacement: changed.text, draft: text,
                        insertionEnd: changed.range.location + changed.text.utf16.count,
                        selectedText: (own.draft as NSString).substring(with: previousRange))
        }
        guard (submitted.isEmpty || allowOriginal),
              Self.equal(document, original), caret == selection else { return nil }
        return Plan(range: selection, replacement: text, draft: text, insertionEnd: selection.location + text.utf16.count,
                    selectedText: selectedOriginal, initialInsertion: true)
    }
    public func permits(_ range: NSRange, document: String, caret: NSRange, initial: Bool) -> Bool {
        guard Self.validAX(range) else { return false }
        if let own = locate(document: document, caret: caret) {
            return range.location >= own.range.location && range.location <= NSMaxRange(own.range) &&
                range.length <= NSMaxRange(own.range) - range.location
        }
        return initial && range == selection && caret == selection && Self.equal(document, original)
    }
    public func comparisonLengths(_ document: String) -> (original: Int, current: Int, prefix: Int, suffix: Int) {
        let current = Array(document.utf16)
        let edges = InlineDraftTransaction.commonEdges(originalUnits, current, limit: Self.maximumDocument)
        return (originalUnits.count, current.count, edges.prefix, edges.suffix)
    }

    /// `originalConfirmedTwice` is supplied by the serial bridge only after two guarded reads.
    /// This authorizes one final replacement, never a loop following an unconfirmed final event.
    public func finalDecision(document: String, caret: NSRange, originalConfirmedTwice: Bool) -> FinalDecision {
        if let own = locate(document: document, caret: caret) { return .owned(own) }
        if originalConfirmedTwice, Self.equal(document, original), caret == selection { return .original(selection) }
        return .clipboard
    }

    private static func structural(_ unit: UInt16) -> Bool {
        // Newlines/paragraph separators, zero-width editor markers and object replacement.
        // Ordinary spaces, tabs and every visible character remain part of the anchored document.
        [0x000a, 0x000d, 0x2028, 0x2029, 0x200b, 0xfeff, 0xfffc].contains(unit)
    }
    private static func trimmedRange(_ range: NSRange, units: [UInt16]) -> NSRange {
        func whitespace(_ unit: UInt16) -> Bool {
            UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        var first = range.location, end = NSMaxRange(range)
        while first < end, whitespace(units[first]) { first += 1 }
        while end > first, whitespace(units[end - 1]) { end -= 1 }
        return NSRange(location: first, length: end - first)
    }
    private static func contentEnd(_ units: [UInt16], minimum: Int) -> Int? {
        guard minimum <= units.count else { return nil }
        var end = units.count
        while end > minimum, structural(units[end - 1]) { end -= 1 }
        return units.count - end <= maximumTail ? end : nil
    }
    private static func boundary(_ units: [UInt16], _ offset: Int) -> Bool {
        offset == 0 || offset == units.count || !(0xd800...0xdbff).contains(units[offset - 1]) || !(0xdc00...0xdfff).contains(units[offset])
    }
    private static func valid(_ range: NSRange, in units: [UInt16]) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= units.count &&
            range.length <= units.count - range.location && boundary(units, range.location) && boundary(units, NSMaxRange(range))
    }
    private static func validAX(_ range: NSRange) -> Bool {
        let bound = maximumDocument + maximumDraft + maximumTail
        return range.location >= 0 && range.length >= 0 && range.location <= bound && range.length <= bound - range.location
    }
}
