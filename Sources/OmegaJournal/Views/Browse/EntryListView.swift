import SwiftUI
import AppKit
import OmegaJournalCore

// MARK: - Entry List

struct EntryListView: View {
    @Bindable var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    var theme = ThemeManager.shared
    var biometricAuth = BiometricAuth.shared

    @FocusState var searchFocused: Bool
    @FocusState var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var showFilters = false
    @AppStorage(ListDensity.storageKey) var densityRaw = ListDensity.comfortable.rawValue
    @State var showSaveSearch = false
    @State var savedSearchName = ""
    @State var bulkTagText = ""
    @State var showBulkTagField = false
    @State var showBulkPermanentDeleteConfirmation = false
    @State var showEmptyTrashConfirmation = false

    /// Always the sidebar destination. The notebook scope is shown separately
    /// (scope pill + subtitle) — it used to replace "All Entries" only, so a
    /// notebook looked like a destination there and was invisible elsewhere.
    var collectionTitle: String {
        if case .smartFolder(let id) = selection { return vm.smartFolder(id: id)?.name ?? "Smart Folder" }
        return selection?.title ?? "All Entries"
    }

    var collectionSubtitle: String {
        ShellHeaderText.subtitle(isSearching: isSearchingCurrentCollection,
                                 filterCount: vm.filter.activeCount,
                                 notebookName: vm.activeJournal?.name,
                                 scopePillVisible: vm.activeJournal != nil)
    }

    /// How a no-results state may widen the search for this destination.
    static func recoveryContext(for selection: SidebarItem?) -> (isLibraryRoot: Bool, canWidenToLibrary: Bool) {
        switch selection {
        case .all, nil: (true, true)
        case .favorites, .thisWeek, .mood, .tag, .smartFolder: (false, true)
        case .archive, .hidden, .trash, .today, .calendar, .insights, .onThisDay: (false, false)
        }
    }

    var recoveryState: ShellListRecovery.EmptyState? {
        let context = Self.recoveryContext(for: selection)
        return ShellListRecovery.emptyState(query: vm.searchText, filterCount: vm.filter.activeCount,
                                            isLibraryRoot: context.isLibraryRoot,
                                            canWidenToLibrary: context.canWidenToLibrary,
                                            notebookName: vm.activeJournal?.name)
    }

    func clearSearch() {
        // Only touch the field editor when it belongs to the search field.
        let editor = searchFocused ? NSApp.keyWindow?.firstResponder as? NSTextView : nil
        Self.clearSearchText(in: vm, fieldEditor: editor)
    }

    /// Clears the search box and its results.
    ///
    /// The field editor is settled FIRST: while it holds marked (still
    /// composing) text — a dead key such as ⌥E, an input-method candidate,
    /// press-and-hold accents — AppKit keeps showing it and ignores the
    /// programmatic "" from SwiftUI. "Clear search and filters" then cleared
    /// the filters and the model but left "query´" in the box (reproduced
    /// live), and the next keystroke committed the old query again.
    static func clearSearchText(in vm: JournalViewModel, fieldEditor: NSTextView?) {
        SearchFieldComposition.clear(fieldEditor)
        vm.searchDebounce?.cancel()
        vm.searchText = ""
        vm.refreshQuery()
    }

    func perform(_ action: ShellListRecovery.Action) {
        switch action {
        case .clearAll:
            clearSearch()
            vm.filter = .empty
        case .clearSearch: clearSearch()
        case .clearFilters: vm.filter = .empty
        case .searchAllEntries:
            // Keeps the query; All Entries reads the same library results.
            selection = .all
            vm.selectedEntryId = nil
        case .showAllNotebooks: vm.setActiveJournal(nil)
        }
    }

    var isHiddenSection: Bool { selection == .hidden }

