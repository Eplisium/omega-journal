import SwiftUI

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
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)

                Text(todayLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryTextColor)

                Text(vm.entries.isEmpty
                     ? "A private place to put down a thought."
                     : "\(vm.writingStreak)-day rhythm · \(vm.entriesThisMonth) entries this month")
                    .font(.system(size: 13))
                    .foregroundColor(theme.bodyTextColor)
            }

            Spacer(minLength: 16)

            Button {
                openJournal()
                vm.createEntry()
            } label: {
                Label("Write", systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(theme.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Write a new journal entry")
        }
    }

    private var writingPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text("TODAY'S PROMPT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.9)
                    .foregroundColor(theme.secondaryTextColor)
            }

            Text(PromptGenerator.today())
                .font(.system(size: 22, weight: .medium, design: .serif))
                .foregroundColor(theme.titleTextColor)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openJournal()
                vm.createEntryFromPrompt()
            } label: {
                Label("Write about this", systemImage: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 10, weight: .semibold))
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
                    .font(.system(size: 10, weight: .semibold))
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
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                    Text("A few places to return to")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Button("See all") { openJournal() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }

            ForEach(recentEntries) { entry in
                Button { openEntry(entry) } label: {
                    HStack(spacing: 11) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(entry.mood.color)
                            .frame(width: 3, height: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.displayTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.titleTextColor)
                                .lineLimit(1)
                            Text(entry.preview)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryTextColor)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(entry.createdAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryTextColor)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardColor.opacity(0.34)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(entry.displayTitle)")
            }
        }
    }

    private var memoryMoment: some View {
        let entry = vm.reflectiveOnThisDay[0]
        return Button { openEntry(entry) } label: {
            HStack(spacing: 13) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.teal)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.teal.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("On This Day")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text(entry.displayTitle)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryTextColor)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 10))
                    .foregroundColor(goal.isComplete ? .green : theme.accentColor)
                Text(goal.type.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.bodyTextColor)
                Spacer()
                Text(goal.displayProgress)
                    .font(.system(size: 10, design: .rounded))
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.bodyTextColor)
                Text(subtitle)
                    .font(.system(size: 9.5))
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
