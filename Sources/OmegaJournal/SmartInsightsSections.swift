import SwiftUI
import Charts
import OmegaJournalCore

// MARK: - Phase 3 Insights sections (embedded by InsightsWorkspaceView)

/// Correlations, weekday mood, themes, habits and streak history for the scoped entries.
struct SmartInsightsSections: View {
    @ObservedObject var vm: JournalViewModel
    let entries: [JournalEntry]
    @ObservedObject private var store = CheckinStore.shared
    @ObservedObject private var theme = ThemeManager.shared
    @State private var themes = ThemeSnapshot()
    @State private var showYearReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            weekdaySection
            correlationSection
            tagMoodSection
            themesSection
            if !store.habits.isEmpty { habitSection }
            streakSection
            OmegaCard {
                OmegaSectionHeader(title: "Year in review", subtitle: "A one-page look back you can export as PDF", systemImage: "sparkles.rectangle.stack") {
                    Button("Open") { showYearReview = true }.disabled(vm.yearReviewYears.isEmpty)
                }
            }
        }
        .task(id: entries.count) { themes = vm.themeSnapshot(for: entries) }
        .sheet(isPresented: $showYearReview) { YearReviewView(vm: vm) }
    }

    private func section<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> C) -> some View {
        let body = content()
        return OmegaCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                OmegaSectionHeader(title: title, subtitle: subtitle)
                body
            }
        }
    }

    // MARK: Weekday

    private var weekdaySection: some View {
        let data = vm.weekdayMood(for: entries)
        let symbols = Calendar.current.shortWeekdaySymbols
        return section("Mood by weekday", "Average mood for each day of the week") {
            if data.allSatisfy({ $0.averageMood == nil }) {
                chartEmptyState("Not enough entries yet.", icon: "calendar")
            } else {
                Chart(data, id: \.weekday) { d in
                    if let avg = d.averageMood {
                        BarMark(x: .value("Day", symbols[d.weekday - 1]), y: .value("Mood", avg))
                            .foregroundStyle(theme.accentColor.gradient)
                            .cornerRadius(4)
                            .annotation(position: .top) {
                                Text(String(format: "%.1f", avg)).font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                            }
                    }
                }
                .chartYScale(domain: 1...5)
                .frame(height: 150)
            }
        }
    }

    // MARK: Correlations

    private var correlationSection: some View {
        let rows = vm.checkinCorrelations(for: entries, store: store)
        return section("Mood and your check-ins", "How sleep, energy, stress and your own metrics line up with mood") {
            if rows.isEmpty {
                Text("Log a few daily check-ins alongside your entries and patterns will appear here (at least \(CheckinStats.minimumPairs) days).")
                    .font(OmegaTheme.captionFont).foregroundColor(theme.secondaryTextColor)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            OmegaChip(title: String(format: "r = %+.2f", row.result.r),
                                      tone: row.result.strength == .none ? .neutral : (row.result.r >= 0 ? .success : .warning))
                            Text(row.result.sentence(metric: row.name))
                                .font(OmegaTheme.captionFont).foregroundColor(theme.titleTextColor)
                        }
                    }
                    if let sleep = sleepSplit {
                        Text(sleep).font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                    }
                }
            }
        }
    }

    private var sleepSplit: String? {
        let mood = CheckinStats.dailyMood(vm.moodSamples(entries))
        let split = CheckinStats.moodSplit(metricValues: store.series(CheckinMetric.sleepId), dailyMood: mood, threshold: 7)
        guard let hi = split.highAverage, let lo = split.lowAverage else { return nil }
        return String(format: "With 7+ hours of sleep your mood averages %.1f (%d days) vs %.1f otherwise (%d days).", hi, split.highDays, lo, split.lowDays)
    }

    // MARK: Tags

    private var tagMoodSection: some View {
        let tags = vm.tagMood(for: entries).prefix(6)
        return section("Tags and mood", "Topics that tend to lift or weigh on your mood") {
            if tags.isEmpty {
                Text("Tags used on at least 3 entries show up here.").font(OmegaTheme.captionFont).foregroundColor(theme.secondaryTextColor)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(Array(tags), id: \.tag) { t in
                        OmegaChip(title: "#\(t.tag)  \(t.delta >= 0 ? "+" : "")\(String(format: "%.1f", t.delta))",
                                  tone: t.delta >= 0 ? .success : .warning)
                            .accessibilityLabel("Tag \(t.tag): mood \(t.delta >= 0 ? "above" : "below") average by \(String(format: "%.1f", abs(t.delta)))")
                    }
                }
            }
        }
    }

    // MARK: Themes

    private var themesSection: some View {
        section("Themes & tone", "Found on this Mac with Apple's NaturalLanguage — nothing leaves your device") {
            if themes.keywords.isEmpty {
                Text("Write a little more and recurring themes will appear.").font(OmegaTheme.captionFont).foregroundColor(theme.secondaryTextColor)
            } else {
                let maxCount = Double(themes.keywords.first?.count ?? 1)
                FlowLayout(spacing: 8) {
                    ForEach(themes.keywords, id: \.word) { k in
                        let weight = Double(k.count) / maxCount
                        Text(k.word)
                            .font(OmegaTheme.font(weight > 0.66 ? .heading : (weight > 0.33 ? .bodyLarge : .body), weight > 0.5 ? .semibold : .regular, design: .serif))
                            .foregroundColor(theme.accentColor.opacity(0.55 + 0.45 * weight))
                            .padding(.horizontal, 4)
                            .accessibilityLabel("\(k.word), \(k.count) mentions")
                    }
                }
                if let s = themes.averageSentiment {
                    Text("Overall tone of your writing: \(toneWord(s)) · \(themes.positiveDays) upbeat and \(themes.negativeDays) heavier entries out of \(themes.analyzedEntries).")
                        .font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                }
            }
        }
    }

    private func toneWord(_ s: Double) -> String {
        switch TextInsights.band(s) { case .positive: "mostly positive"; case .negative: "mostly heavy"; case .neutral: "balanced" }
    }

    // MARK: Habits

    private var habitSection: some View {
        let rows = vm.habitInsights(for: entries, store: store)
        return section("Habits", "Streaks, 30-day consistency and mood on the days you do them") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { r in
                    HStack(spacing: 12) {
                        Text(r.name).font(OmegaTheme.bodyFont).foregroundColor(theme.titleTextColor).frame(width: 120, alignment: .leading)
                        ProgressView(value: r.rate30).tint(theme.accentColor).frame(width: 120)
                        Text("\(Int((r.rate30 * 100).rounded()))%").font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                        Text(r.streak > 0 ? "🔥 \(r.streak)" : "—").font(OmegaTheme.metaFont)
                        if let d = r.moodDone, let n = r.moodNotDone {
                            Text(String(format: "mood %.1f vs %.1f", d, n)).font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                        }
                    }
                }
            }
        }
    }

    // MARK: Streak history

    private var streakSection: some View {
        let runs = vm.streakRuns(for: entries).prefix(5)
        return section("Streak history", "Your longest runs of consecutive writing days") {
            if runs.isEmpty {
                Text("Your streaks will be listed here.").font(OmegaTheme.captionFont).foregroundColor(theme.secondaryTextColor)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        HStack {
                            Image(systemName: "flame.fill").foregroundColor(.orange).accessibilityHidden(true)
                            Text("\(run.length) \(run.length == 1 ? "day" : "days")")
                                .font(OmegaTheme.font(.body, .semibold)).foregroundColor(theme.titleTextColor)
                            Text("\(run.start.formatted(.dateTime.month(.abbreviated).day().year())) – \(run.end.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                        }
                    }
                }
            }
        }
    }
}
