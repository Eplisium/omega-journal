import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    // MARK: - Migrations

    func columnExists(_ table: String, _ column: String) -> Bool {
        guard let stmt = try? prepare("PRAGMA table_info(\(table));") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }

    /// Idempotent ADD COLUMN: SQLite has no IF NOT EXISTS for it, and a
    /// failing exec would (rightly) poison the surrounding transaction.
    func addColumnIfMissing(_ table: String, _ column: String, _ definition: String) -> Bool {
        if columnExists(table, column) { return true }
        return exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    var schemaVersion: Int { getSchemaVersion() }

    func runMigrations() {
        guard exec("""
            CREATE TABLE IF NOT EXISTS schema_version (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                version INTEGER NOT NULL DEFAULT 0
            );
        """), exec("INSERT OR IGNORE INTO schema_version (id, version) VALUES (1, 0);") else {
            enterReadOnlyMode("Could not initialise schema tracking — journal opened read-only.")
            return
        }

        let current = getSchemaVersion()
        let target = Self.currentSchemaVersion

        // A database written by a newer build must not be downgraded or have
        // older migrations re-run against it.
        if current > target {
            enterReadOnlyMode("This journal was created by a newer version of Omega Journal (schema \(current), this app supports \(target)). It was opened read-only; update the app to edit it.")
            return
        }
        if current == target { return }

        let migrations: [(version: Int, run: () -> Bool)] = [
            (1, migrateToV1), (2, migrateToV2), (3, migrateToV3), (4, migrateToV4),
            (5, migrateToV5), (6, migrateToV6), (7, migrateToV7), (8, migrateToV8),
            (9, migrateToV9),
        ]

        // Snapshot existing user data before any change. A brand-new database
        // (version 0, no entries table) has nothing to protect.
        if current > 0 || tableExists("entries") {
            if !snapshotBeforeMigration(fromVersion: current) {
                if entryRowCountIfAny() > 0 {
                    enterReadOnlyMode("Could not take a safety snapshot before upgrading the journal — migration skipped and journal opened read-only. Free disk space and relaunch.")
                    return
                }
            }
        }

        var ranV8 = false
        for m in migrations where current < m.version {
            beginTransaction()
            var ok = m.run()
            if ok { ok = setSchemaVersion(m.version) }
            if !ok { flagTransactionFailure() }
            let committed = endTransaction()
            if !ok || !committed {
                enterReadOnlyMode("Upgrading the journal to schema V\(m.version) failed and was rolled back; your data is unchanged. The journal opened read-only. A pre-upgrade snapshot is in the backups folder.")
                return
            }
            if m.version == 8 { ranV8 = true }
        }
        if ranV8 {
            // The pre-migration plaintext pages stay in the file as free space
            // after the UPDATEs — VACUUM rewrites the database so the old bodies
            // are physically gone. VACUUM cannot run inside a transaction.
            exec("VACUUM;")
        }
    }

    func tableExists(_ name: String) -> Bool {
        guard let stmt = try? prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?;") else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: name)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func entryRowCountIfAny() -> Int {
        guard tableExists("entries"), let stmt = try? prepare("SELECT COUNT(*) FROM entries;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func getSchemaVersion() -> Int {
        guard let stmt = try? prepare("SELECT version FROM schema_version WHERE id = 1;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    /// Records the version. A silent failure would leave schema_version stale,
    /// so the caller treats `false` as a failed migration (rolled back).
    func setSchemaVersion(_ version: Int) -> Bool {
        guard let stmt = try? prepare("UPDATE schema_version SET version = ? WHERE id = 1;") else {
            reportError("Could not prepare schema_version update")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(version))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            reportError("Could not record schema version \(version): \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    /// V1: Base tables (entries + settings)
    func migrateToV1() -> Bool {
        exec("""
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                body TEXT NOT NULL DEFAULT '',
                mood INTEGER DEFAULT 3,
                tags TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                is_favorite INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
        """)
    }

    /// V2: Tags table + junction table, migrate existing comma-separated tags
    func migrateToV2() -> Bool {
        guard exec("""
            CREATE TABLE IF NOT EXISTS tags (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL
            );
            CREATE TABLE IF NOT EXISTS entry_tags (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (entry_id, tag_id)
            );
        """) else { return false }

        // Migrate existing comma-separated tags to the junction table
        guard let stmt = try? prepare("SELECT id, tags FROM entries WHERE tags != '';") else { return false }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let entryId = String(cString: sqlite3_column_text(stmt, 0))
            let tagsStr = String(cString: sqlite3_column_text(stmt, 1))
            let tags = tagsStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for tag in tags {
                execParameterized("INSERT OR IGNORE INTO tags (name) VALUES (?);", tag)
                execParameterized(
                    "INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) SELECT ?, id FROM tags WHERE name = ?;",
                    entryId, tag
                )
            }
        }
        return !transactionFailed
    }

    /// V3: Full-text search index
    func migrateToV3() -> Bool {
        guard exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
                entry_id UNINDEXED,
                title, body, tags
            );
        """) else { return false }

        // Populate FTS from existing entries (idempotent: clear first).
        return exec("DELETE FROM entries_fts;") && exec("""
            INSERT INTO entries_fts(entry_id, title, body, tags)
            SELECT id, title, '', tags FROM entries;
        """)
    }

    /// V4: Attachments table
    func migrateToV4() -> Bool {
        exec("""
            CREATE TABLE IF NOT EXISTS attachments (
                id TEXT PRIMARY KEY,
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                filename TEXT NOT NULL,
                mime_type TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_attachments_entry ON attachments(entry_id);
        """)
    }

    /// V5: Soft-delete (trash) + archive flags, entry templates, and performance indexes.
    func migrateToV5() -> Bool {
        guard addColumnIfMissing("entries", "deleted_at", "REAL"),
              addColumnIfMissing("entries", "is_archived", "INTEGER NOT NULL DEFAULT 0"),
              exec("""
            CREATE TABLE IF NOT EXISTS templates (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                body TEXT NOT NULL DEFAULT '',
                tags TEXT NOT NULL DEFAULT '',
                icon TEXT NOT NULL DEFAULT 'doc.text',
                sort_order INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_entries_created ON entries(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_entries_deleted ON entries(deleted_at);
            CREATE INDEX IF NOT EXISTS idx_entry_tags_tag ON entry_tags(tag_id);
        """) else { return false }
        seedDefaultTemplates()
        return !transactionFailed
    }

    /// V6: `word_count` column so goals and sort-by-words don't need to load bodies.
    /// Backfills every existing row from its body text.
    func migrateToV6() -> Bool {
        guard addColumnIfMissing("entries", "word_count", "INTEGER NOT NULL DEFAULT 0") else { return false }
        // Backfill: split body on whitespace and count tokens, matching JournalEntry.wordCount.
        guard let stmt = try? prepare("SELECT id, body FROM entries;") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let body = String(cString: sqlite3_column_text(stmt, 1))
            let count = body.isEmpty ? 0 : body.split(whereSeparator: { $0.isWhitespace }).count
            execParameterized("UPDATE entries SET word_count = ? WHERE id = ?;",
                              String(count), id)
        }
        return exec("CREATE INDEX IF NOT EXISTS idx_entries_word_count ON entries(word_count DESC);")
            && !transactionFailed
    }

    /// V7: Hidden entries — `is_hidden` flag. Content is gated in the UI; main scopes still include them.
    func migrateToV7() -> Bool {
        addColumnIfMissing("entries", "is_hidden", "INTEGER NOT NULL DEFAULT 0")
            && exec("CREATE INDEX IF NOT EXISTS idx_entries_hidden ON entries(is_hidden);")
    }

    /// V8: Encrypt entry bodies at rest. Adds `body_enc` (AES-GCM blob);
    /// plaintext `body` is migrated to it and then blanked, so the SQLite
    /// file and its auto-backups no longer carry journal text. Idempotent:
    /// blank bodies are skipped, so a re-run never double-encrypts. Returns
    /// false (rolling the whole step back, version NOT bumped) unless EVERY
    /// pending row was converted. The follow-up VACUUM runs after commit in
    /// `runMigrations`.
    func migrateToV8() -> Bool {
        guard addColumnIfMissing("entries", "body_enc", "BLOB") else { return false }
        return encryptPendingBodies()
    }

    /// V9: stable FTS row mapping so per-save index maintenance deletes by
    /// rowid instead of scanning the whole FTS table (`entry_id` is UNINDEXED,
    /// so `DELETE … WHERE entry_id = ?` was a full scan on every save).
    /// `entries.rowid` isn't usable — VACUUM may renumber it — hence the
    /// explicit map. Idempotent: the index is rebuilt from scratch.
    func migrateToV9() -> Bool {
        guard exec("""
            CREATE TABLE IF NOT EXISTS entries_fts_map (
                fts_rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                entry_id TEXT NOT NULL UNIQUE
            );
        """) else { return false }
        return reindexFTS()
    }

    /// Encrypts every entry whose `body_enc` is NULL and whose plaintext
    /// `body` is non-empty, then clears the plaintext column. Returns true only
    /// if all such rows were converted (or there were none).
    @discardableResult
    func encryptPendingBodies() -> Bool {
        beginTransaction()
        defer { endTransaction() }
        guard let stmt = try? prepare("SELECT id, body FROM entries WHERE body_enc IS NULL AND body != '';"),
              let upd = try? prepare("UPDATE entries SET body_enc = ?, body = '' WHERE id = ?;")
        else {
            reportError("Body encryption migration could not prepare")
            flagTransactionFailure()
            return false
        }
        defer { sqlite3_finalize(stmt); sqlite3_finalize(upd) }
        var pairs: [(id: String, sealed: Data)] = []
        var allOK = true
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let body = String(cString: sqlite3_column_text(stmt, 1))
            guard let sealed = try? JournalCrypto.encryptString(body) else {
                reportError("Could not encrypt body for entry \(id) — migration will not complete")
                allOK = false
                continue
            }
            pairs.append((id, sealed))
        }
        for pair in pairs {
            sqlite3_reset(upd)
            bindBlob(upd, index: 1, value: pair.sealed)
            bindText(upd, index: 2, value: pair.id)
            if sqlite3_step(upd) != SQLITE_DONE {
                reportError("Body encryption update failed for \(pair.id)")
                flagTransactionFailure()
                allOK = false
            }
        }
        if !allOK { flagTransactionFailure() }
        return allOK
    }
}
