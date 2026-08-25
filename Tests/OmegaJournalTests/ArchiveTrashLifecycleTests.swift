import Darwin
import Foundation
import Testing
@testable import OmegaJournal

@Suite("Archive and trash lifecycle")
struct ArchiveTrashLifecycleTests {
    @MainActor
    @Test("bulk storage operations keep every collection synchronized")
    func bulkStorageOperationsKeepCollectionsSynchronized() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-journal-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("journal.sqlite3")
        let attachmentsURL = root.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", databaseURL.path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", attachmentsURL.path, 1)

        let vm = JournalViewModel()
        #expect(vm.entries.isEmpty)

        let first = vm.createEntry(title: "First lifecycle entry", body: "A testable journal entry.")
        let second = vm.createEntry(title: "Second lifecycle entry", body: "Another testable journal entry.")
        let ids: Set<String> = [first.id, second.id]

        vm.bulkSelection = ids
        vm.bulkArchive()
        #expect(vm.entries.isEmpty)
        #expect(Set(vm.archivedEntries.map(\.id)) == ids)
        #expect(vm.bulkSelection.isEmpty)
        #expect(!vm.isBulkSelecting)

        // Archived entries used to be absent from the active-only bulk lookup.
        vm.bulkSelection = [first.id]
        vm.bulkFavorite()
        #expect(vm.archivedEntries.first(where: { $0.id == first.id })?.isFavorite == true)

        // Single-entry mutations must update storage collections too, not only
        // the active-library array.
        let favoritedArchiveEntry = try #require(vm.archivedEntries.first(where: { $0.id == first.id }))
        vm.toggleFavorite(favoritedArchiveEntry)
        #expect(vm.archivedEntries.first(where: { $0.id == first.id })?.isFavorite == false)

        let archivedSecond = try #require(vm.archivedEntries.first(where: { $0.id == second.id }))
        vm.setMood(.great, for: archivedSecond)
        #expect(vm.archivedEntries.first(where: { $0.id == second.id })?.mood == .great)

        // Archived entries must be resolvable by the reader/editor, and an
        // autosave must update the Archive card immediately and on disk.
        let editableArchiveEntry = try #require(vm.archivedEntries.first(where: { $0.id == first.id }))
        vm.select(editableArchiveEntry)
        #expect(vm.selectedEntry?.id == first.id)
        vm.startEditing(editableArchiveEntry)
        #expect(vm.editingEntry?.id == first.id)
        var renamedArchiveEntry = try #require(vm.editingEntry)
        renamedArchiveEntry.title = "Renamed lifecycle entry"
        vm.autoSave(renamedArchiveEntry)
        #expect(vm.archivedEntries.first(where: { $0.id == first.id })?.title == "Renamed lifecycle entry")
        vm.flushPendingSave()
        #expect(vm.db.fetchEntry(id: first.id)?.title == "Renamed lifecycle entry")
        vm.stopEditing()

        // Storage collections should search their own records while preserving
        // the active-library FTS search isolation.
        vm.searchText = "Renamed lifecycle"
        vm.refreshQuery()
        #expect(vm.entriesMatchingCurrentSearch(in: vm.archivedEntries).map(\.id) == [first.id])

        // Locked hidden entries never match their body text in a storage search.
        BiometricAuth.shared.lock()
        let hiddenArchiveEntry = try #require(vm.archivedEntries.first(where: { $0.id == second.id }))
        vm.toggleHidden(hiddenArchiveEntry)
        vm.searchText = "Another testable"
        vm.refreshQuery()
        #expect(vm.entriesMatchingCurrentSearch(in: vm.hiddenEntries).isEmpty)

        // A filtered-away row must not remain eligible for a bulk operation.
        vm.bulkSelection = ids
        vm.retainBulkSelection(in: [first.id])
        #expect(vm.bulkSelection == [first.id])
        vm.searchText = ""
        vm.refreshQuery()

        vm.bulkSelection = ids
        vm.bulkMoveToTrash()
        #expect(vm.archivedEntries.isEmpty)
        #expect(Set(vm.trashedEntries.map(\.id)) == ids)
        #expect(vm.bulkSelection.isEmpty)

        // Restore preserves the prior archive state rather than silently moving
        // an archived entry into the active library.
        vm.bulkSelection = ids
        vm.bulkRestoreFromTrash()
        #expect(vm.trashedEntries.isEmpty)
        #expect(Set(vm.archivedEntries.map(\.id)) == ids)

        vm.bulkSelection = ids
        vm.bulkUnarchive()
        #expect(vm.archivedEntries.isEmpty)
        #expect(Set(vm.entries.map(\.id)) == ids)

        vm.bulkSelection = ids
        vm.bulkMoveToTrash()
        vm.bulkSelection = ids
        vm.bulkDeleteForever()
        #expect(vm.entries.isEmpty)
        #expect(vm.archivedEntries.isEmpty)
        #expect(vm.trashedEntries.isEmpty)
        #expect(vm.hiddenEntries.isEmpty)
        #expect(vm.db.fetchEntry(id: first.id) == nil)
        #expect(vm.db.fetchEntry(id: second.id) == nil)
    }
}
