import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
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
    static let entryColumns =
        "e.id, e.title, e.body_enc, e.mood, e.tags, e.created_at, e.updated_at, e.is_pinned, e.is_favorite, e.deleted_at, e.is_archived, e.word_count, e.is_hidden, e.body, e.journal_id"

    func scopeClause(_ scope: EntryScope, journalId: String? = nil) -> String {
        let base: String
        switch scope {
        case .active: base = "e.deleted_at IS NULL AND e.is_archived = 0"
        case .archived: base = "e.deleted_at IS NULL AND e.is_archived = 1"
        case .trashed: base = "e.deleted_at IS NOT NULL"
        case .all: base = "e.deleted_at IS NULL"
        case .hidden: base = "e.deleted_at IS NULL AND e.is_hidden = 1"
        }
        return base + journalClause(journalId)
    }

    /// `AND e.journal_id = '…'` for a journal-scoped fetch. Ids are app-generated
    /// (UUIDs / "default") and sanitized here, so interpolation is safe.
    func journalClause(_ journalId: String?) -> String {
        guard let journalId, !journalId.isEmpty else { return "" }
        let safe = journalId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return " AND e.journal_id = '\(safe)'"
    }

    func orderClause(_ sort: SortOrder) -> String {
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
    func sanitizeFTSQuery(_ raw: String) -> String? {
        OmegaCore.sanitizeFTSQuery(raw)
    }

    func fetchAllEntries(search: String = "", sort: SortOrder = .dateDesc, scope: EntryScope = .active, journalId: String? = nil) -> [JournalEntry] {
        let orderBy = orderClause(sort)
        let scopeSQL = scopeClause(scope, journalId: journalId)

        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            let sql = "SELECT \(Self.entryColumns) FROM entries e WHERE \(scopeSQL) \(orderBy);"
            guard let stmt = try? prepare(sql) else { return [] }
            return collectEntries(stmt)
        }

        // Bodies are ciphertext on disk, so SQL can only see title/tags. The
        // result is the UNION of (a) FTS token/prefix hits on title+tags and
        // (b) a case-insensitive substring pass over title, tags and the
        // decrypted body of the scope. Doing both every time means a body-only
        // match is never hidden by a title hit, and a mid-word title match
        // ("ournal" in "Journal") is never dropped for lacking a body match.
        var ftsIDs = Set<String>()
        if let ftsQuery = sanitizeFTSQuery(search),
           let stmt = try? prepare("SELECT f.entry_id FROM entries_fts f WHERE entries_fts MATCH ?;") {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: ftsQuery)
            while sqlite3_step(stmt) == SQLITE_ROW {
                ftsIDs.insert(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        let allSQL = "SELECT \(Self.entryColumns) FROM entries e WHERE \(scopeSQL) \(orderBy);"
        guard let allStmt = try? prepare(allSQL) else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces)
        return collectEntries(allStmt).filter { e in
            ftsIDs.contains(e.id)
                || e.title.localizedCaseInsensitiveContains(q)
                || e.tags.contains { $0.localizedCaseInsensitiveContains(q) }
                || e.body.localizedCaseInsensitiveContains(q)
        }
    }

    /// Fetches several scopes in one pass, sharing a single attachments/tags
    /// scan across all of them (reload() used to pay 2 full-table scans per
    /// scope × 4 scopes). Results are keyed by the requested scope.
    func fetchScopes(_ requests: [(scope: EntryScope, sort: SortOrder)], journalId: String? = nil) -> [EntryScope: [JournalEntry]] {
        let attachments = allAttachmentsByEntry()
        let tags = allTagsByEntry()
        var result: [EntryScope: [JournalEntry]] = [:]
        result.reserveCapacity(requests.count)
        for request in requests {
            let sql = "SELECT \(Self.entryColumns) FROM entries e WHERE \(scopeClause(request.scope, journalId: journalId)) \(orderClause(request.sort));"
            guard let stmt = try? prepare(sql) else {
                result[request.scope] = []
                continue
            }
            result[request.scope] = collectEntries(stmt, preloaded: (attachments, tags))
        }
        return result
    }

    func fullTextSearch(_ query: String, scope: EntryScope = .active, journalId: String? = nil) -> [JournalEntry] {
        guard let ftsQuery = sanitizeFTSQuery(query) else { return [] }
        let sql = """
            SELECT \(Self.entryColumns)
            FROM entries e
            INNER JOIN entries_fts f ON e.id = f.entry_id
            WHERE entries_fts MATCH ? AND \(scopeClause(scope, journalId: journalId))
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

    func collectEntries(
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

    func isEntryUnreadable(_ id: String) -> Bool { unreadableEntryIds.contains(id) }

    func decryptBody(_ sealed: Data) -> Result<String, Error> {
        do { return .success(try JournalCrypto.decryptString(sealed)) }
        catch {
            if let keyError = error as? JournalCrypto.KeyError { noteKeyError(keyError) }
            return .failure(error)
        }
    }

    func noteKeyError(_ error: JournalCrypto.KeyError) {
        guard encryptionKeyError == nil else { return }
        encryptionKeyError = error.localizedDescription
        reportError(error.localizedDescription)
    }

    func rowToEntry(_ stmt: OpaquePointer?) -> JournalEntry {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let title = String(cString: sqlite3_column_text(stmt, 1))
        // V8: the body is the AES-GCM blob in column 2 (`body_enc`). When it is
        // NULL (a row the encryption migration hasn't converted) fall back to
        // the legacy plaintext `body` (column 13) so text is never hidden.
        // A failed decryption yields an empty body AND marks the entry
        // unreadable: saveEntry then refuses to overwrite the ciphertext.
        let body: String
        if let sealed = blobAt(stmt, index: 2) {
            switch decryptBody(sealed) {
            case .success(let text):
                body = text
                unreadableEntryIds.remove(id)
            case .failure:
                body = ""
                unreadableEntryIds.insert(id)
            }
        } else {
            unreadableEntryIds.remove(id)
            body = sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? ""
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
        let journalId = sqlite3_column_text(stmt, 14).map { String(cString: $0) } ?? JournalDefaults.defaultJournalId

        var entry = JournalEntry(
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
        entry.journalId = journalId.isEmpty ? JournalDefaults.defaultJournalId : journalId
        return entry
    }

    /// Saves an entry. Source-compatible with callers that ignore the result;
    /// returns whether the write committed. Failures are also reported via
    /// `onError`.
    @discardableResult
    func saveEntry(_ entry: JournalEntry) -> Bool {
        // The row write, tag sync, and FTS update must land together — a crash
        // between them would leave the entry text, its sidebar tags, and its
        // search results disagreeing with each other.
        beginTransaction()
        performSave(entry)
        return endTransaction()
    }

    /// Throwing variant of `saveEntry` for callers that want the reason.
    func saveEntryChecked(_ entry: JournalEntry) throws {
        lastErrorMessage = nil
        if !saveEntry(entry) {
            throw SQLiteError.message(lastErrorMessage ?? "Save failed")
        }
    }

    /// Stored ciphertext for the row, and whether it is currently decryptable.
    func existingBodyState(id: String) -> (exists: Bool, unreadable: Bool) {
        guard let stmt = try? prepare("SELECT body_enc FROM entries WHERE id = ?;") else { return (false, false) }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (false, false) }
        guard let sealed = blobAt(stmt, index: 0) else { return (true, false) }
        if case .failure = decryptBody(sealed) { return (true, true) }
        return (true, false)
    }

    func performSave(_ entry: JournalEntry) {
        let wordCount = entry.body.isEmpty ? 0 : entry.body.split(whereSeparator: { $0.isWhitespace }).count
        let existing = existingBodyState(id: entry.id)
        // Never replace ciphertext we cannot read: an unreadable body loads as
        // "" and re-saving that would destroy the only copy. Metadata changes
        // still go through; the body/word_count columns are left untouched.
        let preserveBody = existing.unreadable
        if preserveBody {
            unreadableEntryIds.insert(entry.id)
            if !entry.body.isEmpty {
                reportError("This entry's stored text can't be decrypted, so the new text was NOT saved (the original is preserved). Restore the encryption key or a backup.")
            }
        }
        let sql = preserveBody ? """
        INSERT INTO entries (id, title, body_enc, mood, tags, created_at, updated_at, is_pinned, is_favorite, is_archived, deleted_at, word_count, is_hidden, journal_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, mood=excluded.mood,
            tags=excluded.tags, updated_at=excluded.updated_at,
            is_pinned=excluded.is_pinned, is_favorite=excluded.is_favorite,
            is_archived=excluded.is_archived, deleted_at=excluded.deleted_at,
            is_hidden=excluded.is_hidden, journal_id=excluded.journal_id;
        """ : """
        INSERT INTO entries (id, title, body_enc, mood, tags, created_at, updated_at, is_pinned, is_favorite, is_archived, deleted_at, word_count, is_hidden, journal_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, body='', body_enc=excluded.body_enc, mood=excluded.mood,
            tags=excluded.tags, updated_at=excluded.updated_at,
            is_pinned=excluded.is_pinned, is_favorite=excluded.is_favorite,
            is_archived=excluded.is_archived, deleted_at=excluded.deleted_at,
            word_count=excluded.word_count, is_hidden=excluded.is_hidden, journal_id=excluded.journal_id;
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
            if let keyError = error as? JournalCrypto.KeyError { noteKeyError(keyError) }
            reportError("Could not encrypt entry body — save aborted: \(error.localizedDescription)")
            flagTransactionFailure()
            return
        }
        // Placeholders follow column order: id, title, body_enc, mood, tags,
        // created_at, updated_at, is_pinned, is_favorite, is_archived,
        // deleted_at, word_count, is_hidden, journal_id (1…14).
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
        bindText(stmt, index: 14, value: entry.journalId.isEmpty ? JournalDefaults.defaultJournalId : entry.journalId)
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
        // Attachment files are removed only AFTER the outermost COMMIT (see
        // deleteAttachment / pendingFileRemovals): a rolled-back delete must
        // not have already destroyed the files its restored rows point at.
        for attachment in fetchAttachments(entryId: id) {
            deleteAttachment(id: attachment.id)
        }
        execChecked("DELETE FROM entries WHERE id = ?;", context: "Delete entry failed") { stmt in
            bindText(stmt, index: 1, value: id)
        }
        removeFTS(entryId: id)
    }

    // MARK: - Bulk operations (one transaction each)

    /// Runs `body` inside one transaction (re-entrant). Returns true only if
    /// nothing failed and COMMIT succeeded; on failure everything is rolled back.
    func inTransaction(_ body: () -> Void) -> Bool {
        beginTransaction()
        body()
        return endTransaction()
    }

    /// Sets/clears the favorite flag on many entries atomically. Metadata
    /// only — bodies are never re-read or re-encrypted. Returns how many rows
    /// changed, or nil (nothing applied) if any statement failed.
    func bulkSetFavorite(ids: [String], favorite: Bool) -> Int? {
        beginTransaction()
        var changed = 0
        for id in ids {
            let ok = execChecked("UPDATE entries SET is_favorite = ? WHERE id = ? AND is_favorite != ?;", context: "Bulk favorite failed") { stmt in
                sqlite3_bind_int(stmt, 1, favorite ? 1 : 0)
                bindText(stmt, index: 2, value: id)
                sqlite3_bind_int(stmt, 3, favorite ? 1 : 0)
            }
            if ok { changed += Int(sqlite3_changes(db)) }
        }
        return endTransaction() ? changed : nil
    }

    /// Adds a tag (case-insensitive de-dupe) to many entries atomically,
    /// keeping the text column, junction table and FTS in step. Bodies are not
    /// touched. Returns the number of entries changed, or nil on failure.
    func bulkAddTag(ids: [String], tag: String) -> Int? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        beginTransaction()
        var changed = 0
        for id in ids {
            guard let stmt = try? prepare("SELECT title FROM entries WHERE id = ?;") else { flagTransactionFailure(); continue }
            bindText(stmt, index: 1, value: id)
            let title: String? = sqlite3_step(stmt) == SQLITE_ROW ? String(cString: sqlite3_column_text(stmt, 0)) : nil
            sqlite3_finalize(stmt)
            guard let title else { continue }
            var tags = fetchTagsForEntry(id) ?? []
            if tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { continue }
            tags.append(trimmed)
            let joined = tags.joined(separator: ",")
            execChecked("UPDATE entries SET tags = ?, updated_at = ? WHERE id = ?;", context: "Bulk tag failed") { s in
                bindText(s, index: 1, value: joined)
                sqlite3_bind_double(s, 2, Date().timeIntervalSince1970)
                bindText(s, index: 3, value: id)
            }
            syncTagsForEntry(id, tags: tags)
            let probe = JournalEntry(id: id, title: title, body: "", mood: .neutral, tags: tags,
                                 createdAt: Date(), updatedAt: Date(), isPinned: false, isFavorite: false,
                                 isArchived: false, deletedAt: nil, isHidden: false, attachments: [])
            updateFTS(probe)
            changed += 1
        }
        return endTransaction() ? changed : nil
    }

    /// Moves many entries to the trash atomically.
    @discardableResult
    func bulkTrash(ids: [String]) -> Bool {
        beginTransaction()
        let now = Date().timeIntervalSince1970
        for id in ids {
            execChecked("UPDATE entries SET deleted_at = ? WHERE id = ?;", context: "Bulk trash failed") { stmt in
                sqlite3_bind_double(stmt, 1, now)
                bindText(stmt, index: 2, value: id)
            }
        }
        return endTransaction()
    }

    func emptyTrash() {
        // Ids only — decrypting every trashed body just to delete it is
        // wasteful and would be blocked by unreadable rows.
        guard let stmt = try? prepare("SELECT id FROM entries WHERE deleted_at IS NOT NULL;") else { return }
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(String(cString: sqlite3_column_text(stmt, 0))) }
        sqlite3_finalize(stmt)
        beginTransaction()
        defer { endTransaction() }
        for id in ids { hardDeleteEntry(id: id) }
    }

    func entryCount(scope: EntryScope = .active, journalId: String? = nil) -> Int {
        let sql = "SELECT COUNT(*) FROM entries e WHERE \(scopeClause(scope, journalId: journalId));"
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
}
