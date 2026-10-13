import SwiftUI
import OmegaJournalCore

// MARK: - Writing Heatmap (Contribution Graph)

struct HeatmapView: View {
    let info: [Date: JournalViewModel.DayInfo]
    let onOpenDate: ((Date) -> Void)?
    /// Share (0…1) of tracked habits completed per start-of-day; drawn as a dot on the cell.
    var habitCompletion: [Date: Double] = [:]
    /// First day of the selected Insights period (nil = all time). Grid days
    /// before it are dimmed and excluded from the header stats, so a 7-day
    /// view no longer reports coverage across 26 weeks it never included.
    var periodStart: Date? = nil

    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredDate: Date?
    @State private var selectedDate: Date?

    init(
        info: [Date: JournalViewModel.DayInfo],
        habitCompletion: [Date: Double] = [:],
        periodStart: Date? = nil,
        onOpenDate: ((Date) -> Void)? = nil
    ) {
        self.info = info
        self.habitCompletion = habitCompletion
        self.periodStart = periodStart
        self.onOpenDate = onOpenDate
    }

    private static let cal = Calendar.current
    private static let fullDateFormatter = DateFormatters.fullDate
    private static let shortDateFormatter = DateFormatters.weekdayMonthDay
    private static let monthFormatter = DateFormatters.monthAbbrev

    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 3.5
    private let cellCorner: CGFloat = 3.5
    private let dayLabelWidth: CGFloat = 30

    private var isDark: Bool { theme.colorScheme == .dark }
    private var accent: Color { theme.accentColor }

    // Build the grid: 7 rows (weekday) x N columns (week)
    struct WeekColumn: Identifiable {
        let id: Int
        let startDate: Date
        let days: [Date?]
    }

    /// First day shown in the grid: the start of the week 25 weeks before this one.
    nonisolated static func gridStart(today: Date, calendar cal: Calendar) -> Date? {
        guard let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start else { return nil }
        return cal.date(byAdding: .weekOfYear, value: -25, to: thisWeekStart)
    }

    struct WindowStats: Equatable {
        let total: Int
        let activeDays: Int
        let maxDay: Int
        /// Percent of days in the window (through today) with writing; 0…100.
        let coverage: Int
    }

    /// Stats over ONLY the days the grid shows (`windowStart`…`today`), so the
    /// header never counts entries outside the grid and coverage stays ≤ 100%.
    nonisolated static func windowStats(counts: [Date: Int], windowStart: Date, today: Date,
                                        calendar: Calendar) -> WindowStats {
        let start = calendar.startOfDay(for: windowStart)
        let end = calendar.startOfDay(for: today)
        let inWindow = counts.filter { $0.key >= start && $0.key <= end }.map(\.value)
        let active = inWindow.filter { $0 > 0 }.count
        let span = max(DayKey.dayDistance(from: start, to: end, calendar: calendar) + 1, 1)
        let coverage = min(100, Int((Double(active) / Double(span) * 100).rounded()))
        return WindowStats(total: inWindow.reduce(0, +), activeDays: active,
                           maxDay: inWindow.max() ?? 0, coverage: coverage)
    }

    /// Week columns from `gridStart` through `today` (future days are nil).
    /// Built ONCE per render: it used to be a computed property read by the
    /// grid, the stats row, the month-label row and once per month label,
    /// so every hover re-ran it ~10 times.
    nonisolated static func gridWeeks(today rawToday: Date, calendar cal: Calendar) -> [WeekColumn] {
        let today = cal.startOfDay(for: rawToday)
        guard let rangeStart = Self.gridStart(today: today, calendar: cal) else { return [] }

        var result: [WeekColumn] = []
        var weekStart = rangeStart
        var idx = 0
        while weekStart <= today {
            var days: [Date?] = []
            for d in 0..<7 {
                let date = cal.date(byAdding: .day, value: d, to: weekStart)!
                days.append(date <= today ? date : nil)
            }
            result.append(WeekColumn(id: idx, startDate: weekStart, days: days))
            idx += 1
            weekStart = cal.date(byAdding: .weekOfYear, value: 1, to: weekStart)!
        }
        return result
    }

