import Foundation
import SQLite3
import OmegaJournalCore

// MARK: - Import an existing journal folder (Mac App Store wave)
//
// Fallback for a sandboxed build whose container migration did not bring the
// old journal over: the user picks the old `OmegaJournal` folder and this
// copies its database (+ -wal/-shm), attachments and backups into the current,
// EMPTY journal. Mirrors `restoreBackup`'s close → swap → reopen → migrate
// sequence, and rolls back to the empty journal on any failure, including
// "the entries don't decrypt with this Mac's key".

extension DatabaseManager {
    enum LegacyImportError: Error, LocalizedError, Equatable {
        case notAJournalFolder
        case sameFolder
        case journalNotEmpty
        case invalidDatabase(String)
        case undecryptable
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAJournalFolder:
                return "That folder doesn't contain an Omega Journal database. Choose the \u{201C}OmegaJournal\u{201D} folder (it holds omega_journal.sqlite3)."
            case .sameFolder:
                return "That folder is the journal you're already using."
            case .journalNotEmpty:
                return "Your current journal already has entries, so nothing was imported. Importing only works into an empty journal — bring entries in with a JSON or password-protected export instead."
            case .invalidDatabase(let reason):
                return reason
            case .undecryptable:
                return "That journal is encrypted with a key this Mac's Omega Journal can't read, so nothing was imported. Open the earlier version, make a Password-Protected Export (Settings › Data), then import that file here."
            case .unavailable:
                return "The journal isn't ready for an import right now. Close any open editor and try again."
            case .failed(let reason):
                return "The import didn't finish, and your journal was left as it was. \(reason)"
            }
        }
    }

    struct LegacyImportSummary: Equatable {
        var entries: Int
        var attachments: Int
        var backups: Int
    }

    /// True when the journal holds no entries (active, archived, hidden or
    /// trashed) and no check-in data. Any failure to count counts as
    /// "not empty" — an import must never replace data it couldn't see.
    func isJournalEmptyForImport() -> Bool {
        for table in ["entries", "entry_metrics", "habit_log"] {
            guard let stmt = try? prepare("SELECT COUNT(*) FROM \(table);") else { return false }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) == 0 else { return false }
        }
        return true
    }

    /// Copies the journal in `folder` into this (empty) journal. The caller
    /// must flush pending saves first, hold security-scoped access to
    /// `folder`, and reload all published state afterwards.
    @discardableResult
    func importLegacyJournal(from folder: URL) throws -> LegacyImportSummary {
        let fm = FileManager.default
        guard !openFailed, !isReadOnly, transactionDepth == 0 else { throw LegacyImportError.unavailable }

        let dbFile = MASDataJournalLocation.databaseFileName
        guard let source = MASDataJournalLocation.journalFolder(inPicked: folder, fileExists: { fm.fileExists(atPath: $0) })
        else { throw LegacyImportError.notAJournalFolder }
        let currentDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        if source.standardizedFileURL.resolvingSymlinksInPath().path
            == currentDir.standardizedFileURL.resolvingSymlinksInPath().path {
            throw LegacyImportError.sameFolder
        }
        guard isJournalEmptyForImport() else { throw LegacyImportError.journalNotEmpty }

        // 1. Stage a copy of the source database next to ours and fold its WAL
        //    in, so the source folder is only ever read.
        let staging = currentDir.appendingPathComponent("import-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedDB = staging.appendingPathComponent(dbFile)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = source.appendingPathComponent(dbFile + suffix)
                if suffix.isEmpty || fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: URL(fileURLWithPath: stagedDB.path + suffix))
                }
            }
        } catch {
            throw LegacyImportError.invalidDatabase("Omega Journal couldn't read the journal in that folder. Make sure you chose the OmegaJournal folder and that the earlier version isn't open.")
        }
        Self.checkpointStagedDatabase(at: stagedDB.path)
        do {
            try Self.validateDatabaseFile(at: stagedDB.path, maxVersion: Self.currentSchemaVersion)
        } catch {
            let text = error.localizedDescription
            throw LegacyImportError.invalidDatabase(text.contains("newer version")
                ? "That journal was made by a newer version of Omega Journal. Update this app, then try again."
                : "The journal in that folder couldn't be opened — it may be damaged. Nothing was imported.")
        }

        // 2. Swap: put the empty journal aside, move the staged one in.
        let aside = dbPath + ".pre-import"
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: aside + suffix) }
        sqlite3_close(db)
        db = nil
        do {
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: dbPath + suffix) {
                try fm.moveItem(atPath: dbPath + suffix, toPath: aside + suffix)
            }
        } catch {
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: aside + suffix) {
                try? fm.moveItem(atPath: aside + suffix, toPath: dbPath + suffix)
            }
            openDatabase()
            throw LegacyImportError.failed("Couldn't make room for the imported journal.")
        }

        var copiedFiles: [URL] = []
        func rollback(_ error: LegacyImportError) -> LegacyImportError {
            sqlite3_close(db)
            db = nil
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: dbPath + suffix) }
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: aside + suffix) {
                try? fm.moveItem(atPath: aside + suffix, toPath: dbPath + suffix)
            }
            for url in copiedFiles.reversed() { try? fm.removeItem(at: url) }
            openDatabase()
            _ = getSchemaVersion() >= 0
            unreadableEntryIds.removeAll()
            return error
        }

        do { try fm.moveItem(atPath: stagedDB.path, toPath: dbPath) }
        catch { throw rollback(.failed("Couldn't put the imported journal in place.")) }

        // 3. Reopen + migrate, exactly like a backup restore.
        openDatabase()
        if openFailed { throw rollback(.failed("The imported journal couldn't be opened.")) }
        runMigrations()
        if isReadOnly { throw rollback(.failed("The imported journal couldn't be upgraded.")) }

        // 4. The entries must decrypt with this Mac's key, or the import would
        //    show an unreadable journal (and its backups/attachments too).
        guard encryptedBodiesDecrypt() else { throw rollback(.undecryptable) }

        // 5. Attachments and backups. Never overwrite anything already here.
        var summary = LegacyImportSummary(entries: 0, attachments: 0, backups: 0)
        do {
            summary.attachments = try Self.copyMissingItems(
                from: source.appendingPathComponent(MASDataJournalLocation.attachmentsFolderName, isDirectory: true),
                to: URL(fileURLWithPath: attachmentsDir, isDirectory: true), copied: &copiedFiles)
            summary.backups = try Self.copyMissingItems(
                from: source.appendingPathComponent("backups", isDirectory: true),
                to: backupsDirectory, copied: &copiedFiles)
        } catch {
            throw rollback(.failed("Copying attachments or backups failed."))
        }

        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: aside + suffix) }
        encryptionKeyError = nil
        reconcileTagStorage()
        summary.entries = Int(scalarInt("SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL;"))
        return summary
    }

    /// True when there are no encrypted bodies, or at least one decrypts with
    /// the current key. A wrong key fails every row; a single damaged row in
    /// an otherwise readable journal must not block the import.
    func encryptedBodiesDecrypt() -> Bool {
        guard let stmt = try? prepare("SELECT body_enc FROM entries WHERE body_enc IS NOT NULL LIMIT 50;") else { return false }
        defer { sqlite3_finalize(stmt) }
        var sawEncrypted = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sealed = blobAt(stmt, index: 0) else { continue }
            sawEncrypted = true
            if (try? JournalCrypto.decrypt(sealed)) != nil { return true }
        }
        return !sawEncrypted
    }

    private func scalarInt(_ sql: String) -> Int64 {
        guard let stmt = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    /// Folds a staged copy's WAL into its main file (closing the last
    /// connection checkpoints), so only one file needs moving.
    static func checkpointStagedDatabase(at path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return
        }
        _ = sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
        sqlite3_close(handle)
    }

    /// Recursively copies items that don't exist yet at the destination.
    /// Every created top-level item is appended to `copied` for rollback.
    /// Returns the number of files copied.
    static func copyMissingItems(from source: URL, to destination: URL, copied: inout [URL]) throws -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        if !fm.fileExists(atPath: destination.path) {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        var count = 0
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            var itemIsDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)
            if fm.fileExists(atPath: target.path) {
                if itemIsDir.boolValue { count += try copyMissingItems(from: item, to: target, copied: &copied) }
                continue
            }
            try fm.copyItem(at: item, to: target)
            copied.append(target)
            if itemIsDir.boolValue {
                count += (fm.enumerator(atPath: target.path)?.allObjects.count ?? 0)
            } else {
                count += 1
            }
        }
        return count
    }
}
