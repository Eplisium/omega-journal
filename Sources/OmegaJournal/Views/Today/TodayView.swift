import SwiftUI
import OmegaJournalCore

// MARK: - Today hero content

/// Body-derived text for the Today hero card. A locked hidden entry shows its
/// title/mood/date only (the masked-card rule): no preview, no tags and no
/// word count (its length says something about what it holds).
struct TodayHeroContent: Equatable {
    static let maskedPreview = "Hidden · unlock to read"

    let preview: String
    let tags: [String]
    /// "1,240 words", or nil when masked (the hero then shows no count).
    let wordCountText: String?
    let isMasked: Bool

    init(entry: JournalEntry, hiddenLocked: Bool) {
        isMasked = !ContentMasking.canShowContent(isHidden: entry.isHidden, hiddenLocked: hiddenLocked)
        preview = isMasked ? Self.maskedPreview : entry.preview
        tags = isMasked ? [] : entry.tags
        let words = entry.wordCount
        wordCountText = isMasked ? nil : "\(words.formatted()) \(words == 1 ? "word" : "words")"
    }
}

// MARK: - Today workspace

/// A calm starting point for writing. It intentionally surfaces only a few
/// recent memories; the complete library belongs in the Journal workspace.
struct TodayView: View {
    var vm: JournalViewModel
    let openJournal: () -> Void
    let openCalendar: () -> Void
    let openInsights: () -> Void
    let openEntry: (JournalEntry) -> Void

