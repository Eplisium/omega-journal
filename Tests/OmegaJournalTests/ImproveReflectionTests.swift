import AppKit
import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Reflection track: Calendar, Heatmap and Insights states, metrics and
/// per-render snapshots.
@Suite("Improve Reflection")
@MainActor
struct ImproveReflectionTests {
    static func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12, minute: Int = 0) -> Date {
        utc().date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    static let today = date(2026, 10, 13)

    static func entry(_ title: String = "T", body: String = "one two three", mood: Mood = .neutral,
                      hidden: Bool = false, at createdAt: Date, updatedAt: Date? = nil) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title
        e.body = body
        e.mood = mood
        e.isHidden = hidden
        e.createdAt = createdAt
        e.updatedAt = updatedAt ?? createdAt
        return e
    }

    static func record(_ id: String, _ d: Date, privateEntry: Bool = false) -> AnalyticsRecord {
        AnalyticsRecord(id: id, date: d, isPrivate: privateEntry)
    }

    // MARK: Data states

    @Test("empty journal, empty period, private-excluded, sparse and populated are distinct")
    func dataStates() {
        let cal = Self.utc()
        func classify(_ r: [AnalyticsRecord], _ p: AnalyticsPeriod = .sevenDays,
                      _ v: AnalyticsVisibility = .visibleOnly) -> ReflectionDataState {
            ReflectionDataState.classify(records: r, period: p, visibility: v, relativeTo: Self.today, calendar: cal)
        }
        #expect(classify([]) == .noEntries)
        // Writing exists, but a month ago.
        let old = [Self.record("a", Self.date(2026, 9, 1))]
        #expect(classify(old) == .emptyPeriod)
        #expect(classify(old, .allTime) == .sparse(writingDays: 1))
        // Only private writing in the period.
        let privateOnly = old + [Self.record("p1", Self.date(2026, 10, 12), privateEntry: true),
                                 Self.record("p2", Self.date(2026, 10, 10), privateEntry: true)]
        #expect(classify(privateOnly) == .privateExcluded(count: 2))
        // Including private (rule unchanged) turns it into real data.
        #expect(classify(privateOnly, .sevenDays, .includePrivate) == .sparse(writingDays: 2))
        // Three distinct writing days → populated; two entries on one day are one day.
        let three = [Self.record("1", Self.date(2026, 10, 13, hour: 8)), Self.record("2", Self.date(2026, 10, 13, hour: 20)),
                     Self.record("3", Self.date(2026, 10, 11)), Self.record("4", Self.date(2026, 10, 9))]
        #expect(classify(three) == .populated)
        #expect(classify(Array(three.prefix(3))) == .sparse(writingDays: 2))
        // Future-dated writing never counts as "in this period".
        #expect(classify([Self.record("f", Self.date(2026, 10, 20))]) == .emptyPeriod)
        #expect(ReflectionDataState.privateExcludedCount(records: privateOnly, period: .sevenDays,
                                                         visibility: .includePrivate, relativeTo: Self.today,
                                                         calendar: cal) == 0)
        #expect(ReflectionDataState.noEntries.isEmpty && ReflectionDataState.emptyPeriod.isEmpty)
        #expect(!ReflectionDataState.sparse(writingDays: 1).isEmpty && !ReflectionDataState.populated.isEmpty)
    }

    @Test("each empty reason offers the action that changes it")
    func emptyCopyActions() {
        let none = ReflectionEmptyCopy(state: .noEntries, period: .thirtyDays, isAuthenticated: false)
        #expect(none.actions == [.write])

        let quiet = ReflectionEmptyCopy(state: .emptyPeriod, period: .sevenDays, isAuthenticated: false)
        #expect(quiet.actions == [.showAllTime, .write])
        #expect(quiet.title == "No writing in the last 7 days")
        // Already all-time: widening is not an option.
        #expect(ReflectionEmptyCopy(state: .emptyPeriod, period: .allTime, isAuthenticated: false).actions == [.write])

        let locked = ReflectionEmptyCopy(state: .privateExcluded(count: 1), period: .thirtyDays, isAuthenticated: false)
        #expect(locked.actions.first == .includePrivate)
        #expect(locked.message.contains("1 private entry"))
        #expect(locked.message.contains("Unlock"))
        #expect(ReflectionEmptyCopy.Action.includePrivate.title(isAuthenticated: false) == "Unlock to include")
        let unlocked = ReflectionEmptyCopy(state: .privateExcluded(count: 3), period: .thirtyDays, isAuthenticated: true)
        #expect(unlocked.message.contains("3 private entries"))
        #expect(!unlocked.message.contains("Unlock"))
        #expect(ReflectionEmptyCopy.Action.includePrivate.title(isAuthenticated: true) == "Include private entries")

        #expect(ReflectionEmptyCopy(state: .populated, period: .year, isAuthenticated: true).actions.isEmpty)
        #expect(ReflectionEmptyCopy.sparseMessage(writingDays: 1).contains("1 writing day so far"))
    }

    @Test("compact privacy line states scope and excluded count")
    func scopeCopy() {
        #expect(ReflectionScopeCopy.line(visibility: .includePrivate, excludedCount: 4, scopeNoun: "this period")
                == "Private entries included")
        #expect(ReflectionScopeCopy.line(visibility: .visibleOnly, excludedCount: 0, scopeNoun: "this period")
                == "Private entries excluded")
        #expect(ReflectionScopeCopy.line(visibility: .visibleOnly, excludedCount: 2, scopeNoun: "October 2026")
                == "Private entries excluded · 2 private entries in October 2026")
    }

    // MARK: Selected-day metrics

    @Test("selected-day metrics collapse to one line, nothing for empty days")
    func dayMetrics() {
        #expect(ReflectionDayMetrics.summary(entryCount: 0, words: 0, readingMinutes: 0) == nil)
        #expect(ReflectionDayMetrics.summary(entryCount: 1, words: 1, readingMinutes: 0) == "1 entry · 1 word · 1 min read")
        #expect(ReflectionDayMetrics.summary(entryCount: 2, words: 340, readingMinutes: 2) == "2 entries · 340 words · 2 min read")
    }

    // MARK: Fingerprint (themes refresh)

    @Test("content fingerprint changes on edits and same-size swaps, not on order")
    func fingerprint() {
        let t0 = Self.date(2026, 10, 1)
        let a = (id: "a", updatedAt: t0), b = (id: "b", updatedAt: t0), c = (id: "c", updatedAt: t0)
        let base = ReflectionFingerprint.make([a, b])
        #expect(base == ReflectionFingerprint.make([b, a]))
        // Same count, different entries — the old `.task(id: entries.count)` missed this.
        #expect(base != ReflectionFingerprint.make([a, c]))
        // Edited body → new updatedAt.
        #expect(base != ReflectionFingerprint.make([a, (id: "b", updatedAt: t0.addingTimeInterval(5))]))
        #expect(ReflectionFingerprint.make([]) != base)
    }

    // MARK: Heatmap

    @Test("heatmap stats clip to the selected period")
    func heatmapPeriodWindow() {
        let cal = Self.utc()
        let today = cal.startOfDay(for: Self.today)
        let gridStart = HeatmapView.gridStart(today: today, calendar: cal)!
        let periodStart = AnalyticsPeriod.sevenDays.startDate(relativeTo: today, calendar: cal)!
        #expect(ReflectionHeatmapWindow.statsStart(gridStart: gridStart, periodStart: nil, calendar: cal) == gridStart)
        #expect(ReflectionHeatmapWindow.statsStart(gridStart: gridStart, periodStart: periodStart, calendar: cal) == periodStart)
        // A period longer than the grid keeps the grid start.
        let yearAgo = cal.date(byAdding: .year, value: -1, to: today)!
        #expect(ReflectionHeatmapWindow.statsStart(gridStart: gridStart, periodStart: yearAgo, calendar: cal) == gridStart)

        // Writing on all 7 days of a "7 days" view is 100% of the period,
        // not ~4% of 26 weeks.
        var counts: [Date: Int] = [:]
        for i in 0..<7 { counts[cal.date(byAdding: .day, value: -i, to: today)!] = 1 }
        let start = ReflectionHeatmapWindow.statsStart(gridStart: gridStart, periodStart: periodStart, calendar: cal)
        let stats = HeatmapView.windowStats(counts: counts, windowStart: start, today: today, calendar: cal)
        #expect(stats.coverage == 100 && stats.activeDays == 7 && stats.total == 7)

        #expect(ReflectionHeatmapWindow.isOutsidePeriod(cal.date(byAdding: .day, value: -7, to: today)!, periodStart: periodStart, calendar: cal))
        #expect(!ReflectionHeatmapWindow.isOutsidePeriod(periodStart, periodStart: periodStart, calendar: cal))
        #expect(!ReflectionHeatmapWindow.isOutsidePeriod(gridStart, periodStart: nil, calendar: cal))
    }

    @Test("heatmap grid weeks are built in one pass ending on today")
    func heatmapGridWeeks() {
        let cal = Self.utc()
        let weeks = HeatmapView.gridWeeks(today: Self.today, calendar: cal)
        #expect(weeks.count == 26)
        #expect(weeks.first?.startDate == HeatmapView.gridStart(today: Self.today, calendar: cal))
        #expect(weeks.map(\.id) == Array(0..<26))
        let last = weeks.last!.days
        let today = cal.startOfDay(for: Self.today)
        #expect(last.contains(today))
        // Days after today are blanks, never future cells.
        #expect(last.compactMap { $0 }.allSatisfy { $0 <= today })
        #expect(weeks.dropLast().allSatisfy { $0.days.allSatisfy { $0 != nil } })
    }

    // MARK: Insights snapshot

    @Test("insights snapshot derives every metric once and keeps private entries out")
    func insightsSnapshot() {
        _ = NSApplication.shared
        let cal = Self.utc()
        let a = Self.entry("A", body: "one two three four", mood: .great, at: Self.date(2026, 10, 13, hour: 9))
        let b = Self.entry("B", body: "five six", mood: .bad, at: Self.date(2026, 10, 13, hour: 18))
        let c = Self.entry("C", body: "seven", mood: .good, at: Self.date(2026, 10, 10))
        let d = Self.entry("D", body: "eight nine", at: Self.date(2026, 10, 8))
        let secret = Self.entry("Secret", body: "private words never counted here", hidden: true,
                                at: Self.date(2026, 10, 12))
        let journal = [a, b, c, d, secret]
        // The VM's scoped list (visibleOnly) — the rule itself is not re-implemented.
        let scoped = [a, b, c, d]
        let snap = InsightsSnapshot(journal: journal, entries: scoped, period: .sevenDays,
                                    visibility: .visibleOnly, reference: Self.today, calendar: cal)

        #expect(snap.state == .populated)
        #expect(snap.excludedPrivateCount == 1)
        #expect(snap.wordCount == 9) // secret's 5 words never counted
        #expect(snap.writingDays == 3)
        #expect(snap.entriesPerWritingDay == 4.0 / 3.0)
        #expect(snap.entriesByDay[cal.startOfDay(for: a.createdAt)]?.count == 2)
        #expect(snap.activity[cal.startOfDay(for: secret.createdAt)] == nil)
        #expect(snap.activity[cal.startOfDay(for: a.createdAt)]?.titles == ["B", "A"]) // newest first
        #expect(snap.moodPoints.map(\.date) == snap.moodPoints.map(\.date).sorted())
        #expect(snap.writingPoints.count == 7) // exactly the 7-day period
        #expect(snap.writingPoints.first?.date == AnalyticsPeriod.sevenDays.startDate(relativeTo: Self.today, calendar: cal))
        #expect(snap.writingPoints.last?.words == 6)
        #expect(snap.recent.map(\.title) == ["B", "A", "C", "D"])
        #expect(snap.distribution.map(\.count).reduce(0, +) == 4)
        #expect(snap.weekdayCounts.map(\.count).reduce(0, +) == 4)
        #expect(snap.bestDay?.words == 6)
        #expect(snap.moodHoverTitle(for: MoodPoint(date: a.createdAt, avg: 3), calendar: cal) == "A · B")

        // Editing an included entry changes the fingerprint that keys themes.
        var edited = c
        edited.updatedAt = c.updatedAt.addingTimeInterval(60)
        let after = InsightsSnapshot(journal: journal, entries: [a, b, edited, d], period: .sevenDays,
                                     visibility: .visibleOnly, reference: Self.today, calendar: cal)
        #expect(after.contentFingerprint != snap.contentFingerprint)

        // Empty scope with only a private entry → private-excluded state, no metrics.
        let onlyPrivate = InsightsSnapshot(journal: [secret], entries: [], period: .sevenDays,
                                           visibility: .visibleOnly, reference: Self.today, calendar: cal)
        #expect(onlyPrivate.state == .privateExcluded(count: 1))
        #expect(onlyPrivate.wordCount == 0 && onlyPrivate.entriesPerWritingDay == nil && onlyPrivate.averageMood == nil)
        #expect(onlyPrivate.averageWordsPerEntry == nil && onlyPrivate.bestDay == nil)
    }

    // MARK: Calendar month snapshot

    @Test("calendar month snapshot slices month boundaries and sorts days once")
    func calendarSnapshot() {
        let cal = Self.utc()
        let lastMinute = Self.entry("late", at: Self.date(2026, 9, 30, hour: 23, minute: 59))
        let morning = Self.entry("morning", at: Self.date(2026, 9, 15, hour: 7))
        let evening = Self.entry("evening", at: Self.date(2026, 9, 15, hour: 21))
        let nextMonth = Self.entry("october", at: Self.date(2026, 10, 1, hour: 0))
        let prevMonth = Self.entry("august", at: Self.date(2026, 8, 31, hour: 23))
        let hiddenSep = Self.entry("h", body: "secret words", hidden: true, at: Self.date(2026, 9, 20))
        let hiddenOct = Self.entry("h2", hidden: true, at: Self.date(2026, 10, 2))
        let scoped = [evening, lastMinute, nextMonth, morning, prevMonth]
        let journal = scoped + [hiddenSep, hiddenOct]

        let snap = CalendarMonthSnapshot(scopedEntries: scoped, journal: journal,
                                         anchorMonth: Self.date(2026, 9, 10), visibility: .visibleOnly,
                                         reference: Self.today, calendar: cal)
        #expect(snap.month == Self.date(2026, 9, 1, hour: 0))
        #expect(snap.monthEntries.map(\.title) == ["morning", "evening", "late"])
        #expect(snap.writingDays == [Self.date(2026, 9, 15, hour: 0), Self.date(2026, 9, 30, hour: 0)])
        #expect(snap.entries(on: Self.date(2026, 9, 15, hour: 13), calendar: cal).map(\.title) == ["morning", "evening"])
        #expect(snap.monthWordCount == 9) // hidden entry's words never counted
        #expect(snap.excludedPrivateCount == 1) // only September's private entry
        #expect(snap.averageMood == .neutral)

        let included = CalendarMonthSnapshot(scopedEntries: scoped + [hiddenSep], journal: journal,
                                             anchorMonth: Self.date(2026, 9, 10), visibility: .includePrivate,
                                             reference: Self.today, calendar: cal)
        #expect(included.excludedPrivateCount == 0)
        #expect(included.monthEntries.count == 4)

        let empty = CalendarMonthSnapshot(scopedEntries: scoped, journal: journal,
                                          anchorMonth: Self.date(2026, 7, 4), visibility: .visibleOnly,
                                          reference: Self.today, calendar: cal)
        #expect(empty.monthEntries.isEmpty && empty.writingDays.isEmpty && empty.averageMood == nil)
        #expect(CalendarMonthSnapshot.averageMood([]) == nil)
    }
}
