import SwiftUI
import OmegaJournalCore

// MARK: - Entry List

struct EntryListView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @ObservedObject var theme = ThemeManager.shared
    @ObservedObject var biometricAuth = BiometricAuth.shared

    @FocusState var searchFocused: Bool
    @FocusState var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var showFilters = false
    @State var showSaveSearch = false
    @State var savedSearchName = ""
    @State var bulkTagText = ""
    @State var showBulkTagField = false
    @State var showBulkPermanentDeleteConfirmation = false
    @State var showEmptyTrashConfirmation = false

    var isHiddenSection: Bool { selection == .hidden }

    /// Entries for the currently selected sidebar item, after the filter bar is applied.
    var displayed: [JournalEntry] {
        let base: [JournalEntry]
        switch selection {
        case .favorites: base = vm.libraryEntries.filter(\.isFavorite)
        case .thisWeek:
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            base = vm.libraryEntries.filter { $0.createdAt >= cutoff }
        case .mood(let m): base = vm.libraryEntries.filter { $0.mood == m }
        case .tag(let t): base = vm.libraryEntries.filter { $0.tags.contains(t) }
        case .onThisDay: base = vm.onThisDay
        case .archive: base = vm.entriesMatchingCurrentSearch(in: vm.archivedEntries)
        case .hidden: base = vm.entriesMatchingCurrentSearch(in: vm.hiddenEntries)
        case .trash: base = vm.entriesMatchingCurrentSearch(in: vm.trashedEntries)
        default: base = vm.libraryEntries
        }
        return vm.filter.isActive ? base.filter(vm.filter.matches) : base
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
        guard selection == .all || selection == nil else {
            // Pinned entries always lead, in every collection view.
            let pinned = displayed.filter(\.isPinned)
            let rest = displayed.filter { !$0.isPinned }
            var result: [JournalViewModel.EntrySection] = []
            if !pinned.isEmpty { result.append(.init(title: "Pinned", entries: pinned)) }
            if !rest.isEmpty { result.append(.init(title: selection?.title ?? "Entries", entries: rest)) }
            return displayed.isEmpty ? [] : result
        }
        let ids = Set(displayed.map(\.id))
        return vm.groupedEntries
            .map { JournalViewModel.EntrySection(title: $0.title, entries: $0.entries.filter { ids.contains($0.id) }) }
            .filter { !$0.entries.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            collectionHeader
            if isHiddenSection {
                hiddenBanner
            }
            searchBar
            if showFilters { FilterBar(vm: vm).transition(.move(edge: .top).combined(with: .opacity)) }
            if vm.isBulkSelecting { bulkActionBar.transition(.move(edge: .top).combined(with: .opacity)) }
            if isTrash && !vm.trashedEntries.isEmpty { trashBanner }
            Divider().opacity(0.25)
            listBody
        }
        .background(theme.backgroundColor)
        .alert("Save Search", isPresented: $showSaveSearch) {
            TextField("Name", text: $savedSearchName)
            Button("Save") { vm.saveCurrentSearch(name: savedSearchName) }
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selection?.title ?? "All Entries")
                    .font(OmegaTheme.font(.heading, .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                Text(isSearchingCurrentCollection
                     ? "Search results in \(selection?.title ?? "your Journal")"
                     : "Your private writing library")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer(minLength: 8)
            Text("\(displayed.count)")
                .font(OmegaTheme.font(.meta, .semibold, design: .rounded))
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                .accessibilityLabel("\(displayed.count) entries")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
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
                            if sections.count > 1 || section.title == "Pinned" {
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
            if section.title == "Pinned" {
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
            if vm.filter.isActive {
                Button("Clear filters") { vm.filter = .empty }
                    .buttonStyle(.plain)
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.accentColor)
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

    var emptyTitle: String {
        if !vm.searchText.isEmpty { return "No matches" }
        if vm.filter.isActive { return "No entries match your filters" }
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
        if !vm.searchText.isEmpty { return "Try a different search term." }
        if vm.filter.isActive { return "Loosen the filters to see more." }
        switch selection {
        case .trash: return "Deleted entries appear here for \(DatabaseManager.trashRetentionDays) days."
        case .archive: return "Archived entries are hidden from your main list."
        case .hidden: return "Hide entries from the context menu or read view toolbar."
        case .favorites: return "Star an entry to keep it close."
        default: return "Start writing — your thoughts belong somewhere."
        }
    }
}
