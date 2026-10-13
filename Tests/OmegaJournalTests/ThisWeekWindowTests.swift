import Foundation
import Testing
@testable import OmegaJournal

@Suite("This Week window excludes future-dated entries")
struct ThisWeekWindowTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func includesLastSevenDaysAndLaterToday() {
        let now = date(2026, 6, 15, 9)
        #expect(JournalViewModel.isInThisWeekWindow(date(2026, 6, 15, 23), now: now, calendar: cal))
        #expect(JournalViewModel.isInThisWeekWindow(date(2026, 6, 10), now: now, calendar: cal))
    }

    @Test func excludesFutureDaysAndOlderEntries() {
        let now = date(2026, 6, 15, 9)
        #expect(!JournalViewModel.isInThisWeekWindow(date(2026, 6, 16, 0), now: now, calendar: cal))
        #expect(!JournalViewModel.isInThisWeekWindow(date(2026, 7, 1), now: now, calendar: cal))
        #expect(!JournalViewModel.isInThisWeekWindow(date(2026, 6, 7), now: now, calendar: cal))
    }
}
