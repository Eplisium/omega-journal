import SwiftUI
import Charts
import OmegaJournalCore

// MARK: - Private supporting views

struct InsightSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(OmegaTheme.font(.heading, .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                Text(subtitle)
                    .font(OmegaTheme.font(.caption))
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

struct ReflectionMetric: View {
    let value: String
    let label: String
    let detail: String
    let icon: String
    let tint: Color
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(OmegaTheme.font(.heading, .medium))
                .foregroundColor(tint)
                .frame(width: 33, height: 33)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(OmegaTheme.font(.heading, .bold, design: .rounded))
                    .foregroundColor(theme.titleTextColor)
                    .lineLimit(1)
                Text(label)
                    .font(OmegaTheme.font(.meta, .semibold))
                    .foregroundColor(theme.bodyTextColor)
                Text(detail)
                    .font(OmegaTheme.font(.meta))
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

struct PatternRow: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(OmegaTheme.font(.caption, .semibold))
                .foregroundColor(tint)
                .frame(width: 27, height: 27)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.13)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                Text(value)
                    .font(OmegaTheme.font(.caption, .semibold))
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
struct MoodCheckInChart: View {
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
                    Text(label).font(OmegaTheme.font(.meta))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(OmegaTheme.font(.meta))
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
                        .font(OmegaTheme.font(.bodyLarge))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(OmegaTheme.font(.caption, .semibold, design: .rounded))
                            .foregroundColor(.white)
                        Text(hoverTitleProvider(point))
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(.white.opacity(0.78))
                            .lineLimit(2)
                        if onOpenDay != nil {
                            Text("Click to open this day")
                                .font(OmegaTheme.font(.meta, .medium))
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
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                Text("Hover a point to see that day's entries")
                    .font(OmegaTheme.font(.meta, .medium))
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
struct MoodDistributionRow: View {
    let data: [MoodCount]
    let averageMood: Mood?
    @ObservedObject private var theme = ThemeManager.shared

    private var maxCount: Int { data.map(\.count).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(data) { item in
                HStack(spacing: 10) {
                    Text(item.mood.emoji)
                        .font(OmegaTheme.font(.bodyLarge))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.mood.label)
                                .font(OmegaTheme.font(.meta, .medium))
                                .foregroundColor(theme.secondaryTextColor)
                            Spacer()
                            Text("\(item.count)")
                                .font(OmegaTheme.font(.meta, .bold, design: .rounded))
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
                        .font(OmegaTheme.font(.meta, .semibold))
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
struct WeekdayRhythmChart: View {
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
                        .font(OmegaTheme.font(.meta))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(theme.secondaryTextColor.opacity(0.08))
                AxisValueLabel()
                    .font(OmegaTheme.font(.meta))
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Entries per weekday chart")
    }
}

/// A compact, clickable row for the recent-writing section.
struct InsightsEntryRow: View {
    let entry: JournalEntry
    let onOpen: () -> Void
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Text(entry.mood.emoji)
                    .font(OmegaTheme.font(.bodyLarge))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if entry.isHidden {
                            Image(systemName: "lock.open")
                                .font(OmegaTheme.font(.meta, .semibold))
                                .foregroundColor(theme.accentColor)
                                .accessibilityHidden(true)
                        }
                        Text(entry.displayTitle)
                            .font(OmegaTheme.font(.caption, .semibold))
                            .foregroundColor(theme.titleTextColor)
                            .lineLimit(1)
                    }
                    Text("\(entry.createdAt.formatted(.dateTime.month(.abbreviated).day())) · \(entry.wordCount) words")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(OmegaTheme.font(.meta, .semibold))
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
struct DayEntriesSheet: View {
    let day: Date
    let entries: [JournalEntry]
    let onOpen: (JournalEntry) -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private static let dayFormatter = DateFormatters.fullDate

    private var sortedEntries: [JournalEntry] {
        entries.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.dayFormatter.string(from: day))
                        .font(OmegaTheme.font(.bodyLarge, .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                    Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries") written this day")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Label("Close", systemImage: "xmark")
                        .font(OmegaTheme.font(.meta, .semibold))
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
struct WritingVolumeChart: View {
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
                        .font(OmegaTheme.font(.meta))
                }
            }
            .frame(height: 190)
            .accessibilityLabel("Writing volume chart")
        }
    }
}

func chartEmptyState(_ message: String, icon: String) -> some View {
    HStack {
        Spacer()
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(OmegaTheme.font(.title, .light))
                .foregroundColor(.secondary.opacity(0.55))
            Text(message)
                .font(OmegaTheme.font(.caption))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 32)
        Spacer()
    }
}
