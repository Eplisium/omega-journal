import SwiftUI
import OmegaJournalCore

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var goals = GoalManager.shared

    // Collapsed/expanded state of every section persists across launches.
    @AppStorage(ShellPrefs.sidebarLibraryExpanded) private var libraryExpanded = true
    @AppStorage(ShellPrefs.sidebarReflectExpanded) private var reflectExpanded = true
    @AppStorage(ShellPrefs.sidebarNotebooksExpanded) private var notebooksExpanded = true
    @AppStorage(ShellPrefs.sidebarSmartExpanded) private var smartExpanded = true
    @AppStorage(ShellPrefs.sidebarTagsExpanded) private var tagsExpanded = true
    @AppStorage(ShellPrefs.sidebarMoodsExpanded) private var moodsExpanded = false
    @AppStorage(ShellPrefs.sidebarStorageExpanded) private var storageExpanded = true
    /// Newline-separated tag paths whose children are folded away.
    @AppStorage(ShellPrefs.sidebarCollapsedTags) private var collapsedTagsRaw = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false
    @State private var settingsSection: SettingsSection = .appearance
    @State private var smartFolderDraft: SmartFolder?
    @State private var showTagManager = false
    @State private var journalDraft: JournalDraft?
    @State private var dropTarget: String?
    @FocusState private var sidebarFocused: Bool

    struct JournalDraft: Identifiable { let id = UUID(); var journal: Journal? }

    private var collapsedTags: Set<String> {
        Set(collapsedTagsRaw.split(separator: "\n").map(String.init))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !vm.entries.isEmpty { streakCard }

                    section("TODAY") {
                        row(.today)
                    }

                    disclosureSection("LIBRARY", isExpanded: $libraryExpanded) {
                        row(.all, badge: vm.entries.count)
                        row(.favorites, badge: vm.favoriteCount)
                        row(.thisWeek, badge: vm.entriesThisWeek)
                    }

                    disclosureSection("REFLECT", isExpanded: $reflectExpanded) {
                        row(.calendar)
                        row(.insights)
                        row(.onThisDay, badge: vm.reflectiveOnThisDay.count)
                    }

                    if !vm.smartFolders.filter(\.isPinned).isEmpty { pinnedSection }

                    notebooksSection

                    smartFoldersSection

                    disclosureSection("MOODS", isExpanded: $moodsExpanded) {
                        ForEach(Mood.allCases) { mood in
                            let count = vm.moodCounts[mood] ?? 0
                            if count > 0 { row(.mood(mood), badge: count) }
                        }
                    }

                    if !vm.tagTree.isEmpty {
                        tagsSection
                    }

                    disclosureSection("STORAGE", isExpanded: $storageExpanded) {
                        row(.archive, badge: vm.archivedEntries.count, dropTargetId: "archive") { ids in
                            vm.dropEntriesOnArchive(ids: ids)
                        }
                        row(.hidden, badge: vm.hiddenCount)
                        row(.trash, badge: vm.trashedEntries.count)
                    }

                    goalsCard
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($sidebarFocused)
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }

            Divider().opacity(0.25)
            footer
        }
        .background(theme.sidebarColor)
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm, initialSection: settingsSection)
        }
        .sheet(item: $smartFolderDraft) { draft in
            SmartFolderEditor(vm: vm, folder: draft) { saved in
                if let saved { selection = .smartFolder(saved.id) }
            }
        }
        .sheet(isPresented: $showTagManager) {
            TagManagerView(vm: vm)
        }
        .sheet(item: $journalDraft) { draft in
            NotebookEditor(vm: vm, journal: draft.journal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            settingsSection = .appearance
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showShortcuts)) { _ in
            settingsSection = .about
            showSettings = true
        }
    }

    /// Keyboard navigation through the primary destinations.
    private var keyboardOrder: [SidebarItem] {
        var items: [SidebarItem] = [.today, .all, .favorites, .thisWeek, .calendar, .insights, .onThisDay]
        items += (vm.smartFolders.filter(\.isPinned) + vm.smartFolders.filter { !$0.isPinned }).map { .smartFolder($0.id) }
        items += TagTree.flatten(vm.tagTree, collapsed: collapsedTags).map { .tag($0.path) }
        items += [.archive, .hidden, .trash]
        return items
    }

    private func moveSelection(_ delta: Int) {
        let order = keyboardOrder
        guard let current = selection, let idx = order.firstIndex(of: current) else {
            selection = order.first; return
        }
        selection = order[min(max(idx + delta, 0), order.count - 1)]
        vm.selectedEntryId = nil
    }

    // MARK: Notebooks

    private var notebooksSection: some View {
        disclosureSection("NOTEBOOKS", isExpanded: $notebooksExpanded, trailing: {
            sectionAddButton("New notebook") { journalDraft = JournalDraft(journal: nil) }
        }) {
            notebookRow(nil)
            ForEach(vm.journals) { j in notebookRow(j) }
        }
    }

    private func notebookRow(_ journal: Journal?) -> some View {
        let isActive = vm.activeJournalId == journal?.id
        let count = journal.map { vm.journalCounts[$0.id] ?? 0 } ?? vm.journalCounts.values.reduce(0, +)
        let color = journal.flatMap { TagColors.rgb(hex: $0.colorHex) }.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? theme.secondaryTextColor
        let name = journal?.name ?? "All notebooks"
        return SidebarRowButton(
            title: name, icon: nil, dot: color, badge: count, indent: 0,
            isSelected: isActive, tint: color, theme: theme, isDropTarget: dropTarget == "nb:\(journal?.id ?? "")"
        ) {
            vm.setActiveJournal(journal?.id)
        }
        .contextMenu {
            if let journal {
                Button("Edit Notebook…") { journalDraft = JournalDraft(journal: journal) }
                if !journal.isDefault {
                    Divider()
                    Button("Delete Notebook", role: .destructive) { vm.deleteJournal(journal) }
                }
            }
        }
        .dropDestination(for: String.self, action: { items, _ in
            guard let journal else { return false }
            let ids = items.flatMap(EntryDragPayload.decode)
            guard !ids.isEmpty else { return false }
            vm.moveToJournal(ids: ids, journalId: journal.id)
            return true
        }, isTargeted: { dropTarget = $0 ? "nb:\(journal?.id ?? "")" : (dropTarget == "nb:\(journal?.id ?? "")" ? nil : dropTarget) })
        .accessibilityLabel(isActive ? "\(name), current notebook" : "Switch to \(name)")
    }

    // MARK: Smart folders

    private var pinnedSection: some View {
        section("PINNED") {
            ForEach(vm.smartFolders.filter(\.isPinned)) { folder in
                row(.smartFolder(folder.id), badge: vm.smartFolderCounts[folder.id] ?? 0)
                    .contextMenu { folderMenu(folder) }
            }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: SmartFolder) -> some View {
        Button(folder.isPinned ? "Unpin from Top" : "Pin to Top") { vm.togglePinSmartFolder(folder) }
        Button("Edit Smart Folder…") { smartFolderDraft = folder }
        Divider()
        Button("Delete Smart Folder", role: .destructive) {
            if selection == .smartFolder(folder.id) { selection = .all }
            vm.deleteSmartFolder(folder)
        }
    }

    private var smartFoldersSection: some View {
        disclosureSection("SMART FOLDERS", isExpanded: $smartExpanded, trailing: {
            sectionAddButton("New smart folder") { smartFolderDraft = SmartFolder(name: "") }
        }) {
            if vm.smartFolders.isEmpty {
                Text("Save a search or build a folder from tags, moods, dates and more.")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            ForEach(vm.smartFolders.filter { !$0.isPinned }) { folder in
                row(.smartFolder(folder.id), badge: vm.smartFolderCounts[folder.id] ?? 0)
                    .contextMenu { folderMenu(folder) }
            }
        }
    }

    // MARK: Tags (nested, colored, drop targets)

    private var tagsSection: some View {
        disclosureSection("TAGS", isExpanded: $tagsExpanded, trailing: {
            sectionAddButton("Manage tags", icon: "slider.horizontal.3") { showTagManager = true }
        }) {
            let nodes = TagTree.flatten(vm.tagTree, collapsed: collapsedTags)
            ForEach(nodes.prefix(60)) { node in
                tagRow(node)
            }
        }
    }

    private func tagRow(_ node: TagNode) -> some View {
        let item = SidebarItem.tag(node.path)
        let color = vm.color(forTag: node.path) ?? theme.accentColor
        let hasChildren = !node.children.isEmpty
        let folded = collapsedTags.contains(node.path)
        return HStack(spacing: 0) {
            SidebarRowButton(
                title: node.name, icon: nil, dot: color, badge: node.totalCount, indent: node.depth,
                isSelected: selection == item, tint: color, theme: theme, isDropTarget: dropTarget == "tag:\(node.path)",
                disclosure: hasChildren ? (folded ? .collapsed : .expanded) : nil,
                onDisclosure: { toggleTagFold(node.path) }
            ) {
                selection = item
                vm.selectedEntryId = nil
            }
        }
        .contextMenu {
            Button("Manage Tags…") { showTagManager = true }
            if hasChildren { Button(folded ? "Expand" : "Collapse") { toggleTagFold(node.path) } }
        }
        .dropDestination(for: String.self, action: { items, _ in
            let ids = items.flatMap(EntryDragPayload.decode)
            guard !ids.isEmpty else { return false }
            vm.dropEntries(ids: ids, onTag: node.path)
            return true
        }, isTargeted: { dropTarget = $0 ? "tag:\(node.path)" : (dropTarget == "tag:\(node.path)" ? nil : dropTarget) })
        .accessibilityLabel("Tag \(node.path)")
        .accessibilityValue("\(node.totalCount) \(node.totalCount == 1 ? "entry" : "entries")")
    }

    private func toggleTagFold(_ path: String) {
        var set = collapsedTags
        if set.contains(path) { set.remove(path) } else { set.insert(path) }
        collapsedTagsRaw = set.sorted().joined(separator: "\n")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                Text("Ω")
                    .font(OmegaTheme.font(.bodyLarge, .bold, design: .serif))
                    .foregroundColor(theme.onAccentColor)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Omega Journal")
                    .font(OmegaTheme.font(.body, .semibold, design: .serif))
                    .foregroundColor(theme.titleTextColor)
                Text("\(vm.entries.count) entries · \(vm.totalWordCount.formatted()) words")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Streak card

    private var streakCard: some View {
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(vm.writingStreak > 0 ? .orange : theme.secondaryTextColor.opacity(0.5))
                    Text("\(vm.writingStreak)")
                        .font(OmegaTheme.font(.heading, .bold, design: .rounded))
                        .foregroundColor(theme.titleTextColor)
                }
                Text(vm.writingStreak == 0 ? "fresh start" : "\(vm.streakUnit)\(vm.writingStreak == 1 ? "" : "s") showing up")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Divider().frame(height: 26).opacity(0.25)
            VStack(spacing: 1) {
                Text("\(vm.entriesThisMonth)")
                    .font(OmegaTheme.font(.heading, .bold, design: .rounded))
                    .foregroundColor(theme.titleTextColor)
                Text("this month")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.cardColor.opacity(0.6))
        )
        .hoverGlow(radius: 11, glow: 0.3, border: 0.35, lift: false)
        .padding(.bottom, 10)
    }

    // MARK: Goals card

    private var goalsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TODAY'S GOALS")
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.secondaryTextColor)
                .tracking(0.7)
                .padding(.horizontal, 4)

            ForEach(goals.goals.filter { $0.type == .dailyWords || $0.type == .dailyEntries }) { goal in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: goal.isComplete ? "checkmark.circle.fill" : goal.type.icon)
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(goal.isComplete ? .green : theme.accentColor)
                        Text(goal.type.rawValue)
                            .font(OmegaTheme.font(.meta, .medium))
                            .foregroundColor(theme.bodyTextColor)
                        Spacer()
                        Text(goal.displayProgress)
                            .font(OmegaTheme.font(.meta, design: .rounded))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.secondaryTextColor.opacity(0.15))
                            Capsule()
                                .fill(goal.isComplete ? Color.green : theme.accentColor)
                                .frame(width: max(2, geo.size.width * goal.progress))
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 10)
        .padding(.top, 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                selection = .all
                vm.createEntry()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil").font(OmegaTheme.font(.meta, .semibold))
                    Text("New Entry").font(OmegaTheme.font(.meta, .medium))
                }
                .foregroundColor(theme.onAccentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(.plain)
            .omegaTooltip("New Entry (⌘N)")

            Button { settingsSection = .appearance; showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(OmegaTheme.font(.caption))
                    .foregroundColor(theme.secondaryTextColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.cardColor.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .omegaTooltip("Settings (⌘,)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.secondaryTextColor)
                .tracking(0.7)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    @ViewBuilder
    private func disclosureSection<C: View>(_ title: String, isExpanded: Binding<Bool>,
                                            @ViewBuilder trailing: () -> some View = { EmptyView() },
                                            @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(OmegaTheme.Motion.quick.animation(reduceMotion: reduceMotion)) { isExpanded.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(OmegaTheme.font(.meta, .semibold))
                            .foregroundColor(theme.secondaryTextColor)
                            .tracking(0.7)
                        Image(systemName: "chevron.right")
                            .font(OmegaTheme.font(.meta, .bold))
                            .foregroundColor(theme.secondaryTextColor)
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title.capitalized) section")
                .accessibilityValue(isExpanded.wrappedValue ? "expanded" : "collapsed")
                .accessibilityHint("Double tap to \(isExpanded.wrappedValue ? "collapse" : "expand")")
                if isExpanded.wrappedValue { trailing() }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 3)

            if isExpanded.wrappedValue { content() }
        }
    }

    private func sectionAddButton(_ label: String, icon: String = "plus", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.secondaryTextColor)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .omegaTooltip(label)
    }

    private func row(_ item: SidebarItem, badge: Int? = nil, dropTargetId: String? = nil,
                     onDrop: (([String]) -> Void)? = nil) -> some View {
        let title: String = {
            if case .smartFolder(let id) = item { return vm.smartFolder(id: id)?.name ?? "Smart Folder" }
            return item.title
        }()
        let base = SidebarRowButton(
            title: title, icon: item.icon, dot: nil, badge: badge, indent: 0,
            isSelected: selection == item, tint: tint(for: item), theme: theme,
            isDropTarget: dropTargetId != nil && dropTarget == dropTargetId
        ) {
            selection = item
            vm.selectedEntryId = nil
        }
        return Group {
            if let onDrop {
                base.dropDestination(for: String.self, action: { items, _ in
                    let ids = items.flatMap(EntryDragPayload.decode)
                    guard !ids.isEmpty else { return false }
                    onDrop(ids)
                    return true
                }, isTargeted: { on in dropTarget = on ? dropTargetId : (dropTarget == dropTargetId ? nil : dropTarget) })
            } else {
                base
            }
        }
    }

    private func tint(for item: SidebarItem) -> Color {
        if case .mood(let m) = item { return m.color }
        if case .trash = item { return .red }
        return theme.accentColor
    }
}

