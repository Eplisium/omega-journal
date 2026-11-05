import Foundation
import Testing
@testable import OmegaJournalCore

/// core-10: weekly / monthly review periods are half-open [start, end).
@Suite("Audit fix core: review period boundaries")
struct AuditFixCoreReviewTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }

    private func entry(_ date: Date) -> ReviewEntry {
        ReviewEntry(title: "E", body: "x", mood: 3, tags: [], createdAt: date)
    }

    private func noon(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Self.utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test("core-10 an entry at Monday 00:00:00 belongs to that week's review only")
    func weekBoundary() {
        let c = Self.utc
        let monday = c.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        let e = entry(monday)
        #expect(ReviewGenerator.draft(period: .week, entries: [e], reference: noon(2026, 3, 5), calendar: c).entryCount == 0)
        #expect(ReviewGenerator.draft(period: .week, entries: [e], reference: noon(2026, 3, 10), calendar: c).entryCount == 1)
        // The last instant before the boundary still belongs to the earlier week.
        let sundayLate = entry(monday.addingTimeInterval(-1))
        #expect(ReviewGenerator.draft(period: .week, entries: [sundayLate], reference: noon(2026, 3, 5), calendar: c).entryCount == 1)
        #expect(ReviewGenerator.draft(period: .week, entries: [sundayLate], reference: noon(2026, 3, 10), calendar: c).entryCount == 0)
    }

    @Test("core-10 an entry at the 1st 00:00:00 belongs to that month's review only")
    func monthBoundary() {
        let c = Self.utc
        let first = c.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        let e = entry(first)
        #expect(ReviewGenerator.draft(period: .month, entries: [e], reference: noon(2026, 3, 20), calendar: c).entryCount == 0)
        #expect(ReviewGenerator.draft(period: .month, entries: [e], reference: noon(2026, 4, 2), calendar: c).entryCount == 1)
        // The period's own start is included.
        let marchFirst = entry(c.date(from: DateComponents(year: 2026, month: 3, day: 1))!)
        #expect(ReviewGenerator.draft(period: .month, entries: [marchFirst], reference: noon(2026, 3, 20), calendar: c).entryCount == 1)
    }
}
