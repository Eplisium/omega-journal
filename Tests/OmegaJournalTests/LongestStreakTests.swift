import Foundation
import Testing
@testable import OmegaJournalCore

/// core-2: the longest daily streak can never be shorter than the current one.
@Suite("Longest streak keeps days since the previous miss")
struct LongestStreakTests {
    static func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.firstWeekday = 2
        return c
    }

    private static func days(_ offsets: [Int], from base: Date, _ c: Calendar) -> Set<Date> {
        Set(offsets.map { c.date(byAdding: .day, value: $0, to: base)! })
    }

    @Test("core-2 a breaking second miss restarts the run after the previous miss")
    func longestNotBelowCurrent() {
        let c = Self.cal("UTC")
        // W M W W W M W W W W W W W  (misses 4 days apart: the second one breaks)
        let base = c.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12))!
        let days = Self.days([0, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12], from: base, c)
        let today = c.date(byAdding: .day, value: 12, to: base)!
        #expect(StreakCalculator.dailyStreak(writingDays: days, today: today, calendar: c) == 10)
        #expect(StreakCalculator.longestDailyStreak(writingDays: days, calendar: c) == 10)
        let s = StreakCalculator.summary(writingDays: days, mode: .dailyWithRest, today: today, calendar: c)
        #expect(s.current == 10 && s.longest == 10)
    }

    @Test("core-2 back-to-back misses still end the run; old rules unchanged")
    func unchangedRules() {
        let c = Self.cal("UTC")
        let base = c.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 12))!
        // W W M M W W W: two misses in a row — the best run is the last 3 days.
        #expect(StreakCalculator.longestDailyStreak(writingDays: Self.days([0, 1, 4, 5, 6], from: base, c), calendar: c) == 3)
        // W M W W W W W W M W: misses 7 apart are both forgiven.
        #expect(StreakCalculator.longestDailyStreak(writingDays: Self.days([0, 2, 3, 4, 5, 6, 7, 9], from: base, c),
                                                    calendar: c) == 8)
        // Gaps of 2+ days end a run; the longest of several runs wins.
        #expect(StreakCalculator.longestDailyStreak(writingDays: Self.days([0, 1, 2, 10, 11], from: base, c), calendar: c) == 3)
    }

    /// Longest = the best current streak over every written day (same grace rule), for many
    /// seeded random histories, in UTC and across Santiago's midnight DST jumps.
    @Test("core-2 longest equals the best current streak over every day (seeded random histories)",
          arguments: ["UTC", "America/Santiago"])
    func longestMatchesBestCurrent(tz: String) {
        let c = Self.cal(tz)
        let base = c.date(from: DateComponents(year: 2019, month: 8, day: 20, hour: 12))!
        var seed: UInt64 = 0x5EED_C0DE
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        for _ in 0..<60 {
            let length = 20 + Int(next() % 40)
            let missRate = 1 + next() % 4
            let offsets = (0..<length).filter { _ in next() % (missRate + 3) >= missRate }
            guard !offsets.isEmpty else { continue }
            let days = Self.days(offsets, from: base, c)
            let longest = StreakCalculator.longestDailyStreak(writingDays: days, calendar: c)
            let best = offsets.map { off in
                StreakCalculator.dailyStreak(writingDays: days, today: c.date(byAdding: .day, value: off, to: base)!, calendar: c)
            }.max() ?? 0
            #expect(longest == best, "\(tz) offsets \(offsets): longest \(longest), best current \(best)")
        }
    }

    @Test("core-2 summary never reports a longest below the current streak (both modes)")
    func summaryClamp() {
        let c = Self.cal("UTC")
        let base = c.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12))!
        let days = Self.days(Array(0..<21), from: base, c)
        let today = c.date(byAdding: .day, value: 20, to: base)!
        for mode in StreakMode.allCases {
            let s = StreakCalculator.summary(writingDays: days, mode: mode, weeklyTarget: 3, today: today, calendar: c)
            #expect(s.longest >= s.current, "\(mode)")
        }
    }
}
