import Foundation
import SwiftUI
import OmegaJournalCore

extension JournalViewModel {
    // MARK: - Stats

    var moodThisWeek: [Mood: Int] {
        let w = Date().addingTimeInterval(-7 * 24 * 3600)
        var c: [Mood: Int] = [:]
        for e in entries where e.createdAt >= w { c[e.mood, default: 0] += 1 }
        return c
    }
    var totalWordCount: Int { entries.reduce(0) { $0 + $1.wordCount } }
    var averageMood: Double { entries.isEmpty ? 0 : Double(entries.reduce(0) { $0 + $1.mood.rawValue }) / Double(entries.count) }
    var entriesThisWeek: Int { entries.filter { $0.createdAt >= Date().addingTimeInterval(-7 * 24 * 3600) }.count }
    var favoriteCount: Int { entries.filter(\.isFavorite).count }
    var hiddenCount: Int { hiddenEntries.count }

    /// Distinct calendar days with an active entry (cache: `writingDaysCache`).
    var writingDays: Set<Date> {
        let key = [Double(entries.count), entries.reduce(0) { $0 + $1.createdAt.timeIntervalSince1970 }]
        if let cache = writingDaysCache, cache.key == key { return cache.days }
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.createdAt) })
        writingDaysCache = (key, days)
        return days
    }

    /// Non-punitive streak: see `StreakCalculator` (one rest day per 7 is
    /// forgiven; weekly-goal mode counts weeks that hit the target).
    var streakSummary: StreakSummary {
        GoalManager.shared.streakSummary(writingDays: writingDays)
    }
    var writingStreak: Int { streakSummary.current }
    var longestStreak: Int { streakSummary.longest }
    var streakUnit: String { streakSummary.unit }
    /// Gentle "welcome back" copy, owned by Core so all views share one voice.
    var welcomeBackMessage: String { StreakCopy.welcomeBack(daysAway: streakSummary.daysSinceLastEntry) }

    var entriesThisMonth: Int {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .month, for: Date())?.start else { return 0 }
        return entries.filter { $0.createdAt >= start }.count
    }

    var averageWordsPerEntry: Int {
        entries.isEmpty ? 0 : totalWordCount / entries.count
    }

    var totalReadingTime: String {
        let total = entries.reduce(0) { $0 + $1.readingMinutes }
        if total < 60 { return "\(total) min" }
        return "\(total / 60)h \(total % 60)m"
    }

    private var activitySamples: [ActivitySample] {
        entries.map { ActivitySample(date: $0.createdAt, words: $0.wordCount) }
    }

    /// The weekday the user journals on most, e.g. "Sunday".
    var mostProductiveDay: String {
        ActivityStats.mostProductiveWeekday(activitySamples) ?? "—"
    }

    /// The hour of day the user writes most often, e.g. "9 PM".
    var mostProductiveHour: String {
        ActivityStats.mostProductiveHour(activitySamples).map(ActivityStats.hourLabel) ?? "—"
    }

    /// Words written per day over the last `days`, for the writing-volume chart.
    func wordsPerDay(days: Int = 30) -> [WordPoint] {
        ActivityStats.wordsPerDay(activitySamples, days: days).map { WordPoint(date: $0.date, words: $0.words) }
    }

    /// Entry counts per weekday (Sun…Sat) for the weekday-rhythm chart.
    var entriesByWeekday: [WeekdayCount] {
        let cal = Calendar.current
        let counts = ActivityStats.countsByWeekday(activitySamples, calendar: cal)
        return (1...7).map { WeekdayCount(weekday: $0, symbol: cal.shortWeekdaySymbols[$0 - 1], count: counts[$0] ?? 0) }
    }
}
