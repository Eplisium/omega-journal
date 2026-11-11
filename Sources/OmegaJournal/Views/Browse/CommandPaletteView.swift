import SwiftUI
import OmegaJournalCore

// MARK: - Command Palette (⌘K)
//
// A single fuzzy-searchable surface for navigation, actions, and jumping to any entry.

struct CommandPaletteView: View {
    var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    private let theme = ThemeManager.shared

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // MARK: Command model

    struct Command: Identifiable {
        /// Stable across renders (group + key, where key defaults to the title
        /// and is the entry id for entry rows) so ForEach keeps row identity.
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let group: String
        let run: () -> Void
        /// ⌘↩ action and its hint label (entries: open in the editor).
        var secondary: (label: String, run: () -> Void)?
        /// Body snippet with its own match highlight (content hits).
        var snippet: SearchSnippet?
        /// Matched character ranges in `title`, highlighted in the row.
        var titleRanges: [Range<Int>] = []
        /// Entries open; commands run (the ↩ hint).
        var isEntry: Bool { group == "Entries" || group == "In entries" }

        init(title: String, subtitle: String, icon: String, group: String, key: String? = nil,
             run: @escaping () -> Void) {
            self.id = group + "|" + (key ?? title)
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.group = group
            self.run = run
        }
    }

