import SwiftUI
import Charts
import OmegaJournalCore

// MARK: - Insights reflection workspace

/// A calm, scoped reflection surface. It derives entirely from the ViewModel's
/// analytics snapshot, never from the Journal's transient search result.
///
/// Interactive by design: mood points resolve the entries behind them on
/// hover, every heatmap day drills into its entries, and recent-writing rows
/// open entries directly — all through the shared drill-through sheet.
struct InsightsWorkspaceView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    @State private var presentedEntry: EntryDrillThroughRoute?
    @State private var presentedDay: DayEntriesRoute?
    @State private var workspaceSize: CGSize = .zero

    private var entries: [JournalEntry] { vm.scopedAnalyticsEntries }
    /// Habit completion share per day (dot overlay on the heatmap).
    private var habitCompletionByDate: [Date: Double] {
        var out: [Date: Double] = [:]
        for (key, v) in CheckinStore.shared.dailyHabitCompletion {
            if let d = DayKey.date(from: key) { out[Calendar.current.startOfDay(for: d)] = v }
        }
        return out
    }
    private var writingPoints: [WordPoint] { vm.wordsPerDay(for: entries, period: vm.analyticsPeriod) }
    private var moodPoints: [MoodPoint] { vm.moodTrend(for: entries) }
    private var distribution: [MoodCount] { vm.moodDistribution(for: entries) }
    private var activity: [Date: JournalViewModel.DayInfo] { vm.dailyInfo(for: entries) }
    /// Pre-computed once per render — drives chart hover lookups and drill-down.
    private var entriesByDay: [Date: [JournalEntry]] { vm.entriesByDay(for: entries) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                scopeCard
                reflectionSummary

                if entries.isEmpty {
                    emptyState
                } else {
                    heroMetrics
                    writingSection
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            moodSection.frame(maxWidth: .infinity, alignment: .leading)
                            patternsSection.frame(width: 300, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            moodSection
                            patternsSection
                        }
                    }
                    activitySection
                    distributionSection
                    rhythmSection
                    SmartInsightsSections(vm: vm, entries: entries)
                    recentWritingSection
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
            .frame(maxWidth: 1_200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { workspaceSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in workspaceSize = newSize }
            }
        )
        .sheet(item: $presentedEntry, onDismiss: finishPresentedEntry) { route in
            EntryDrillThroughSheet(vm: vm, entryID: route.entryID, contextTitle: "Insights entry")
                // Cap to the workspace so the reader/editor sheet always fits;
                // floors match the sheet's own minWidth/minHeight.
                .frame(maxWidth: max(760, workspaceSize.width * 0.94),
                       maxHeight: max(560, workspaceSize.height * 0.92))
        }
        .sheet(item: $presentedDay, onDismiss: finishPresentedEntry) { route in
            DayEntriesSheet(
                day: route.day,
                entries: entriesByDay[route.day] ?? [],
                onOpen: { openEntry($0) }
            )
            .frame(maxWidth: min(520, max(420, workspaceSize.width * 0.5)),
                   maxHeight: max(420, workspaceSize.height * 0.72))
        }
    }

    // MARK: - Entry navigation

    private func openEntry(_ entry: JournalEntry) {
        Task { @MainActor in
            guard await vm.revealIfNeeded(entry) else { return }
            vm.select(entry)
            presentedEntry = EntryDrillThroughRoute(entryID: entry.id)
        }
    }

    private func openDay(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard let dayEntries = entriesByDay[day], !dayEntries.isEmpty else { return }
        if dayEntries.count == 1 {
            openEntry(dayEntries[0])
        } else {
            presentedDay = DayEntriesRoute(day: day)
        }
    }

    private func finishPresentedEntry() {
        if let entryID = presentedEntry?.entryID, vm.editingEntryId == entryID {
            vm.stopEditing()
        }
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 24) {
                headerCopy
                Spacer(minLength: 20)
                periodSelector
            }
            VStack(alignment: .leading, spacing: 14) {
                headerCopy
                periodSelector
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Insights")
                .font(OmegaTheme.font(.heading, .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text("A quieter way to notice your writing rhythm.")
                .font(OmegaTheme.font(.body))
                .foregroundColor(theme.secondaryTextColor)
        }
    }

    private var periodSelector: some View {
        Picker("Insight period", selection: $vm.analyticsPeriod) {
            ForEach(AnalyticsPeriod.allCases) { period in
                Text(period.label).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 330, idealWidth: 430, maxWidth: 470)
        .accessibilityLabel("Insight period")
    }

    // MARK: - Scope

    private var scopeCard: some View {
        HStack(spacing: 12) {
            Image(systemName: biometricAuth.isAuthenticated ? "eye" : "lock.fill")
                .font(OmegaTheme.font(.body, .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(theme.accentColor.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text("Reflective scope")
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text(vm.analyticsVisibilityLabel)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }

            Spacer(minLength: 12)

            if biometricAuth.isAuthenticated {
                Toggle("Include private", isOn: privateInclusionBinding)
                    .toggleStyle(.switch)
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.bodyTextColor)
                    .accessibilityLabel("Include private entries in Insights")
            } else {
                Button(action: requestPrivateInclusion) {
                    Label("Unlock to include", systemImage: "lock.open")
                        .font(OmegaTheme.font(.meta, .semibold))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Authenticates before private entries can be included")
            }
        }
        .padding(14)
        .background(surface(opacity: 0.5))
        .overlay(border)
        .accessibilityElement(children: .contain)
    }

    private var privateInclusionBinding: Binding<Bool> {
        Binding(
            get: { vm.analyticsVisibility == .includePrivate },
            set: { includePrivate in
                vm.analyticsVisibility = includePrivate ? .includePrivate : .visibleOnly
            }
        )
    }

    // MARK: - Summary

    private var reflectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summaryTitle)
                .font(OmegaTheme.font(.meta, .medium, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text(summaryBody)
                .font(OmegaTheme.font(.body))
                .foregroundColor(theme.bodyTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(theme.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var summaryTitle: String {
        entries.isEmpty ? "A reflection starts with a page." : "Your \(vm.analyticsPeriod.label.lowercased()) in writing"
    }

    private var summaryBody: String {
        guard !entries.isEmpty else {
            return "Write when you are ready. Insights will stay quiet until there is something meaningful to notice."
        }
        let entryWord = entries.count == 1 ? "entry" : "entries"
        let dayWord = vm.analyticsWritingDays == 1 ? "day" : "days"
        var sentence = "You wrote \(entries.count) \(entryWord) on \(vm.analyticsWritingDays) \(dayWord), adding \(vm.analyticsWordCount.formatted()) words."
        if let mood = averageMood {
            sentence += " Your recorded check-ins centered around \(mood.emoji) \(mood.label.lowercased())."
        }
        return sentence
    }
}

// MARK: - Day drill-down route

struct DayEntriesRoute: Identifiable {
    let day: Date
    var id: TimeInterval { day.timeIntervalSince1970 }
}

// MARK: - InsightsWorkspaceView content

extension InsightsWorkspaceView {

    // MARK: Hero metrics

    private var heroMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            ReflectionMetric(
                value: "\(vm.analyticsWritingDays)",
                label: "Writing days",
                detail: vm.analyticsPeriod.label,
                icon: "calendar.badge.checkmark",
                tint: theme.accentColor
            )
            ReflectionMetric(
                value: vm.analyticsWordCount.formatted(),
                label: "Words written",
                detail: "Across \(entries.count) \(entries.count == 1 ? "entry" : "entries")",
                icon: "text.word.spacing",
                tint: .teal
            )
            ReflectionMetric(
                value: averageMood.map { "\($0.emoji) \($0.label)" } ?? "—",
                label: "Mood check-ins",
                detail: averageMood == nil ? "No check-ins yet" : "A gentle average",
                icon: "face.smiling",
                tint: .orange
            )
            ReflectionMetric(
                value: bestDay.map { "\($0.words.formatted())" } ?? "—",
                label: "Best writing day",
                detail: bestDay.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "Not yet in this period",
                icon: "flame.fill",
                tint: .pink
            )
            ReflectionMetric(
                value: entriesPerWritingDay.map { String(format: "%.1f", $0) } ?? "—",
                label: "Entries per writing day",
                detail: averageMood == nil ? "No rhythm yet" : "Your cadence",
                icon: "square.stack.3d.up",
                tint: .indigo
            )
        }
    }

    // MARK: Sections

    private var writingSection: some View {
        InsightSection(title: "Writing volume", subtitle: "Words recorded across your selected period") {
            WritingVolumeChart(points: writingPoints)
        }
    }

    private var moodSection: some View {
        InsightSection(title: "Mood check-ins", subtitle: "Hover a point to see the entries behind it · click to open the day") {
            MoodCheckInChart(points: moodPoints, hoverTitleProvider: moodHoverTitle, onOpenDay: { openDay($0.date) })
        }
    }

    private var patternsSection: some View {
        InsightSection(title: "Patterns", subtitle: "Small observations, not a score") {
            VStack(alignment: .leading, spacing: 10) {
                PatternRow(
                    icon: "calendar",
                    title: "Most active day",
                    value: mostProductiveDay,
                    tint: theme.accentColor
                )
                PatternRow(
                    icon: "clock",
                    title: "Common writing time",
                    value: mostProductiveHour,
                    tint: .teal
                )
                PatternRow(
                    icon: "flame",
                    title: "Current rhythm",
                    value: scopedWritingStreak > 0 ? "\(scopedWritingStreak)-day streak" : "Start when ready",
                    tint: .orange
                )
                PatternRow(
                    icon: "text.word.spacing",
                    title: "Average entry",
                    value: averageWordsPerEntry,
                    tint: .indigo
                )
            }
        }
    }

    private var activitySection: some View {
        InsightSection(title: "Writing activity", subtitle: "Hover for a day's story · click to open its entries") {
            HeatmapView(info: activity, habitCompletion: habitCompletionByDate, onOpenDate: openDay)
        }
    }

    private var distributionSection: some View {
        InsightSection(title: "Mood distribution", subtitle: "How your check-ins lean across the scale") {
            MoodDistributionRow(data: distribution, averageMood: averageMood)
        }
    }

    private var rhythmSection: some View {
        InsightSection(title: "Weekday rhythm", subtitle: "Which days carry your writing") {
            WeekdayRhythmChart(data: weekdayCounts)
        }
    }

    private var recentWritingSection: some View {
        InsightSection(title: "Recent writing", subtitle: "Click a row to open the entry right here") {
            let recent = entries.sorted { $0.createdAt > $1.createdAt }.prefix(4)
            if recent.isEmpty {
                chartEmptyState("Nothing written in this period yet.", icon: "book.closed")
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(recent), id: \.id) { entry in
                        InsightsEntryRow(entry: entry, onOpen: { openEntry(entry) })
                    }
                }
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(OmegaTheme.font(.display, .light))
                .foregroundColor(theme.accentColor.opacity(0.7))
            Text("No writing in this period")
                .font(OmegaTheme.font(.heading, .semibold, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text("Try a longer period, or begin a new entry when the moment feels right.")
                .font(OmegaTheme.font(.caption))
                .foregroundColor(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
            Button {
                NotificationCenter.default.post(name: .newEntry, object: nil)
            } label: {
                Label("Write an entry", systemImage: "square.and.pencil")
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.onAccentColor)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.accentColor))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .background(surface(opacity: 0.42))
        .overlay(border)
    }

    // MARK: Chart hover helpers

    /// Titles of the entries behind a mood point — what the hover card shows.
    private func moodHoverTitle(for point: MoodPoint) -> String {
        let day = Calendar.current.startOfDay(for: point.date)
        let dayEntries = entriesByDay[day] ?? []
        guard !dayEntries.isEmpty else { return point.avg.formatted(.number.precision(.fractionLength(1))) }
        return dayEntries
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.displayTitle)
            .joined(separator: " · ")
    }

    // MARK: Derived descriptions

    private var averageMood: Mood? {
        guard let average = vm.analyticsAverageMood else { return nil }
        return Mood(rawValue: Int(average.rounded())) ?? .neutral
    }

    private var bestDay: WordPoint? {
        writingPoints.max { $0.words < $1.words }.flatMap { $0.words > 0 ? $0 : nil }
    }

    private var entriesPerWritingDay: Double? {
        guard vm.analyticsWritingDays > 0 else { return nil }
        return Double(entries.count) / Double(vm.analyticsWritingDays)
    }

    private var averageWordsPerEntry: String {
        let count = entries.count
        guard count > 0 else { return "Not enough data" }
        let words = vm.analyticsWordCount / count
        return "\(words) words"
    }

    private var weekdayCounts: [WeekdayCount] {
        let cal = Calendar.current
        var counts: [Int: Int] = [:]
        for entry in entries {
            counts[cal.component(.weekday, from: entry.createdAt), default: 0] += 1
        }
        return (1...7).map {
            WeekdayCount(weekday: $0, symbol: cal.veryShortWeekdaySymbols[$0 - 1], count: counts[$0] ?? 0)
        }
    }

    private var scopedWritingStreak: Int {
        let calendar = Calendar.current
        let days = Set(entries.map { calendar.startOfDay(for: $0.createdAt) })
        guard !days.isEmpty else { return 0 }
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day), days.contains(yesterday) else {
                return 0
            }
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    private var mostProductiveDay: String {
        let calendar = Calendar.current
        var counts: [Int: Int] = [:]
        for entry in entries {
            counts[calendar.component(.weekday, from: entry.createdAt), default: 0] += 1
        }
        guard let day = counts.max(by: { $0.value < $1.value })?.key else { return "Not enough data" }
        return calendar.weekdaySymbols[day - 1]
    }

    private var mostProductiveHour: String {
        let calendar = Calendar.current
        var counts: [Int: Int] = [:]
        for entry in entries {
            counts[calendar.component(.hour, from: entry.createdAt), default: 0] += 1
        }
        guard let hour = counts.max(by: { $0.value < $1.value })?.key else { return "Not enough data" }
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display) \(hour < 12 ? "AM" : "PM")"
    }

    private func requestPrivateInclusion() {
        Task { @MainActor in
            guard await biometricAuth.authenticate() else { return }
            vm.analyticsVisibility = .includePrivate
        }
    }

    private func surface(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.cardColor.opacity(opacity))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(theme.colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08), lineWidth: 1)
    }
}
