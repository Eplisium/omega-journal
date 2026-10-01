import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    // MARK: - Tag storage reconciliation

    /// Heals drift between the two tag storage systems: the legacy
    /// `entries.tags` comma-separated text column and the normalized
    /// `tags`/`entry_tags` junction tables (the sidebar's source of truth).
    ///
    /// The junction backfill in migrateToV2 and several historical write paths
    /// used `execParameterized`, which swallows SQL failures silently — so an
    /// entry could carry tags in its text column with no junction rows, making
    /// the sidebar count them as 0 until the entry was next edited (every
    /// saveEntry re-syncs both stores). This runs at every launch and takes the
    /// UNION of both stores per entry so neither side can lose tags, rewrites
    /// the text column from the junction table, and prunes orphaned tag rows.
    /// Idempotent by construction — a second run is a no-op. Internal (not
    /// private) so tests can drive reconciliation directly after simulating
    /// historical drift patterns.
    func reconcileTagStorage() {
        beginTransaction()
        defer { endTransaction() }
        // 1. Ensure every entry's tags exist as junction rows, from BOTH stores.
        var entryRows: [(id: String, legacy: [String], junction: [String])] = []
        guard let fetchStmt = try? prepare("""
            SELECT e.id, IFNULL(e.tags, ''),
                   IFNULL((SELECT GROUP_CONCAT(t.name, '\u{1F}')
                           FROM entry_tags et JOIN tags t ON t.id = et.tag_id
                           WHERE et.entry_id = e.id), '')
            FROM entries e;
            """) else { return }
        defer { sqlite3_finalize(fetchStmt) }
        while sqlite3_step(fetchStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(fetchStmt, 0))
            let legacyRaw = String(cString: sqlite3_column_text(fetchStmt, 1))
            let junctionRaw = String(cString: sqlite3_column_text(fetchStmt, 2))
            func parse(_ raw: String, separator: Character) -> [String] {
                raw.split(separator: separator, omittingEmptySubsequences: true)
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            // The text column is comma-separated; the junction concat uses an
            // unlikely control character so tag names may contain commas.
            entryRows.append((id,
                              parse(legacyRaw, separator: ","),
                              parse(junctionRaw, separator: "\u{1F}")))
        }

        var changedCount = 0
        for row in entryRows {
            let merged = Array(Set(row.legacy).union(row.junction)).sorted()
            // Only touch rows where at least one store disagrees with the union
            // (covers text-column-only AND junction-only drift).
            guard merged != row.junction.sorted() || merged != row.legacy.sorted() else { continue }

            // Union of both stores must exist as tag rows…
            for tag in merged {
                execParameterized("INSERT OR IGNORE INTO tags (name) VALUES (?);", tag)
            }
            // …and the junction table must carry the full merged set.
            execParameterized("DELETE FROM entry_tags WHERE entry_id = ?;", row.id)
            for tag in merged {
                execParameterized(
                    "INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) SELECT ?, id FROM tags WHERE name = ?;",
                    row.id, tag
                )
            }
            // The text column is rewritten to mirror the junction table exactly.
            execParameterized("UPDATE entries SET tags = ? WHERE id = ?;",
                              merged.joined(separator: ","), row.id)
            changedCount += 1
        }

        // 2. Prune tag rows with no links at all (incl. ones left behind when a
        //    junction write failed silently in the past).
        exec("DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM entry_tags);")

        if changedCount > 0 {
            rebuildFTS()
            print("OmegaJournal: reconciled tag storage for \(changedCount) entries")
        }
    }

    // MARK: - Tags (junction table)

    func syncTagsForEntry(_ entryId: String, tags: [String]) {
        // Remove old associations
        execParameterized("DELETE FROM entry_tags WHERE entry_id = ?;", entryId)

        // Add new associations
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            execParameterized("INSERT OR IGNORE INTO tags (name) VALUES (?);", trimmed)
            execParameterized(
                "INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) SELECT ?, id FROM tags WHERE name = ?;",
                entryId, trimmed
            )
        }
    }

    func fetchTagsForEntry(_ entryId: String) -> [String]? {
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

    /// One query for every entry's tags, grouped by entry id — avoids N+1 when
    /// listing entries. Mirrors `allAttachmentsByEntry()`.
    func allTagsByEntry() -> [String: [String]] {
        let sql = """
            SELECT et.entry_id, t.name
            FROM entry_tags et
            INNER JOIN tags t ON t.id = et.tag_id
            ORDER BY t.name;
        """
        guard let stmt = try? prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [String: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let entryId = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            map[entryId, default: []].append(name)
        }
        return map
    }

    func tagsWithCounts(includeHidden: Bool = true, journalId: String? = nil) -> [(tag: String, count: Int)] {
        // Count only active (non-trashed, non-archived) entries so the sidebar
        // tag list matches what the entry list actually shows. Archived entries
        // are excluded because they don't appear in `vm.entries` (scope .active).
        // Hidden entries are excluded while the biometric session is locked —
        // the sidebar shouldn't advertise the tags used on private entries.
        let hiddenClause = (includeHidden ? "" : " AND e.is_hidden = 0") + journalClause(journalId)
        let sql = """
            SELECT t.name, COUNT(et.entry_id) as cnt
            FROM tags t
            INNER JOIN entry_tags et ON t.id = et.tag_id
            INNER JOIN entries e ON et.entry_id = e.id
            WHERE e.deleted_at IS NULL AND e.is_archived = 0\(hiddenClause)
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
        // Renaming a tag to its own name must be a no-op: the merge path below
        // deletes the old tag row, which for a self-rename is the ONLY row — it
        // would sever every junction link and destroy the tag.
        guard oldName != newName else { return }

        beginTransaction()
        defer { endTransaction() }

        // Ensure the new tag row exists (parameterized — no string interpolation).
        execParameterized("INSERT OR IGNORE INTO tags (name) VALUES (?);", newName)

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

        // Re-point the junction table. `oldTagId`/`newTagId` are ints from SQLite
        // itself, so interpolation here is safe; everything user-supplied is bound.
        exec("UPDATE OR IGNORE entry_tags SET tag_id = \(newTagId) WHERE tag_id = \(oldTagId);")
        exec("DELETE FROM entry_tags WHERE tag_id = \(oldTagId);")
        exec("DELETE FROM tags WHERE id = \(oldTagId);")

        // Fix the legacy `entries.tags` text column per-entry. SQL REPLACE() does a
        // blind substring replace, so renaming "art"→"artwork" would corrupt "smart".
        // Instead, fetch each affected entry, swap the exact tag token in Swift, and
        // write it back with a parameterized UPDATE.
        guard let affectedStmt = try? prepare("SELECT entry_id FROM entry_tags WHERE tag_id = ?;") else {
            rebuildFTS(); return
        }
        defer { sqlite3_finalize(affectedStmt) }
        sqlite3_bind_int(affectedStmt, 1, newTagId)
        var affectedIds: [String] = []
        while sqlite3_step(affectedStmt) == SQLITE_ROW {
            affectedIds.append(String(cString: sqlite3_column_text(affectedStmt, 0)))
        }
        for eid in affectedIds {
            guard let e = fetchEntry(id: eid) else { continue }
            let rewritten = e.tags.map { $0 == oldName ? newName : $0 }
            execParameterized("UPDATE entries SET tags = ? WHERE id = ?;",
                              rewritten.joined(separator: ","), eid)
        }

        // Rebuild FTS to reflect the renamed tag.
        rebuildFTS()
    }

    func deleteTag(_ name: String) {
        guard let stmt = try? prepare("SELECT id FROM tags WHERE name = ?;") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }
        let tagId = sqlite3_column_int(stmt, 0)

        // Junction rows, the tag row, and every affected entry's text column
        // must change together or not at all.
        beginTransaction()
        defer { endTransaction() }

        // Collect affected entries before we sever the junction rows, so we can
        // rewrite their `entries.tags` text column afterward.
        guard let entryStmt = try? prepare("SELECT entry_id FROM entry_tags WHERE tag_id = ?;") else { return }
        defer { sqlite3_finalize(entryStmt) }
        sqlite3_bind_int(entryStmt, 1, tagId)
        var entryIds: [String] = []
        while sqlite3_step(entryStmt) == SQLITE_ROW {
            entryIds.append(String(cString: sqlite3_column_text(entryStmt, 0)))
        }

        exec("DELETE FROM entry_tags WHERE tag_id = \(tagId);")
        exec("DELETE FROM tags WHERE id = \(tagId);")

        // Rewrite the text column per-entry with a parameterized UPDATE.
        for eid in entryIds {
            guard let e = fetchEntry(id: eid) else { continue }
            let newTags = e.tags.filter { $0 != name }
            execParameterized("UPDATE entries SET tags = ? WHERE id = ?;",
                              newTags.joined(separator: ","), eid)
            if let e2 = fetchEntry(id: eid) { updateFTS(e2) }
        }
    }

    /// Rebuilds the FTS index inside a transaction — the delete+insert pair
    /// must never be observed half-applied. Since V8 bodies are ciphertext, so
    /// the index only carries title and tags.
    func rebuildFTS() {
        reindexFTS()
    }
}
