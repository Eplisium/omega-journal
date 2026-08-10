import SwiftUI

// MARK: - Sidebar View

struct SidebarView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @Binding var selection: SidebarItem?
    @State private var topTags: [(tag: String, count: Int)] = []

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            List(selection: $selection) {
                Section {
                    SidebarRow(label: "Insights", icon: "chart.xyaxis.line", color: .accentColor, count: 0, tag: .insights)
                    SidebarRow(label: "On This Day", icon: "clock.arrow.circlepath", color: .teal, count: vm.onThisDay.count, tag: .onThisDay)
                } header: { SidebarHeader("Discover") }

                Section {
                    SidebarRow(label: "All Entries", icon: "book.closed.fill", color: .accentColor, count: vm.entryCount, tag: .all)
                    SidebarRow(label: "Favorites", icon: "star.fill", color: .yellow, count: vm.entries.filter { $0.isFavorite }.count, tag: .favorites)
                    SidebarRow(label: "This Week", icon: "calendar", color: .green, count: vm.entriesThisWeek, tag: .thisWeek)
                } header: { SidebarHeader("Library") }

                if !topTags.isEmpty {
                    Section {
                        ForEach(topTags.prefix(8), id: \.tag) { item in
                            tagRow(item.tag, count: item.count)
                        }
                    } header: { SidebarHeader("Tags") }
                }

                Section {
                    ForEach(Mood.allCases) { mood in
                        moodRow(mood)
                    }
                } header: { SidebarHeader("Moods") }

                Section {
                    StatRow(title: "Total Entries", value: "\(vm.entryCount)")
                    StatRow(title: "This Week", value: "\(vm.entriesThisWeek)")
                    StatRow(title: "Avg Mood", value: String(format: "%.1f", vm.averageMood))
                    StatRow(title: "Total Words", value: "\(vm.totalWordCount)")
                    StatRow(title: "Writing Streak", value: "\(vm.writingStreak) days")
                } header: { SidebarHeader("Statistics") }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(theme.sidebarColor)
        }
        .background(theme.sidebarColor)
        .frame(minWidth: OmegaTheme.sidebarWidth)
        .onAppear { loadTags() }
        .onChange(of: vm.entries.count) { _, _ in loadTags() }
    }

    private func loadTags() {
        topTags = vm.db.tagsWithCounts()
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.pages")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accentColor)
            Text("Omega Journal")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(theme.sidebarColor)
    }

    private func moodRow(_ mood: Mood) -> some View {
        HStack(spacing: 10) {
            Text(mood.emoji).font(.title3)
            Text(mood.label).foregroundColor(.primary)
            Spacer()
            if let c = vm.moodThisWeek[mood], c > 0 {
                Text("\(c)")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(mood.color.opacity(0.25))
                    .clipShape(Capsule())
            }
        }
        .tag(SidebarItem.mood(mood))
    }

    private func tagRow(_ tag: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "number")
                .foregroundColor(theme.accentColor.opacity(0.7))
                .font(.system(size: 12))
                .frame(width: 20)
            Text(tag)
                .font(.system(size: 13))
                .foregroundColor(.primary)
            Spacer()
            Text("\(count)")
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
        }
        .tag(SidebarItem.tag(tag))
    }
}

// MARK: - Sidebar Supporting Views

struct SidebarHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(OmegaTheme.headerFont)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.8)
            .padding(.leading, 2)
    }
}

struct SidebarRow: View {
    let label: String, icon: String, color: Color
    let count: Int
    let tag: SidebarItem
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 13))
                .frame(width: 20)
            Text(label)
                .font(.system(size: 13))
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
        .tag(tag)
    }
}

struct StatRow: View {
    let title: String, value: String
    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 1)
    }
}
