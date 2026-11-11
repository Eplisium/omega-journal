import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

// Wave 1 / data-perf: single-entry and bulk mutations patch the in-memory
// lists instead of re-reading (and re-decrypting) every row. The result must
// be exactly what a full `reload()` would show.

@Suite("W1Data targeted refresh: same state as a full reload", .serialized)
@MainActor
struct W1DataTargetedRefreshTests {
    init() { TestSharedEnvironment.pin() }

    struct Snapshot: Equatable {
        var active: [JournalEntry]
        var archived: [JournalEntry]
        var trashed: [JournalEntry]
        var hidden: [JournalEntry]
        var tags: [String]
        var tagTree: String
        var smartFolderCounts: [String: Int]
        var journalCounts: [String: Int]
        var search: [String]?
        var selected: String?
        var editing: String?
        var moodCounts: String
    }

    static func snapshot(_ vm: JournalViewModel) -> Snapshot {
        Snapshot(active: vm.entries, archived: vm.archivedEntries, trashed: vm.trashedEntries, hidden: vm.hiddenEntries,
                 tags: vm.allTags.map { "\($0.tag)=\($0.count)" }, tagTree: String(describing: vm.tagTree),
                 smartFolderCounts: vm.smartFolderCounts, journalCounts: vm.journalCounts,
                 search: vm.searchResults?.map(\.id), selected: vm.selectedEntryId, editing: vm.editingEntryId,
                 moodCounts: String(describing: vm.moodCounts.sorted { $0.key.rawValue < $1.key.rawValue }))
    }

    /// Asserts the in-memory state equals what `reload()` produces.
    static func expectMatchesReload(_ vm: JournalViewModel, _ label: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        let patched = snapshot(vm)
        vm.reload()
        let reloaded = snapshot(vm)
        #expect(patched.active.map(\.id) == reloaded.active.map(\.id), "\(label): active order", sourceLocation: sourceLocation)
        #expect(patched == reloaded, "\(label)", sourceLocation: sourceLocation)
    }

    static func makeVM(sort: OmegaJournal.SortOrder = .dateDesc) -> (URL, DatabaseManager, JournalViewModel) {
        let (root, db) = DataSafetyTests.makeDB()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let moods = Mood.allCases
        _ = db.inTransaction {
            for i in 0..<40 {
                var e = JournalEntry.new()
                e.title = i % 9 == 0 ? "" : "Entry \(String(format: "%02d", (i * 17) % 40))"
                e.body = "walk \(i) " + (i % 2 == 0 ? "rain" : "sun") + " " + String(repeating: "w ", count: i % 6)
                e.tags = [["work"], ["family", "work/meetings"], [], ["travel"]][i % 4]
                e.mood = moods[i % moods.count]
                e.createdAt = base.addingTimeInterval(Double((i * 13) % 40) * 3_600)
                e.updatedAt = base.addingTimeInterval(Double((i * 7) % 40) * 60)
                e.isPinned = i % 11 == 0
                e.isFavorite = i % 5 == 0
                e.isHidden = i % 6 == 0
                e.isArchived = i % 7 == 0
                if i % 10 == 9 { e.deletedAt = Date().addingTimeInterval(-Double(i) * 60) }
                if i % 8 == 3 { e.journalId = "second" }
                db.performSave(e)
            }
        }
        let vm = JournalViewModel(database: db)
        vm.sortOrder = sort
        vm.smartFolders = [SmartFolder(name: "Rainy work", query: "rain", tags: ["work"])]
        vm.reload()
        return (root, db, vm)
    }

    @Test("single-entry trash, restore, archive, unarchive, hide and unhide", arguments: [OmegaJournal.SortOrder.dateDesc, .titleAsc, .wordsDesc])
    func singleEntryMutations(sort: OmegaJournal.SortOrder) throws {
        let (root, _, vm) = Self.makeVM(sort: sort)
        defer { try? FileManager.default.removeItem(at: root) }
        let wasUnlocked = BiometricAuth.shared.isAuthenticated
        BiometricAuth.shared.setAuthenticatedForTesting(true)
        defer { BiometricAuth.shared.setAuthenticatedForTesting(wasUnlocked) }
        vm.reload()

        let a = try #require(vm.entries.first { !$0.isPinned && !$0.tags.isEmpty })
        vm.selectedEntryId = a.id
        vm.deleteEntry(a)
        Self.expectMatchesReload(vm, "trash")

        let t = try #require(vm.trashedEntries.first { $0.id == a.id })
        vm.restoreFromTrash(t)
        Self.expectMatchesReload(vm, "restore")

        let b = try #require(vm.entries.first { $0.id != a.id && !$0.isHidden })
        vm.toggleArchive(b)
        Self.expectMatchesReload(vm, "archive")
        let ba = try #require(vm.archivedEntries.first { $0.id == b.id })
        vm.toggleArchive(ba)
        Self.expectMatchesReload(vm, "unarchive")

        let c = try #require(vm.entries.first { !$0.isHidden })
        vm.toggleHidden(c)
        Self.expectMatchesReload(vm, "hide")
        let ch = try #require(vm.hiddenEntries.first { $0.id == c.id })
        vm.toggleHidden(ch)
        Self.expectMatchesReload(vm, "unhide")

        let hiddenArchived = try #require(vm.archivedEntries.first { !$0.isHidden })
        vm.toggleHidden(hiddenArchived)
        Self.expectMatchesReload(vm, "hide archived")

        let forever = try #require(vm.trashedEntries.first)
        vm.deleteForever(forever)
        Self.expectMatchesReload(vm, "delete forever")
    }

