import SwiftUI

// MARK: - Calendar View
//
// A month-at-a-glance browser: each day shows entry count and a mood tint, and clicking
// a day filters the detail pane to that day's entries.

struct CalendarView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    @State private var anchorMonth = Date()
    @State private var selectedDay: Date?

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    private var entriesByDay: [Date: [JournalEntry]] { vm.entriesByDay() }

    /// Days shown in the grid, padded with leading blanks so weekdays line up.
    private var gridDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: anchorMonth) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leadingBlanks = firstWeekday - calendar.firstWeekday
        let padding = (leadingBlanks + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: anchorMonth)?.count ?? 30

        var result: [Date?] = Array(repeating: nil, count: padding)
        for offset in 0..<dayCount {
            result.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        // Pad the tail so the final row is complete.
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private var monthEntries: [JournalEntry] {
        guard let interval = calendar.dateInterval(of: .month, for: anchorMonth) else { return [] }
        return vm.entries.filter { $0.createdAt >= interval.start && $0.createdAt < interval.end }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)

            ScrollView {
                VStack(spacing: 16) {
                    monthSummary
                    grid
                    if let day = selectedDay {
                        dayDetail(day)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
        }
        .background(theme.backgroundColor)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accentColor)

            Text(anchorMonth.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.titleTextColor)
                .frame(minWidth: 150)

            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accentColor)

            Button("Today") {
                withAnimation {
                    anchorMonth = Date()
                    selectedDay = calendar.startOfDay(for: Date())
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(theme.accentColor.opacity(0.14)))

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var monthSummary: some View {
        HStack(spacing: 0) {
            summaryStat("\(monthEntries.count)", "entries")
            summaryStat("\(monthEntries.reduce(0) { $0 + $1.wordCount }.formatted())", "words")
            summaryStat("\(Set(monthEntries.map { calendar.startOfDay(for: $0.createdAt) }).count)", "days written")
            let avg = monthEntries.isEmpty ? 0 : Double(monthEntries.reduce(0) { $0 + $1.mood.rawValue }) / Double(monthEntries.count)
            summaryStat(monthEntries.isEmpty ? "—" : String(format: "%.1f", avg), "avg mood")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardColor.opacity(0.45))
        )
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(theme.titleTextColor)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryTextColor)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.secondaryTextColor)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 62)
                    }
                }
            }
        }
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private func dayCell(_ day: Date) -> some View {
        let dayStart = calendar.startOfDay(for: day)
        let dayEntries = entriesByDay[dayStart] ?? []
        let isToday = calendar.isDateInToday(day)
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isFuture = dayStart > calendar.startOfDay(for: Date())

        // Tint the cell by the day's average mood.
        let tint: Color = dayEntries.isEmpty
            ? theme.cardColor.opacity(0.3)
            : {
                let avg = Double(dayEntries.reduce(0) { $0 + $1.mood.rawValue }) / Double(dayEntries.count)
                let mood = Mood(rawValue: Int(avg.rounded())) ?? .neutral
                return mood.color.opacity(min(0.55, 0.2 + Double(dayEntries.count) * 0.14))
            }()

        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedDay = isSelected ? nil : dayStart
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday ? .bold : .medium, design: .rounded))
                    .foregroundColor(isFuture ? theme.secondaryTextColor.opacity(0.4) : theme.titleTextColor)

                if dayEntries.isEmpty {
                    Circle().fill(.clear).frame(height: 4)
                } else {
                    HStack(spacing: 2) {
                        ForEach(dayEntries.prefix(3).indices, id: \.self) { i in
                            Circle()
                                .fill(dayEntries[i].mood.color)
                                .frame(width: 4, height: 4)
                        }
                        if dayEntries.count > 3 {
                            Text("+").font(.system(size: 7, weight: .bold)).foregroundColor(theme.secondaryTextColor)
                        }
                    }
                }

                if !dayEntries.isEmpty {
                    Text("\(dayEntries.reduce(0) { $0 + $1.wordCount })w")
                        .font(.system(size: 7.5, design: .rounded))
                        .foregroundColor(theme.secondaryTextColor)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accentColor : (isToday ? theme.accentColor.opacity(0.5) : .clear),
                        lineWidth: isSelected ? 2 : 1.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                vm.createEntry(on: day)
            } label: { Label("New Entry on This Day", systemImage: "square.and.pencil") }
        }
        .help(dayEntries.isEmpty ? "No entries" : "\(dayEntries.count) entries")
    }

    // MARK: Day detail

    private func dayDetail(_ day: Date) -> some View {
        let dayEntries = (entriesByDay[day] ?? []).sorted { $0.createdAt < $1.createdAt }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(day.formatted(date: .complete, time: .omitted))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.titleTextColor)
                Spacer()
                Button {
                    vm.createEntry(on: day)
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }

            if dayEntries.isEmpty {
                Text("Nothing written this day.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.vertical, 6)
            } else {
                ForEach(dayEntries) { entry in
                    Button {
                        vm.select(entry)
                    } label: {
                        HStack(spacing: 8) {
                            Text(entry.mood.emoji).font(.system(size: 13))
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    if entry.isHidden {
                                        Image(systemName: (entry.isHidden && !biometricAuth.isAuthenticated) ? "lock.fill" : "lock.open")
                                            .font(.system(size: 8))
                                            .foregroundColor(theme.accentColor)
                                    }
                                    Text(entry.displayTitle)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(theme.titleTextColor)
                                        .lineLimit(1)
                                }
                                Text(entry.isHidden && !biometricAuth.isAuthenticated ? "Hidden · unlock to read" : entry.preview)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.secondaryTextColor)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9.5))
                                .foregroundColor(theme.secondaryTextColor)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.cardColor.opacity(0.5)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.cardColor.opacity(0.35))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func shiftMonth(_ delta: Int) {
        withAnimation(.easeOut(duration: 0.18)) {
            anchorMonth = calendar.date(byAdding: .month, value: delta, to: anchorMonth) ?? anchorMonth
            selectedDay = nil
        }
    }
}
