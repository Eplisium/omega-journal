import Foundation
import Testing
@testable import OmegaJournalCore

@Suite("Text insights (NaturalLanguage)")
struct TextInsightsTests {
    @Test("keywords surface repeated nouns and drop stopwords")
    func keywords() {
        let texts = [
            "I went to the garden today and planted tomatoes in the garden.",
            "The garden needs water. My sister visited the garden with her dog.",
            "Worked on the project at the office. The project deadline is close."
        ]
        let k = TextInsights.topKeywords(in: texts, limit: 5)
        #expect(k.first?.word == "garden")
        #expect(k.first!.count >= 3)
        #expect(!k.contains { TextInsights.stopwords.contains($0.word) })
    }

    @Test("sentiment sign and empty input")
    func sentiment() {
        #expect(TextInsights.sentiment(of: "") == nil)
        let good = TextInsights.sentiment(of: "I love this wonderful happy day, everything is great and beautiful.")
        let bad = TextInsights.sentiment(of: "This is terrible, I hate everything, awful miserable horrible day.")
        #expect(good != nil && bad != nil)
        #expect(good! > bad!)
        #expect(TextInsights.band(0.6) == .positive && TextInsights.band(-0.6) == .negative && TextInsights.band(0) == .neutral)
    }
}

@Suite("Year in review")
struct YearReviewTests {
    static var cal: Calendar { CheckinStatsTests.cal }
    static func d(_ y: Int, _ m: Int, _ day: Int) -> Date { CheckinStatsTests.date(y, m, day) }

    @Test("aggregates one year and ignores others")
    func build() {
        let e = [
            YearReviewEntry(title: "A", wordCount: 100, mood: 5, tags: ["x", "y"], createdAt: Self.d(2026, 1, 1), isFavorite: true),
            YearReviewEntry(title: "B", wordCount: 300, mood: 3, tags: ["x"], createdAt: Self.d(2026, 1, 2)),
            YearReviewEntry(title: "C", wordCount: 50, mood: 1, tags: ["z"], createdAt: Self.d(2026, 3, 5)),
            YearReviewEntry(title: "Old", wordCount: 999, mood: 1, tags: ["x"], createdAt: Self.d(2025, 6, 1)),
        ]
        let r = YearReviewBuilder.build(year: 2026, entries: e, calendar: Self.cal)
        #expect(r.entryCount == 3 && r.totalWords == 450 && r.writingDays == 3)
        #expect(r.longestStreak == 2)
        #expect(r.monthlyEntries[0] == 2 && r.monthlyEntries[2] == 1 && r.monthlyEntries[1] == 0)
        #expect(r.topTags.first?.tag == "x" && r.topTags.first?.count == 2)
        #expect(r.bestMonth == 1)
        #expect(r.longestEntryTitle == "B")
        #expect(r.favoriteTitles == ["A"])
        #expect(YearReviewBuilder.availableYears(e, calendar: Self.cal) == [2026, 2025])
    }

    @Test("empty year is safe")
    func empty() {
        let r = YearReviewBuilder.build(year: 2024, entries: [], calendar: Self.cal)
        #expect(r.entryCount == 0 && r.averageMood == nil && r.bestMonth == nil)
    }

    @Test("on this day grouped by year, newest first, excludes current year")
    func onThisDay() {
        let ref = Self.d(2026, 10, 1)
        let dates = [Self.d(2025, 10, 1), Self.d(2024, 10, 1), Self.d(2024, 10, 2), Self.d(2026, 10, 1), Self.d(2023, 10, 1)]
        let g = OnThisDayGrouping.group(dates, date: { $0 }, reference: ref, calendar: Self.cal)
        #expect(g.map(\.year) == [2025, 2024, 2023])
        #expect(g[1].items.count == 1)
    }
}

@Suite("Review schedule")
struct ReviewScheduleTests {
    static var cal: Calendar { CheckinStatsTests.cal }