    /// Entries for the currently selected sidebar item, after the filter bar is applied.
    var displayed: [JournalEntry] {
        let base: [JournalEntry]
        switch selection {
        case .favorites: base = vm.libraryEntries.filter(\.isFavorite)
        case .thisWeek:
            base = vm.libraryEntries.filter { JournalViewModel.isInThisWeekWindow($0.createdAt) }
        case .mood(let m): base = vm.libraryEntries.filter { $0.mood == m }
        case .tag(let t): base = EntryFilter.entries(vm.libraryEntries, taggedWith: t, hiddenLocked: vm.hiddenLocked)
        case .smartFolder(let id):
            base = vm.smartFolder(id: id).map { vm.smartFolderEntries($0, from: vm.libraryEntries) } ?? []
        // Same privacy-scoped source as the sidebar badge and Today/On This Day surfaces.
        case .onThisDay: base = vm.reflectiveOnThisDay
        case .archive: base = vm.entriesMatchingCurrentSearch(in: vm.archivedEntries)
        case .hidden: base = vm.entriesMatchingCurrentSearch(in: vm.hiddenEntries)
        case .trash: base = vm.entriesMatchingCurrentSearch(in: vm.trashedEntries)
        default: base = vm.libraryEntries
        }
        guard vm.filter.isActive else { return base }
        let locked = vm.hiddenLocked
        return base.filter { vm.filter.matches($0, hiddenLocked: locked) }
    }

    var displayedIDs: [String] { displayed.map(\.id) }

