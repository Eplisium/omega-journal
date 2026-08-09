import SwiftUI
import Charts

// MARK: - Insights Dashboard

struct InsightsView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                statGrid
                trendSection
                distributionSection
                heatmapSection
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.backgroundColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insights")
                .font(OmegaTheme.titleFont)
            Text("Your journaling, visualized")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }

    private var statGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            InsightStat(value: "\(vm.entryCount)", label: "Total entries", icon: "books.vertical.fill", color: .accentColor)
            InsightStat(value: "\(vm.entriesThisMonth)", label: "This month", icon: "calendar", color: .blue)
            InsightStat(value: "\(vm.writingStreak)", label: "Day streak", icon: "flame.fill", color: .orange)
            InsightStat(value: "\(vm.longestStreak)", label: "Best streak", icon: "trophy.fill", color: .yellow)
            InsightStat(value: String(format: "%.1f", vm.averageMood), label: "Avg mood", icon: "face.smiling", color: .green)
            InsightStat(value: vm.totalWordCount.formatted(), label: "Total words", icon: "text.word.spacing", color: .purple)
            InsightStat(value: vm.totalReadingTime, label: "Reading time", icon: "clock.fill", color: .teal)
        }
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Mood trend", subtitle: "Last 30 days · dashed line = neutral")
            MetricCard {
                MoodTrendChartView(data: vm.moodTrend(days: 30))
            }
        }
    }

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Mood distribution", subtitle: "How often each mood appears")
            MetricCard {
                MoodDistributionView(data: vm.moodDistribution)
            }
        }
    }

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Writing activity", subtitle: "Last 26 weeks of entries")
            MetricCard {
                HeatmapView(info: vm.dailyInfo(daysBack: 26 * 7))
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Insight Stat Card

struct InsightStat: View {
    let value: String, label: String, icon: String, color: Color
    @ObservedObject private var theme = ThemeManager.shared

    private var isDark: Bool { theme.colorScheme == .dark }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                .fill(theme.cardColor.opacity(isDark ? 0.5 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                .strokeBorder(
                    isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Metric Card Container

struct MetricCard<Content: View>: View {
    @ViewBuilder let content: Content
    @ObservedObject private var theme = ThemeManager.shared

    private var isDark: Bool { theme.colorScheme == .dark }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .fill(theme.cardColor.opacity(isDark ? 0.4 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .strokeBorder(
                        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08),
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - Mood Trend Chart

struct MoodTrendChartView: View {
    let data: [MoodPoint]
    var body: some View {
        if data.isEmpty {
            emptyChart("No mood data yet — start writing!")
        } else {
            Chart(data) { point in
                LineMark(x: .value("Date", point.date), y: .value("Mood", point.avg))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor.gradient)
                    .symbol(Circle().strokeBorder(lineWidth: 1))
                    .symbolSize(24)
                RuleMark(y: .value("Neutral", 3.0))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }
            .chartYScale(domain: 1...5)
            .chartYAxis {
                AxisMarks(values: [1, 2, 3, 4, 5]) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
                    AxisValueLabel {
                        let label = [1: "😞", 2: "😕", 3: "😐", 4: "🙂", 5: "😄"][v.as(Int.self) ?? 3] ?? ""
                        Text(label).font(.system(size: 10))
                    }
                }
            }
            .frame(height: 180)
        }
    }
}

// MARK: - Mood Distribution Chart

struct MoodDistributionView: View {
    let data: [MoodCount]
    var body: some View {
        Chart(data) { item in
            BarMark(x: .value("Mood", item.mood.label), y: .value("Count", item.count))
                .foregroundStyle(item.mood.color.gradient)
                .cornerRadius(4)
            if item.count > 0 {
                RuleMark(y: .value("Count", item.count))
                    .foregroundStyle(.clear)
                    .annotation(position: .top) {
                        Text("\(item.count)").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                    }
            }
        }
        .frame(height: 150)
        .chartYAxis { AxisMarks(position: .leading) }
    }
}

// MARK: - Writing Heatmap (Contribution Graph)

struct HeatmapView: View {
    let info: [Date: JournalViewModel.DayInfo]

    @State private var hoveredDate: Date?

    private static let cal = Calendar.current
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    // Build the grid: 7 rows (weekday) x N columns (week)
    private struct WeekColumn: Identifiable {
        let id: Int
        let startDate: Date   // Sunday of this week
        let days: [Date?]     // index 0=Sun..6=Sat, nil = outside range
    }

    private var weeks: [WeekColumn] {
        let cal = Self.cal
        let today = cal.startOfDay(for: Date())
        // Go back 26 weeks from the start of the current week
        guard let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start,
              let rangeStart = cal.date(byAdding: .weekOfYear, value: -25, to: thisWeekStart)
        else { return [] }

        var result: [WeekColumn] = []
        var weekStart = rangeStart
        var idx = 0
        while weekStart <= today {
            var days: [Date?] = []
            for d in 0..<7 {
                let date = cal.date(byAdding: .day, value: d, to: weekStart)!
                if date <= today {
                    days.append(date)
                } else {
                    days.append(nil)
                }
            }
            result.append(WeekColumn(id: idx, startDate: weekStart, days: days))
            idx += 1
            weekStart = cal.date(byAdding: .weekOfYear, value: 1, to: weekStart)!
        }
        return result
    }

    // Month label positions: where each new month starts
    private struct MonthLabel: Identifiable {
        let id: Int
        let name: String
        let weekIndex: Int
        let showYear: Bool
    }

    private var monthLabels: [MonthLabel] {
        let cal = Self.cal
        let monthFmt = DateFormatter(); monthFmt.dateFormat = "MMM"
        var labels: [MonthLabel] = []
        var lastMonth = -1
        var lastYear = -1
        for (i, week) in weeks.enumerated() {
            let comp = cal.dateComponents([.year, .month], from: week.startDate)
            let m = comp.month ?? 0
            let y = comp.year ?? 0
            if m != lastMonth {
                let showYear = y != lastYear
                labels.append(MonthLabel(id: m + y * 100, name: monthFmt.string(from: week.startDate), weekIndex: i, showYear: showYear))
                lastMonth = m
                lastYear = y
            }
        }
        return labels
    }

    // Stats
    private var totalEntries: Int { info.values.reduce(0) { $0 + $1.count } }
    private var activeDays: Int { info.values.filter { $0.count > 0 }.count }
    private var maxDay: Int { info.values.map(\.count).max() ?? 0 }

    private func color(for count: Int) -> Color {
        switch count {
        case 0: Color.secondary.opacity(0.10)
        case 1: Color.green.opacity(0.30)
        case 2: Color.green.opacity(0.50)
        case 3: Color.green.opacity(0.70)
        default: Color.green
        }
    }

    private let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Summary stats row
            HStack(spacing: 16) {
                statBadge("\(totalEntries)", "entries", .green)
                statBadge("\(activeDays)", "active days", .accentColor)
                statBadge("\(weeks.count)", "weeks", .secondary)
                if maxDay > 0 {
                    statBadge("\(maxDay)", "best day", .orange)
                }
            }
            .font(.system(size: 11))

            // The contribution graph
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Month labels row
                    monthLabelsRow

                    // Grid: day labels + cells
                    HStack(alignment: .top, spacing: 0) {
                        // Day-of-week labels (only Mon, Wed, Fri for compactness)
                        VStack(spacing: cellSpacing) {
                            ForEach(0..<7, id: \.self) { di in
                                Text(di % 2 == 1 ? dayLabels[di] : "")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .frame(width: 28, height: cellSize, alignment: .trailing)
                                    .padding(.trailing, 4)
                            }
                        }

                        // Week columns
                        HStack(alignment: .top, spacing: cellSpacing) {
                            ForEach(weeks) { week in
                                VStack(spacing: cellSpacing) {
                                    ForEach(0..<7, id: \.self) { di in
                                        if let date = week.days[di] {
                                            dayCell(date)
                                        } else {
                                            Color.clear.frame(width: cellSize, height: cellSize)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Legend
            HStack(spacing: 6) {
                Text("Less")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: i))
                        .frame(width: 11, height: 11)
                }
                Text("More")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                Text("Today").font(.system(size: 10)).foregroundColor(.secondary)
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
            }
        }
    }

    private let cellSize: CGFloat = 13
    private let cellSpacing: CGFloat = 3

    @ViewBuilder
    private var monthLabelsRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            // Offset for day-label column
            Spacer().frame(width: 32)

            ZStack(alignment: .topLeading) {
                // Render month labels at their absolute x positions
                ForEach(monthLabels) { label in
                    let xOffset = CGFloat(label.weekIndex) * (cellSize + cellSpacing)
                    VStack(alignment: .leading, spacing: 0) {
                        if label.showYear {
                            Text(Self.cal.component(.year, from: weeks[label.weekIndex].startDate).description)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        Text(label.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .offset(x: xOffset)
                }
            }
            .frame(height: 28)
        }
    }

    @ViewBuilder
    private func statBadge(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let dayInfo = info[date]
        let count = dayInfo?.count ?? 0
        let hovered = hoveredDate == date

        RoundedRectangle(cornerRadius: 2)
            .fill(color(for: count))
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(
                        Self.cal.isDateInToday(date) ? Color.accentColor
                            : (hovered ? Color.white.opacity(0.5) : .clear),
                        lineWidth: Self.cal.isDateInToday(date) ? 1.5 : 1
                    )
            )
            .scaleEffect(hovered ? 1.6 : 1.0)
            .zIndex(hovered ? 10 : 0)
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.12)) {
                    hoveredDate = inside ? date : nil
                }
            }
            .popover(isPresented: Binding(
                get: { hoveredDate == date },
                set: { if !$0 && hoveredDate == date { hoveredDate = nil } }
            )) {
                dayPopover(date, info: dayInfo)
            }
    }

    @ViewBuilder
    private func dayPopover(_ date: Date, info: JournalViewModel.DayInfo?) -> some View {
        let dateStr = Self.fullDateFormatter.string(from: date)
        let count = info?.count ?? 0

        VStack(alignment: .leading, spacing: 6) {
            Text(dateStr)
                .font(.system(size: 12, weight: .semibold))

            if count == 0 {
                Text("No entries")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("\(count) \(count == 1 ? "entry" : "entries")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                    if let moods = info?.moods, !moods.isEmpty {
                        Text("·").foregroundColor(.secondary)
                        ForEach(moods.prefix(5).indices, id: \.self) { i in
                            Text(moods[i].emoji).font(.system(size: 11))
                        }
                    }
                }

                if let titles = info?.titles, !titles.isEmpty {
                    Divider()
                    ForEach(titles.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.accentColor.opacity(0.6))
                                .frame(width: 4, height: 4)
                            Text(titles[i])
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if count > 3 {
                        Text("+ \(count - 3) more…")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            }
        }
        .padding(10)
        .frame(minWidth: 140)
    }
}

// MARK: - Empty Chart Placeholder

func emptyChart(_ message: String) -> some View {
    HStack {
        Spacer()
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 28)).foregroundColor(.secondary.opacity(0.5))
            Text(message).font(.system(size: 13)).foregroundColor(.secondary)
        }
        .padding(.vertical, 30)
        Spacer()
    }
}

// MARK: - Markdown Exporter

enum MDExporter {
    static func export(_ entries: [JournalEntry], to url: URL) throws {
        var md = "# Omega Journal Export\n\n"
        md += "_Generated \(Date().formatted(date: .long, time: .shortened)) — \(entries.count) entries_\n\n"
        for e in entries {
            md += "## \(e.title.isEmpty ? "Untitled" : e.title)\n\n"
            md += "- **Date:** \(e.createdAt.formatted(date: .long, time: .shortened))\n"
            md += "- **Mood:** \(e.mood.label) \(e.mood.emoji)\n"
            if !e.tags.isEmpty {
                md += "- **Tags:** \(e.tags.map { "#\($0)" }.joined(separator: " "))\n"
            }
            md += "\n\(e.body.isEmpty ? "_No content_" : e.body)\n\n---\n\n"
        }
        try md.write(to: url, atomically: true, encoding: .utf8)
    }
}
