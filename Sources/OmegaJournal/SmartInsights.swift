import Foundation
import SwiftUI
import OmegaJournalCore

// MARK: - Reflection data for Insights (privacy-scoped)
//
// Every function here reads `scopedAnalyticsEntries` / `reflectionEntries`, which already exclude
// hidden entries unless the user opted in AND is biometrically unlocked.

struct ThemeSnapshot: Equatable {
    var keywords: [KeywordCount] = []
    /// -1…1 average NLTagger sentiment, nil when nothing could be scored.
    var averageSentiment: Double?
    var positiveDays = 0
    var negativeDays = 0
    var analyzedEntries = 0
}

struct CheckinCorrelationRow: Identifiable, Equatable {
    let id: String
    let name: String
    let result: CorrelationResult
}

struct HabitInsightRow: Identifiable, Equatable {
    let id: String
    let name: String
    let streak: Int
    let rate30: Double
    let moodDone: Double?
    let moodNotDone: Double?
}

extension JournalViewModel {
    func moodSamples(_ source: [JournalEntry]) -> [(date: Date, mood: Int)] {
        source.map { ($0.createdAt, $0.mood.rawValue) }
    }

    /// Average mood per weekday for the scoped entries.
    func weekdayMood(for source: [JournalEntry]) -> [WeekdayMood] {
        CheckinStats.moodByWeekday(moodSamples(source))
    }

    /// Tags that go with happier / lower days.
    func tagMood(for source: [JournalEntry]) -> [TagMood] {
        CheckinStats.moodByTag(source.map { ($0.mood.rawValue, $0.tags) })
    }

    /// On-device NaturalLanguage themes + sentiment. Capped to the 300 most recent entries.
    func themeSnapshot(for source: [JournalEntry]) -> ThemeSnapshot {
        let recent = source.sorted { $0.createdAt > $1.createdAt }.prefix(300)
        let texts = recent.map { [$0.title, $0.body].filter { !$0.isEmpty }.joined(separator: ". ") }
        var snap = ThemeSnapshot()
        snap.keywords = TextInsights.topKeywords(in: texts, limit: 24)
        let scores = texts.compactMap { TextInsights.sentiment(of: $0) }
        snap.analyzedEntries = scores.count
        snap.averageSentiment = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        snap.positiveDays = scores.filter { TextInsights.band($0) == .positive }.count
        snap.negativeDays = scores.filter { TextInsights.band($0) == .negative }.count
        return snap
    }

    /// Mood vs each check-in metric (sleep, energy, stress, custom).
    func checkinCorrelations(for source: [JournalEntry], store: CheckinStore) -> [CheckinCorrelationRow] {
        let mood = CheckinStats.dailyMood(moodSamples(source))
        return store.metrics.compactMap { m in
            guard let r = CheckinStats.correlation(metricValues: store.series(m.id), dailyMood: mood) else { return nil }
            return CheckinCorrelationRow(id: m.id, name: m.name.lowercased(), result: r)
        }
        .sorted { abs($0.result.r) > abs($1.result.r) }
    }

    func habitInsights(for source: [JournalEntry], store: CheckinStore) -> [HabitInsightRow] {
        let mood = CheckinStats.dailyMood(moodSamples(source))
        return store.habits.map { h in
            let done = store.habitLog[h.id] ?? []
            let split = HabitStats.moodWithHabit(doneDays: done, dailyMood: mood)
            return HabitInsightRow(id: h.id, name: h.name, streak: store.streak(h.id),
                                   rate30: HabitStats.completionRate(doneDays: done, days: 30, today: Date()),
                                   moodDone: split.done, moodNotDone: split.notDone)
        }
    }

    func streakRuns(for source: [JournalEntry]) -> [StreakRun] {
        StreakHistory.runs(days: Set(source.map { Calendar.current.startOfDay(for: $0.createdAt) }))
    }

    // MARK: Year in review

    func yearReview(year: Int) -> YearReview {
        // Year in review follows the same privacy scope as every other reflective surface.
        let src = reflectionEntries(period: .allTime)
        return YearReviewBuilder.build(year: year, entries: src.map {
            YearReviewEntry(title: $0.title, wordCount: $0.wordCount, mood: $0.mood.rawValue, tags: $0.tags,
                            createdAt: $0.createdAt, isFavorite: $0.isFavorite)
        })
    }

    var yearReviewYears: [Int] {
        YearReviewBuilder.availableYears(reflectionEntries(period: .allTime).map {
            YearReviewEntry(title: $0.title, wordCount: $0.wordCount, mood: $0.mood.rawValue, tags: $0.tags, createdAt: $0.createdAt)
        })
    }

    // MARK: On This Day v2

    /// Memories from this month/day, grouped by year (newest first). Respects the hidden-entry scope.
    var onThisDayByYear: [OnThisDayYear<JournalEntry>] {
        OnThisDayGrouping.group(calendarEntries, date: { $0.createdAt })
    }

    // MARK: Weekly / monthly review → entry

    func reviewDraft(_ period: ReviewPeriod, reference: Date = Date()) -> ReviewDraft {
        // Hidden entries never feed a review draft; reviews are saved as normal (visible) entries.
        let src = entries.filter { !$0.isHidden }.map {
            ReviewEntry(title: $0.title, body: $0.body, mood: $0.mood.rawValue, tags: $0.tags,
                        createdAt: $0.createdAt, isFavorite: $0.isFavorite, isPinned: $0.isPinned, isHidden: false)
        }
        return ReviewGenerator.draft(period: period, entries: src, reference: reference)
    }

    /// One click: creates (and opens) an entry containing the generated review. Idempotent per
    /// period: a review with the same title is opened instead of duplicated.
    @discardableResult
    func saveReviewAsEntry(_ period: ReviewPeriod, reference: Date = Date()) -> JournalEntry {
        let draft = reviewDraft(period, reference: reference)
        let bare = draft.body.hasPrefix("# \(draft.title)") ? String(draft.body.dropFirst(draft.title.count + 2)).trimmingCharacters(in: .whitespacesAndNewlines) : draft.body
        if let existing = entries.first(where: { $0.title == draft.title && $0.tags.contains("review") }) {
            select(existing)
            showToast("Opened your existing \(period == .week ? "weekly" : "monthly") review")
            return existing
        }
        let entry = createEntry(title: draft.title, body: bare, tags: ["review"])
        showToast("Saved \(draft.title)")
        return entry
    }
}
