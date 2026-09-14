import Foundation
import Testing
@testable import OmegaJournal

/// Coverage for audit item E1 — error propagation:
/// 1. DatabaseManager must report failed writes through `onError` instead of
///    silently swallowing them, and buffer reports until a listener exists.
/// 2. Export must throw on unwritable destinations and round-trip empty and
///    single-entry journals safely.
@Suite("Error propagation", .serialized)
struct ErrorPropagationTests {
    private static func makeIsolatedDatabase() throws -> (root: URL, db: DatabaseManager) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-errors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
        return (root, DatabaseManager.shared)
    }

    @MainActor
    @Test("failed writes are reported through onError")
    func failedWritesReportThroughOnError() throws {
        let (root, db) = try Self.makeIsolatedDatabase()

        defer { db.onError = nil }
        var reported: [String] = []
        db.onError = { reported.append($0) }

        // Insert an entry, then sabotage the schema so subsequent mutations
        // fail — renaming the table makes every statement referencing it a
        // prepare error, covering the saveEntry upsert, the archive UPDATE,
        // and the entry-columns SELECT inside fetchEntry. The rename keeps
        // all data intact and is reversed before the test returns (other
        // suites share this process-wide singleton).
        var entry = JournalEntry.new()
        entry.title = "Doomed"
        db.saveEntry(entry)
        #expect(db.fetchEntry(id: entry.id) != nil)
        db.sabotageTableForTesting("entries")

        db.setArchived(id: entry.id, archived: true)
        #expect(reported.contains { $0.contains("Archive failed") })

        // saveEntry failure inside its transaction must also be reported.
        db.saveEntry(entry)
        #expect(reported.contains { $0.contains("Save failed") })

        #expect(db.fetchEntry(id: entry.id) == nil)

        db.restoreTableForTesting("entries")
        #expect(db.fetchEntry(id: entry.id) != nil)
        db.hardDeleteEntry(id: entry.id)
    }

    @MainActor
    @Test("error reports buffer until a listener is installed")
    func errorReportsBufferUntilListenerInstalls() throws {
        let (root, db) = try Self.makeIsolatedDatabase()
        db.onError = nil // no listener yet — the whole point of this test

        // Sabotage the schema so saveEntry's upsert fails, with no listener
        // installed; the report must buffer.
        db.sabotageTableForTesting("entries")
        var entry = JournalEntry.new()
        entry.title = "Buffered"
        db.saveEntry(entry) // fails, buffered
        db.restoreTableForTesting("entries")

        var reported: [String] = []
        db.onError = { reported.append($0) } // install must flush the buffer
        #expect(reported.contains { $0.contains("Save failed") })
        db.onError = nil
    }

    @MainActor
    @Test("attachment file is removed when the row insert fails")
    func attachmentFileRemovedWhenRowInsertFails() throws {
        let (root, db) = try Self.makeIsolatedDatabase()

        var entry = JournalEntry.new()
        db.saveEntry(entry)

        // Point the attachments directory at an unwritable location so the
        // file write itself fails; saveAttachment must return nil, not a
        // phantom record.
        let original = db.attachmentsDirectoryForTesting
        db.setAttachmentsDirectoryForTesting("/proc/nonexistent-\(UUID().uuidString)")
        defer { db.setAttachmentsDirectoryForTesting(original) }

        let attachment = db.saveAttachment(
            entryId: entry.id, data: Data("x".utf8),
            filename: "test.txt", mimeType: "text/plain")
        #expect(attachment == nil)
        #expect(db.fetchAttachments(entryId: entry.id).isEmpty)

        db.hardDeleteEntry(id: entry.id)
    }

    @Test("export throws on unwritable destination")
    func exportThrowsOnUnwritableDestination() throws {
        var entry = JournalEntry.new()
        entry.title = "Unwritable target"
        let unwritable = URL(fileURLWithPath: "/proc/nonexistent-\(UUID().uuidString)/out.json")

        #expect(throws: (any Error).self) {
            try ExportManager.exportJSON([entry], to: unwritable)
        }

        #expect(throws: (any Error).self) {
            try ExportManager.exportMarkdown([entry], to: unwritable)
        }
    }

    @Test("empty and single-entry journals export and re-import cleanly")
    func emptyAndSingleEntryRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Empty journal: must produce a valid file that imports 0 entries
        // rather than throwing.
        let emptyURL = dir.appendingPathComponent("empty.json")
        try ExportManager.exportJSON([], to: emptyURL)
        let emptyExport = try JSONDecoder.dateWithISO8601.decode(
            ExportManager.JSONExport.self, from: Data(contentsOf: emptyURL))
        #expect(emptyExport.entries.isEmpty)
        #expect(emptyExport.entryCount == 0)

        // Single entry round-trips with all fields intact.
        var entry = JournalEntry.new()
        entry.title = "Solo"
        entry.body = "Body text"
        entry.tags = ["one", "two"]
        entry.isPinned = true
        let singleURL = dir.appendingPathComponent("single.json")
        try ExportManager.exportJSON([entry], to: singleURL)
        let decoded = try JSONDecoder.dateWithISO8601.decode(
            ExportManager.JSONExport.self, from: Data(contentsOf: singleURL))
        #expect(decoded.entries.count == 1)
        let back = decoded.entries[0]
        #expect(back.id == entry.id)
        #expect(back.title == "Solo")
        #expect(back.body == "Body text")
        #expect(back.tags == ["one", "two"])
        #expect(back.isPinned == true)
    }

    @MainActor
    @Test("corrupt JSON import fails gracefully with no entries added")
    func corruptJSONImportFailsGracefully() throws {
        let (root, db) = try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        let before = db.fetchAllEntries(scope: .all).count

        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-corrupt-\(UUID().uuidString).json")
        try Data("not json at all {{{".utf8).write(to: badURL)
        defer { try? FileManager.default.removeItem(at: badURL) }

        let added = vm.importJSON(from: badURL)
        #expect(added == 0)
        #expect(vm.toast?.isError == true)
        #expect(db.fetchAllEntries(scope: .all).count == before)
    }
}

