import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    // MARK: - Auto Backup

    var backupsDirectory: URL {
        URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
    }

    /// Local-calendar day stamp used to gate the automatic backup.
    static func backupDayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static let dailyBackupPrefix = "omega_journal_"
    static let dailyBackupsToKeep = 7

    /// Backs up at most once per calendar day. Returns whether a backup ran
    /// and succeeded. The day is only stamped after success, so a failed
    /// attempt retries on the next launch.
    @discardableResult
    func autoBackup(now: Date = Date()) -> Bool {
        let today = Self.backupDayStamp(now)
        guard getSetting("lastBackupDate", defaultValue: "") != today else { return false }
        guard backupDatabase(now: now) != nil else {
            reportError("Automatic backup failed — will retry on next launch")
            return false
        }
        setSetting("lastBackupDate", value: today)
        return true
    }

    /// Writes a sealed VACUUM INTO snapshot of the live database to `url`.
    /// NOTE: attachments are NOT included in database backups — they live as
    /// individually sealed files in the attachments directory and are never
    /// deleted by a restore.
    func snapshotDatabase(to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url) // VACUUM INTO requires a fresh target
        // VACUUM INTO produces a clean hot snapshot (and compacts away freed
        // pages, so pre-encryption plaintext doesn't ride along in backup
        // files). Requires no active transaction.
        let escapedPath = url.path.replacingOccurrences(of: "'", with: "''")
        guard exec("VACUUM INTO '\(escapedPath)';") else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        // Seal the snapshot: the hot copy would otherwise be a plaintext
        // copy of the database sitting beside the (body-encrypted) live DB.
        do {
            let plain = try Data(contentsOf: url)
            try JournalCrypto.writeEncrypted(plain, to: url)
        } catch {
            reportError("Backup encryption failed — removing partial backup: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f.string(from: date)
    }

    func backupDatabase(now: Date = Date()) -> URL? {
        // Keep backups next to the live database instead of assuming the standard
        // Application Support path (keeps test backups inside the temp dir).
        let backupDir = backupsDirectory
        let backupURL = backupDir.appendingPathComponent("\(Self.dailyBackupPrefix)\(Self.fileStamp(now)).sqlite3")
        guard snapshotDatabase(to: backupURL) else {
            reportError("Backup failed: could not write snapshot")
            return nil
        }
        cleanupOldBackups(in: backupDir, prefix: Self.dailyBackupPrefix, keep: Self.dailyBackupsToKeep)
        mirrorBackupToChosenFolder(backupURL)
        return backupURL
    }

    /// Safety snapshot taken before pending migrations run.
    func snapshotBeforeMigration(fromVersion: Int) -> Bool {
        let url = backupsDirectory.appendingPathComponent("pre-migration_v\(fromVersion)_\(Self.fileStamp(Date())).sqlite3")
        guard snapshotDatabase(to: url) else { return false }
        cleanupOldBackups(in: backupsDirectory, prefix: "pre-migration_", keep: 3)
        return true
    }

    func cleanupOldBackups(in directory: URL, prefix: String, keep count: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        let sorted = files.filter { $0.pathExtension == "sqlite3" && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for file in sorted.dropFirst(count) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Backup listing & restore

    /// Every backup/snapshot file (daily, pre-migration, pre-restore), newest first.
    func listBackups() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        ) else { return [] }
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.filter { $0.pathExtension == "sqlite3" }
            .sorted { (mtime($0), $0.lastPathComponent) > (mtime($1), $1.lastPathComponent) }
    }

    enum RestoreError: Error, LocalizedError {
        case invalid(String)
        case failed(String)
        var errorDescription: String? {
            switch self { case .invalid(let m), .failed(let m): return m }
        }
    }

    /// Replaces the live database with the contents of a backup. Validates the
    /// backup first (decrypts, integrity_check, known schema, version not
    /// newer than this app), snapshots the current database, then swaps files.
    /// On any failure the original database is put back and this throws.
    /// The caller must reload all published state afterwards. Attachments are
    /// not part of backups and are left untouched (rows in the restored
    /// database whose files no longer exist simply have no data).
    func restoreBackup(from url: URL) throws {
        guard !openFailed else { throw RestoreError.failed("The database is not open.") }
        guard transactionDepth == 0 else { throw RestoreError.failed("A write is in progress.") }
        let fm = FileManager.default

        // 1. Decrypt + stage.
        let raw: Data
        do { raw = try Data(contentsOf: url) } catch { throw RestoreError.invalid("Could not read the backup file.") }
        let plain: Data
        if raw.starts(with: Data("SQLite format 3\0".utf8)) {
            plain = raw
        } else if let opened = try? JournalCrypto.decrypt(raw) {
            plain = opened
        } else {
            throw RestoreError.invalid("The backup could not be decrypted (wrong key or corrupted file).")
        }
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let staging = dir.appendingPathComponent("restore-staging-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: staging.path + suffix) }
        }
        do { try plain.write(to: staging, options: .atomic) } catch { throw RestoreError.failed("Could not stage the backup: \(error.localizedDescription)") }

        // 2. Validate.
        try Self.validateDatabaseFile(at: staging.path, maxVersion: Self.currentSchemaVersion)

        // 3. Snapshot the current database first (bypass query_only if set).
        _ = sqlite3_exec(db, "PRAGMA query_only=OFF;", nil, nil, nil)
        let snapshotURL = backupsDirectory.appendingPathComponent("pre-restore_\(Self.fileStamp(Date())).sqlite3")
        let snapped = snapshotDatabase(to: snapshotURL)
        if isReadOnly { _ = sqlite3_exec(db, "PRAGMA query_only=ON;", nil, nil, nil) }
        guard snapped else { throw RestoreError.failed("Could not snapshot the current journal; restore cancelled.") }
        cleanupOldBackups(in: backupsDirectory, prefix: "pre-restore_", keep: 5)

        // 4. Swap.
        let aside = dbPath + ".pre-restore"
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: aside + suffix) }
        sqlite3_close(db)
        db = nil
        do {
            try fm.moveItem(atPath: dbPath, toPath: aside)
        } catch {
            openDatabase()
            throw RestoreError.failed("Could not move the current database aside: \(error.localizedDescription)")
        }
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: dbPath + suffix) }

        func rollback(_ message: String) -> RestoreError {
            sqlite3_close(db)
            db = nil
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: dbPath + suffix) }
            try? fm.moveItem(atPath: aside, toPath: dbPath)
            openDatabase()
            _ = getSchemaVersion() >= 0
            return RestoreError.failed(message)
        }

        do { try fm.moveItem(atPath: staging.path, toPath: dbPath) }
        catch { throw rollback("Could not put the backup in place: \(error.localizedDescription)") }

        openDatabase()
        if openFailed { throw rollback("The restored database could not be opened; original restored.") }
        runMigrations()
        if isReadOnly {
            let reason = startupError ?? "unknown"
            throw rollback("The restored database could not be upgraded (\(reason)); original restored.")
        }
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: aside + suffix) }
        encryptionKeyError = nil
        reconcileTagStorage()
    }

    /// Opens a database file read-only and checks it looks like a journal.
    static func validateDatabaseFile(at path: String, maxVersion: Int) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h = handle else {
            sqlite3_close(handle)
            throw RestoreError.invalid("The backup is not a valid database.")
        }
        defer { sqlite3_close(h) }
        func firstText(_ sql: String) -> String? {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { sqlite3_finalize(st); return nil }
            defer { sqlite3_finalize(st) }
            guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
            return String(cString: c)
        }
        guard firstText("PRAGMA integrity_check;") == "ok" else {
            throw RestoreError.invalid("The backup failed its integrity check.")
        }
        guard let v = firstText("SELECT version FROM schema_version WHERE id = 1;"), let version = Int(v) else {
            throw RestoreError.invalid("The backup is not an Omega Journal database.")
        }
        guard version <= maxVersion else {
            throw RestoreError.invalid("The backup was made by a newer version of Omega Journal.")
        }
        guard version >= 1, firstText("SELECT COUNT(*) FROM entries;") != nil else {
            throw RestoreError.invalid("The backup has no journal entries table.")
        }
    }

    // MARK: - Export Helpers

    /// Full export snapshot: every non-trashed entry (active + archived, hidden
    /// included) plus everything currently in the trash, so backups round-trip
    /// the complete lifecycle state.
    func fetchAllEntriesForExport() -> [JournalEntry] {
        let scopes = fetchScopes([(.all, .dateDesc), (.trashed, .dateDesc)])
        return (scopes[.all] ?? []) + (scopes[.trashed] ?? [])
    }
}
