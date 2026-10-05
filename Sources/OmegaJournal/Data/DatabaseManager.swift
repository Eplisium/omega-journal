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
    var pendingErrors: [String] = []

    /// Reports a failed write. Reporting never changes control flow — inside a
    /// transaction the failure is also flagged for rollback; outside one the
    /// swallow-and-continue behaviour that tests rely on is preserved.
    func reportError(_ message: String) {
        print("OmegaJournal: \(message)")
        lastErrorMessage = message
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
    @discardableResult
    func execChecked(_ sql: String, context: String, bind: (OpaquePointer?) -> Void) -> Bool {
        guard let stmt = try? prepare(sql) else {
            reportError("\(context) failed to prepare")
            flagTransactionFailure()
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            reportError("\(context): \(String(cString: sqlite3_errmsg(db)))")
            flagTransactionFailure()
            return false
        }
        return true
    }

    var db: OpaquePointer?
    var dbPath: String
    var attachmentsDir: String

    // Current schema version — bump when adding migrations
    static let currentSchemaVersion = 12

    /// Entries stay in the trash this long before `purgeExpiredTrash()` removes them.
    static let trashRetentionDays = 30

    /// Set when the database could not be opened, is newer than this app, or a
    /// migration failed / key is unavailable. The app stays launchable; while
    /// `isReadOnly` every write is refused by SQLite (`PRAGMA query_only`).
    var startupError: String?
    /// True when writes are blocked (schema newer than app, failed migration…).
    var isReadOnly = false
    var openFailed = false
    /// Non-nil once the encryption key was found missing/unusable.
    var encryptionKeyError: String?
    /// Last error text reported (for the throwing save variant).
    var lastErrorMessage: String?

    let isPrimaryInstance: Bool

    static func defaultPaths() -> (db: String, attachments: String, isTest: Bool) {
        let fileManager = FileManager.default
        if let testPath = ProcessInfo.processInfo.environment["OMEGA_JOURNAL_TEST_DATABASE_PATH"], !testPath.isEmpty {
            // An explicit, test-only override keeps lifecycle integration tests
            // completely isolated from a person's real journal database.
            let databaseURL = URL(fileURLWithPath: testPath)
            let testRoot = databaseURL.deletingLastPathComponent()
            try? fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
            let att = ProcessInfo.processInfo.environment["OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH"]
                ?? testRoot.appendingPathComponent("attachments", isDirectory: true).path
            return (databaseURL.path, att, true)
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("OmegaJournal", isDirectory: true)
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        return (appDir.appendingPathComponent("omega_journal.sqlite3").path,
                appDir.appendingPathComponent("attachments", isDirectory: true).path, false)
    }

    init() {
        let paths = Self.defaultPaths()
        dbPath = paths.db
        attachmentsDir = paths.attachments
        isPrimaryInstance = true
        if !paths.isTest {
            // Decrypted attachment copies never outlive the session.
            JournalCrypto.installTemporaryFileCleanup()
        }
        bootstrap()
    }

    /// Opens an independent database at an explicit path (tests, tooling).
    /// The shared instance remains the only one the app uses.
    init(databasePath: String, attachmentsPath: String) {
        dbPath = databasePath
        attachmentsDir = attachmentsPath
        isPrimaryInstance = false
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: databasePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        bootstrap()
    }

    func bootstrap() {
        try? FileManager.default.createDirectory(atPath: attachmentsDir, withIntermediateDirectories: true)
        openDatabase()
        guard !openFailed else { return }
        JournalCrypto.registerEncryptedDataProbe(owner: self) { [weak self] in self?.hasEncryptedRows() ?? false }
        runMigrations()
        guard !isReadOnly else { return }
        reconcileTagStorage()
        purgeExpiredTrash()
        autoBackup()
    }

    func openDatabase() {
        openFailed = false
        isReadOnly = false
        startupError = nil
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            openFailed = true
            isReadOnly = true
            startupError = "Failed to open database: \(msg)"
            reportError(startupError!)
            return
        }
        exec("PRAGMA busy_timeout=5000;")
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA foreign_keys=ON;")
        // Deleted entry text should not linger in free pages of the file.
        exec("PRAGMA secure_delete=ON;")
    }

    /// Refuses further writes on this connection and records why.
    func enterReadOnlyMode(_ reason: String) {
        isReadOnly = true
        startupError = reason
        _ = sqlite3_exec(db, "PRAGMA query_only=ON;", nil, nil, nil)
        reportError(reason)
    }

    /// True when any row holds an encrypted body — used to refuse minting a
    /// replacement key that would orphan that data.
    func hasEncryptedRows() -> Bool {
        guard let stmt = try? prepare("SELECT 1 FROM entries WHERE body_enc IS NOT NULL LIMIT 1;") else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Entries whose stored ciphertext could not be decrypted on their last
    /// read (wrong/missing key, corruption). Their bodies show as empty in
    /// the model but the stored ciphertext is preserved by `saveEntry`.
    var unreadableEntryIds: Set<String> = []

    // MARK: - SQL Helpers

    func exec(_ sql: String) -> Bool {
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

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.message("Prepare failed: \(msg)\nSQL: \(sql)")
        }
        return stmt
    }

    func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    func bindBlob(_ stmt: OpaquePointer?, index: Int32, value: Data) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = value.withUnsafeBytes { raw in sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT) }
        if bound != SQLITE_OK {
            reportError("Blob bind failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func blobAt(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    /// Runs a one-shot statement with the given text parameters bound left-to-right
    /// (1, 2, 3…). Failures do not throw or log; inside a transaction they flag it for rollback — used for internal mutations where the
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
    var transactionDepth = 0
    /// Set when any statement fails inside the active transaction. The
    /// outermost unwind then rolls back instead of committing a partial write.
    /// Failures outside a transaction keep the historical swallow-and-continue
    /// behaviour (tests rely on simulating failed writes that way).
    var transactionFailed = false

    func flagTransactionFailure() {
        if transactionDepth > 0 { transactionFailed = true }
    }

    func beginTransaction() {
        if transactionDepth == 0 {
            pendingFileRemovals.removeAll()
            if !exec("BEGIN IMMEDIATE TRANSACTION;") { transactionFailed = true }
        }
        transactionDepth += 1
    }

    /// Files to delete once the OUTERMOST transaction has committed. Removing
    /// them inside the transaction would destroy data a rollback then restores
    /// rows for.
    var pendingFileRemovals: [String] = []

    /// Must be balanced with `beginTransaction` — wrap bodies in
    /// `defer { endTransaction() }` so early returns cannot strand an open
    /// transaction (an open one would buffer every later write uncommitted).
    /// Returns true when nothing failed: at the outermost level that means
    /// COMMIT succeeded; when nested it means no failure has been flagged yet.
    @discardableResult
    func endTransaction() -> Bool {
        guard transactionDepth > 0 else { return true }
        transactionDepth -= 1
        guard transactionDepth == 0 else { return !transactionFailed }
        var committed = false
        if transactionFailed {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        } else {
            committed = sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
            if !committed {
                reportError("Commit failed: \(String(cString: sqlite3_errmsg(db)))")
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }
        transactionFailed = false
        let files = pendingFileRemovals
        pendingFileRemovals.removeAll()
        if committed {
            for path in files { try? FileManager.default.removeItem(atPath: path) }
        }
        return committed
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

    /// Overwrites a row's ciphertext (simulates corruption / wrong key).
    func corruptBodyForTesting(id: String) {
        execChecked("UPDATE entries SET body_enc = ? WHERE id = ?;", context: "corrupt") { stmt in
            bindBlob(stmt, index: 1, value: Data(repeating: 0xAB, count: 64))
            bindText(stmt, index: 2, value: id)
        }
    }

    func rawBodyEncForTesting(id: String) -> Data? {
        guard let stmt = try? prepare("SELECT body_enc FROM entries WHERE id = ?;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return blobAt(stmt, index: 0)
    }

    func scalarIntForTesting(_ sql: String) -> Int {
        guard let stmt = try? prepare(sql) else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
    }

    func setSchemaVersionForTesting(_ v: Int) { _ = setSchemaVersion(v) }

    func setAttachmentsDirectoryForTesting(_ path: String) {
        attachmentsDir = path
    }
    #endif


    var databasePath: String { dbPath }

    deinit {
        JournalCrypto.unregisterEncryptedDataProbe(owner: self)
        sqlite3_close(db)
    }
}
