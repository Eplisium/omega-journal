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
    static let accent = Color(red: 0.35, green: 0.45, blue: 0.75)
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.30, green: 0.40, blue: 0.70), Color(red: 0.45, green: 0.35, blue: 0.65)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let sidebarGradient = LinearGradient(
        colors: [Color(red: 0.12, green: 0.13, blue: 0.18), Color(red: 0.08, green: 0.09, blue: 0.14)],
        startPoint: .top, endPoint: .bottom
    )
    static let titleFont = Font.system(size: 30, weight: .bold, design: .serif)
    static let bodyFont = Font.system(size: 16, design: .serif)
    static let headerFont = Font.system(size: 11, weight: .semibold)
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
                    HStack(spacing: 10) {
                        Text(mood.emoji).font(.title3)
                        Text(mood.label).foregroundColor(.primary)
                        Spacer()
                        if let c = vm.moodThisWeek[mood], c > 0 {
                            Text("\(c)").font(.caption2.weight(.medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(mood.color.opacity(0.25)).clipShape(Capsule())
                        }
                    }
                    .tag(SidebarItem.mood(mood))
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
        .navigationTitle("Omega Journal")
        .frame(minWidth: 240)
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
            .tracking(0.5)
    }
}

struct SidebarRow: View {
    let label: String, icon: String, color: Color
    let count: Int
    let tag: SidebarItem
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color).frame(width: 20)
            Text(label)
            Spacer()
            if count > 0 { Text("\(count)").font(.caption2.weight(.medium)).foregroundColor(.secondary) }
        }
        .tag(tag)
    }
}

struct StatRow: View {
    let title: String, value: String
    var body: some View {
        HStack { Text(title).font(.caption).foregroundColor(.secondary); Spacer(); Text(value).font(.caption.weight(.medium)) }
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
            Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 13))
            TextField("Search entries...", text: $vm.searchText)
                .textFieldStyle(.plain).font(.system(size: 13))
                .onChange(of: vm.searchText) { _, _ in vm.reload() }
            if !vm.searchText.isEmpty {
                Button { vm.searchText = ""; vm.reload() } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var sortBar: some View {
        HStack {
            Menu {
                ForEach(SortOrder.allCases) { o in Button(o.rawValue) { vm.sortOrder = o; vm.reload() } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 10))
                    Text(vm.sortOrder.rawValue).font(.system(size: 11))
                }.foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Text("\(filteredEntries.count) \(filteredEntries.count == 1 ? "entry" : "entries")")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder
    private var entryList: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "book").font(.system(size: 44)).foregroundColor(.secondary.opacity(0.5))
                Text(vm.searchText.isEmpty ? "No entries yet" : "No results found")
                    .font(.system(size: 16, weight: .medium)).foregroundColor(.secondary)
                Text(vm.searchText.isEmpty ? "Press ⌘N or click ✏️ to start writing" : "Try a different search")
                    .font(.system(size: 12)).foregroundColor(.secondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $vm.selectedEntryId) {
                ForEach(filteredEntries) { entry in
                    EntryCardView(entry: entry, isSelected: vm.selectedEntryId == entry.id)
                        .tag(entry.id)
                        .contextMenu {
                            Button(entry.isPinned ? "Unpin" : "Pin") { vm.togglePin(entry) }
                            Button(entry.isFavorite ? "Unfavorite" : "Favorite") { vm.toggleFavorite(entry) }
                            Divider()
                            Button("Delete", role: .destructive) { vm.deleteEntry(entry) }
                        }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(theme.backgroundColor)
            .alternatingRowBackgrounds()
        }
    }
}

// MARK: - Entry Card

