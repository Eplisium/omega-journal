import Foundation
import SQLite3
import OmegaJournalCore

// MARK: - Entry revisions (version history)

struct EntryRevision: Identifiable, Hashable {
    let id: String
    let entryId: String
    let createdAt: Date
    let title: String
    let wordCount: Int
    let isAuto: Bool

    var stamp: RevisionStamp { RevisionStamp(id: id, createdAt: createdAt, isAuto: isAuto) }
}

extension DatabaseManager {
    /// Newest first. Metadata only — bodies are decrypted on demand via `revisionBody(id:)`.
    func revisions(entryId: String) -> [EntryRevision] {
        guard tableExists("entry_revisions"),
              let stmt = try? prepare("SELECT id, entry_id, created_at, title, word_count, is_auto FROM entry_revisions WHERE entry_id = ? ORDER BY created_at DESC;")
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: entryId)
        var out: [EntryRevision] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(EntryRevision(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                entryId: String(cString: sqlite3_column_text(stmt, 1)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                title: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                wordCount: Int(sqlite3_column_int(stmt, 4)),
                isAuto: sqlite3_column_int(stmt, 5) != 0))
        }
        return out
    }

    func revisionCount(entryId: String) -> Int {
        guard let stmt = try? prepare("SELECT COUNT(*) FROM entry_revisions WHERE entry_id = ?;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: entryId)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Decrypted body of a revision; nil if missing or undecryptable.
    func revisionBody(id: String) -> String? {
        guard let stmt = try? prepare("SELECT body_enc FROM entry_revisions WHERE id = ?;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let sealed = blobAt(stmt, index: 0) else { return nil }
        if case .success(let text) = decryptBody(sealed) { return text }
        return nil
    }

    /// Takes a snapshot of `entry` following `RevisionPolicy` (skip unchanged / coalesce bursts),
    /// then prunes per the retention schedule. Returns what happened.
    @discardableResult
    func snapshotRevision(of entry: JournalEntry, isAuto: Bool = true, now: Date = Date()) -> RevisionDecision {
        guard tableExists("entry_revisions"), !isReadOnly, !isEntryUnreadable(entry.id) else { return .skip }
        let existing = revisions(entryId: entry.id)
        let latest = existing.first
        let latestText = latest.flatMap { revisionBody(id: $0.id) }
        // A title-only change is still a change worth keeping.
        let combinedNew = entry.title + "\u{1}" + entry.body
        let combinedOld = latest.flatMap { l in latestText.map { l.title + "\u{1}" + $0 } }
        var decision = RevisionPolicy.decide(latest: latest?.stamp, latestText: combinedOld,
                                             newText: combinedNew, now: now, isAuto: isAuto)
        if entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { decision = .skip }
        guard decision != .skip else { return .skip }
        guard let sealed = try? JournalCrypto.encryptString(entry.body) else { return .skip }

        let ok = inTransaction {
            if decision == .replaceLatest, let latest {
                execChecked("UPDATE entry_revisions SET created_at = ?, title = ?, body_enc = ?, word_count = ? WHERE id = ?;",
                            context: "Updating revision failed") { stmt in
                    sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
                    bindText(stmt, index: 2, value: entry.title)
                    bindBlob(stmt, index: 3, value: sealed)
                    sqlite3_bind_int(stmt, 4, Int32(MarkdownLogic.wordCount(entry.body)))
                    bindText(stmt, index: 5, value: latest.id)
                }
            } else {
                insertRevisionRow(entryId: entry.id, title: entry.title, sealedBody: sealed,
                                  wordCount: MarkdownLogic.wordCount(entry.body), isAuto: isAuto, createdAt: now)
            }
            pruneRevisions(entryId: entry.id, now: now)
        }
        return ok ? decision : .skip
    }

    @discardableResult
    func insertRevisionRow(entryId: String, title: String, sealedBody: Data, wordCount: Int,
                           isAuto: Bool, createdAt: Date) -> Bool {
        execChecked("INSERT INTO entry_revisions (id, entry_id, created_at, title, body_enc, word_count, is_auto) VALUES (?, ?, ?, ?, ?, ?, ?);",
                    context: "Saving revision failed") { stmt in
            bindText(stmt, index: 1, value: UUID().uuidString)
            bindText(stmt, index: 2, value: entryId)
            sqlite3_bind_double(stmt, 3, createdAt.timeIntervalSince1970)
            bindText(stmt, index: 4, value: title)
            bindBlob(stmt, index: 5, value: sealedBody)
            sqlite3_bind_int(stmt, 6, Int32(wordCount))
            sqlite3_bind_int(stmt, 7, isAuto ? 1 : 0)
        }
    }

    /// Imports a revision with its original timestamp (JSON import). Body is sealed here.
    @discardableResult
    func importRevision(entryId: String, title: String, body: String, createdAt: Date, isAuto: Bool) -> Bool {
        guard tableExists("entry_revisions"), let sealed = try? JournalCrypto.encryptString(body) else { return false }
        return insertRevisionRow(entryId: entryId, title: title, sealedBody: sealed,
                                 wordCount: MarkdownLogic.wordCount(body), isAuto: isAuto, createdAt: createdAt)
    }

    func pruneRevisions(entryId: String, now: Date = Date()) {
        let doomed = RevisionPolicy.idsToPrune(revisions(entryId: entryId).map(\.stamp), now: now)
        for id in doomed {
            execChecked("DELETE FROM entry_revisions WHERE id = ?;", context: "Pruning revision failed") { stmt in
                bindText(stmt, index: 1, value: id)
            }
        }
    }

    func deleteRevisions(entryId: String) {
        execChecked("DELETE FROM entry_revisions WHERE entry_id = ?;", context: "Deleting revisions failed") { stmt in
            bindText(stmt, index: 1, value: entryId)
        }
    }
}
