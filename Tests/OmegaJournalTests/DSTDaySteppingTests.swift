import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// core-1 / core-3 / core-4: day and week walks across a DST jump at local
/// midnight. Every test uses an explicit time-zone calendar; the process
/// time zone is never changed.
@Suite("DST-safe day stepping")
@MainActor
struct DSTDaySteppingTests {
    static func cal(_ tz: String, firstWeekday: Int = 2) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = firstWeekday
        return c
    }

    static func noon(_ y: Int, _ m: Int, _ d: Int, _ c: Calendar) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: DayStep

    @Test("DayStep lands on each day's start across a skipped midnight (Santiago, Beirut)")
    func dayStepAcrossSkippedMidnight() {
        // Santiago jumps 00:00 → 01:00 on 2019-09-08; Beirut on 2019-03-31.
        for (tz, y, m, d) in [("America/Santiago", 2019, 9, 8), ("Asia/Beirut", 2019, 3, 31)] {
            let c = Self.cal(tz)
            let before = c.startOfDay(for: Self.noon(y, m, d - 3, c))
            var day = before
            var keys: [String] = []
            for _ in 0..<6 {
                day = DayStep.startOfDay(byAdding: 1, to: day, calendar: c)
                #expect(day == c.startOfDay(for: day), "\(tz): \(day) is not a start of day")
                keys.append(DayKey.string(from: day, calendar: c))
            }
            let first = Self.noon(y, m, d - 3, c)
            let expected = (1...6).map { DayKey.string(from: c.date(byAdding: .day, value: $0, to: first)!, calendar: c) }
            #expect(keys == expected, "\(tz): \(keys)")
            // The jump day itself starts at 01:00, and walking back re-lands on midnight.
            let jump = c.startOfDay(for: Self.noon(y, m, d, c))
            #expect(c.component(.hour, from: jump) == 1)
            let back = DayStep.startOfDay(byAdding: -1, to: jump, calendar: c)
            #expect(c.component(.hour, from: back) == 0)
            #expect(DayKey.dayDistance(from: back, to: jump, calendar: c) == 1)
        }
    }

    @Test("DayStep week steps return real week starts after a DST Sunday")
    func weekStepAcrossDSTSunday() {
        let c = Self.cal("America/Santiago", firstWeekday: 1)
        let dstWeek = c.dateInterval(of: .weekOfYear, for: Self.noon(2019, 9, 10, c))!.start  // Sun 9/8 01:00
        let next = DayStep.startOfWeek(byAdding: 1, to: dstWeek, calendar: c)!
        #expect(next == c.dateInterval(of: .weekOfYear, for: Self.noon(2019, 9, 17, c))!.start)
        #expect(c.component(.hour, from: next) == 0)
        let prev = DayStep.startOfWeek(byAdding: -1, to: dstWeek, calendar: c)!
        #expect(DayKey.string(from: prev, calendar: c) == "2019-09-01")
    }

    // MARK: core-1 StreakCalculator

    @Test("core-1a dailyStreak counts through the Santiago midnight DST jump")
    func dailyStreakDST() {
        let c = Self.cal("America/Santiago")
        let days = Set((1...12).map { Self.noon(2019, 9, $0, c) })
        #expect(StreakCalculator.dailyStreak(writingDays: days, today: Self.noon(2019, 9, 12, c), calendar: c) == 12)
        // Today still open: the streak ends yesterday and keeps every day.
        #expect(StreakCalculator.dailyStreak(writingDays: days, today: Self.noon(2019, 9, 13, c), calendar: c) == 12)
    }

    @Test("core-1b longestDailyStreak counts through the Santiago midnight DST jump")
    func longestDailyStreakDST() {
        let c = Self.cal("America/Santiago")
        let days = Set((1...12).map { Self.noon(2019, 9, $0, c) })
        #expect(StreakCalculator.longestDailyStreak(writingDays: days, calendar: c) == 12)
        let s = StreakCalculator.summary(writingDays: days, mode: .dailyWithRest, today: Self.noon(2019, 9, 12, c), calendar: c)
        #expect(s.current == 12 && s.longest == 12)
    }

    @Test("core-1c weekly streaks count through a DST week (Sunday-start weeks)")
    func weeklyStreakDST() {
        let c = Self.cal("America/Santiago", firstWeekday: 1)
        // Every day Sun 2019-08-18 … Sat 2019-09-21 = 5 full Sunday-start weeks.
        let start = Self.noon(2019, 8, 18, c)
        let days = Set((0..<35).map { c.date(byAdding: .day, value: $0, to: start)! })
        let today = Self.noon(2019, 9, 21, c)
        #expect(StreakCalculator.weeklyStreak(writingDays: days, target: 3, today: today, calendar: c) == 5)
        #expect(StreakCalculator.longestWeeklyStreak(writingDays: days, target: 3, calendar: c) == 5)
        let s = StreakCalculator.summary(writingDays: days, mode: .weekly, weeklyTarget: 3, today: today, calendar: c)
        #expect(s.current == 5 && s.longest == 5 && s.unit == "week")
    }

    // MARK: core-3 Insights writing chart

    @Test("core-3 InsightsSnapshot writing points keep counting after the DST day and include today")
    func insightsWritingPointsDST() {
        let c = Self.cal("America/Santiago")
        let entries: [JournalEntry] = (5...12).map { d in
            var e = JournalEntry.new()
            e.title = "D\(d)"; e.body = "one two three"; e.createdAt = Self.noon(2019, 9, d, c)
            return e
        }
        let snap = InsightsSnapshot(journal: entries, entries: entries, period: .allTime, visibility: .visibleOnly,
                                    reference: Self.noon(2019, 9, 12, c), calendar: c)
        #expect(snap.writingPoints.count == 8)
        #expect(snap.writingPoints.map(\.words) == Array(repeating: 3, count: 8),
                "\(snap.writingPoints.map { "\(DayKey.string(from: $0.date, calendar: c))=\($0.words)" })")
        #expect(snap.writingPoints.reduce(0) { $0 + $1.words } == snap.wordCount)
        #expect(snap.writingPoints.last.map { DayKey.string(from: $0.date, calendar: c) } == "2019-09-12")
        #expect(snap.writingPoints.allSatisfy { $0.date == c.startOfDay(for: $0.date) })
    }

    @Test("core-3 ActivityStats.wordsPerDay keys every day on its start when today is the DST day")
    func activityWordsPerDayOnDSTDay() {
        let c = Self.cal("America/Santiago")
        let samples = (2...8).map { ActivitySample(date: Self.noon(2019, 9, $0, c), words: 10) }
        let out = ActivityStats.wordsPerDay(samples, days: 7, now: Self.noon(2019, 9, 8, c), calendar: c)
        #expect(out.map(\.words) == Array(repeating: 10, count: 7), "\(out.map(\.words))")
        #expect(out.map { DayKey.string(from: $0.date, calendar: c) }
                == (2...8).map { String(format: "2019-09-%02d", $0) })
    }

    // MARK: core-4 Heatmap

    @Test("core-4 heatmap grid days stay on start-of-day, one per calendar day, across a DST week")
    func heatmapGridDST() {
        let c = Self.cal("America/Santiago", firstWeekday: 1)
        let today = Self.noon(2019, 10, 15, c)
        let weeks = HeatmapView.gridWeeks(today: today, calendar: c)
        let days = weeks.flatMap { $0.days.compactMap { $0 } }
        let off = days.filter { $0 != c.startOfDay(for: $0) }
        #expect(off.isEmpty, "\(off.count) cells not at start of day, first: \(off.first.map { "\($0)" } ?? "-")")
        // Consecutive calendar days with no gap or repeat, ending today.
        for (a, b) in zip(days, days.dropFirst()) {
            #expect(DayKey.dayDistance(from: a, to: b, calendar: c) == 1)
        }
        #expect(days.last == c.startOfDay(for: today))
        #expect(weeks.allSatisfy { c.component(.weekday, from: $0.startDate) == 1 })
        // A cell after the DST Sunday finds the day's `startOfDay`-keyed info.
        let key = c.startOfDay(for: Self.noon(2019, 9, 20, c))
        #expect(days.contains(key))
    }
}
