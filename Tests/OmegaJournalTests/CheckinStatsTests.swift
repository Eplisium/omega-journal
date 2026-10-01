import Foundation
import Testing
@testable import OmegaJournalCore

@Suite("Check-in statistics")
struct CheckinStatsTests {
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 1; return c }
    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }

    @Test("pearson known values")
    func pearson() {
        #expect(abs(CheckinStats.pearson([1, 2, 3, 4], [2, 4, 6, 8])! - 1) < 1e-9)
        #expect(abs(CheckinStats.pearson([1, 2, 3, 4], [8, 6, 4, 2])! + 1) < 1e-9)
        #expect(CheckinStats.pearson([1, 1, 1], [1, 2, 3]) == nil)
        #expect(CheckinStats.pearson([1, 2], [1, 2]) == nil)
    }

    @Test("correlation pairs only days with both values")
    func correlationPairs() {
        let metric = ["2026-01-01": 6.0, "2026-01-02": 7.0, "2026-01-03": 8.0, "2026-01-04": 9.0, "2026-01-05": 5.0, "2026-01-09": 1.0]
        let mood = ["2026-01-01": 2.0, "2026-01-02": 3.0, "2026-01-03": 4.0, "2026-01-04": 5.0, "2026-01-05": 1.0, "2026-02-01": 3.0]
        let r = CheckinStats.correlation(metricValues: metric, dailyMood: mood)!
        #expect(r.n == 5)
        #expect(r.r > 0.99)
        #expect(r.strength == .strong)
        #expect(r.sentence(metric: "sleep").contains("Strong"))
    }

    @Test("too few pairs reports no strength")
    func fewPairs() {
        let r = CorrelationResult(r: 0.9, n: 3)
        #expect(r.strength == .none)
        #expect(r.sentence(metric: "sleep").contains("at least"))
    }

    @Test("mood split by threshold")
    func split() {
        let s = CheckinStats.moodSplit(metricValues: ["a": 8, "b": 7, "c": 5], dailyMood: ["a": 5, "b": 4, "c": 2], threshold: 7)
        #expect(s.highAverage == 4.5)
        #expect(s.lowAverage == 2)
        #expect(s.highDays == 2 && s.lowDays == 1)
    }

    @Test("mood by weekday orders from first weekday and averages")
    func weekday() {
        // 2026-10-05 is a Monday, 2026-10-12 Monday, 2026-10-04 Sunday
        let samples = [(Self.date(2026, 10, 5), 4), (Self.date(2026, 10, 12), 2), (Self.date(2026, 10, 4), 5)]
        let out = CheckinStats.moodByWeekday(samples, calendar: Self.cal)
        #expect(out.count == 7)
        #expect(out[0].weekday == 1 && out[0].averageMood == 5)
        #expect(out[1].weekday == 2 && out[1].averageMood == 3 && out[1].entryCount == 2)
        #expect(out[2].averageMood == nil)
    }

    @Test("tag mood delta ignores rare tags and sorts by magnitude")
    func tags() {
        let s: [(mood: Int, tags: [String])] = [(5, ["run"]), (5, ["run"]), (5, ["Run"]), (1, ["work"]), (1, ["work"]), (1, ["work"]), (3, ["rare"])]
        let out = CheckinStats.moodByTag(s, minCount: 3)
        #expect(out.map(\.tag).sorted() == ["run", "work"])
        #expect(out.first!.delta != 0)
        #expect(out.first(where: { $0.tag == "run" })!.delta > 0)
        #expect(out.first(where: { $0.tag == "work" })!.delta < 0)
    }

    @Test("day keys round-trip")
    func dayKey() {
        let d = Self.date(2026, 3, 9)
        #expect(DayKey.string(from: d, calendar: Self.cal) == "2026-03-09")
        #expect(Self.cal.component(.day, from: DayKey.date(from: "2026-03-09", calendar: Self.cal)!) == 9)
        #expect(DayKey.date(from: "bad") == nil)
    }

    @Test("streak history lists runs longest first")
    func runs() {
        let days: Set<Date> = [Self.date(2026, 1, 1), Self.date(2026, 1, 2), Self.date(2026, 1, 3), Self.date(2026, 1, 10), Self.date(2026, 1, 11), Self.date(2026, 2, 1)]
        let r = StreakHistory.runs(days: days, calendar: Self.cal)
        #expect(r.map(\.length) == [3, 2, 1])
    }
}

@Suite("Habit statistics")
struct HabitStatsTests {
    static var cal: Calendar { CheckinStatsTests.cal }
    static let today = CheckinStatsTests.date(2026, 10, 10)

    @Test("current streak survives an unchecked today")
    func streak() {
        let done: Set<String> = ["2026-10-09", "2026-10-08", "2026-10-07", "2026-10-01"]
        #expect(HabitStats.currentStreak(doneDays: done, today: Self.today, calendar: Self.cal) == 3)
        #expect(HabitStats.currentStreak(doneDays: done.union(["2026-10-10"]), today: Self.today, calendar: Self.cal) == 4)
        #expect(HabitStats.currentStreak(doneDays: ["2026-10-01"], today: Self.today, calendar: Self.cal) == 0)
    }

    @Test("completion rate over a window")
    func rate() {
        let done: Set<String> = ["2026-10-10", "2026-10-09", "2026-10-08", "2026-10-01"]
        #expect(HabitStats.completionRate(doneDays: done, days: 4, today: Self.today, calendar: Self.cal) == 0.75)
    }

    @Test("daily completion is share of habits")
    func daily() {
        let out = HabitStats.dailyCompletion(habitIds: ["a", "b"], log: ["a": ["d1", "d2"], "b": ["d1"]])
        #expect(out["d1"] == 1 && out["d2"] == 0.5)
        #expect(HabitStats.dailyCompletion(habitIds: [], log: ["a": ["d1"]]).isEmpty)
    }

    @Test("mood on days habit done vs not")
    func moodSplit() {
        let r = HabitStats.moodWithHabit(doneDays: ["a"], dailyMood: ["a": 5, "b": 2, "c": 4])
        #expect(r.done == 5 && r.notDone == 3)
    }
}
