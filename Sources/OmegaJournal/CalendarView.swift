import Foundation
import SwiftUI

// MARK: - Calendar Workspace
//
// A full-width reflective workspace. Calendar deliberately reads from the
// ViewModel's reflective scope instead of the Journal list/search result.

struct CalendarView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    private enum DisplayMode: String, CaseIterable, Identifiable {
        case month = "Month"
        case agenda = "Agenda"

        var id: String { rawValue }
    }

    @State private var anchorMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var displayMode: DisplayMode = .month
    @State private var presentedEntry: CalendarEntryRoute?
    @State private var presentedEntryID: String?

    private let calendar = Calendar.current
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
    private let inspectorColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    /// The ViewModel owns the actual privacy rule. This defensive filter makes
    /// the Calendar safe even during an auth-state transition.
    private var scopedCalendarEntries: [JournalEntry] {
        vm.calendarEntries.filter { entry in
            !entry.isHidden || biometricAuth.isAuthenticated
        }
    }

    private var entriesByDay: [Date: [JournalEntry]] {
        vm.entriesByDay(for: scopedCalendarEntries)
    }

    private var monthEntries: [JournalEntry] {
        guard let interval = calendar.dateInterval(of: .month, for: anchorMonth) else { return [] }
        return scopedCalendarEntries.filter { entry in
            entry.createdAt >= interval.start && entry.createdAt < interval.end
        }
    }

    private var selectedDayEntries: [JournalEntry] {
        entriesByDay[calendar.startOfDay(for: selectedDay), default: []]
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Days shown in the month grid, padded at both ends to retain weekday alignment.
    private var gridDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: anchorMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leadingBlanks = (weekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: anchorMonth)?.count ?? 0

        var result = Array<Date?>(repeating: nil, count: leadingBlanks)
        for offset in 0..<dayCount {
            result.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let start = max(0, calendar.firstWeekday - 1)
        return Array(symbols[start...] + symbols[..<start])
    }

    private var agendaDays: [Date] {
        let visibleDays = entriesByDay.keys.filter(isInAnchorMonth)
        var days = Set(visibleDays)
        let normalizedSelection = calendar.startOfDay(for: selectedDay)
        if isInAnchorMonth(normalizedSelection) {
            days.insert(normalizedSelection)
        }
        return days.sorted()
    }

    private var dayJumpBinding: Binding<Date> {
        Binding(
            get: { selectedDay },
            set: { navigate(to: $0) }
        )
    }

    private var privacyInclusionBinding: Binding<Bool> {
        Binding(
            get: { vm.analyticsVisibility == .includePrivate },
            set: { includePrivate in
                guard biometricAuth.isAuthenticated else { return }
                vm.analyticsVisibility = includePrivate ? .includePrivate : .visibleOnly
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    reflectiveScopeControl
                    monthSummary

                    switch displayMode {
                    case .month:
                        monthWorkspace
                    case .agenda:
                        agendaWorkspace
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .sheet(item: $presentedEntry, onDismiss: finishPresentedEntry) { route in
            CalendarEntryContextSheet(vm: vm, entryID: route.entryID)
        }
    }

    // MARK: - Header and scope

    private var workspaceHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                workspaceTitle
                Spacer(minLength: 12)
                workspaceControls
            }

            VStack(alignment: .leading, spacing: 14) {
                workspaceTitle
                workspaceControls
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(theme.backgroundColor)
    }

    private var workspaceTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Calendar")
                .font(.system(size: 25, weight: .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text("Reflect on your writing rhythm without leaving the workspace.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryTextColor)
        }
    }

    private var workspaceControls: some View {
        HStack(spacing: 9) {
            Picker("Calendar display", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .accessibilityLabel("Calendar display")

            Divider()
                .frame(height: 20)
                .opacity(0.3)

            Button(action: { shiftMonth(-1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accentColor)
            .help("Previous month")
            .accessibilityLabel("Previous month")

            Text(anchorMonth.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.titleTextColor)
                .frame(minWidth: 142)

            Button(action: { shiftMonth(1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accentColor)
            .help("Next month")
            .accessibilityLabel("Next month")

            Button("Today", action: goToToday)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                .help("Jump to today")

            DatePicker(
                "Jump to date",
                selection: dayJumpBinding,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .frame(width: 126)
            .accessibilityLabel("Jump to date")
        }
    }

    private var reflectiveScopeControl: some View {
        HStack(spacing: 12) {
            Image(systemName: biometricAuth.isAuthenticated ? "eye" : "lock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.accentColor.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text("Reflective scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text(vm.analyticsVisibilityLabel)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryTextColor)
            }

            Spacer(minLength: 16)

            if biometricAuth.isAuthenticated {
                Toggle("Include private", isOn: privacyInclusionBinding)
                    .toggleStyle(.switch)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.bodyTextColor)
                    .accessibilityLabel("Include private entries in Calendar")
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
                .help("Authenticate before including private entries")
                .accessibilityHint("Authenticates before private entries can be included")
            }
        }
        .padding(14)
        .background(cardSurface(opacity: 0.5))
        .overlay(cardBorder)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Summary

    private var monthSummary: some View {
        let writingDays = Set(monthEntries.map { calendar.startOfDay(for: $0.createdAt) }).count
        let wordCount = monthEntries.reduce(0) { $0 + $1.wordCount }
        let average = averageMood(for: monthEntries)

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
            spacing: 10
        ) {
            summaryMetric(value: "\(monthEntries.count)", label: "Entries", icon: "book.closed")
            summaryMetric(value: wordCount.formatted(), label: "Words", icon: "text.word.spacing")
            summaryMetric(value: "\(writingDays)", label: "Writing days", icon: "calendar")
            summaryMetric(
                value: average.map { "\($0.emoji) \($0.label)" } ?? "—",
                label: "Average mood",
                icon: "face.smiling"
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardSurface(opacity: 0.45))
        .overlay(cardBorder)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(anchorMonth.formatted(.dateTime.month(.wide).year())) reflective summary")
    }

    private func summaryMetric(value: String, label: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(theme.titleTextColor)
                    .lineLimit(1)
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Month mode

    private var monthWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                monthGridCard
                    .frame(minWidth: 520, maxWidth: .infinity)
                selectedDayInspector
                    .frame(width: 360)
            }

            VStack(alignment: .leading, spacing: 20) {
                monthGridCard
                selectedDayInspector
            }
        }
    }

    private var monthGridCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Month at a glance")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text("Select any day to inspect its writing.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Text("\(monthEntries.count) \(entryWord(for: monthEntries.count))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryTextColor)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                        Text(symbol.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.secondaryTextColor)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                }

                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                        if let day {
                            CalendarDayCell(
                                day: day,
                                entries: dayEntries(for: day),
                                isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                                calendar: calendar,
                                onSelect: { selectDay(day) }
                            )
                        } else {
                            Color.clear
                                .frame(minHeight: 82)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(cardSurface(opacity: 0.45))
        .overlay(cardBorder)
    }

    // MARK: - Agenda mode

    private var agendaWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                agendaCard
                    .frame(minWidth: 520, maxWidth: .infinity)
                selectedDayInspector
                    .frame(width: 360)
            }

            VStack(alignment: .leading, spacing: 20) {
                selectedDayInspector
                agendaCard
            }
        }
    }

    private var agendaCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agenda")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text("Writing days in \(anchorMonth.formatted(.dateTime.month(.wide).year())).")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Text("\(agendaDays.count) \(agendaDays.count == 1 ? "day" : "days")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryTextColor)
            }

            if agendaDays.isEmpty {
                agendaEmptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(agendaDays, id: \.self) { day in
                        agendaDaySection(day)
                    }
                }
            }
        }
        .padding(20)
        .background(cardSurface(opacity: 0.45))
        .overlay(cardBorder)
    }

    private var agendaEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(theme.secondaryTextColor)
            Text("No entries in this month’s reflective scope.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.titleTextColor)
            Text("Choose a date in the inspector to begin writing.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryTextColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func agendaDaySection(_ day: Date) -> some View {
        let entries = dayEntries(for: day)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)

        return VStack(alignment: .leading, spacing: 8) {
            Button(action: { selectDay(day) }) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(day.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryTextColor)
                        Text(day.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.titleTextColor)
                    }
                    Spacer()
                    Text("\(entries.count) \(entryWord(for: entries.count))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryTextColor)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryTextColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? theme.accentColor.opacity(0.14) : theme.cardColor.opacity(0.34))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(entries.count) \(entryWord(for: entries.count))")
            .accessibilityHint("Select this day in the calendar inspector")

            if entries.isEmpty {
                Text("No entries on this selected date.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.leading, 12)
            } else {
                ForEach(entries) { entry in
                    CalendarEntryRow(entry: entry, onOpen: { openEntry(entry) })
                }
            }
        }
    }

    // MARK: - Selected day inspector

    private var selectedDayInspector: some View {
        let entries = selectedDayEntries
        let words = entries.reduce(0) { $0 + $1.wordCount }
        let readingMinutes = entries.reduce(0) { $0 + $1.readingMinutes }
        let mood = averageMood(for: entries)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DAY INSPECTOR")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(theme.secondaryTextColor)
                    Text(selectedDay.formatted(date: .complete, time: .omitted))
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                    Text("\(entries.count) \(entryWord(for: entries.count)) in this reflective scope")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryTextColor)
                }

                Spacer(minLength: 8)

                Button(action: createEntryForSelectedDay) {
                    Label("New Entry", systemImage: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .help("Create an entry for \(selectedDay.formatted(date: .complete, time: .omitted))")
                .accessibilityLabel("New entry for \(selectedDay.formatted(date: .complete, time: .omitted))")
            }

            LazyVGrid(columns: inspectorColumns, spacing: 8) {
                dayTotal(value: "\(entries.count)", label: "Entries", icon: "book.closed")
                dayTotal(value: words.formatted(), label: "Words", icon: "text.word.spacing")
                dayTotal(value: "\(readingMinutes) min", label: "Reading", icon: "clock")
                dayTotal(
                    value: mood.map { "\($0.emoji) \($0.label)" } ?? "—",
                    label: "Avg. mood",
                    icon: "face.smiling"
                )
            }

            Divider().opacity(0.22)

            HStack {
                Text("Entries")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.titleTextColor)
                Spacer()
                if !entries.isEmpty {
                    Text("Open to read or edit")
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryTextColor)
                }
            }

            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nothing written on this day yet.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.titleTextColor)
                    Text("Start a dated entry without leaving Calendar.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryTextColor)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 7) {
                    ForEach(entries) { entry in
                        CalendarEntryRow(entry: entry, onOpen: { openEntry(entry) })
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface(opacity: 0.56))
        .overlay(cardBorder)
        .accessibilityElement(children: .contain)
    }

    private func dayTotal(value: String, label: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(theme.titleTextColor)
                    .lineLimit(1)
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.cardColor.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions and helpers

    private func requestPrivateInclusion() {
        Task { @MainActor in
            guard await biometricAuth.authenticate() else { return }
            vm.analyticsVisibility = .includePrivate
        }
    }

    private func openEntry(_ entry: JournalEntry) {
        Task { @MainActor in
            guard await vm.revealIfNeeded(entry) else { return }
            vm.select(entry)
            presentEntry(id: entry.id)
        }
    }

    private func createEntryForSelectedDay() {
        vm.createEntry(on: selectedDay)
        guard let entryID = vm.editingEntryId else { return }
        presentEntry(id: entryID)
    }

    private func presentEntry(id: String) {
        presentedEntryID = id
        presentedEntry = CalendarEntryRoute(entryID: id)
    }

    private func finishPresentedEntry() {
        if let entryID = presentedEntryID, vm.editingEntryId == entryID {
            vm.stopEditing()
        }
        presentedEntryID = nil
    }

    private func goToToday() {
        navigate(to: Date())
    }

    private func navigate(to date: Date) {
        let day = calendar.startOfDay(for: date)
        let month = calendar.dateInterval(of: .month, for: day)?.start ?? day
        withAnimation(.easeOut(duration: 0.18)) {
            selectedDay = day
            anchorMonth = month
        }
    }

    private func selectDay(_ date: Date) {
        navigate(to: date)
    }

    private func shiftMonth(_ delta: Int) {
        guard let candidate = calendar.date(byAdding: .month, value: delta, to: anchorMonth),
              let interval = calendar.dateInterval(of: .month, for: candidate),
              let range = calendar.range(of: .day, in: .month, for: candidate) else {
            return
        }

        let selectedDayNumber = calendar.component(.day, from: selectedDay)
        let targetDayNumber = min(max(selectedDayNumber, range.lowerBound), range.upperBound - 1)
        let target = calendar.date(byAdding: .day, value: targetDayNumber - 1, to: interval.start) ?? interval.start

        withAnimation(.easeOut(duration: 0.18)) {
            anchorMonth = interval.start
            selectedDay = calendar.startOfDay(for: target)
        }
    }

    private func dayEntries(for day: Date) -> [JournalEntry] {
        entriesByDay[calendar.startOfDay(for: day), default: []]
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func isInAnchorMonth(_ day: Date) -> Bool {
        calendar.isDate(day, equalTo: anchorMonth, toGranularity: .month)
    }

    private func averageMood(for entries: [JournalEntry]) -> Mood? {
        guard !entries.isEmpty else { return nil }
        let total = entries.reduce(0) { $0 + $1.mood.rawValue }
        let value = Int((Double(total) / Double(entries.count)).rounded())
        return Mood(rawValue: value) ?? .neutral
    }

    private func entryWord(for count: Int) -> String {
        count == 1 ? "entry" : "entries"
    }

    private func cardSurface(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.cardColor.opacity(opacity))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                theme.colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08),
                lineWidth: 1
            )
    }
}

