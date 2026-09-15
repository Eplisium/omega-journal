import Foundation
import SQLite3
import OmegaJournalCore

// MARK: - SQLite Error

enum SQLiteError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let msg): return msg }
    }
}

// MARK: - Database Manager

final class DatabaseManager {
    static let shared = DatabaseManager()

    /// Hook the app layer uses to surface write failures to the user. Called on
    /// the main actor with a human-readable message. Failures that occur before
    /// an app layer exists (migrations at first launch) are buffered and
    /// flushed to the first handler that is installed.
    var onError: ((String) -> Void)? {
        didSet {
            guard onError != nil, !pendingErrors.isEmpty else { return }
            let buffered = pendingErrors
            pendingErrors.removeAll()
            buffered.forEach(onError!)
        }
    }
    private var pendingErrors: [String] = []

    /// Reports a failed write. Reporting never changes control flow — inside a
    /// transaction the failure is also flagged for rollback; outside one the
    /// swallow-and-continue behaviour that tests rely on is preserved.
    func reportError(_ message: String) {
        print("OmegaJournal: \(message)")
        if let onError {
            onError(message)
        } else {
            // Keep only the most recent few; nothing is listening yet.
            pendingErrors.append(message)
            if pendingErrors.count > 5 { pendingErrors.removeFirst(pendingErrors.count - 5) }
        }
    }

