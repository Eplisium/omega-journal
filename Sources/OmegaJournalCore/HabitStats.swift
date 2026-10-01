import Foundation

// MARK: - Habits (pure model + statistics)

public struct Habit: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var icon: String
    public var sortOrder: Int
    public var isArchived: Bool
    public init(id: String, name: String, icon: String = "checkmark.circle", sortOrder: Int = 0, isArchived: Bool = false) {
        self.id = id; self.name = name; self.icon = icon; self.sortOrder = sortOrder; self.isArchived = isArchived
    }
}

public enum HabitStats {
    /// Consecutive completed days ending today (or yesterday, so an unchecked
    /// today does not zero the streak until the day is over).
    public static func currentStreak(doneDays: Set<String>, today: Date, calendar: Calendar = .current) -> Int {
        var cursor = calendar.startOfDay(for: today)
        if !doneDays.contains(DayKey.string(from: cursor, calendar: calendar)) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = y
        }
        var n = 0
        while doneDays.contains(DayKey.string(from: cursor, calendar: calendar)) {
            n += 1
            guard let p = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = p
        }
        return n
    }

    /// Fraction of the last `days` days (ending today) that were completed.
    public static func completionRate(doneDays: Set<String>, days: Int, today: Date, calendar: Calendar = .current) -> Double {
        guard days > 0 else { return 0 }
        let t = calendar.startOfDay(for: today)
        var done = 0
        for i in 0..<days {
            guard let d = calendar.date(byAdding: .day, value: -i, to: t) else { continue }
            if doneDays.contains(DayKey.string(from: d, calendar: calendar)) { done += 1 }
        }
        return Double(done) / Double(days)
    }

    /// Per-day fraction of active habits completed (feeds the heatmap overlay).
    /// `log` maps habit id → completed day keys.
    public static func dailyCompletion(habitIds: [String], log: [String: Set<String>]) -> [String: Double] {
        guard !habitIds.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for id in habitIds { for d in log[id] ?? [] { counts[d, default: 0] += 1 } }
        return counts.mapValues { min(1, Double($0) / Double(habitIds.count)) }
    }

    /// Mean mood on days a habit was done vs not (nil sides when no data).
    public static func moodWithHabit(doneDays: Set<String>, dailyMood: [String: Double]) -> (done: Double?, notDone: Double?) {
        var d: [Double] = [], n: [Double] = []
        for (day, m) in dailyMood { if doneDays.contains(day) { d.append(m) } else { n.append(m) } }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        return (avg(d), avg(n))
    }
}
