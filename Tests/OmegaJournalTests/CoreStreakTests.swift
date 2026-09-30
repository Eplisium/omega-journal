import Foundation
import Testing
@testable import OmegaJournalCore

@Suite("Core streaks and tags")
struct CoreStreakTests {
    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }
    private let today = Date(timeIntervalSince1970: 1_790_000_000) // fixed reference

    private func days(_ offsets: [Int]) -> Set<Date> {
        let c = Self.cal
        let t = c.startOfDay(for: today)
        return Set(offsets.map { c.date(byAdding: .day, value: -$0, to: t)! })
    }

    @Test("consecutive days count fully")
    func consecutive() {
        #expect(StreakCalculator.dailyStreak(writingDays: days([0, 1, 2, 3]), today: today, calendar: Self.cal) == 4)
    }

    @Test("today not yet written does not break the streak")
    func todayOpen() {
        #expect(StreakCalculator.dailyStreak(writingDays: days([1, 2, 3]), today: today, calendar: Self.cal) == 3)
    }

    @Test("one missed day per 7 is forgiven")
    func oneRestDay() {
        // wrote today, yesterday, skipped 2, wrote 3,4,5
        #expect(StreakCalculator.dailyStreak(writingDays: days([0, 1, 3, 4, 5]), today: today, calendar: Self.cal) == 5)
    }

    @Test("two misses inside 7 days break the streak")
    func twoMissesBreak() {
        // misses at 2 and 4 (within 7 of each other)
        #expect(StreakCalculator.dailyStreak(writingDays: days([0, 1, 3, 5, 6]), today: today, calendar: Self.cal) == 3)
    }

    @Test("misses 7+ days apart are both forgiven")
    func spacedMisses() {
        // miss at 2 and miss at 9
        let d = days([0, 1, 3, 4, 5, 6, 7, 8, 10])
        #expect(StreakCalculator.dailyStreak(writingDays: d, today: today, calendar: Self.cal) == 9)
    }

    @Test("empty history is zero")
    func empty() {
        #expect(StreakCalculator.dailyStreak(writingDays: [], today: today, calendar: Self.cal) == 0)
        #expect(StreakCalculator.longestDailyStreak(writingDays: [], calendar: Self.cal) == 0)
    }

    @Test("longest streak forgives a single gap")
    func longest() {
        let d = days([20, 19, 17, 16, 15, 5, 4])
        #expect(StreakCalculator.longestDailyStreak(writingDays: d, calendar: Self.cal) == 5)
    }

    @Test("weekly mode counts weeks meeting the target; open week never breaks")
    func weekly() {
        let c = Self.cal
        let week = c.dateInterval(of: .weekOfYear, for: today)!.start
        func d(_ weeksBack: Int, _ n: Int) -> [Date] {
            let w = c.date(byAdding: .weekOfYear, value: -weeksBack, to: week)!
            return (0..<n).map { c.date(byAdding: .day, value: $0, to: w)! }
        }
        let set = Set(d(1, 3) + d(2, 4) + d(3, 1))
        #expect(StreakCalculator.weeklyStreak(writingDays: set, target: 3, today: today, calendar: c) == 2)
        #expect(StreakCalculator.longestWeeklyStreak(writingDays: set, target: 3, calendar: c) == 2)
    }

    @Test("summary reports unit and days since last entry")
    func summary() {
        let s = StreakCalculator.summary(writingDays: days([2]), mode: .dailyWithRest, today: today, calendar: Self.cal)
        #expect(s.unit == "day")
        #expect(s.daysSinceLastEntry == 2)
        #expect(!s.writtenToday)
    }

    @Test("welcome-back copy is never guilt-inducing")
    func copy() {
        for d in [nil, 0, 1, 3, 30] as [Int?] {
            let m = StreakCopy.welcomeBack(daysAway: d).lowercased()
            #expect(!m.contains("lost") && !m.contains("broke") && !m.contains("failed"))
        }
    }

    @Test("normalizeTags trims, strips commas and #, dedupes case-insensitively")
    func tags() {
        #expect(OmegaCore.normalizeTags([" Work ", "work", "#Life", "a,b", "", "  "]) == ["Work", "Life", "a b"])
    }
}
