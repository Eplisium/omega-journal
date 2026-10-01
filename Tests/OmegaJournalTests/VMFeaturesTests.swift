import Darwin
import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

@Suite("VM saved searches, backlinks, reviews", .serialized)
@MainActor
struct VMFeaturesTests {
    private static func isolate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-journal-vmf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    @MainActor
    private func cleanup(_ vm: JournalViewModel) {
        for e in vm.db.fetchAllEntriesForExport() where e.title.hasPrefix("VMF") || e.tags.contains("vmftest") || e.tags.contains("review") {
            vm.db.hardDeleteEntry(id: e.id)
        }
        vm.db.setSetting(SavedSearchStore.settingKey, value: "")
    }

    @MainActor
    @Test("saved searches save, apply, persist, delete")
    func savedSearches() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        vm.db.setSetting(SavedSearchStore.settingKey, value: "")
        vm.searchText = "garden"
        vm.filter.tags = ["vmftest"]
        vm.filter.moods = [.good]
        vm.saveCurrentSearch(name: "Garden good")
        #expect(vm.savedSearches.count == 1)
        let s = vm.savedSearches[0]
        #expect(s.query == "garden" && s.tag == "vmftest" && s.mood == "Good")

        vm.searchText = ""; vm.filter = .empty
        vm.applySavedSearch(s)
        #expect(vm.searchText == "garden" && vm.filter.tags == ["vmftest"] && vm.filter.moods == [.good])

        let vm2 = JournalViewModel()
        #expect(vm2.savedSearches == [s])
        vm2.deleteSavedSearch(s)
        #expect(vm2.savedSearches.isEmpty)
        #expect(SavedSearchStore.decode(vm2.db.getSetting(SavedSearchStore.settingKey)).isEmpty)
        cleanup(vm2)
    }

    @MainActor
    @Test("backlinks(for:) finds linking entries and excludes self")
    func backlinks() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        let target = vm.createEntry(title: "VMF Garden", body: "x", tags: ["vmftest"])
        let linker = vm.createEntry(title: "VMF Monday", body: "went to [[vmf garden]]", tags: ["vmftest"])
        _ = vm.createEntry(title: "VMF Other", body: "nothing", tags: ["vmftest"])
        vm.stopEditing()
        #expect(vm.backlinks(for: target).map(\.id) == [linker.id])
        #expect(vm.backlinks(for: linker).isEmpty)
        cleanup(vm)
    }

    @MainActor
    @Test("createReviewEntry makes a tagged draft entry")
    func review() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        _ = vm.createEntry(title: "VMF today", body: "hello world", tags: ["vmftest"])
        let r = vm.createReviewEntry(period: .week)
        #expect(r.title.hasPrefix("Weekly review"))
        #expect(r.tags == ["review"])
        #expect(r.body.contains("#vmftest"))
        vm.stopEditing()
        cleanup(vm)
    }
}
