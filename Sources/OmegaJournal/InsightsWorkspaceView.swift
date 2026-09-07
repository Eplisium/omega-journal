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
                .font(.system(size: 28, weight: .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text("A quieter way to notice your writing rhythm.")
                .font(.system(size: 13))
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(theme.accentColor.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text("Reflective scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text(vm.analyticsVisibilityLabel)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryTextColor)
            }

            Spacer(minLength: 12)

            if biometricAuth.isAuthenticated {
                Toggle("Include private", isOn: privateInclusionBinding)
                    .toggleStyle(.switch)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.bodyTextColor)
                    .accessibilityLabel("Include private entries in Insights")
            } else {
                Button(action: requestPrivateInclusion) {
                    Label("Unlock to include", systemImage: "lock.open")
                        .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 21, weight: .medium, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text(summaryBody)
                .font(.system(size: 13))
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
            HeatmapView(info: activity, onOpenDate: openDay)
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
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.accentColor.opacity(0.7))
            Text("No writing in this period")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text("Try a longer period, or begin a new entry when the moment feels right.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
            Button {
                NotificationCenter.default.post(name: .newEntry, object: nil)
            } label: {
                Label("Write an entry", systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
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

// MARK: - Private supporting views

private struct InsightSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryTextColor)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.cardColor.opacity(0.44)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ReflectionMetric: View {
    let value: String
    let label: String
    let detail: String
    let icon: String
    let tint: Color
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 33, height: 33)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(theme.titleTextColor)
                    .lineLimit(1)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.bodyTextColor)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(theme.cardColor.opacity(0.48)))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(theme.colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct PatternRow: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 27, height: 27)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.13)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.secondaryTextColor)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.bodyTextColor)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Mood trend with hover resolution: the nearest point highlights, and the
/// strip below names the entries behind it. A click drills into that day.
private struct MoodCheckInChart: View {
    let points: [MoodPoint]
    var hoverTitleProvider: (MoodPoint) -> String
    var onOpenDay: ((MoodPoint) -> Void)? = nil

    @ObservedObject private var theme = ThemeManager.shared
    @State private var hovered: HoveredMoodPoint?

    private struct HoveredMoodPoint {
        let point: MoodPoint
        let location: CGPoint
    }

    var body: some View {
        if points.isEmpty {
            chartEmptyState("No mood check-ins in this period.", icon: "face.smiling")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                chart
                hoverStrip
            }
        }
    }

    private var chart: some View {
        Chart(points) { point in
            PointMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Mood", point.avg)
            )
            .symbolSize(58)
            .foregroundStyle(theme.accentColor)

            RuleMark(y: .value("Neutral", 3.0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(theme.secondaryTextColor.opacity(0.38))
        }
        .chartYScale(domain: 1...5)
        .chartYAxis {
            AxisMarks(values: [1, 2, 3, 4, 5]) { value in
                AxisGridLine().foregroundStyle(theme.secondaryTextColor.opacity(0.10))
                AxisValueLabel {
                    let label = [1: "😞", 2: "😕", 3: "😐", 4: "🙂", 5: "😄"][value.as(Int.self) ?? 3] ?? ""
                    Text(label).font(.system(size: 10))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 9))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovered = resolve(location: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            hovered = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        guard let resolved = resolve(location: value.location, proxy: proxy, geometry: geometry) else { return }
                        onOpenDay?(resolved.point)
                    })

                if let hovered {
                    Circle()
                        .stroke(theme.accentColor.opacity(0.9), lineWidth: 2)
                        .background(Circle().fill(theme.accentColor.opacity(0.18)))
                        .frame(width: 16, height: 16)
                        .position(hovered.location)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(height: 190)
        .animation(.easeInOut(duration: 0.12), value: hovered?.point.date)
        .accessibilityLabel("Mood check-in chart")
    }

    @ViewBuilder
    private var hoverStrip: some View {
        if let hovered {
            let point = hovered.point
            let mood = Mood(rawValue: Int(point.avg.rounded())) ?? .neutral
            OmegaHoverCard(accent: mood.color) {
                HStack(alignment: .top, spacing: 10) {
                    Text(mood.emoji)
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                        Text(hoverTitleProvider(point))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.78))
                            .lineLimit(2)
                        if onOpenDay != nil {
                            Text("Click to open this day")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 40, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                Text("Hover a point to see that day's entries")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.75))
                Spacer(minLength: 0)
            }
            .frame(minHeight: 40)
        }
    }

    /// Nearest mood point within a forgiving horizontal band. `plotFrame` is
    /// an Anchor — resolve it through the overlay's geometry before hit-testing.
    private func resolve(location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> HoveredMoodPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let plotRect = geometry[plotFrame]
        guard plotRect.insetBy(dx: -6, dy: -10).contains(location) else { return nil }

        var best: (point: MoodPoint, distance: CGFloat)?
        for point in points {
            guard let position = proxy.position(for: (x: point.date, y: point.avg)) else { continue }
            let dx = abs(position.x - location.x)
            guard dx < 24, dx < (best?.distance ?? .greatestFiniteMagnitude) else { continue }
            best = (point, dx)
        }
        guard let best else { return nil }
        let position = proxy.position(for: (x: best.point.date, y: best.point.avg)) ?? location
        return HoveredMoodPoint(point: best.point, location: position)
    }
}

