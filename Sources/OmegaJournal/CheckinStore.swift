import Foundation
import SwiftUI
import OmegaJournalCore

// MARK: - Check-in & habit store

/// Observable state for the daily check-in and habit strip. Backed by
/// `DatabaseManager` (V12 tables). Values are plain numbers keyed by local day.
@MainActor
final class CheckinStore: ObservableObject {
    static let shared = CheckinStore(db: DatabaseManager.shared)

    let db: DatabaseManager
    @Published private(set) var metrics: [CheckinMetric] = []
    @Published private(set) var habits: [Habit] = []
    /// day key → metric id → value
    @Published private(set) var values: [String: [String: Double]] = [:]
    /// habit id → completed day keys
    @Published private(set) var habitLog: [String: Set<String>] = [:]

    /// How far back values/logs are loaded (covers a year-in-review).
    static let historyDays = 800

    init(db: DatabaseManager) {
        self.db = db
        reload()
    }

    func reload() {
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -Self.historyDays, to: Date()).map { DayKey.string(from: $0) }
        metrics = db.fetchMetrics()
        habits = db.fetchHabits()
        var map: [String: [String: Double]] = [:]
        for v in db.fetchCheckinValues(fromDay: from) { map[v.day, default: [:]][v.metricId] = v.value }
        values = map
        habitLog = db.fetchHabitLog(fromDay: from)
    }

    nonisolated static func todayKey(_ now: Date = Date()) -> String { DayKey.string(from: now) }

    // MARK: Metrics

    func value(_ metricId: String, day: String = CheckinStore.todayKey()) -> Double? { values[day]?[metricId] }

    func setValue(_ metricId: String, _ value: Double?, day: String = CheckinStore.todayKey()) {
        guard db.setCheckinValue(day: day, metricId: metricId, value: value) else { return }
        if let value { values[day, default: [:]][metricId] = value } else { values[day]?[metricId] = nil }
    }

    /// day key → value for one metric (for correlations).
    func series(_ metricId: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for (day, m) in values { if let v = m[metricId] { out[day] = v } }
        return out
    }

    @discardableResult
    func addMetric(name: String, kind: CheckinMetricKind, unit: String) -> Bool {
        guard db.addMetric(name: name, kind: kind, unit: unit) != nil else { return false }
        reload(); return true
    }

    func removeMetric(_ id: String) { if db.removeMetric(id: id) { reload() } }

    var hasTodayCheckin: Bool { !(values[Self.todayKey()] ?? [:]).isEmpty }

    // MARK: Habits

    @discardableResult
    func addHabit(name: String) -> Bool {
        guard db.addHabit(name: name) != nil else { return false }
        reload(); return true
    }

    func deleteHabit(_ id: String) { if db.deleteHabit(id: id) { reload() } }

    func isDone(_ habitId: String, day: String = CheckinStore.todayKey()) -> Bool {
        habitLog[habitId]?.contains(day) ?? false
    }

    func toggleHabit(_ habitId: String, day: String = CheckinStore.todayKey()) {
        let now = !isDone(habitId, day: day)
        guard db.setHabitDone(habitId: habitId, day: day, done: now) else { return }
        if now { habitLog[habitId, default: []].insert(day) } else { habitLog[habitId]?.remove(day) }
    }

    func streak(_ habitId: String, today: Date = Date()) -> Int {
        HabitStats.currentStreak(doneDays: habitLog[habitId] ?? [], today: today)
    }

    /// Per-day share of habits completed — overlays the writing heatmap.
    var dailyHabitCompletion: [String: Double] {
        HabitStats.dailyCompletion(habitIds: habits.map(\.id), log: habitLog)
    }
}