    private let theme = ThemeManager.shared
    private let goals = GoalManager.shared
    private let biometricAuth = BiometricAuth.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TodayCheckinPrefs.showKey) private var showCheckin = true

    var body: some View {
        // Everything below reads the clock (greeting, date, today's entry,
        // recents, On This Day). The schedule re-renders the page at midnight
        // and at each greeting change, so a Today left open overnight rolls
        // over. `Date()` (not the tick's date) stays right after a late tick,
        // e.g. when the Mac slept through midnight.
        TimelineView(TodayRolloverSchedule()) { _ in
            page(now: Date())
        }
    }

    private func page(now: Date) -> some View {
        let todays = Self.todaysEntry(in: vm.entries, now: now)
        // Reflective scope: a future-dated entry is not "recent writing".
        let recent = vm.recentReflectiveEntries(limit: 3, relativeTo: now)
            .filter { $0.id != todays?.id }
        let memory = vm.reflectiveOnThisDay(relativeTo: now).first
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                welcomeHeader(now: now)
                // One clear focus: today's writing. Everything else is quieter below.
                if let todays { heroCard(todays) } else { startWritingCard }

                VStack(alignment: .leading, spacing: 12) {
                    // One folded line under the writing; opens to the check-in and habits.
                    if showCheckin { TodayCheckinSection(now: now) }
                    if let memory { memoryMoment(memory) }
                }

                if !recent.isEmpty { recentWriting(recent) }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            // A readable column, centred: the page no longer stretches cards edge to edge.
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor)
    }

    /// Date (with the current streak) + greeting + one gentle line. Totals
    /// live in the sidebar footer and Insights, not here.
    private func welcomeHeader(now: Date) -> some View {
        let dateText = now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let streak = vm.entries.isEmpty ? 0 : vm.streakSummary.current
        let unit = vm.streakSummary.unit
        return VStack(alignment: .leading, spacing: 6) {
            Text(UITodayCopy.dateLine(dateText: dateText, streak: streak, unit: unit))
                .font(OmegaTheme.font(.caption, .medium))
                .foregroundColor(theme.secondaryTextColor)
                .accessibilityLabel(UITodayCopy.dateLineAccessibility(dateText: dateText, streak: streak, unit: unit))

            Text(Self.greeting(at: now))
                .font(OmegaTheme.font(.display, .semibold, design: .serif))
                .foregroundColor(theme.titleTextColor)
                .accessibilityAddTraits(.isHeader)

            Text(StreakCopy.welcomeBack(daysAway: vm.entries.isEmpty ? nil : vm.streakSummary.daysSinceLastEntry))
                .font(OmegaTheme.font(.body))
                .foregroundColor(theme.secondaryTextColor)
        }
    }

    // MARK: Hero — start writing

    /// Shown when nothing has been written today: today's prompt as the
    /// invitation, one primary Write action, templates as a quiet option.
    private var startWritingCard: some View {
        let prompt = PromptGenerator.today()
        return VStack(alignment: .leading, spacing: 14) {
            Text(UITodayCopy.promptHeading)
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.accentColor)

            Button {
                openJournal()
                vm.createEntryFromPrompt()
            } label: {
                Text(prompt)
                    .font(OmegaTheme.font(.title, .regular, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .omegaTooltip("Start an entry with today's prompt")
            .accessibilityLabel("Write about today's prompt: \(prompt)")

            HStack(spacing: 14) {
                Button {
                    openJournal()
                    vm.createEntryFromPrompt()
                } label: {
                    Label("Write", systemImage: "square.and.pencil")
                        .font(OmegaTheme.font(.body, .semibold))
                        .foregroundColor(theme.onAccentColor)
                        .ojAccentCapsule(theme.accentColor, horizontal: 18, vertical: 9)
                }
                .ojGlassButtonStyle(prominent: true, height: 38)
                .accessibilityLabel("Write about today's prompt")

                Button {
                    openJournal()
                    vm.createEntry()
                } label: {
                    Text("Blank entry")
                        .font(OmegaTheme.font(.body, .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Write a new blank entry")

                Button {
                    NotificationCenter.default.post(name: .newFromTemplate, object: nil)
                } label: {
                    Text("Template…")
                        .font(OmegaTheme.font(.body, .medium))
                        .foregroundColor(theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start an entry from a template")
                Spacer(minLength: 0)
            }

            goalProgress
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.cardColor.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: Hero — today's entry

    /// The newest entry written on `now`'s day (the hero offers to continue
    /// it). Evaluated against the page's clock, so it lapses at midnight.
    static func todaysEntry(in entries: [JournalEntry], now: Date, calendar: Calendar = .current) -> JournalEntry? {
        entries
            .filter { calendar.isDate($0.createdAt, inSameDayAs: now) }
            .max { $0.createdAt < $1.createdAt }
    }

    private func heroCard(_ entry: JournalEntry) -> some View {
        let hero = TodayHeroContent(entry: entry, hiddenLocked: !biometricAuth.isAuthenticated)
        return VStack(alignment: .leading, spacing: 12) {
            Button { openEntry(entry) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(UITodayCopy.entryHeading)
                            .font(OmegaTheme.font(.meta, .semibold))
                            .foregroundColor(theme.accentColor)
                        Text("· \(entry.mood.face) \(UIRowMetaFormat.dateText(for: entry.createdAt))")
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.secondaryTextColor)
                        Spacer()
                    }

                    Text(entry.displayTitle)
                        .font(OmegaTheme.font(.title, .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(hero.preview)
                        .font(OmegaTheme.font(.body))
                        .foregroundColor(theme.bodyTextColor)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open today's entry: \(entry.displayTitle)")

            HStack(spacing: 14) {
                Button { openEntry(entry); vm.startEditing(entry) } label: {
                    Label("Continue writing", systemImage: "pencil.line")
                        .font(OmegaTheme.font(.body, .semibold))
                        .foregroundColor(theme.onAccentColor)
                        .ojAccentCapsule(theme.accentColor, horizontal: 16, vertical: 8)
                }
                .ojGlassButtonStyle(prominent: true, height: 36)
                .accessibilityLabel("Continue today's entry")
                if let words = hero.wordCountText {
                    Text(words)
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                ForEach(hero.tags.prefix(2), id: \.self) { tag in
                    Text("#\(TagPath.leaf(of: tag))")
                        .font(OmegaTheme.font(.meta, .medium))
                        .foregroundColor(theme.secondaryTextColor)
                }
            }

            goalProgress
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.cardColor.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: Goals (inside the hero)

    private var dailyGoals: [WritingGoal] {
        goals.goals.filter { $0.type == .dailyWords || $0.type == .dailyEntries }
    }

    /// Today's goal progress as thin bars at the foot of the hero (it used to
    /// be a separate "TODAY'S PROGRESS" card).
    @ViewBuilder
    private var goalProgress: some View {
        let daily = dailyGoals
        if !daily.isEmpty {
            Divider().opacity(0.25)
            HStack(alignment: .top, spacing: 18) {
                ForEach(daily) { goal in TodayGoalRow(goal: goal) }
            }
        }
    }

    // MARK: Secondary — quiet rows

    /// Up to three recent entries as a compact list (title + relative date).
    private func recentWriting(_ recentEntries: [JournalEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recently")
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.secondaryTextColor)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("See all") { openJournal() }
                    .buttonStyle(.plain)
                    .font(OmegaTheme.font(.caption, .medium))
                    .foregroundColor(theme.accentColor)
                    .accessibilityLabel("See all entries")
            }
            VStack(spacing: 0) {
                ForEach(Array(recentEntries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().opacity(0.18).padding(.leading, 34) }
                    TodayQuietRow(face: entry.mood.face,
                                  title: entry.displayTitle,
                                  trailing: UIRowMetaFormat.dateText(for: entry.createdAt),
                                  isFavorite: entry.isFavorite) { openEntry(entry) }
                        .accessibilityLabel("Open \(entry.displayTitle)")
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.cardColor.opacity(0.32)))
        }
    }

    private func memoryMoment(_ entry: JournalEntry) -> some View {
        TodayQuietRow(systemImage: "clock.arrow.circlepath",
                      title: "On this day: \(entry.displayTitle)",
                      trailing: entry.createdAt.formatted(.dateTime.year()),
                      isFavorite: false) { openEntry(entry) }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.cardColor.opacity(0.32)))
            .accessibilityLabel("Open memory from this day: \(entry.displayTitle)")
    }

    /// Changes at the hours `TodayRolloverSchedule.boundaryHours` lists.
    nonisolated static func greeting(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Still awake?"
        }
    }
}

// MARK: - Midnight / greeting rollover

/// When the Today page has to re-render on its own: every midnight (date,
/// today's entry, recents, On This Day) and whenever the greeting changes.
nonisolated struct TodayRolloverSchedule: TimelineSchedule {
    /// Midnight plus the hours `TodayView.greeting(at:)` switches at.
    static let boundaryHours = [0, 5, 12, 17, 22]

    var calendar: Calendar = .current

    /// The first boundary strictly after `date`. `.nextTime` keeps a skipped
    /// midnight (a DST jump at 00:00) on the new day instead of dropping it.
    static func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date {
        let candidates = boundaryHours.compactMap {
            calendar.nextDate(after: date, matching: DateComponents(hour: $0, minute: 0, second: 0),
                              matchingPolicy: .nextTime)
        }
        return candidates.min() ?? date.addingTimeInterval(3_600)
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let calendar = calendar
        var next = startDate
        return AnyIterator {
            defer { next = Self.nextBoundary(after: next, calendar: calendar) }
            return next
        }
    }
}

/// One compact, hoverable line on Today (recent entries, On This Day).
private struct TodayQuietRow: View {
    var face: String?
    var systemImage: String?
    let title: String
    let trailing: String
    let isFavorite: Bool
    let action: () -> Void
    private let theme = ThemeManager.shared
    @State private var hover = false

    init(face: String? = nil, systemImage: String? = nil, title: String, trailing: String,
         isFavorite: Bool, action: @escaping () -> Void) {
        self.face = face; self.systemImage = systemImage
        self.title = title; self.trailing = trailing; self.isFavorite = isFavorite; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let face { Text(face).font(OmegaTheme.font(.body)) }
                    else if let systemImage {
                        Image(systemName: systemImage)
                            .font(OmegaTheme.font(.body, .medium))
                            .foregroundColor(theme.accentColor)
                    }
                }
                .frame(width: 22)
                .accessibilityHidden(true)
                Text(title)
                    .font(OmegaTheme.font(.body, .medium, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                    .lineLimit(1)
                if isFavorite {
                    Image(systemName: "star.fill").font(OmegaTheme.font(.meta)).foregroundColor(.yellow)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                Text(trailing)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(1).fixedSize()
                Image(systemName: "chevron.right")
                    .font(OmegaTheme.font(.meta, .semibold))
                    .foregroundColor(theme.secondaryTextColor.opacity(hover ? 0.9 : 0.4))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hover ? theme.cardColor.opacity(0.55) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct TodayGoalRow: View {
    let goal: WritingGoal
    private let theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: goal.isComplete ? "checkmark.circle.fill" : goal.type.icon)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(goal.isComplete ? .green : theme.accentColor)
                Text(goal.type.rawValue)
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.bodyTextColor)
                Spacer()
                Text(goal.displayProgress)
                    .font(OmegaTheme.font(.meta, design: .rounded))
                    .foregroundColor(theme.secondaryTextColor)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.secondaryTextColor.opacity(0.15))
                    Capsule()
                        .fill(goal.isComplete ? Color.green : theme.accentColor)
                        .frame(width: max(2, proxy.size.width * goal.progress))
                }
            }
            .frame(height: 5)
        }
    }
}
