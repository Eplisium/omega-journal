import Combine
import Foundation
import SwiftUI
import AppKit
import OmegaJournalCore

extension JournalViewModel {
    // MARK: - Entry mutations

    /// Immediate mutations must not race a pending debounced autosave: the
    /// debounce holds a full entry snapshot captured before the mutation, and
    /// letting it fire afterwards would silently revert pin/favorite/mood/
    /// archive/hide state. Flush first so storage reflects what is on screen,
    /// then apply the mutation on top.
    func flushBeforeImmediateMutation() {
        saveDebounce?.cancel()
        if let e = editingEntry { db.saveEntry(e) }
    }

    func togglePin(_ entry: JournalEntry) {
        flushBeforeImmediateMutation()
        var u = entry; u.isPinned.toggle(); u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
        showToast(u.isPinned ? "Pinned" : "Unpinned")
    }

    func toggleFavorite(_ entry: JournalEntry) {
        flushBeforeImmediateMutation()
        var u = entry; u.isFavorite.toggle(); u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
        showToast(u.isFavorite ? "Added to favorites" : "Removed from favorites")
    }

    func setMood(_ mood: Mood, for entry: JournalEntry) {
        flushBeforeImmediateMutation()
        var u = entry; u.mood = mood; u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
    }

    // MARK: - Trash & archive

