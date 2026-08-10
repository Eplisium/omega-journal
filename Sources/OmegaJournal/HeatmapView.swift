import SwiftUI

// MARK: - Writing Heatmap (Contribution Graph)

struct HeatmapView: View {
    let info: [Date: JournalViewModel.DayInfo]

    @ObservedObject private var theme = ThemeManager.shared
    @State private var hoveredDate: Date?

    private static let cal = Calendar.current
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f
    }()

    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 3.5
    private let cellCorner: CGFloat = 3.5
    private let dayLabelWidth: CGFloat = 30

    private var isDark: Bool { theme.colorScheme == .dark }
    private var accent: Color { theme.accentColor }

    // Build the grid: 7 rows (weekday) x N columns (week)
    private struct WeekColumn: Identifiable {
        let id: Int
        let startDate: Date
        let days: [Date?]
    }

    private var weeks: [WeekColumn] {
        let cal = Self.cal
        let today = cal.startOfDay(for: Date())
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
    }

    private var monthLabels: [MonthLabel] {
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
                    showYear: y != lastYear && lastYear != -1
                ))
                lastMonth = m
                lastYear = y
            }
        }
        return labels
    }

    private var totalEntries: Int { info.values.reduce(0) { $0 + $1.count } }
    private var activeDays: Int { info.values.filter { $0.count > 0 }.count }
    private var maxDay: Int { info.values.map(\.count).max() ?? 0 }
    private var coverage: Int {
        let span = max(weeks.count * 7, 1)
        return Int((Double(activeDays) / Double(span) * 100).rounded())
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
        VStack(alignment: .leading, spacing: 14) {
            statsRow
            dayDetailStrip

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    monthLabelsRow

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
        let date = hoveredDate
        let dayInfo = date.flatMap { info[$0] }
        let count = dayInfo?.count ?? 0
        let stripAccent: Color = {
            guard date != nil else { return accent.opacity(0.55) }
            return count == 0 ? Color.secondary : accent
        }()

        OmegaHoverCard(accent: stripAccent, showsArrow: false) {
            Group {
                if let date {
                    dayDetailContent(date, info: dayInfo)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.45))
                        Text("Hover a day to see entries, moods, and titles")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.62))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 36)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.15), value: hoveredDate)
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
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    if isToday {
                        Text("Today")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(detailAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(detailAccent.opacity(0.18)))
                    }
                }

                if count == 0 {
                    Text("No entries")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.white.opacity(0.55))
                } else {
                    HStack(spacing: 6) {
                        Text("\(count) \(count == 1 ? "entry" : "entries")")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(detailAccent)
                        if let moods = info?.moods, !moods.isEmpty {
                            Text("·").foregroundColor(Color.white.opacity(0.35))
                            HStack(spacing: 2) {
                                ForEach(Array(moods.prefix(6).enumerated()), id: \.offset) { _, mood in
                                    Text(mood.emoji).font(.system(size: 12))
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
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                    if count > titles.count {
                        Text("+ \(count - titles.count) more…")
                            .font(.system(size: 10, weight: .medium))
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

    private var statsRow: some View {
        HStack(spacing: 10) {
            heatStat(icon: "square.stack.3d.up.fill", value: "\(totalEntries)", label: "entries", tint: .green)
            heatStat(icon: "sun.max.fill", value: "\(activeDays)", label: "active days", tint: accent)
            heatStat(icon: "calendar", value: "\(weeks.count)", label: "weeks", tint: .secondary)
            if maxDay > 0 {
                heatStat(icon: "flame.fill", value: "\(maxDay)", label: "best day", tint: .orange)
            }
            heatStat(icon: "chart.pie.fill", value: "\(coverage)%", label: "coverage", tint: .teal)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func heatStat(icon: String, value: String, label: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(isDark ? 0.18 : 0.12))
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text(label)
                    .font(.system(size: 10))
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
    private var monthLabelsRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer().frame(width: dayLabelWidth + 8)

            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(
                        width: CGFloat(weeks.count) * (cellSize + cellSpacing) - cellSpacing + 16,
                        height: 22
                    )

                ForEach(monthLabels) { label in
                    let xOffset = CGFloat(label.weekIndex) * (cellSize + cellSpacing) + 8
                    HStack(spacing: 4) {
                        Text(label.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        if label.showYear {
                            Text(Self.cal.component(.year, from: weeks[label.weekIndex].startDate).description)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
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
                    .font(.system(size: 9, weight: .medium))
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
        let isToday = Self.cal.isDateInToday(date)

        RoundedRectangle(cornerRadius: cellCorner, style: .continuous)
            .fill(fill(for: count))
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: cellCorner, style: .continuous)
                    .strokeBorder(border(for: count, isToday: isToday, hovered: hovered),
                                  lineWidth: isToday || hovered ? 1.6 : 1)
            )
            .shadow(color: (hovered && count > 0) ? accent.opacity(0.35) : .clear, radius: 4, y: 1)
            .scaleEffect(hovered ? 1.35 : 1.0)
            .zIndex(hovered ? 20 : 0)
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.12)) {
                    hoveredDate = inside ? date : nil
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: hovered)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(date: date, count: count))
    }

    private func accessibilityLabel(date: Date, count: Int) -> String {
        let d = Self.fullDateFormatter.string(from: date)
        if count == 0 { return "\(d), no entries" }
        return "\(d), \(count) \(count == 1 ? "entry" : "entries")"
    }

    // MARK: Legend

    private var legendRow: some View {
        HStack(spacing: 8) {
            Text("Less")
                .font(.system(size: 10, weight: .medium))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(accent, lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                Text("Today")
                    .font(.system(size: 10, weight: .medium))
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
