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
                goalSection
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

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Writing Goals", subtitle: "Track your daily and weekly progress")
            MetricCard {
                InsightsGoalView()
            }
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
            sectionTitle("Writing activity", subtitle: "Last 26 weeks · hover a day for details")
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

// MARK: - Insights Goal View

struct InsightsGoalView: View {
    @ObservedObject private var goals = GoalManager.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 24) {
            ForEach(goals.goals) { goal in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(theme.cardColor.opacity(0.8), lineWidth: 5)
                            .frame(width: 48, height: 48)
                        Circle()
                            .trim(from: 0, to: goal.progress)
                            .stroke(goal.isComplete ? Color.green : theme.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .frame(width: 48, height: 48)
                            .rotationEffect(.degrees(-90))
                        if goal.isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.green)
                        } else {
                            Text("\(Int(goal.progress * 100))%")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(goal.type.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(goal.displayProgress)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
    }
}
