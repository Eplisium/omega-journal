import SwiftUI
import OmegaJournalCore

// MARK: - Entry List

struct EntryListView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFilters = false
    @State private var showSaveSearch = false
    @State private var savedSearchName = ""
    @State private var bulkTagText = ""
    @State private var showBulkTagField = false
    @State private var showBulkPermanentDeleteConfirmation = false
    @State private var showEmptyTrashConfirmation = false

    private var isHiddenSection: Bool { selection == .hidden }

    /// Entries for the currently selected sidebar item, after the filter bar is applied.
    private var displayed: [JournalEntry] {
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

    private var displayedIDs: [String] { displayed.map(\.id) }

    private var isSearchingCurrentCollection: Bool {
        !vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isTrash: Bool { selection == .trash }

    private var bulkStorage: BulkEntryStorage {
        switch selection {
        case .archive: .archive
        case .hidden: .hidden
        case .trash: .trash
        default: .library
        }
    }

    private var bulkActions: [BulkEntryAction] {
        BulkEntryActions.available(in: bulkStorage)
    }

    /// Grouped sections for the currently displayed set.
    private var sections: [JournalViewModel.EntrySection] {
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

    private var collectionHeader: some View {
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

    private var hiddenBanner: some View {
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

    // MARK: Search bar

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                TextField("Search entries…", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(OmegaTheme.font(.caption))
                    .foregroundColor(theme.titleTextColor)
                    .focused($searchFocused)
                    .onChange(of: vm.searchText) { _, _ in vm.searchTextChanged() }
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                        vm.refreshQuery()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.cardColor.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(searchFocused ? theme.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                    )
            )

            HStack(spacing: 6) {
                Text(displayed.isEmpty ? "No entries" : "\(displayed.count) \(displayed.count == 1 ? "entry" : "entries")")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)

                Spacer()

                Button {
                    withAnimation(reduceMotion ? nil : .default) { showFilters.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease.circle\(vm.filter.isActive ? ".fill" : "")")
                            .font(OmegaTheme.font(.meta))
                        if vm.filter.activeCount > 0 {
                            Text("\(vm.filter.activeCount)")
                                .font(OmegaTheme.font(.meta, .semibold, design: .rounded))
                        }
                    }
                    .foregroundColor(vm.filter.isActive ? theme.accentColor : theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .omegaTooltip("Filters")
                .accessibilityLabel(vm.filter.isActive ? "Filters, \(vm.filter.activeCount) active" : "Filters")

                if !vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty || vm.filter.isActive {
                    Button {
                        savedSearchName = vm.searchText.trimmingCharacters(in: .whitespaces)
                        showSaveSearch = true
                    } label: {
                        Image(systemName: "bookmark")
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .omegaTooltip("Save this search")
                    .accessibilityLabel("Save this search")
                }

                sortSegmentedControl

                Button {
                    withAnimation(reduceMotion ? nil : .default) {
                        vm.isBulkSelecting.toggle()
                        if !vm.isBulkSelecting { vm.clearBulkSelection() }
                    }
                } label: {
                    Image(systemName: vm.isBulkSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(vm.isBulkSelecting ? theme.accentColor : theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .omegaTooltip("Select multiple")
                .accessibilityLabel("Select multiple entries")
                .accessibilityAddTraits(vm.isBulkSelecting ? [.isSelected] : [])

                if biometricAuth.isAuthenticated && vm.hiddenCount > 0 {
                    Button {
                        vm.lockHiddenEntries()
                    } label: {
                        Image(systemName: "lock.fill")
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .omegaTooltip("Lock hidden entries (⌘L)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: Segmented sort (Latest | Oldest | A–Z)

    private var sortSegmentedControl: some View {
        HStack(spacing: 2) {
            segment("Latest", active: vm.sortOrder == .dateDesc) { vm.setSortOrder(.dateDesc) }
            segment("Oldest", active: vm.sortOrder == .dateAsc) { vm.setSortOrder(.dateAsc) }
            segment("A–Z", active: vm.sortOrder == .titleAsc) { vm.setSortOrder(.titleAsc) }
        }
        .padding(2)
        .background(
            Capsule().fill(theme.cardColor.opacity(0.7))
        )
        .overlay(Capsule().strokeBorder(theme.titleTextColor.opacity(0.08), lineWidth: 1))
    }

    private func segment(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(OmegaTheme.font(.meta, active ? .semibold : .regular))
                .foregroundColor(active ? theme.onAccentColor : theme.secondaryTextColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(active ? theme.accentColor : .clear)
                )
        }
        .buttonStyle(.plain)
        .omegaTooltip(active ? "Sorted by \(label)" : "Sort by \(label)")
    }

    // MARK: Bulk action bar

    private var bulkActionBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("\(vm.bulkSelection.count) selected")
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.titleTextColor)

                Button("All") {
                    vm.bulkSelection = Set(displayed.map(\.id))
                }
                .buttonStyle(.plain)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.accentColor)

                Button("None") { vm.bulkSelection.removeAll() }
                    .buttonStyle(.plain)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)

                Spacer()

                ForEach(bulkActions, id: \.self) { action in
                    bulkActionButton(action)
                }
            }

            if showBulkTagField {
                HStack(spacing: 6) {
                    TextField("Tag name…", text: $bulkTagText)
                        .textFieldStyle(.plain)
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.titleTextColor)
                        .onSubmit {
                            vm.bulkAddTag(bulkTagText)
                            bulkTagText = ""
                            showBulkTagField = false
                        }
                    Button("Add") {
                        vm.bulkAddTag(bulkTagText)
                        bulkTagText = ""
                        showBulkTagField = false
                    }
                    .buttonStyle(.plain)
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.backgroundColor.opacity(0.6)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.accentColor.opacity(0.1))
    }

    @ViewBuilder
    private func bulkActionButton(_ action: BulkEntryAction) -> some View {
        switch action {
        case .favorite:
            bulkButton("star", "Favorite") { vm.bulkFavorite() }
        case .tag:
            bulkButton("number", "Tag") { withAnimation(reduceMotion ? nil : .default) { showBulkTagField.toggle() } }
        case .archive:
            bulkButton("archivebox", "Archive") { vm.bulkArchive() }
        case .unarchive:
            bulkButton("tray.and.arrow.up", "Unarchive") { vm.bulkUnarchive() }
        case .moveToTrash:
            bulkButton("trash", "Move to Trash", destructive: true) { vm.bulkMoveToTrash() }
        case .restoreFromTrash:
            bulkButton("arrow.uturn.backward", "Restore") { vm.bulkRestoreFromTrash() }
        case .deleteForever:
            bulkButton("trash.slash", "Delete Forever", destructive: true) {
                showBulkPermanentDeleteConfirmation = true
            }
        }
    }

    private func bulkButton(_ icon: String, _ help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(destructive ? .red : theme.accentColor)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(vm.bulkSelection.isEmpty)
        .opacity(vm.bulkSelection.isEmpty ? 0.4 : 1)
        .omegaTooltip(help, accent: destructive ? .red : nil)
    }

    private var trashBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(OmegaTheme.font(.meta))
            Text("Entries are deleted forever after \(DatabaseManager.trashRetentionDays) days.")
                .font(OmegaTheme.font(.meta))
            Spacer()
            Button("Empty Trash") { showEmptyTrashConfirmation = true }
                .buttonStyle(.plain)
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(.red)
        }
        .foregroundColor(theme.secondaryTextColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08))
    }

    // MARK: List

    @ViewBuilder
    private var listBody: some View {
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
    private func moveSelection(_ delta: Int) {
        guard !vm.isBulkSelecting, vm.editingEntryId == nil else { return }
        let ids = sections.flatMap { $0.entries.map(\.id) }
        guard let next = ShellEntryNavigation.step(delta, from: vm.selectedEntryId, in: ids) else { return }
        vm.selectedEntryId = next
    }

    private func deleteSelected() -> KeyPress.Result {
        guard !isTrash, !vm.isBulkSelecting, vm.editingEntryId == nil, let entry = vm.selectedEntry else { return .ignored }
        vm.deleteEntry(entry)
        return .handled
    }

    private func sectionHeader(_ section: JournalViewModel.EntrySection) -> some View {
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

    private var emptyState: some View {
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

    private var emptyTitle: String {
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

    private var emptySubtitle: String {
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

// MARK: - Entry Row

private struct EntryRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    let isTrash: Bool

    // Selection state is read straight from the view model instead of being
    // passed in as values. Rows live inside a LazyVStack, where stale passed-in
    // copies can survive a parent re-render — the reported symptom was the bulk
    // toolbar active while rows still rendered (and tapped) as if it were off.
    // @ObservedObject re-renders the row on every publish, so these stay live.
    private var isSelected: Bool { vm.selectedEntryId == entry.id }
    private var isBulkSelected: Bool { vm.bulkSelection.contains(entry.id) }
    private var isBulkSelecting: Bool { vm.isBulkSelecting }

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared
    @State private var hover = false
    @State private var showPermanentDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 9) {
            if isBulkSelecting {
                Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                    .font(OmegaTheme.font(.bodyLarge))
                    .foregroundColor(isBulkSelected ? theme.accentColor : theme.secondaryTextColor.opacity(0.5))
            }

            Circle()
                .fill(entry.mood.color)
                .frame(width: 8, height: 8)
                .opacity(isContentLocked ? 0.35 : 0.95)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if entry.isPinned {
                        Image(systemName: "pin.fill").font(OmegaTheme.font(.meta)).foregroundColor(theme.accentColor)
                    }
                    if entry.isHidden {
                        Image(systemName: isContentLocked ? "lock.fill" : "lock.open")
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.accentColor.opacity(isContentLocked ? 0.9 : 0.7))
                    }
                    Text(entry.displayTitle)
                        .font(OmegaTheme.font(.body, .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor.opacity(isContentLocked ? 0.72 : 1))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if entry.isFavorite {
                        Image(systemName: "star.fill").font(OmegaTheme.font(.meta)).foregroundColor(.yellow)
                    }
                    if !entry.attachments.isEmpty {
                        Image(systemName: "paperclip").font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
                    }
                }

                if isContentLocked {
                    Text("Hidden · unlock to read")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor.opacity(0.55))
                        .lineLimit(1)
                } else {
                    Text(entry.preview)
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    Text(entry.mood.emoji).font(OmegaTheme.font(.meta))
                    Text(isTrash ? trashLabel : entry.createdAt.formatted(date: .abbreviated, time: .shortened).replacingOccurrences(of: " AM", with: " AM"))
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor.opacity(0.8))
                    if entry.wordCount > 0 {
                        Text("· \(entry.wordCount)w")
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                    }
                    Spacer(minLength: 2)
                    if !isContentLocked {
                        ForEach(entry.tags.prefix(2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(OmegaTheme.font(.meta, .medium))
                                .foregroundColor(theme.accentColor.opacity(0.9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                        }
                        if entry.tags.count > 2 {
                            Text("+\(entry.tags.count - 2)")
                                .font(OmegaTheme.font(.meta))
                                .foregroundColor(theme.secondaryTextColor.opacity(0.7))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(rowBackground)
        )
        .hoverGlow(radius: 11, glow: 0.26, border: 0.4, lift: false)
        .opacity(isContentLocked ? 0.82 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isBulkSelecting ? "Double tap to change its bulk selection" : "Double tap to open this entry")
        .onHover { hover = $0 }
        .onTapGesture(count: 2) {
            if !isTrash && !isBulkSelecting { vm.startEditing(entry) }
        }
        .onTapGesture {
            if isBulkSelecting {
                vm.toggleBulkSelection(entry.id)
            } else {
                // Clicking never deselects: the selection stays put so the
                // reader pane doesn't vanish on an accidental re-click.
                vm.select(entry)
            }
        }
        .contextMenu { contextMenu }
        .confirmationDialog(
            "Delete this entry forever?",
            isPresented: $showPermanentDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) {
                vm.deleteForever(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The entry and its attachments will be permanently removed.")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
    }

    private var trashLabel: String {
        let remaining = DatabaseManager.trashRetentionDays - entry.daysInTrash
        return remaining <= 0 ? "Deleting soon" : "\(remaining)d left"
    }

    private var isContentLocked: Bool {
        entry.isHidden && !biometricAuth.isAuthenticated
    }

    private var accessibilityLabel: String {
        let privacy = isContentLocked ? "Hidden entry" : entry.displayTitle
        let metadata = "\(entry.mood.label), \(entry.createdAt.formatted(date: .abbreviated, time: .omitted))"
        return "\(privacy), \(metadata)"
    }

    private var rowBackground: Color {
        if isBulkSelected { return theme.accentColor.opacity(0.14) }
        if isSelected { return theme.accentColor.opacity(0.12) }
        if isContentLocked { return theme.cardColor.opacity(hover ? 0.28 : 0.18) }
        if hover { return theme.cardColor.opacity(0.75) }
        return theme.cardColor.opacity(0.4)
    }

    private var rowBorder: Color {
        if isSelected { return theme.accentColor.opacity(0.45) }
        if isContentLocked { return theme.accentColor.opacity(0.22) }
        return theme.titleTextColor.opacity(0.06)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if isTrash {
            Button { vm.restoreFromTrash(entry) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Divider()
            Button(role: .destructive) { showPermanentDeleteConfirmation = true } label: {
                Label("Delete Forever", systemImage: "trash.slash")
            }
        } else {
            Button { vm.startEditing(entry) } label: { Label("Edit", systemImage: "pencil") }
            Button { vm.togglePin(entry) } label: {
                Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
            Button { vm.toggleFavorite(entry) } label: {
                Label(entry.isFavorite ? "Unfavorite" : "Favorite", systemImage: entry.isFavorite ? "star.slash" : "star")
            }
            Button { vm.duplicate(entry) } label: { Label("Duplicate", systemImage: "doc.on.doc") }
            Divider()
            Menu("Set Mood") {
                ForEach(Mood.allCases) { mood in
                    Button { vm.setMood(mood, for: entry) } label: {
                        Label("\(mood.emoji)  \(mood.label)", systemImage: vm.selectedEntry?.mood == mood ? "checkmark" : "")
                    }
                }
            }
            Button { vm.copyAsMarkdown(entry) } label: { Label("Copy as Markdown", systemImage: "doc.on.clipboard") }
            Divider()
            Button { vm.toggleHidden(entry) } label: {
                Label(entry.isHidden ? "Unhide" : "Hide", systemImage: entry.isHidden ? "lock.open" : "lock")
            }
            Button { vm.toggleArchive(entry) } label: {
                Label(entry.isArchived ? "Unarchive" : "Archive", systemImage: entry.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            Button(role: .destructive) { vm.deleteEntry(entry) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }
}

// MARK: - Filter Bar

private struct FilterBar: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FILTERS")
                    .font(OmegaTheme.font(.meta, .semibold))
                    .tracking(0.7)
                    .foregroundColor(theme.secondaryTextColor)
                Spacer()
                if vm.filter.isActive {
                    Button("Reset") { vm.filter = .empty }
                        .buttonStyle(.plain)
                        .font(OmegaTheme.font(.meta, .medium))
                        .foregroundColor(theme.accentColor)
                }
            }

            // Mood chips
            HStack(spacing: 4) {
                ForEach(Mood.allCases) { mood in
                    let on = vm.filter.moods.contains(mood)
                    Button {
                        if on { vm.filter.moods.remove(mood) } else { vm.filter.moods.insert(mood) }
                    } label: {
                        Text(mood.emoji)
                            .font(OmegaTheme.font(.caption))
                            .frame(width: 24, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(on ? mood.color.opacity(0.28) : theme.cardColor.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(on ? mood.color.opacity(0.7) : .clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .omegaTooltip(mood.label)
                }

                Spacer()

                Picker("", selection: $vm.filter.dateRange) {
                    ForEach(EntryFilter.DateRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .labelsHidden()
                .font(OmegaTheme.font(.meta))
                .frame(width: 118)
            }

            // Toggles
            HStack(spacing: 5) {
                toggle("Favorites", "star.fill", $vm.filter.favoritesOnly)
                toggle("Pinned", "pin.fill", $vm.filter.pinnedOnly)
                toggle("Files", "paperclip", $vm.filter.withAttachmentsOnly)
                Spacer()
                Text("Min words")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                Stepper("", value: $vm.filter.minWords, in: 0...2000, step: 50)
                    .labelsHidden()
                Text("\(vm.filter.minWords)")
                    .font(OmegaTheme.font(.meta, design: .rounded))
                    .foregroundColor(theme.bodyTextColor)
                    .frame(width: 26, alignment: .leading)
            }

            // Tag chips
            if !vm.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(vm.allTags.prefix(14), id: \.tag) { item in
                            let on = vm.filter.tags.contains(item.tag)
                            Button {
                                if on { vm.filter.tags.remove(item.tag) } else { vm.filter.tags.insert(item.tag) }
                            } label: {
                                Text("#\(item.tag)")
                                    .font(OmegaTheme.font(.meta, on ? .semibold : .regular))
                                    .foregroundColor(on ? theme.accentColor : theme.secondaryTextColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        Capsule().fill(on ? theme.accentColor.opacity(0.2) : theme.cardColor.opacity(0.5))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.cardColor.opacity(0.35))
    }

    private func toggle(_ label: String, _ icon: String, _ binding: Binding<Bool>) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(OmegaTheme.font(.meta))
                Text(label).font(OmegaTheme.font(.meta, binding.wrappedValue ? .semibold : .regular))
            }
            .foregroundColor(binding.wrappedValue ? theme.accentColor : theme.secondaryTextColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(binding.wrappedValue ? theme.accentColor.opacity(0.18) : theme.cardColor.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }
}
