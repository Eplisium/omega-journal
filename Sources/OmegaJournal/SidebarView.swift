import SwiftUI
import OmegaJournalCore

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var goals = GoalManager.shared

    @AppStorage("shell.sidebar.tagsExpanded") private var tagsExpanded = true
    @AppStorage("shell.sidebar.moodsExpanded") private var moodsExpanded = false
    @AppStorage("shell.sidebar.savedExpanded") private var savedExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false
    @State private var settingsSection: SettingsSection = .appearance

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !vm.entries.isEmpty { streakCard }

                    section("TODAY") {
                        row(.today)
                    }

                    section("LIBRARY") {
                        row(.all, badge: vm.entries.count)
                        row(.favorites, badge: vm.favoriteCount)
                        row(.thisWeek, badge: vm.entriesThisWeek)
                    }

                    section("REFLECT") {
                        row(.calendar)
                        row(.insights)
                        row(.onThisDay, badge: vm.reflectiveOnThisDay.count)
                    }

                    disclosureSection("MOODS", isExpanded: $moodsExpanded) {
                        ForEach(Mood.allCases) { mood in
                            let count = vm.moodCounts[mood] ?? 0
                            if count > 0 { row(.mood(mood), badge: count) }
                        }
                    }

                    if !vm.savedSearches.isEmpty {
                        disclosureSection("SAVED SEARCHES", isExpanded: $savedExpanded) {
                            ForEach(vm.savedSearches) { search in
                                savedSearchRow(search)
                            }
                        }
                    }

                    if !vm.allTags.isEmpty {
                        disclosureSection("TAGS", isExpanded: $tagsExpanded) {
                            ForEach(vm.allTags.prefix(24), id: \.tag) { item in
                                row(.tag(item.tag), badge: item.count)
                            }
                        }
                    }

                    section("STORAGE") {
                        row(.archive, badge: vm.archivedEntries.count)
                        row(.hidden, badge: vm.hiddenCount)
                        row(.trash, badge: vm.trashedEntries.count)
                    }

                    goalsCard
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)

            Divider().opacity(0.25)
            footer
        }
        .background(theme.sidebarColor)
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm, initialSection: settingsSection)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            settingsSection = .appearance
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showShortcuts)) { _ in
            settingsSection = .about
            showSettings = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                Text("Ω")
                    .font(OmegaTheme.font(.bodyLarge, .bold, design: .serif))
                    .foregroundColor(theme.onAccentColor)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Omega Journal")
                    .font(OmegaTheme.font(.body, .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                Text("\(vm.entries.count) entries · \(vm.totalWordCount.formatted()) words")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Streak card

    private var streakCard: some View {
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(vm.writingStreak > 0 ? .orange : theme.secondaryTextColor.opacity(0.5))
                    Text("\(vm.writingStreak)")
                        .font(OmegaTheme.font(.heading, .bold, design: .rounded))
                        .foregroundColor(theme.titleTextColor)
                }
                Text(vm.writingStreak == 0 ? "fresh start" : "\(vm.streakUnit)\(vm.writingStreak == 1 ? "" : "s") showing up")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Divider().frame(height: 26).opacity(0.25)
            VStack(spacing: 1) {
                Text("\(vm.entriesThisMonth)")
                    .font(OmegaTheme.font(.heading, .bold, design: .rounded))
                    .foregroundColor(theme.titleTextColor)
                Text("this month")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.cardColor.opacity(0.6))
        )
        .hoverGlow(radius: 11, glow: 0.3, border: 0.35, lift: false)
        .padding(.bottom, 10)
    }

    // MARK: Goals card

    private var goalsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TODAY'S GOALS")
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.secondaryTextColor)
                .tracking(0.7)
                .padding(.horizontal, 4)

            ForEach(goals.goals.filter { $0.type == .dailyWords || $0.type == .dailyEntries }) { goal in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
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
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.secondaryTextColor.opacity(0.15))
                            Capsule()
                                .fill(goal.isComplete ? Color.green : theme.accentColor)
                                .frame(width: max(2, geo.size.width * goal.progress))
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 10)
        .padding(.top, 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                selection = .all
                vm.createEntry()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil").font(OmegaTheme.font(.meta, .semibold))
                    Text("New Entry").font(OmegaTheme.font(.meta, .medium))
                }
                .foregroundColor(theme.onAccentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(.plain)
            .omegaTooltip("New Entry (⌘N)")

            Button { settingsSection = .appearance; showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(OmegaTheme.font(.caption))
                    .foregroundColor(theme.secondaryTextColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.cardColor.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .omegaTooltip("Settings (⌘,)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.secondaryTextColor)
                .tracking(0.7)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 3)
            content()
        }
    }

    @ViewBuilder
    private func disclosureSection<C: View>(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if reduceMotion { isExpanded.wrappedValue.toggle() } else { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() } }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(OmegaTheme.font(.meta, .semibold))
                        .foregroundColor(theme.secondaryTextColor)
                        .tracking(0.7)
                    Image(systemName: "chevron.right")
                        .font(OmegaTheme.font(.meta, .bold))
                        .foregroundColor(theme.secondaryTextColor)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title.capitalized) section")
            .accessibilityValue(isExpanded.wrappedValue ? "expanded" : "collapsed")
            .accessibilityHint("Double tap to \(isExpanded.wrappedValue ? "collapse" : "expand")")

            if isExpanded.wrappedValue { content() }
        }
    }

    private func savedSearchRow(_ search: SavedSearch) -> some View {
        Button {
            selection = .all
            vm.selectedEntryId = nil
            vm.applySavedSearch(search)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.secondaryTextColor)
                    .frame(width: 15)
                Text(search.name)
                    .font(OmegaTheme.font(.caption))
                    .foregroundColor(theme.bodyTextColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Saved search: \(search.name)")
        .contextMenu {
            Button("Delete Saved Search", role: .destructive) { vm.deleteSavedSearch(search) }
        }
    }

    private func row(_ item: SidebarItem, badge: Int? = nil) -> some View {
        SidebarRow(
            item: item,
            badge: badge,
            isSelected: selection == item,
            theme: theme
        ) {
            selection = item
            vm.selectedEntryId = nil
        }
    }
}

// MARK: - Sidebar Row

private struct SidebarRow: View {
    let item: SidebarItem
    let badge: Int?
    let isSelected: Bool
    let theme: ThemeManager
    let action: () -> Void

    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        if case .mood(let m) = item { return m.color }
        if case .trash = item { return .red }
        return theme.accentColor
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(isSelected ? tint : theme.secondaryTextColor)
                    .frame(width: 15)
                Text(item.title)
                    .font(OmegaTheme.font(.caption, isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.titleTextColor : theme.bodyTextColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(OmegaTheme.font(.meta, .medium, design: .rounded))
                        .foregroundColor(isSelected ? tint : theme.secondaryTextColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                isSelected ? tint.opacity(0.18) : theme.secondaryTextColor.opacity(0.12)
                            )
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.16) : (hover ? Color.white.opacity(0.05) : .clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(tint)
                        .frame(width: 2.5, height: 14)
                        .offset(x: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(badge.map { $0 > 0 ? "\($0) \($0 == 1 ? "entry" : "entries")" : "" } ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { hover = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover)
    }
}
