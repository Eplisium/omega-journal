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

    private var db: OpaquePointer?
    private let dbPath: String
    private let attachmentsDir: String

    // Current schema version — bump when adding migrations
    private static let currentSchemaVersion = 5

    /// Entries stay in the trash this long before `purgeExpiredTrash()` removes them.
    static let trashRetentionDays = 30

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("OmegaJournal", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dbPath = appDir.appendingPathComponent("omega_journal.sqlite3").path
        attachmentsDir = appDir.appendingPathComponent("attachments", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: attachmentsDir, withIntermediateDirectories: true)
        openDatabase()
        runMigrations()
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

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            print("SQLite exec error: \(msg)")
        }
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
        guard let stmt = try? prepare("UPDATE schema_version SET version = ? WHERE id = 1;") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(version))
        sqlite3_step(stmt)
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
                exec("INSERT OR IGNORE INTO tags (name) VALUES ('\(escapeSQL(tag)));")
                exec("INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) SELECT '\(escapeSQL(entryId))', id FROM tags WHERE name = '\(escapeSQL(tag))';")
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
            SELECT id, title, body, tags FROM entries;
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

        // Backup once per day
        guard lastBackup != today else { return }
        _ = backupDatabase()
        setSetting("lastBackupDate", value: today)
    }

    func backupDatabase() -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let backupDir = appSupport.appendingPathComponent("OmegaJournal/backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "omega_journal_\(formatter.string(from: Date())).sqlite3"
        let backupURL = backupDir.appendingPathComponent(filename)

        // Use SQLite backup API for safe hot backup
        var backupDb: OpaquePointer?
        guard sqlite3_open(backupURL.path, &backupDb) == SQLITE_OK else { return nil }
        defer { sqlite3_close(backupDb) }

        let backup = sqlite3_backup_init(backupDb, "main", db, "main")
        guard backup != nil else { return nil }
        defer { sqlite3_backup_finish(backup) }

        let rc = sqlite3_backup_step(backup, -1)
        if rc == SQLITE_DONE {
            // Clean up old backups (keep last 7)
            cleanupOldBackups(in: backupDir, keep: 7)
            return backupURL
        }
        return nil
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
        case active     // not trashed, not archived
        case archived
        case trashed
        case all        // everything except the trash
    }

    private static let entryColumns =
        "e.id, e.title, e.body, e.mood, e.tags, e.created_at, e.updated_at, e.is_pinned, e.is_favorite, e.deleted_at, e.is_archived"

    private func scopeClause(_ scope: EntryScope) -> String {
        switch scope {
        case .active: return "e.deleted_at IS NULL AND e.is_archived = 0"
        case .archived: return "e.deleted_at IS NULL AND e.is_archived = 1"
        case .trashed: return "e.deleted_at IS NOT NULL"
        case .all: return "e.deleted_at IS NULL"
        }
    }

    private func orderClause(_ sort: SortOrder) -> String {
        switch sort {
        case .dateDesc: return "ORDER BY e.is_pinned DESC, e.created_at DESC"
        case .dateAsc: return "ORDER BY e.is_pinned DESC, e.created_at ASC"
        case .titleAsc: return "ORDER BY e.is_pinned DESC, e.title COLLATE NOCASE ASC"
        case .titleDesc: return "ORDER BY e.is_pinned DESC, e.title COLLATE NOCASE DESC"
        case .updatedDesc: return "ORDER BY e.is_pinned DESC, e.updated_at DESC"
        case .wordsDesc: return "ORDER BY e.is_pinned DESC, LENGTH(e.body) DESC"
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

        let likeSQL = """
            SELECT \(Self.entryColumns)
            FROM entries e
            WHERE (e.title LIKE ? OR e.body LIKE ? OR e.tags LIKE ?) AND \(scopeSQL)
            \(orderBy);
        """
        guard let stmt = try? prepare(likeSQL) else { return [] }
        let pattern = "%\(search)%"
        bindText(stmt, index: 1, value: pattern)
        bindText(stmt, index: 2, value: pattern)
        bindText(stmt, index: 3, value: pattern)
        return collectEntries(stmt)
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
            return entry
        }
        return nil
    }

    private func collectEntries(_ stmt: OpaquePointer?) -> [JournalEntry] {
        defer { sqlite3_finalize(stmt) }
        var entries: [JournalEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(rowToEntry(stmt))
        }
        // Attach attachments in one pass rather than N queries.
        let byEntry = allAttachmentsByEntry()
        for i in entries.indices {
            entries[i].attachments = byEntry[entries[i].id] ?? []
        }
        return entries
    }

    private func rowToEntry(_ stmt: OpaquePointer?) -> JournalEntry {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let title = String(cString: sqlite3_column_text(stmt, 1))
        let body = String(cString: sqlite3_column_text(stmt, 2))
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

        // Prefer tags from junction table if available
        let tags = fetchTagsForEntry(id) ?? tagsStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        return JournalEntry(
            id: id, title: title, body: body,
            mood: Mood(rawValue: Int(mood)) ?? .neutral,
            tags: tags,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            isPinned: isPinned, isFavorite: isFavorite,
            isArchived: isArchived, deletedAt: deletedAt,
            attachments: []
        )
    }

    func saveEntry(_ entry: JournalEntry) {
        let sql = """
        INSERT INTO entries (id, title, body, mood, tags, created_at, updated_at, is_pinned, is_favorite, is_archived, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, body=excluded.body, mood=excluded.mood,
            tags=excluded.tags, updated_at=excluded.updated_at,
            is_pinned=excluded.is_pinned, is_favorite=excluded.is_favorite,
            is_archived=excluded.is_archived, deleted_at=excluded.deleted_at;
        """
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: entry.id)
        bindText(stmt, index: 2, value: entry.title)
        bindText(stmt, index: 3, value: entry.body)
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
        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            print("Save failed: \(msg)")
        }

        syncTagsForEntry(entry.id, tags: entry.tags)
        updateFTS(entry)
    }

    /// Moves an entry to the trash. Recoverable for `trashRetentionDays`.
    func trashEntry(id: String) {
        guard let stmt = try? prepare("UPDATE entries SET deleted_at = ? WHERE id = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        bindText(stmt, index: 2, value: id)
        sqlite3_step(stmt)
    }

    /// Pulls an entry back out of the trash.
    func restoreEntry(id: String) {
        guard let stmt = try? prepare("UPDATE entries SET deleted_at = NULL WHERE id = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        sqlite3_step(stmt)
    }

    func setArchived(id: String, archived: Bool) {
        guard let stmt = try? prepare("UPDATE entries SET is_archived = ? WHERE id = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, archived ? 1 : 0)
        bindText(stmt, index: 2, value: id)
        sqlite3_step(stmt)
    }

    /// Irreversibly removes an entry, its attachments and its search index rows.
    func hardDeleteEntry(id: String) {
        for attachment in fetchAttachments(entryId: id) {
            deleteAttachment(id: attachment.id)
        }
        if let stmt = try? prepare("DELETE FROM entries WHERE id = ?;") {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: id)
            sqlite3_step(stmt)
        }
        if let ftsStmt = try? prepare("DELETE FROM entries_fts WHERE entry_id = ?;") {
            defer { sqlite3_finalize(ftsStmt) }
            bindText(ftsStmt, index: 1, value: id)
            sqlite3_step(ftsStmt)
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

    // MARK: - FTS Sync

    private func updateFTS(_ entry: JournalEntry) {
        // Delete old FTS entry, insert new
        if let delStmt = try? prepare("DELETE FROM entries_fts WHERE entry_id = ?;") {
            defer { sqlite3_finalize(delStmt) }
            bindText(delStmt, index: 1, value: entry.id)
            sqlite3_step(delStmt)
        }
        let insSQL = "INSERT INTO entries_fts(entry_id, title, body, tags) VALUES (?, ?, ?, ?);"
        guard let insStmt = try? prepare(insSQL) else { return }
        defer { sqlite3_finalize(insStmt) }
        bindText(insStmt, index: 1, value: entry.id)
        bindText(insStmt, index: 2, value: entry.title)
        bindText(insStmt, index: 3, value: entry.body)
        bindText(insStmt, index: 4, value: entry.tags.joined(separator: ","))
        sqlite3_step(insStmt)
    }

    // MARK: - Tags (junction table)

    private func syncTagsForEntry(_ entryId: String, tags: [String]) {
        // Remove old associations
        exec("DELETE FROM entry_tags WHERE entry_id = '\(escapeSQL(entryId))';")

        // Add new associations
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            exec("INSERT OR IGNORE INTO tags (name) VALUES ('\(escapeSQL(trimmed))');")
            exec("INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) SELECT '\(escapeSQL(entryId))', id FROM tags WHERE name = '\(escapeSQL(trimmed))';")
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

    func tagsWithCounts() -> [(tag: String, count: Int)] {
        let sql = """
            SELECT t.name, COUNT(et.entry_id) as cnt
            FROM tags t
            INNER JOIN entry_tags et ON t.id = et.tag_id
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
        exec("INSERT OR IGNORE INTO tags (name) VALUES ('\(escapeSQL(newName))');")
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

        // Update junction table
        exec("UPDATE OR IGNORE entry_tags SET tag_id = \(newTagId) WHERE tag_id = \(oldTagId);")
        exec("DELETE FROM entry_tags WHERE tag_id = \(oldTagId);")
        exec("DELETE FROM tags WHERE id = \(oldTagId);")

        // Update entries.tags column for compatibility
        exec("UPDATE entries SET tags = REPLACE(tags, '\(escapeSQL(oldName))', '\(escapeSQL(newName))');")

        // Rebuild FTS
        rebuildFTS()
    }

    func deleteTag(_ name: String) {
        guard let stmt = try? prepare("SELECT id FROM tags WHERE name = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }
        let tagId = sqlite3_column_int(stmt, 0)

        // Get affected entries to update their tags column
        guard let entryStmt = try? prepare("SELECT entry_id FROM entry_tags WHERE tag_id = ?;") else { return }
        defer { sqlite3_finalize(entryStmt) }
        sqlite3_bind_int(entryStmt, 1, tagId)
        var entryIds: [String] = []
        while sqlite3_step(entryStmt) == SQLITE_ROW {
            entryIds.append(String(cString: sqlite3_column_text(entryStmt, 0)))
        }

        exec("DELETE FROM entry_tags WHERE tag_id = \(tagId);")
        exec("DELETE FROM tags WHERE id = \(tagId);")

        // Update entries.tags column
        for eid in entryIds {
            if let e = fetchEntry(id: eid) {
                let newTags = e.tags.filter { $0 != name }
                exec("UPDATE entries SET tags = '\(escapeSQL(newTags.joined(separator: ",")))' WHERE id = '\(escapeSQL(eid))';")
                if let e2 = fetchEntry(id: eid) { updateFTS(e2) }
            }
        }
    }

    private func rebuildFTS() {
        exec("DELETE FROM entries_fts;")
        exec("""
            INSERT INTO entries_fts(entry_id, title, body, tags)
            SELECT id, title, body, tags FROM entries;
        """)
    }

    // MARK: - Attachments

    func saveAttachment(entryId: String, data: Data, filename: String, mimeType: String = "") -> Attachment? {
        let id = UUID().uuidString
        let dir = (attachmentsDir as NSString).appendingPathComponent(id)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let filePath = (dir as NSString).appendingPathComponent(filename)
        do {
            try data.write(to: URL(fileURLWithPath: filePath))
        } catch {
            print("Failed to save attachment: \(error)")
            return nil
        }

        let sql = "INSERT INTO attachments (id, entry_id, filename, mime_type, created_at) VALUES (?, ?, ?, ?, ?);"
        guard let stmt = try? prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        bindText(stmt, index: 2, value: entryId)
        bindText(stmt, index: 3, value: filename)
        bindText(stmt, index: 4, value: mimeType)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_step(stmt)

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
        sqlite3_step(stmt)
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

    func fetchAllEntriesForExport() -> [JournalEntry] {
        fetchAllEntries(sort: .dateDesc)
    }

    private func escapeSQL(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
    var databasePath: String { dbPath }

    deinit { sqlite3_close(db) }
}