    /// Moves an entry to the trash (recoverable for 30 days).
    func deleteEntry(_ entry: JournalEntry) {
        // A pending autosave captured the pre-trash snapshot (deletedAt == nil);
        // letting it fire would overwrite deleted_at and resurrect the entry.
        saveDebounce?.cancel()
        db.trashEntry(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        searchResults?.removeAll { $0.id == entry.id }
        archivedEntries.removeAll { $0.id == entry.id }
        hiddenEntries.removeAll { $0.id == entry.id }
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        trashedEntries = db.fetchAllEntries(sort: .dateDesc, scope: .trashed, journalId: activeJournalId)
        pushUndo(.restoreTrashed(ids: [entry.id]))
        refreshTagCounts()
        showToast("Moved to Trash", actionLabel: "Undo")
        GoalManager.shared.loadGoals()
    }

    func restoreFromTrash(_ entry: JournalEntry) {
        db.restoreEntry(id: entry.id)
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        reload()
        showToast("Restored “\(entry.displayTitle)”")
    }

    func deleteForever(_ entry: JournalEntry) {
        saveDebounce?.cancel()
        db.hardDeleteEntry(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        searchResults?.removeAll { $0.id == entry.id }
        archivedEntries.removeAll { $0.id == entry.id }
        trashedEntries.removeAll { $0.id == entry.id }
        hiddenEntries.removeAll { $0.id == entry.id }
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        refreshTagCounts()
        showToast("Deleted permanently", isError: true)
    }

    func emptyTrash() {
        saveDebounce?.cancel()
        let count = trashedEntries.count
        db.emptyTrash()
        trashedEntries = []
        if let selected = selectedEntryId, !entries.contains(where: { $0.id == selected }) {
            selectedEntryId = nil
        }
        if let editing = editingEntryId, entry(id: editing) == nil {
            editingEntryId = nil
        }
        refreshTagCounts()
        showToast("Emptied Trash (\(count) \(count == 1 ? "entry" : "entries"))", isError: true)
    }

    func toggleArchive(_ entry: JournalEntry) {
        // Archiving a trashed row would corrupt restore semantics (it would come
        // back pre-archived) and pollute the undo stack — refuse instead.
        guard !entry.isTrashed else { return }
        flushBeforeImmediateMutation()
        let newValue = !entry.isArchived
        db.setArchived(id: entry.id, archived: newValue)
        if selectedEntryId == entry.id { selectedEntryId = nil }
        reload()
        if newValue { pushUndo(.unarchive(ids: [entry.id])) }
        showToast(newValue ? "Archived" : "Unarchived", actionLabel: newValue ? "Undo" : nil)
    }

    func toggleHidden(_ entry: JournalEntry) {
        let newValue = !entry.isHidden
        // Unhiding reveals that the entry exists as a normal card — require auth.
        if !newValue && !BiometricAuth.shared.isAuthenticated {
            Task {
                guard await BiometricAuth.shared.authenticate() else { return }
                applyHidden(entry, hidden: false)
            }
            return
        }
        applyHidden(entry, hidden: newValue)
    }

    func applyHidden(_ entry: JournalEntry, hidden: Bool) {
        flushBeforeImmediateMutation()
        db.setHidden(id: entry.id, hidden: hidden)
        // Close editor if hiding, but keep the entry selected so the card
        // stays visible (masked) in the list.
        if hidden && editingEntryId == entry.id { editingEntryId = nil }
        reload()
        showToast(hidden ? "Hidden" : "Unhidden")
    }

    // MARK: - Bulk actions

    func toggleBulkSelection(_ id: String) {
        if bulkSelection.contains(id) { bulkSelection.remove(id) } else { bulkSelection.insert(id) }
    }

    func clearBulkSelection() {
        bulkSelection.removeAll()
        isBulkSelecting = false
    }

    /// Keeps batch operations bounded to the rows currently visible in the
    /// Journal list whenever search or advanced filters change.
    func retainBulkSelection(in visibleIDs: [String]) {
        bulkSelection.formIntersection(Set(visibleIDs))
    }

    /// Restricts a bulk command to entries actually present in the intended
    /// lifecycle collection, so stale or missing IDs are never acted on.
    func selectedIDs(in source: [JournalEntry]) -> [String] {
        let available = Set(source.map(\.id))
        return bulkSelection.filter(available.contains).sorted()
    }

    var nonTrashedEntries: [JournalEntry] {
        entries + archivedEntries
    }

    /// Soft-deletes the selected active or archived entries. The operation is
    /// intentionally reversible via the toast's Undo action.
    func bulkMoveToTrash() {
        saveDebounce?.cancel()
        let ids = selectedIDs(in: nonTrashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        guard db.bulkTrash(ids: ids) else {
            showToast("Couldn't move the selection to Trash — nothing was changed", isError: true)
            reload()
            return
        }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        if let editing = editingEntryId, ids.contains(editing) { editingEntryId = nil }
        pushUndo(.restoreTrashed(ids: ids))
        clearBulkSelection()
        reload()
        showToast("Moved \(ids.count) \(ids.count == 1 ? "entry" : "entries") to Trash", actionLabel: "Undo")
    }

    /// Legacy name retained for existing callers. All bulk "Delete" actions
    /// outside Trash are recoverable moves to Trash.
    func bulkDelete() {
        bulkMoveToTrash()
    }

    func bulkArchive() {
        flushBeforeImmediateMutation()
        let ids = selectedIDs(in: entries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.setArchived(id: id, archived: true) }
        pushUndo(.unarchive(ids: ids))
        clearBulkSelection()
        reload()
        showToast("Archived \(ids.count) \(ids.count == 1 ? "entry" : "entries")", actionLabel: "Undo")
    }

    func bulkUnarchive() {
        flushBeforeImmediateMutation()
        let ids = selectedIDs(in: archivedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.setArchived(id: id, archived: false) }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        clearBulkSelection()
        reload()
        showToast("Unarchived \(ids.count) \(ids.count == 1 ? "entry" : "entries")")
    }

    func bulkRestoreFromTrash() {
        let ids = selectedIDs(in: trashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.restoreEntry(id: id) }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        clearBulkSelection()
        reload()
        showToast("Restored \(ids.count) \(ids.count == 1 ? "entry" : "entries")")
    }

    /// Irreversibly removes only selected entries that are already in Trash.
    /// The UI must obtain explicit confirmation before invoking this method.
    func bulkDeleteForever() {
        saveDebounce?.cancel()
        let ids = selectedIDs(in: trashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.hardDeleteEntry(id: id) }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        if let editing = editingEntryId, ids.contains(editing) { editingEntryId = nil }
        clearBulkSelection()
        reload()
        showToast("Deleted \(ids.count) \(ids.count == 1 ? "entry" : "entries") permanently", isError: true)
    }

    func bulkFavorite() {
        let ids = selectedIDs(in: nonTrashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        // Work from the in-memory (already decrypted) snapshot instead of
        // re-fetching + decrypting every row from SQLite.
        flushBeforeImmediateMutation()
        // One metadata-only transaction: no body re-encryption, all-or-nothing.
        guard let changed = db.bulkSetFavorite(ids: ids, favorite: true) else {
            showToast("Couldn't favorite the selection — nothing was changed", isError: true)
            reload()
            return
        }
        clearBulkSelection()
        reload()
        showToast(changed == 0 ? "Selected entries were already favorites" : "Favorited \(changed) \(changed == 1 ? "entry" : "entries")")
    }

    func bulkAddTag(_ tag: String) {
        // Commas are the text-column separator — never allow them inside a tag.
        guard let trimmed = OmegaCore.normalizeTags([tag]).first, !bulkSelection.isEmpty else { return }
        let ids = selectedIDs(in: nonTrashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        flushBeforeImmediateMutation()
        guard let changed = db.bulkAddTag(ids: ids, tag: trimmed) else {
            showToast("Couldn't tag the selection — nothing was changed", isError: true)
            reload()
            return
        }
        clearBulkSelection()
        reload()
        showToast(changed == 0 ? "Selected entries already have #\(trimmed)" : "Tagged \(changed) \(changed == 1 ? "entry" : "entries") with #\(trimmed)")
    }

    // MARK: - Undo & toasts

    func showToast(_ message: String, actionLabel: String? = nil, isError: Bool = false) {
        let t = Toast(message: message, actionLabel: actionLabel, isError: isError)
        toast = t
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if self?.toast == t { self?.toast = nil }
            }
        }
    }

    func pushUndo(_ action: UndoAction) {
        undoStack.append(action)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
    }

    var undoDepth: Int { undoStack.count }

    func performUndo() {
        guard let action = undoStack.popLast() else { return }
        // Report what actually changed: entries may since have been deleted
        // forever or restored by hand.
        switch action {
        case .restoreTrashed(let ids):
            let restorable = ids.filter { db.fetchEntry(id: $0)?.isTrashed == true }
            for id in restorable { db.restoreEntry(id: id) }
            showToast(Self.undoMessage(verb: "Restored", count: restorable.count, requested: ids.count))
        case .unarchive(let ids):
            let archived = ids.filter { db.fetchEntry(id: $0).map { $0.isArchived && !$0.isTrashed } == true }
            for id in archived { db.setArchived(id: id, archived: false) }
            showToast(Self.undoMessage(verb: "Unarchived", count: archived.count, requested: ids.count))
        }
        reload()
    }

    static func undoMessage(verb: String, count: Int, requested: Int) -> String {
        if count == 0 { return "Nothing to undo — those entries have changed since" }
        let noun = count == 1 ? "entry" : "entries"
        if count < requested { return "\(verb) \(count) of \(requested) \(requested == 1 ? "entry" : "entries")" }
        return "\(verb) \(count) \(noun)"
    }
}
