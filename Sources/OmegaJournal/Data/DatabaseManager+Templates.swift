import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    // MARK: - Templates

    func seedDefaultTemplates() {
        guard templates().isEmpty else { return }
        for (i, t) in EntryTemplate.builtIns.enumerated() {
            var copy = t
            copy.sortOrder = i
            saveTemplate(copy)
        }
    }

    func templates() -> [EntryTemplate] {
        let sql = "SELECT id, name, body, tags, icon, sort_order FROM templates ORDER BY sort_order, name;"
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [EntryTemplate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tagsStr = String(cString: sqlite3_column_text(stmt, 3))
            result.append(EntryTemplate(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                body: String(cString: sqlite3_column_text(stmt, 2)),
                tags: tagsStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                icon: String(cString: sqlite3_column_text(stmt, 4)),
                sortOrder: Int(sqlite3_column_int(stmt, 5))
            ))
        }
        return result
    }

    @discardableResult
    func saveTemplate(_ template: EntryTemplate) -> Bool {
        let sql = """
            INSERT INTO templates (id, name, body, tags, icon, sort_order)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name, body=excluded.body, tags=excluded.tags,
                icon=excluded.icon, sort_order=excluded.sort_order;
        """
        return execChecked(sql, context: "Saving template failed") { stmt in
            bindText(stmt, index: 1, value: template.id)
            bindText(stmt, index: 2, value: template.name)
            bindText(stmt, index: 3, value: template.body)
            // Commas are the storage separator, so tags are normalised (no commas/#, no dupes) on the way in.
            bindText(stmt, index: 4, value: TemplateExpander.parseTagField(template.tags.joined(separator: ",")).joined(separator: ","))
            bindText(stmt, index: 5, value: template.icon)
            sqlite3_bind_int(stmt, 6, Int32(template.sortOrder))
        }
    }

    @discardableResult
    func deleteTemplate(id: String) -> Bool {
        execChecked("DELETE FROM templates WHERE id = ?;", context: "Deleting template failed") { stmt in
            bindText(stmt, index: 1, value: id)
        }
    }

    // MARK: - Settings

    func getSetting(_ key: String, defaultValue: String = "") -> String {
        let sql = "SELECT value FROM settings WHERE key = ?;"
        guard let stmt = try? prepare(sql) else { return defaultValue }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: key)
        if sqlite3_step(stmt) == SQLITE_ROW { return String(cString: sqlite3_column_text(stmt, 0)) }
        return defaultValue
    }

    /// Stores a setting. Returns whether the write landed (callers may ignore).
    @discardableResult
    func setSetting(_ key: String, value: String) -> Bool {
        execChecked("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                    context: "Saving setting '\(key)' failed") { stmt in
            bindText(stmt, index: 1, value: key)
            bindText(stmt, index: 2, value: value)
        }
    }
}

extension DatabaseManager {
    /// Rewrites `sort_order` to match the given id order (one transaction).
    @discardableResult
    func reorderTemplates(ids: [String]) -> Bool {
        inTransaction {
            for (i, id) in ids.enumerated() {
                execChecked("UPDATE templates SET sort_order = ? WHERE id = ?;", context: "Reordering templates failed") { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(i))
                    bindText(stmt, index: 2, value: id)
                }
            }
        }
    }
}
