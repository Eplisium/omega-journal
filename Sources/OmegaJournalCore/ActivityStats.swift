import Foundation

/// A minimal (date, words) sample so activity math has no dependency on the app's entry model.
public struct ActivitySample: Equatable, Sendable {
    public let date: Date
    public let words: Int
    public init(date: Date, words: Int) { self.date = date; self.words = words }
}

/// Pure calendar-based writing-activity math (weekday/hour habits, per-day volume).
/// The calendar is injectable so results are deterministic in tests.
public enum ActivityStats {
    /// Weekday name the user writes on most (ties resolved by the lowest weekday), or `nil` if empty.
    public static func mostProductiveWeekday(_ samples: [ActivitySample], calendar: Calendar = .current) -> String? {
        var counts: [Int: Int] = [:]
        for s in samples { counts[calendar.component(.weekday, from: s.date), default: 0] += 1 }
        guard let best = bestKey(counts) else { return nil }
        return calendar.weekdaySymbols[best - 1]
    }

    /// Hour of day (0...23) the user writes in most, or `nil` if empty.
    public static func mostProductiveHour(_ samples: [ActivitySample], calendar: Calendar = .current) -> Int? {
        var counts: [Int: Int] = [:]
        for s in samples { counts[calendar.component(.hour, from: s.date), default: 0] += 1 }
        return bestKey(counts)
    }

    /// "9 PM"-style label for an hour in 0...23.
    public static func hourLabel(_ hour: Int) -> String {
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display) \(hour < 12 ? "AM" : "PM")"
    }

    /// Entry counts for weekdays 1...7 (Sunday-first in the Gregorian calendar).
    public static func countsByWeekday(_ samples: [ActivitySample], calendar: Calendar = .current) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for s in samples { counts[calendar.component(.weekday, from: s.date), default: 0] += 1 }
        return (1...7).reduce(into: [:]) { $0[$1] = counts[$1] ?? 0 }
    }

    /// Words per day for the last `days` days ending today (oldest first), zero-filled.
    public static func wordsPerDay(_ samples: [ActivitySample], days: Int, now: Date = Date(),
                                   calendar: Calendar = .current) -> [ActivitySample] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var map: [Date: Int] = [:]
        for s in samples { map[calendar.startOfDay(for: s.date), default: 0] += s.words }
        return (0..<days).compactMap { i in
            guard let day = calendar.date(byAdding: .day, value: -(days - 1 - i), to: today) else { return nil }
            return ActivitySample(date: day, words: map[day] ?? 0)
        }
    }

    // Deterministic: highest count wins, lowest key breaks ties (dictionary order is random).
    private static func bestKey(_ counts: [Int: Int]) -> Int? {
        counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }
}