    @Test("while searching and with the hidden session locked")
    func searchingAndLocked() throws {
        let (root, _, vm) = Self.makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let wasUnlocked = BiometricAuth.shared.isAuthenticated
        BiometricAuth.shared.setAuthenticatedForTesting(false)
        defer { BiometricAuth.shared.setAuthenticatedForTesting(wasUnlocked) }
        vm.searchText = "rain"
        vm.reload()
        defer { vm.searchText = ""; vm.refreshQuery() }
        let a = try #require(vm.searchResults?.first)
        vm.toggleArchive(a)
        Self.expectMatchesReload(vm, "archive while searching")
        let b = try #require(vm.entries.first { !$0.isHidden })
        vm.applyHidden(b, hidden: true)
        Self.expectMatchesReload(vm, "hide while locked")
        let c = try #require(vm.entries.first)
        vm.deleteEntry(c)
        Self.expectMatchesReload(vm, "trash while searching")
        vm.performUndo()
        Self.expectMatchesReload(vm, "undo trash")
    }

    @Test("bulk actions and undo")
    func bulkActions() throws {
        let (root, _, vm) = Self.makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let wasUnlocked = BiometricAuth.shared.isAuthenticated
        BiometricAuth.shared.setAuthenticatedForTesting(true)
        defer { BiometricAuth.shared.setAuthenticatedForTesting(wasUnlocked) }
        vm.reload()

        vm.bulkSelection = Set(vm.entries.prefix(4).map(\.id))
        vm.bulkArchive()
        Self.expectMatchesReload(vm, "bulk archive")
        vm.performUndo()
        Self.expectMatchesReload(vm, "undo bulk archive")

        vm.bulkSelection = Set(vm.archivedEntries.prefix(2).map(\.id))
        vm.bulkUnarchive()
        Self.expectMatchesReload(vm, "bulk unarchive")

        vm.bulkSelection = Set(vm.entries.suffix(3).map(\.id))
        vm.bulkFavorite()
        Self.expectMatchesReload(vm, "bulk favorite")

        vm.bulkSelection = Set(vm.entries.prefix(3).map(\.id))
        vm.bulkAddTag("fresh/tag")
        Self.expectMatchesReload(vm, "bulk tag")

        vm.bulkSelection = Set(vm.entries.prefix(5).map(\.id))
        vm.bulkMoveToTrash()
        Self.expectMatchesReload(vm, "bulk trash")

        vm.bulkSelection = Set(vm.trashedEntries.prefix(2).map(\.id))
        vm.bulkRestoreFromTrash()
        Self.expectMatchesReload(vm, "bulk restore")

        vm.bulkSelection = Set(vm.trashedEntries.prefix(2).map(\.id))
        vm.bulkDeleteForever()
        Self.expectMatchesReload(vm, "bulk delete forever")

        vm.emptyTrash()
        Self.expectMatchesReload(vm, "empty trash")
        #expect(vm.trashedEntries.isEmpty)
    }

    @Test("a notebook-scoped list drops rows from other notebooks")
    func notebookScope() throws {
        let (root, db, vm) = Self.makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.activeJournalId = "second"
        vm.reload()
        let a = try #require(vm.entries.first)
        vm.toggleArchive(a)
        Self.expectMatchesReload(vm, "archive in notebook")
        // A row moved to another notebook behind the list's back disappears.
        let b = try #require(vm.entries.first)
        var moved = b
        moved.journalId = JournalDefaults.defaultJournalId
        #expect(db.saveEntry(moved))
        vm.relocateEntries([b.id])
        #expect(!vm.entries.contains { $0.id == b.id })
        Self.expectMatchesReload(vm, "moved out of notebook")
    }

    @Test("tag rename and merge re-read only the tagged rows", arguments: [OmegaJournal.SortOrder.dateDesc, .titleDesc])
    func tagRename(sort: OmegaJournal.SortOrder) {
        let (root, _, vm) = Self.makeVM(sort: sort)
        defer { try? FileManager.default.removeItem(at: root) }
        vm.filter.tags = ["work/meetings"]
        vm.renameTagTree("work", to: "job")
        #expect(vm.allTags.contains { $0.tag == "job/meetings" })
        #expect(!vm.allTags.contains { $0.tag == "work" })
        #expect(vm.filter.tags == ["job/meetings"])
        Self.expectMatchesReload(vm, "rename tree")
        vm.mergeTag("travel", into: "family")
        Self.expectMatchesReload(vm, "merge")
        // A tag that exists only in another notebook: no row here changes.
        vm.activeJournalId = JournalDefaults.defaultJournalId
        vm.reload()
        vm.renameTagTree("family", to: "kin")
        Self.expectMatchesReload(vm, "rename in notebook")
    }

    @Test("a large relocation re-sorts once and still matches a reload")
    func largeRelocation() {
        let (root, db, vm) = Self.makeVM(sort: .moodDesc)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (vm.entries + vm.archivedEntries).map(\.id)
        _ = db.bulkSetFavorite(ids: ids, favorite: true)
        vm.relocateEntries(ids)
        #expect(vm.entries.allSatisfy { $0.isFavorite })
        Self.expectMatchesReload(vm, "relocate everything")
    }

    @Test("an unsaved editor snapshot survives a targeted refresh")
    func unsavedSnapshotSurvives() throws {
        let (root, _, vm) = Self.makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try #require(vm.entries.first { !$0.isHidden })
        var edited = target
        edited.body = "typed but not yet saved"
        vm.unsavedSnapshots[target.id] = edited
        vm.relocateEntries([target.id])
        #expect(vm.entry(id: target.id)?.body == "typed but not yet saved")
        vm.unsavedSnapshots[target.id] = nil
    }
}
