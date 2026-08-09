import SwiftUI
import UniformTypeIdentifiers

// MARK: - App

@main
struct OmegaJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Entry") { NotificationCenter.default.post(name: .newEntry, object: nil) }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Delete Entry") { NotificationCenter.default.post(name: .deleteEntry, object: nil) }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}

extension Notification.Name {
    static let newEntry = Notification.Name("newEntry")
    static let deleteEntry = Notification.Name("deleteEntry")
}

// MARK: - Theme

enum OmegaTheme {
    // MARK: Spacing & Layout
    static let contentMaxWidth: CGFloat = 720
    static let contentPadding: CGFloat = 48
    static let cardPadding: CGFloat = 18
    static let cardRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 8
    static let sidebarWidth: CGFloat = 260

    // MARK: Typography
    static let titleFont = Font.system(size: 34, weight: .bold, design: .serif)
    static let bodyFont = Font.system(size: 16, design: .serif)
    static let headerFont = Font.system(size: 11, weight: .semibold)
    static let sectionTitleFont = Font.system(size: 13, weight: .semibold)
    static let metaFont = Font.system(size: 12)
    static let captionFont = Font.system(size: 11)

    // MARK: Surfaces
    static func cardBackground(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }
    static func cardBorder(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
    static func hairline(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }

    // MARK: Shadows
    static let cardShadow = Color.black.opacity(0.15)
    static let cardShadowRadius: CGFloat = 4
    static let cardShadowY: CGFloat = 2

    // MARK: Interactive
    static func hoverFill(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }
    static func selectedFill(accent: Color) -> Color { accent.opacity(0.14) }
    static func accentSoft(accent: Color) -> Color { accent.opacity(0.20) }

    // MARK: Buttons
    static let toolbarButtonSize: CGFloat = 28
    static let toolbarIconSize: CGFloat = 13
}

// MARK: - Content

struct ContentView: View {
    @StateObject private var vm = JournalViewModel()
    @ObservedObject private var theme = ThemeManager.shared
    @State private var sidebarSelection: SidebarItem? = .all

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm, selection: $sidebarSelection)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { vm.createEntry() } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .help("New Entry (⌘N)")
                    }
                }
        } content: {
            EntryListView(vm: vm, selection: $sidebarSelection)
        } detail: {
            DetailView(vm: vm, selection: $sidebarSelection)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(theme.accentColor)
        .preferredColorScheme(theme.colorScheme)
        .background(theme.backgroundColor)
        .onAppear { _ = ThemeManager.shared }
    }
}

// MARK: - Sidebar

enum SidebarItem: Hashable { case all, favorites, thisWeek, mood(Mood), insights, onThisDay }

struct SidebarView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @Binding var selection: SidebarItem?

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
}

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

// MARK: - Entry List

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
                .onChange(of: vm.searchText) { _, _ in vm.reload() }
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

// MARK: - Entry Card

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

// MARK: - Detail View

struct DetailView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?

    var body: some View {
        Group {
            if selection == .insights {
                InsightsView(vm: vm)
            } else if let eid = vm.editingEntryId, let entry = vm.entries.first(where: { $0.id == eid }) {
                EditorView(vm: vm, entry: entry)
            } else if let entry = vm.selectedEntry {
                ReadView(entry: entry, vm: vm)
            } else {
                EmptyDetail(vm: vm)
            }
        }
    }
}

// MARK: - Empty Detail

