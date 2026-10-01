import Foundation
import SwiftUI
import OmegaJournalCore

extension JournalViewModel {
    // MARK: - Tag color

    func color(forTag tag: String) -> Color? {
        // A nested tag inherits its nearest colored ancestor.
        var path: String? = tag
        while let p = path {
            if let hex = tagColors[p], let rgb = TagColors.rgb(hex: hex) {
                return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
            }
            path = TagPath.parent(of: p)
        }
        return nil
    }

    func setTagColor(_ tag: String, hex: String?) {
        guard db.setTagColor(tag, hex: hex) else { return }
        tagColors = db.tagColors()
    }

    // MARK: - Rename / merge / delete

    /// Renames a tag and its whole subtree; merges into an existing tag when the name is taken.
    func renameTagTree(_ old: String, to new: String) {
        flushBeforeImmediateMutation()
        let n = db.renameTagTree(from: old, to: new)
        guard n > 0 else {
            showToast("Couldn't rename “\(old)”", isError: true)
            return
        }
        fixFiltersAfterRename(old: old, new: TagPath.normalize(new) ?? new)
        reload()
        showToast("Renamed to #\(TagPath.normalize(new) ?? new)")
    }

    /// Merges `source` (and its children) into `target`.
    func mergeTag(_ source: String, into target: String) {
        guard source != target else { return }
        renameTagTree(source, to: target)
    }

    func deleteTagEverywhere(_ tag: String) {
        flushBeforeImmediateMutation()
        for name in db.allTagNames() where TagPath.isSameOrDescendant(name, of: tag) { db.deleteTag(name) }
        filter.tags = filter.tags.filter { !TagPath.isSameOrDescendant($0, of: tag) }
        reload()
        showToast("Deleted #\(tag)")
    }

    private func fixFiltersAfterRename(old: String, new: String) {
        let remapped = filter.tags.map { TagPath.renamed($0, from: old, to: new) ?? $0 }
        if Set(remapped) != filter.tags { filter.tags = Set(remapped) }
    }

    // MARK: - Drag & drop from the list into the sidebar

    /// Tags the dragged entries (immediate mutation, one transaction).
    func dropEntries(ids: [String], onTag tag: String) {
        let valid = ids.filter { id in entry(id: id).map { !$0.isTrashed } ?? false }
        guard !valid.isEmpty, let clean = TagPath.normalize(tag) else { return }
        flushBeforeImmediateMutation()
        guard let changed = db.bulkAddTag(ids: valid, tag: clean) else {
            showToast("Couldn't tag the entries — nothing was changed", isError: true)
            reload(); return
        }
        reload()
        showToast(changed == 0 ? "Already tagged #\(clean)" : "Tagged \(changed) \(changed == 1 ? "entry" : "entries") with #\(clean)")
    }

    func dropEntriesOnArchive(ids: [String]) {
        let valid = ids.filter { id in entries.contains { $0.id == id } }
        guard !valid.isEmpty else { return }
        flushBeforeImmediateMutation()
        for id in valid { db.setArchived(id: id, archived: true) }
        pushUndo(.unarchive(ids: valid))
        reload()
        showToast("Archived \(valid.count) \(valid.count == 1 ? "entry" : "entries")", actionLabel: "Undo")
    }

    /// Ids to drag from a row: the whole bulk selection when the row is part of it, else just the row.
    func dragIDs(for entry: JournalEntry) -> [String] {
        bulkSelection.contains(entry.id) && bulkSelection.count > 1 ? bulkSelection.sorted() : [entry.id]
    }

    // MARK: - Notebooks

    /// Journal new entries are created in: the active journal, else the default.
    var newEntryJournalId: String { activeJournalId ?? JournalDefaults.defaultJournalId }

    var activeJournal: Journal? { journals.first { $0.id == activeJournalId } }

    func journal(id: String) -> Journal? { journals.first { $0.id == id } }

    func setActiveJournal(_ id: String?) {
        let target = id.flatMap { want in journals.contains { $0.id == want } ? want : nil }
        guard target != activeJournalId else { return }
        flushBeforeImmediateMutation()
        activeJournalId = target
        db.setSetting(Self.activeJournalSettingKey, value: target ?? "")
        if let sel = selectedEntryId, entry(id: sel) == nil { selectedEntryId = nil }
        reload()
    }

    @discardableResult
    func createJournal(name: String, colorHex: String) -> Journal? {
        guard let j = db.createJournal(name: name, colorHex: colorHex) else {
            showToast("Couldn't create that notebook — the name may be empty or taken", isError: true)
            return nil
        }
        journals = db.fetchJournals()
        refreshOrganization()
        return j
    }

    func updateJournal(_ journal: Journal, name: String, colorHex: String) {
        guard db.updateJournal(id: journal.id, name: name, colorHex: colorHex) else {
            showToast("Couldn't update the notebook", isError: true); return
        }
        journals = db.fetchJournals()
    }

    func deleteJournal(_ journal: Journal) {
        guard db.deleteJournal(id: journal.id) else { return }
        journals = db.fetchJournals()
        if activeJournalId == journal.id {
            activeJournalId = nil
            db.setSetting(Self.activeJournalSettingKey, value: "")
        }
        reload()
        showToast("Deleted notebook “\(journal.name)” — its entries moved to \(JournalDefaults.defaultJournalName)")
    }

    func moveToJournal(ids: [String], journalId: String) {
        flushBeforeImmediateMutation()
        guard let n = db.moveEntries(ids: ids, toJournal: journalId) else {
            showToast("Couldn't move entries", isError: true); return
        }
        reload()
        if n > 0 { showToast("Moved \(n) \(n == 1 ? "entry" : "entries") to \(journal(id: journalId)?.name ?? "notebook")") }
    }

    func moveSelectedToJournal(_ journalId: String) {
        moveToJournal(ids: selectedIDs(in: nonTrashedEntries), journalId: journalId)
        clearBulkSelection()
    }
}