struct EntryCardView: View {
    let entry: JournalEntry
    let isSelected: Bool
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(entry.mood.color).frame(width: 8, height: 8)
                if entry.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.orange) }
                if entry.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(.yellow) }
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .foregroundColor(entry.title.isEmpty ? .secondary : .primary)
                Spacer()
            }
            Text(entry.preview).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                Text(entry.createdAt.formatted(.dateTime.month().day().year()))
                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
                Text("·").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                Text("\(entry.wordCount) words").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
                if !entry.tags.isEmpty {
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(entry.tags.prefix(2), id: \.self) { Text("#\($0)").font(.system(size: 9)).foregroundColor(theme.accentColor.opacity(0.85)) }
                        if entry.tags.count > 2 { Text("+\(entry.tags.count - 2)").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5)) }
                    }
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? theme.accentColor.opacity(0.18) : theme.cardColor.opacity(0.55)))
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
        VStack(spacing: 24) {
            ZStack {
                Circle().fill(theme.accentColor.opacity(0.14)).frame(width: 120, height: 120)
                Image(systemName: "book.pages").font(.system(size: 44)).foregroundColor(theme.accentColor.opacity(0.8))
            }
            VStack(spacing: 6) {
                Text("Select an entry or create a new one").font(.system(size: 18, weight: .medium)).foregroundColor(.secondary)
                Text("⌘N to start writing").font(.system(size: 12)).foregroundColor(.secondary.opacity(0.6))
            }

            Divider().frame(maxWidth: 320)

            VStack(spacing: 12) {
                Text("Today's prompt").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).textCase(.uppercase).tracking(0.6)
                Text(PromptGenerator.today())
                    .font(.system(size: 16, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)
                    .frame(maxWidth: 420)
                Button { vm.createEntryFromPrompt() } label: {
                    Label("Write on this prompt", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .help("Start a new entry pre-filled with today's prompt")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Read View

struct ReadView: View {
    let entry: JournalEntry
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    Text(entry.mood.emoji).font(.system(size: 40))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title.isEmpty ? "Untitled" : entry.title)
                            .font(OmegaTheme.titleFont)
                        HStack(spacing: 10) {
                            Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                                .font(.system(size: 12)).foregroundColor(.secondary)
                            if entry.updatedAt > entry.createdAt.addingTimeInterval(1) {
                                Text("· Edited \(entry.updatedAt.formatted(.relative(presentation: .named)))")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                    }
                    Spacer()
                    actionButtons
                }
                HStack(spacing: 8) {
                    Text("Mood:").font(.system(size: 13)).foregroundColor(.secondary)
                    Text(entry.mood.label).font(.system(size: 13, weight: .medium)).foregroundColor(entry.mood.color)
                    Spacer()
                }
                if !entry.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(entry.tags, id: \.self) { tag in
                            Text("#\(tag)").font(.system(size: 12))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(theme.accentColor.opacity(0.14)).clipShape(Capsule())
                        }
                    }
                }
                Divider()
                Text(entry.body.isEmpty ? "No content" : entry.body)
                    .font(OmegaTheme.bodyFont)
                    .foregroundColor(entry.body.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled).lineSpacing(4)
            }
            .padding(40).frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity)
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
        HStack(spacing: 4) {
            ActionButton(icon: entry.isPinned ? "pin.fill" : "pin", color: .orange, active: entry.isPinned, tooltip: entry.isPinned ? "Unpin entry" : "Pin entry") { vm.togglePin(entry) }
            ActionButton(icon: entry.isFavorite ? "star.fill" : "star", color: .yellow, active: entry.isFavorite, tooltip: entry.isFavorite ? "Remove from favorites" : "Add to favorites") { vm.toggleFavorite(entry) }
            ActionButton(icon: "pencil", color: theme.accentColor, active: false, tooltip: "Edit entry") { vm.startEditing(entry) }
            ActionButton(icon: "trash", color: .red, active: false, tooltip: "Delete entry", isDestructive: true) { showDeleteConfirm = true }
        }
    }
}

// MARK: - Custom Tooltip