// MARK: - Sidebar Row

struct SidebarRowButton: View {
    enum Disclosure { case expanded, collapsed }

    let title: String
    let icon: String?
    let dot: Color?
    let badge: Int?
    let indent: Int
    let isSelected: Bool
    let tint: Color
    let theme: ThemeManager
    var isDropTarget = false
    var disclosure: Disclosure? = nil
    var onDisclosure: (() -> Void)? = nil
    let action: () -> Void

    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 4) {
            if indent > 0 { Spacer().frame(width: CGFloat(indent) * 12) }
            if let disclosure {
                Button { onDisclosure?() } label: {
                    Image(systemName: "chevron.right")
                        .font(OmegaTheme.font(.meta, .bold))
                        .foregroundColor(theme.secondaryTextColor)
                        .rotationEffect(.degrees(disclosure == .expanded ? 90 : 0))
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(disclosure == .expanded ? "Collapse \(title)" : "Expand \(title)")
            } else if dot != nil {
                Spacer().frame(width: 12)
            }
            Button(action: action) {
                HStack(spacing: 8) {
                    if let dot {
                        Circle().fill(dot).frame(width: 8, height: 8).frame(width: 15)
                    } else if let icon {
                        Image(systemName: icon)
                            .font(OmegaTheme.font(.meta, .medium))
                            .foregroundColor(isSelected ? tint : theme.secondaryTextColor)
                            .frame(width: 15)
                    }
                    Text(title)
                        .font(OmegaTheme.font(.caption, isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? theme.titleTextColor : theme.bodyTextColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let badge, badge > 0 {
                        // Subtle: plain tabular number, no capsule unless selected.
                        Text("\(badge)")
                            .font(OmegaTheme.font(.meta, .regular, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(isSelected ? tint : theme.secondaryTextColor.opacity(0.8))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isDropTarget ? tint.opacity(0.28) : (isSelected ? tint.opacity(0.16) : (hover ? theme.titleTextColor.opacity(0.05) : .clear)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isDropTarget ? tint.opacity(0.8) : .clear, lineWidth: 1.5)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: 2.5, height: 14)
                    .offset(x: -1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue(badge.map { $0 > 0 ? "\($0) \($0 == 1 ? "entry" : "entries")" : "" } ?? "")
        .onHover { hover = $0 }
        .animation(OmegaTheme.Motion.quick.animation(reduceMotion: reduceMotion), value: hover)
        .animation(OmegaTheme.Motion.quick.animation(reduceMotion: reduceMotion), value: isDropTarget)
    }
}