/// Horizontal mood-scale distribution with counts and a soft average chip.
private struct MoodDistributionRow: View {
    let data: [MoodCount]
    let averageMood: Mood?
    @ObservedObject private var theme = ThemeManager.shared

    private var maxCount: Int { data.map(\.count).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(data) { item in
                HStack(spacing: 10) {
                    Text(item.mood.emoji)
                        .font(.system(size: 14))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.mood.label)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(theme.secondaryTextColor)
                            Spacer()
                            Text("\(item.count)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(theme.titleTextColor)
                                .monospacedDigit()
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.cardColor.opacity(0.5))
                                Capsule()
                                    .fill(item.mood.color.opacity(item.count == 0 ? 0.12 : 0.75))
                                    .frame(width: barWidth(in: geo.size.width, count: item.count))
                            }
                        }
                        .frame(height: 6)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.mood.label): \(item.count) check-ins")
            }

            if let average = averageMood {
                HStack(spacing: 6) {
                    Spacer()
                    Label("Average \(average.emoji) \(average.label)",
                          systemImage: "line.diagonal")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.accentColor.opacity(0.13)))
                }
            }
        }
    }

    private func barWidth(in available: CGFloat, count: Int) -> CGFloat {
        guard maxCount > 0 else { return 0 }
        return available * (CGFloat(count) / CGFloat(maxCount))
    }
}

/// Entries per weekday over the scoped period — order stays Sun…Sat via a
/// numeric axis with custom labels (categorical axes sort alphabetically).
private struct WeekdayRhythmChart: View {
    let data: [WeekdayCount]
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Chart(data) { item in
            BarMark(
                x: .value("Weekday", item.weekday),
                y: .value("Entries", item.count),
                width: .fixed(22)
            )
            .cornerRadius(3)
            .foregroundStyle(theme.accentColor.gradient.opacity(0.85))
        }
        .chartXScale(domain: 0.4...7.6)
        .chartXAxis {
            AxisMarks(values: Array(1...7)) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel {
                    let weekday = value.as(Int.self) ?? 1
                    Text(Calendar.current.veryShortWeekdaySymbols[weekday - 1])
                        .font(.system(size: 9))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(theme.secondaryTextColor.opacity(0.08))
                AxisValueLabel()
                    .font(.system(size: 9))
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Entries per weekday chart")
    }
}

/// A compact, clickable row for the recent-writing section.
private struct InsightsEntryRow: View {
    let entry: JournalEntry
    let onOpen: () -> Void
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Text(entry.mood.emoji)
                    .font(.system(size: 15))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if entry.isHidden {
                            Image(systemName: "lock.open")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(theme.accentColor)
                                .accessibilityHidden(true)
                        }
                        Text(entry.displayTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.titleTextColor)
                            .lineLimit(1)
                    }
                    Text("\(entry.createdAt.formatted(.dateTime.month(.abbreviated).day())) · \(entry.wordCount) words")
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.secondaryTextColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryTextColor.opacity(isHovered ? 0.9 : 0.45))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.cardColor.opacity(isHovered ? 0.62 : 0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(isHovered ? 0.35 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open this entry in Insights")
    }
}

/// Lists every entry behind a multi-entry day; each row opens the full sheet.
private struct DayEntriesSheet: View {
    let day: Date
    let entries: [JournalEntry]
    let onOpen: (JournalEntry) -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    private var sortedEntries: [JournalEntry] {
        entries.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.dayFormatter.string(from: day))
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                    Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries") written this day")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Label("Close", systemImage: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close day entries")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(theme.cardColor.opacity(0.22))

            Divider().opacity(0.25)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sortedEntries, id: \.id) { entry in
                        CalendarEntryRow(entry: entry, onOpen: { onOpen(entry) })
                    }
                }
                .padding(16)
            }
        }
        .background(theme.backgroundColor)
    }
}

/// Daily word volume for the scoped period.
private struct WritingVolumeChart: View {
    let points: [WordPoint]
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        if points.allSatisfy({ $0.words == 0 }) {
            chartEmptyState("No words recorded in this period yet.", icon: "text.word.spacing")
        } else {
            Chart(points) { point in
                BarMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Words", point.words)
                )
                .foregroundStyle(theme.accentColor.gradient)
                .cornerRadius(4)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 9))
                }
            }
            .frame(height: 190)
            .accessibilityLabel("Writing volume chart")
        }
    }
}

private func chartEmptyState(_ message: String, icon: String) -> some View {
    HStack {
        Spacer()
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.secondary.opacity(0.55))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 32)
        Spacer()
    }
}
