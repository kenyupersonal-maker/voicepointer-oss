import AppKit
import Foundation

/// I04D — Clipboard transaction for one editor paste.
///
/// Takes temporary ownership of a pasteboard, places dictation text, and can
/// put the snapshotted original contents back. Synchronization is best-effort
/// via `changeCount` only: external processes can race, so atomicity across
/// apps is not claimed. No keyboard, AX, event, or network access happens here.
@MainActor
@_spi(Testing)
public final class ClipboardTransfer {

    internal enum Error: Swift.Error, Sendable, Equatable {
        case busy              // a lease is already active
        case invalidText       // empty or more than 50,000 UTF-16 units
        case clipboardChanged  // contents changed while snapshotting
        case unavailable       // unreadable data or failed pasteboard write
        case tooLarge          // snapshot exceeds 64 items or 16 MiB
    }

    static let shared = ClipboardTransfer()

    private struct Lease {
        let id: UUID
        let originals: [NSPasteboardItem]
        var writtenCount: Int
        let privateDraft: Bool
        var hasWritten: Bool
        var pendingRestore = false
    }

    private static let ownershipType = NSPasteboard.PasteboardType("com.kenyu.voicepointer.clipboard-lease")
    private static let maxItems = 64
    private static let maxBytes = 16 * 1024 * 1024
    private static let maxTextUTF16Units = 50_000

    private let pasteboard: NSPasteboard
    private var lease: Lease?
    private struct OwnChange { let before: Int; let after: Int }
    private var ownChanges: [OwnChange] = []

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Snapshot the current contents, replace them with `text`, and return the
    /// lease id used later with `restore(id:)` / `abandon(id:)`. All validation
    /// and snapshotting happen before the first write. A later write failure
    /// attempts restoration only while the board is still owned.
    func begin(text: String) throws -> UUID {
        try begin(text: Optional(text), expectedChangeCount: nil)
    }

    public var changeCount: Int { pasteboard.changeCount }

    /// Reserves the sentence's original snapshot without changing its clipboard contents.
    public func reserveDraft(expectedChangeCount: Int) throws -> UUID {
        if let active = lease, active.privateDraft, active.pendingRestore {
            guard owns(id: active.id), acceptsCount(expectedChangeCount) else { throw Error.clipboardChanged }
            let id = UUID()
            let marker = inheritedMarker?.owner == active.id ? inheritedMarker!.marker : active.id
            // Rotate the owner token while keeping the first sentence's original snapshot.
            lease = Lease(id: id, originals: active.originals, writtenCount: active.writtenCount,
                          privateDraft: true, hasWritten: active.hasWritten)
            if active.hasWritten {
                // Ownership of the existing payload is still the predecessor's marker until our next write.
                inheritedMarker = (id, marker)
            }
            return id
        }
        return try begin(text: nil, expectedChangeCount: expectedChangeCount)
    }
    private var inheritedMarker: (owner: UUID, marker: UUID)?

    private func acceptsCount(_ expected: Int) -> Bool {
        let current = pasteboard.changeCount
        if current == expected { return true }
        var count = expected
        for change in ownChanges where change.before == count { count = change.after }
        return count == current
    }
    private func noteOwnChange(from before: Int, to after: Int) {
        guard before != after else { return }
        ownChanges.append(.init(before: before, after: after))
        if ownChanges.count > 32 { ownChanges.removeFirst(ownChanges.count - 32) }
    }
    public func pendingDraftRestore(id: UUID) -> Bool { lease?.id == id && lease?.pendingRestore == true }

    /// One bounded actor turn allows a new sentence to inherit a still-owned original snapshot.
    /// A rotated token makes this delayed restoration incapable of touching its successor.
    public func releaseDraft(id: UUID) async -> Bool {
        guard var active = lease, active.id == id, active.privateDraft else { return false }
        active.pendingRestore = true; lease = active
        try? await Task.sleep(for: .milliseconds(10))
        return restore(id: id)
    }

