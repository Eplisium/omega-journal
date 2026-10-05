import Foundation
import Testing
import OmegaJournalCore

@Suite("Activity stats")
struct ActivityStatsTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test("empty input yields no habit")
    func empty() {
        #expect(ActivityStats.mostProductiveWeekday([], calendar: cal) == nil)
        #expect(ActivityStats.mostProductiveHour([], calendar: cal) == nil)
        #expect(ActivityStats.wordsPerDay([], days: 0, calendar: cal).isEmpty)
    }

    @Test("most productive weekday and hour, with deterministic ties")
    func habits() {
        // 2026-10-05 is a Monday; 10-06 Tuesday.
        let s = [ActivitySample(date: date(2026, 10, 5, 21), words: 1),
                 ActivitySample(date: date(2026, 10, 12, 21), words: 1),
                 ActivitySample(date: date(2026, 10, 6, 9), words: 1)]
        #expect(ActivityStats.mostProductiveWeekday(s, calendar: cal) == "Monday")
        #expect(ActivityStats.mostProductiveHour(s, calendar: cal) == 21)
        let tie = [ActivitySample(date: date(2026, 10, 6, 9), words: 1), ActivitySample(date: date(2026, 10, 5, 9), words: 1)]
        #expect(ActivityStats.mostProductiveWeekday(tie, calendar: cal) == "Monday") // Monday (2) beats Tuesday (3) on a tie
    }

    @Test("hour labels", arguments: [(0, "12 AM"), (9, "9 AM"), (12, "12 PM"), (21, "9 PM")])
    func labels(_ hour: Int, _ label: String) {
        #expect(ActivityStats.hourLabel(hour) == label)
    }

    @Test("weekday counts always cover 1...7")
    func weekdays() {
        let counts = ActivityStats.countsByWeekday([ActivitySample(date: date(2026, 10, 5), words: 1)], calendar: cal)
        #expect(counts.count == 7)
        #expect(counts[2] == 1) // Monday
        #expect(counts[1] == 0)
    }

    @Test("words per day sums same-day entries and zero-fills gaps, oldest first")
    func volume() {
        let now = date(2026, 10, 5, 18)
        let s = [ActivitySample(date: date(2026, 10, 5, 8), words: 100),
                 ActivitySample(date: date(2026, 10, 5, 20), words: 50),
                 ActivitySample(date: date(2026, 10, 3, 10), words: 7)]
        let out = ActivityStats.wordsPerDay(s, days: 3, now: now, calendar: cal)
        #expect(out.map(\.words) == [7, 0, 150])
        #expect(out.first!.date < out.last!.date)
    }
}
