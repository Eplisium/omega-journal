import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    // MARK: - FTS Sync

    /// rowid of the entry's FTS row via `entries_fts_map` (V9). Deleting by
    /// rowid is an index lookup; the UNINDEXED `entry_id` column would need a
    /// full FTS scan on every save.
    func ftsRowid(for entryId: String, create: Bool) -> Int64? {
        if let stmt = try? prepare("SELECT fts_rowid FROM entries_fts_map WHERE entry_id = ?;") {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: entryId)
            if sqlite3_step(stmt) == SQLITE_ROW { return sqlite3_column_int64(stmt, 0) }
        }
        guard create else { return nil }
        guard execChecked("INSERT INTO entries_fts_map (entry_id) VALUES (?);", context: "FTS map insert failed", bind: { bindText($0, index: 1, value: entryId) }) else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    func removeFTS(entryId: String) {
        guard let rowid = ftsRowid(for: entryId, create: false) else {
            // Not mapped (never indexed) — nothing to remove.
            return
        }
        execChecked("DELETE FROM entries_fts WHERE rowid = ?;", context: "Delete entry search index failed") { stmt in
            sqlite3_bind_int64(stmt, 1, rowid)
        }
        execChecked("DELETE FROM entries_fts_map WHERE entry_id = ?;", context: "Delete entry search map failed") { stmt in
            bindText(stmt, index: 1, value: entryId)
        }
    }

    func updateFTS(_ entry: JournalEntry) {
        guard let rowid = ftsRowid(for: entry.id, create: true) else {
            flagTransactionFailure()
            return
        }
        // FTS stores only title/tags — indexing body would put plaintext back
        // on disk. Body search is handled by decryptBodyMatches in Swift.
        guard execChecked("DELETE FROM entries_fts WHERE rowid = ?;", context: "FTS delete failed", bind: { sqlite3_bind_int64($0, 1, rowid) }),
              execChecked("INSERT INTO entries_fts(rowid, entry_id, title, body, tags) VALUES (?, ?, ?, '', ?);", context: "FTS insert failed", bind: { stmt in
                sqlite3_bind_int64(stmt, 1, rowid)
                bindText(stmt, index: 2, value: entry.id)
                bindText(stmt, index: 3, value: entry.title)
                bindText(stmt, index: 4, value: entry.tags.joined(separator: ","))
              })
        else { return }
    }

    /// Rebuilds the whole index (and the id→rowid map) from `entries`.
    /// Returns false if any step failed (caller's transaction is flagged).
    @discardableResult
    func reindexFTS() -> Bool {
        beginTransaction()
        defer { endTransaction() }
        guard exec("DELETE FROM entries_fts;"),
              exec("DELETE FROM entries_fts_map;"),
              exec("INSERT INTO entries_fts_map (entry_id) SELECT id FROM entries;"),
              exec("""
                INSERT INTO entries_fts(rowid, entry_id, title, body, tags)
                SELECT m.fts_rowid, e.id, e.title, '', e.tags
                FROM entries e JOIN entries_fts_map m ON m.entry_id = e.id;
              """)
        else {
            reportError("FTS rebuild failed")
            return false
        }
        return true
    }
}
