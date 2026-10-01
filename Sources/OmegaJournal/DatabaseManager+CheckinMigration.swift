import Foundation
import SQLite3
import OmegaJournalCore

extension DatabaseManager {
    /// V12: structured daily check-ins (`metrics` + `entry_metrics`) and habits
    /// (`habits` + `habit_log`). Idempotent. These tables hold only metadata
    /// (names, numbers, day keys) — no journal body text — so they follow the
    /// same plaintext-metadata policy as tags/moods; free text never lands here.
    func migrateToV12() -> Bool {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS metrics (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'scale',
                unit TEXT NOT NULL DEFAULT '',
                icon TEXT NOT NULL DEFAULT 'circle',
                sort_order INTEGER NOT NULL DEFAULT 0,
                is_builtin INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS entry_metrics (
                day TEXT NOT NULL,
                metric_id TEXT NOT NULL REFERENCES metrics(id) ON DELETE CASCADE,
                value REAL NOT NULL,
                updated_at REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (day, metric_id)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_entry_metrics_metric ON entry_metrics(metric_id, day);",
            """
            CREATE TABLE IF NOT EXISTS habits (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                icon TEXT NOT NULL DEFAULT 'checkmark.circle',
                sort_order INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL DEFAULT 0
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS habit_log (
                habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
                day TEXT NOT NULL,
                PRIMARY KEY (habit_id, day)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_habit_log_day ON habit_log(day);",
            "INSERT OR IGNORE INTO metrics (id, name, kind, unit, icon, sort_order, is_builtin) VALUES ('\(CheckinMetric.sleepId)', 'Sleep', 'number', 'h', 'bed.double.fill', 0, 1);",
            "INSERT OR IGNORE INTO metrics (id, name, kind, unit, icon, sort_order, is_builtin) VALUES ('\(CheckinMetric.energyId)', 'Energy', 'scale', '', 'bolt.fill', 1, 1);",
            "INSERT OR IGNORE INTO metrics (id, name, kind, unit, icon, sort_order, is_builtin) VALUES ('\(CheckinMetric.stressId)', 'Stress', 'scale', '', 'waveform.path.ecg', 2, 1);",
        ]
        for sql in statements where !exec(sql) { return false }
        return true
    }
}
