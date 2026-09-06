import Foundation
import Testing
@testable import OmegaJournal

/// Verifies how hidden entries participate in the sidebar tag counts — in
/// particular that unhiding an entry restores its tags to the totals.
@Suite("Hidden entry tag participation", .serialized)
struct HiddenTagParticipationTests {
    private static func makeIsolatedDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    @MainActor
    @Test("unhidden entries count toward sidebar tag totals")
    func unhiddenEntriesCountTowardTagTotals() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        let tag = "unhide-tag-\(UUID().uuidString.prefix(6))"

        let entry = vm.createEntry(title: "Tag participation entry", body: "x", tags: [tag])

        func count(for t: String) -> Int {
            vm.allTags.first { $0.tag == t }?.count ?? 0
        }

        // 1. Active entry with the tag is counted.
        #expect(count(for: tag) == 1)

        // 2. Hiding it must remove the tag from the sidebar while the biometric
        //    session is locked — the sidebar must not advertise private tags.
        vm.toggleHidden(entry)
        let hiddenEntry = try #require(vm.db.fetchEntry(id: entry.id))
        #expect(hiddenEntry.isHidden == true)
        #expect(vm.hiddenEntries.contains { $0.id == entry.id })
        #expect(count(for: tag) == 0, "locked session must exclude hidden tags")

        // 3. Unlocking the session brings the tag back (entry still hidden).
        #expect(vm.db.tagsWithCounts(includeHidden: true).first { $0.tag == tag }?.count == 1)

        // 4. Unhiding restores the tag at the VM level with the session locked.
        vm.db.setHidden(id: entry.id, hidden: false)
        vm.reload()
        let unhiddenEntry = try #require(vm.db.fetchEntry(id: entry.id))
        #expect(unhiddenEntry.isHidden == false)
        #expect(count(for: tag) == 1)

        // 4. Junction-table tags survive hide/unhide round-trips. fetchEntry
        //    sources tags from the junction table when rows exist there.
        let junctionTags = try #require(vm.db.fetchEntry(id: entry.id))
        #expect(junctionTags.tags.contains(tag))

        // Keep the shared singleton database empty for the other suites.
        vm.db.hardDeleteEntry(id: entry.id)
    }
}
