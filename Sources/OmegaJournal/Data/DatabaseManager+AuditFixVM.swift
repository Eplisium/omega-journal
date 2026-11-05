import Foundation
import SQLite3

extension DatabaseManager {
    // MARK: - Scoped Empty Trash

    /// Permanently deletes exactly the given entries — but only rows that are
    /// still in Trash — with their attachments and search rows, in one
    /// transaction (all or nothing). A stale id that has since been restored
    /// is skipped, never destroyed. Returns how many entries were deleted, or
    /// nil if anything failed (everything rolled back).
    func hardDeleteTrashedEntries(ids: [String]) -> Int? {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return 0 }
        var deleted = 0
        let ok = inTransaction {
            guard let stmt = try? prepare("SELECT id FROM entries WHERE deleted_at IS NOT NULL;") else {
                flagTransactionFailure()
                return
            }
            var targets: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                if wanted.contains(id) { targets.append(id) }
            }
            sqlite3_finalize(stmt)
            for id in targets { hardDeleteEntry(id: id) }
            deleted = targets.count
        }
        return ok ? deleted : nil
    }
}