struct EmptyDetail: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.10))
                    .frame(width: 110, height: 110)
                Image(systemName: "book.pages")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(theme.accentColor.opacity(0.7))
            }

            VStack(spacing: 8) {
                Text("Select an entry or create a new one")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.secondary)
                Text("⌘N to start writing")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Divider()
                .frame(maxWidth: 280)

            VStack(spacing: 14) {
                Text("Today's prompt")
                    .font(OmegaTheme.headerFont)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text(PromptGenerator.today())
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)
                    .lineSpacing(3)
                    .frame(maxWidth: 380)
                Button { vm.createEntryFromPrompt() } label: {
                    Label("Write on this prompt", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Start a new entry pre-filled with today's prompt")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }
}

// MARK: - Read View

struct ReadView: View {
    let entry: JournalEntry
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showDeleteConfirm = false

    private var isDark: Bool { theme.colorScheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Hero section
                HStack(alignment: .top, spacing: 16) {
                    Text(entry.mood.emoji)
                        .font(.system(size: 44))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title.isEmpty ? "Untitled" : entry.title)
                            .font(OmegaTheme.titleFont)
                            .foregroundColor(.primary)
                        HStack(spacing: 8) {
                            Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                                .font(OmegaTheme.metaFont)
                                .foregroundColor(.secondary)
                            if entry.updatedAt > entry.createdAt.addingTimeInterval(1) {
                                Text("·")
                                    .font(OmegaTheme.metaFont)
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("Edited \(entry.updatedAt.formatted(.relative(presentation: .named)))")
                                    .font(OmegaTheme.metaFont)
                                    .foregroundColor(.secondary)
                            }
                            Text("·")
                                .font(OmegaTheme.metaFont)
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(entry.readingTime)
                                .font(OmegaTheme.metaFont)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    actionButtons
                }

                // Mood & tags
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Mood:")
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary)
                        Text(entry.mood.label)
                            .font(OmegaTheme.metaFont.weight(.medium))
                            .foregroundColor(entry.mood.color)
                    }
                    if !entry.tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(entry.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(OmegaTheme.captionFont.weight(.medium))
                                    .foregroundColor(theme.accentColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(theme.accentColor.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    Spacer()
                }

                Divider()
                    .background(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))

                // Body
                Text(entry.body.isEmpty ? "No content" : entry.body)
                    .font(OmegaTheme.bodyFont)
                    .foregroundColor(entry.body.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .lineSpacing(5)
            }
            .padding(OmegaTheme.contentPadding)
            .frame(maxWidth: OmegaTheme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor)
        .alert("Delete Entry", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { vm.deleteEntry(entry) }
        } message: {
            Text("Are you sure you want to delete \"\(entry.title.isEmpty ? "Untitled" : entry.title)\"? This cannot be undone.")
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            ActionButton(icon: entry.isPinned ? "pin.fill" : "pin", color: .orange, active: entry.isPinned, tooltip: entry.isPinned ? "Unpin entry" : "Pin entry") { vm.togglePin(entry) }
            ActionButton(icon: entry.isFavorite ? "star.fill" : "star", color: .yellow, active: entry.isFavorite, tooltip: entry.isFavorite ? "Remove from favorites" : "Add to favorites") { vm.toggleFavorite(entry) }
            ActionButton(icon: "pencil", color: theme.accentColor, active: false, tooltip: "Edit entry") { vm.startEditing(entry) }
            ActionButton(icon: "trash", color: .red, active: false, tooltip: "Delete entry", isDestructive: true) { showDeleteConfirm = true }
        }
    }
}

// MARK: - Shared Hover Card / Tooltip chrome
// Used by action-button tooltips and the Insights calendar day hovers.

enum OmegaHoverChrome {
    static let fill = Color(red: 0.11, green: 0.10, blue: 0.16)
    static let cornerRadius: CGFloat = 10
    static let arrowWidth: CGFloat = 10
    static let arrowHeight: CGFloat = 5
}

/// Dark glass card with accent border — shared look for tooltips & calendar hovers.
struct OmegaHoverCard<Content: View>: View {
    let accent: Color
    var showsArrow: Bool = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: OmegaHoverChrome.cornerRadius, style: .continuous)
                            .fill(OmegaHoverChrome.fill)
                        RoundedRectangle(cornerRadius: OmegaHoverChrome.cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.14), Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        RoundedRectangle(cornerRadius: OmegaHoverChrome.cornerRadius, style: .continuous)
                            .strokeBorder(accent.opacity(0.55), lineWidth: 1)
                    }
                )
                .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 6)
                .shadow(color: accent.opacity(0.22), radius: 8, x: 0, y: 2)

            if showsArrow {
                Triangle()
                    .fill(OmegaHoverChrome.fill)
                    .frame(width: OmegaHoverChrome.arrowWidth, height: OmegaHoverChrome.arrowHeight)
                    .overlay(
                        Triangle()
                            .stroke(accent.opacity(0.55), lineWidth: 1)
                            .frame(width: OmegaHoverChrome.arrowWidth, height: OmegaHoverChrome.arrowHeight)
                    )
                    .offset(y: -1)
            }
        }
        .compositingGroup()
    }
}

struct CustomTooltip: View {
    let text: String
    let color: Color

