import Foundation
import CryptoKit
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

    /// `AND e.journal_id = '…'` for a journal-scoped fetch. Imported notebooks keep
    /// their exported ids verbatim (`travel.2025`, `o'brien`), so the id is quoted
    /// as a standard SQL string literal (`'` doubled) instead of being stripped of
    /// punctuation — stripping silently filtered such notebooks to nothing.
    /// Shared with `tagsWithCounts`, so every journal-scoped query agrees.
    func journalClause(_ journalId: String?) -> String {
        guard let journalId, !journalId.isEmpty else { return "" }
        // A NUL would truncate the SQL text; such an id can't match any row.
        guard !journalId.unicodeScalars.contains("\0") else { return " AND 0" }
        let literal = journalId.replacingOccurrences(of: "'", with: "''")
        return " AND e.journal_id = '\(literal)'"
    }

    func orderClause(_ sort: SortOrder) -> String {
        // `e.id` breaks ties so the order is fully determined: the view model
        // re-creates it in memory when it moves single rows between lists
        // (`JournalViewModel.storagePrecedes`) — keep the two in step.
        switch sort {
        case .dateDesc: return "ORDER BY e.is_pinned DESC, e.created_at DESC, e.id ASC"
        case .dateAsc: return "ORDER BY e.is_pinned DESC, e.created_at ASC, e.id ASC"
        case .titleAsc: return "ORDER BY e.is_pinned DESC, e.title COLLATE NOCASE ASC, e.id ASC"
        case .titleDesc: return "ORDER BY e.is_pinned DESC, e.title COLLATE NOCASE DESC, e.id ASC"
        case .updatedDesc: return "ORDER BY e.is_pinned DESC, e.updated_at DESC, e.id ASC"
        case .wordsDesc: return "ORDER BY e.is_pinned DESC, e.word_count DESC, e.id ASC"
        case .moodDesc: return "ORDER BY e.is_pinned DESC, e.mood DESC, e.created_at DESC, e.id ASC"
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
            guard let stmt = prepareRead(sql) else { return [] }
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
           let stmt = prepareRead("SELECT f.entry_id FROM entries_fts f WHERE entries_fts MATCH ?;") {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: ftsQuery)
            while sqlite3_step(stmt) == SQLITE_ROW {
                ftsIDs.insert(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        let allSQL = "SELECT \(Self.entryColumns) FROM entries e WHERE \(scopeSQL) \(orderBy);"
        guard let allStmt = prepareRead(allSQL) else { return [] }
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
        fetchScopesChecked(requests, journalId: journalId).entries
    }

    /// `fetchScopes` that also says which scopes could not be read in full
    /// (their list may be empty or cut short — never treat it as the truth).
    func fetchScopesChecked(_ requests: [(scope: EntryScope, sort: SortOrder)], journalId: String? = nil)
        -> (entries: [EntryScope: [JournalEntry]], failed: Set<EntryScope>) {
        let failuresBefore = readFailureCount
        let attachments = allAttachmentsByEntry()
        let tags = allTagsByEntry()
        // Without the shared maps every scope would show wrong tags/attachments.
        let mapsFailed = readFailureCount != failuresBefore
        var result: [EntryScope: [JournalEntry]] = [:]
        var failed: Set<EntryScope> = []
        result.reserveCapacity(requests.count)
        for request in requests {
            let before = readFailureCount
            let sql = "SELECT \(Self.entryColumns) FROM entries e WHERE \(scopeClause(request.scope, journalId: journalId)) \(orderClause(request.sort));"
            if let stmt = prepareRead(sql, context: "fetchScopes") {
                result[request.scope] = collectEntries(stmt, preloaded: (attachments, tags))
            } else {
                result[request.scope] = []
            }
            if mapsFailed || readFailureCount != before { failed.insert(request.scope) }
        }
        return (result, failed)
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
        guard let stmt = prepareRead(sql) else { return [] }
        bindText(stmt, index: 1, value: ftsQuery)
        return collectEntries(stmt)
    }

    /// Entry ids of FTS hits (title/tags) in rank order, scope-filtered.
    /// Nothing is decrypted: ranking only needs ids.
    func ftsRankedIds(_ query: String, scope: EntryScope = .active, journalId: String? = nil) -> [String] {
        guard let ftsQuery = sanitizeFTSQuery(query) else { return [] }
        let sql = """
            SELECT e.id
            FROM entries e
            INNER JOIN entries_fts f ON e.id = f.entry_id
            WHERE entries_fts MATCH ? AND \(scopeClause(scope, journalId: journalId))
            ORDER BY rank;
        """
        guard let stmt = prepareRead(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: ftsQuery)
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(String(cString: sqlite3_column_text(stmt, 0))) }
        return ids
    }

    /// The rows `ids`, assembled exactly like a list fetch (junction tags,
    /// attachments, batched decryption). Missing ids are simply absent.
    func fetchEntries(ids: [String]) -> [JournalEntry] {
        guard !ids.isEmpty else { return [] }
        var out: [JournalEntry] = []
        // A handful of rows: per-row lookups (indexed) instead of scanning the
        // whole attachments and tags tables. Same rows, same order either way.
        let maps: (attachments: [String: [Attachment]], tags: [String: [String]])
        if ids.count <= 32 {
            var attachments: [String: [Attachment]] = [:]
            var tags: [String: [String]] = [:]
            for id in ids {
                let a = fetchAttachments(entryId: id)
                if !a.isEmpty { attachments[id] = a }
                if let t = fetchTagsForEntry(id) { tags[id] = t }
            }
            maps = (attachments, tags)
        } else {
            maps = (allAttachmentsByEntry(), allTagsByEntry())
        }
        var start = ids.startIndex
        while start < ids.endIndex {
            let end = min(start + 500, ids.endIndex)
            let chunk = Array(ids[start..<end])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT \(Self.entryColumns) FROM entries e WHERE e.id IN (\(marks));"
            guard let stmt = prepareRead(sql) else { return out }
            for (i, id) in chunk.enumerated() { bindText(stmt, index: Int32(i + 1), value: id) }
            out += collectEntries(stmt, preloaded: maps)
            start = end
        }
        return out
    }

    func fetchEntry(id: String) -> JournalEntry? {
        let sql = "SELECT \(Self.entryColumns) FROM entries e WHERE e.id = ?;"
        let row: JournalEntry?? = withCachedRead(sql, context: "fetchEntry") { stmt -> JournalEntry? in
            bindText(stmt, index: 1, value: id)
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return rowToEntry(stmt)
            case SQLITE_DONE: return nil
            default:
                noteReadFailure("fetchEntry")
                return nil
            }
        }
        guard var entry = row ?? nil else { return nil }
        entry.attachments = fetchAttachments(entryId: entry.id)
        // Populate tags from the junction table (the text-column fallback in
        // rowToEntry only covers the no-junction-rows case).
        if let tags = fetchTagsForEntry(entry.id) { entry.tags = tags }
        return entry
    }

    func collectEntries(
        _ stmt: OpaquePointer?,
        preloaded: (attachments: [String: [Attachment]], tags: [String: [String]])? = nil
    ) -> [JournalEntry] {
        defer { sqlite3_finalize(stmt) }
        var entries: [JournalEntry] = []
        var sealedBodies: [(index: Int, sealed: Data)] = []
        // A step error (I/O, corruption) ends the list early: recorded as a
        // read failure so the caller never presents it as the whole journal.
        forEachRow(stmt, context: "collectEntries") {
            let (entry, sealed) = rowFields(stmt)
            if let sealed { sealedBodies.append((entries.count, sealed)) }
            entries.append(entry)
        }
        // Bodies are decrypted in one batch (cache hits skip AES entirely,
        // misses are opened in parallel off the main thread).
        resolveBodies(&entries, sealed: sealedBodies)
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
        var (entry, sealed) = rowFields(stmt)
        guard let sealed else { return entry }
        var one = [entry]
        resolveBodies(&one, sealed: [(0, sealed)])
        entry = one[0]
        return entry
    }

    /// Every column except the encrypted body, plus that body's ciphertext
    /// (nil for a legacy plaintext row, whose text is already in `body`).
    /// `resolveBodies` turns the ciphertext into text.
    func rowFields(_ stmt: OpaquePointer?) -> (entry: JournalEntry, sealed: Data?) {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let title = String(cString: sqlite3_column_text(stmt, 1))
        // V8: the body is the AES-GCM blob in column 2 (`body_enc`). When it is
        // NULL (a row the encryption migration hasn't converted) fall back to
        // the legacy plaintext `body` (column 13) so text is never hidden.
        // A failed decryption yields an empty body AND marks the entry
        // unreadable: saveEntry then refuses to overwrite the ciphertext.
        let sealed = blobAt(stmt, index: 2)
        let body: String
        if sealed == nil {
            unreadableEntryIds.remove(id)
            body = sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? ""
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
        return (entry, sealed)
    }

    // MARK: - Body decryption (batched, cached)

    /// Below this many cache misses the batch is opened inline; above it the
    /// AES work and word counting fan out across cores.
    static let parallelDecryptThreshold = 64

    /// Fills `entries[i].body` for every `(i, ciphertext)` pair.
    ///
    /// - A body whose ciphertext is byte-identical to the one it was last
    ///   decrypted from comes from `bodyCache` (no AES, word count kept).
    ///   AES-GCM seals with a fresh random nonce, so any rewrite of the row
    ///   — or any corruption of it — changes the bytes and misses the cache.
    /// - Misses are decrypted with the key fetched once here (on the main
    ///   actor), in parallel when there are many, and their word counts are
    ///   primed in the same pass.
    /// - A failure leaves the body empty and marks the entry unreadable,
    ///   exactly as the per-row path did, so saves never overwrite it.
    func resolveBodies(_ entries: inout [JournalEntry], sealed pairs: [(index: Int, sealed: Data)]) {
        guard !pairs.isEmpty else { return }
        var misses: [(index: Int, sealed: Data)] = []
        misses.reserveCapacity(pairs.count)
        for pair in pairs {
            let id = entries[pair.index].id
            if let cached = bodyCache[id], cached.sealed == pair.sealed {
                entries[pair.index].body = cached.body
                entries[pair.index].derived = cached.derived
                unreadableEntryIds.remove(id)
            } else {
                misses.append(pair)
            }
        }
        guard !misses.isEmpty else { return }
        let key: SymmetricKey
        do {
            key = try JournalCrypto.key()
        } catch {
            if let keyError = error as? JournalCrypto.KeyError { noteKeyError(keyError) }
            for miss in misses {
                entries[miss.index].body = ""
                unreadableEntryIds.insert(entries[miss.index].id)
            }
            return
        }
        let opened = Self.openBodies(misses.map(\.sealed), key: key,
                                     parallel: misses.count >= Self.parallelDecryptThreshold)
        for (miss, result) in zip(misses, opened) {
            let id = entries[miss.index].id
            if let result {
                entries[miss.index].body = result.body
                let memo = EntryDerivedMemo()
                memo.prime(result)
                entries[miss.index].derived = memo
                bodyCache[id] = CachedBody(sealed: miss.sealed, body: result.body, derived: memo)
                unreadableEntryIds.remove(id)
            } else {
                entries[miss.index].body = ""
                bodyCache[id] = nil
                unreadableEntryIds.insert(id)
            }
        }
    }

    /// Opens every blob with `key` (nil = could not be decrypted) and derives
    /// its memoized values (word count, image markup, search eligibility). Pure and nonisolated: runs on worker threads.
    nonisolated static func openBodies(_ blobs: [Data], key: SymmetricKey, parallel: Bool) -> [OpenedBody?] {
        guard parallel else { return blobs.map { openBody($0, key: key) } }
        var out = [OpenedBody?](repeating: nil, count: blobs.count)
        out.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let results = buffer
            let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
            let chunk = (blobs.count + workers - 1) / workers
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                let lower = worker * chunk
                let upper = min(lower + chunk, blobs.count)
                guard lower < upper else { return }
                for i in lower..<upper { results[i] = openBody(blobs[i], key: key) }
            }
        }
        return out
    }

    /// Opens one blob (nil = could not be decrypted). A static function rather
    /// than a local closure so the concurrent workers capture nothing mutable.
    nonisolated static func openBody(_ blob: Data, key: SymmetricKey) -> OpenedBody? {
        guard let text = try? JournalCrypto.decryptString(blob, using: key) else { return nil }
        return OpenedBody(body: text)
    }

    /// Drops cached plaintext for ids that are gone (hard delete) or for
    /// everything (connection reopened on another file).
    func forgetCachedBody(id: String) { bodyCache[id] = nil }
    func clearBodyCache() { bodyCache.removeAll() }

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
        let row: (exists: Bool, sealed: Data?)? = withCachedStatement("SELECT body_enc FROM entries WHERE id = ?;") { stmt in
            bindText(stmt, index: 1, value: id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (false, nil) }
            return (true, blobAt(stmt, index: 0))
        }
        guard let row, row.exists else { return (false, false) }
        guard let sealed = row.sealed else { return (true, false) }
        // The exact bytes decrypted before are readable; skip the AES pass.
        if let cached = bodyCache[id], cached.sealed == sealed { return (true, false) }
        if case .failure = decryptBody(sealed) { return (true, true) }
        return (true, false)
    }

    func performSave(_ entry: JournalEntry) {
        // The editor's count (stamp stripped, markdown word rules), so goals,
        // the goal ring and "sort by words" agree with what the user sees.
        let wordCount = entry.wordCount // memoized JournalEntry.countWords(body)
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
        let sealedBody: Data
        do {
            sealedBody = try JournalCrypto.encryptString(entry.body)
        } catch {
            if let keyError = error as? JournalCrypto.KeyError { noteKeyError(keyError) }
            reportError("Could not encrypt entry body — save aborted: \(error.localizedDescription)")
            flagTransactionFailure()
            return
        }
        let saved = withCachedStatement(sql) { stmt -> String? in
            bindEntryRow(stmt, entry, sealedBody: sealedBody, wordCount: wordCount)
            return sqlite3_step(stmt) == SQLITE_DONE ? nil : String(cString: sqlite3_errmsg(db))
        }
        switch saved {
        case nil:
            reportError("Save failed to prepare: \(String(cString: sqlite3_errmsg(db)))")
            flagTransactionFailure()
            return
        case let message??:
            reportError("Save failed: \(message)")
            // Nothing (row, tags, FTS) should survive a failed upsert.
            flagTransactionFailure()
        case .some(nil):
            // The next read of this exact ciphertext needs no AES pass. (A
            // rolled-back transaction leaves other bytes on disk: no hit.)
            if !preserveBody {
                bodyCache[entry.id] = CachedBody(sealed: sealedBody, body: entry.body, derived: entry.derived)
            }
        }

        syncTagsForEntry(entry.id, tags: entry.tags)
        updateFTS(entry)
    }

    /// Binds one `entries` upsert row (placeholders 1…14, column order).
    private func bindEntryRow(_ stmt: OpaquePointer, _ entry: JournalEntry, sealedBody: Data, wordCount: Int) {
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
        forgetCachedBody(id: id)
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
        guard let stmt = prepareRead(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int(stmt, 0)) }
        return 0
    }

    /// Start of tomorrow: goal windows end here, so an entry dated later
    /// (planned from the Calendar) never counts as written.
    static func endOfToday(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
    }

    /// WHERE clause shared by the goal aggregates: live, unarchived entries
    /// dated in `[since, until)`; hidden entries only while unlocked (locked
    /// hidden entries never contribute word counts).
    private func goalWindowClause(includeHidden: Bool) -> String {
        "deleted_at IS NULL AND is_archived = 0 AND created_at >= ? AND created_at < ?"
            + (includeHidden ? "" : " AND is_hidden = 0")
    }

    /// Entry count since a timestamp — used by goal tracking. Ends at `until`
    /// (default: end of today) and skips hidden entries unless
    /// `includeHidden` (default: the current biometric session).
    func entryCount(since: Date, until: Date? = nil,
                    includeHidden: Bool = BiometricAuth.shared.isAuthenticated) -> Int {
        goalAggregate("SELECT COUNT(*) FROM entries WHERE \(goalWindowClause(includeHidden: includeHidden));",
                      since: since, until: until ?? Self.endOfToday())
    }

    /// Sum of word counts since a timestamp — used by goal tracking and the
    /// editor goal ring. Reads the stored `word_count` column so no body text
    /// is loaded. Same window and hidden-entry rule as `entryCount(since:)`.
    func wordCountSum(since: Date, until: Date? = nil,
                      includeHidden: Bool = BiometricAuth.shared.isAuthenticated) -> Int {
        goalAggregate("SELECT COALESCE(SUM(word_count), 0) FROM entries WHERE \(goalWindowClause(includeHidden: includeHidden));",
                      since: since, until: until ?? Self.endOfToday())
    }

    private func goalAggregate(_ sql: String, since: Date, until: Date) -> Int {
        guard let stmt = prepareRead(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, until.timeIntervalSince1970)
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
        return 0
    }
}
