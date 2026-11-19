//
//  InlineDraftTransaction.swift
//  VoicePointerCore
//
//  Pure logic that revises the user's own in-progress draft at the current
//  input position without ever touching the rest of the document. No AX,
//  pasteboard, keyboard, or network access: a native bridge consumes the
//  emitted plans, applies them, and handles timeout / target loss by calling
//  abandon(). Draft content is never logged.
//

import Foundation

public struct InlineDraftTransaction: Sendable {

    /// A single proposed revision. The bridge may only confirm when the
    /// observed document and selection exactly match the expected values.
    public struct Plan: Sendable, Equatable {
        public let id: UUID
        public let replaceRange: NSRange
        public let text: String
        public let expectedDocument: String
        public let expectedSelection: NSRange
    }

    public enum Decision: Sendable, Equatable {
        case replace(Plan)
        case unchanged
        case stale
        case busy
        case abandoned
    }

    public enum Reconciliation: Sendable, Equatable {
        case applied, notApplied, unknown
    }

    public private(set) var isAbandoned: Bool = false
    public private(set) var hasWritten: Bool = false
    public private(set) var lastDraft: String = ""
    /// The drafts written before the last one, oldest first, without repeats (at most 24): what Undo in the
    /// field may step back to.
    public private(set) var earlierDrafts: [String] = []
    public private(set) var lastDocument: String
    public private(set) var expectedSelection: NSRange

    /// Where the confirmed draft sits in `lastDocument` (UTF-16 units); nil until something was written.
    public var writtenRange: NSRange? {
        hasWritten ? NSRange(location: ownedRange.location, length: lastDraft.utf16.count) : nil
    }

    private let originalSelection: NSRange
    private var ownedRange: NSRange
    private var lastAcceptedSequence: UInt64? = nil
    private var pending: Pending?

    public init?(originalText: String, selection: NSRange) {
        guard Self.isValid(selection, inUTF16Of: originalText) else { return nil }
        lastDocument = originalText
        expectedSelection = selection
        originalSelection = selection
        ownedRange = selection
    }

    public mutating func prepare(
        text: String,
        sequence: UInt64,
        currentDocument: String,
        currentSelection: NSRange,
        replacingOnlyChanges: Bool = false
    ) -> Decision {
        if isAbandoned { return .abandoned }
        if pending != nil { return .busy }
        if let lastAcceptedSequence, sequence <= lastAcceptedSequence { return .stale }
        if !Self.exact(currentDocument, lastDocument) || currentSelection != expectedSelection {
            abandon()
            return .abandoned
        }
        if text.utf16.count > Self.maximumDraftUTF16Length
            || Self.containsForbiddenControlCharacters(text) {
            abandon()
            return .abandoned
        }
        if (!hasWritten && text.isEmpty) || (hasWritten && Self.exact(text, lastDraft)) {
            lastAcceptedSequence = sequence
            return .unchanged
        }
        // First revision replaces the original selection; later revisions
        // replace exactly the span the previous confirmed draft occupies.
        let fullRange = hasWritten
            ? NSRange(location: ownedRange.location, length: lastDraft.utf16.count)
            : originalSelection
        guard let expectedDocument = Self.replacing(lastDocument, range: fullRange, with: text) else {
            abandon()
            return .abandoned
        }
        let changed = hasWritten && replacingOnlyChanges
            ? Self.changedSpan(previous: lastDraft, next: text, location: fullRange.location)
            : (range: fullRange, text: text)
        let expectedSelection = NSRange(location: fullRange.location + text.utf16.count, length: 0)
        let plan = Plan(
            id: UUID(),
            replaceRange: changed.range,
            text: changed.text,
            expectedDocument: expectedDocument,
            expectedSelection: expectedSelection)
        pending = Pending(
            id: plan.id,
            sequence: sequence,
            draft: text,
            newOwnedRange: NSRange(location: fullRange.location, length: text.utf16.count),
            expectedDocument: expectedDocument,
            expectedSelection: expectedSelection)
        return .replace(plan)
    }

    public mutating func confirm(
        planID: UUID,
        observedDocument: String,
        observedSelection: NSRange
    ) -> Bool {
        // An unmatched id never disturbs a live pending plan.
        guard let p = pending, p.id == planID else { return false }
        pending = nil
        if !Self.exact(observedDocument, p.expectedDocument) || observedSelection != p.expectedSelection {
            isAbandoned = true
            return false
        }
        lastDocument = p.expectedDocument
        noteEarlierDraft(lastDraft, replacedBy: p.draft)
        lastDraft = p.draft
        expectedSelection = p.expectedSelection
        ownedRange = p.newOwnedRange
        lastAcceptedSequence = p.sequence
        hasWritten = true
        return true
    }

    /// The first plan wrote its draft in front of the original text, and the field dropped that original
    /// text by itself (a composer's empty-state hint goes away when text arrives), so what is there is
    /// exactly the draft. Accepts that document as the confirmed one; the draft then owns the span from
    /// position 0 and later revisions replace it as usual. Only for the pending first write into a field
    /// whose caret stood at 0 with nothing selected. Anything else leaves the transaction untouched, so the
    /// caller can still reconcile or abandon it.
    public mutating func acceptVanishedOriginal(
        planID: UUID,
        observedDocument: String,
        observedSelection: NSRange
    ) -> Bool {
        guard let p = pending, p.id == planID, !hasWritten, !isAbandoned,
              originalSelection.location == 0, originalSelection.length == 0,
              Self.exact(observedDocument, p.draft),
              observedSelection == p.expectedSelection else { return false }
        pending = nil
        lastDocument = p.draft
        lastDraft = p.draft
        expectedSelection = p.expectedSelection
        ownedRange = p.newOwnedRange
        lastAcceptedSequence = p.sequence
        hasWritten = true
        return true
    }

