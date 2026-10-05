import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    /// V11: organization — tag colors, journals (notebooks) and `entries.journal_id`.
    ///
    /// Idempotent: every statement is IF NOT EXISTS / guarded, and the default-journal
    /// backfill only touches rows that have no journal yet. Existing entries all land in
    /// the default journal, so a freshly migrated library looks exactly as before.
    func migrateToV11() -> Bool {
        guard addColumnIfMissing("tags", "color", "TEXT") else { return false }
        guard exec("""
            CREATE TABLE IF NOT EXISTS journals (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                color TEXT NOT NULL DEFAULT '#8B5CF6',
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
        """) else { return false }
        guard execChecked("INSERT OR IGNORE INTO journals (id, name, color, sort_order, created_at) VALUES (?, ?, ?, 0, ?);",
                          context: "Create default journal failed", bind: { stmt in
            bindText(stmt, index: 1, value: JournalDefaults.defaultJournalId)
            bindText(stmt, index: 2, value: JournalDefaults.defaultJournalName)
            bindText(stmt, index: 3, value: TagColors.palette[0])
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        }) else { return false }
        guard addColumnIfMissing("entries", "journal_id", "TEXT NOT NULL DEFAULT '\(JournalDefaults.defaultJournalId)'") else { return false }
        guard exec("UPDATE entries SET journal_id = '\(JournalDefaults.defaultJournalId)' WHERE journal_id IS NULL OR journal_id = '';") else { return false }
        return exec("CREATE INDEX IF NOT EXISTS idx_entries_journal ON entries(journal_id);")
    }
}