    var body: some View {
        OmegaHoverCard(accent: color) {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct TooltipContainer<Content: View>: View {
    let tooltip: String
    let color: Color
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false
    @State private var showTip = false

    var body: some View {
        content()
            .onHover { hovering in
                if hovering {
                    isHovered = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        if isHovered { showTip = true }
                    }
                } else {
                    isHovered = false
                    showTip = false
                }
            }
            .background(alignment: .top) {
                if showTip && !tooltip.isEmpty {
                    CustomTooltip(text: tooltip, color: color)
                        .offset(y: -44)
                        .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.82), value: showTip)
            .zIndex(showTip ? 1000 : 0)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let icon: String, color: Color, active: Bool
    let tooltip: String
    let isDestructive: Bool
    let action: () -> Void
    @State private var hover = false

    init(icon: String, color: Color, active: Bool, tooltip: String = "", isDestructive: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.color = color
        self.active = active
        self.tooltip = tooltip
        self.isDestructive = isDestructive
        self.action = action
    }

    private var hoverBackground: Color {
        if isDestructive && hover {
            return Color.red.opacity(0.18)
        }
        if active && hover {
            return color.opacity(0.18)
        }
        return hover ? Color(nsColor: .controlBackgroundColor) : Color.clear
    }

    private var iconColor: Color {
        if isDestructive && hover { return .red }
        if active { return color }
        return .secondary
    }

    var body: some View {
        TooltipContainer(tooltip: tooltip, color: isDestructive ? .red : color) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hoverBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                hover
                                    ? (isDestructive ? Color.red.opacity(0.35) : color.opacity(active ? 0.45 : 0.25))
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .scaleEffect(hover ? 1.08 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(.easeInOut(duration: 0.15), value: hover)
        }
    }
}

// MARK: - Editor View

struct EditorView: View {
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    @ObservedObject private var theme = ThemeManager.shared

    @State private var title = ""
    @State private var bodyText = ""
    @State private var mood: Mood = .neutral
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var saveStatus = "Saved"
    @State private var isBodyFocused = false

    private var isDark: Bool { theme.colorScheme == .dark }
    private var currentWordCount: Int { bodyText.isEmpty ? 0 : bodyText.split(whereSeparator: { $0.isWhitespace }).count }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    TextField("Entry title...", text: $title, axis: .vertical)
                        .font(OmegaTheme.titleFont)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .onChange(of: title) { _, _ in autoSave() }

                    HStack(spacing: 12) {
                        Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary)
                        Text("·")
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("\(currentWordCount) words")
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(.secondary)
                        Spacer()
                        saveIndicator
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("How are you feeling?")
                            .font(OmegaTheme.sectionTitleFont)
                        HStack(spacing: 8) {
                            ForEach(Mood.allCases) { moodButton($0) }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                            .font(OmegaTheme.sectionTitleFont)
                        FlowLayout(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                HStack(spacing: 4) {
                                    Text("#\(tag)")
                                        .font(OmegaTheme.captionFont)
                                    Button {
                                        tags.removeAll { $0 == tag }
                                        autoSave()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(theme.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            TextField("Add tag...", text: $tagInput)
                                .font(OmegaTheme.captionFont)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(theme.cardColor.opacity(0.6))
                                .clipShape(Capsule())
                                .frame(width: 100)
                                .onSubmit {
                                    let t = tagInput.trimmingCharacters(in: .whitespaces)
                                    if !t.isEmpty && !tags.contains(t) { tags.append(t); autoSave() }
                                    tagInput = ""
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Entry")
                            .font(OmegaTheme.sectionTitleFont)
                        TextEditor(text: $bodyText)
                            .font(OmegaTheme.bodyFont)
                            .frame(minHeight: 320)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                                    .fill(theme.cardColor.opacity(0.4))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                                    .strokeBorder(
                                        isBodyFocused
                                            ? theme.accentColor.opacity(0.5)
                                            : (isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)),
                                        lineWidth: 1
                                    )
                            )
                            .onChange(of: bodyText) { _, _ in autoSave() }
                            .lineSpacing(5)
                            .onTapGesture { isBodyFocused = true }
                    }
                }
                .padding(OmegaTheme.contentPadding)
                .frame(maxWidth: OmegaTheme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            // Bottom bar
            HStack {
                Button("Cancel") { vm.stopEditing() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Done") { vm.stopEditing() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, OmegaTheme.contentPadding)
            .padding(.vertical, 12)
            .background(theme.sidebarColor)
            .overlay(alignment: .top) {
                Divider()
                    .background(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            title = entry.title
            bodyText = entry.body
            mood = entry.mood
            tags = entry.tags
        }
    }

    private var saveIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(saveStatus == "Saved" ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(saveStatus)
                .font(OmegaTheme.captionFont)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    private func moodButton(_ m: Mood) -> some View {
        let sel = mood == m
        return Button {
            mood = m
            autoSave()
        } label: {
            VStack(spacing: 4) {
                Text(m.emoji)
                    .font(.system(size: 26))
                Text(m.label)
                    .font(.system(size: 10))
                    .foregroundColor(sel ? .primary : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .fill(sel ? theme.accentColor.opacity(0.18) : theme.cardColor.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .strokeBorder(sel ? theme.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func autoSave() {
        saveStatus = "Saving..."
        var u = entry
        u.title = title
        u.body = bodyText
        u.mood = mood
        u.tags = tags
        vm.autoSave(u)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            saveStatus = "Saved"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var dbPath = DatabaseManager.shared.databasePath

    var body: some View {
        TabView {
            Form {
                LabeledContent("Database location") {
                    VStack(alignment: .trailing) {
                        Text(dbPath).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (dbPath as NSString).deletingLastPathComponent) }
                    }
                }
                LabeledContent("Total entries") { Text("\\(DatabaseManager.shared.entryCount())") }
            }
            .tabItem { Label("General", systemImage: "gear") }

            ThemesTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            ExportTab()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 520, height: 380)
    }
}

// MARK: - Themes Tab

struct ThemesTab: View {
    @ObservedObject private var theme = ThemeManager.shared
    @State private var accent: Color = .accentColor
    @State private var background: Color = .black
    @State private var sidebar: Color = .black
    @State private var card: Color = .gray

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(ThemePresets.all.keys).sorted(), id: \.self) { name in
                            presetButton(name)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("Preset themes", systemImage: "swatchpalette")
                        .font(.system(size: 13, weight: .medium))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        ColorPicker("Accent", selection: $accent, supportsOpacity: false)
                        ColorPicker("Background", selection: $background, supportsOpacity: false)
                        ColorPicker("Sidebar", selection: $sidebar, supportsOpacity: false)
                        ColorPicker("Card", selection: $card, supportsOpacity: false)
                        Text("Custom colors save automatically as a “Custom” theme.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("Custom colors", systemImage: "eyedropper")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .padding(20)
        }
        .onAppear {
            accent = theme.accentColor
            background = theme.backgroundColor
            sidebar = theme.sidebarColor
            card = theme.cardColor
        }
        .onChange(of: accent) { _, _ in applyCustom() }
        .onChange(of: background) { _, _ in applyCustom() }
        .onChange(of: sidebar) { _, _ in applyCustom() }
        .onChange(of: card) { _, _ in applyCustom() }
    }

    private func applyCustom() {
        theme.applyCustom(accent: accent, background: background, sidebar: sidebar, card: card)
    }

    private func presetButton(_ name: String) -> some View {
        let preset = ThemePresets.all[name]!
        let selected = theme.themeName == name
        return Button {
            theme.applyTheme(named: name)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    HStack(spacing: 3) {
                        ForEach(preset.swatchColors, id: \.self) { c in
                            Circle()
                                .fill(c)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                        }
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.accentColor)
                        .font(.system(size: 14))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .strokeBorder(
                        selected ? theme.accentColor : Color.secondary.opacity(0.12),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Export Tab

struct ExportTab: View {
    @State private var exportMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export all entries as a single Markdown file.")
                        .font(.system(size: 13))
                    Button {
                        exportAll()
                    } label: {
                        Label("Export to Markdown…", systemImage: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if !exportMessage.isEmpty {
                        Text(exportMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
            } label: {
                Label("Markdown export", systemImage: "doc.text")
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(20)
    }

    private func exportAll() {
        let panel = NSSavePanel()
        panel.title = "Export journal as Markdown"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Omega-Journal-Export.md"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try MDExporter.export(DatabaseManager.shared.fetchAllEntries(), to: url)
                exportMessage = "Exported \(DatabaseManager.shared.entryCount()) entries to \(url.lastPathComponent)"
            } catch {
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let mw = proposal.width ?? .infinity
        var h: CGFloat = 0, x: CGFloat = 0, rh: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > mw { h += rh + spacing; x = 0; rh = 0 }
            x += sz.width + spacing; rh = max(rh, sz.height)
        }
        h += rh
        return CGSize(width: mw, height: h)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let mx = bounds.maxX; var x = bounds.minX, y = bounds.minY, rh: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > mx { x = bounds.minX; y += rh + spacing; rh = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rh = max(rh, sz.height)
        }
    }
}
