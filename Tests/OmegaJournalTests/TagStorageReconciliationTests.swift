import Foundation
import Testing
@testable import OmegaJournal

/// Verifies the launch-time reconciliation between the legacy `entries.tags`
/// text column and the `tags`/`entry_tags` junction tables. Historical write
/// paths (the V2 backfill among them) could fail silently, leaving an entry's
/// tags in one store but not the other — the sidebar then under-counted until
/// the entry happened to be edited again.
@Suite("Tag storage reconciliation", .serialized)
struct TagStorageReconciliationTests {
    private static func makeIsolatedDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    @MainActor
    @Test("reconciliation restores junction rows lost to silent write failures")
    func restoresMissingJunctionRows() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        let entry = vm.createEntry(title: "Drift entry", body: "x", tags: ["alpha", "beta"])

        // Simulate the historical failure: junction rows vanish while the text
        // column still carries the tags (and an orphan tag row is left behind).
        vm.db.execParameterized("DELETE FROM entry_tags WHERE entry_id = ?;", entry.id)
        vm.db.execParameterized("INSERT OR IGNORE INTO tags (name) VALUES (?);", "orphan-leftover")

        // The junction table is the sidebar's source of truth; query it fresh
        // (vm.allTags is a cached snapshot taken at create time).
        #expect(!vm.db.tagsWithCounts().contains { $0.tag == "alpha" },
                "precondition: junction loss means the sidebar counts 0")

        vm.db.reconcileTagStorage()

        let healed = try #require(vm.db.fetchEntry(id: entry.id))
        #expect(healed.tags.contains("alpha"), "text column survives reconciliation")
        #expect(healed.tags.contains("beta"))
        #expect(healed.tags != ["alpha,beta"], "comma inside a tag name means separators were misparsed")
        let counts = vm.db.tagsWithCounts()
        #expect(counts.contains { $0.tag == "alpha" && $0.count == 1 })
        #expect(counts.contains { $0.tag == "beta" && $0.count == 1 })
        #expect(!counts.contains { $0.tag == "orphan-leftover" },
                "orphaned tag rows must be pruned")

        // Idempotency: a second pass changes nothing and duplicates no rows.
        vm.db.reconcileTagStorage()
        let again = try #require(vm.db.fetchEntry(id: entry.id))
        #expect(Set(again.tags) == Set(["alpha", "beta"]))

        // Keep the shared singleton database empty for the other suites.
        vm.db.hardDeleteEntry(id: entry.id)
    }

    @MainActor
    @Test("reconciliation unions junction-only tags back into the text column")
    func restoresMissingTextColumnTags() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        let entry = vm.createEntry(title: "Reverse drift entry", body: "x", tags: [])

        // Simulate the opposite drift: junction rows exist but the text column
        // is empty (e.g. a junction write succeeded, the text write failed).
        vm.db.execParameterized("INSERT OR IGNORE INTO tags (name) VALUES (?);", "gamma")
        vm.db.execParameterized(
            "INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) SELECT ?, id FROM tags WHERE name = ?;",
            entry.id, "gamma"
        )

        vm.db.reconcileTagStorage()

        let healed = try #require(vm.db.fetchEntry(id: entry.id))
        #expect(healed.tags.contains("gamma"))
        #expect(vm.db.tagsWithCounts().contains { $0.tag == "gamma" && $0.count == 1 })

        // Keep the shared singleton database empty for the other suites.
        vm.db.hardDeleteEntry(id: entry.id)
    }
}
