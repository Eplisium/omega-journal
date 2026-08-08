import SwiftUI
import Charts

// MARK: - Insights Dashboard

struct InsightsView: View {
    @ObservedObject var vm: JournalViewModel

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                statGrid
                trendSection
                distributionSection
                heatmapSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insights").font(OmegaTheme.titleFont)
            Text("Your journaling, visualized").font(.system(size: 13)).foregroundColor(.secondary)
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
                HeatmapView(counts: vm.dailyCounts(daysBack: 26 * 7))
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }
}

// MARK: - Insight Stat Card

struct InsightStat: View {
    let value: String, label: String, icon: String, color: Color
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 18, weight: .medium)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 18, weight: .bold))
                Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Metric Card Container

struct MetricCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
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

// MARK: - Writing Heatmap

struct HeatmapView: View {
    let counts: [Date: Int]

    private struct Week: Identifiable {
        let id: Int
        let days: [Date?]
    }

    private var weeks: [Week] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let anchor = cal.date(byAdding: .day, value: 1, to: today),
              let firstDay = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)) else { return [] }
        var result: [Week] = []
        var cursor = firstDay
        var idx = 0
        while cursor < anchor {
            var week: [Date?] = []
            for _ in 0..<7 {
                week.append(cursor < anchor ? cursor : nil)
                cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            }
            result.append(Week(id: idx, days: week))
            idx += 1
        }
        return result
    }

    private func color(for count: Int) -> Color {
        switch count {
        case 0: Color.secondary.opacity(0.12)
        case 1: Color.green.opacity(0.35)
        case 2: Color.green.opacity(0.55)
        case 3: Color.green.opacity(0.75)
        default: Color.green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(weeks) { week in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { di in
                                if let date = week.days[di] {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(color(for: counts[date] ?? 0))
                                        .frame(width: 13, height: 13)
                                        .help(dayHelp(date))
                                } else {
                                    Color.clear.frame(width: 13, height: 13)
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Less").font(.system(size: 10)).foregroundColor(.secondary)
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(color(for: i)).frame(width: 11, height: 11)
                }
                Text("More").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    private func dayHelp(_ date: Date) -> String {
        let count = counts[date] ?? 0
        let verb = count == 1 ? "entry" : "entries"
        return "\(date.formatted(.dateTime.month().day().year())) · \(count) \(verb)"
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