    /// Runs one UPDATE-style statement with bound parameters, checking the
    /// step result and reporting failures. Returns whether the write landed.
    private func execChecked(_ sql: String, context: String, bind: (OpaquePointer?) -> Void) -> Bool {
        guard let stmt = try? prepare(sql) else {
            reportError("\(context) failed to prepare")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            reportError("\(context): \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private var db: OpaquePointer?
    private var dbPath: String
    private var attachmentsDir: String

    // Current schema version — bump when adding migrations
    private static let currentSchemaVersion = 8

    /// Entries stay in the trash this long before `purgeExpiredTrash()` removes them.
    static let trashRetentionDays = 30

    private init() {
        let fileManager = FileManager.default
        if let testPath = ProcessInfo.processInfo.environment["OMEGA_JOURNAL_TEST_DATABASE_PATH"], !testPath.isEmpty {
            // An explicit, test-only override keeps lifecycle integration tests
            // completely isolated from a person's real journal database.
            let databaseURL = URL(fileURLWithPath: testPath)
            let testRoot = databaseURL.deletingLastPathComponent()
            try? fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
            dbPath = databaseURL.path
            attachmentsDir = ProcessInfo.processInfo.environment["OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH"]
                ?? testRoot.appendingPathComponent("attachments", isDirectory: true).path
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("OmegaJournal", isDirectory: true)
            try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
            dbPath = appDir.appendingPathComponent("omega_journal.sqlite3").path
            attachmentsDir = appDir.appendingPathComponent("attachments", isDirectory: true).path
        }
        try? FileManager.default.createDirectory(atPath: attachmentsDir, withIntermediateDirectories: true)
        openDatabase()
        runMigrations()
        reconcileTagStorage()
        purgeExpiredTrash()
        autoBackup()
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            fatalError("Failed to open database: \(msg)")
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
    }

    // MARK: - SQL Helpers

    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            reportError("SQLite exec error: \(msg)")
            flagTransactionFailure()
            return false
        }
        return true
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.message("Prepare failed: \(msg)\nSQL: \(sql)")
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindBlob(_ stmt: OpaquePointer?, index: Int32, value: Data) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = value.withUnsafeBytes { raw in sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT) }
        if bound != SQLITE_OK {
            reportError("Blob bind failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func blobAt(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    /// Runs a one-shot statement with the given text parameters bound left-to-right
    /// (1, 2, 3…). Silently logs failures — used for internal mutations where the
    /// caller doesn't need the result. Internal (not private) so the tag-storage
    /// reconciliation and its tests can simulate historical write patterns.
    func execParameterized(_ sql: String, _ values: String...) {
        guard let stmt = try? prepare(sql) else {
            flagTransactionFailure()
            return
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in values.enumerated() { bindText(stmt, index: Int32(i + 1), value: v) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            flagTransactionFailure()
        }
    }

    // MARK: - Transactions

    /// Depth of the active transaction stack. The connection is
    /// single-threaded (every caller is on the main actor), so a plain counter
    /// is sufficient; re-entrancy lets composed mutations each request their
    /// own transaction and still behave correctly when nested inside a larger
    /// one (only the outermost begin/commit touches SQLite).
    private var transactionDepth = 0
    /// Set when any statement fails inside the active transaction. The
    /// outermost unwind then rolls back instead of committing a partial write.
    /// Failures outside a transaction keep the historical swallow-and-continue
    /// behaviour (tests rely on simulating failed writes that way).
    private var transactionFailed = false

    private func flagTransactionFailure() {
        if transactionDepth > 0 { transactionFailed = true }
    }

    private func beginTransaction() {
        if transactionDepth == 0 { exec("BEGIN IMMEDIATE TRANSACTION;") }
        transactionDepth += 1
    }

    /// Must be balanced with `beginTransaction` — wrap bodies in
    /// `defer { endTransaction() }` so early returns cannot strand an open
    /// transaction (an open one would buffer every later write uncommitted).
    private func endTransaction() {
        guard transactionDepth > 0 else { return }
        transactionDepth -= 1
        if transactionDepth == 0 {
            if transactionFailed {
                exec("ROLLBACK;")
            } else {
                exec("COMMIT;")
            }
            transactionFailed = false
        }
    }

    // MARK: - Test hooks

    // The error-propagation tests need to make real writes fail. Renaming the
    // table makes every statement referencing it a prepare error while keeping
    // ALL data intact — unlike DROP COLUMN, which would destroy column values
    // other concurrently-running test suites may still be reading. Must always
    // be paired with `restoreTableForTesting` before the test returns.
    #if DEBUG
    func sabotageTableForTesting(_ table: String) {
        exec("ALTER TABLE \(table) RENAME TO \(table)_sabotaged;")
    }

    func restoreTableForTesting(_ table: String) {
        exec("ALTER TABLE \(table)_sabotaged RENAME TO \(table);")
    }

    /// Re-writes a body as legacy plaintext (NULL body_enc) to simulate a
    /// pre-V8 row; the normal save path then re-encrypts it on next write.
    /// Used by EncryptionAtRestTests to exercise the upgrade path.
    func legacyPlaintextForTesting(id: String, body: String) {
        execChecked("UPDATE entries SET body = ?, body_enc = NULL WHERE id = ?;", context: "Legacy plaintext write failed") { stmt in
            bindText(stmt, index: 1, value: body)
            bindText(stmt, index: 2, value: id)
        }
    }

    /// Flushes the WAL into the main DB file so tests can assert on the
    /// on-disk bytes (WAL otherwise buffers recent writes).
    func checkpointForTesting() {
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func vacuumForTesting() {
        exec("VACUUM;")
    }

    var attachmentsDirectoryForTesting: String { attachmentsDir }

    func setAttachmentsDirectoryForTesting(_ path: String) {
        attachmentsDir = path
    }
    #endif

    // MARK: - Migrations

    private func runMigrations() {
        // Create schema_version table if it doesn't exist
        exec("""
            CREATE TABLE IF NOT EXISTS schema_version (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                version INTEGER NOT NULL DEFAULT 0
            );
        """)

        // Insert initial version row if missing
        exec("INSERT OR IGNORE INTO schema_version (id, version) VALUES (1, 0);")

        let current = getSchemaVersion()

        if current < 1 {
            migrateToV1()
        }
        if current < 2 {
            migrateToV2()
        }
        if current < 3 {
            migrateToV3()
        }
        if current < 4 {
            migrateToV4()
        }
        if current < 5 {
            migrateToV5()
        }
        if current < 6 {
            migrateToV6()
        }
        if current < 7 {
            migrateToV7()
        }
        if current < 8 {
            migrateToV8()
        }
    }

    private func getSchemaVersion() -> Int {
        guard let stmt = try? prepare("SELECT version FROM schema_version WHERE id = 1;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    private func setSchemaVersion(_ version: Int) {
        // A silent failure here would leave schema_version stale, so the next
        // launch would re-run migrations against already-migrated data.
        guard let stmt = try? prepare("UPDATE schema_version SET version = ? WHERE id = 1;") else {
            fatalError("Could not prepare schema_version update — migration state is untrackable")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(version))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            fatalError("Could not record schema version \(version): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// V1: Base tables (entries + settings)
    private func migrateToV1() {
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
        setSchemaVersion(1)
    }

    /// V2: Tags table + junction table, migrate existing comma-separated tags
    private func migrateToV2() {
        exec("""
            CREATE TABLE IF NOT EXISTS tags (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL
            );
            CREATE TABLE IF NOT EXISTS entry_tags (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (entry_id, tag_id)
            );
        """)

        // Migrate existing comma-separated tags to the junction table
        guard let stmt = try? prepare("SELECT id, tags FROM entries WHERE tags != '';") else {
            setSchemaVersion(2); return
        }
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
        setSchemaVersion(2)
    }

    /// V3: Full-text search index
    private func migrateToV3() {
        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
                entry_id UNINDEXED,
                title, body, tags
            );
        """)

        // Populate FTS from existing entries
        exec("""
            INSERT INTO entries_fts(entry_id, title, body, tags)
            SELECT id, title, '', tags FROM entries;
        """)
        setSchemaVersion(3)
    }

    /// V4: Attachments table
    private func migrateToV4() {
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
        setSchemaVersion(4)
    }

    /// V5: Soft-delete (trash) + archive flags, entry templates, and performance indexes.
    private func migrateToV5() {
        // `ALTER TABLE ... ADD COLUMN` fails if the column already exists; exec() logs and
        // continues, which is the behaviour we want for an idempotent migration.
        exec("ALTER TABLE entries ADD COLUMN deleted_at REAL;")
        exec("ALTER TABLE entries ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0;")
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
        """)
        seedDefaultTemplates()
        setSchemaVersion(5)
    }

    /// V6: `word_count` column so goals and sort-by-words don't need to load bodies.
    /// Backfills every existing row from its body text.
    private func migrateToV6() {
        exec("ALTER TABLE entries ADD COLUMN word_count INTEGER NOT NULL DEFAULT 0;")
        // Backfill: split body on whitespace and count tokens, matching JournalEntry.wordCount.
        guard let stmt = try? prepare("SELECT id, body FROM entries;") else {
            setSchemaVersion(6); return
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let body = String(cString: sqlite3_column_text(stmt, 1))
            let count = body.isEmpty ? 0 : body.split(whereSeparator: { $0.isWhitespace }).count
            execParameterized("UPDATE entries SET word_count = ? WHERE id = ?;",
                              String(count), id)
        }
        exec("CREATE INDEX IF NOT EXISTS idx_entries_word_count ON entries(word_count DESC);")
        setSchemaVersion(6)
    }

    /// V7: Hidden entries — `is_hidden` flag. Content is gated in the UI; main scopes still include them.
    private func migrateToV7() {
        exec("ALTER TABLE entries ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0;")
        exec("CREATE INDEX IF NOT EXISTS idx_entries_hidden ON entries(is_hidden);")
        setSchemaVersion(7)
    }

    /// V8: Encrypt entry bodies at rest. Adds `body_enc` (AES-GCM blob);
    /// plaintext `body` is migrated to it and then blanked, so the SQLite
    /// file and its auto-backups no longer carry journal text. FTS and LIKE
    /// can no longer see bodies — search re-adds decrypted-body matching in
    /// Swift (see fetchAllEntries/fetchScopes). Idempotent: blank bodies are
    /// skipped, so a re-run never double-encrypts.
    private func migrateToV8() {
        exec("ALTER TABLE entries ADD COLUMN body_enc BLOB;")
        encryptPendingBodies()
        setSchemaVersion(8)
        // The pre-migration plaintext pages stay in the file as free space
        // after the UPDATEs — VACUUM rewrites the database so the old bodies
        // are physically gone, not just logically.
        exec("VACUUM;")
    }

    /// Encrypts every entry whose `body_enc` is NULL and whose plaintext
    /// `body` is non-empty, then clears the plaintext column. Runs inside the
    /// V8 migration and can be re-invoked (encryption upgrade path).
    private func encryptPendingBodies() {
        beginTransaction()
        defer { endTransaction() }
        guard let stmt = try? prepare("SELECT id, body FROM entries WHERE body_enc IS NULL AND body != '';"),
              let upd = try? prepare("UPDATE entries SET body_enc = ?, body = '' WHERE id = ?;")
        else {
            reportError("Body encryption migration could not prepare")
            return
        }
        defer { sqlite3_finalize(stmt); sqlite3_finalize(upd) }
        var pairs: [(id: String, sealed: Data)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let body = String(cString: sqlite3_column_text(stmt, 1))
            guard let sealed = try? JournalCrypto.encryptString(body) else {
                reportError("Could not encrypt body for entry \(id) — plaintext kept")
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
            }
        }
    }

    // MARK: - Tag storage reconciliation

    /// Heals drift between the two tag storage systems: the legacy
    /// `entries.tags` comma-separated text column and the normalized
    /// `tags`/`entry_tags` junction tables (the sidebar's source of truth).
    ///
    /// The junction backfill in migrateToV2 and several historical write paths
    /// used `execParameterized`, which swallows SQL failures silently — so an
    /// entry could carry tags in its text column with no junction rows, making
    /// the sidebar count them as 0 until the entry was next edited (every
    /// saveEntry re-syncs both stores). This runs at every launch and takes the
    /// UNION of both stores per entry so neither side can lose tags, rewrites
    /// the text column from the junction table, and prunes orphaned tag rows.
    /// Idempotent by construction — a second run is a no-op. Internal (not
    /// private) so tests can drive reconciliation directly after simulating
    /// historical drift patterns.
    func reconcileTagStorage() {
        beginTransaction()
        defer { endTransaction() }
        // 1. Ensure every entry's tags exist as junction rows, from BOTH stores.
        var entryRows: [(id: String, legacy: [String], junction: [String])] = []
        guard let fetchStmt = try? prepare("""
            SELECT e.id, IFNULL(e.tags, ''),
                   IFNULL((SELECT GROUP_CONCAT(t.name, '\u{1F}')
                           FROM entry_tags et JOIN tags t ON t.id = et.tag_id
                           WHERE et.entry_id = e.id), '')
            FROM entries e;
            """) else { return }
        defer { sqlite3_finalize(fetchStmt) }
        while sqlite3_step(fetchStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(fetchStmt, 0))
            let legacyRaw = String(cString: sqlite3_column_text(fetchStmt, 1))
            let junctionRaw = String(cString: sqlite3_column_text(fetchStmt, 2))
            func parse(_ raw: String, separator: Character) -> [String] {
                raw.split(separator: separator, omittingEmptySubsequences: true)
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            // The text column is comma-separated; the junction concat uses an
            // unlikely control character so tag names may contain commas.
            entryRows.append((id,
                              parse(legacyRaw, separator: ","),
                              parse(junctionRaw, separator: "\u{1F}")))
        }

        var changedCount = 0
        for row in entryRows {
            let merged = Array(Set(row.legacy).union(row.junction)).sorted()
            // Only touch rows where at least one store disagrees with the union
            // (covers text-column-only AND junction-only drift).
            guard merged != row.junction.sorted() || merged != row.legacy.sorted() else { continue }

            // Union of both stores must exist as tag rows…
            for tag in merged {
                execParameterized("INSERT OR IGNORE INTO tags (name) VALUES (?);", tag)
            }
            // …and the junction table must carry the full merged set.
            execParameterized("DELETE FROM entry_tags WHERE entry_id = ?;", row.id)
            for tag in merged {
                execParameterized(
                    "INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) SELECT ?, id FROM tags WHERE name = ?;",
                    row.id, tag
                )
            }
            // The text column is rewritten to mirror the junction table exactly.
            execParameterized("UPDATE entries SET tags = ? WHERE id = ?;",
                              merged.joined(separator: ","), row.id)
            changedCount += 1
        }

        // 2. Prune tag rows with no links at all (incl. ones left behind when a
        //    junction write failed silently in the past).
        exec("DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM entry_tags);")

        if changedCount > 0 {
            rebuildFTS()
            print("OmegaJournal: reconciled tag storage for \(changedCount) entries")
        }
    }

    // MARK: - Trash

    /// Permanently removes trashed entries older than `trashRetentionDays`.
    func purgeExpiredTrash() {
        let cutoff = Date().addingTimeInterval(-Double(Self.trashRetentionDays) * 86_400).timeIntervalSince1970
        guard let stmt = try? prepare("SELECT id FROM entries WHERE deleted_at IS NOT NULL AND deleted_at < ?;") else { return }
        var ids: [String] = []
        sqlite3_bind_double(stmt, 1, cutoff)
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        sqlite3_finalize(stmt)
        for id in ids { hardDeleteEntry(id: id) }
    }

    // MARK: - Auto Backup

    private func autoBackup() {
        let lastBackup = getSetting("lastBackupDate", defaultValue: "")
        let formatter = ISO8601DateFormatter()
        let today = formatter.string(from: Date())

        // Backup at most once per calendar day — and only stamp the setting when
        // the backup actually succeeded, so a failed attempt (unwritable disk,
        // I/O error) is retried on the next launch instead of being skipped
        // until tomorrow.
        guard lastBackup != today else { return }
        guard backupDatabase() != nil else {
            // Failed attempts retry on the next launch; the user should know
            // today's backup didn't happen.
            reportError("Automatic backup failed — will retry on next launch")
            return
        }
        setSetting("lastBackupDate", value: today)
    }

    func backupDatabase() -> URL? {
        // Keep backups next to the live database instead of assuming the standard
        // Application Support path. For the real journal this is the same location
        // as before; under test isolation it keeps backup files inside the temp
        // directory rather than dropping them into the user's real backups folder
        // (where they could evict a genuine backup from the keep-last-7 window).
        let databaseURL = URL(fileURLWithPath: dbPath)
        let backupDir = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let filename = "omega_journal_\(formatter.string(from: Date())).sqlite3"
        let backupURL = backupDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: backupURL) // VACUUM INTO requires a fresh target

        // VACUUM INTO produces a clean hot snapshot (and compacts away freed
        // pages, so pre-encryption plaintext doesn't ride along in backup
        // files). Requires no active transaction and the target must not exist
        // — the timestamped filename guarantees that.
        let escapedPath = backupURL.path.replacingOccurrences(of: "'", with: "''")
        guard exec("VACUUM INTO '\(escapedPath)';") else {
            reportError("Backup failed: VACUUM INTO could not run")
            try? FileManager.default.removeItem(at: backupURL)
            return nil
        }

        // Seal the backup file: the hot copy would otherwise be a plaintext
        // snapshot of the database sitting beside the (body-encrypted) live DB.
        do {
            let plain = try Data(contentsOf: backupURL)
            try JournalCrypto.writeEncrypted(plain, to: backupURL)
        } catch {
            reportError("Backup encryption failed — removing partial backup: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: backupURL)
            return nil
        }

        // Clean up old backups (keep last 7)
        cleanupOldBackups(in: backupDir, keep: 7)
        return backupURL
    }

    private func cleanupOldBackups(in directory: URL, keep count: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) else { return }

        let sorted = files.filter { $0.pathExtension == "sqlite3" }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }

        for file in sorted.dropFirst(count) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - CRUD (parameterized queries throughout)

    /// Which slice of the library a fetch should look at.
    enum EntryScope {
        case active     // not trashed, not archived (includes hidden)
        case archived   // not trashed, archived (includes hidden)
        case trashed
        case all        // everything except the trash (includes hidden)
        case hidden     // hidden entries only (sidebar filter)
    }

    // Column 2 is `body_enc` (the AES-GCM blob) since V8 — rowToEntry
    // decrypts it. The legacy `body` text column is always empty on disk.
    private static let entryColumns =
        "e.id, e.title, e.body_enc, e.mood, e.tags, e.created_at, e.updated_at, e.is_pinned, e.is_favorite, e.deleted_at, e.is_archived, e.word_count, e.is_hidden"

    private func scopeClause(_ scope: EntryScope) -> String {
        switch scope {
        case .active: return "e.deleted_at IS NULL AND e.is_archived = 0"
        case .archived: return "e.deleted_at IS NULL AND e.is_archived = 1"
        case .trashed: return "e.deleted_at IS NOT NULL"
        case .all: return "e.deleted_at IS NULL"
        case .hidden: return "e.deleted_at IS NULL AND e.is_hidden = 1"
        }
    }

    private func orderClause(_ sort: SortOrder) -> String {
        switch sort {
        case .dateDesc: return "ORDER BY e.is_pinned DESC, e.created_at DESC"
        case .dateAsc: return "ORDER BY e.is_pinned DESC, e.created_at ASC"
        case .titleAsc: return "ORDER BY e.is_pinned DESC, e.title COLLATE NOCASE ASC"
        case .titleDesc: return "ORDER BY e.is_pinned DESC, e.title COLLATE NOCASE DESC"
        case .updatedDesc: return "ORDER BY e.is_pinned DESC, e.updated_at DESC"
        case .wordsDesc: return "ORDER BY e.is_pinned DESC, e.word_count DESC"
        case .moodDesc: return "ORDER BY e.is_pinned DESC, e.mood DESC, e.created_at DESC"
        }
    }

    /// FTS5 treats many punctuation characters as query syntax. Anything the user types
    /// is wrapped as a quoted prefix term so `foo("bar` can't blow up the parser.
    private func sanitizeFTSQuery(_ raw: String) -> String? {
        OmegaCore.sanitizeFTSQuery(raw)
    }

    func fetchAllEntries(search: String = "", sort: SortOrder = .dateDesc, scope: EntryScope = .active) -> [JournalEntry] {
        let orderBy = orderClause(sort)
        let scopeSQL = scopeClause(scope)

        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            let sql = "SELECT \(Self.entryColumns) FROM entries e WHERE \(scopeSQL) \(orderBy);"
            guard let stmt = try? prepare(sql) else { return [] }
            return collectEntries(stmt)
        }

        // Prefer FTS, fall back to LIKE when the query yields nothing (or can't be tokenized).
        if let ftsQuery = sanitizeFTSQuery(search) {
            let ftsSQL = """
                SELECT \(Self.entryColumns)
                FROM entries e
                INNER JOIN entries_fts f ON e.id = f.entry_id
                WHERE entries_fts MATCH ? AND \(scopeSQL)
                \(orderBy);
            """
            if let stmt = try? prepare(ftsSQL) {
                bindText(stmt, index: 1, value: ftsQuery)
                let results = collectEntries(stmt)
                if !results.isEmpty { return results }
            }
        }

        // Bodies are ciphertext on disk, so LIKE only covers title/tags here;
        // `decryptBodyMatches` re-adds decrypted-body matching in Swift.
        let likeSQL = """
            SELECT \(Self.entryColumns)
            FROM entries e
            WHERE (e.title LIKE ? OR e.tags LIKE ?) AND \(scopeSQL)
            \(orderBy);
        """
        guard let stmt = try? prepare(likeSQL) else { return [] }
        let pattern = "%\(search)%"
        bindText(stmt, index: 1, value: pattern)
        bindText(stmt, index: 2, value: pattern)
        let likeResults = collectEntries(stmt)
        if !likeResults.isEmpty {
            return decryptBodyMatches(likeResults, query: search)
        }
        // Title/tags didn't match — the hit may live in an encrypted body.
        // Scan the scope and filter on decrypted bodies in Swift.
        let allSQL = "SELECT \(Self.entryColumns) FROM entries e WHERE \(scopeSQL) \(orderBy);"
        guard let allStmt = try? prepare(allSQL) else { return [] }
        return decryptBodyMatches(collectEntries(allStmt), query: search)
    }

    /// Since V8, SQL can no longer see body text (it's ciphertext), so body
    /// matching happens here on the decrypted rows. Case-insensitive
    /// substring, mirroring the old LIKE behaviour.
    private func decryptBodyMatches(_ entries: [JournalEntry], query: String) -> [JournalEntry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.body.lowercased().contains(q) }
    }

    /// Fetches several scopes in one pass, sharing a single attachments/tags
    /// scan across all of them (reload() used to pay 2 full-table scans per
    /// scope × 4 scopes). Results are keyed by the requested scope.
    func fetchScopes(_ requests: [(scope: EntryScope, sort: SortOrder)]) -> [EntryScope: [JournalEntry]] {
        let attachments = allAttachmentsByEntry()
        let tags = allTagsByEntry()
        var result: [EntryScope: [JournalEntry]] = [:]
        result.reserveCapacity(requests.count)
        for request in requests {
            let sql = "SELECT \(Self.entryColumns) FROM entries e WHERE \(scopeClause(request.scope)) \(orderClause(request.sort));"
            guard let stmt = try? prepare(sql) else {
                result[request.scope] = []
                continue
            }
            result[request.scope] = collectEntries(stmt, preloaded: (attachments, tags))
        }
        return result
    }

    func fullTextSearch(_ query: String, scope: EntryScope = .active) -> [JournalEntry] {
        guard let ftsQuery = sanitizeFTSQuery(query) else { return [] }
        let sql = """
            SELECT \(Self.entryColumns)
            FROM entries e
            INNER JOIN entries_fts f ON e.id = f.entry_id
            WHERE entries_fts MATCH ? AND \(scopeClause(scope))
            ORDER BY rank;
        """
        guard let stmt = try? prepare(sql) else { return [] }
        bindText(stmt, index: 1, value: ftsQuery)
        return collectEntries(stmt)
    }

    func fetchEntry(id: String) -> JournalEntry? {
        let sql = "SELECT \(Self.entryColumns) FROM entries e WHERE e.id = ?;"
        guard let stmt = try? prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        if sqlite3_step(stmt) == SQLITE_ROW {
            var entry = rowToEntry(stmt)
            entry.attachments = fetchAttachments(entryId: entry.id)
            // Populate tags from the junction table (the text-column fallback in
            // rowToEntry only covers the no-junction-rows case).
            if let tags = fetchTagsForEntry(entry.id) { entry.tags = tags }
            return entry
        }
        return nil
    }

    private func collectEntries(
        _ stmt: OpaquePointer?,
        preloaded: (attachments: [String: [Attachment]], tags: [String: [String]])? = nil
    ) -> [JournalEntry] {
        defer { sqlite3_finalize(stmt) }
        var entries: [JournalEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(rowToEntry(stmt))
        }
        // Attach attachments in one pass rather than N queries. Callers that
        // fetch several scopes in a row can share one preloaded pair of maps
        // instead of re-scanning the attachments/tags tables per scope.
        let attachmentsByEntry = preloaded?.attachments ?? allAttachmentsByEntry()
        // Attach tags in one pass too — rowToEntry falls back to the text column,
        // so this batched lookup replaces it with the junction-table source of truth.
        let tagsByEntry = preloaded?.tags ?? allTagsByEntry()
        for i in entries.indices {
            entries[i].attachments = attachmentsByEntry[entries[i].id] ?? []
            if let tags = tagsByEntry[entries[i].id], !tags.isEmpty {
                entries[i].tags = tags
            }
        }
        return entries
    }

    private func rowToEntry(_ stmt: OpaquePointer?) -> JournalEntry {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let title = String(cString: sqlite3_column_text(stmt, 1))
        // V8: the body is the AES-GCM blob in column 2 (`body_enc`); the
        // legacy plaintext column is always ''. A failed decryption surfaces
        // as an empty body rather than a crash — matching a corrupted row.
        let body: String
        if let sealed = blobAt(stmt, index: 2) {
            body = (try? JournalCrypto.decryptString(sealed)) ?? ""
        } else {
            body = ""
        }
        let mood = sqlite3_column_int(stmt, 3)
        let tagsStr = String(cString: sqlite3_column_text(stmt, 4))
        let createdAt = sqlite3_column_double(stmt, 5)
        let updatedAt = sqlite3_column_double(stmt, 6)
        let isPinned = sqlite3_column_int(stmt, 7) != 0
        let isFavorite = sqlite3_column_int(stmt, 8) != 0
        let deletedAt: Date? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let isArchived = sqlite3_column_int(stmt, 10) != 0

        // In list context `collectEntries` overwrites this with the junction-table
        // result from `allTagsByEntry()`. For single-entry fetches (`fetchEntry`),
        // `fetchTagsForEntry` is called explicitly below. This text-column fallback
        // covers the rare case where the junction table has no rows yet.
        let tags = tagsStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let isHidden = sqlite3_column_int(stmt, 12) != 0

        return JournalEntry(
            id: id, title: title, body: body,
            mood: Mood(rawValue: Int(mood)) ?? .neutral,
            tags: tags,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            isPinned: isPinned, isFavorite: isFavorite,
            isArchived: isArchived, deletedAt: deletedAt,
            isHidden: isHidden,
            attachments: []
        )
    }

    func saveEntry(_ entry: JournalEntry) {
        // The row write, tag sync, and FTS update must land together — a crash
        // between them would leave the entry text, its sidebar tags, and its
        // search results disagreeing with each other.
        beginTransaction()
        defer { endTransaction() }

        let wordCount = entry.body.isEmpty ? 0 : entry.body.split(whereSeparator: { $0.isWhitespace }).count
        // Bodies are encrypted at rest (V8): the `body` column stays empty on
        // disk, the ciphertext lives in `body_enc`. FTS still indexes the
        // plaintext so search keeps working — the FTS table is part of the
        // encrypted story being "bodies not recoverable from the DB file";
        // see rebuildFTS for the residual-surface note.
        let sql = """
        INSERT INTO entries (id, title, body_enc, mood, tags, created_at, updated_at, is_pinned, is_favorite, is_archived, deleted_at, word_count, is_hidden)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, body='', body_enc=excluded.body_enc, mood=excluded.mood,
            tags=excluded.tags, updated_at=excluded.updated_at,
            is_pinned=excluded.is_pinned, is_favorite=excluded.is_favorite,
            is_archived=excluded.is_archived, deleted_at=excluded.deleted_at,
            word_count=excluded.word_count, is_hidden=excluded.is_hidden;
        """
        guard let stmt = try? prepare(sql) else {
            reportError("Save failed to prepare: \(String(cString: sqlite3_errmsg(db)))")
            flagTransactionFailure()
            return
        }
        defer { sqlite3_finalize(stmt) }
        let sealedBody: Data
        do {
            sealedBody = try JournalCrypto.encryptString(entry.body)
        } catch {
            reportError("Could not encrypt entry body — save aborted: \(error.localizedDescription)")
            flagTransactionFailure()
            return
        }
        // Placeholders follow column order: id, title, body_enc, mood, tags,
        // created_at, updated_at, is_pinned, is_favorite, is_archived,
        // deleted_at, word_count, is_hidden (1…13).
        bindText(stmt, index: 1, value: entry.id)
        bindText(stmt, index: 2, value: entry.title)
        bindBlob(stmt, index: 3, value: sealedBody)
        sqlite3_bind_int(stmt, 4, Int32(entry.mood.rawValue))
        bindText(stmt, index: 5, value: entry.tags.joined(separator: ","))
        sqlite3_bind_double(stmt, 6, entry.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, entry.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 8, entry.isPinned ? 1 : 0)
        sqlite3_bind_int(stmt, 9, entry.isFavorite ? 1 : 0)
        sqlite3_bind_int(stmt, 10, entry.isArchived ? 1 : 0)
        if let deletedAt = entry.deletedAt {
            sqlite3_bind_double(stmt, 11, deletedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        sqlite3_bind_int(stmt, 12, Int32(wordCount))
        sqlite3_bind_int(stmt, 13, entry.isHidden ? 1 : 0)
        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            reportError("Save failed: \(msg)")
            // Nothing (row, tags, FTS) should survive a failed upsert.
            flagTransactionFailure()
        }

        syncTagsForEntry(entry.id, tags: entry.tags)
        updateFTS(entry)
    }

    /// Moves an entry to the trash. Recoverable for `trashRetentionDays`.
    func trashEntry(id: String) {
        execChecked("UPDATE entries SET deleted_at = ? WHERE id = ?;", context: "Move to trash failed") { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            bindText(stmt, index: 2, value: id)
        }
    }

    /// Pulls an entry back out of the trash.
    func restoreEntry(id: String) {
        execChecked("UPDATE entries SET deleted_at = NULL WHERE id = ?;", context: "Restore failed") { stmt in
            bindText(stmt, index: 1, value: id)
        }
    }

    func setArchived(id: String, archived: Bool) {
        execChecked("UPDATE entries SET is_archived = ? WHERE id = ?;", context: "Archive failed") { stmt in
            sqlite3_bind_int(stmt, 1, archived ? 1 : 0)
            bindText(stmt, index: 2, value: id)
        }
    }

    func setHidden(id: String, hidden: Bool) {
        execChecked("UPDATE entries SET is_hidden = ? WHERE id = ?;", context: "Hide failed") { stmt in
            sqlite3_bind_int(stmt, 1, hidden ? 1 : 0)
            bindText(stmt, index: 2, value: id)
        }
    }

    /// Irreversibly removes an entry, its attachments and its search index rows.
    /// Runs as one transaction so a crash can never leave half an entry behind.
    func hardDeleteEntry(id: String) {
        beginTransaction()
        defer { endTransaction() }
        for attachment in fetchAttachments(entryId: id) {
            deleteAttachment(id: attachment.id)
        }
        execChecked("DELETE FROM entries WHERE id = ?;", context: "Delete entry failed") { stmt in
            bindText(stmt, index: 1, value: id)
        }
        execChecked("DELETE FROM entries_fts WHERE entry_id = ?;", context: "Delete entry search index failed") { stmt in
            bindText(stmt, index: 1, value: id)
        }
    }

    /// Legacy name — now a soft delete so nothing is lost by accident.
    func deleteEntry(id: String) { trashEntry(id: id) }

    func emptyTrash() {
        let ids = fetchAllEntries(scope: .trashed).map(\.id)
        for id in ids { hardDeleteEntry(id: id) }
    }

    func entryCount(scope: EntryScope = .active) -> Int {
        let sql = "SELECT COUNT(*) FROM entries e WHERE \(scopeClause(scope));"
        guard let stmt = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int(stmt, 0)) }
        return 0
    }

    /// Entry count since a timestamp — used by goal tracking.
    func entryCount(since: Date) -> Int {
        let sql = "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL AND is_archived = 0 AND created_at >= ?;"
        guard let stmt = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int(stmt, 0)) }
        return 0
    }

