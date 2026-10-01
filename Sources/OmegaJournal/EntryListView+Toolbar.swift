import SwiftUI
import OmegaJournalCore

extension EntryListView {
    // MARK: Search bar

    var searchBar: some View {
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

                Menu {
                    Picker("Density", selection: $densityRaw) {
                        ForEach(ListDensity.allCases) { d in Label(d.label, systemImage: d.icon).tag(d.rawValue) }
                    }
                } label: {
                    Image(systemName: (ListDensity(rawValue: densityRaw) ?? .comfortable).icon)
                        .font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("List density")
                .omegaTooltip("List density")

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
                        vm.recordRecentSearch(vm.searchText)
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
                    .accessibilityLabel("Lock hidden entries")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: Segmented sort (Latest | Oldest | A–Z)

    var sortSegmentedControl: some View {
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

    func segment(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
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

    var bulkActionBar: some View {
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
                    .keyboardShortcut(.escape, modifiers: [])

                if bulkStorage == .library && vm.journals.count > 1 {
                    Menu {
                        ForEach(vm.journals) { j in
                            Button(j.name) { vm.moveSelectedToJournal(j.id) }
                        }
                    } label: {
                        Label("Move", systemImage: "book.closed").font(OmegaTheme.font(.meta))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(vm.bulkSelection.isEmpty)
                    .accessibilityLabel("Move selected entries to a notebook")
                }

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
    func bulkActionButton(_ action: BulkEntryAction) -> some View {
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

    func bulkButton(_ icon: String, _ help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
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
        .accessibilityLabel(help)
    }

    var trashBanner: some View {
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
}