    /// A timed-out AX/paste call may have changed the editor. Resolve it from
    /// exact document and caret evidence before any final write or Send.
    public mutating func reconcile(document: String, selection: NSRange) -> Reconciliation {
        guard let p = pending else { return .unknown }
        if Self.exact(document, p.expectedDocument), selection == p.expectedSelection {
            return confirm(planID: p.id, observedDocument: document, observedSelection: selection)
                ? .applied : .unknown
        }
        if Self.exact(document, lastDocument), selection == expectedSelection {
            pending = nil
            return .notApplied
        }
        abandon()
        return .unknown
    }

    /// Only valid when a write was rejected before it was submitted.
    public mutating func discardUnsubmitted(planID: UUID) {
        if pending?.id == planID { pending = nil }
    }

    /// Permanently gives up; the last confirmed draft is preserved.
    public mutating func abandon() {
        pending = nil
        isAbandoned = true
    }

    // MARK: - Internals

    private static let maximumEarlierDrafts = 24

    private mutating func noteEarlierDraft(_ previous: String, replacedBy next: String) {
        guard hasWritten, !previous.isEmpty, previous != next, !earlierDrafts.contains(previous) else { return }
        earlierDrafts.append(previous)
        if earlierDrafts.count > Self.maximumEarlierDrafts { earlierDrafts.removeFirst() }
    }

    private struct Pending: Sendable {
        let id: UUID
        let sequence: UInt64
        let draft: String
        let newOwnedRange: NSRange
        let expectedDocument: String
        let expectedSelection: NSRange
    }

    private static let maximumDraftUTF16Length = 50_000

    /// UTF16-exact equality. Swift `==` canonicalizes and can wrongly accept
    /// strings whose UTF16 lengths differ; document identity requires exact
    /// UTF16 unit equality.
    private static func exact(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    static func changedSpan(previous: String, next: String, location: Int) -> (range: NSRange, text: String) {
        let old = Array(previous.utf16), new = Array(next.utf16)
        let edges = commonEdges(old, new, repairBoundaries: true)
        return (NSRange(location: location + edges.prefix, length: old.count - edges.prefix - edges.suffix),
                String(decoding: new[edges.prefix..<(new.count - edges.suffix)], as: UTF16.self))
    }

    /// Non-overlapping edges. Diagnostic lengths retain raw unit boundaries; changed spans repair them.
    static func commonEdges(_ old: [UInt16], _ new: [UInt16], repairBoundaries: Bool = false,
                            limit: Int = .max) -> (prefix: Int, suffix: Int) {
        let bound = min(old.count, new.count, limit)
        var prefix = 0
        while prefix < bound, old[prefix] == new[prefix] { prefix += 1 }
        if repairBoundaries {
            while prefix > 0, !isBoundary(old, at: prefix) || !isBoundary(new, at: prefix) { prefix -= 1 }
        }
        var suffix = 0
        while suffix < bound - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        if repairBoundaries {
            while suffix > 0, !isBoundary(old, at: old.count - suffix) || !isBoundary(new, at: new.count - suffix) { suffix -= 1 }
        }
        return (prefix, suffix)
    }

    /// Rejects C0 control characters other than TAB (0x09) and LF (0x0A);
    /// DEL (0x7F) is also rejected. Draft text is never logged.
    private static func containsForbiddenControlCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if (scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A)
                || scalar.value == 0x7F {
                return true
            }
        }
        return false
    }

    private static func isValid(_ range: NSRange, inUTF16Of text: String) -> Bool {
        if range.location == NSNotFound || range.length == NSNotFound { return false }
        guard range.location >= 0, range.length >= 0 else { return false }
        let units = Array(text.utf16)
        guard range.location <= units.count,
              range.length <= units.count - range.location else { return false }
        return Self.isBoundary(units, at: range.location)
            && Self.isBoundary(units, at: range.location + range.length)
    }

    private static func replacing(
        _ source: String,
        range: NSRange,
        with replacement: String
    ) -> String? {
        let units = Array(source.utf16)
        guard range.location >= 0, range.length >= 0,
              range.location <= units.count,
              range.length <= units.count - range.location,
              Self.isBoundary(units, at: range.location),
              Self.isBoundary(units, at: range.location + range.length) else { return nil }
        let head = String(decoding: units[..<range.location], as: UTF16.self)
        let tail = String(decoding: units[(range.location + range.length)...], as: UTF16.self)
        return head + replacement + tail
    }

    /// True when `offset` does not split a UTF-16 surrogate pair.
    private static func isBoundary(_ units: [UInt16], at offset: Int) -> Bool {
        if offset <= 0 { return offset == 0 }
        if offset >= units.count { return offset == units.count }
        let previous = units[offset - 1]
        let next = units[offset]
        let previousIsHigh = (0xD800...0xDBFF).contains(previous)
        let nextIsLow = (0xDC00...0xDFFF).contains(next)
        return !(previousIsHigh && nextIsLow)
    }
}