    private struct MonthLabel: Identifiable {
        let id: Int
        let name: String
        let weekIndex: Int
        let showYear: Bool
        let year: Int
    }

    private func monthLabels(for weeks: [WeekColumn]) -> [MonthLabel] {
        let cal = Self.cal
        var labels: [MonthLabel] = []
        var lastMonth = -1
        var lastYear = -1
        for (i, week) in weeks.enumerated() {
            let anchor = week.days.compactMap { $0 }.first ?? week.startDate
            let comp = cal.dateComponents([.year, .month], from: anchor)
            let m = comp.month ?? 0
            let y = comp.year ?? 0
            if m != lastMonth {
                labels.append(MonthLabel(
                    id: m + y * 100,
                    name: Self.monthFormatter.string(from: anchor),
                    weekIndex: i,
                    showYear: y != lastYear && lastYear != -1,
                    year: y
                ))
                lastMonth = m
                lastYear = y
            }
        }
        return labels
    }

    /// Header stats over the visible grid, clipped to the selected period.
    private func currentStats(today: Date) -> WindowStats {
        let gridStart = Self.gridStart(today: today, calendar: Self.cal) ?? today
        let start = ReflectionHeatmapWindow.statsStart(gridStart: gridStart, periodStart: periodStart, calendar: Self.cal)
        return Self.windowStats(counts: info.mapValues(\.count), windowStart: start, today: today, calendar: Self.cal)
    }

    /// Theme-aware intensity ramp (empty → soft surface, busy → full accent).
    private func fill(for count: Int) -> Color {
        let empty = isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
        switch count {
        case 0: return empty
        case 1: return accent.opacity(isDark ? 0.28 : 0.22)
        case 2: return accent.opacity(isDark ? 0.48 : 0.40)
        case 3: return accent.opacity(isDark ? 0.70 : 0.62)
        default: return accent.opacity(isDark ? 0.92 : 0.88)
        }
    }

