import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// core-6 + browse-10: date-ranged smart folders and the filter bar's date
/// ranges have an upper bound, so planned (future-dated) entries don't match.
@Suite("Date ranges exclude future-dated entries")
@MainActor
struct FutureDateRangeTests {
    static func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.firstWeekday = 2
        return c
    }

    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ c: Calendar) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func rec(_ d: Date) -> SearchQuery.Record {
        .init(id: UUID().uuidString, title: "t", body: "b", tags: [], moodName: "good", moodValue: 4, createdAt: d)
    }

    private func entry(_ d: Date) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = "t"; e.body = "b"; e.createdAt = d
        return e
    }

    @Test("core-6 smart folders: day windows stop at the end of today, month/year at their end")
    func smartFolderBounds() {
        let c = Self.cal("UTC")
        let now = Self.at(2026, 3, 15, 12, 0, c)
        func matches(_ range: SmartFolder.DateRange, _ d: Date) -> Bool {
            SmartFolder(name: range.label, dateRange: range).matches(rec(d), hiddenLocked: true, now: now, calendar: c)
        }
        let lateToday = Self.at(2026, 3, 15, 23, 59, c)
        let tomorrow = Self.at(2026, 3, 16, 0, 0, c)
        let laterThisMonth = Self.at(2026, 3, 28, 12, 0, c)
        let nextMonth = Self.at(2026, 4, 1, 0, 0, c)
        let nextYear = Self.at(2027, 1, 2, 12, 0, c)
        for range in [SmartFolder.DateRange.today, .last7, .last30] {
            #expect(matches(range, lateToday), "\(range)")
            #expect(!matches(range, tomorrow), "\(range)")
        }
        #expect(matches(.thisMonth, laterThisMonth))
        #expect(!matches(.thisMonth, nextMonth))
        #expect(!matches(.thisMonth, nextYear))
        #expect(matches(.thisYear, laterThisMonth))
        #expect(!matches(.thisYear, nextYear))
        #expect(matches(.any, nextYear))
        #expect(SmartFolder.DateRange.any.end(now: now, calendar: c) == nil)
    }

    @Test("core-6 the day-window end is the real start of tomorrow on a DST eve (Santiago)")
    func smartFolderEndOnDSTEve() {
        let c = Self.cal("America/Santiago")
        let now = Self.at(2019, 9, 7, 12, 0, c)
        let end = SmartFolder.DateRange.today.end(now: now, calendar: c)
        #expect(end == c.startOfDay(for: Self.at(2019, 9, 8, 12, 0, c)))   // 01:00, midnight is skipped
        #expect(SmartFolder(name: "T", dateRange: .today)
            .matches(rec(Self.at(2019, 9, 7, 23, 30, c)), hiddenLocked: true, now: now, calendar: c))
        #expect(!SmartFolder(name: "T", dateRange: .today)
            .matches(rec(Self.at(2019, 9, 8, 1, 30, c)), hiddenLocked: true, now: now, calendar: c))
    }

    @Test("browse-10 filter bar: day windows stop at the end of today, month/year at their end")
    func entryFilterBounds() {
        let c = Self.cal("UTC")
        let now = Self.at(2026, 3, 15, 12, 0, c)
        func matches(_ range: EntryFilter.DateRange, _ d: Date) -> Bool {
            var f = EntryFilter()
            f.dateRange = range
            return f.matches(entry(d), hiddenLocked: true, now: now, calendar: c)
        }
        let lateToday = Self.at(2026, 3, 15, 23, 59, c)
        let inThreeDays = Self.at(2026, 3, 18, 9, 0, c)
        for range in [EntryFilter.DateRange.today, .last7, .last30] {
            #expect(matches(range, lateToday), "\(range)")
            #expect(!matches(range, inThreeDays), "\(range)")
        }
        #expect(matches(.thisMonth, Self.at(2026, 3, 31, 23, 0, c)))
        #expect(!matches(.thisMonth, Self.at(2026, 4, 1, 0, 0, c)))
        #expect(matches(.thisYear, Self.at(2026, 12, 31, 23, 0, c)))
        #expect(!matches(.thisYear, Self.at(2027, 1, 1, 0, 0, c)))
        #expect(matches(.any, Self.at(2030, 1, 1, 0, 0, c)))
    }

    @Test("browse-10 an entry dated in 3 days matches neither 'Today' nor 'Last 7 days' (live clock)")
    func dateFilterExcludesFuture() {
        let e = entry(Calendar.current.date(byAdding: .day, value: 3, to: Date())!)
        var f = EntryFilter()
        f.dateRange = .today
        #expect(!JournalViewModel.isInThisWeekWindow(e.createdAt))   // sidebar rule
        #expect(!f.matches(e, hiddenLocked: true), "an entry dated in 3 days matches the 'Today' filter")
        f.dateRange = .last7
        #expect(!f.matches(e, hiddenLocked: true), "an entry dated in 3 days matches 'Last 7 days'")
        // Something written now still matches.
        #expect(f.matches(entry(Date()), hiddenLocked: true))
    }
}
