import Foundation
import SQLite3
import OmegaJournalCore

// MARK: - Backup UX support (chosen folder, verification, integrity)

struct BackupInfo: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let date: Date
    let bytes: Int64
    let isExternal: Bool
    var kind: String {
        let n = url.lastPathComponent
        if n.hasPrefix("pre-migration_") { return "Before upgrade" }
        if n.hasPrefix("pre-restore_") { return "Before restore" }
        return "Daily backup"
    }
}

struct BackupVerification: Equatable {
    let entryCount: Int
    let schemaVersion: Int
}

extension DatabaseManager {
    static let backupFolderKey = "backupFolderPath"

    /// User-chosen extra backup destination (iCloud Drive, external disk…), if set and present.
    var chosenBackupFolder: URL? {
        let path = getSetting(Self.backupFolderKey, defaultValue: "")
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func setChosenBackupFolder(_ url: URL?) {
        setSetting(Self.backupFolderKey, value: url?.path ?? "")
    }

    /// Copies a freshly written daily backup into the chosen folder and prunes old copies there.
    /// Failure never fails the local backup — it is reported and the local copy stands.
    func mirrorBackupToChosenFolder(_ source: URL) {
        guard let folder = chosenBackupFolder else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(source.lastPathComponent)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: source, to: dest)
            cleanupOldBackups(in: folder, prefix: Self.dailyBackupPrefix, keep: Self.dailyBackupsToKeep * 4)
        } catch {
            reportError("Couldn't copy the backup to “\(folder.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    /// Takes a backup right now (local + chosen folder). Returns the local file.
    @discardableResult
    func backupNow() -> URL? { backupDatabase(now: Date()) }

    /// Local and chosen-folder backups, newest first.
    func backupInfos() -> [BackupInfo] {
        func infos(in dir: URL, external: Bool) -> [BackupInfo] {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles)
            else { return [] }
            return files.filter { $0.pathExtension == "sqlite3" }.map { url in
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return BackupInfo(url: url, date: v?.contentModificationDate ?? .distantPast,
                                  bytes: Int64(v?.fileSize ?? 0), isExternal: external)
            }
        }
        var all = infos(in: backupsDirectory, external: false)
        if let folder = chosenBackupFolder { all += infos(in: folder, external: true) }
        return all.sorted { $0.date > $1.date }
    }

    /// Decrypts and validates a backup without touching the live database.
    func verifyBackup(at url: URL) throws -> BackupVerification {
        let fm = FileManager.default
        let raw: Data
        do { raw = try Data(contentsOf: url) } catch { throw RestoreError.invalid("Could not read the backup file.") }
        let plain: Data
        if raw.starts(with: Data("SQLite format 3\0".utf8)) { plain = raw }
        else if let opened = try? JournalCrypto.decrypt(raw) { plain = opened }
        else { throw RestoreError.invalid("The backup could not be decrypted (wrong key or corrupted file).") }
        let tmp = fm.temporaryDirectory.appendingPathComponent("verify-\(UUID().uuidString).sqlite3")
        defer { for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: tmp.path + suffix) } }
        try plain.write(to: tmp, options: .atomic)
        try Self.validateDatabaseFile(at: tmp.path, maxVersion: Self.currentSchemaVersion)
        var h: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle = h else {
            sqlite3_close(h); throw RestoreError.invalid("The backup is not a valid database.")
        }
        defer { sqlite3_close(handle) }
        func int(_ sql: String) -> Int {
            var st: OpaquePointer?
            defer { sqlite3_finalize(st) }
            guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(st, 0))
        }
        return BackupVerification(entryCount: int("SELECT COUNT(*) FROM entries;"),
                                  schemaVersion: int("SELECT version FROM schema_version WHERE id = 1;"))
    }

    /// `PRAGMA integrity_check` + `foreign_key_check` on the live database. "ok" when healthy.
    func integrityReport() -> (ok: Bool, details: [String]) {
        var lines: [String] = []
        if let stmt = try? prepare("PRAGMA integrity_check;") {
            while sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) { lines.append(String(cString: c)) }
            sqlite3_finalize(stmt)
        } else { lines.append("Could not run the integrity check.") }
        let healthy = lines == ["ok"]
        if let stmt = try? prepare("PRAGMA foreign_key_check;") {
            var violations = 0
            while sqlite3_step(stmt) == SQLITE_ROW { violations += 1 }
            sqlite3_finalize(stmt)
            if violations > 0 { lines.append("\(violations) broken reference(s) found.") }
            return (healthy && violations == 0, lines)
        }
        return (healthy, lines)
    }
}
