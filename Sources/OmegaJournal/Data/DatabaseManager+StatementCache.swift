import Foundation
import SQLite3

// MARK: - Prepared-statement cache
//
// Hot paths (saving an entry, its tags and search-index row; reading one
// entry, its tags and attachments) used to compile the same SQL on every
// call. They now check a prepared statement out of this cache instead.
//
// Rules:
// - Checkout resets the statement and clears its bindings; check-in (the end
//   of `withCachedStatement`) resets it again, so a cached statement is never
//   left mid-step holding a read snapshot or a lock.
// - A statement already checked out (re-entrant use of the same SQL) is not
//   shared: the nested caller gets a one-off statement that is finalized.
// - Every cached statement is finalized before the connection closes
//   (`closeConnection()`); `sqlite3_close` refuses to close a connection with
//   live statements.
// - SQLite re-prepares a cached statement by itself after a schema change.

extension DatabaseManager {
    /// Upper bound on cached statements (only constant hot-path SQL is cached).
    static let statementCacheLimit = 64

    /// Runs `body` with a prepared statement for `sql`: cached when possible,
    /// reset and unbound before and after. Returns nil if it couldn't be
    /// prepared (the caller reports that as it did for `prepare`).
    func withCachedStatement<T>(_ sql: String, _ body: (OpaquePointer) -> T) -> T? {
        if statementsInUse.contains(sql) {
            // Re-entrant: never reset a statement another caller is stepping.
            guard let stmt = (try? prepare(sql)) ?? nil else { return nil }
            defer { sqlite3_finalize(stmt) }
            return body(stmt)
        }
        guard let stmt = checkOutStatement(sql) else { return nil }
        statementsInUse.insert(sql)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            statementsInUse.remove(sql)
        }
        return body(stmt)
    }

    private func checkOutStatement(_ sql: String) -> OpaquePointer? {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            statementCacheHits += 1
            return cached
        }
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK,
              let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        if statementCache.count >= Self.statementCacheLimit { finalizeCachedStatements(keepInUse: true) }
        statementCache[sql] = stmt
        return stmt
    }

    /// Finalizes every cached statement (before closing or reopening the
    /// connection). `keepInUse` spares statements a caller is stepping.
    func finalizeCachedStatements(keepInUse: Bool = false) {
        for (sql, stmt) in statementCache where !(keepInUse && statementsInUse.contains(sql)) {
            sqlite3_finalize(stmt)
            statementCache[sql] = nil
        }
    }

    /// Closes the connection after finalizing cached statements.
    func closeConnection() {
        finalizeCachedStatements()
        sqlite3_close(db)
        db = nil
    }

    /// `withCachedStatement` for a read path: a statement that can't be
    /// prepared is recorded as a read failure (see `noteReadFailure`).
    func withCachedRead<T>(_ sql: String, context: String = #function, _ body: (OpaquePointer) -> T) -> T? {
        let result = withCachedStatement(sql, body)
        if result == nil { noteReadFailure(context) }
        return result
    }

    /// `execParameterized` through the statement cache (hot writes).
    func execParameterizedCached(_ sql: String, _ values: String...) {
        let ok = withCachedStatement(sql) { stmt -> Bool in
            for (i, v) in values.enumerated() { bindText(stmt, index: Int32(i + 1), value: v) }
            return sqlite3_step(stmt) == SQLITE_DONE
        }
        if ok != true { flagTransactionFailure() }
    }

    /// `execChecked` through the statement cache (hot writes).
    @discardableResult
    func execCheckedCached(_ sql: String, context: String, bind: (OpaquePointer?) -> Void) -> Bool {
        // nil = done; otherwise SQLite's message, read before the reset.
        let outcome = withCachedStatement(sql) { stmt -> String? in
            bind(stmt)
            return sqlite3_step(stmt) == SQLITE_DONE ? nil : String(cString: sqlite3_errmsg(db))
        }
        switch outcome {
        case nil:
            reportError("\(context) failed to prepare")
            flagTransactionFailure()
            return false
        case let message??:
            reportError("\(context): \(message)")
            flagTransactionFailure()
            return false
        case .some(nil):
            return true
        }
    }
}