    private func replacement(text: String, id: UUID, privateDraft: Bool) throws -> NSPasteboardItem {
        guard !text.isEmpty, text.utf16.count <= Self.maxTextUTF16Units else { throw Error.invalidText }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string), item.setString(id.uuidString, forType: Self.ownershipType) else {
            throw Error.unavailable
        }
        if privateDraft {
            for name in ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"] {
                guard item.setData(Data(), forType: .init(name)) else { throw Error.unavailable }
            }
        }
        return item
    }

    private func begin(text: String?, expectedChangeCount: Int?) throws -> UUID {
        guard lease == nil else { throw Error.busy }
        if let text {
            guard !text.isEmpty, text.utf16.count <= Self.maxTextUTF16Units else { throw Error.invalidText }
        }

        let originalCount = pasteboard.changeCount
        guard expectedChangeCount == nil || acceptsCount(expectedChangeCount!) else { throw Error.clipboardChanged }
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= Self.maxItems else { throw Error.tooLarge }

        // In-memory snapshot; item order, type order, and type names preserved.
        var snapshots: [[(NSPasteboard.PasteboardType, Data)]] = []
        snapshots.reserveCapacity(items.count)
        var total = 0
        for item in items {
            var entries: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let raw = item.data(forType: type) else {
                    // Incomplete snapshot; nothing has been written yet.
                    throw Error.unavailable
                }
                guard raw.count <= Self.maxBytes - total else { throw Error.tooLarge }
                total += raw.count
                entries.append((type, raw))
            }
            snapshots.append(entries)
        }
        // Someone else touched the pasteboard while we were reading: no mutation.
        guard pasteboard.changeCount == originalCount else { throw Error.clipboardChanged }

        // Preconstruct the replacement item and the restoration items.
        let id = UUID()
        let textItem = try text.map { try replacement(text: $0, id: id, privateDraft: false) }
        let originals: [NSPasteboardItem] = try snapshots.map { entries in
            let restored = NSPasteboardItem()
            for (type, data) in entries {
                guard restored.setData(data, forType: type) else { throw Error.unavailable }
            }
            return restored
        }

        guard pasteboard.changeCount == originalCount else { throw Error.clipboardChanged }
        guard let textItem else {
            lease = Lease(id: id, originals: originals, writtenCount: originalCount, privateDraft: true, hasWritten: false)
            return id
        }
        _ = try writeReplacement(textItem, id: id, originals: originals, before: originalCount, currentHostOnly: false)
        lease = Lease(id: id, originals: originals, writtenCount: pasteboard.changeCount, privateDraft: false, hasWritten: true)
        return id
    }

    public func owns(id: UUID) -> Bool {
        guard let active = lease, active.id == id else { return false }
        return pasteboard.changeCount == active.writtenCount &&
            (!active.hasWritten || pasteboard.string(forType: Self.ownershipType) ==
             (inheritedMarker?.owner == id ? inheritedMarker!.marker.uuidString : id.uuidString))
    }

    /// Reuses the original snapshot. A user copy invalidates ownership; it is never snapshotted again.
    public func updateDraft(text: String, id: UUID) throws {
        guard var active = lease, active.id == id, active.privateDraft, !active.pendingRestore else { throw Error.clipboardChanged }
        let item = try replacement(text: text, id: id, privateDraft: true)
        guard owns(id: id) else { lease = nil; throw Error.clipboardChanged }
        active.writtenCount = try writeReplacement(item, id: id, originals: active.originals,
            before: active.writtenCount, currentHostOnly: true)
        active.hasWritten = true
        inheritedMarker = nil
        lease = active
    }

    /// Same write/owner checks for both routes; callers retain their distinct admission and lease setup.
    private func writeReplacement(_ item: NSPasteboardItem, id: UUID, originals: [NSPasteboardItem],
                                  before: Int, currentHostOnly: Bool) throws -> Int {
        let cleared = currentHostOnly ? pasteboard.prepareForNewContents(with: .currentHostOnly) : pasteboard.clearContents()
        noteOwnChange(from: before, to: cleared)
        guard pasteboard.changeCount == cleared else { lease = nil; throw Error.clipboardChanged }
        guard pasteboard.writeObjects([item]) else {
            lease = nil
            if pasteboard.changeCount == cleared { _ = rewrite(originals) }
            throw Error.unavailable
        }
        guard pasteboard.string(forType: Self.ownershipType) == id.uuidString else {
            lease = nil; throw Error.clipboardChanged
        }
        let written = pasteboard.changeCount
        noteOwnChange(from: cleared, to: written)
        return written
    }

    /// Restore the snapshotted original contents. Returns false for an unknown
    /// lease id or when the pasteboard changed after our write (a later user
    /// copy is never clobbered). Ownership is released regardless of outcome.
    public func restore(id: UUID) -> Bool {
        guard let active = lease, active.id == id else { return false }
        let owned = owns(id: id)
        lease = nil; inheritedMarker = nil
        guard pasteboard.changeCount == active.writtenCount else { return false }
        if !active.hasWritten { return true }
        guard owned else { return false }
        return rewrite(active.originals)
    }

    /// Drop the lease without writing the pasteboard: a delayed paste may
    /// still need to read the dictation text. Unknown id: no mutation.
    public func abandon(id: UUID) {
        if lease?.id == id { lease = nil; inheritedMarker = nil }
    }

    /// Clear, then write `items`; an empty snapshot restores an empty board.
    private func rewrite(_ items: [NSPasteboardItem]) -> Bool {
        let before = pasteboard.changeCount
        let cleared = pasteboard.clearContents()
        noteOwnChange(from: before, to: cleared)
        guard pasteboard.changeCount == cleared else { return false }
        let result = items.isEmpty ? true : pasteboard.writeObjects(items)
        if result { noteOwnChange(from: cleared, to: pasteboard.changeCount) }
        return result
    }
}
