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
        flushPendingSave()
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
        // A later retry of an unsaved snapshot must not revert this mood.
        unsavedSnapshots[u.id]?.mood = mood
        db.saveEntry(u)
        updateEntry(u)
    }

    // MARK: - Targeted refresh

    /// What `reload()` does, for a change confined to the rows `ids`: only
    /// those rows are re-read (decrypting at most them) and moved into the
    /// lists they now belong to — or out of every list when they are gone or
    /// in another notebook. Every other row stays as it was. Sidebar tag
    /// counts, the tag tree, smart-folder and notebook counts, goals, search
    /// results and the selection are then refreshed exactly as `reload()`
    /// refreshes them. `W1DataTargetedRefreshTests` pins the equivalence.
    func relocateEntries(_ ids: [String]) {
        persistPendingSnapshot()
        let failuresBefore = db.readFailureCount
        defer { noteReadOutcome(since: failuresBefore, complete: false) }
        let wanted = Set(ids)
        let fetched = wanted.isEmpty ? [] : db.fetchEntries(ids: Array(wanted))
        // If the rows couldn't be re-read, leave them where they are: moving
        // them out of every list would make them look deleted.
        if !wanted.isEmpty, db.readFailureCount == failuresBefore {
            let fresh = fetched.filter { e in
                activeJournalId.map { $0.isEmpty || e.journalId == $0 } ?? true
            }.sorted { $0.id < $1.id }
            var active = entries.filter { !wanted.contains($0.id) }
            var archived = archivedEntries.filter { !wanted.contains($0.id) }
            var trashed = trashedEntries.filter { !wanted.contains($0.id) }
            // A few rows are inserted in place; many are appended and the
            // list re-sorted once (inserting thousands one by one is quadratic).
            let insertInPlace = fresh.count <= 16
            func place(_ e: JournalEntry, _ list: inout [JournalEntry], _ order: SortOrder) {
                if insertInPlace { Self.insert(e, into: &list, by: order) } else { list.append(e) }
            }
            for e in fresh {
                if e.isTrashed {
                    place(e, &trashed, .dateDesc)
                } else if e.isArchived {
                    place(e, &archived, sortOrder)
                } else {
                    place(e, &active, sortOrder)
                }
            }
            if !insertInPlace {
                let order = sortOrder
                active.sort { Self.storagePrecedes($0, $1, by: order) }
                archived.sort { Self.storagePrecedes($0, $1, by: order) }
                trashed.sort { Self.storagePrecedes($0, $1, by: .dateDesc) }
            }
            entries = active
            archivedEntries = archived
            trashedEntries = trashed
            hiddenEntries = Self.hiddenScope(active: entries, archived: archivedEntries)
            reapplyUnsavedSnapshots()
        }
        refreshTagCounts()
        GoalManager.shared.loadGoals()
        refreshQuery()
        dropDanglingSelectionAndEditor()
    }

    // MARK: - Trash & archive

    /// Moves an entry to the trash (recoverable for 30 days).
    func deleteEntry(_ entry: JournalEntry, toast message: String = "Moved to Trash") {
        // Already in Trash (e.g. the palette's "Move to Trash" on a trashed
        // selection): trashing again would restart its 30-day retention and
        // push an Undo that pulls it out of Trash.
        guard !entry.isTrashed, self.entry(id: entry.id)?.isTrashed != true else { return }
        // A pending autosave captured the pre-trash snapshot (deletedAt == nil);
        // letting it fire later would overwrite deleted_at and resurrect the
        // entry, and cancelling it would lose the edit. Save it now, THEN trash.
        flushBeforeImmediateMutation()
        db.trashEntry(id: entry.id)
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        relocateEntries([entry.id])
        pushUndo(.restoreTrashed(ids: [entry.id]))
        showToast(message, actionLabel: "Undo")
    }

    func restoreFromTrash(_ entry: JournalEntry) {
        flushBeforeImmediateMutation()
        db.restoreEntry(id: entry.id)
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        relocateEntries([entry.id])
        showToast("Restored “\(entry.displayTitle)”")
    }

    func deleteForever(_ entry: JournalEntry) {
        flushBeforeImmediateMutation()
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

    /// Permanently deletes the Trash the user is looking at. `trashedEntries`
    /// is scoped to the active notebook — so are the confirmation's count and
    /// the toast — and other notebooks' Trash is never touched.
    func emptyTrash() {
        flushBeforeImmediateMutation()
        let ids = trashedEntries.map(\.id)
        guard let count = db.hardDeleteTrashedEntries(ids: ids) else {
            showToast("Couldn't empty Trash — nothing was deleted", isError: true)
            reload()
            return
        }
        // Re-read the emptied rows (also drops a selection/editor on one).
        relocateEntries(ids)
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
        relocateEntries([entry.id])
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
        relocateEntries([entry.id])
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
        flushBeforeImmediateMutation()
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
        relocateEntries(ids)
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
        relocateEntries(ids)
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
        relocateEntries(ids)
        showToast("Unarchived \(ids.count) \(ids.count == 1 ? "entry" : "entries")")
    }

    func bulkRestoreFromTrash() {
        flushBeforeImmediateMutation()
        let ids = selectedIDs(in: trashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.restoreEntry(id: id) }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        clearBulkSelection()
        relocateEntries(ids)
        showToast("Restored \(ids.count) \(ids.count == 1 ? "entry" : "entries")")
    }

    /// Irreversibly removes only selected entries that are already in Trash.
    /// The UI must obtain explicit confirmation before invoking this method.
    func bulkDeleteForever() {
        flushBeforeImmediateMutation()
        let ids = selectedIDs(in: trashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.hardDeleteEntry(id: id) }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        if let editing = editingEntryId, ids.contains(editing) { editingEntryId = nil }
        clearBulkSelection()
        relocateEntries(ids)
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
        relocateEntries(ids)
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
        relocateEntries(ids)
        showToast(changed == 0 ? "Selected entries already have #\(trimmed)" : "Tagged \(changed) \(changed == 1 ? "entry" : "entries") with #\(trimmed)")
    }

    // MARK: - Undo & toasts

    func showToast(_ message: String, actionLabel: String? = nil, isError: Bool = false) {
        let t = Toast(message: message, actionLabel: actionLabel, isError: isError)
        toast = t
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.toast == t { self?.toast = nil }
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
        flushBeforeImmediateMutation()
        // Report what actually changed: entries may since have been deleted
        // forever or restored by hand.
        switch action {
        case .restoreTrashed(let ids):
            let restorable = ids.filter { db.fetchEntry(id: $0)?.isTrashed == true }
            for id in restorable { db.restoreEntry(id: id) }
            relocateEntries(ids)
            showToast(Self.undoMessage(verb: "Restored", count: restorable.count, requested: ids.count))
        case .unarchive(let ids):
            let archived = ids.filter { db.fetchEntry(id: $0).map { $0.isArchived && !$0.isTrashed } == true }
            for id in archived { db.setArchived(id: id, archived: false) }
            relocateEntries(ids)
            showToast(Self.undoMessage(verb: "Unarchived", count: archived.count, requested: ids.count))
        }
    }

    static func undoMessage(verb: String, count: Int, requested: Int) -> String {
        if count == 0 { return "Nothing to undo — those entries have changed since" }
        let noun = count == 1 ? "entry" : "entries"
        if count < requested { return "\(verb) \(count) of \(requested) \(requested == 1 ? "entry" : "entries")" }
        return "\(verb) \(count) \(noun)"
    }
}
