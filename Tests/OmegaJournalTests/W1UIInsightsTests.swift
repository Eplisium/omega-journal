import Foundation
import Testing
@testable import OmegaJournal
import OmegaJournalCore

@Suite("W1UI: Insights and Calendar labels")
struct W1UIInsightsTests {
    let en = Locale(identifier: "en_US")

    @Test("best day and totals carry units")
    func units() {
        #expect(UIInsightsCopy.words(34, locale: en) == "34 words")
        #expect(UIInsightsCopy.words(1, locale: en) == "1 word")
        #expect(UIInsightsCopy.entries(1, locale: en) == "1 entry")
        #expect(UIInsightsCopy.entries(1200, locale: en) == "1,200 entries")
    }

    @Test("words detail folds in the per-entry average")
    func wordsDetail() {
        #expect(UIInsightsCopy.wordsDetail(entryCount: 0, averagePerEntry: nil, locale: en) == "Nothing written yet")
        #expect(UIInsightsCopy.wordsDetail(entryCount: 1, averagePerEntry: 34, locale: en) == "Across 1 entry")
        #expect(UIInsightsCopy.wordsDetail(entryCount: 9, averagePerEntry: 16, locale: en) == "Across 9 entries · about 16 each")
    }

    @Test("average mood names its sample size")
    func mood() {
        #expect(UIInsightsCopy.moodDetail(checkIns: 0) == "No check-ins yet")
        #expect(UIInsightsCopy.moodDetail(checkIns: 1) == "From 1 check-in")
        #expect(UIInsightsCopy.moodDetail(checkIns: 9) == "From 9 check-ins")
    }

    @Test("writing days read against the period")
    func writingDays() {
        #expect(UIInsightsCopy.writingDaysDetail(writingDays: 9, periodDays: 30) == "9 of 30 days")
        #expect(UIInsightsCopy.writingDaysDetail(writingDays: 40, periodDays: 30) == "30 of 30 days")
        #expect(UIInsightsCopy.writingDaysDetail(writingDays: 9, periodDays: nil) == "All time")
    }

    @Test("correlations use words, not r values; covers every strength")
    func correlation() {
        let all = ["strong", "moderate", "weak", "none"].map(UIInsightsCopy.correlationChip(strength:))
        #expect(all == ["Strong link", "Moderate link", "Weak link", "No clear link"])
        #expect(!all.contains { $0.contains("r =") })
        // Keeps pace with the Core enum's raw values.
        #expect(UIInsightsCopy.correlationChip(strength: CorrelationResult.Strength.moderate.rawValue) == "Moderate link")
    }

    @Test("streak pattern copy")
    func streak() {
        #expect(UIInsightsCopy.streak(0) == "Start when ready")
        #expect(UIInsightsCopy.streak(1) == "1 day")
        #expect(UIInsightsCopy.streak(6) == "6 days in a row")
    }

    @Test("calendar cells are compact so a six-week month fits")
    func calendarCell() {
        #expect(CalendarDayCell.minHeight <= 64)
        #expect(CalendarDayCell.minHeight >= 52, "still a comfortable click target")
    }
}
