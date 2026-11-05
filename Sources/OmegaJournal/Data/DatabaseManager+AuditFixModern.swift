import Foundation
import SQLite3

// MARK: - Widget snapshot source (whole journal)

extension DatabaseManager {
    /// What the widget may know about one entry: when it was written and its
    /// stored word count. No title, body or tags; nothing is decrypted.
    nonisolated struct WidgetEntryRow: Equatable, Sendable {
        let id: String
        let createdAt: Date
        let wordCount: Int
    }

    /// One-row summary of the same entries as `widgetEntryRows()`. Cheap
    /// enough for ContentView's body: it changes when an entry is added,
    /// removed (trash, archive, hide), re-dated or edited, in any notebook.
    nonisolated struct WidgetStorageStamp: Hashable, Sendable {
        var count = 0
        var createdTotal = 0.0
        var updatedTotal = 0.0
        var updatedMax = 0.0
        var words = 0.0
    }

    /// The entries the widget counts: the whole journal (every notebook,
    /// whatever the sidebar shows), minus hidden, trashed and archived ones.
    private var widgetEntriesClause: String { "\(scopeClause(.active)) AND e.is_hidden = 0" }

    /// Every entry the widget counts, from stored columns only.
    func widgetEntryRows() -> [WidgetEntryRow] {
        let sql = "SELECT e.id, e.created_at, e.word_count FROM entries e WHERE \(widgetEntriesClause);"
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [WidgetEntryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = sqlite3_column_text(stmt, 0) else { continue }
            rows.append(WidgetEntryRow(id: String(cString: id),
                                       createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                       wordCount: Int(sqlite3_column_int(stmt, 2))))
        }
        return rows
    }

    func widgetStorageStamp() -> WidgetStorageStamp {
        let sql = """
        SELECT COUNT(*), TOTAL(e.created_at), TOTAL(e.updated_at), COALESCE(MAX(e.updated_at), 0), TOTAL(e.word_count)
        FROM entries e WHERE \(widgetEntriesClause);
        """
        guard let stmt = try? prepare(sql) else { return WidgetStorageStamp() }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return WidgetStorageStamp() }
        return WidgetStorageStamp(count: Int(sqlite3_column_int64(stmt, 0)),
                                  createdTotal: sqlite3_column_double(stmt, 1),
                                  updatedTotal: sqlite3_column_double(stmt, 2),
                                  updatedMax: sqlite3_column_double(stmt, 3),
                                  words: sqlite3_column_double(stmt, 4))
    }
}
