import SwiftUI

// MARK: - Entry List View

struct EntryListView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @Binding var selection: SidebarItem?

    var filteredEntries: [JournalEntry] {
        guard let s = selection else { return vm.entries }
        switch s {
        case .all: return vm.entries
        case .favorites: return vm.entries.filter { $0.isFavorite }
        case .thisWeek: return vm.entries.filter { $0.createdAt >= Date().addingTimeInterval(-7*24*3600) }
        case .mood(let m): return vm.entries.filter { $0.mood == m }
        case .onThisDay: return vm.onThisDay
        case .insights: return vm.entries
        case .tag(let t): return vm.entries.filter { $0.tags.contains(t) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            sortBar
            Divider()
            entryList
        }
        .frame(minWidth: 320)
        .background(theme.backgroundColor)
        .onReceive(NotificationCenter.default.publisher(for: .newEntry)) { _ in vm.createEntry() }
        .onReceive(NotificationCenter.default.publisher(for: .deleteEntry)) { _ in if let e = vm.selectedEntry { vm.deleteEntry(e) } }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 13))
            TextField("Search entries...", text: $vm.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { vm.performSearch() }
                .onChange(of: vm.searchText) { _, newValue in
                    if newValue.isEmpty { vm.reload() }
                }
            if !vm.searchText.isEmpty {
                Button { vm.searchText = ""; vm.reload() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sortBar: some View {
        HStack {
            Menu {
                ForEach(SortOrder.allCases) { o in
                    Button(o.rawValue) { vm.sortOrder = o; vm.reload() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10))
                    Text(vm.sortOrder.rawValue)
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Text("\(filteredEntries.count) \(filteredEntries.count == 1 ? "entry" : "entries")")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var entryList: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "book")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(vm.searchText.isEmpty ? "No entries yet" : "No results found")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                Text(vm.searchText.isEmpty ? "Press ⌘N or click ✏️ to start writing" : "Try a different search")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredEntries) { entry in
                        EntryCardView(entry: entry, isSelected: vm.selectedEntryId == entry.id)
                            .tag(entry.id)
                            .onTapGesture { vm.toggleSelection(entry) }
                            .contextMenu {
                                Button(entry.isPinned ? "Unpin" : "Pin") { vm.togglePin(entry) }
                                Button(entry.isFavorite ? "Unfavorite" : "Favorite") { vm.toggleFavorite(entry) }
                                Divider()
                                Button("Delete", role: .destructive) { vm.deleteEntry(entry) }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
            .background(theme.backgroundColor)
        }
    }
}

// MARK: - Entry Card View

struct EntryCardView: View {
    let entry: JournalEntry
    let isSelected: Bool
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false

    private var isDark: Bool { theme.colorScheme == .dark }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
            .fill(isSelected
                ? theme.accentColor.opacity(0.14)
                : (isHovered
                    ? theme.cardColor.opacity(0.85)
                    : theme.cardColor.opacity(0.55)))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.mood.color)
                    .frame(width: 7, height: 7)
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(entry.title.isEmpty ? .secondary : .primary)
                Spacer()
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
                if entry.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                }
                if !entry.attachments.isEmpty {
                    Image(systemName: "paperclip")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            // Preview
            Text(entry.preview)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .lineSpacing(2)

            // Metadata row
            HStack(spacing: 6) {
                Text(relativeDate(entry.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                Text("·")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("\(entry.wordCount) words")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                if !entry.tags.isEmpty {
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(entry.tags.prefix(2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(theme.accentColor.opacity(0.85))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.accentColor.opacity(0.10))
                                .clipShape(Capsule())
                        }
                        if entry.tags.count > 2 {
                            Text("+\(entry.tags.count - 2)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                }
            }
        }
        .padding(OmegaTheme.cardPadding)
        .background(cardBackground)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                .strokeBorder(
                    isSelected
                        ? theme.accentColor.opacity(0.35)
                        : (isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)),
                    lineWidth: 1
                )
        )
        .shadow(
            color: isDark ? Color.black.opacity(0.25) : Color.black.opacity(0.08),
            radius: isSelected ? 6 : 3,
            x: 0,
            y: isSelected ? 3 : 1
        )
        .scaleEffect(isHovered && !isSelected ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }

    var body: some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.title.isEmpty ? "Untitled entry" : entry.title)
            .accessibilityHint("Double-tap to open")
            .accessibilityAddTraits(.isButton)
    }

    private func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(days)d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
