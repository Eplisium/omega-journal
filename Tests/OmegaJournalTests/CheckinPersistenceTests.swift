import Darwin
import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

@Suite("Check-ins, habits, backups (isolated DB)", .serialized)
@MainActor
struct CheckinPersistenceTests {
    private static func makeDB() -> (DatabaseManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omega-checkin-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        return (db, root)
    }

    @Test("V12 creates tables and seeds built-in metrics idempotently")
    func migration() {
        let (db, root) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(DatabaseManager.currentSchemaVersion >= 12)
        for t in ["metrics", "entry_metrics", "habits", "habit_log"] { #expect(db.tableExists(t)) }
        #expect(db.fetchMetrics().map(\.id) == [CheckinMetric.sleepId, CheckinMetric.energyId, CheckinMetric.stressId])
        #expect(db.migrateToV12())          // idempotent re-run
        #expect(db.fetchMetrics().count == 3)
    }

    @Test("check-in values upsert, clear, and cascade with custom metric deletion")
    func values() throws {
        let (db, root) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(db.setCheckinValue(day: "2026-10-01", metricId: CheckinMetric.sleepId, value: 6.5))
        #expect(db.setCheckinValue(day: "2026-10-01", metricId: CheckinMetric.sleepId, value: 7.5))
        #expect(db.fetchCheckinValues().map(\.value) == [7.5])
        let custom = try #require(db.addMetric(name: "Water", kind: .number, unit: "cups"))
        #expect(db.setCheckinValue(day: "2026-10-02", metricId: custom.id, value: 5))
        #expect(db.fetchCheckinValues().count == 2)
        #expect(db.removeMetric(id: custom.id))
        #expect(db.fetchCheckinValues().map(\.metricId) == [CheckinMetric.sleepId])
        #expect(db.setCheckinValue(day: "2026-10-01", metricId: CheckinMetric.sleepId, value: nil))
        #expect(db.fetchCheckinValues().isEmpty)
        // Built-ins are archived, not deleted.
        #expect(db.removeMetric(id: CheckinMetric.stressId))
        #expect(!db.fetchMetrics().contains { $0.id == CheckinMetric.stressId })
        #expect(db.fetchMetrics(includeArchived: true).contains { $0.id == CheckinMetric.stressId })
        #expect(db.addMetric(name: "   ", kind: .scale, unit: "") == nil)
    }

    @Test("habits log, toggle off, delete removes log")
    func habits() throws {
        let (db, root) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try #require(db.addHabit(name: "Walk"))
        #expect(db.setHabitDone(habitId: h.id, day: "2026-10-01", done: true))
        #expect(db.setHabitDone(habitId: h.id, day: "2026-10-01", done: true)) // idempotent
        #expect(db.setHabitDone(habitId: h.id, day: "2026-10-02", done: true))
        #expect(db.fetchHabitLog()[h.id] == ["2026-10-01", "2026-10-02"])
        #expect(db.setHabitDone(habitId: h.id, day: "2026-10-02", done: false))
        #expect(db.fetchHabitLog()[h.id] == ["2026-10-01"])
        #expect(db.deleteHabit(id: h.id))
        #expect(db.fetchHabits().isEmpty && db.fetchHabitLog().isEmpty)
    }

    @MainActor
    @Test("CheckinStore reflects writes and computes streaks and completion")
    func store() throws {
        let (db, root) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckinStore(db: db)
        store.setValue(CheckinMetric.energyId, 4)
        #expect(store.value(CheckinMetric.energyId) == 4 && store.hasTodayCheckin)
        store.setValue(CheckinMetric.energyId, nil)
        #expect(!store.hasTodayCheckin)
        #expect(store.addHabit(name: "Read"))
        let h = try #require(store.habits.first)
        store.toggleHabit(h.id)
        #expect(store.isDone(h.id) && store.streak(h.id) == 1)
        #expect(store.dailyHabitCompletion[CheckinStore.todayKey()] == 1)
        store.toggleHabit(h.id)
        #expect(!store.isDone(h.id))
        // Survives a reload from disk.
        store.toggleHabit(h.id)
        store.reload()
        #expect(store.isDone(h.id))
    }

    @Test("backup folder mirrors daily backups; infos list both; verify and integrity work")
    func backupFolder() throws {
        let (db, root) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        db.setChosenBackupFolder(extra)
        #expect(db.chosenBackupFolder?.path == extra.path)
        let local = try #require(db.backupNow())
        let mirrored = extra.appendingPathComponent(local.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: mirrored.path))
        let infos = db.backupInfos()
        #expect(infos.contains { $0.isExternal } && infos.contains { !$0.isExternal })
        let v = try db.verifyBackup(at: mirrored)
        #expect(v.schemaVersion == DatabaseManager.currentSchemaVersion && v.entryCount == 0)
        #expect(db.integrityReport().ok)
        // Corrupt copy is rejected.
        let junk = root.appendingPathComponent("junk.sqlite3")
        try Data("not a database".utf8).write(to: junk)
        #expect(throws: Error.self) { try db.verifyBackup(at: junk) }
        // Unset folder stops mirroring.
        db.setChosenBackupFolder(nil)
        #expect(db.chosenBackupFolder == nil)
    }

    @Test("restoring a V12 backup brings back check-in data")
    func restoreKeepsCheckins() throws {
        let (db, root) = Self.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        db.setCheckinValue(day: "2026-10-01", metricId: CheckinMetric.sleepId, value: 8)
        let backup = try #require(db.backupNow())
        db.setCheckinValue(day: "2026-10-01", metricId: CheckinMetric.sleepId, value: 3)
        try db.restoreBackup(from: backup)
        #expect(db.fetchCheckinValues().first?.value == 8)
    }
}
