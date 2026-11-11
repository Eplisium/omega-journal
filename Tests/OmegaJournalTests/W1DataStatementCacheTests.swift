import Foundation
import SQLite3
import Testing
import OmegaJournalCore
@testable import OmegaJournal

// Wave 1 / data-perf: hot paths reuse prepared statements. A cached
// statement must never leak bindings or rows between uses, never be reset
// under a caller that is still stepping it, and never keep the connection
// from closing.

@Suite("W1Data statement cache", .serialized)
@MainActor
struct W1DataStatementCacheTests {
    init() { TestSharedEnvironment.pin() }

    private func entry(_ title: String, tags: [String] = []) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title
        e.body = "body of \(title)"
        e.tags = tags
        return e
    }

    @Test("saves and single-entry reads reuse statements with identical results")
    func reuseIsTransparent() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = entry("A", tags: ["one", "two"])
        let b = entry("B", tags: ["three"])
        #expect(db.saveEntry(a))
        let hitsAfterFirst = db.statementCacheHits
        #expect(db.saveEntry(b))
        #expect(db.statementCacheHits > hitsAfterFirst, "the second save reuses the first save's statements")
        #expect(!db.statementCache.isEmpty)

        // Bindings never leak: each read sees only its own row and tags.
        for _ in 0..<3 {
            #expect(db.fetchEntry(id: a.id)?.title == "A")
            #expect(db.fetchEntry(id: a.id)?.tags == ["one", "two"])
            #expect(db.fetchEntry(id: b.id)?.tags == ["three"])
            #expect(db.fetchEntry(id: "missing") == nil)
        }
        #expect(db.fetchTagsForEntry(b.id) == ["three"])
        #expect(db.fetchTagsForEntry("missing") == nil)
        #expect(db.fetchAttachments(entryId: a.id).isEmpty)
        #expect(db.ftsRankedIds("B") == [b.id])
        #expect(db.statementsInUse.isEmpty)
    }

    @Test("a checked-in statement holds no read snapshot")
    func checkedInStatementsAreReset() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = entry("Visible")
        #expect(db.saveEntry(a))
        _ = db.fetchEntry(id: a.id)
        // Every cached statement is reset: none is mid-step.
        for stmt in db.statementCache.values {
            #expect(sqlite3_stmt_busy(stmt) == 0)
        }
        // A write from another connection is seen by the next cached read.
        let other = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                    attachmentsPath: root.appendingPathComponent("attachments").path)
        var renamed = a
        renamed.title = "Renamed elsewhere"
        #expect(other.saveEntry(renamed))
        #expect(db.fetchEntry(id: a.id)?.title == "Renamed elsewhere")
    }

    @Test("re-entrant use of the same SQL gets its own statement")
    func reentrancy() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(db.saveEntry(entry("A")))
        #expect(db.saveEntry(entry("B")))
        let sql = "SELECT title FROM entries ORDER BY title;"
        var outer: [String] = []
        var innerCounts: [Int] = []
        _ = db.withCachedStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                outer.append(String(cString: sqlite3_column_text(stmt, 0)))
                let inner = db.withCachedStatement(sql) { s -> Int in
                    var n = 0
                    while sqlite3_step(s) == SQLITE_ROW { n += 1 }
                    return n
                }
                innerCounts.append(inner ?? -1)
            }
        }
        #expect(outer == ["A", "B"], "the outer iteration was not reset by the inner use")
        #expect(innerCounts == [2, 2])
    }

    @Test("closing and reopening finalizes every cached statement")
    func closeFinalizes() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(db.saveEntry(entry("A")))
        #expect(!db.statementCache.isEmpty)
        db.closeConnection()
        #expect(db.db == nil)
        #expect(db.statementCache.isEmpty)
        db.openDatabase()
        #expect(db.fetchAllEntries().map(\.title) == ["A"])
        #expect(db.saveEntry(entry("B")))
        #expect(db.fetchAllEntries().count == 2)
    }

    @Test("a cached statement survives a schema change")
    func schemaChange() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = entry("A")
        #expect(db.saveEntry(a))
        _ = db.fetchEntry(id: a.id)
        #expect(db.exec("CREATE TABLE w1data_probe (x INTEGER);"))
        #expect(db.exec("CREATE INDEX w1data_idx ON entries(title);"))
        #expect(db.fetchEntry(id: a.id)?.title == "A")
        #expect(db.saveEntry(entry("B")))
    }

    @Test("the cache stays bounded")
    func bounded() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<(DatabaseManager.statementCacheLimit + 10) {
            _ = db.withCachedStatement("SELECT \(i);") { sqlite3_step($0) }
        }
        #expect(db.statementCache.count <= DatabaseManager.statementCacheLimit)
    }

    @Test("a failed cached save still rolls back and is reported")
    func failedSaveReported() {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(db.saveEntry(entry("A")))
        var errors: [String] = []
        db.onError = { errors.append($0) }
        defer { db.onError = nil }
        #expect(db.exec("CREATE TRIGGER w1data_block BEFORE INSERT ON entries BEGIN SELECT RAISE(ABORT, 'blocked'); END;"))
        let b = entry("B")
        #expect(!db.saveEntry(b))
        #expect(db.fetchEntry(id: b.id) == nil)
        #expect(errors.contains { $0.contains("Save failed") })
        #expect(db.statementsInUse.isEmpty)
    }

    @Test("the Application Support fallback is the standard folder")
    func applicationSupportFallback() {
        let url = DatabaseManager.fallbackApplicationSupport()
        #expect(url.path.hasSuffix("/Library/Application Support"))
    }
}