    /// Title with matched characters emphasised.
    static func highlightedTitle(_ title: String, ranges: [Range<Int>], accent: Color, base: Color) -> AttributedString {
        var out = AttributedString()
        let chars = Array(title)
        var i = 0
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lo = min(max(r.lowerBound, i), chars.count), hi = min(max(r.upperBound, lo), chars.count)
            if lo > i { var plain = AttributedString(String(chars[i..<lo])); plain.foregroundColor = base; out += plain }
            if hi > lo {
                var hit = AttributedString(String(chars[lo..<hi]))
                hit.foregroundColor = accent
                hit.inlinePresentationIntent = .stronglyEmphasized
                out += hit
            }
            i = hi
        }
        if i < chars.count { var rest = AttributedString(String(chars[i...])); rest.foregroundColor = base; out += rest }
        return out
    }

    /// ⌘↩ for an entry row: open it in the editor. Never offered for a
    /// locked hidden entry or one in the trash.
    private func editAction(for entry: JournalEntry) -> (label: String, run: () -> Void)? {
        guard !entry.isTrashed,
              ContentMasking.canShowContent(isHidden: entry.isHidden, hiddenLocked: vm.hiddenLocked) else { return nil }
        return ("edit", {
            selection = .all
            vm.select(entry)
            vm.startEditing(entry)
        })
    }

    /// Jump-to-entry subtitle. Word count is body-derived, so it is omitted
    /// for a locked hidden entry (title/mood/date only).
    nonisolated static func entrySubtitle(for entry: JournalEntry, hiddenLocked: Bool) -> String {
        let base = "\(entry.mood.face) \(entry.createdAt.formatted(date: .abbreviated, time: .omitted))"
        guard ContentMasking.canShowContent(isHidden: entry.isHidden, hiddenLocked: hiddenLocked) else { return base }
        return base + " · \(entry.wordCount)w"
    }

    /// An Entry-group command for the selection.
    nonisolated enum EntryAction: Equatable {
        case edit, togglePin, toggleFavorite, duplicate, archive, unarchive, moveToTrash
        case restore, deleteForever

        func title(for entry: JournalEntry) -> String {
            switch self {
            case .edit: "Edit “\(entry.displayTitle)”"
            case .togglePin: entry.isPinned ? "Unpin Entry" : "Pin Entry"
            case .toggleFavorite: entry.isFavorite ? "Remove Favorite" : "Favorite Entry"
            case .duplicate: "Duplicate Entry"
            case .archive: "Archive Entry"
            case .unarchive: "Unarchive Entry"
            case .moveToTrash: "Move to Trash"
            case .restore: "Restore from Trash"
            case .deleteForever: "Delete Forever"
            }
        }

        var icon: String {
            switch self {
            case .edit: "pencil"
            case .togglePin: "pin"
            case .toggleFavorite: "star"
            case .duplicate: "doc.on.doc"
            case .archive: "archivebox"
            case .unarchive: "tray.and.arrow.up"
            case .moveToTrash: "trash"
            case .restore: "arrow.uturn.backward"
            case .deleteForever: "trash.slash"
            }
        }
    }

    /// The Entry commands for the selection, by lifecycle (as the row's
    /// context menu does). A trashed entry offers only Restore and Delete
    /// Forever: editing, pinning or archiving it made no sense, and "Move to
    /// Trash" again restarted its 30-day clock. An archived entry offers
    /// Unarchive — "Archive Entry" used to toggle it back out of the archive.
    nonisolated static func entryActions(for entry: JournalEntry) -> [EntryAction] {
        if entry.isTrashed { return [.restore, .deleteForever] }
        return [.edit, .togglePin, .toggleFavorite, .duplicate, entry.isArchived ? .unarchive : .archive, .moveToTrash]
    }

    private func run(_ action: EntryAction, on entry: JournalEntry) {
        switch action {
        case .edit: vm.startEditing(entry)
        case .togglePin: vm.togglePin(entry)
        case .toggleFavorite: vm.toggleFavorite(entry)
        case .duplicate: vm.duplicate(entry)
        case .archive, .unarchive: vm.toggleArchive(entry)
        case .moveToTrash: vm.deleteEntry(entry)
        case .restore: vm.restoreFromTrash(entry)
        case .deleteForever: if Self.confirmDeleteForever() { vm.deleteForever(entry) }
        }
    }

    /// The palette has closed by the time a command runs, so Delete Forever
    /// asks with an alert of its own (the row dialog's wording).
    private static func confirmDeleteForever() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this entry forever?"
        alert.informativeText = "This cannot be undone. The entry and its attachments will be permanently removed."
        alert.addButton(withTitle: "Delete Forever")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var commands: [Command] {
        var list: [Command] = [
            Command(title: "New Entry", subtitle: "Start writing", icon: "square.and.pencil", group: "Create") {
                selection = .all
                vm.createEntry()
            },
            Command(title: "New from Template", subtitle: "Pick a structure", icon: "doc.badge.plus", group: "Create") {
                selection = .all
                NotificationCenter.default.post(name: .newFromTemplate, object: nil)
            },
            Command(title: "New from Today's Prompt", subtitle: PromptGenerator.today(), icon: "sparkles", group: "Create") {
                selection = .all
                vm.createEntryFromPrompt()
            },
        ]
        // On-device question answering over the journal (Apple Intelligence only).
        if SmartAssist.availability.isAvailable {
            list.append(Command(title: "Ask Your Journal…", subtitle: "On this Mac (⇧⌘A)", icon: "sparkles", group: "Create") {
                NotificationCenter.default.post(name: .showAskJournal, object: nil)
            })
        }

        // Navigation
        let destinations: [SidebarItem] = [.today, .all, .favorites, .thisWeek, .calendar, .map, .insights, .onThisDay, .archive, .hidden, .trash]
        for dest in destinations {
            list.append(Command(title: "Go to \(dest.title)", subtitle: "Navigate", icon: dest.icon, group: "Navigate") {
                selection = dest
                vm.selectedEntryId = nil
            })
        }

        // Entry actions on the current selection, following its lifecycle.
        if let entry = vm.selectedEntry {
            for action in Self.entryActions(for: entry) {
                list.append(Command(title: action.title(for: entry),
                                    subtitle: action == .edit ? "Open in editor" : entry.displayTitle,
                                    icon: action.icon, group: "Entry") {
                    run(action, on: entry)
                })
            }
        }

        // Sorting
        for order in SortOrder.allCases {
            list.append(Command(title: "Sort by \(order.rawValue)", subtitle: "Change list order", icon: order.icon, group: "View") {
                vm.setSortOrder(order)
            })
        }

        // Themes
        for name in ThemePresets.all.map(\.name) {
            list.append(Command(title: "Theme: \(name)", subtitle: "Change appearance", icon: "paintpalette", group: "View") {
                ThemeManager.shared.applyTheme(named: name)
            })
        }

        // Data
        list.append(contentsOf: [
            Command(title: "Export as Markdown", subtitle: "\(vm.entries.count) entries", icon: "arrow.down.doc", group: "Data") {
                ImportExportPanels.exportMarkdown(vm: vm)
            },
            Command(title: "Export as JSON", subtitle: "Full backup", icon: "curlybraces", group: "Data") {
                ImportExportPanels.exportJSON(vm: vm)
            },
            Command(title: "Export as PDF", subtitle: "Printable book", icon: "doc.richtext", group: "Data") {
                ImportExportPanels.exportPDF(vm: vm)
            },
            Command(title: "Export as Book (EPUB)", subtitle: "Read in Books or any e-reader", icon: "book", group: "Data") {
                ExportManager.exportEPUB(vm: vm, scope: .all)
            },
            Command(title: "Import Entries", subtitle: "JSON backup or markdown files", icon: "square.and.arrow.down", group: "Data") {
                ImportExportPanels.showImportPanel(vm: vm)
            },
        ])

        if BiometricAuth.shared.isAuthenticated {
            list.append(Command(title: "Lock Hidden Entries", subtitle: "Re-mask hidden content (⌘L)", icon: "lock.fill", group: "View") {
                vm.lockHiddenEntries()
            })
        }

        // Jump-to-entry
        let locked = vm.hiddenLocked
        for entry in vm.entries.prefix(200) {
            var cmd = Command(
                title: entry.displayTitle,
                subtitle: Self.entrySubtitle(for: entry, hiddenLocked: locked),
                icon: "doc.text",
                group: "Entries",
                key: entry.id
            ) {
                selection = .all
                vm.select(entry)
            }
            cmd.secondary = editAction(for: entry)
            list.append(cmd)
        }

        return list
    }

    private var results: [Command] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = commands   // build once per results pass
        guard !q.isEmpty else {
            return Array(all.filter { $0.group != "Entries" }.prefix(24))
        }
        // One relevance score for commands, entry titles and content hits,
        // so a weak command match never sits above the entry you meant.
        var scored: [(Command, Int)] = all.compactMap { cmd in
            guard let m = UIPaletteRanking.score(q, title: cmd.title, subtitle: cmd.subtitle) else { return nil }
            var c = cmd
            c.titleRanges = m.ranges
            return (c, m.score)
        }
        // Content matches (body/tags/operators). Masked while locked: hidden entries match title only
        // and never contribute a body snippet.
        let titled = Set(scored.filter { $0.0.group == "Entries" }.map { $0.0.id.replacingOccurrences(of: "Entries|", with: "") })
        for (rank, hit) in vm.contentSearchHits(q, limit: 8).enumerated() where !titled.contains(hit.entry.id) {
            var cmd = Command(title: hit.entry.displayTitle,
                              subtitle: hit.snippet?.text ?? "\(hit.entry.mood.face) \(hit.entry.createdAt.formatted(date: .abbreviated, time: .omitted))",
                              icon: "text.magnifyingglass", group: "In entries", key: hit.entry.id) {
                selection = .all
                vm.select(hit.entry)
            }
            cmd.snippet = hit.snippet
            cmd.titleRanges = UIPaletteRanking.match(q, in: hit.entry.displayTitle, allowFuzzy: false)?.ranges ?? []
            cmd.secondary = editAction(for: hit.entry)
            // Search already ordered these; keep that order within the tier.
            scored.append((cmd, UIPaletteRanking.Tier.contentHit.rawValue - rank))
        }
        return Array(UIPaletteRanking.ranked(scored).prefix(30))
    }

    var body: some View {
        // Results are computed once per render and shared by the list, the
        // count and the key handlers below.
        let rows = results
        ZStack(alignment: .top) {
            Color.black.opacity(GlassPolicy.modalDimOpacity(glass: GlassSupport.usesGlass(.floatingPanel),
                                                            reduceTransparency: reduceTransparency))
                .ignoresSafeArea()
                .onTapGesture { vm.showCommandPalette = false }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 9) {
                    Image(systemName: "command")
                        .font(OmegaTheme.font(.body, .medium))
                        .foregroundColor(theme.accentColor)
                    // Placeholder drawn by SwiftUI: on glass AppKit's placeholder
                    // color fell to near-invisible against the dark wash.
                    TextField("", text: $query, prompt: Text(""))
                        .accessibilityLabel("Type a command or search entries")
                        .background(alignment: .leading) {
                            if query.isEmpty {
                                Text("Type a command or search entries…")
                                    .font(OmegaTheme.font(.bodyLarge))
                                    .foregroundColor(theme.secondaryTextColor)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(OmegaTheme.font(.bodyLarge))
                        .foregroundColor(theme.titleTextColor)
                        .focused($focused)
                        .onSubmit { runHighlighted() }
                        .onChange(of: query) { _, _ in highlighted = 0 }
                    Text("esc")
                        .font(OmegaTheme.font(.meta, design: .rounded))
                        .foregroundColor(theme.secondaryTextColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.secondaryTextColor.opacity(0.15)))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().opacity(0.3)

                // Results
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, cmd in
                                resultRow(cmd, index: index)
                                    .id(index)
                            }
                            if rows.isEmpty {
                                Text("No matching commands")
                                    .font(OmegaTheme.font(.caption))
                                    .foregroundColor(theme.secondaryTextColor)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: highlighted) { _, new in
                        if reduceMotion { proxy.scrollTo(new, anchor: .center) } else { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) } }
                    }
                }

                Divider().opacity(0.3)

                HStack(spacing: 12) {
                    let current = rows.indices.contains(highlighted) ? rows[highlighted] : nil
                    hint("↑↓", "navigate")
                    hint("↩", current?.isEntry == true ? "open" : "run")
                    if let secondary = current?.secondary { hint("⌘↩", secondary.label) }
                    hint("esc", "close")
                    Spacer()
                    Text(A11yDescriptions.paletteResultCount(rows.count))
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .frame(width: 620)
            // A dense list of text: a partly opaque theme wash under the
            // rows keeps them legible over busy content behind the glass.
            .background {
                if GlassSupport.usesGlass(.floatingPanel) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.cardColor.opacity(reduceTransparency ? 0.9 : 0.6))
                }
            }
            // Floating layer: Liquid Glass on macOS 26, the solid card before.
            .ojGlass(.floatingPanel, in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                     tint: theme.accentColor) { panel in
                panel
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(theme.cardColor)
                            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 1)
                    )
            }
            .padding(.top, 90)
        }
        .background {
            // ⌘↩ runs the highlighted row's secondary action (entries: edit).
            Button("") { runSecondary() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear { focused = true; highlighted = 0 }
        .onExitCommand { vm.showCommandPalette = false }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = max(0, min(rows.count - 1, highlighted + 1))
            return .handled
        }
        // A labelled container (not a label smeared over every child) that
        // keeps its rows individually reachable.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Command palette")
    }

    private func resultRow(_ cmd: Command, index: Int) -> some View {
        let isOn = index == highlighted
        return Button {
            highlighted = index
            runHighlighted()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: cmd.icon)
                    .font(OmegaTheme.font(.caption))
                    .foregroundColor(isOn ? theme.accentColor : theme.secondaryTextColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.highlightedTitle(cmd.title, ranges: cmd.titleRanges,
                                               accent: theme.accentColor, base: theme.titleTextColor))
                        .font(OmegaTheme.font(.caption, isOn ? .semibold : .regular))
                        .lineLimit(1)
                    if let snippet = cmd.snippet {
                        Text(EntryRow.highlighted(snippet, accent: theme.accentColor, base: theme.secondaryTextColor))
                            .font(OmegaTheme.font(.meta))
                            .lineLimit(1)
                    } else {
                        Text(cmd.subtitle)
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.secondaryTextColor)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(cmd.group)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.secondaryTextColor.opacity(0.1)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                // Concentric with the glass panel's larger corners.
                RoundedRectangle(cornerRadius: GlassSupport.usesGlass(.floatingPanel) ? 12 : 7, style: .continuous)
                    .fill(isOn ? theme.accentColor.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // ↑/↓ move a visual highlight, not keyboard focus — expose it.
        .accessibilityLabel(cmd.subtitle.isEmpty ? cmd.title : "\(cmd.title), \(cmd.subtitle)")
        .accessibilityValue(cmd.group)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(OmegaTheme.font(.meta, design: .rounded))
                .foregroundColor(theme.bodyTextColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.secondaryTextColor.opacity(0.15)))
            Text(label)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
        }
    }

    private func runSecondary() {
        let rows = results
        guard rows.indices.contains(highlighted), let secondary = rows[highlighted].secondary else { return }
        vm.showCommandPalette = false
        DispatchQueue.main.async { secondary.run() }
    }

    private func runHighlighted() {
        guard highlighted < results.count else { return }
        let cmd = results[highlighted]
        vm.showCommandPalette = false
        DispatchQueue.main.async { cmd.run() }
    }
}
