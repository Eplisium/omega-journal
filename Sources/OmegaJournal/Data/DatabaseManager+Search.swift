import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    // MARK: - FTS Sync

    /// rowid of the entry's FTS row via `entries_fts_map` (V9). Deleting by
    /// rowid is an index lookup; the UNINDEXED `entry_id` column would need a
    /// full FTS scan on every save.
    func ftsRowid(for entryId: String, create: Bool) -> Int64? {
        let mapped: Int64?? = withCachedStatement("SELECT fts_rowid FROM entries_fts_map WHERE entry_id = ?;") { stmt -> Int64? in
            bindText(stmt, index: 1, value: entryId)
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
        }
        if let rowid = mapped ?? nil { return rowid }
        guard create else { return nil }
        guard execCheckedCached("INSERT INTO entries_fts_map (entry_id) VALUES (?);", context: "FTS map insert failed", bind: { bindText($0, index: 1, value: entryId) }) else { return nil }
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
        guard execCheckedCached("DELETE FROM entries_fts WHERE rowid = ?;", context: "FTS delete failed", bind: { sqlite3_bind_int64($0, 1, rowid) }),
              execCheckedCached("INSERT INTO entries_fts(rowid, entry_id, title, body, tags) VALUES (?, ?, ?, '', ?);", context: "FTS insert failed", bind: { stmt in
                sqlite3_bind_int64(stmt, 1, rowid)
                bindText(stmt, index: 2, value: entry.id)
                bindText(stmt, index: 3, value: entry.title)
                bindText(stmt, index: 4, value: entry.tags.joined(separator: ","))
              })
        else { return }
    }

    /// Rebuilds the whole index (and the id→rowid map) from `entries`.
    /// Returns false if any step failed (caller's transaction is flagged).
    ///
    /// On a regular FTS5 table `DELETE` only appends delete markers: the old
    /// postings stay readable in the `entries_fts_data` segments until a merge
    /// that may never come. Builds before V8 indexed the plaintext body, so a
    /// DELETE-and-reinsert alone left those body words in the file (DATA-1).
    /// `optimize` merges every segment into one and drops the deleted
    /// postings (their pages are zeroed by `PRAGMA secure_delete`). It is used
    /// instead of DROP TABLE, which fails with SQLITE_LOCKED while a caller
    /// (renameTag) still holds a stepped statement.
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
              """),
              exec("INSERT INTO entries_fts(entries_fts) VALUES('optimize');")
        else {
            reportError("FTS rebuild failed")
            return false
        }
        enableFTSSecureDeleteIfSupported()
        return true
    }

    /// FTS5 `secure-delete` (SQLite 3.42+) removes a row's postings on
    /// update/delete instead of leaving them for a later merge, so edited or
    /// deleted titles and tags don't linger in the index. Once a row is
    /// written with it on, FTS5 older than 3.42 can no longer read the table,
    /// so it is only enabled when this system's SQLite is comfortably newer
    /// (3.44+). Best effort: the option is persistent, and failure to set it
    /// changes nothing else (raw exec — never poisons the caller's transaction).
    static let ftsSecureDeleteMinimumVersion: Int32 = 3_044_000

    static var systemSupportsFTSSecureDelete: Bool {
        sqlite3_libversion_number() >= ftsSecureDeleteMinimumVersion
    }

    /// True when the persistent FTS5 `secure-delete` option is on.
    var ftsSecureDeleteEnabled: Bool {
        guard tableExists("entries_fts_config"),
              let stmt = try? prepare("SELECT v FROM entries_fts_config WHERE k = 'secure-delete';") else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1
    }

    func enableFTSSecureDeleteIfSupported() {
        guard Self.systemSupportsFTSSecureDelete, !isReadOnly, !ftsSecureDeleteEnabled else { return }
        if sqlite3_exec(db, "INSERT INTO entries_fts(entries_fts, rank) VALUES('secure-delete', 1);", nil, nil, nil) != SQLITE_OK {
            OmegaLog.search.error("FTS secure-delete not enabled: \(String(cString: sqlite3_errmsg(self.db)), privacy: .private)")
        }
    }
}
