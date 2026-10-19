import SwiftUI
import OmegaJournalCore

// MARK: - Content View

struct ContentView: View {
    @StateObject private var vm = JournalViewModel()
    @ObservedObject private var theme = ThemeManager.shared
    @State private var sidebarSelection: SidebarItem? = .today
    @State private var showTemplatePicker = false
    @StateObject private var onboarding = OnboardingState()
    @SceneStorage("shell.sidebarSelection") private var storedSelection = SidebarItem.today.storageKey
    @State private var didRestoreSelection = false
    @State private var showLegacyImportOffer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if vm.isZenMode, let entry = vm.editingEntry {
                // Zen mode takes over the whole window — no chrome, just the page.
                Self.zenEditor(vm: vm, entry: entry)
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.isZenMode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: vm.showCommandPalette)
        .tint(theme.accentColor)
        .preferredColorScheme(theme.colorScheme)
        .background(theme.backgroundColor)
        .environmentObject(vm)
        .sheet(isPresented: $showTemplatePicker) {
            TemplatePickerView(vm: vm)
        }
        .sheet(isPresented: $onboarding.isPresentingTour) {
            OnboardingTourView(onboarding: onboarding) {
                sidebarSelection = .all
                vm.createEntry()
            }
        }
        .sheet(isPresented: $onboarding.isPresentingWhatsNew) {
            WhatsNewView(onboarding: onboarding)
        }
        .onAppear {
            // ContentView only exists after the launch gate adopted the key,
            // so reading the database here is safe. A sandboxed build with an
            // empty journal first offers to import the earlier version's
            // journal; onboarding waits until that offer is answered.
            if vm.shouldOfferLegacyImport() {
                showLegacyImportOffer = true
            } else {
                onboarding.evaluateOnLaunch(hasEntries: !vm.entries.isEmpty)
            }
            QuitGuard.check = { [weak vm] in vm?.quitDecision() ?? .terminate }
        }
        .alert("Bring over your earlier journal?", isPresented: $showLegacyImportOffer) {
            Button("Choose Folder…") {
                JournalViewModel.markLegacyImportOfferHandled()
                // Let the alert finish dismissing before the open panel runs.
                DispatchQueue.main.async {
                    vm.chooseAndImportLegacyJournal()
                    onboarding.evaluateOnLaunch(hasEntries: !vm.entries.isEmpty)
                }
            }
            Button("Not Now", role: .cancel) {
                JournalViewModel.markLegacyImportOfferHandled()
                onboarding.evaluateOnLaunch(hasEntries: !vm.entries.isEmpty)
            }
        } message: {
            Text("If you used Omega Journal downloaded from GitHub, you can import that journal into this one. You can also do this later in Settings › Data.")
        }
        .modifier(ShellEntryCommands(vm: vm, selection: $sidebarSelection))
        .modifier(ShellLifecycle(vm: vm, selection: $sidebarSelection, showTemplatePicker: $showTemplatePicker,
                                 storedSelection: $storedSelection, didRestore: $didRestoreSelection))
        .modifier(ShellReviewRequests(vm: vm, selection: $sidebarSelection))
    }

    /// Zen-mode editor. Keyed by entry id (as DetailView does) so switching or
    /// creating an entry rebuilds the editor instead of carrying the previous
    /// entry's @State (title/body/tags) into the next one and autosaving it there.
    static func zenEditor(vm: JournalViewModel, entry: JournalEntry) -> some View {
        EditorView(vm: vm, entry: entry)
            .id(entry.id)
    }

    /// ONE split view for every workspace. The window used to swap between a
    /// three-column split (Library) and a two-column one (Today, Calendar,
    /// Insights, On This Day); each swap rebuilt the sidebar column, so a
    /// dragged sidebar width snapped back to 232pt, its scroll jumped to the
    /// top, and the list header moved between the title-bar row and below
    /// it. Now the sidebar column is never rebuilt and only the pane to its
    /// right changes (`Self.workspacePane`).
    private var mainSplitView: some View {
        NavigationSplitView {
            SidebarView(vm: vm, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
        } detail: {
            Self.workspacePane(vm: vm, selection: $sidebarSelection)
                .frame(minWidth: ShellListColumn.paneMinWidth)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// What sits right of the sidebar for the current destination.
    @ViewBuilder
    static func workspacePane(vm: JournalViewModel, selection: Binding<SidebarItem?>) -> some View {
        switch ShellColumns.forWorkspace(usesEntryCollection: (selection.wrappedValue?.workspace ?? .today).usesEntryCollection) {
        case .listAndDetail:
            JournalColumnsView(vm: vm, selection: selection)
        case .page:
            ReflectionWorkspaceView(vm: vm, selection: selection)
        }
    }
}

// MARK: - Journal columns (list | detail)

/// Entry list and entry detail side by side, with a draggable divider. The
/// list width is the user's (persisted), clamped by `ShellListColumn` so the
/// reader/editor keeps the room it was designed for at 940pt.
struct JournalColumnsView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage(ShellListColumn.storageKey) private var storedWidth = ShellListColumn.idealWidth
    /// Live width while dragging; persisted once on release.
    @State private var dragWidth: Double?
    @State private var dragOrigin: Double?

    var body: some View {
        GeometryReader { geo in
            let available = Double(geo.size.width)
            let width = ShellListColumn.width(stored: dragWidth ?? storedWidth, available: available)
            HStack(spacing: 0) {
                EntryListView(vm: vm, selection: $selection)
                    .frame(width: width)
                divider(width: width, available: available)
                    .zIndex(1) // grab area overlaps both columns
                DetailView(vm: vm, selection: $selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func divider(width: Double, available: Double) -> some View {
        Rectangle()
            .fill(theme.secondaryTextColor.opacity(0.18))
            .frame(width: ShellListColumn.dividerWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                // Wider invisible grab area than the 1pt line.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let origin = dragOrigin ?? width
                                dragOrigin = origin
                                dragWidth = ShellListColumn.dragged(from: origin, by: Double(value.translation.width),
                                                                    available: available)
                            }
                            .onEnded { _ in
                                if let dragWidth { storedWidth = dragWidth }
                                dragWidth = nil
                                dragOrigin = nil
                            }
                    )
            }
            .accessibilityElement()
            .accessibilityLabel("Entry list width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: storedWidth = ShellListColumn.clampStored(width + ShellListColumn.step)
                case .decrement: storedWidth = ShellListColumn.clampStored(width - ShellListColumn.step)
                @unknown default: break
                }
            }
    }
}

// MARK: - Sidebar Item

enum SidebarItem: Hashable {
    case today
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
    case smartFolder(String)

    var title: String {
        switch self {
        case .today: "Today"
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
        case .smartFolder: "Smart Folder"
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max"
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
        case .smartFolder: "folder.badge.gearshape"
        }
    }

    /// Stable string for @SceneStorage state restoration.
    var storageKey: String {
        switch self {
        case .today: "today"
        case .all: "all"
        case .favorites: "favorites"
        case .thisWeek: "thisWeek"
        case .mood(let m): "mood:\(m.rawValue)"
        case .insights: "insights"
        case .calendar: "calendar"
        case .onThisDay: "onThisDay"
        case .archive: "archive"
        case .hidden: "hidden"
        case .trash: "trash"
        case .tag(let t): "tag:\(t)"
        case .smartFolder(let id): "smart:\(id)"
        }
    }

    /// Restores a selection. `.hidden` is never restored — a relaunch must
    /// not open straight onto private entries.
    init?(storageKey: String) {
        switch storageKey {
        case "today": self = .today
        case "all": self = .all
        case "favorites": self = .favorites
        case "thisWeek": self = .thisWeek
        case "insights": self = .insights
        case "calendar": self = .calendar
        case "onThisDay": self = .onThisDay
        case "archive": self = .archive
        case "hidden": self = .all
        case "trash": self = .trash
        default:
            if storageKey.hasPrefix("mood:"), let raw = Int(storageKey.dropFirst(5)), let m = Mood(rawValue: raw) {
                self = .mood(m)
            } else if storageKey.hasPrefix("tag:"), storageKey.count > 4 {
                self = .tag(String(storageKey.dropFirst(4)))
            } else if storageKey.hasPrefix("smart:"), storageKey.count > 6 {
                self = .smartFolder(String(storageKey.dropFirst(6)))
            } else {
                return nil
            }
        }
    }

    /// Collection filters stay inside the Journal workspace. Reflective pages
    /// intentionally take over the content area instead of inheriting the list.
    var workspace: JournalWorkspace {
        switch self {
        case .today: .today
        case .calendar: .calendar
        case .insights: .insights
        case .onThisDay: .onThisDay
        case .all, .favorites, .thisWeek, .mood, .archive, .hidden, .trash, .tag, .smartFolder: .journal
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
    static let showToday = Notification.Name("OmegaJournal.showToday")
    static let showJournal = Notification.Name("OmegaJournal.showJournal")
    static let showInsights = Notification.Name("OmegaJournal.showInsights")
    static let showCalendar = Notification.Name("OmegaJournal.showCalendar")
    static let importEntries = Notification.Name("OmegaJournal.importEntries")
    static let focusSearch = Notification.Name("OmegaJournal.focusSearch")
    static let lockHiddenEntries = Notification.Name("OmegaJournal.lockHiddenEntries")
    static let editSelectedEntry = Notification.Name("OmegaJournal.editSelectedEntry")
    static let togglePinSelected = Notification.Name("OmegaJournal.togglePinSelected")
    static let toggleFavoriteSelected = Notification.Name("OmegaJournal.toggleFavoriteSelected")
    static let toggleArchiveSelected = Notification.Name("OmegaJournal.toggleArchiveSelected")
    static let selectNextEntry = Notification.Name("OmegaJournal.selectNextEntry")
    static let selectPreviousEntry = Notification.Name("OmegaJournal.selectPreviousEntry")
    static let findInEntryOrList = Notification.Name("OmegaJournal.findInEntryOrList")
    static let searchAllEntries = Notification.Name("OmegaJournal.searchAllEntries")
    static let showShortcuts = Notification.Name("OmegaJournal.showShortcuts")
    static let showSettings = Notification.Name("OmegaJournal.showSettings")
    static let duplicateSelected = Notification.Name("OmegaJournal.duplicateSelected")
    static let exportSelected = Notification.Name("OmegaJournal.exportSelected")
    static let quitTimeSave = Notification.Name("OmegaJournal.quitTimeSave")
}

// MARK: - Drop import filter

enum ShellImportFilter {
    /// File URLs that look like markdown documents (.md / .markdown).
    static func markdownFiles(in urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL && ["md", "markdown"].contains($0.pathExtension.lowercased()) }
    }
}

// MARK: - Entry keyboard navigation

enum ShellEntryNavigation {
    /// Next/previous id in `ids` relative to `current`; clamps at the ends and
    /// selects the first entry when nothing (or something not listed) is selected.
    static func step(_ delta: Int, from current: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else {
            return delta >= 0 ? ids.first : ids.last
        }
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }
}

// MARK: - Entry command receivers

/// Menu-driven entry commands, kept out of ContentView.body so the main view
/// chain stays cheap for the type checker.
struct ShellEntryCommands: ViewModifier {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let markdown = ShellImportFilter.markdownFiles(in: urls)
                guard !markdown.isEmpty else { return false }
                selection = .all
                vm.importMarkdown(from: markdown)
                return true
            }
            .onReceive(NotificationCenter.default.publisher(for: .editSelectedEntry)) { _ in
                guard selection != .trash, let entry = vm.selectedEntry, !entry.isTrashed else { return }
                vm.startEditing(entry)
            }
            .onReceive(NotificationCenter.default.publisher(for: .togglePinSelected)) { _ in
                if let entry = vm.selectedEntry, !entry.isTrashed { vm.togglePin(entry) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleFavoriteSelected)) { _ in
                if let entry = vm.selectedEntry, !entry.isTrashed { vm.toggleFavorite(entry) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleArchiveSelected)) { _ in
                if let entry = vm.selectedEntry, !entry.isTrashed { vm.toggleArchive(entry) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .duplicateSelected)) { _ in
                if let entry = vm.selectedEntry, !entry.isTrashed { vm.duplicate(entry) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportSelected)) { _ in
                if vm.selectedEntry != nil { ImportExportPanels.exportCurrentEntry(vm: vm) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickCapture)) { _ in
                vm.drainQuickCaptureInbox()
            }
            // Captures made before this window existed (launch gate) are queued.
            .onAppear { vm.drainQuickCaptureInbox() }
            .onReceive(NotificationCenter.default.publisher(for: .findInEntryOrList)) { _ in
                if vm.editingEntryId != nil, NSApp.keyWindow?.firstResponder is NSTextView {
                    let item = NSMenuItem()
                    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                    if NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item) { return }
                }
                focusListSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchAllEntries)) { _ in
                vm.filter = .empty
                focusListSearch(forceLibrary: true)
            }
    }

    /// The search field only exists in the Journal workspace, so switch there
    /// first and focus on the next runloop turn once the field is on screen.
    private func focusListSearch(forceLibrary: Bool = false) {
        if forceLibrary || !(selection?.workspace ?? .today).usesEntryCollection {
            selection = .all
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .focusSearch, object: nil)
        }
    }
}