// MARK: - Month day cell

private struct CalendarDayCell: View {
    let day: Date
    let entries: [JournalEntry]
    let isSelected: Bool
    let calendar: Calendar
    let onSelect: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    private var safeEntries: [JournalEntry] {
        entries.filter { !$0.isHidden || biometricAuth.isAuthenticated }
    }

    private var averageMood: Mood? {
        guard !safeEntries.isEmpty else { return nil }
        let sum = safeEntries.reduce(0) { $0 + $1.mood.rawValue }
        return Mood(rawValue: Int((Double(sum) / Double(safeEntries.count)).rounded())) ?? .neutral
    }

    private var entryLabel: String {
        safeEntries.count == 1 ? "1 entry" : "\(safeEntries.count) entries"
    }

    private var accessibilityDescription: String {
        let date = day.formatted(date: .complete, time: .omitted)
        guard !safeEntries.isEmpty else { return "\(date), no entries" }
        let mood = averageMood.map { ", average mood \($0.label)" } ?? ""
        return "\(date), \(entryLabel)\(mood)"
    }

    var body: some View {
        let isToday = calendar.isDateInToday(day)
        let isFuture = calendar.startOfDay(for: day) > calendar.startOfDay(for: Date())
        let fillColor = isSelected
            ? theme.accentColor.opacity(0.22)
            : (averageMood?.color.opacity(0.17) ?? theme.cardColor.opacity(0.38))

        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 14, weight: isToday ? .bold : .semibold, design: .rounded))
                        .foregroundColor(isFuture ? theme.secondaryTextColor.opacity(0.55) : theme.titleTextColor)
                    Spacer(minLength: 4)
                    if !safeEntries.isEmpty {
                        Text("\(safeEntries.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(theme.accentColor)
                    }
                }

                Spacer(minLength: 2)

                if safeEntries.isEmpty {
                    Text(isFuture ? "Future" : "No entry")
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryTextColor.opacity(isFuture ? 0.5 : 0.82))
                } else {
                    HStack(spacing: 5) {
                        if let mood = averageMood {
                            Circle()
                                .fill(mood.color)
                                .frame(width: 7, height: 7)
                        }
                        Text(entryLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryTextColor)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fillColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accentColor : (isToday ? theme.accentColor.opacity(0.58) : Color.clear),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accessibilityDescription)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Select this day to inspect its entries")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Accessible entry row

private struct CalendarEntryRow: View {
    let entry: JournalEntry
    let onOpen: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    private var isLockedPrivate: Bool {
        entry.isHidden && !biometricAuth.isAuthenticated
    }

    private var accessibilityDescription: String {
        if isLockedPrivate {
            return "Private calendar entry. Unlock to view."
        }
        return "\(entry.displayTitle), \(entry.mood.label) mood, \(entry.createdAt.formatted(date: .omitted, time: .shortened)), \(entry.wordCount) words"
    }

    var body: some View {
        Button(action: open) {
            Group {
                if isLockedPrivate {
                    lockedContent
                } else {
                    entryContent
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.cardColor.opacity(0.42)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isLockedPrivate ? theme.accentColor.opacity(0.34) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(isLockedPrivate ? "Authenticate to view this entry" : "Open this entry in Calendar")
    }

    private var entryContent: some View {
        HStack(spacing: 10) {
            Text(entry.mood.emoji)
                .font(.system(size: 17))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
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
                Text("\(entry.createdAt.formatted(date: .omitted, time: .shortened)) · \(entry.wordCount) words")
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.secondaryTextColor)
                .accessibilityHidden(true)
        }
    }

    private var lockedContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Private entry")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text("Unlock to view")
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer()
            Image(systemName: "lock.open")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .accessibilityHidden(true)
        }
    }

    private func open() {
        if isLockedPrivate {
            Task { @MainActor in
                guard await biometricAuth.authenticate() else { return }
                onOpen()
            }
        } else {
            onOpen()
        }
    }
}

// MARK: - Contextual entry drill-through

private struct CalendarEntryRoute: Identifiable {
    let entryID: String
    var id: String { entryID }
}

private struct CalendarEntryContextSheet: View {
    @ObservedObject var vm: JournalViewModel
    let entryID: String

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared
    @Environment(\.dismiss) private var dismiss

    /// Resolve on every body update rather than retaining an entry snapshot.
    /// The scoped lookup also removes private metadata immediately on re-lock.
    private var currentEntry: JournalEntry? {
        guard let entry = vm.calendarEntries.first(where: { $0.id == entryID }) else { return nil }
        return entry.isHidden && !biometricAuth.isAuthenticated ? nil : entry
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().opacity(0.25)
            sheetContent
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(theme.backgroundColor)
    }

    private var sheetHeader: some View {
        HStack(spacing: 8) {
            Label("Calendar entry", systemImage: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.titleTextColor)
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
            .accessibilityLabel("Close Calendar entry")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.cardColor.opacity(0.22))
    }

    @ViewBuilder
    private var sheetContent: some View {
        if let entry = currentEntry {
            if vm.editingEntryId == entryID {
                EditorView(vm: vm, entry: entry)
                    .id("calendar-editor-\(entry.id)")
            } else {
                ReadView(vm: vm, entry: entry)
                    .id("calendar-reader-\(entry.id)")
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(theme.accentColor)
                Text("Entry unavailable")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                Text("This entry is no longer available in the current Calendar scope.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
                Button("Close", action: { dismiss() })
                    .buttonStyle(.bordered)
                    .tint(theme.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
    }
}