    /// Sum of word counts since a timestamp — used by goal tracking.
    /// Reads the stored `word_count` column so no body text is loaded.
    func wordCountSum(since: Date) -> Int {
        let sql = "SELECT COALESCE(SUM(word_count), 0) FROM entries WHERE deleted_at IS NULL AND is_archived = 0 AND created_at >= ?;"
        guard let stmt = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    // MARK: - FTS Sync

    private func updateFTS(_ entry: JournalEntry) {
        // Delete old FTS entry, insert new
        if let delStmt = try? prepare("DELETE FROM entries_fts WHERE entry_id = ?;") {
            defer { sqlite3_finalize(delStmt) }
            bindText(delStmt, index: 1, value: entry.id)
            sqlite3_step(delStmt)
        }
        // FTS stores only title/tags — indexing body would put plaintext back
        // on disk. Body search is handled by decryptBodyMatches in Swift.
        let insSQL = "INSERT INTO entries_fts(entry_id, title, body, tags) VALUES (?, '', ?, ?);"
        guard let insStmt = try? prepare(insSQL) else { return }
        defer { sqlite3_finalize(insStmt) }
        bindText(insStmt, index: 1, value: entry.id)
        bindText(insStmt, index: 2, value: entry.title)
        bindText(insStmt, index: 3, value: entry.tags.joined(separator: ","))
        sqlite3_step(insStmt)
    }

    // MARK: - Tags (junction table)

    private func syncTagsForEntry(_ entryId: String, tags: [String]) {
        // Remove old associations
        execParameterized("DELETE FROM entry_tags WHERE entry_id = ?;", entryId)

        // Add new associations
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            execParameterized("INSERT OR IGNORE INTO tags (name) VALUES (?);", trimmed)
            execParameterized(
                "INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) SELECT ?, id FROM tags WHERE name = ?;",
                entryId, trimmed
            )
        }
    }