    private func border(for count: Int, isToday: Bool, hovered: Bool) -> Color {
        if isToday { return accent }
        if hovered { return Color.white.opacity(isDark ? 0.55 : 0.35) }
        if count == 0 {
            return isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.06)
        }
        return accent.opacity(isDark ? 0.18 : 0.12)
    }

    private var dayLabels: [String] {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday
        return (0..<7).map { offset in
            let idx = (first - 1 + offset) % 7
            return symbols[idx]
        }
    }

    var body: some View {
        // Derive the grid and stats once per render (hover re-renders often).
        let today = Self.cal.startOfDay(for: Date())
        let weeks = Self.gridWeeks(today: today, calendar: Self.cal)
        let stats = currentStats(today: today)
        return VStack(alignment: .leading, spacing: 14) {
            statsRow(stats, weekCount: weeks.count)
            dayDetailStrip

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    monthLabelsRow(weeks)

                    HStack(alignment: .top, spacing: 0) {
                        dayLabelsColumn

                        HStack(alignment: .top, spacing: cellSpacing) {
                            ForEach(weeks) { week in
                                VStack(spacing: cellSpacing) {
                                    ForEach(0..<7, id: \.self) { di in
                                        if let date = week.days[di] {
                                            dayCell(date)
                                        } else {
                                            RoundedRectangle(cornerRadius: cellCorner, style: .continuous)
                                                .fill(Color.clear)
                                                .frame(width: cellSize, height: cellSize)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06),
                                    lineWidth: 1
                                )
                        )
                    }
                }
            }

            legendRow
        }
    }

    /// Fixed hover detail strip — same chrome as action-button tooltips, no clipping.
    @ViewBuilder
    private var dayDetailStrip: some View {
        let date = hoveredDate ?? selectedDate
        let dayInfo = date.flatMap { info[$0] }
        let count = dayInfo?.count ?? 0
        let stripAccent: Color = {
            guard date != nil else { return accent.opacity(0.55) }
            return count == 0 ? Color.secondary : accent
        }()

        OmegaHoverCard(accent: stripAccent) {
            Group {
                if let date {
                    dayDetailContent(date, info: dayInfo)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(OmegaTheme.font(.caption))
                            .foregroundColor(Color.white.opacity(0.45))
                        Text("Hover a day to see entries, moods, and titles")
                            .font(OmegaTheme.font(.caption, .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.62))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 36)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hoveredDate ?? selectedDate)
        }
    }

    @ViewBuilder
    private func dayDetailContent(_ date: Date, info: JournalViewModel.DayInfo?) -> some View {
        let dateStr = Self.shortDateFormatter.string(from: date)
        let count = info?.count ?? 0
        let isToday = Self.cal.isDateInToday(date)
        let detailAccent: Color = count == 0 ? Color.secondary : accent

        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(dateStr)
                        .font(OmegaTheme.font(.body, .semibold, design: .rounded))
                        .foregroundColor(.white)
                    if isToday {
                        Text("Today")
                            .font(OmegaTheme.font(.meta, .bold, design: .rounded))
                            .foregroundColor(detailAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(detailAccent.opacity(0.18)))
                    }
                }

                if count == 0 {
                    Text("No entries")
                        .font(OmegaTheme.font(.caption))
                        .foregroundColor(Color.white.opacity(0.55))
                } else {
                    HStack(spacing: 6) {
                        Text("\(count) \(count == 1 ? "entry" : "entries")")
                            .font(OmegaTheme.font(.caption, .semibold, design: .rounded))
                            .foregroundColor(detailAccent)
                        if let moods = info?.moods, !moods.isEmpty {
                            Text("·").foregroundColor(Color.white.opacity(0.35))
                            HStack(spacing: 2) {
                                ForEach(Array(moods.prefix(6).enumerated()), id: \.offset) { _, mood in
                                    Text(mood.emoji).font(OmegaTheme.font(.caption))
                                }
                            }
                        }
                    }
                }
            }

            if let titles = info?.titles, !titles.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 1)
                    .frame(minHeight: 36)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(detailAccent.opacity(0.85))
                                .frame(width: 4, height: 4)
                                .padding(.top, 4)
                            Text(title)
                                .font(OmegaTheme.font(.meta))
                                .foregroundColor(Color.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                    if count > titles.count {
                        Text("+ \(count - titles.count) more…")
                            .font(OmegaTheme.font(.meta, .medium))
                            .foregroundColor(Color.white.opacity(0.45))
                            .padding(.leading, 10)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 36, alignment: .topLeading)
    }

    // MARK: Stats

    private func statsRow(_ stats: WindowStats, weekCount: Int) -> some View {
        HStack(spacing: 10) {
            heatStat(icon: "square.stack.3d.up.fill", value: "\(stats.total)", label: "entries", tint: .green)
            heatStat(icon: "sun.max.fill", value: "\(stats.activeDays)", label: "active days", tint: accent)
            if periodStart == nil {
                heatStat(icon: "calendar", value: "\(weekCount)", label: "weeks", tint: .secondary)
            }
            if stats.maxDay > 0 {
                heatStat(icon: "flame.fill", value: "\(stats.maxDay)", label: "best day", tint: .orange)
            }
            heatStat(icon: "chart.pie.fill", value: "\(stats.coverage)%",
                     label: periodStart == nil ? "coverage" : "of period", tint: .teal)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func heatStat(icon: String, value: String, label: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(tint)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(isDark ? 0.18 : 0.12))
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(OmegaTheme.font(.body, .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text(label)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardColor.opacity(isDark ? 0.35 : 0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    // MARK: Labels

    @ViewBuilder
    private func monthLabelsRow(_ weeks: [WeekColumn]) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer().frame(width: dayLabelWidth + 8)

            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(
                        width: CGFloat(weeks.count) * (cellSize + cellSpacing) - cellSpacing + 16,
                        height: 22
                    )

                ForEach(monthLabels(for: weeks)) { label in
                    let xOffset = CGFloat(label.weekIndex) * (cellSize + cellSpacing) + 8
                    HStack(spacing: 4) {
                        Text(label.name)
                            .font(OmegaTheme.font(.meta, .semibold))
                            .foregroundColor(.secondary)
                        if label.showYear {
                            Text(label.year.description)
                                .font(OmegaTheme.font(.meta, .medium, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.55))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                    }
                    .offset(x: xOffset)
                }
            }
        }
    }

    private var dayLabelsColumn: some View {
        VStack(spacing: cellSpacing) {
            ForEach(0..<7, id: \.self) { di in
                Text(di % 2 == 1 ? dayLabels[di] : "")
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(.secondary.opacity(0.7))
                    .frame(width: dayLabelWidth, height: cellSize, alignment: .trailing)
                    .padding(.trailing, 8)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Cells

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let dayInfo = info[date]
        let count = dayInfo?.count ?? 0
        let hovered = hoveredDate == date
        let selected = selectedDate == date
        let isToday = Self.cal.isDateInToday(date)
        let outside = ReflectionHeatmapWindow.isOutsidePeriod(date, periodStart: periodStart, calendar: Self.cal)

        RoundedRectangle(cornerRadius: cellCorner, style: .continuous)
            .fill(fill(for: count))
            .opacity(outside ? 0.35 : 1)
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: cellCorner, style: .continuous)
                    .strokeBorder(border(for: count, isToday: isToday, hovered: hovered || selected),
                                  lineWidth: isToday || hovered || selected ? 1.6 : 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if let h = habitCompletion[date], h > 0 {
                    Circle()
                        .fill(Color.white.opacity(0.35 + 0.65 * h))
                        .frame(width: 4, height: 4)
                        .overlay(Circle().strokeBorder(accent.opacity(0.9), lineWidth: 0.5))
                        .padding(1.5)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: ((hovered || selected) && count > 0) ? accent.opacity(0.35) : .clear, radius: 4, y: 1)
            .scaleEffect(reduceMotion ? 1.0 : (hovered ? 1.35 : (selected ? 1.15 : 1.0)))
            .zIndex(hovered || selected ? 20 : 0)
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                    hoveredDate = inside ? date : nil
                }
            }
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { selectedDate = date }
                onOpenDate?(date)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: hovered)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: selected)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel(date: date, count: count) + (outside ? ", outside the selected period" : ""))
            .accessibilityHint(onOpenDate == nil ? "Select this day for details" : "Open this day")
            .accessibilityAction {
                selectedDate = date
                onOpenDate?(date)
            }
    }

    private func accessibilityLabel(date: Date, count: Int) -> String {
        let d = Self.fullDateFormatter.string(from: date)
        let habit = (habitCompletion[date] ?? 0) > 0 ? ", \(Int(((habitCompletion[date] ?? 0) * 100).rounded())) percent of habits done" : ""
        if count == 0 { return "\(d), no entries\(habit)" }
        return "\(d), \(count) \(count == 1 ? "entry" : "entries")\(habit)"
    }

    // MARK: Legend

    private var legendRow: some View {
        HStack(spacing: 8) {
            Text("Less")
                .font(OmegaTheme.font(.meta, .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(fill(for: i))
                        .frame(width: 12, height: 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .strokeBorder(
                                    i == 0
                                        ? (isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.06))
                                        : accent.opacity(0.15),
                                    lineWidth: 1
                                )
                        )
                }
            }

            Text("More")
                .font(OmegaTheme.font(.meta, .medium))
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(accent, lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                Text("Today")
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(accent.opacity(isDark ? 0.10 : 0.08))
            )
        }
    }
}
