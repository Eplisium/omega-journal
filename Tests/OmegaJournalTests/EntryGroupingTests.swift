import Foundation
import Testing
import OmegaJournalCore

@Suite("Entry grouping")
struct EntryGroupingTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private var now: Date { date(2026, 10, 10, 15) }

    /// Fixture mirrors the real bug: a pinned old entry, a Sept 30 entry (inside the
    /// rolling 30 days) and several August entries.
    private var fixture: [EntryGroupItem] {
        [
            EntryGroupItem(id: "pinned-aug", date: date(2026, 8, 7), isPinned: true),
            EntryGroupItem(id: "today", date: date(2026, 10, 10, 9), isPinned: false),
            EntryGroupItem(id: "yesterday", date: date(2026, 10, 9), isPinned: false),
            EntryGroupItem(id: "week", date: date(2026, 10, 6), isPinned: false),
            EntryGroupItem(id: "sep30", date: date(2026, 9, 30), isPinned: false),
            EntryGroupItem(id: "aug24", date: date(2026, 8, 24), isPinned: false),
            EntryGroupItem(id: "aug12", date: date(2026, 8, 12), isPinned: false),
            EntryGroupItem(id: "dec25", date: date(2025, 12, 25), isPinned: false),
        ]
    }

    private func sorted(_ items: [EntryGroupItem], ascending: Bool) -> [EntryGroupItem] {
        items.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return ascending ? a.date < b.date : a.date > b.date
        }
    }

    @Test("Latest: pinned first, then strictly newest-to-oldest sections")
    func latestOrder() {
        let sections = EntryGrouping.sections(for: sorted(fixture, ascending: false),
                                              groupByDate: true, fallbackTitle: "All Entries",
                                              now: now, calendar: cal)
        #expect(sections.map(\.title) == ["Pinned", "Today", "Yesterday", "Previous 7 Days",
                                          "Previous 30 Days", "August 2026", "December 2025"])
        let flat = sections.flatMap(\.ids)
        #expect(flat == ["pinned-aug", "today", "yesterday", "week", "sep30", "aug24", "aug12", "dec25"])
        // The regression: a September entry must never sort below August.
        #expect(flat.firstIndex(of: "sep30")! < flat.firstIndex(of: "aug24")!)
    }

    @Test("Oldest: sections follow the ascending list order")
    func oldestOrder() {
        let sections = EntryGrouping.sections(for: sorted(fixture, ascending: true),
                                              groupByDate: true, fallbackTitle: "All Entries",
                                              now: now, calendar: cal)
        #expect(sections.map(\.title) == ["Pinned", "December 2025", "August 2026",
                                          "Previous 30 Days", "Previous 7 Days", "Yesterday", "Today"])
        #expect(sections.flatMap(\.ids) == ["pinned-aug", "dec25", "aug12", "aug24", "sep30", "week", "yesterday", "today"])
    }

    @Test("Non-date sorts keep the global order in one section")
    func flatForTitleSort() {
        let input = [
            EntryGroupItem(id: "p", date: date(2026, 8, 1), isPinned: true),
            EntryGroupItem(id: "a", date: date(2026, 8, 1), isPinned: false),
            EntryGroupItem(id: "b", date: date(2026, 10, 10), isPinned: false),
            EntryGroupItem(id: "c", date: date(2025, 1, 1), isPinned: false),
        ]
        let sections = EntryGrouping.sections(for: input, groupByDate: false, fallbackTitle: "Entries",
                                              now: now, calendar: cal)
        #expect(sections.map(\.title) == ["Pinned", "Entries"])
        #expect(sections[1].ids == ["a", "b", "c"])
    }

    @Test("Empty input yields no sections")
    func empty() {
        #expect(EntryGrouping.sections(for: [], groupByDate: true, fallbackTitle: "x", now: now, calendar: cal).isEmpty)
    }

    @Test("Future-dated entries group with Today instead of a month bucket")
    func future() {
        #expect(EntryGrouping.bucketTitle(for: date(2026, 10, 12), now: now, calendar: cal) == "Today")
    }
}
