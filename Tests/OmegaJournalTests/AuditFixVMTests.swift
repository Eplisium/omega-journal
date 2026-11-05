import AppKit
import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

/// Audit fix wave, track vm: editor lifecycle (draft discard, Trash instead of
/// hard delete, Zen/save-state reset, dangling ids), lock re-masking search,
/// notebook delete/move, archive sort, scoped Empty Trash.
@Suite("Audit fix vm: editor lifecycle, lock, notebooks, trash", .serialized)
@MainActor
struct AuditFixVMTests {
    /// Private DB per test; the env vars keep any `.shared` singleton off the
    /// real journal too.
    private static func makeVM() throws -> (JournalViewModel, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-auditfix-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
        let db = DatabaseManager(databasePath: root.appendingPathComponent("private.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("private-att", isDirectory: true).path)
        BiometricAuth.shared.setAuthenticatedForTesting(false)
        return (JournalViewModel(database: db), root)
    }

    private static func tearDown(_ vm: JournalViewModel, _ root: URL) {
        vm.saveDebounce?.cancel()
        vm.saveWriterOverride = nil
        vm.searchText = ""
        BiometricAuth.shared.setAuthenticatedForTesting(false)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: vm-1 — only an untouched blank draft is discarded on Done

    @Test("a new entry with only a voice memo / file attachment survives Done")
    func attachmentOnlyDraftSurvivesDone() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let memo = vm.createEntry()
        vm.addAttachment(to: memo, data: Data("fake m4a".utf8), filename: "Voice memo.m4a", mimeType: "audio/mp4")
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: memo.id)?.isTrashed == false)
        #expect(vm.db.fetchAttachments(entryId: memo.id).count == 1)

        // Same for a PDF on an archived-scope-free draft opened via startEditing.
        let pdf = vm.createEntry()
        vm.addAttachment(to: pdf, data: Data("%PDF".utf8), filename: "scan.pdf", mimeType: "application/pdf")
        vm.startEditing(try #require(vm.entry(id: pdf.id)))
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: pdf.id) != nil)
        #expect(vm.db.fetchAttachments(entryId: pdf.id).count == 1)
    }

    @Test("tags or a mood make a new draft content; a truly blank one is still discarded")
    func draftContentRule() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let blank = vm.createEntry()
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: blank.id) == nil)
        #expect(vm.entry(id: blank.id) == nil)

        let tagged = vm.createEntry()
        var t = try #require(vm.editingEntry); t.tags = ["errand"]
        vm.autoSave(t)
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: tagged.id)?.tags == ["errand"])
        #expect(vm.db.fetchEntry(id: tagged.id)?.isTrashed == false)

        let moody = vm.createEntry()
        vm.setMood(.great, for: try #require(vm.editingEntry))
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: moody.id)?.mood == .great)
        #expect(vm.db.fetchEntry(id: moody.id)?.isTrashed == false)

        // Calendar's back-dated blank draft follows the same rule.
        vm.createEntry(on: Date(timeIntervalSinceNow: -3 * 86_400))
        let dated = try #require(vm.editingEntryId)
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: dated) == nil)
    }

    // MARK: vm-2 — clearing an existing entry moves it to Trash, never hard-deletes

    @Test("clearing an existing entry and pressing Done moves it to Trash with Undo")
    func clearedExistingEntryGoesToTrash() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let e = vm.createEntry(title: "Old entry", body: "years of text", tags: ["keep"])
        vm.stopEditing()
        vm.startEditing(try #require(vm.entry(id: e.id)))
        var cleared = try #require(vm.editingEntry)
        cleared.title = ""; cleared.body = ""; cleared.tags = []   // select-all + delete
        vm.autoSave(cleared)
        vm.stopEditing()                                           // Done

        let stored = try #require(vm.db.fetchEntry(id: e.id), "an existing entry was hard-deleted on Done")
        #expect(stored.isTrashed)
        #expect(vm.trashedEntries.contains { $0.id == e.id })
        #expect(!vm.entries.contains { $0.id == e.id })
        #expect(vm.toast?.message == "Empty entry moved to Trash")
        #expect(vm.toast?.actionLabel == "Undo")
        vm.performUndo()
        #expect(vm.db.fetchEntry(id: e.id)?.isTrashed == false)
    }

    @Test("clearing text but keeping tags keeps the entry; the audit repro survives")
    func clearedTextWithTagsIsKept() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let e = vm.createEntry(title: "Old entry", body: "years of text", tags: ["keep"])
        vm.stopEditing()
        vm.startEditing(try #require(vm.entry(id: e.id)))
        var cleared = try #require(vm.editingEntry)
        cleared.title = ""; cleared.body = ""
        vm.autoSave(cleared)
        vm.stopEditing()
        let stored = try #require(vm.db.fetchEntry(id: e.id))
        #expect(!stored.isTrashed)
        #expect(stored.tags == ["keep"])
    }

    @Test("a new draft that was typed into and then cleared goes to Trash, not oblivion")
    func typedThenClearedDraftGoesToTrash() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let e = vm.createEntry()
        var typed = try #require(vm.editingEntry); typed.body = "a thought"
        vm.autoSave(typed)
        vm.flushPendingSave()
        var cleared = try #require(vm.editingEntry); cleared.body = ""
        vm.autoSave(cleared)
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: e.id)?.isTrashed == true)
    }

    @Test("reopening an existing attachment-only entry and pressing Done keeps it active")
    func existingAttachmentOnlyEntryKept() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let e = vm.createEntry()
        vm.addAttachment(to: e, data: Data("m4a".utf8), filename: "memo.m4a", mimeType: "audio/mp4")
        vm.stopEditing()
        vm.startEditing(try #require(vm.entry(id: e.id)))
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: e.id)?.isTrashed == false)
        #expect(vm.db.fetchAttachments(entryId: e.id).count == 1)
    }

    // MARK: vm-3 — opening another editor over a blank draft discards it

    @Test("opening another editor over a blank new draft discards the draft")
    func blankDraftNotOrphanedByNextEditor() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let keep = vm.createEntry(title: "keep", body: "x"); vm.stopEditing()
        let blank = vm.createEntry()                     // ⌘N
        vm.startEditing(try #require(vm.entry(id: keep.id)))   // double-click another row
        #expect(vm.db.fetchEntry(id: blank.id) == nil)
        #expect(vm.entry(id: blank.id) == nil)
        #expect(vm.editingEntryId == keep.id)
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: keep.id) != nil)

        let blank2 = vm.createEntry()                    // ⌘N
        let other = vm.createEntry()                     // ⌘N again
        #expect(vm.db.fetchEntry(id: blank2.id) == nil)
        #expect(vm.editingEntryId == other.id)
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: other.id) == nil)
    }

    @Test("re-opening the same blank draft keeps it; an attachment draft is never discarded by a switch")
    func switchRespectsDraftRule() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let blank = vm.createEntry()
        vm.startEditing(try #require(vm.entry(id: blank.id)))   // same entry: not a switch
        #expect(vm.db.fetchEntry(id: blank.id) != nil)
        #expect(vm.editingEntryId == blank.id)

        vm.addAttachment(to: blank, data: Data("m4a".utf8), filename: "memo.m4a", mimeType: "audio/mp4")
        let next = vm.createEntry(title: "next", body: "")
        #expect(vm.db.fetchEntry(id: blank.id) != nil)
        #expect(vm.db.fetchAttachments(entryId: blank.id).count == 1)
        vm.stopEditing()
        #expect(vm.db.fetchEntry(id: next.id) != nil)
    }

    // MARK: vm-4 / browse-2 — every lock path re-masks the search results

    @Test("locking re-runs the active search so hidden body matches disappear")
    func lockRefreshesSearchResults() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        BiometricAuth.shared.setAuthenticatedForTesting(true)
        let h = vm.createEntry(title: "Ordinary title", body: "the zebrafish secret", isHidden: true)
        vm.stopEditing()
        vm.searchText = "zebrafish"
        vm.refreshQuery()
        #expect(vm.libraryEntries.map(\.id) == [h.id])
        vm.lockHiddenEntries()
        #expect(vm.hiddenLocked)
        #expect(!vm.libraryEntries.contains { $0.id == h.id })
    }

    @Test("a lock that bypasses lockHiddenEntries (idle relock) also re-masks search; unlock re-reveals")
    func sessionObserverRefreshesSearch() async throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        BiometricAuth.shared.setAuthenticatedForTesting(true)
        let h = vm.createEntry(title: "Plain", body: "quokkacodeword appointment", isHidden: true)
        vm.stopEditing()
        vm.searchText = "quokkacodeword"
        vm.refreshQuery()
        #expect(vm.libraryEntries.map(\.id) == [h.id])
        BiometricAuth.shared.setAuthenticatedForTesting(false)   // what BiometricAuth.lock() does
        try await Task.sleep(nanoseconds: 100_000_000)         // observers run async on main
        #expect(!vm.libraryEntries.contains { $0.id == h.id })
        BiometricAuth.shared.setAuthenticatedForTesting(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(vm.libraryEntries.map(\.id) == [h.id])
    }

    // MARK: vm-5 — deleteJournal flushes first

    @Test("deleting a notebook with a pending edit leaves no entry in a deleted notebook")
    func deleteJournalFlushesFirst() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let nb = try #require(vm.createJournal(name: "Work VM", colorHex: "#336699"))
        vm.setActiveJournal(nb.id)
        let e = vm.createEntry(title: "in work", body: "draft")
        var edited = try #require(vm.editingEntry)
        edited.body = "draft plus last keystrokes"
        vm.autoSave(edited)                       // debounce pending (journalId = Work)
        vm.deleteJournal(nb)                      // within 700 ms
        vm.flushPendingSave()
        let stored = try #require(vm.db.fetchEntry(id: e.id))
        #expect(stored.body == "draft plus last keystrokes")
        #expect(stored.journalId == JournalDefaults.defaultJournalId)
        #expect(vm.db.fetchJournals().contains { $0.id == stored.journalId })
    }

    @Test("an unsaved snapshot filed in a deleted notebook is re-filed to the default journal")
    func deleteJournalRewritesUnsavedSnapshots() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let nb = try #require(vm.createJournal(name: "Gone VM", colorHex: "#663399"))
        vm.setActiveJournal(nb.id)
        let e = vm.createEntry(title: "in gone", body: "text")
        vm.saveWriterOverride = { _ in throw SQLiteError.message("disk I/O error") }
        var edited = try #require(vm.editingEntry); edited.body = "text that failed to save"
        vm.autoSave(edited)
        vm.flushPendingSave()
        #expect(vm.unsavedSnapshots[e.id]?.journalId == nb.id)
        vm.deleteJournal(nb)
        #expect(vm.unsavedSnapshots[e.id]?.journalId == JournalDefaults.defaultJournalId)
        vm.saveWriterOverride = nil
        vm.flushPendingSave()
        let stored = try #require(vm.db.fetchEntry(id: e.id))
        #expect(stored.body == "text that failed to save")
        #expect(stored.journalId == JournalDefaults.defaultJournalId)
    }

    // MARK: vm-6 — reload reconciles dangling editor/selection ids

    @Test("moving the edited entry out of the active notebook closes the editor for good")
    func moveEditedEntryOutOfScope() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let a = try #require(vm.createJournal(name: "VM A", colorHex: "#112233"))
        let b = try #require(vm.createJournal(name: "VM B", colorHex: "#445566"))
        vm.setActiveJournal(a.id)
        let e = vm.createEntry(title: "moving", body: "text")       // editor open in A
        var typed = try #require(vm.editingEntry); typed.body = "text and more"
        vm.autoSave(typed)
        vm.isZenMode = true
        vm.moveToJournal(ids: [e.id], journalId: b.id)              // drag row onto "VM B"
        #expect(vm.editingEntryId == nil)
        #expect(vm.selectedEntryId == nil)
        #expect(!vm.isZenMode)
        #expect(vm.db.fetchEntry(id: e.id)?.body == "text and more")
        #expect(vm.db.fetchEntry(id: e.id)?.journalId == b.id)
        vm.setActiveJournal(nil)                                     // later: "All notebooks"
        #expect(vm.editingEntry == nil)                              // editor must not pop back open
    }

    @Test("restoring a backup without the open entry closes its editor")
    func restoreDropsDanglingEditor() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let e = vm.createEntry(title: "written after the backup", body: "x")
        vm.isZenMode = true
        vm.db.hardDeleteEntry(id: e.id)        // stands in for: the restored backup predates it
        vm.reloadAfterRestore()
        #expect(vm.editingEntryId == nil)
        #expect(vm.selectedEntryId == nil)
        #expect(!vm.isZenMode)
    }

    // MARK: vm-7 — every path that closes the editor leaves Zen and settles the indicator

    @Test("trashing / hiding / bulk-trashing the entry open in Zen leaves Zen mode")
    func closingPathsClearZen() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        _ = vm.createEntry(title: "zen", body: "text")
        var typed = try #require(vm.editingEntry); typed.body = "text typed in zen"
        vm.autoSave(typed)
        vm.isZenMode = true
        vm.deleteEntry(try #require(vm.editingEntry))   // palette "Move to Trash" over Zen
        #expect(vm.editingEntryId == nil)
        #expect(!vm.isZenMode)
        #expect(vm.saveState == .idle)
        let next = vm.createEntry(title: "next", body: "")
        #expect(!vm.isZenMode)                          // next editor is not full-window Zen

        vm.isZenMode = true
        vm.applyHidden(try #require(vm.entry(id: next.id)), hidden: true)
        #expect(vm.editingEntryId == nil)
        #expect(!vm.isZenMode)

        let bulk = vm.createEntry(title: "bulk", body: "x")
        vm.isZenMode = true
        vm.bulkSelection = [bulk.id]
        vm.bulkMoveToTrash()
        #expect(vm.editingEntryId == nil)
        #expect(!vm.isZenMode)
    }

    // MARK: vm-8 — sort order applies to Archive in place

    @Test("changing the sort order re-sorts the Archive list too")
    func sortOrderAppliesToArchive() throws {
        let (vm, root) = try Self.makeVM()
        defer {
            vm.setSortOrder(.dateDesc)
            Self.tearDown(vm, root)
        }
        let a = vm.createEntry(title: "Alpha archived", body: "a"); vm.stopEditing()
        let z = vm.createEntry(title: "Zulu archived", body: "z"); vm.stopEditing()
        var older = try #require(vm.entry(id: a.id)); older.createdAt = Date(timeIntervalSinceNow: -86_400)
        vm.db.saveEntry(older); vm.reload()
        vm.toggleArchive(try #require(vm.entry(id: z.id)))
        vm.toggleArchive(try #require(vm.entry(id: a.id)))
        #expect(vm.archivedEntries.map(\.title) == ["Zulu archived", "Alpha archived"])
        vm.setSortOrder(.titleAsc)
        let shown = vm.archivedEntries.map(\.title)
        vm.reload()
        #expect(shown == vm.archivedEntries.map(\.title))
        #expect(shown == ["Alpha archived", "Zulu archived"])
    }

    // MARK: browse-1 — Empty Trash deletes only the trash the user was shown

    @Test("Empty Trash inside a notebook scope deletes only that notebook's trash")
    func emptyTrashRespectsNotebookScope() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let other = try #require(vm.createJournal(name: "VM Other", colorHex: TagColors.palette[1]))
        let a = vm.createEntry(title: "VM default nb", body: "a"); vm.stopEditing()
        let b = vm.createEntry(title: "VM other nb", body: "b", journalId: other.id); vm.stopEditing()
        let b2 = vm.createEntry(title: "VM other nb 2", body: "b2", journalId: other.id); vm.stopEditing()
        vm.addAttachment(to: try #require(vm.entry(id: a.id)), data: Data("keep".utf8), filename: "keep.pdf", mimeType: "application/pdf")
        vm.deleteEntry(try #require(vm.entry(id: a.id)))
        vm.deleteEntry(try #require(vm.entry(id: b.id)))
        vm.deleteEntry(try #require(vm.entry(id: b2.id)))
        vm.setActiveJournal(other.id)
        #expect(Set(vm.trashedEntries.map(\.id)) == [b.id, b2.id])   // "Delete 2 entries Forever"
        vm.emptyTrash()
        #expect(vm.db.fetchEntry(id: b.id) == nil)
        #expect(vm.db.fetchEntry(id: b2.id) == nil)
        #expect(vm.db.fetchEntry(id: a.id)?.isTrashed == true, "another notebook's trash was hard-deleted")
        #expect(vm.db.fetchAttachments(entryId: a.id).count == 1)
        #expect(vm.trashedEntries.isEmpty)
        #expect(vm.toast?.message == "Emptied Trash (2 entries)")

        vm.setActiveJournal(nil)                                       // "All notebooks"
        #expect(vm.trashedEntries.map(\.id) == [a.id])
        vm.emptyTrash()
        #expect(vm.db.fetchEntry(id: a.id) == nil)
        #expect(vm.toast?.message == "Emptied Trash (1 entry)")
    }

    @Test("Empty Trash never deletes a stale in-memory row that has left Trash")
    func emptyTrashSkipsRestoredRows() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let e = vm.createEntry(title: "VM restored elsewhere", body: "x"); vm.stopEditing()
        vm.deleteEntry(try #require(vm.entry(id: e.id)))
        vm.db.restoreEntry(id: e.id)                 // out-of-band restore; trashedEntries is stale
        #expect(vm.trashedEntries.contains { $0.id == e.id })
        vm.emptyTrash()
        #expect(vm.db.fetchEntry(id: e.id)?.isTrashed == false)
        #expect(vm.toast?.message == "Emptied Trash (0 entries)")
    }

    // MARK: browse-8 (VM half) — trashing an already-trashed entry is a no-op

    @Test("Move to Trash on an entry already in Trash keeps its retention and pushes no Undo")
    func trashingTrashedEntryIsNoOp() throws {
        let (vm, root) = try Self.makeVM()
        defer { Self.tearDown(vm, root) }
        let e = vm.createEntry(title: "VM old trash", body: "x")
        vm.stopEditing()
        vm.deleteEntry(e)
        let twentyDaysAgo = Date().addingTimeInterval(-20 * 86_400).timeIntervalSince1970
        #expect(vm.db.exec("UPDATE entries SET deleted_at = \(twentyDaysAgo) WHERE id = '\(e.id)';"))
        vm.reload()
        let selected = try #require(vm.entry(id: e.id))
        #expect(selected.daysInTrash >= 19)
        vm.selectedEntryId = selected.id
        let depth = vm.undoDepth
        vm.toast = nil
        vm.deleteEntry(try #require(vm.selectedEntry))   // palette "Move to Trash"
        #expect(try #require(vm.db.fetchEntry(id: e.id)).daysInTrash >= 19)
        #expect(vm.undoDepth == depth)
        #expect(vm.toast == nil)
        #expect(vm.selectedEntryId == e.id)
    }
}
