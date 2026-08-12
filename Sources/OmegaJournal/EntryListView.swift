import SwiftUI

// MARK: - Entry List

struct EntryListView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared

    @FocusState private var searchFocused: Bool
    @State private var showFilters = false
    @State private var bulkTagText = ""
    @State private var showBulkTagField = false

    private var isHiddenSection: Bool { selection == .hidden }

    /// Entries for the currently selected sidebar item, after the filter bar is applied.
    private var displayed: [JournalEntry] {
        let base: [JournalEntry]
        switch selection {
        case .favorites: base = vm.entries.filter(\.isFavorite)
        case .thisWeek:
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            base = vm.entries.filter { $0.createdAt >= cutoff }
        case .mood(let m): base = vm.entries.filter { $0.mood == m }
        case .tag(let t): base = vm.entries.filter { $0.tags.contains(t) }
        case .onThisDay: base = vm.onThisDay
        case .archive: return vm.archivedEntries
        case .hidden: return vm.hiddenEntries
        case .trash: return vm.trashedEntries
        default: base = vm.entries
        }
        return vm.filter.isActive ? base.filter(vm.filter.matches) : base
    }

    private var isTrash: Bool { selection == .trash }

    /// Grouped sections for the currently displayed set.
    private var sections: [JournalViewModel.EntrySection] {
        guard selection == .all || selection == nil else {
            return displayed.isEmpty ? [] : [.init(title: selection?.title ?? "Entries", entries: displayed)]
        }
        let ids = Set(displayed.map(\.id))
        return vm.groupedEntries
            .map { JournalViewModel.EntrySection(title: $0.title, entries: $0.entries.filter { ids.contains($0.id) }) }
            .filter { !$0.entries.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
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
        .animation(.easeInOut(duration: 0.18), value: showFilters)
        .animation(.easeInOut(duration: 0.18), value: vm.isBulkSelecting)
        .animation(.easeInOut(duration: 0.2), value: biometricAuth.isAuthenticated)
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocused = true
        }
    }

    // MARK: Hidden Banner

    private var hiddenBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: biometricAuth.isAuthenticated ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 10))
                .foregroundColor(theme.accentColor)
            Text(biometricAuth.isAuthenticated
                 ? "Hidden content is visible — lock if someone walks by."
                 : "Content is hidden — authenticate to reveal.")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryTextColor)
            Spacer()
            if biometricAuth.isAuthenticated {
                Button {
                    vm.lockHiddenEntries()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                        Text("Lock")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .help("Lock hidden entries (⌘L)")
            } else {
                Button {
                    Task { _ = await biometricAuth.authenticate() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: biometricAuth.biometricType == "Touch ID" ? "touchid" : "lock.open.fill")
                            .font(.system(size: 10))
                        Text("Unlock")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.white)
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
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryTextColor)
                TextField("Search entries…", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(theme.titleTextColor)
                    .focused($searchFocused)
                    .onChange(of: vm.searchText) { _, _ in vm.searchTextChanged() }
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                        vm.refreshQuery()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
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
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryTextColor)

                Spacer()

                Button {
                    withAnimation { showFilters.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease.circle\(vm.filter.isActive ? ".fill" : "")")
                            .font(.system(size: 11))
                        if vm.filter.activeCount > 0 {
                            Text("\(vm.filter.activeCount)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                        }
                    }
                    .foregroundColor(vm.filter.isActive ? theme.accentColor : theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .help("Filters")

                Menu {
                    ForEach(SortOrder.allCases) { order in
                        Button {
                            vm.setSortOrder(order)
                        } label: {
                            Label(order.rawValue, systemImage: vm.sortOrder == order ? "checkmark" : order.icon)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryTextColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort: \(vm.sortOrder.rawValue)")

                Button {
                    withAnimation {
                        vm.isBulkSelecting.toggle()
                        if !vm.isBulkSelecting { vm.clearBulkSelection() }
                    }
                } label: {
                    Image(systemName: vm.isBulkSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundColor(vm.isBulkSelecting ? theme.accentColor : theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .help("Select multiple")

                if biometricAuth.isAuthenticated && vm.hiddenCount > 0 {
                    Button {
                        vm.lockHiddenEntries()
                    } label: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Lock hidden entries (⌘L)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: Bulk action bar

    private var bulkActionBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("\(vm.bulkSelection.count) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.titleTextColor)

                Button("All") {
                    vm.bulkSelection = Set(displayed.map(\.id))
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(theme.accentColor)

                Button("None") { vm.bulkSelection.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryTextColor)

                Spacer()

                bulkButton("star", "Favorite") { vm.bulkFavorite() }
                bulkButton("number", "Tag") { withAnimation { showBulkTagField.toggle() } }
                bulkButton("archivebox", "Archive") { vm.bulkArchive() }
                bulkButton("trash", "Delete", destructive: true) { vm.bulkDelete() }
            }

            if showBulkTagField {
                HStack(spacing: 6) {
                    TextField("Tag name…", text: $bulkTagText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
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
                    .font(.system(size: 10, weight: .medium))
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

    private func bulkButton(_ icon: String, _ help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(destructive ? .red : theme.accentColor)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(vm.bulkSelection.isEmpty)
        .opacity(vm.bulkSelection.isEmpty ? 0.4 : 1)
        .help(help)
    }

    private var trashBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 10))
            Text("Entries are deleted forever after \(DatabaseManager.trashRetentionDays) days.")
                .font(.system(size: 10))
            Spacer()
            Button("Empty Trash") { vm.emptyTrash() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
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
                                    isSelected: vm.selectedEntryId == entry.id,
                                    isBulkSelected: vm.bulkSelection.contains(entry.id),
                                    isBulkSelecting: vm.isBulkSelecting,
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
        }
    }

    private func sectionHeader(_ section: JournalViewModel.EntrySection) -> some View {
        HStack(spacing: 5) {
            if section.title == "Pinned" {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundColor(theme.accentColor)
            }
            Text(section.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
                .foregroundColor(theme.secondaryTextColor)
            Text("\(section.entries.count)")
                .font(.system(size: 9, design: .rounded))
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
                .font(.system(size: 30, weight: .light))
                .foregroundColor(theme.secondaryTextColor.opacity(0.4))
            VStack(spacing: 4) {
                Text(emptyTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.bodyTextColor)
                Text(emptySubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
            if vm.filter.isActive {
                Button("Clear filters") { vm.filter = .empty }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            } else if !isTrash && selection != .archive {
                Button {
                    vm.createEntry()
                } label: {
                    Text("Write your first entry")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
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
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    let isSelected: Bool
    let isBulkSelected: Bool
    let isBulkSelecting: Bool
    let isTrash: Bool

    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var biometricAuth = BiometricAuth.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            if isBulkSelecting {
                Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isBulkSelected ? theme.accentColor : theme.secondaryTextColor.opacity(0.5))
            }

            RoundedRectangle(cornerRadius: 2)
                .fill(entry.mood.color)
                .frame(width: 3)
                .opacity(isContentLocked ? 0.35 : 0.85)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if entry.isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(theme.accentColor)
                    }
                    if entry.isHidden {
                        Image(systemName: isContentLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 8))
                            .foregroundColor(theme.accentColor.opacity(isContentLocked ? 0.9 : 0.7))
                    }
                    Text(entry.displayTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.titleTextColor.opacity(isContentLocked ? 0.72 : 1))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if entry.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundColor(.yellow)
                    }
                    if !entry.attachments.isEmpty {
                        Image(systemName: "paperclip").font(.system(size: 8)).foregroundColor(theme.secondaryTextColor)
                    }
                }

                if isContentLocked {
                    Text("Hidden · unlock to read")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryTextColor.opacity(0.55))
                        .lineLimit(1)
                } else {
                    Text(entry.preview)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryTextColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    Text(entry.mood.emoji).font(.system(size: 9))
                    Text(isTrash ? trashLabel : entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9.5))
                        .foregroundColor(theme.secondaryTextColor.opacity(0.8))
                    if entry.wordCount > 0 {
                        Text("· \(entry.wordCount)w")
                            .font(.system(size: 9.5))
                            .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                    }
                    Spacer(minLength: 2)
                    if !isContentLocked {
                        ForEach(entry.tags.prefix(2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundColor(theme.accentColor.opacity(0.9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                        }
                        if entry.tags.count > 2 {
                            Text("+\(entry.tags.count - 2)")
                                .font(.system(size: 8.5))
                                .foregroundColor(theme.secondaryTextColor.opacity(0.7))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(rowBorder, lineWidth: 1)
        )
        .opacity(isContentLocked ? 0.82 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) {
            if !isTrash && !isBulkSelecting { vm.startEditing(entry) }
        }
        .onTapGesture {
            if isBulkSelecting { vm.toggleBulkSelection(entry.id) } else { vm.select(entry) }
        }
        .contextMenu { contextMenu }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var trashLabel: String {
        let remaining = DatabaseManager.trashRetentionDays - entry.daysInTrash
        return remaining <= 0 ? "Deleting soon" : "\(remaining)d left"
    }

    private var isContentLocked: Bool {
        entry.isHidden && !biometricAuth.isAuthenticated
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
        return .clear
    }

    @ViewBuilder
    private var contextMenu: some View {
        if isTrash {
            Button { vm.restoreFromTrash(entry) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Divider()
            Button(role: .destructive) { vm.deleteForever(entry) } label: {
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
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundColor(theme.secondaryTextColor)
                Spacer()
                if vm.filter.isActive {
                    Button("Reset") { vm.filter = .empty }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
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
                            .font(.system(size: 12))
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
                    .help(mood.label)
                }

                Spacer()

                Picker("", selection: $vm.filter.dateRange) {
                    ForEach(EntryFilter.DateRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .labelsHidden()
                .font(.system(size: 10))
                .frame(width: 118)
            }

            // Toggles
            HStack(spacing: 5) {
                toggle("Favorites", "star.fill", $vm.filter.favoritesOnly)
                toggle("Pinned", "pin.fill", $vm.filter.pinnedOnly)
                toggle("Files", "paperclip", $vm.filter.withAttachmentsOnly)
                Spacer()
                Text("Min words")
                    .font(.system(size: 9))
                    .foregroundColor(theme.secondaryTextColor)
                Stepper("", value: $vm.filter.minWords, in: 0...2000, step: 50)
                    .labelsHidden()
                Text("\(vm.filter.minWords)")
                    .font(.system(size: 10, design: .rounded))
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
                                    .font(.system(size: 9.5, weight: on ? .semibold : .regular))
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
                Image(systemName: icon).font(.system(size: 8))
                Text(label).font(.system(size: 9.5, weight: binding.wrappedValue ? .semibold : .regular))
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
