import Foundation
import SQLite3
import Testing
import OmegaJournalCore
@testable import OmegaJournal

// Wave 1 / data-perf: a read that fails must never look like an empty
// journal. Failures are counted by the data layer, surfaced as fixed wording
// in `JournalViewModel.readError`, and the lists on screen are kept.

@Suite("W1Data read errors: never an empty journal", .serialized)
@MainActor
struct W1DataReadErrorTests {
    init() { TestSharedEnvironment.pin() }

    static func seed(_ db: DatabaseManager, count: Int) -> [String] {
        var ids: [String] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<count {
            var e = JournalEntry.new()
            e.title = "Entry \(i)"
            e.body = "body \(i)"
            e.tags = ["t\(i % 2)"]
            e.createdAt = base.addingTimeInterval(Double(i) * 60)
            #expect(db.saveEntry(e))
            ids.append(e.id)
        }
        return ids
    }

    /// Registers `boom()` (always fails) on the connection.
    static func installBoom(_ db: DatabaseManager) {
        let rc = sqlite3_create_function_v2(db.db, "boom", 0, SQLITE_UTF8, nil, { ctx, _, _ in
            sqlite3_result_error(ctx, "boom", -1)
        }, nil, nil, nil)
        #expect(rc == SQLITE_OK)
    }

    @Test("a reload that can't read keeps the lists and shows fixed wording")
    func reloadFailureKeepsLists() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = Self.seed(db, count: 5)
        let vm = JournalViewModel(database: db)
        #expect(vm.entries.count == 5)
        #expect(vm.readError == nil)

        #expect(db.exec("ALTER TABLE entries RENAME TO entries_unavailable;"))
        vm.reload()
        #expect(vm.entries.count == 5, "the list must not turn empty")
        let message = try #require(vm.readError)
        #expect(message == JournalViewModel.readErrorMessage)
        for jargon in ["SQL", "SELECT", "sqlite", "prepare", "no such"] {
            #expect(!message.localizedCaseInsensitiveContains(jargon))
        }

        #expect(db.exec("ALTER TABLE entries_unavailable RENAME TO entries;"))
        vm.retryReading()
        #expect(vm.readError == nil)
        #expect(vm.entries.count == 5)
    }

    @Test("a statement that stops on an error mid-list is a failure, not a short journal")
    func stepErrorMidList() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = Self.seed(db, count: 6)
        let vm = JournalViewModel(database: db)
        #expect(vm.entries.count == 6)
        Self.installBoom(db)
        // Shadow `entries` with a temp view that errors on one row.
        #expect(db.exec("""
            CREATE TEMP VIEW entries AS
            SELECT id, title, body_enc, mood, tags, created_at, updated_at, is_pinned, is_favorite, deleted_at,
                   is_archived, word_count, is_hidden, body, journal_id
            FROM main.entries WHERE CASE WHEN id = '\(ids[2])' THEN boom() ELSE 1 END;
            """))
        let before = db.readFailureCount
        let partial = db.fetchAllEntries()
        #expect(db.readFailureCount > before)
        #expect(partial.count < 6)

        vm.reload()
        #expect(vm.entries.count == 6)
        #expect(vm.readError != nil)
        #expect(db.exec("DROP VIEW temp.entries;"))
        vm.reload()
        #expect(vm.readError == nil)
    }

    @Test("a targeted refresh that can't re-read leaves the row where it was")
    func relocateFailureKeepsRow() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = Self.seed(db, count: 3)
        let vm = JournalViewModel(database: db)
        let target = try #require(vm.entries.first)
        #expect(db.exec("ALTER TABLE entry_tags RENAME TO entry_tags_unavailable;"))
        vm.relocateEntries([target.id])
        #expect(vm.entries.contains { $0.id == target.id })
        #expect(vm.readError != nil)
        #expect(db.exec("ALTER TABLE entry_tags_unavailable RENAME TO entry_tags;"))
        vm.retryReading()
        #expect(vm.readError == nil)
    }

    @Test("the first load on an unreadable journal says so")
    func firstLoadFailure() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = Self.seed(db, count: 2)
        #expect(db.exec("ALTER TABLE attachments RENAME TO attachments_unavailable;"))
        let vm = JournalViewModel(database: db)
        #expect(vm.readError == JournalViewModel.readErrorMessage)
        #expect(db.exec("ALTER TABLE attachments_unavailable RENAME TO attachments;"))
    }

    @Test("hasEncryptedRows fails closed")
    func hasEncryptedRowsFailsClosed() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        // An empty journal really has none.
        #expect(db.hasEncryptedRows() == false)
        _ = Self.seed(db, count: 1)
        #expect(db.hasEncryptedRows() == true)

        // Unanswerable: the query can't be prepared.
        let (root2, db2) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root2) }
        #expect(db2.exec("ALTER TABLE entries RENAME COLUMN body_enc TO body_enc_unavailable;"))
        #expect(db2.hasEncryptedRows() == true)

        // Unanswerable: the step errors.
        let (root3, db3) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root3) }
        Self.installBoom(db3)
        #expect(db3.exec("CREATE TEMP VIEW entries AS SELECT boom() AS body_enc;"))
        #expect(db3.hasEncryptedRows() == true)

        // Unanswerable: no connection.
        let (root4, db4) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root4) }
        sqlite3_close(db4.db)
        db4.db = nil
        #expect(db4.hasEncryptedRows() == true)
    }
}
