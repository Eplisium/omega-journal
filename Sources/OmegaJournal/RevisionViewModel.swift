import Foundation
import OmegaJournalCore

extension JournalViewModel {
    /// Version history is gated exactly like the body: a hidden entry's revisions are
    /// invisible while the biometric session is locked.
    func canViewRevisions(of entry: JournalEntry) -> Bool {
        !entry.isHidden || BiometricAuth.shared.isAuthenticated
    }

    func revisions(for entry: JournalEntry) -> [EntryRevision] {
        guard canViewRevisions(of: entry) else { return [] }
        return db.revisions(entryId: entry.id)
    }

    func revisionBody(_ revision: EntryRevision, for entry: JournalEntry) -> String? {
        guard canViewRevisions(of: entry) else { return nil }
        return db.revisionBody(id: revision.id)
    }

    /// Snapshot of the entry as stored (called when an edit session starts/ends).
    func snapshotRevision(of entry: JournalEntry) {
        db.snapshotRevision(of: entry)
    }

    /// Restores a revision: saves the current text as a manual "before restore" revision first,
    /// then writes the old text through the immediate-mutation path.
    /// Returns the restored (title, body) so an open editor can adopt it.
    @discardableResult
    func restoreRevision(_ revision: EntryRevision, for entry: JournalEntry) -> (title: String, body: String)? {
        guard canViewRevisions(of: entry), let body = db.revisionBody(id: revision.id) else {
            showToast("Couldn't read that version", isError: true)
            return nil
        }
        flushBeforeImmediateMutation()
        let current = self.entry(id: entry.id) ?? entry
        db.snapshotRevision(of: current, isAuto: false)
        var u = current
        u.title = revision.title
        u.body = body
        u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
        refreshTagCounts()
        showToast("Restored version from \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))")
        return (revision.title, body)
    }
}