    @Test("weekly fires on the chosen weekday and hour")
    func weekly() {
        let s = ReviewSchedule(weeklyEnabled: true, weeklyWeekday: 1, hour: 18)
        let now = CheckinStatsTests.date(2026, 10, 1) // Thursday
        let dates = s.upcoming(.week, after: now, count: 3, calendar: Self.cal)
        #expect(dates.count == 3)
        for d in dates {
            #expect(Self.cal.component(.weekday, from: d) == 1)
            #expect(Self.cal.component(.hour, from: d) == 18)
            #expect(d > now)
        }
        #expect(Self.cal.dateComponents([.day], from: dates[0], to: dates[1]).day == 7)
    }

    @Test("monthly clamps to day 28 and disabled yields nothing")
    func monthly() {
        let s = ReviewSchedule(monthlyEnabled: true, monthlyDay: 31, hour: 9)
        #expect(s.monthlyDay == 28)
        let dates = s.upcoming(.month, after: CheckinStatsTests.date(2026, 10, 1), count: 3, calendar: Self.cal)
        #expect(dates.map { Self.cal.component(.day, from: $0) } == [28, 28, 28])
        #expect(ReviewSchedule().upcoming(.week, after: Date(), count: 3).isEmpty)
    }
}

@Suite("App lock policy")
struct AppLockPolicyTests {
    @Test("policy matrix")
    func matrix() {
        let now = Date()
        #expect(!AppLockPolicy.shouldLock(enabled: false, timeout: .immediately, lastActive: nil, now: now))
        #expect(AppLockPolicy.shouldLock(enabled: true, timeout: .never, lastActive: nil, now: now))
        #expect(!AppLockPolicy.shouldLock(enabled: true, timeout: .never, lastActive: now.addingTimeInterval(-99_999), now: now))
        #expect(AppLockPolicy.shouldLock(enabled: true, timeout: .immediately, lastActive: now, now: now))
        #expect(!AppLockPolicy.shouldLock(enabled: true, timeout: .fiveMinutes, lastActive: now.addingTimeInterval(-120), now: now))
        #expect(AppLockPolicy.shouldLock(enabled: true, timeout: .fiveMinutes, lastActive: now.addingTimeInterval(-301), now: now))
    }
}

@Suite("Passphrase vault")
struct PassphraseVaultTests {
    @Test("round trip, wrong passphrase, tamper, non-vault")
    func roundTrip() throws {
        let plain = Data("secret journal ✍️".utf8)
        let sealed = try PassphraseVault.seal(plain, passphrase: "correct horse", iterations: 1_000)
        #expect(PassphraseVault.isVault(sealed))
        #expect(!sealed.contains(plain))
        #expect(try PassphraseVault.open(sealed, passphrase: "correct horse") == plain)
        #expect(throws: PassphraseVault.VaultError.wrongPassphraseOrCorrupt) { try PassphraseVault.open(sealed, passphrase: "nope") }
        var bad = sealed; bad[bad.count - 3] ^= 0xFF
        #expect(throws: PassphraseVault.VaultError.wrongPassphraseOrCorrupt) { try PassphraseVault.open(bad, passphrase: "correct horse") }
        #expect(throws: PassphraseVault.VaultError.notAVault) { try PassphraseVault.open(Data("hello".utf8), passphrase: "x") }
        #expect(throws: PassphraseVault.VaultError.emptyPassphrase) { try PassphraseVault.seal(plain, passphrase: "") }
    }

    @Test("two seals of the same data differ (fresh salt/nonce)")
    func randomised() throws {
        let a = try PassphraseVault.seal(Data("x".utf8), passphrase: "pw", iterations: 1_000)
        let b = try PassphraseVault.seal(Data("x".utf8), passphrase: "pw", iterations: 1_000)
        #expect(a != b)
    }
}

private extension Data {
    func contains(_ other: Data) -> Bool { range(of: other) != nil }
}