struct CustomTooltip: View {
    let text: String
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.12, green: 0.10, blue: 0.20))
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(color.opacity(0.6), lineWidth: 1)
                    }
                )
                .shadow(color: Color.black.opacity(0.5), radius: 10, x: 0, y: 4)
                .shadow(color: color.opacity(0.3), radius: 6, x: 0, y: 2)

            Triangle()
                .fill(Color(red: 0.12, green: 0.10, blue: 0.20))
                .frame(width: 8, height: 4)
                .overlay(
                    Triangle()
                        .stroke(color.opacity(0.6), lineWidth: 1)
                        .frame(width: 8, height: 4)
                )
                .offset(y: -1)
        }
        .compositingGroup()
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
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if isHovered { showTip = true }
                    }
                } else {
                    isHovered = false
                    showTip = false
                }
            }
            .background(alignment: .top) {
                if showTip {
                    CustomTooltip(text: tooltip, color: color)
                        .offset(y: -40)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showTip)
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
                        RoundedRectangle(cornerRadius: 8)
                            .fill(hoverBackground)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    TextField("Entry title...", text: $title, axis: .vertical)
                        .font(OmegaTheme.titleFont).textFieldStyle(.plain).lineLimit(1...3)
                        .onChange(of: title) { _, _ in autoSave() }

                    HStack(spacing: 12) {
                        Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                            .font(.system(size: 12)).foregroundColor(.secondary)
                        Text("·").font(.system(size: 12)).foregroundColor(.secondary.opacity(0.5))
                        Text("\(currentWordCount) words").font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer()
                        Text(saveStatus).font(.system(size: 11)).foregroundColor(.secondary.opacity(0.5))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("How are you feeling?").font(.system(size: 14, weight: .medium))
                        HStack(spacing: 8) { ForEach(Mood.allCases) { moodButton($0) } }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags").font(.system(size: 14, weight: .medium))
                        FlowLayout(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                HStack(spacing: 4) {
                                    Text("#\(tag)").font(.system(size: 12))
                                    Button { tags.removeAll { $0 == tag }; autoSave() } label: {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(.secondary)
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(theme.accentColor.opacity(0.14)).clipShape(Capsule())
                            }
                            TextField("Add tag...", text: $tagInput)
                                .font(.system(size: 12)).textFieldStyle(.plain)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color(nsColor: .controlBackgroundColor)).clipShape(Capsule()).frame(width: 110)
                                .onSubmit {
                                    let t = tagInput.trimmingCharacters(in: .whitespaces)
                                    if !t.isEmpty && !tags.contains(t) { tags.append(t); autoSave() }
                                    tagInput = ""
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Entry").font(.system(size: 14, weight: .medium))
                        TextEditor(text: $bodyText)
                            .font(OmegaTheme.bodyFont).frame(minHeight: 280).padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                            .onChange(of: bodyText) { _, _ in autoSave() }.lineSpacing(4)
                    }
                }
                .padding(40).frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity)
            }
            HStack {
                Button("Cancel") { vm.stopEditing() }.buttonStyle(.bordered)
                Spacer()
                Button("Done") { vm.stopEditing() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 40).padding(.vertical, 12).background(theme.sidebarColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { title = entry.title; bodyText = entry.body; mood = entry.mood; tags = entry.tags }
    }

    private var currentWordCount: Int { bodyText.isEmpty ? 0 : bodyText.split(whereSeparator: { $0.isWhitespace }).count }

    private func moodButton(_ m: Mood) -> some View {
        let sel = mood == m
        return Button { mood = m; autoSave() } label: {
            VStack(spacing: 4) {
                Text(m.emoji).font(.system(size: 26))
                Text(m.label).font(.system(size: 10))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(sel ? theme.accentColor.opacity(0.2) : theme.cardColor))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(sel ? theme.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func autoSave() {
        saveStatus = "Saving..."
        var u = entry; u.title = title; u.body = bodyText; u.mood = mood; u.tags = tags
        vm.autoSave(u)
        Task { @MainActor in try? await Task.sleep(nanoseconds: 900_000_000); saveStatus = "Saved" }
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
        .frame(width: 460, height: 320)
    }
}

// MARK: - Themes Tab

struct ThemesTab: View {
    @ObservedObject private var theme = ThemeManager.shared
    @State private var accent: Color = .accentColor
    @State private var background: Color = .black
    @State private var sidebar: Color = .black
    @State private var card: Color = .gray

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(ThemePresets.all.keys).sorted(), id: \.self) { name in
                            presetButton(name)
                        }
                    }
                } label: { Label("Preset themes", systemImage: "swatchpalette") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ColorPicker("Accent", selection: $accent, supportsOpacity: false)
                        ColorPicker("Background", selection: $background, supportsOpacity: false)
                        ColorPicker("Sidebar", selection: $sidebar, supportsOpacity: false)
                        ColorPicker("Card", selection: $card, supportsOpacity: false)
                        Text("Custom colors save automatically as a “Custom” theme.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } label: { Label("Custom colors", systemImage: "eyedropper") }
            }
            .padding(16)
        }
        .onAppear {
            accent = theme.accentColor
            background = theme.backgroundColor
            sidebar = theme.sidebarColor
            card = theme.cardColor
        }
        .onChange(of: accent) { _, n in applyCustom() }
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
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 12, weight: .medium))
                    HStack(spacing: 3) {
                        ForEach(preset.swatchColors, id: \.self) { c in
                            Circle().fill(c).frame(width: 13, height: 13)
                        }
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(theme.accentColor)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? theme.accentColor : Color.secondary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Export Tab

struct ExportTab: View {
    @State private var exportMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Export all entries as a single Markdown file.").font(.system(size: 13))
                    Button {
                        exportAll()
                    } label: {
                        Label("Export to Markdown…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    if !exportMessage.isEmpty {
                        Text(exportMessage).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                .padding(6)
            } label: { Label("Markdown export", systemImage: "doc.text") }
        }
        .padding(16)
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
