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
    @State private var presentedEntry: EntryDrillThroughRoute?
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

    /// Live size of the calendar workspace. Sheets presented from here are
    /// capped to a fraction of it — otherwise a sheet containing ReadView's
    /// ScrollView reports the scroll content's full height as its ideal size
    /// and grows past the bottom of the window on long entries.
    @State private var workspaceSize: CGSize = .zero

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
                    // Only relevant when hidden entries exist; otherwise it's noise.
                    if vm.hiddenCount > 0 { reflectiveScopeControl }
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
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { workspaceSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in workspaceSize = newSize }
            }
        )
        .sheet(item: $presentedEntry, onDismiss: finishPresentedEntry) { route in
            EntryDrillThroughSheet(vm: vm, entryID: route.entryID, contextTitle: "Calendar entry")
                // Cap to the workspace so the sheet always fits on screen; the
                // reader/editor inside scrolls. Floors match the sheet's own
                // minWidth/minHeight so it never collapses.
                .frame(maxWidth: max(760, workspaceSize.width * 0.94),
                       maxHeight: max(560, workspaceSize.height * 0.92))
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
                .font(OmegaTheme.font(.bodyLarge, .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text("Reflect on your writing rhythm without leaving the workspace.")
                .font(OmegaTheme.font(.caption))
                .foregroundColor(theme.secondaryTextColor)
        }
    }

    private var workspaceControls: some View {
        HStack(spacing: 12) {
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
                .frame(height: 22)
                .opacity(0.3)

            monthNavigator

            PillActionButton(title: "Today", tooltip: "Jump to today", action: goToToday)

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
        // Never let the controls squeeze: with the labels locked to their ideal
        // size, ViewThatFits falls back to the stacked header instead of
        // crushing this row (which used to wrap "Today" one letter per line).
        .fixedSize(horizontal: true, vertical: false)
    }

    /// One grouped control — ‹ September 2026 › — so the month navigation
    /// reads as a single date navigator instead of three floating items.
    private var monthNavigator: some View {
        HStack(spacing: 0) {
            MonthChevronButton(systemName: "chevron.left", label: "Previous month", hint: "Show the previous month") {
                shiftMonth(-1)
            }

            Text(anchorMonth.formatted(.dateTime.month(.wide).year()))
                .font(OmegaTheme.font(.body, .semibold))
                .foregroundColor(theme.titleTextColor)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 142)
                .padding(.horizontal, 6)

            MonthChevronButton(systemName: "chevron.right", label: "Next month", hint: "Show the next month") {
                shiftMonth(1)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var reflectiveScopeControl: some View {
        HStack(spacing: 12) {
            Image(systemName: biometricAuth.isAuthenticated ? "eye" : "lock.fill")
                .font(OmegaTheme.font(.bodyLarge, .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.accentColor.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text("Reflective scope")
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text(vm.analyticsVisibilityLabel)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }

            Spacer(minLength: 16)

            if biometricAuth.isAuthenticated {
                Toggle("Include private", isOn: privacyInclusionBinding)
                    .toggleStyle(.switch)
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.bodyTextColor)
                    .accessibilityLabel("Include private entries in Calendar")
            } else {
                Button(action: requestPrivateInclusion) {
                    Label("Unlock to include", systemImage: "lock.open")
                        .font(OmegaTheme.font(.meta, .semibold))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .omegaTooltip("Authenticate before including private entries")
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
                .font(OmegaTheme.font(.bodyLarge, .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(OmegaTheme.font(.bodyLarge, .bold, design: .rounded))
                    .foregroundColor(theme.titleTextColor)
                    .lineLimit(1)
                Text(label)
                    .font(OmegaTheme.font(.meta))
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
                        .font(OmegaTheme.font(.bodyLarge, .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text("Select any day to inspect its writing.")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Text("\(monthEntries.count) \(entryWord(for: monthEntries.count))")
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.secondaryTextColor)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                        Text(symbol.uppercased())
                            .font(OmegaTheme.font(.meta, .semibold))
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
                        .font(OmegaTheme.font(.bodyLarge, .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text("Writing days in \(anchorMonth.formatted(.dateTime.month(.wide).year())).")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Text("\(agendaDays.count) \(agendaDays.count == 1 ? "day" : "days")")
                    .font(OmegaTheme.font(.meta, .medium))
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
                .font(OmegaTheme.font(.title, .light))
                .foregroundColor(theme.secondaryTextColor)
            Text("No entries in this month’s reflective scope.")
                .font(OmegaTheme.font(.caption, .medium))
                .foregroundColor(theme.titleTextColor)
            Text("Choose a date in the inspector to begin writing.")
                .font(OmegaTheme.font(.meta))
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
                            .font(OmegaTheme.font(.meta, .semibold))
                            .foregroundColor(theme.secondaryTextColor)
                        Text(day.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(OmegaTheme.font(.bodyLarge, .semibold))
                            .foregroundColor(theme.titleTextColor)
                    }
                    Spacer()
                    Text("\(entries.count) \(entryWord(for: entries.count))")
                        .font(OmegaTheme.font(.meta, .medium))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryTextColor)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                        .font(OmegaTheme.font(.meta, .semibold))
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
                    .font(OmegaTheme.font(.meta))
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
                        .font(OmegaTheme.font(.meta, .semibold))
                        .tracking(0.8)
                        .foregroundColor(theme.secondaryTextColor)
                    Text(selectedDay.formatted(date: .complete, time: .omitted))
                        .font(OmegaTheme.font(.heading, .bold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                    Text("\(entries.count) \(entryWord(for: entries.count)) in this reflective scope")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }

                Spacer(minLength: 8)

                Button(action: createEntryForSelectedDay) {
                    Label("New Entry", systemImage: "square.and.pencil")
                        .font(OmegaTheme.font(.meta, .semibold))
                        .foregroundColor(theme.onAccentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .omegaTooltip("Create an entry for \(selectedDay.formatted(date: .complete, time: .omitted))")
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
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.titleTextColor)
                Spacer()
                if !entries.isEmpty {
                    Text("Open to read or edit")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
            }

            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nothing written on this day yet.")
                        .font(OmegaTheme.font(.caption, .medium))
                        .foregroundColor(theme.titleTextColor)
                    Text("Start a dated entry without leaving Calendar.")
                        .font(OmegaTheme.font(.meta))
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
                .font(OmegaTheme.font(.meta, .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(OmegaTheme.font(.caption, .bold, design: .rounded))
                    .foregroundColor(theme.titleTextColor)
                    .lineLimit(1)
                Text(label)
                    .font(OmegaTheme.font(.meta))
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
        presentedEntry = EntryDrillThroughRoute(entryID: id)
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
