import SwiftUI
import Charts
import OmegaJournalCore

// MARK: - Insights reflection workspace

/// A calm, scoped reflection surface. It derives entirely from the ViewModel's
/// analytics snapshot, never from the Journal's transient search result.
///
/// Interactive by design: mood points resolve the entries behind them on
/// hover, every heatmap day drills into its entries, and recent-writing rows
/// open entries directly — all through the shared drill-through sheet.
struct InsightsWorkspaceView: View {
    var vm: JournalViewModel
    private let biometricAuth = BiometricAuth.shared

    var body: some View {
        // Derive everything once per render; the content reads stored values.
        InsightsWorkspaceContent(vm: vm, data: InsightsSnapshot.make(vm: vm))
    }
}

/// The Insights workspace body. `data` is computed once by the parent, so
/// hover callbacks and the ~20 derived labels never re-filter the journal.
struct InsightsWorkspaceContent: View {
    let vm: JournalViewModel
    let data: InsightsSnapshot
    private let theme = ThemeManager.shared
    private let biometricAuth = BiometricAuth.shared
    private let checkins = CheckinStore.shared

    @State private var drill = DrillThroughPresentation()
    @State private var workspaceSize: CGSize = .zero

    private var entries: [JournalEntry] { data.entries }
    /// Habit completion share per day (dot overlay on the heatmap).
    private var habitCompletionByDate: [Date: Double] {
        var out: [Date: Double] = [:]
        for (key, v) in checkins.dailyHabitCompletion {
            if let d = DayKey.date(from: key) { out[Calendar.current.startOfDay(for: d)] = v }
        }
        return out
    }
    private var entriesByDay: [Date: [JournalEntry]] { data.entriesByDay }

    private var periodBinding: Binding<AnalyticsPeriod> {
        Binding(get: { vm.analyticsPeriod }, set: { vm.analyticsPeriod = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                // Only relevant when hidden entries exist; otherwise it's noise.
                if vm.hiddenCount > 0 { scopeCard }

                if data.state.isEmpty {
                    emptyState
                } else {
                    reflectionSummary
                    if case .sparse(let days) = data.state { sparseNote(writingDays: days) }
                    heroMetrics
                    writingSection
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            moodSection.frame(maxWidth: .infinity, alignment: .leading)
                            if data.state == .populated {
                                patternsSection.frame(width: 300, alignment: .leading)
                            }
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            moodSection
                            if data.state == .populated { patternsSection }
                        }
                    }
                    activitySection
                    distributionSection
                    if data.state == .populated { rhythmSection }
                    SmartInsightsSections(vm: vm, entries: entries, contentFingerprint: data.contentFingerprint)
                    recentWritingSection
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
            .frame(maxWidth: 1_200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { workspaceSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in workspaceSize = newSize }
            }
        )
        .sheet(item: $drill.presentedEntry, onDismiss: finishPresentedEntry) { route in
            EntryDrillThroughSheet(vm: vm, entryID: route.entryID, contextTitle: "Insights entry")
                // Cap to the workspace so the reader/editor sheet always fits;
                // floors match the sheet's own minWidth/minHeight.
                .frame(maxWidth: max(760, workspaceSize.width * 0.94),
                       maxHeight: max(560, workspaceSize.height * 0.92))
        }
        .sheet(item: $drill.presentedDay, onDismiss: finishPresentedDay) { route in
            DayEntriesSheet(
                day: route.day,
                entries: entriesByDay[route.day] ?? [],
                onOpen: { openEntry($0) }
            )
            .frame(maxWidth: min(520, max(420, workspaceSize.width * 0.5)),
                   maxHeight: max(420, workspaceSize.height * 0.72))
        }
    }

    // MARK: - Entry navigation

    private func openEntry(_ entry: JournalEntry) {
        Task { @MainActor in
            guard await vm.revealIfNeeded(entry) else { return }
            vm.select(entry)
            // From the day sheet this dismisses it first; the entry sheet is
            // presented after that dismissal (see finishPresentedDay).
            drill.presentEntry(id: entry.id)
        }
    }

    private func openDay(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard let dayEntries = entriesByDay[day], !dayEntries.isEmpty else { return }
        if dayEntries.count == 1 {
            openEntry(dayEntries[0])
        } else {
            drill.presentedDay = DayEntriesRoute(day: day)
        }
    }

    private func finishPresentedEntry() {
        // `presentedEntry` is already nil here; the coordinator remembers the id.
        if drill.entryDismissed(editingEntryId: vm.editingEntryId) {
            vm.stopEditing()
        }
    }