// MARK: - Navigation / lifecycle receivers

struct ShellLifecycle: ViewModifier {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @Binding var showTemplatePicker: Bool
    @Binding var storedSelection: String
    @Binding var didRestore: Bool

    func body(content: Content) -> some View {
        content
        .onAppear {
            guard !didRestore else { return }
            didRestore = true
            selection = SidebarItem(storageKey: storedSelection) ?? .today
        }
        .onChange(of: selection) { _, next in
            if let next { storedSelection = next.storageKey }
            // A bulk selection is meaningful only within the collection in
            // which it was made. Never carry it into another library/storage
            // destination or a reflective workspace.
            vm.clearBulkSelection()
            guard let next, !next.workspace.usesEntryCollection, vm.isEditing else { return }
            vm.flushPendingSave()
            vm.stopEditing()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newEntry)) { _ in
            selection = .all
            vm.createEntry()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFromTemplate)) { _ in
            selection = .all
            showTemplatePicker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFromPrompt)) { _ in
            selection = .all
            vm.createEntryFromPrompt()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCommandPalette)) { _ in
            vm.showCommandPalette.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleZenMode)) { _ in
            if vm.editingEntryId != nil { vm.isZenMode.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showToday)) { _ in
            selection = .today
        }
        .onReceive(NotificationCenter.default.publisher(for: .showJournal)) { _ in
            selection = .all
        }
        .onReceive(NotificationCenter.default.publisher(for: .showInsights)) { _ in
            selection = .insights
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCalendar)) { _ in
            selection = .calendar
        }
        .onReceive(NotificationCenter.default.publisher(for: .importEntries)) { _ in
            ImportExportPanels.showImportPanel(vm: vm)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lockHiddenEntries)) { _ in
            vm.lockHiddenEntries()
        }

        .onReceive(NotificationCenter.default.publisher(for: .quitTimeSave)) { _ in
            // Quit is in progress and this call runs synchronously — flush
            // regardless of the `isEditing` guard used for workspace switches,
            // otherwise the final keystrokes of an edit session are lost.
            vm.flushPendingSave()
        }
    }
}

// MARK: - Review reminder receiver

/// Tapping a weekly/monthly review notification posts `.reviewRequested`
/// (see `NotificationPresenter`); open Today and save that period's review.
struct ShellReviewRequests: ViewModifier {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .reviewRequested)) { note in
            guard JournalViewModel.reviewPeriod(fromRequest: note.userInfo) != nil else { return }
            selection = .today
            vm.handleReviewRequest(userInfo: note.userInfo)
        }
    }
}
