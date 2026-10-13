import Foundation
import OmegaJournalCore

// MARK: - Insights snapshot (computed once per render)
//
// `vm.scopedAnalyticsEntries` re-filters the whole journal on every access and
// `JournalEntry.wordCount` re-tokenises the body on every access. The Insights
// workspace used to read both through ~30 computed properties per render (and
// again on every chart hover callback). Everything Insights shows is now
// derived exactly once into this value and passed down.

struct InsightsSnapshot {
    let period: AnalyticsPeriod
    /// Entries in the reflective scope (period + privacy rule), unchanged.
    let entries: [JournalEntry]
    let state: ReflectionDataState
    let visibility: AnalyticsVisibility
    /// Private entries in this period hidden by the current scope (dates only).
    let excludedPrivateCount: Int
    /// First day of the selected period; nil for "All time".
    let periodStart: Date?

    let wordCount: Int
    let writingDays: Int
    let averageMoodValue: Double?
    let entriesByDay: [Date: [JournalEntry]]
    let activity: [Date: JournalViewModel.DayInfo]
    let writingPoints: [WordPoint]
    let moodPoints: [MoodPoint]
    let distribution: [MoodCount]
    let weekdayCounts: [WeekdayCount]
    let recent: [JournalEntry]
    let streak: Int
    let mostProductiveDay: String?
    let mostProductiveHour: String?
    /// Changes whenever an included entry is added, removed or edited.
    let contentFingerprint: Int

    var averageMood: Mood? {
        averageMoodValue.map { Mood(rawValue: Int($0.rounded())) ?? .neutral }
    }

    var entriesPerWritingDay: Double? {
        guard writingDays > 0 else { return nil }
        return Double(entries.count) / Double(writingDays)
    }

    var bestDay: WordPoint? {
        writingPoints.max { $0.words < $1.words }.flatMap { $0.words > 0 ? $0 : nil }
    }

    var averageWordsPerEntry: Int? {
        entries.isEmpty ? nil : wordCount / entries.count
    }

    @MainActor
    static func make(vm: JournalViewModel, reference: Date = Date()) -> InsightsSnapshot {
        InsightsSnapshot(
            journal: vm.entries,
            entries: vm.scopedAnalyticsEntries,
            period: vm.analyticsPeriod,
            visibility: vm.effectiveAnalyticsVisibility,
            reference: reference
        )
    }

    /// - Parameters:
    ///   - journal: the whole active journal; only id/date/private flag are read.
    ///   - entries: the already-scoped entries (the ViewModel owns that rule).
    init(
        journal: [JournalEntry],
        entries: [JournalEntry],
        period: AnalyticsPeriod,
        visibility: AnalyticsVisibility,
        reference: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.period = period
        self.entries = entries
        self.visibility = visibility

        let records = journal.map { AnalyticsRecord(id: $0.id, date: $0.createdAt, isPrivate: $0.isHidden) }
        state = ReflectionDataState.classify(
            records: records, period: period, visibility: visibility,
            relativeTo: reference, calendar: calendar
        )
        excludedPrivateCount = ReflectionDataState.privateExcludedCount(
            records: records, period: period, visibility: visibility,
            relativeTo: reference, calendar: calendar
        )
        periodStart = period.startDate(relativeTo: reference, calendar: calendar)

        // One pass: word counts, buckets, weekday counts, mood totals.
        var words = 0
        var moodTotal = 0
        var byDay: [Date: [JournalEntry]] = [:]
        var wordsByDay: [Date: Int] = [:]
        var weekday: [Int: Int] = [:]
        var samples: [ActivitySample] = []
        samples.reserveCapacity(entries.count)
        for entry in entries {
            let w = entry.wordCount
            let day = calendar.startOfDay(for: entry.createdAt)
            words += w
            moodTotal += entry.mood.rawValue
            byDay[day, default: []].append(entry)
            wordsByDay[day, default: 0] += w
            weekday[calendar.component(.weekday, from: entry.createdAt), default: 0] += 1
            samples.append(ActivitySample(date: entry.createdAt, words: w))
        }
        wordCount = words
        writingDays = byDay.count
        averageMoodValue = entries.isEmpty ? nil : Double(moodTotal) / Double(entries.count)
        entriesByDay = byDay

        var info: [Date: JournalViewModel.DayInfo] = [:]
        var trend: [MoodPoint] = []
        for (day, dayEntries) in byDay {
            let newestFirst = dayEntries.sorted { $0.createdAt > $1.createdAt }
            info[day] = JournalViewModel.DayInfo(
                date: day,
                count: newestFirst.count,
                moods: newestFirst.map(\.mood),
                titles: newestFirst.prefix(3).map(\.displayTitle)
            )
            trend.append(MoodPoint(
                date: day,
                avg: Double(dayEntries.reduce(0) { $0 + $1.mood.rawValue }) / Double(dayEntries.count)
            ))
        }
        activity = info
        moodPoints = trend.sorted { $0.date < $1.date }

        let today = calendar.startOfDay(for: reference)
        let chartStart = periodStart ?? byDay.keys.min() ?? today
        var points: [WordPoint] = []
        var cursor = calendar.startOfDay(for: chartStart)
        while cursor <= today {
            points.append(WordPoint(date: cursor, words: wordsByDay[cursor] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        writingPoints = points

        var moodCounts: [Mood: Int] = [:]
        for entry in entries { moodCounts[entry.mood, default: 0] += 1 }
        distribution = Mood.allCases
            .map { MoodCount(mood: $0, count: moodCounts[$0] ?? 0) }
            .sorted { $0.mood.rawValue < $1.mood.rawValue }

        let symbols = calendar.veryShortWeekdaySymbols
        weekdayCounts = (1...7).map {
            WeekdayCount(weekday: $0, symbol: symbols[$0 - 1], count: weekday[$0] ?? 0)
        }

        recent = Array(entries.sorted { $0.createdAt > $1.createdAt }.prefix(4))
        streak = StreakHistory.currentLength(days: Set(entries.map(\.createdAt)))
        mostProductiveDay = ActivityStats.mostProductiveWeekday(samples)
        mostProductiveHour = ActivityStats.mostProductiveHour(samples).map(ActivityStats.hourLabel)
        contentFingerprint = ReflectionFingerprint.make(entries.map { ($0.id, $0.updatedAt) })
    }

    /// Titles of the entries behind a mood point — what the hover card shows.
    func moodHoverTitle(for point: MoodPoint, calendar: Calendar = .current) -> String {
        let dayEntries = entriesByDay[calendar.startOfDay(for: point.date)] ?? []
        guard !dayEntries.isEmpty else { return point.avg.formatted(.number.precision(.fractionLength(1))) }
        return dayEntries
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.displayTitle)
            .joined(separator: " · ")
    }
}
