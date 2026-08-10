import SwiftUI

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var goals = GoalManager.shared

    @State private var tagsExpanded = true
    @State private var moodsExpanded = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    streakCard

                    section("LIBRARY") {
                        row(.all, badge: vm.entries.count)
                        row(.favorites, badge: vm.favoriteCount)
                        row(.thisWeek, badge: vm.entriesThisWeek)
                        if !vm.onThisDay.isEmpty {
                            row(.onThisDay, badge: vm.onThisDay.count)
                        }
                    }

                    section("BROWSE") {
                        row(.calendar)
                        row(.insights)
                    }

                    disclosureSection("MOODS", isExpanded: $moodsExpanded) {
                        ForEach(Mood.allCases) { mood in
                            let count = vm.entries.filter { $0.mood == mood }.count
                            if count > 0 { row(.mood(mood), badge: count) }
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
            SettingsView(vm: vm)
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
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Omega Journal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text("\(vm.entries.count) entries · \(vm.totalWordCount.formatted()) words")
                    .font(.system(size: 10))
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
                        .font(.system(size: 11))
                        .foregroundColor(vm.writingStreak > 0 ? .orange : theme.secondaryTextColor.opacity(0.5))
                    Text("\(vm.writingStreak)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(theme.titleTextColor)
                }
                Text("day streak")
                    .font(.system(size: 9))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Divider().frame(height: 26).opacity(0.25)
            VStack(spacing: 1) {
                Text("\(vm.entriesThisMonth)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(theme.titleTextColor)
                Text("this month")
                    .font(.system(size: 9))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardColor.opacity(0.6))
        )
        .padding(.bottom, 10)
    }

    // MARK: Goals card

    private var goalsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TODAY'S GOALS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.secondaryTextColor)
                .tracking(0.7)
                .padding(.horizontal, 4)

            ForEach(goals.goals.filter { $0.type == .dailyWords || $0.type == .dailyEntries }) { goal in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: goal.isComplete ? "checkmark.circle.fill" : goal.type.icon)
                            .font(.system(size: 9))
                            .foregroundColor(goal.isComplete ? .green : theme.accentColor)
                        Text(goal.type.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.bodyTextColor)
                        Spacer()
                        Text(goal.displayProgress)
                            .font(.system(size: 9, design: .rounded))
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
                vm.createEntry()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .semibold))
                    Text("New Entry").font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(.plain)
            .help("New Entry (⌘N)")

            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryTextColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.cardColor.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
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
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.secondaryTextColor)
                        .tracking(0.7)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
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

            if isExpanded.wrappedValue { content() }
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

    private var tint: Color {
        if case .mood(let m) = item { return m.color }
        if case .trash = item { return .red }
        return theme.accentColor
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? tint : theme.secondaryTextColor)
                    .frame(width: 15)
                Text(item.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.titleTextColor : theme.bodyTextColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
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
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
