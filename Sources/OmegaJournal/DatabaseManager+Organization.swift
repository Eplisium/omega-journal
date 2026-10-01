import Foundation
import SQLite3
import OmegaJournalCore

/// A notebook. Every entry belongs to exactly one.
struct Journal: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var colorHex: String
    var sortOrder: Int
    var isDefault: Bool { id == JournalDefaults.defaultJournalId }
}

extension DatabaseManager {
    // MARK: - Journals

    func fetchJournals() -> [Journal] {
        guard tableExists("journals"),
              let stmt = try? prepare("SELECT id, name, color, sort_order FROM journals ORDER BY sort_order, created_at;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Journal] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Journal(id: String(cString: sqlite3_column_text(stmt, 0)),
                               name: String(cString: sqlite3_column_text(stmt, 1)),
                               colorHex: String(cString: sqlite3_column_text(stmt, 2)),
                               sortOrder: Int(sqlite3_column_int(stmt, 3))))
        }
        return out
    }

    @discardableResult
    func createJournal(name: String, colorHex: String = TagColors.palette[0]) -> Journal? {
        guard let clean = JournalDefaults.normalizedName(name) else { return nil }
        let existing = fetchJournals()
        guard !existing.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { return nil }
        let journal = Journal(id: UUID().uuidString, name: clean,
                              colorHex: TagColors.normalizedHex(colorHex) ?? TagColors.palette[0],
                              sortOrder: (existing.map(\.sortOrder).max() ?? 0) + 1)
        let ok = execChecked("INSERT INTO journals (id, name, color, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
                             context: "Create journal failed") { stmt in
            bindText(stmt, index: 1, value: journal.id)
            bindText(stmt, index: 2, value: journal.name)
            bindText(stmt, index: 3, value: journal.colorHex)
            sqlite3_bind_int(stmt, 4, Int32(journal.sortOrder))
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        }
        return ok ? journal : nil
    }

    @discardableResult
    func updateJournal(id: String, name: String? = nil, colorHex: String? = nil) -> Bool {
        if let name {
            guard let clean = JournalDefaults.normalizedName(name) else { return false }
            let clash = fetchJournals().contains { $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame }
            guard !clash else { return false }
            guard execChecked("UPDATE journals SET name = ? WHERE id = ?;", context: "Rename journal failed", bind: { stmt in
                bindText(stmt, index: 1, value: clean); bindText(stmt, index: 2, value: id)
            }) else { return false }
        }
        if let colorHex, let hex = TagColors.normalizedHex(colorHex) {
            guard execChecked("UPDATE journals SET color = ? WHERE id = ?;", context: "Journal color failed", bind: { stmt in
                bindText(stmt, index: 1, value: hex); bindText(stmt, index: 2, value: id)
            }) else { return false }
        }
        return true
    }

    /// Deletes a journal; its entries (including trashed ones) move to the default journal. The default journal can't be deleted.
    @discardableResult
    func deleteJournal(id: String) -> Bool {
        guard id != JournalDefaults.defaultJournalId else { return false }
        beginTransaction()
        execChecked("UPDATE entries SET journal_id = ? WHERE journal_id = ?;", context: "Move entries failed") { stmt in
            bindText(stmt, index: 1, value: JournalDefaults.defaultJournalId); bindText(stmt, index: 2, value: id)
        }
        execChecked("DELETE FROM journals WHERE id = ?;", context: "Delete journal failed") { stmt in bindText(stmt, index: 1, value: id) }
        return endTransaction()
    }

    /// Moves entries to a journal (metadata only; one transaction). Returns rows changed, nil on failure.
    func moveEntries(ids: [String], toJournal journalId: String) -> Int? {
        guard fetchJournals().contains(where: { $0.id == journalId }) else { return nil }
        beginTransaction()
        var changed = 0
        for id in ids {
            let ok = execChecked("UPDATE entries SET journal_id = ? WHERE id = ? AND journal_id != ?;", context: "Move to journal failed") { stmt in
                bindText(stmt, index: 1, value: journalId); bindText(stmt, index: 2, value: id); bindText(stmt, index: 3, value: journalId)
            }
            if ok { changed += Int(sqlite3_changes(db)) }
        }
        return endTransaction() ? changed : nil
    }

    /// Non-trashed entry counts per journal. While locked (`includeHidden == false`) hidden entries are not counted.
    func journalEntryCounts(includeHidden: Bool) -> [String: Int] {
        let hidden = includeHidden ? "" : " AND is_hidden = 0"
        guard let stmt = try? prepare("SELECT journal_id, COUNT(*) FROM entries WHERE deleted_at IS NULL\(hidden) GROUP BY journal_id;") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int(stmt, 1))
        }
        return out
    }

    func journalIdForEntry(_ id: String) -> String? {
        guard let stmt = try? prepare("SELECT journal_id FROM entries WHERE id = ?;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_text(stmt, 0).map { String(cString: $0) } : nil
    }

    // MARK: - Tag colors

    func tagColors() -> [String: String] {
        guard columnExists("tags", "color"), let stmt = try? prepare("SELECT name, color FROM tags WHERE color IS NOT NULL AND color != '';") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1))
        }
        return out
    }

    /// `hex == nil` clears the color. A tag that no entry uses has no row, so this is a no-op for it.
    @discardableResult
    func setTagColor(_ name: String, hex: String?) -> Bool {
        let value = hex.flatMap(TagColors.normalizedHex)
        if hex != nil && value == nil { return false }
        return execChecked("UPDATE tags SET color = ? WHERE name = ?;", context: "Tag color failed") { stmt in
            if let value { bindText(stmt, index: 1, value: value) } else { sqlite3_bind_null(stmt, 1) }
            bindText(stmt, index: 2, value: name)
        }
    }

    // MARK: - Nested tag rename / merge

    /// Renames `old` AND every `old/…` descendant to live under `new`. If a target tag already exists the
    /// entries are merged into it (junction links de-duplicated). The surviving tag keeps an existing color;
    /// otherwise it inherits the old one. Returns the number of tags re-pointed.
    @discardableResult
    func renameTagTree(from old: String, to newName: String) -> Int {
        guard let target = TagPath.normalize(newName), target != old else { return 0 }
        // Moving a tag beneath itself would orphan it.
        guard !(target + "/").hasPrefix(old + "/") || target == old else { return 0 }
        let colors = tagColors()
        let affected = allTagNames().filter { TagPath.renamed($0, from: old, to: target) != nil }
        guard !affected.isEmpty else { return 0 }
        beginTransaction()
        for name in affected {
            guard let dest = TagPath.renamed(name, from: old, to: target) else { continue }
            let inherited = colors[dest] == nil ? colors[name] : nil
            renameTag(from: name, to: dest)
            if let inherited { setTagColor(dest, hex: inherited) }
        }
        _ = endTransaction()
        return affected.count
    }

    func allTagNames() -> [String] {
        guard let stmt = try? prepare("SELECT name FROM tags;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    // MARK: - Smart-folder / search support

    /// Matching records for the pure matchers. Bodies are decrypted (one fetch).
    func searchRecords(scope: EntryScope = .active, journalId: String? = nil) -> [SearchQuery.Record] {
        fetchAllEntries(scope: scope, journalId: journalId).map(\.searchRecord)
    }
}

extension JournalEntry {
    var searchRecord: SearchQuery.Record {
        SearchQuery.Record(id: id, title: title, body: body, tags: tags, moodName: mood.label, moodValue: mood.rawValue,
                           createdAt: createdAt, attachmentCount: attachments.count,
                           hasImage: attachments.contains { $0.isImage } || body.contains("!["),
                           wordCount: wordCount, isHidden: isHidden)
    }
}

extension DatabaseManager {
    /// Resolves an imported journal reference to a real journal id. Unknown ids are recreated under their
    /// exported name; nil/blank references land in the default journal. Never throws away an entry's notebook.
    func ensureJournal(id: String?, name: String?) -> String {
        guard let id, !id.isEmpty else { return JournalDefaults.defaultJournalId }
        let existing = fetchJournals()
        if existing.contains(where: { $0.id == id }) { return id }
        let wanted = JournalDefaults.normalizedName(name ?? "") ?? "Imported"
        var finalName = wanted
        var n = 2
        while existing.contains(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            finalName = "\(wanted) \(n)"; n += 1
        }
        let ok = execChecked("INSERT OR IGNORE INTO journals (id, name, color, sort_order, created_at) VALUES (?, ?, ?, ?, ?);",
                             context: "Recreate journal failed") { stmt in
            bindText(stmt, index: 1, value: id)
            bindText(stmt, index: 2, value: finalName)
            bindText(stmt, index: 3, value: TagColors.palette[0])
            sqlite3_bind_int(stmt, 4, Int32((existing.map(\.sortOrder).max() ?? 0) + 1))
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        }
        return ok ? id : JournalDefaults.defaultJournalId
    }
}
