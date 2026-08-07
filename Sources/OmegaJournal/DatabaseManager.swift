import Foundation
import SQLite3

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

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("OmegaJournal", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dbPath = appDir.appendingPathComponent("omega_journal.sqlite3").path
        openDatabase()
        createTables()
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            fatalError("Failed to open database: \(msg)")
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            print("SQLite exec error: \(msg)")
        }
    }

    private func createTables() {
        let schema = """
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
        """
        exec(schema)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.message("Prepare failed: \(msg)\nSQL: \(sql)")
        }
        return stmt
    }

    // MARK: - CRUD

    func fetchAllEntries(search: String = "", sort: SortOrder = .dateDesc) -> [JournalEntry] {
        var entries: [JournalEntry] = []
        let orderBy: String
        switch sort {
        case .dateDesc: orderBy = "ORDER BY is_pinned DESC, created_at DESC"
        case .dateAsc: orderBy = "ORDER BY is_pinned DESC, created_at ASC"
        case .titleAsc: orderBy = "ORDER BY is_pinned DESC, title ASC COLLATE NOCASE"
        case .titleDesc: orderBy = "ORDER BY is_pinned DESC, title DESC COLLATE NOCASE"
        }
        let whereClause = search.isEmpty ? "" : "WHERE title LIKE '%\(escapeSQL(search))%' OR body LIKE '%\(escapeSQL(search))%' OR tags LIKE '%\(escapeSQL(search))%'"
        let sql = "SELECT id, title, body, mood, tags, created_at, updated_at, is_pinned, is_favorite FROM entries \(whereClause) \(orderBy);"
        guard let stmt = try? prepare(sql) else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(rowToEntry(stmt))
        }
        sqlite3_finalize(stmt)
        return entries
    }

    func fetchEntry(id: String) -> JournalEntry? {
        let sql = "SELECT id, title, body, mood, tags, created_at, updated_at, is_pinned, is_favorite FROM entries WHERE id = ?;"
        guard let stmt = try? prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW { return rowToEntry(stmt) }
        return nil
    }

    private func rowToEntry(_ stmt: OpaquePointer?) -> JournalEntry {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let title = String(cString: sqlite3_column_text(stmt, 1))
        let body = String(cString: sqlite3_column_text(stmt, 2))
        let mood = sqlite3_column_int(stmt, 3)
        let tags = String(cString: sqlite3_column_text(stmt, 4))
        let createdAt = sqlite3_column_double(stmt, 5)
        let updatedAt = sqlite3_column_double(stmt, 6)
        let isPinned = sqlite3_column_int(stmt, 7) != 0
        let isFavorite = sqlite3_column_int(stmt, 8) != 0
        return JournalEntry(
            id: id, title: title, body: body,
            mood: Mood(rawValue: Int(mood)) ?? .neutral,
            tags: tags.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            isPinned: isPinned, isFavorite: isFavorite
        )
    }

    func saveEntry(_ entry: JournalEntry) {
        let sql = """
        INSERT INTO entries (id, title, body, mood, tags, created_at, updated_at, is_pinned, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, body=excluded.body, mood=excluded.mood,
            tags=excluded.tags, updated_at=excluded.updated_at,
            is_pinned=excluded.is_pinned, is_favorite=excluded.is_favorite;
        """
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, entry.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, entry.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, entry.body, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, Int32(entry.mood.rawValue))
        sqlite3_bind_text(stmt, 5, entry.tags.joined(separator: ","), -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, entry.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, entry.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 8, entry.isPinned ? 1 : 0)
        sqlite3_bind_int(stmt, 9, entry.isFavorite ? 1 : 0)
        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            print("Save failed: \(msg)")
        }
    }

    func deleteEntry(id: String) {
        let sql = "DELETE FROM entries WHERE id = ?;"
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    func entryCount() -> Int {
        let sql = "SELECT COUNT(*) FROM entries;"
        guard let stmt = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int(stmt, 0)) }
        return 0
    }

    func getSetting(_ key: String, defaultValue: String = "") -> String {
        let sql = "SELECT value FROM settings WHERE key = ?;"
        guard let stmt = try? prepare(sql) else { return defaultValue }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW { return String(cString: sqlite3_column_text(stmt, 0)) }
        return defaultValue
    }

    func setSetting(_ key: String, value: String) {
        let sql = "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    private func escapeSQL(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
    var databasePath: String { dbPath }

    deinit { sqlite3_close(db) }
}
