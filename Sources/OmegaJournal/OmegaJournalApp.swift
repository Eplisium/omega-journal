import SwiftUI

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
            DetailView(vm: vm)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Sidebar

enum SidebarItem: Hashable { case all, favorites, thisWeek, mood(Mood) }

struct SidebarView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
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
    @Binding var selection: SidebarItem?

    var filteredEntries: [JournalEntry] {
        guard let s = selection else { return vm.entries }
        switch s {
        case .all: return vm.entries
        case .favorites: return vm.entries.filter { $0.isFavorite }
        case .thisWeek: return vm.entries.filter { $0.createdAt >= Date().addingTimeInterval(-7*24*3600) }
        case .mood(let m): return vm.entries.filter { $0.mood == m }
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
            .alternatingRowBackgrounds()
        }
    }
}

// MARK: - Entry Card

struct EntryCardView: View {
    let entry: JournalEntry
    let isSelected: Bool

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
                        ForEach(entry.tags.prefix(2), id: \.self) { Text("#\($0)").font(.system(size: 9)).foregroundColor(.accentColor.opacity(0.7)) }
                        if entry.tags.count > 2 { Text("+\(entry.tags.count - 2)").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5)) }
                    }
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear))
    }
}

// MARK: - Detail View

struct DetailView: View {
    @ObservedObject var vm: JournalViewModel
    var body: some View {
        Group {
            if let eid = vm.editingEntryId, let entry = vm.entries.first(where: { $0.id == eid }) {
                EditorView(vm: vm, entry: entry)
            } else if let entry = vm.selectedEntry {
                ReadView(entry: entry, vm: vm)
            } else {
                EmptyDetail()
            }
        }
    }
}

// MARK: - Empty Detail

struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().fill(OmegaTheme.accent.opacity(0.08)).frame(width: 120, height: 120)
                Image(systemName: "book.pages").font(.system(size: 44)).foregroundColor(OmegaTheme.accent.opacity(0.5))
            }
            Text("Select an entry or create a new one").font(.system(size: 18, weight: .medium)).foregroundColor(.secondary)
            Text("⌘N to start writing").font(.system(size: 12)).foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Read View

struct ReadView: View {
    let entry: JournalEntry
    @ObservedObject var vm: JournalViewModel

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
                                .background(Color.accentColor.opacity(0.1)).clipShape(Capsule())
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            ActionButton(icon: entry.isPinned ? "pin.fill" : "pin", color: .orange, active: entry.isPinned) { vm.togglePin(entry) }
            ActionButton(icon: entry.isFavorite ? "star.fill" : "star", color: .yellow, active: entry.isFavorite) { vm.toggleFavorite(entry) }
            ActionButton(icon: "pencil", color: .accentColor, active: false) { vm.startEditing(entry) }
            ActionButton(icon: "trash", color: .red, active: false) { vm.deleteEntry(entry) }
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let icon: String, color: Color, active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium))
                .foregroundColor(active ? color : .secondary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color(nsColor: .controlBackgroundColor) : Color.clear))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: - Editor View

struct EditorView: View {
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry

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
                                .background(Color.accentColor.opacity(0.1)).clipShape(Capsule())
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
            .padding(.horizontal, 40).padding(.vertical, 12).background(Color(nsColor: .controlBackgroundColor))
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
            .background(RoundedRectangle(cornerRadius: 10).fill(sel ? m.color.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(sel ? m.color : Color.clear, lineWidth: 2))
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
                LabeledContent("Total entries") { Text("\(DatabaseManager.shared.entryCount())") }
            }
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 450, height: 200)
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