    private func fetchTagsForEntry(_ entryId: String) -> [String]? {
        let sql = """
            SELECT t.name FROM tags t
            INNER JOIN entry_tags et ON t.id = et.tag_id
            WHERE et.entry_id = ?
            ORDER BY t.name;
        """
        guard let stmt = try? prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: entryId)
        var tags: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            tags.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return tags.isEmpty ? nil : tags
    }

    /// One query for every entry's tags, grouped by entry id — avoids N+1 when
    /// listing entries. Mirrors `allAttachmentsByEntry()`.
    func allTagsByEntry() -> [String: [String]] {
        let sql = """
            SELECT et.entry_id, t.name
            FROM entry_tags et
            INNER JOIN tags t ON t.id = et.tag_id
            ORDER BY t.name;
        """
        guard let stmt = try? prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [String: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let entryId = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            map[entryId, default: []].append(name)
        }
        return map
    }

    func allTags() -> [String] {
        let sql = "SELECT name FROM tags ORDER BY name;"
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var tags: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            tags.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return tags
    }

    func tagsWithCounts(includeHidden: Bool = true) -> [(tag: String, count: Int)] {
        // Count only active (non-trashed, non-archived) entries so the sidebar
        // tag list matches what the entry list actually shows. Archived entries
        // are excluded because they don't appear in `vm.entries` (scope .active).
        // Hidden entries are excluded while the biometric session is locked —
        // the sidebar shouldn't advertise the tags used on private entries.
        let hiddenClause = includeHidden ? "" : " AND e.is_hidden = 0"
        let sql = """
            SELECT t.name, COUNT(et.entry_id) as cnt
            FROM tags t
            INNER JOIN entry_tags et ON t.id = et.tag_id
            INNER JOIN entries e ON et.entry_id = e.id
            WHERE e.deleted_at IS NULL AND e.is_archived = 0\(hiddenClause)
            GROUP BY t.id
            ORDER BY cnt DESC, t.name;
            """
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                Int(sqlite3_column_int(stmt, 1))
            ))
        }
        return results
    }

    func renameTag(from oldName: String, to newName: String) {
        // Renaming a tag to its own name must be a no-op: the merge path below
        // deletes the old tag row, which for a self-rename is the ONLY row — it
        // would sever every junction link and destroy the tag.
        guard oldName != newName else { return }

        beginTransaction()
        defer { endTransaction() }

        // Ensure the new tag row exists (parameterized — no string interpolation).
        execParameterized("INSERT OR IGNORE INTO tags (name) VALUES (?);", newName)

        guard let oldIdStmt = try? prepare("SELECT id FROM tags WHERE name = ?;") else { return }
        defer { sqlite3_finalize(oldIdStmt) }
        bindText(oldIdStmt, index: 1, value: oldName)
        guard sqlite3_step(oldIdStmt) == SQLITE_ROW else { return }
        let oldTagId = sqlite3_column_int(oldIdStmt, 0)

        guard let newIdStmt = try? prepare("SELECT id FROM tags WHERE name = ?;") else { return }
        defer { sqlite3_finalize(newIdStmt) }
        bindText(newIdStmt, index: 1, value: newName)
        guard sqlite3_step(newIdStmt) == SQLITE_ROW else { return }
        let newTagId = sqlite3_column_int(newIdStmt, 0)

        // Re-point the junction table. `oldTagId`/`newTagId` are ints from SQLite
        // itself, so interpolation here is safe; everything user-supplied is bound.
        exec("UPDATE OR IGNORE entry_tags SET tag_id = \(newTagId) WHERE tag_id = \(oldTagId);")
        exec("DELETE FROM entry_tags WHERE tag_id = \(oldTagId);")
        exec("DELETE FROM tags WHERE id = \(oldTagId);")

        // Fix the legacy `entries.tags` text column per-entry. SQL REPLACE() does a
        // blind substring replace, so renaming "art"→"artwork" would corrupt "smart".
        // Instead, fetch each affected entry, swap the exact tag token in Swift, and
        // write it back with a parameterized UPDATE.
        guard let affectedStmt = try? prepare("SELECT entry_id FROM entry_tags WHERE tag_id = ?;") else {
            rebuildFTS(); return
        }
        defer { sqlite3_finalize(affectedStmt) }
        sqlite3_bind_int(affectedStmt, 1, newTagId)
        var affectedIds: [String] = []
        while sqlite3_step(affectedStmt) == SQLITE_ROW {
            affectedIds.append(String(cString: sqlite3_column_text(affectedStmt, 0)))
        }
        for eid in affectedIds {
            guard let e = fetchEntry(id: eid) else { continue }
            let rewritten = e.tags.map { $0 == oldName ? newName : $0 }
            execParameterized("UPDATE entries SET tags = ? WHERE id = ?;",
                              rewritten.joined(separator: ","), eid)
        }

        // Rebuild FTS to reflect the renamed tag.
        rebuildFTS()
    }

    func deleteTag(_ name: String) {
        guard let stmt = try? prepare("SELECT id FROM tags WHERE name = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }
        let tagId = sqlite3_column_int(stmt, 0)

        // Junction rows, the tag row, and every affected entry's text column
        // must change together or not at all.
        beginTransaction()
        defer { endTransaction() }

        // Collect affected entries before we sever the junction rows, so we can
        // rewrite their `entries.tags` text column afterward.
        guard let entryStmt = try? prepare("SELECT entry_id FROM entry_tags WHERE tag_id = ?;") else { return }
        defer { sqlite3_finalize(entryStmt) }
        sqlite3_bind_int(entryStmt, 1, tagId)
        var entryIds: [String] = []
        while sqlite3_step(entryStmt) == SQLITE_ROW {
            entryIds.append(String(cString: sqlite3_column_text(entryStmt, 0)))
        }

        exec("DELETE FROM entry_tags WHERE tag_id = \(tagId);")
        exec("DELETE FROM tags WHERE id = \(tagId);")

        // Rewrite the text column per-entry with a parameterized UPDATE.
        for eid in entryIds {
            guard let e = fetchEntry(id: eid) else { continue }
            let newTags = e.tags.filter { $0 != name }
            execParameterized("UPDATE entries SET tags = ? WHERE id = ?;",
                              newTags.joined(separator: ","), eid)
            if let e2 = fetchEntry(id: eid) { updateFTS(e2) }
        }
    }

    /// Rebuilds the FTS index inside a transaction — the delete+insert pair must
    /// never be observed half-applied.


    /// Rebuilds the FTS index inside a transaction — the delete+insert pair
    /// must never be observed half-applied. Since V8 the `entries` table no
    /// longer stores plaintext bodies, so the index is fed from decrypted
    /// bodies in Swift.
    private func rebuildFTS() {
        beginTransaction()
        defer { endTransaction() }
        exec("DELETE FROM entries_fts;")
        guard let stmt = try? prepare("SELECT id, title, tags, body_enc FROM entries;") else {
            reportError("FTS rebuild could not read entries")
            return
        }
        defer { sqlite3_finalize(stmt) }
        guard let insert = try? prepare("INSERT INTO entries_fts(entry_id, title, body, tags) VALUES (?, '', ?, ?);") else {
            reportError("FTS rebuild could not prepare insert")
            return
        }
        defer { sqlite3_finalize(insert) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let tags = String(cString: sqlite3_column_text(stmt, 2))
            sqlite3_reset(insert)
            bindText(insert, index: 1, value: id)
            bindText(insert, index: 2, value: title)
            bindText(insert, index: 3, value: tags)
            if sqlite3_step(insert) != SQLITE_DONE {
                reportError("FTS rebuild insert failed for \(id)")
                flagTransactionFailure()
            }
        }
    }

    // MARK: - Attachments

    /// Decrypts an attachment file for display or external opening. Returns
    /// nil if the file is missing or fails authentication (corrupted/wrong key).
    func readAttachmentData(_ attachment: Attachment) -> Data? {
        let dir = (attachmentsDir as NSString).appendingPathComponent(attachment.id)
        let filePath = (dir as NSString).appendingPathComponent(attachment.filename)
        return try? JournalCrypto.readEncrypted(from: URL(fileURLWithPath: filePath))
    }

    /// Writes a decrypted copy to a caller-managed temp file for NSWorkspace
    /// opening. The caller should remove it after use; the plaintext lives
    /// only transiently in the system temp directory.
    func openAttachmentExternally(_ attachment: Attachment) -> URL? {
        let dir = (attachmentsDir as NSString).appendingPathComponent(attachment.id)
        let filePath = (dir as NSString).appendingPathComponent(attachment.filename)
        return try? JournalCrypto.decryptedTemporaryFile(
            from: URL(fileURLWithPath: filePath),
            preferredName: attachment.filename)
    }

    func saveAttachment(entryId: String, data: Data, filename: String, mimeType: String = "") -> Attachment? {
        let id = UUID().uuidString
        let dir = (attachmentsDir as NSString).appendingPathComponent(id)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Stored encrypted (S1): the plaintext bytes never touch disk. The
        // filename is used as the on-disk name but the content is sealed.
        let filePath = (dir as NSString).appendingPathComponent(filename)
        do {
            try JournalCrypto.writeEncrypted(data, to: URL(fileURLWithPath: filePath))
        } catch {
            reportError("Failed to save attachment: \(error.localizedDescription)")
            return nil
        }

        let sql = "INSERT INTO attachments (id, entry_id, filename, mime_type, created_at) VALUES (?, ?, ?, ?, ?);"
        guard let stmt = try? prepare(sql) else {
            try? FileManager.default.removeItem(atPath: dir)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        bindText(stmt, index: 2, value: entryId)
        bindText(stmt, index: 3, value: filename)
        bindText(stmt, index: 4, value: mimeType)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            print("Attachment insert failed: \(String(cString: sqlite3_errmsg(db)))")
            // Don't leave an orphaned file behind for a row that doesn't exist.
            try? FileManager.default.removeItem(atPath: dir)
            return nil
        }

        return Attachment(id: id, entryId: entryId, filename: filename, mimeType: mimeType, createdAt: Date())
    }

    func fetchAttachments(entryId: String) -> [Attachment] {
        let sql = "SELECT id, entry_id, filename, mime_type, created_at FROM attachments WHERE entry_id = ? ORDER BY created_at;"
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: entryId)
        var attachments: [Attachment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            attachments.append(Attachment(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                entryId: String(cString: sqlite3_column_text(stmt, 1)),
                filename: String(cString: sqlite3_column_text(stmt, 2)),
                mimeType: String(cString: sqlite3_column_text(stmt, 3)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            ))
        }
        return attachments
    }

    func deleteAttachment(id: String) {
        // Delete file
        let dir = (attachmentsDir as NSString).appendingPathComponent(id)
        try? FileManager.default.removeItem(atPath: dir)

        // Delete record
        let sql = "DELETE FROM attachments WHERE id = ?;"
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            print("Attachment row delete failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    /// One query for every attachment, grouped by entry — avoids N+1 when listing entries.
    func allAttachmentsByEntry() -> [String: [Attachment]] {
        let sql = "SELECT id, entry_id, filename, mime_type, created_at FROM attachments ORDER BY created_at;"
        guard let stmt = try? prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [String: [Attachment]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let a = Attachment(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                entryId: String(cString: sqlite3_column_text(stmt, 1)),
                filename: String(cString: sqlite3_column_text(stmt, 2)),
                mimeType: String(cString: sqlite3_column_text(stmt, 3)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            )
            map[a.entryId, default: []].append(a)
        }
        return map
    }

    // MARK: - Templates

    private func seedDefaultTemplates() {
        guard templates().isEmpty else { return }
        for (i, t) in EntryTemplate.builtIns.enumerated() {
            var copy = t
            copy.sortOrder = i
            saveTemplate(copy)
        }
    }

    func templates() -> [EntryTemplate] {
        let sql = "SELECT id, name, body, tags, icon, sort_order FROM templates ORDER BY sort_order, name;"
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [EntryTemplate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tagsStr = String(cString: sqlite3_column_text(stmt, 3))
            result.append(EntryTemplate(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                body: String(cString: sqlite3_column_text(stmt, 2)),
                tags: tagsStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                icon: String(cString: sqlite3_column_text(stmt, 4)),
                sortOrder: Int(sqlite3_column_int(stmt, 5))
            ))
        }
        return result
    }

    func saveTemplate(_ template: EntryTemplate) {
        let sql = """
            INSERT INTO templates (id, name, body, tags, icon, sort_order)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name, body=excluded.body, tags=excluded.tags,
                icon=excluded.icon, sort_order=excluded.sort_order;
        """
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: template.id)
        bindText(stmt, index: 2, value: template.name)
        bindText(stmt, index: 3, value: template.body)
        bindText(stmt, index: 4, value: template.tags.joined(separator: ","))
        bindText(stmt, index: 5, value: template.icon)
        sqlite3_bind_int(stmt, 6, Int32(template.sortOrder))
        sqlite3_step(stmt)
    }

    func deleteTemplate(id: String) {
        guard let stmt = try? prepare("DELETE FROM templates WHERE id = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        sqlite3_step(stmt)
    }

    // MARK: - Settings

    func getSetting(_ key: String, defaultValue: String = "") -> String {
        let sql = "SELECT value FROM settings WHERE key = ?;"
        guard let stmt = try? prepare(sql) else { return defaultValue }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: key)
        if sqlite3_step(stmt) == SQLITE_ROW { return String(cString: sqlite3_column_text(stmt, 0)) }
        return defaultValue
    }

    func setSetting(_ key: String, value: String) {
        let sql = "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: key)
        bindText(stmt, index: 2, value: value)
        sqlite3_step(stmt)
    }

    // MARK: - Export Helpers

    /// Full export snapshot: every non-trashed entry (active + archived, hidden
    /// included) plus everything currently in the trash, so backups round-trip
    /// the complete lifecycle state.
    func fetchAllEntriesForExport() -> [JournalEntry] {
        let scopes = fetchScopes([(.all, .dateDesc), (.trashed, .dateDesc)])
        return (scopes[.all] ?? []) + (scopes[.trashed] ?? [])
    }

    var databasePath: String { dbPath }

    deinit { sqlite3_close(db) }
}