    var isSearchingCurrentCollection: Bool {
        !vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isTrash: Bool { selection == .trash }

    var bulkStorage: BulkEntryStorage {
        switch selection {
        case .archive: .archive
        case .hidden: .hidden
        case .trash: .trash
        default: .library
        }
    }

    var bulkActions: [BulkEntryAction] {
        BulkEntryActions.available(in: bulkStorage)
    }

    /// Grouped sections for the currently displayed set.
    var sections: [JournalViewModel.EntrySection] {
        // Pinned entries always lead. The main library gets date sections for
        // chronological sorts; collections stay one continuous list.
        let isLibrary = selection == .all || selection == nil
        return vm.sections(for: displayed, fallbackTitle: collectionTitle,
                           groupByDate: isLibrary && vm.groupsByDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            collectionHeader
            if isHiddenSection {
                hiddenBanner
            }
            searchBar
            if showFilters {
                FilterBar(vm: vm).transition(.move(edge: .top).combined(with: .opacity))
            } else {
                activeFilterChips
            }
            if vm.isBulkSelecting { bulkActionBar.transition(.move(edge: .top).combined(with: .opacity)) }
            if isTrash && !vm.trashedEntries.isEmpty { trashBanner }
            Divider().opacity(0.25)
            listBody
                // Search syntax helpers float over the top of the list while
                // the field has focus. Inserting them into the column pushed
                // every row down the moment the field was clicked.
                .overlay(alignment: .top) {
                    if searchFocused {
                        SearchOperatorBar(vm: vm, floating: true)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: searchFocused)
        }
        .background(theme.backgroundColor)
        .alert("Save Search", isPresented: $showSaveSearch) {
            TextField("Name", text: $savedSearchName)
            Button("Save") {
                vm.saveCurrentSearch(name: savedSearchName)
                vm.loadOrganizationState()
                vm.refreshOrganization()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current search text and first tag or mood filter to the sidebar.")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showFilters)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: vm.isBulkSelecting)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: biometricAuth.isAuthenticated)
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectNextEntry)) { _ in moveSelection(1) }
        .onReceive(NotificationCenter.default.publisher(for: .selectPreviousEntry)) { _ in moveSelection(-1) }
        .dropDestination(for: URL.self) { urls, _ in
            let markdown = ShellImportFilter.markdownFiles(in: urls)
            guard !markdown.isEmpty else { return false }
            vm.importMarkdown(from: markdown)
            return true
        }
        .onChange(of: displayedIDs) { _, ids in
            vm.retainBulkSelection(in: ids)
        }
        .confirmationDialog(
            "Delete \(vm.bulkSelection.count) \(vm.bulkSelection.count == 1 ? "entry" : "entries") forever?",
            isPresented: $showBulkPermanentDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) {
                vm.bulkDeleteForever()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The selected entries and their attachments will be permanently removed.")
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $showEmptyTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(vm.trashedEntries.count) \(vm.trashedEntries.count == 1 ? "entry" : "entries") Forever", role: .destructive) {
                vm.emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every entry currently in Trash, including attachments.")
        }
    }

    // MARK: Collection header

    var collectionHeader: some View {
        // Subtitle spans the full column under the title row, so the notebook
        // pill and count only compete with the (short) title — beside the
        // pill the subtitle was truncated to "Search results · 1 fi…".
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Text(collectionTitle)
                    .font(OmegaTheme.font(.heading, .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let journal = vm.activeJournal { notebookScopePill(journal) }
                Text("\(displayed.count)")
                    .font(OmegaTheme.font(.meta, .semibold, design: .rounded))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                    .accessibilityLabel("\(displayed.count) entries")
            }
            Text(collectionSubtitle)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// The notebook scope, drawn as a removable pill in the notebook's color so
    /// it reads as "what this list is limited to", not as another destination.
    func notebookScopePill(_ journal: Journal) -> some View {
        let color = TagColors.rgb(hex: journal.colorHex).map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? theme.secondaryTextColor
        return Button {
            vm.setActiveJournal(nil)
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(journal.name).lineLimit(1).truncationMode(.tail)
                Image(systemName: "xmark").font(OmegaTheme.font(.meta, .bold))
            }
            .font(OmegaTheme.font(.meta, .medium))
            .foregroundColor(theme.bodyTextColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(maxWidth: 120)
            .background(Capsule().strokeBorder(color.opacity(0.7), lineWidth: 1))
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .omegaTooltip("Showing only \(journal.name) — click to show all notebooks")
        .accessibilityLabel("Notebook scope: \(journal.name)")
        .accessibilityHint("Shows entries from all notebooks")
    }

    // MARK: Hidden Banner

    var hiddenBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: biometricAuth.isAuthenticated ? "lock.open.fill" : "lock.fill")
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.accentColor)
            Text(biometricAuth.isAuthenticated
                 ? "Hidden content is visible — lock if someone walks by."
                 : "Content is hidden — authenticate to reveal.")
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
            Spacer()
            if biometricAuth.isAuthenticated {
                Button {
                    vm.lockHiddenEntries()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(OmegaTheme.font(.meta))
                        Text("Lock")
                            .font(OmegaTheme.font(.meta, .semibold))
                    }
                    .foregroundColor(theme.onAccentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .omegaTooltip("Lock hidden entries (⌘L)")
            } else {
                Button {
                    Task { _ = await biometricAuth.authenticate() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: biometricAuth.biometricType == "Touch ID" ? "touchid" : "lock.open.fill")
                            .font(OmegaTheme.font(.meta))
                        Text("Unlock")
                            .font(OmegaTheme.font(.meta, .semibold))
                    }
                    .foregroundColor(theme.onAccentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundColor(theme.secondaryTextColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.accentColor.opacity(0.08))
    }

    // MARK: List

    @ViewBuilder
    var listBody: some View {
        if displayed.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                EntryRow(
                                    vm: vm,
                                    entry: entry,
                                    isTrash: isTrash
                                )
                            }
                        } header: {
                            if sections.count > 1 || section.isPinned {
                                sectionHeader(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.return) {
                guard !isTrash, let entry = vm.selectedEntry else { return .ignored }
                vm.startEditing(entry)
                return .handled
            }
            .onKeyPress(.delete) { deleteSelected() }
            .onKeyPress(.deleteForward) { deleteSelected() }
        }
    }

    /// Moves selection through the visible (section-ordered) rows.
    func moveSelection(_ delta: Int) {
        guard !vm.isBulkSelecting, vm.editingEntryId == nil else { return }
        let ids = sections.flatMap { $0.entries.map(\.id) }
        guard let next = ShellEntryNavigation.step(delta, from: vm.selectedEntryId, in: ids) else { return }
        vm.selectedEntryId = next
    }

    func deleteSelected() -> KeyPress.Result {
        guard !isTrash, !vm.isBulkSelecting, vm.editingEntryId == nil, let entry = vm.selectedEntry else { return .ignored }
        vm.deleteEntry(entry)
        return .handled
    }

    func sectionHeader(_ section: JournalViewModel.EntrySection) -> some View {
        HStack(spacing: 5) {
            if section.isPinned {
                Image(systemName: "pin.fill")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.accentColor)
            }
            Text(section.title.uppercased())
                .font(OmegaTheme.font(.meta, .semibold))
                .tracking(0.7)
                .foregroundColor(theme.secondaryTextColor)
            Text("\(section.entries.count)")
                .font(OmegaTheme.font(.meta, design: .rounded))
                .foregroundColor(theme.secondaryTextColor.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(theme.backgroundColor.opacity(0.96))
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: vm.searchText.isEmpty ? (selection?.icon ?? "book.closed") : "magnifyingglass")
                .font(OmegaTheme.font(.display, .light))
                .foregroundColor(theme.secondaryTextColor.opacity(0.4))
            VStack(spacing: 4) {
                Text(emptyTitle)
                    .font(OmegaTheme.font(.body, .medium))
                    .foregroundColor(theme.bodyTextColor)
                Text(emptySubtitle)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
            if let recovery = recoveryState {
                // Every way out of a no-results list, primary action first.
                VStack(spacing: 6) {
                    ForEach(Array(recovery.actions.enumerated()), id: \.element) { index, action in
                        recoveryButton(action, primary: index == 0)
                    }
                }
            } else if !isTrash && selection != .archive {
                Button {
                    vm.createEntry()
                } label: {
                    Text("Write your first entry")
                        .font(OmegaTheme.font(.meta, .medium))
                        .foregroundColor(theme.onAccentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    func recoveryButton(_ action: ShellListRecovery.Action, primary: Bool) -> some View {
        Button { perform(action) } label: {
            Text(action.title)
                .font(OmegaTheme.font(.meta, .medium))
                .foregroundColor(primary ? theme.onAccentColor : theme.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, primary ? 6 : 2)
                .background(Capsule().fill(primary ? theme.accentColor : .clear))
        }
        .buttonStyle(.plain)
    }

    var emptyTitle: String {
        if let recovery = recoveryState { return recovery.title }
        switch selection {
        case .trash: return "Trash is empty"
        case .archive: return "Nothing archived"
        case .hidden: return "No hidden entries"
        case .favorites: return "No favorites yet"
        case .onThisDay: return "Nothing from this day"
        default: return "No entries yet"
        }
    }

    var emptySubtitle: String {
        if let recovery = recoveryState { return recovery.subtitle }
        switch selection {
        case .trash: return "Deleted entries appear here for \(DatabaseManager.trashRetentionDays) days."
        case .archive: return "Archived entries are hidden from your main list."
        case .hidden: return "Hide entries from the context menu or read view toolbar."
        case .favorites: return "Star an entry to keep it close."
        default: return "Start writing — your thoughts belong somewhere."
        }
    }
}

/// Settles an in-progress text composition in a field editor.
@MainActor
enum SearchFieldComposition {
    /// Drops marked (uncommitted) text and empties the field editor, so the
    /// box shows the cleared value immediately. SwiftUI's own "" does not
    /// reach a field editor that was composing (seen live: after dropping
    /// only the marked run, the box still read "zzqq" while the model was
    /// empty). Returns whether there was marked text.
    @discardableResult
    static func clear(_ editor: NSTextView?) -> Bool {
        guard let editor else { return false }
        let hadMarkedText = editor.hasMarkedText()
        if hadMarkedText {
            // Resets the input method / dead-key state, so the next keystroke
            // doesn't complete the old composition.
            editor.inputContext?.discardMarkedText()
            if editor.hasMarkedText() { editor.unmarkText() }
        }
        if !editor.string.isEmpty { editor.string = "" }
        return hadMarkedText
    }
}
