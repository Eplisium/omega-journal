import SwiftUI

// MARK: - Content View

struct ContentView: View {
    @StateObject private var vm = JournalViewModel()
    @ObservedObject private var theme = ThemeManager.shared
    @State private var sidebarSelection: SidebarItem? = .all
    @State private var showTemplatePicker = false

    var body: some View {
        ZStack {
            if vm.isZenMode, let entry = vm.editingEntry {
                // Zen mode takes over the whole window — no chrome, just the page.
                EditorView(vm: vm, entry: entry)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                mainSplitView
            }

            if vm.showCommandPalette {
                CommandPaletteView(vm: vm, selection: $sidebarSelection)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.isZenMode)
        .animation(.easeInOut(duration: 0.15), value: vm.showCommandPalette)
        .tint(theme.accentColor)
        .preferredColorScheme(theme.colorScheme)
        .background(theme.backgroundColor)
        .environmentObject(vm)
        .sheet(isPresented: $showTemplatePicker) {
            TemplatePickerView(vm: vm)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newEntry)) { _ in
            vm.createEntry()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFromTemplate)) { _ in
            showTemplatePicker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFromPrompt)) { _ in
            vm.createEntryFromPrompt()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCommandPalette)) { _ in
            vm.showCommandPalette.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleZenMode)) { _ in
            if vm.editingEntryId != nil { vm.isZenMode.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showInsights)) { _ in
            sidebarSelection = .insights
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCalendar)) { _ in
            sidebarSelection = .calendar
        }
        .onReceive(NotificationCenter.default.publisher(for: .importEntries)) { _ in
            ImportExportPanels.showImportPanel(vm: vm)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lockHiddenEntries)) { _ in
            vm.lockHiddenEntries()
        }
    }

    private var mainSplitView: some View {
        NavigationSplitView {
            SidebarView(vm: vm, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
        } content: {
            EntryListView(vm: vm, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            DetailView(vm: vm, selection: $sidebarSelection)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Sidebar Item

enum SidebarItem: Hashable {
    case all
    case favorites
    case thisWeek
    case mood(Mood)
    case insights
    case calendar
    case onThisDay
    case archive
    case hidden
    case trash
    case tag(String)

    var title: String {
        switch self {
        case .all: "All Entries"
        case .favorites: "Favorites"
        case .thisWeek: "This Week"
        case .mood(let m): m.label
        case .insights: "Insights"
        case .calendar: "Calendar"
        case .onThisDay: "On This Day"
        case .archive: "Archive"
        case .hidden: "Hidden"
        case .trash: "Trash"
        case .tag(let t): "#\(t)"
        }
    }

    var icon: String {
        switch self {
        case .all: "tray.full"
        case .favorites: "star"
        case .thisWeek: "calendar.badge.clock"
        case .mood(let m): m.icon
        case .insights: "chart.line.uptrend.xyaxis"
        case .calendar: "calendar"
        case .onThisDay: "clock.arrow.circlepath"
        case .archive: "archivebox"
        case .hidden: "lock.fill"
        case .trash: "trash"
        case .tag: "number"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newEntry = Notification.Name("OmegaJournal.newEntry")
    static let newFromTemplate = Notification.Name("OmegaJournal.newFromTemplate")
    static let newFromPrompt = Notification.Name("OmegaJournal.newFromPrompt")
    static let toggleCommandPalette = Notification.Name("OmegaJournal.toggleCommandPalette")
    static let toggleZenMode = Notification.Name("OmegaJournal.toggleZenMode")
    static let showInsights = Notification.Name("OmegaJournal.showInsights")
    static let showCalendar = Notification.Name("OmegaJournal.showCalendar")
    static let importEntries = Notification.Name("OmegaJournal.importEntries")
    static let focusSearch = Notification.Name("OmegaJournal.focusSearch")
    static let lockHiddenEntries = Notification.Name("OmegaJournal.lockHiddenEntries")
}
