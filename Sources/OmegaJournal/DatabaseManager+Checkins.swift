import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    // MARK: - Metrics

    func fetchMetrics(includeArchived: Bool = false) -> [CheckinMetric] {
        guard tableExists("metrics"),
              let stmt = try? prepare("SELECT id, name, kind, unit, icon, sort_order, is_builtin FROM metrics\(includeArchived ? "" : " WHERE is_archived = 0") ORDER BY sort_order, name;")
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [CheckinMetric] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(CheckinMetric(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                kind: CheckinMetricKind(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .scale,
                unit: String(cString: sqlite3_column_text(stmt, 3)),
                sortOrder: Int(sqlite3_column_int(stmt, 5)),
                isBuiltin: sqlite3_column_int(stmt, 6) != 0,
                icon: String(cString: sqlite3_column_text(stmt, 4))))
        }
        return out
    }

    @discardableResult
    func addMetric(name: String, kind: CheckinMetricKind, unit: String) -> CheckinMetric? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let order = (fetchMetrics(includeArchived: true).map(\.sortOrder).max() ?? -1) + 1
        let metric = CheckinMetric(id: UUID().uuidString, name: String(clean.prefix(40)), kind: kind,
                                   unit: unit.trimmingCharacters(in: .whitespaces), sortOrder: order, icon: "circle.dotted")
        let ok = execChecked("INSERT INTO metrics (id, name, kind, unit, icon, sort_order, is_builtin) VALUES (?, ?, ?, ?, ?, ?, 0);",
                             context: "Adding metric failed") { stmt in
            bindText(stmt, index: 1, value: metric.id)
            bindText(stmt, index: 2, value: metric.name)
            bindText(stmt, index: 3, value: metric.kind.rawValue)
            bindText(stmt, index: 4, value: metric.unit)
            bindText(stmt, index: 5, value: metric.icon)
            sqlite3_bind_int(stmt, 6, Int32(metric.sortOrder))
        }
        return ok ? metric : nil
    }

    /// Built-in metrics are archived (hidden), custom ones deleted with their values.
    @discardableResult
    func removeMetric(id: String) -> Bool {
        let builtin = fetchMetrics(includeArchived: true).first { $0.id == id }?.isBuiltin ?? false
        if builtin {
            return execChecked("UPDATE metrics SET is_archived = 1 WHERE id = ?;", context: "Archiving metric failed") { bindText($0, index: 1, value: id) }
        }
        beginTransaction()
        execChecked("DELETE FROM entry_metrics WHERE metric_id = ?;", context: "Deleting metric values failed") { bindText($0, index: 1, value: id) }
        execChecked("DELETE FROM metrics WHERE id = ?;", context: "Deleting metric failed") { bindText($0, index: 1, value: id) }
        return endTransaction()
    }

    // MARK: - Values

    /// Sets (or with `nil` clears) one metric on one day.
    @discardableResult
    func setCheckinValue(day: String, metricId: String, value: Double?) -> Bool {
        guard let value else {
            return execChecked("DELETE FROM entry_metrics WHERE day = ? AND metric_id = ?;", context: "Clearing check-in failed") { stmt in
                bindText(stmt, index: 1, value: day); bindText(stmt, index: 2, value: metricId)
            }
        }
        return execChecked("""
            INSERT INTO entry_metrics (day, metric_id, value, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(day, metric_id) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
            """, context: "Saving check-in failed") { stmt in
            bindText(stmt, index: 1, value: day)
            bindText(stmt, index: 2, value: metricId)
            sqlite3_bind_double(stmt, 3, value)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        }
    }

    func fetchCheckinValues(fromDay: String? = nil) -> [CheckinValue] {
        guard tableExists("entry_metrics") else { return [] }
        let sql = "SELECT day, metric_id, value FROM entry_metrics" + (fromDay == nil ? "" : " WHERE day >= ?") + " ORDER BY day;"
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let fromDay { bindText(stmt, index: 1, value: fromDay) }
        var out: [CheckinValue] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(CheckinValue(day: String(cString: sqlite3_column_text(stmt, 0)),
                                    metricId: String(cString: sqlite3_column_text(stmt, 1)),
                                    value: sqlite3_column_double(stmt, 2)))
        }
        return out
    }

    // MARK: - Habits

    func fetchHabits(includeArchived: Bool = false) -> [Habit] {
        guard tableExists("habits"),
              let stmt = try? prepare("SELECT id, name, icon, sort_order, is_archived FROM habits\(includeArchived ? "" : " WHERE is_archived = 0") ORDER BY sort_order, created_at;")
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Habit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Habit(id: String(cString: sqlite3_column_text(stmt, 0)),
                             name: String(cString: sqlite3_column_text(stmt, 1)),
                             icon: String(cString: sqlite3_column_text(stmt, 2)),
                             sortOrder: Int(sqlite3_column_int(stmt, 3)),
                             isArchived: sqlite3_column_int(stmt, 4) != 0))
        }
        return out
    }

    @discardableResult
    func addHabit(name: String, icon: String = "checkmark.circle") -> Habit? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let order = (fetchHabits(includeArchived: true).map(\.sortOrder).max() ?? -1) + 1
        let habit = Habit(id: UUID().uuidString, name: String(clean.prefix(40)), icon: icon, sortOrder: order)
        let ok = execChecked("INSERT INTO habits (id, name, icon, sort_order, is_archived, created_at) VALUES (?, ?, ?, ?, 0, ?);",
                             context: "Adding habit failed") { stmt in
            bindText(stmt, index: 1, value: habit.id)
            bindText(stmt, index: 2, value: habit.name)
            bindText(stmt, index: 3, value: habit.icon)
            sqlite3_bind_int(stmt, 4, Int32(habit.sortOrder))
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        }
        return ok ? habit : nil
    }

    @discardableResult
    func archiveHabit(id: String, archived: Bool = true) -> Bool {
        execChecked("UPDATE habits SET is_archived = ? WHERE id = ?;", context: "Archiving habit failed") { stmt in
            sqlite3_bind_int(stmt, 1, archived ? 1 : 0); bindText(stmt, index: 2, value: id)
        }
    }

    @discardableResult
    func deleteHabit(id: String) -> Bool {
        beginTransaction()
        execChecked("DELETE FROM habit_log WHERE habit_id = ?;", context: "Deleting habit log failed") { bindText($0, index: 1, value: id) }
        execChecked("DELETE FROM habits WHERE id = ?;", context: "Deleting habit failed") { bindText($0, index: 1, value: id) }
        return endTransaction()
    }

    @discardableResult
    func setHabitDone(habitId: String, day: String, done: Bool) -> Bool {
        if done {
            return execChecked("INSERT OR IGNORE INTO habit_log (habit_id, day) VALUES (?, ?);", context: "Logging habit failed") { stmt in
                bindText(stmt, index: 1, value: habitId); bindText(stmt, index: 2, value: day)
            }
        }
        return execChecked("DELETE FROM habit_log WHERE habit_id = ? AND day = ?;", context: "Clearing habit failed") { stmt in
            bindText(stmt, index: 1, value: habitId); bindText(stmt, index: 2, value: day)
        }
    }

    /// habit id → completed day keys.
    func fetchHabitLog(fromDay: String? = nil) -> [String: Set<String>] {
        guard tableExists("habit_log") else { return [:] }
        let sql = "SELECT habit_id, day FROM habit_log" + (fromDay == nil ? "" : " WHERE day >= ?") + ";"
        guard let stmt = try? prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        if let fromDay { bindText(stmt, index: 1, value: fromDay) }
        var out: [String: Set<String>] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(stmt, 0)), default: []].insert(String(cString: sqlite3_column_text(stmt, 1)))
        }
        return out
    }
}
