import Foundation
import SQLite3

extension DatabaseManager {
    /// V10: per-entry version history. Bodies are sealed with the same AES-GCM key as
    /// `entries.body_enc` (V8) — plaintext revision text is never written to disk.
    /// Titles mirror `entries.title` (already stored in the clear). `ON DELETE CASCADE`
    /// removes history with the entry (foreign keys are enabled on this connection).
    /// Idempotent (`IF NOT EXISTS`).
    func migrateToV10() -> Bool {
        exec("""
            CREATE TABLE IF NOT EXISTS entry_revisions (
                id TEXT PRIMARY KEY,
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                created_at REAL NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                body_enc BLOB NOT NULL,
                word_count INTEGER NOT NULL DEFAULT 0,
                is_auto INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_revisions_entry ON entry_revisions(entry_id, created_at DESC);
        """)
    }
}