    private func finishPresentedDay() {
        guard let pending = drill.dayDismissed() else { return }
        // Next runloop: never present a sheet while another is still tearing down.
        DispatchQueue.main.async { drill.presentEntry(id: pending) }
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
                .font(OmegaTheme.font(.heading, .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text("A quieter way to notice your writing rhythm.")
                .font(OmegaTheme.font(.body))
                .foregroundColor(theme.secondaryTextColor)
        }
    }

    private var periodSelector: some View {
        Picker("Insight period", selection: periodBinding) {
            ForEach(AnalyticsPeriod.allCases) { period in
                Text(period.label).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 330, idealWidth: 430, maxWidth: 470)
        .accessibilityLabel("Insight period")
    }

    // MARK: - Scope

    private var scopeCard: some View {
        ReflectionScopeBar(
            visibility: data.visibility,
            excludedCount: data.excludedPrivateCount,
            scopeNoun: data.period == .allTime ? "your journal" : "this period",
            isAuthenticated: biometricAuth.isAuthenticated,
            includePrivate: privateInclusionBinding,
            onUnlock: requestPrivateInclusion,
            surfaceName: "Insights"
        )
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
            Text("Your \(data.period.label.lowercased()) in writing")
                .font(OmegaTheme.font(.meta, .medium, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text(summaryBody)
                .font(OmegaTheme.font(.body))
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

    private var summaryBody: String {
        let entryWord = entries.count == 1 ? "entry" : "entries"
        let dayWord = data.writingDays == 1 ? "day" : "days"
        var sentence = "You wrote \(entries.count) \(entryWord) on \(data.writingDays) \(dayWord), adding \(data.wordCount.formatted()) words."
        if let mood = averageMood {
            sentence += " Your recorded check-ins centered around \(mood.face) \(mood.label.lowercased())."
        }
        return sentence
    }
}

// MARK: - Day drill-down route

struct DayEntriesRoute: Identifiable {
    let day: Date
    var id: TimeInterval { day.timeIntervalSince1970 }
}

// MARK: - Drill-through sheet coordination

/// Sheet state for Insights drill-through, kept pure so it is testable.
///
/// - `sheet(item:)` clears `presentedEntry` BEFORE `onDismiss` runs, so the
///   presented id is remembered separately (as CalendarView does) and editing
///   can still be stopped on dismissal.
/// - Opening an entry while the day sheet is up must not stack a second sheet:
///   the day sheet is dismissed first and the entry presented after.
struct DrillThroughPresentation {
    var presentedEntry: EntryDrillThroughRoute?
    var presentedDay: DayEntriesRoute?
    private(set) var presentedEntryID: String?
    private(set) var pendingEntryID: String?

    mutating func presentEntry(id: String) {
        if presentedDay != nil {
            pendingEntryID = id
            presentedDay = nil
            return
        }
        presentedEntryID = id
        presentedEntry = EntryDrillThroughRoute(entryID: id)
    }

    /// Call from the entry sheet's onDismiss. True when the dismissed entry is
    /// the one being edited, i.e. the caller must stop editing.
    mutating func entryDismissed(editingEntryId: String?) -> Bool {
        defer { presentedEntryID = nil }
        guard let id = presentedEntryID else { return false }
        return id == editingEntryId
    }

    /// Call from the day sheet's onDismiss. Returns an entry to present next.
    mutating func dayDismissed() -> String? {
        defer { pendingEntryID = nil }
        return pendingEntryID
    }
}

// MARK: - InsightsWorkspaceView content

extension InsightsWorkspaceContent {

    // MARK: Hero metrics

    /// Four tiles, one row on a normal window: how often, how much, how it
    /// felt, and the standout day. (Entries-per-day and average length were
    /// folded into details — they repeated the same numbers.)
    private var heroMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            ReflectionMetric(
                value: "\(data.writingDays)",
                label: data.writingDays == 1 ? "Writing day" : "Writing days",
                detail: UIInsightsCopy.writingDaysDetail(writingDays: data.writingDays, periodDays: periodDayCount),
                icon: "calendar.badge.checkmark",
                tint: theme.accentColor
            )
            ReflectionMetric(
                value: data.wordCount.formatted(),
                label: "Words written",
                detail: UIInsightsCopy.wordsDetail(entryCount: entries.count, averagePerEntry: data.averageWordsPerEntry),
                icon: "text.word.spacing",
                tint: .teal
            )
            ReflectionMetric(
                value: averageMood.map { "\($0.face) \($0.label)" } ?? "—",
                label: "Average mood",
                detail: UIInsightsCopy.moodDetail(checkIns: checkInCount),
                icon: "face.smiling",
                tint: .orange
            )
            ReflectionMetric(
                value: bestDay.map { UIInsightsCopy.words($0.words) } ?? "—",
                label: "Best day",
                detail: bestDay.map { $0.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
                    ?? "Not yet in this period",
                icon: "star",
                tint: .pink
            )
        }
    }

    // MARK: Sections

    private var writingSection: some View {
        InsightSection(title: "Words per day", subtitle: "How much you wrote each day in this period") {
            WritingVolumeChart(points: data.writingPoints)
        }
    }

    private var moodSection: some View {
        InsightSection(title: "Mood over time", subtitle: "Daily average · hover for the entries behind it, click to open the day") {
            MoodCheckInChart(points: data.moodPoints, hoverTitleProvider: { data.moodHoverTitle(for: $0) }, onOpenDay: { openDay($0.date) })
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
                    title: "Usual writing time",
                    value: mostProductiveHour,
                    tint: .teal
                )
                PatternRow(
                    icon: "flame",
                    title: "Current streak",
                    value: UIInsightsCopy.streak(data.streak),
                    tint: .orange
                )
            }
        }
    }

    private var activitySection: some View {
        InsightSection(title: "Writing activity", subtitle: "Hover for a day's story · click to open its entries") {
            HeatmapView(info: data.activity, habitCompletion: habitCompletionByDate,
                        periodStart: data.periodStart, onOpenDate: openDay)
        }
    }

    private var distributionSection: some View {
        InsightSection(title: "Mood mix", subtitle: "How often each mood appears") {
            MoodDistributionRow(data: data.distribution, averageMood: averageMood)
        }
    }

    private var rhythmSection: some View {
        InsightSection(title: "Entries by weekday", subtitle: "Which days you write most") {
            WeekdayRhythmChart(data: data.weekdayCounts)
        }
    }

    private var recentWritingSection: some View {
        InsightSection(title: "Recent writing", subtitle: "Click a row to open the entry right here") {
            let recent = data.recent
            if recent.isEmpty {
                chartEmptyState("Nothing written in this period yet.", icon: "book.closed")
            } else {
                VStack(spacing: 8) {
                    ForEach(recent, id: \.id) { entry in
                        InsightsEntryRow(entry: entry, onOpen: { openEntry(entry) })
                    }
                }
            }
        }
    }

    // MARK: Empty and sparse states

    /// One state per reason — empty journal, quiet period, or only private
    /// entries — each with the action that actually changes it.
    private var emptyState: some View {
        let copy = ReflectionEmptyCopy(state: data.state, period: data.period,
                                     isAuthenticated: biometricAuth.isAuthenticated)
        return VStack(spacing: 12) {
            Image(systemName: copy.icon)
                .font(OmegaTheme.font(.display, .light))
                .foregroundColor(theme.accentColor.opacity(0.7))
                .accessibilityHidden(true)
            Text(copy.title)
                .font(OmegaTheme.font(.heading, .semibold, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text(copy.message)
                .font(OmegaTheme.font(.caption))
                .foregroundColor(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                ForEach(copy.actions, id: \.self) { action in
                    emptyActionButton(action, primary: action == copy.actions.first)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .background(surface(opacity: 0.42))
        .overlay(border)
        .accessibilityElement(children: .contain)
    }

    private func emptyActionButton(_ action: ReflectionEmptyCopy.Action, primary: Bool) -> some View {
        Button { perform(action) } label: {
            Label(action.title(isAuthenticated: biometricAuth.isAuthenticated), systemImage: action.icon)
                .font(OmegaTheme.font(.caption, .semibold))
                .foregroundColor(primary ? theme.onAccentColor : theme.accentColor)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(Capsule().fill(primary ? theme.accentColor : theme.accentColor.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private func perform(_ action: ReflectionEmptyCopy.Action) {
        switch action {
        case .write:
            NotificationCenter.default.post(name: .newEntry, object: nil)
        case .showAllTime:
            vm.analyticsPeriod = .allTime
        case .includePrivate:
            // Same rule as the scope bar: inclusion needs an authenticated session.
            if biometricAuth.isAuthenticated {
                vm.analyticsVisibility = .includePrivate
            } else {
                requestPrivateInclusion()
            }
        }
    }

    private func sparseNote(writingDays: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf")
                .foregroundColor(theme.accentColor)
                .accessibilityHidden(true)
            Text(ReflectionEmptyCopy.sparseMessage(writingDays: writingDays))
                .font(OmegaTheme.font(.caption))
                .foregroundColor(theme.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(surface(opacity: 0.32))
        .overlay(border)
    }

    // MARK: Derived descriptions

    private var averageMood: Mood? { data.averageMood }
    private var bestDay: WordPoint? { data.bestDay }
    /// Mood check-ins in the period (every entry with a mood counts once).
    private var checkInCount: Int { data.distribution.reduce(0) { $0 + $1.count } }

    /// Calendar days the selected period spans up to today; nil for All time.
    private var periodDayCount: Int? {
        guard let start = data.periodStart else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: Date())).day ?? 0
        return max(1, days + 1)
    }

    /// Deterministic on ties (lowest weekday wins).
    private var mostProductiveDay: String { data.mostProductiveDay ?? "Not enough data" }

    /// Deterministic on ties (earliest hour wins).
    private var mostProductiveHour: String { data.mostProductiveHour ?? "Not enough data" }

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
