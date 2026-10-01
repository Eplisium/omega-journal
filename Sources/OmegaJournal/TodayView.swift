import SwiftUI
import OmegaJournalCore

// MARK: - Today workspace

/// A calm starting point for writing. It intentionally surfaces only a few
/// recent memories; the complete library belongs in the Journal workspace.
struct TodayView: View {
    @ObservedObject var vm: JournalViewModel
    let openJournal: () -> Void
    let openCalendar: () -> Void
    let openInsights: () -> Void
    let openEntry: (JournalEntry) -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var goals = GoalManager.shared

    private var recentEntries: [JournalEntry] {
        Array(vm.calendarEntries.sorted { $0.createdAt > $1.createdAt }.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                welcomeHeader
                heroCard
                statRow
                writingPrompt
                progressAndShortcuts

                if !recentEntries.isEmpty {
                    recentWriting
                }

                if !vm.reflectiveOnThisDay.isEmpty {
                    memoryMoment
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 1_120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor)
    }

    private var welcomeHeader: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(greeting)
                    .font(OmegaTheme.font(.meta, .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)

                Text(todayLabel)
                    .font(OmegaTheme.font(.body, .medium))
                    .foregroundColor(theme.secondaryTextColor)

                Text(vm.entries.isEmpty
                     ? "A private place to put down a thought."
                     : "\(StreakCopy.streakLine(vm.streakSummary)) · \(vm.entriesThisMonth) entries this month")
                    .font(OmegaTheme.font(.body))
                    .foregroundColor(theme.bodyTextColor)
            }

            Spacer(minLength: 16)

            Button {
                openJournal()
                vm.createEntry()
            } label: {
                Label("Write", systemImage: "square.and.pencil")
                    .font(OmegaTheme.font(.body, .semibold))
                    .foregroundColor(theme.onAccentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(theme.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Write a new journal entry")
        }
    }

    // MARK: Hero — today's entry

    private var todaysEntry: JournalEntry? {
        vm.entries
            .filter { Calendar.current.isDate($0.createdAt, inSameDayAs: Date()) }
            .max { $0.createdAt < $1.createdAt }
    }

    @ViewBuilder
    private var heroCard: some View {
        if let entry = todaysEntry {
            Button { openEntry(entry) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.mood.color)
                            .frame(width: 7, height: 7)
                        Text("Today · \(entry.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                            .font(OmegaTheme.font(.meta, .medium))
                            .foregroundColor(theme.secondaryTextColor)
                        Spacer()
                        if !entry.tags.isEmpty {
                            ForEach(entry.tags.prefix(2), id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(OmegaTheme.font(.meta, .medium))
                                    .foregroundColor(theme.accentColor.opacity(0.9))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                            }
                        }
                    }

                    Text("Today's entry")
                        .font(OmegaTheme.font(.meta, .semibold))
                        .tracking(1.0)
                        .foregroundColor(theme.secondaryTextColor)

                    Text(entry.displayTitle)
                        .font(OmegaTheme.font(.caption, .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                        .lineLimit(1)

                    Text(entry.preview)
                        .font(OmegaTheme.font(.caption))
                        .foregroundColor(theme.bodyTextColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 10) {
                        Label("Continue writing", systemImage: "pencil.line")
                            .font(OmegaTheme.font(.caption, .semibold))
                            .foregroundColor(theme.onAccentColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(theme.accentColor))
                        Text("\(entry.wordCount) words")
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.secondaryTextColor)
                        Spacer()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.cardColor.opacity(0.72))
                )
                .shadow(color: theme.accentColor.opacity(0.18), radius: 20, x: 0, y: 6)
                .contentShape(Rectangle())
                .hoverGlow(radius: 16, glow: 0.4, border: 0.55)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue today's entry: \(entry.displayTitle)")
        }
    }

    // MARK: Stat cards

    private var statRow: some View {
        HStack(spacing: 14) {
            statCard(value: "\(vm.entriesThisWeek)", label: "Entries this week", detail: StreakCopy.streakLine(vm.streakSummary))
            statCard(value: vm.totalWordCount.formatted(), label: "Words written", detail: "\(vm.entries.count) entries total")
            statCard(value: "\(vm.entriesThisMonth)", label: "This month", detail: "Every entry counts")
        }
    }

    private func statCard(value: String, label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(OmegaTheme.font(.bodyLarge, .bold, design: .serif))
                .foregroundColor(theme.titleTextColor)
            Text(label)
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.bodyTextColor)
            Text(detail)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.cardColor.opacity(0.5))
        )
        .hoverGlow(radius: 13, glow: 0.26, border: 0.3, lift: false)
    }

    private var writingPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.accentColor)
                Text("TODAY'S PROMPT")
                    .font(OmegaTheme.font(.meta, .semibold))
                    .tracking(0.9)
                    .foregroundColor(theme.secondaryTextColor)
            }

            Text(PromptGenerator.today())
                .font(OmegaTheme.font(.caption, .medium, design: .serif))
                .foregroundColor(theme.titleTextColor)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openJournal()
                vm.createEntryFromPrompt()
            } label: {
                Label("Write about this", systemImage: "arrow.right")
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardColor.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var progressAndShortcuts: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("TODAY'S PROGRESS")
                    .font(OmegaTheme.font(.meta, .semibold))
                    .tracking(0.8)
                    .foregroundColor(theme.secondaryTextColor)

                ForEach(goals.goals.filter { $0.type == .dailyWords || $0.type == .dailyEntries }) { goal in
                    TodayGoalRow(goal: goal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.cardColor.opacity(0.42)))

            VStack(alignment: .leading, spacing: 12) {
                Text("RETURN TO")
                    .font(OmegaTheme.font(.meta, .semibold))
                    .tracking(0.8)
                    .foregroundColor(theme.secondaryTextColor)

                HStack(spacing: 8) {
                    TodayShortcut(icon: "books.vertical", title: "Journal", subtitle: "All entries", action: openJournal)
                    TodayShortcut(icon: "calendar", title: "Calendar", subtitle: "Browse time", action: openCalendar)
                    TodayShortcut(icon: "chart.line.uptrend.xyaxis", title: "Insights", subtitle: "Reflect", action: openInsights)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.cardColor.opacity(0.42)))
        }
    }

    private var recentWriting: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent writing")
                        .font(OmegaTheme.font(.heading, .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                    Text("A few places to return to")
                        .font(OmegaTheme.font(.caption))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Button("See all") { openJournal() }
                    .buttonStyle(.plain)
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.accentColor)
            }

            HStack(alignment: .top, spacing: 14) {
                ForEach(recentEntries) { entry in
                    Button { openEntry(entry) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(entry.mood.color)
                                    .frame(width: 7, height: 7)
                                Text(entry.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                    .font(OmegaTheme.font(.meta))
                                    .foregroundColor(theme.secondaryTextColor)
                                Spacer(minLength: 4)
                                if entry.isFavorite {
                                    Image(systemName: "star.fill")
                                        .font(OmegaTheme.font(.meta))
                                        .foregroundColor(.yellow)
                                }
                            }

                            Text(entry.displayTitle)
                                .font(OmegaTheme.font(.bodyLarge, .semibold, design: .serif))
                                .foregroundColor(theme.titleTextColor)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Text(entry.preview)
                                .font(OmegaTheme.font(.meta))
                                .foregroundColor(theme.secondaryTextColor)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(minHeight: 42, alignment: .top)

                            Spacer(minLength: 0)

                            HStack(spacing: 4) {
                                ForEach(entry.tags.prefix(2), id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(OmegaTheme.font(.meta, .medium))
                                        .foregroundColor(theme.accentColor.opacity(0.9))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                                }
                                Spacer(minLength: 2)
                                Text("\(entry.wordCount)w")
                                    .font(OmegaTheme.font(.meta))
                                    .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(theme.cardColor.opacity(0.5))
                        )
                        .contentShape(Rectangle())
                        .hoverGlow(radius: 13, glow: 0.3, border: 0.4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(entry.displayTitle)")
                }
            }
        }
    }

    private var memoryMoment: some View {
        let entry = vm.reflectiveOnThisDay[0]
        return Button { openEntry(entry) } label: {
            HStack(spacing: 13) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(OmegaTheme.font(.heading, .medium))
                    .foregroundColor(.teal)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.teal.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("On This Day")
                        .font(OmegaTheme.font(.caption, .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text(entry.displayTitle)
                        .font(OmegaTheme.font(.body))
                        .foregroundColor(theme.secondaryTextColor)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(OmegaTheme.font(.meta, .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(theme.cardColor.opacity(0.34)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open memory from this day: \(entry.displayTitle)")
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Still awake?"
        }
    }

    private var todayLabel: String {
        Date().formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct TodayGoalRow: View {
    let goal: WritingGoal
    @ObservedObject private var theme = ThemeManager.shared

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

private struct TodayShortcut: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: icon)
                    .font(OmegaTheme.font(.bodyLarge, .medium))
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(OmegaTheme.font(.meta, .semibold))
                    .foregroundColor(theme.bodyTextColor)
                Text(subtitle)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.backgroundColor.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(title)")
    }
}