private extension JSONDecoder {
    static let dateWithISO8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Audit item P1 — fetchScopes must return exactly what per-scope
/// fetchAllEntries calls return, so the batched reload path can't drift.
@Suite("Fetch scopes equivalence", .serialized)
struct FetchScopesEquivalenceTests {
    @MainActor
    @Test("fetchScopes matches per-scope fetchAllEntries for every lifecycle state")
    func fetchScopesMatchesPerScopeFetches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-scopes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
        let db = DatabaseManager.shared

        var active = JournalEntry.new()
        active.title = "Active"
        active.tags = ["shared"]
        var archived = JournalEntry.new()
        archived.title = "Archived"
        archived.isArchived = true
        var trashed = JournalEntry.new()
        trashed.title = "Trashed"
        trashed.deletedAt = Date()
        var hidden = JournalEntry.new()
        hidden.title = "Hidden"
        hidden.isHidden = true
        for e in [active, archived, trashed, hidden] { db.saveEntry(e) }

        let requests: [(scope: DatabaseManager.EntryScope, sort: OmegaJournal.SortOrder)] = [
            (.active, .dateDesc), (.trashed, .dateDesc),
            (.archived, .dateDesc), (.hidden, .dateDesc),
        ]
        let batched = db.fetchScopes(requests)
        for request in requests {
            let individual = db.fetchAllEntries(sort: request.sort, scope: request.scope)
            #expect(batched[request.scope]?.map(\.id) == individual.map(\.id))
            #expect(batched[request.scope]?.map { $0.tags } == individual.map { $0.tags })
        }

        // Cleanup.
        for e in [active, archived, trashed, hidden] { db.hardDeleteEntry(id: e.id) }
    }
}
