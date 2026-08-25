import SwiftUI
import Charts
import OmegaJournalCore

// MARK: - Insights reflection workspace

/// A calm, scoped reflection surface. It derives entirely from the ViewModel's
/// analytics snapshot, never from the Journal's transient search result.
struct InsightsWorkspaceView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    private var entries: [JournalEntry] { vm.scopedAnalyticsEntries }
    private var writingPoints: [WordPoint] { vm.wordsPerDay(for: entries, period: vm.analyticsPeriod) }
    private var moodPoints: [MoodPoint] { vm.moodTrend(for: entries) }
    private var distribution: [MoodCount] { vm.moodDistribution(for: entries) }
    private var activity: [Date: JournalViewModel.DayInfo] { vm.dailyInfo(for: entries) }

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
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
            .frame(maxWidth: 1_200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor)
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

    // MARK: - Content

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
        }
    }

    private var writingSection: some View {
        InsightSection(title: "Writing volume", subtitle: "Words recorded across your selected period") {
            WritingVolumeChart(points: writingPoints)
        }
    }

    private var moodSection: some View {
        InsightSection(title: "Mood check-ins", subtitle: "Each point is a day you chose to record") {
            MoodCheckInChart(points: moodPoints)
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
            }
        }
    }

    private var activitySection: some View {
        InsightSection(title: "Writing activity", subtitle: "Select a day to inspect its contribution") {
            HeatmapView(info: activity)
        }
    }

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

    // MARK: - Derived descriptions

    private var averageMood: Mood? {
        guard let average = vm.analyticsAverageMood else { return nil }
        return Mood(rawValue: Int(average.rounded())) ?? .neutral
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

private struct MoodCheckInChart: View {
    let points: [MoodPoint]
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        if points.isEmpty {
            chartEmptyState("No mood check-ins in this period.", icon: "face.smiling")
        } else {
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
            .frame(height: 190)
            .accessibilityLabel("Mood check-in chart")
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
