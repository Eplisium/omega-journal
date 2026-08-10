import SwiftUI
import OmegaJournalCore

// MARK: - Command Palette (⌘K)
//
// A single fuzzy-searchable surface for navigation, actions, and jumping to any entry.

struct CommandPaletteView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @ObservedObject private var theme = ThemeManager.shared

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    // MARK: Command model

    struct Command: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
        let group: String
        let run: () -> Void
    }

    private var commands: [Command] {
        var list: [Command] = [
            Command(title: "New Entry", subtitle: "Start writing", icon: "square.and.pencil", group: "Create") {
                vm.createEntry()
            },
            Command(title: "New from Template", subtitle: "Pick a structure", icon: "doc.badge.plus", group: "Create") {
                NotificationCenter.default.post(name: .newFromTemplate, object: nil)
            },
            Command(title: "New from Today's Prompt", subtitle: PromptGenerator.today(), icon: "sparkles", group: "Create") {
                vm.createEntryFromPrompt()
            },
        ]

        // Navigation
        let destinations: [SidebarItem] = [.all, .favorites, .thisWeek, .calendar, .insights, .onThisDay, .archive, .trash]
        for dest in destinations {
            list.append(Command(title: "Go to \(dest.title)", subtitle: "Navigate", icon: dest.icon, group: "Navigate") {
                selection = dest
                vm.selectedEntryId = nil
            })
        }

        // Entry actions on the current selection
        if let entry = vm.selectedEntry {
            list.append(contentsOf: [
                Command(title: "Edit “\(entry.displayTitle)”", subtitle: "Open in editor", icon: "pencil", group: "Entry") {
                    vm.startEditing(entry)
                },
                Command(title: entry.isPinned ? "Unpin Entry" : "Pin Entry", subtitle: entry.displayTitle, icon: "pin", group: "Entry") {
                    vm.togglePin(entry)
                },
                Command(title: entry.isFavorite ? "Remove Favorite" : "Favorite Entry", subtitle: entry.displayTitle, icon: "star", group: "Entry") {
                    vm.toggleFavorite(entry)
                },
                Command(title: "Duplicate Entry", subtitle: entry.displayTitle, icon: "doc.on.doc", group: "Entry") {
                    vm.duplicate(entry)
                },
                Command(title: "Archive Entry", subtitle: entry.displayTitle, icon: "archivebox", group: "Entry") {
                    vm.toggleArchive(entry)
                },
                Command(title: "Move to Trash", subtitle: entry.displayTitle, icon: "trash", group: "Entry") {
                    vm.deleteEntry(entry)
                },
            ])
        }

        // Sorting
        for order in SortOrder.allCases {
            list.append(Command(title: "Sort by \(order.rawValue)", subtitle: "Change list order", icon: order.icon, group: "View") {
                vm.setSortOrder(order)
            })
        }

        // Themes
        for name in ThemePresets.all.keys.sorted() {
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
            Command(title: "Import Entries", subtitle: "JSON backup or markdown files", icon: "square.and.arrow.down", group: "Data") {
                ImportExportPanels.showImportPanel(vm: vm)
            },
        ])

        // Jump-to-entry
        for entry in vm.entries.prefix(200) {
            list.append(Command(
                title: entry.displayTitle,
                subtitle: "\(entry.mood.emoji) \(entry.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(entry.wordCount)w",
                icon: "doc.text",
                group: "Entries"
            ) {
                selection = .all
                vm.select(entry)
            })
        }

        return list
    }

    /// Subsequence fuzzy match — "nte" matches "New Template".
    private func fuzzyScore(_ needle: String, _ haystack: String) -> Int? {
        OmegaCore.fuzzyScore(needle, haystack)
    }

    private var results: [Command] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return Array(commands.filter { $0.group != "Entries" }.prefix(24))
        }
        return commands
            .compactMap { cmd -> (Command, Int)? in
                guard let s = fuzzyScore(q, cmd.title) ?? fuzzyScore(q, cmd.subtitle).map({ $0 / 2 }) else { return nil }
                return (cmd, s)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(30)
            .map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { vm.showCommandPalette = false }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 9) {
                    Image(systemName: "command")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.accentColor)
                    TextField("Type a command or search entries…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundColor(theme.titleTextColor)
                        .focused($focused)
                        .onSubmit { runHighlighted() }
                        .onChange(of: query) { _, _ in highlighted = 0 }
                    Text("esc")
                        .font(.system(size: 9, design: .rounded))
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
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, cmd in
                                resultRow(cmd, index: index)
                                    .id(index)
                            }
                            if results.isEmpty {
                                Text("No matching commands")
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryTextColor)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: highlighted) { _, new in
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }

                Divider().opacity(0.3)

                HStack(spacing: 12) {
                    hint("↑↓", "navigate")
                    hint("↩", "run")
                    hint("esc", "close")
                    Spacer()
                    Text("\(results.count) results")
                        .font(.system(size: 9))
                        .foregroundColor(theme.secondaryTextColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .frame(width: 620)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.cardColor)
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 1)
            )
            .padding(.top, 90)
        }
        .onAppear { focused = true; highlighted = 0 }
        .onExitCommand { vm.showCommandPalette = false }
        .background(KeyCaptureView(
            onUp: { highlighted = max(0, highlighted - 1) },
            onDown: { highlighted = min(results.count - 1, highlighted + 1) }
        ))
    }

    private func resultRow(_ cmd: Command, index: Int) -> some View {
        let isOn = index == highlighted
        return Button {
            highlighted = index
            runHighlighted()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: cmd.icon)
                    .font(.system(size: 12))
                    .foregroundColor(isOn ? theme.accentColor : theme.secondaryTextColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cmd.title)
                        .font(.system(size: 12.5, weight: isOn ? .semibold : .regular))
                        .foregroundColor(theme.titleTextColor)
                        .lineLimit(1)
                    Text(cmd.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryTextColor)
                        .lineLimit(1)
                }
                Spacer()
                Text(cmd.group)
                    .font(.system(size: 9))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.secondaryTextColor.opacity(0.1)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? theme.accentColor.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(theme.bodyTextColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.secondaryTextColor.opacity(0.15)))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(theme.secondaryTextColor)
        }
    }

    private func runHighlighted() {
        guard highlighted < results.count else { return }
        let cmd = results[highlighted]
        vm.showCommandPalette = false
        DispatchQueue.main.async { cmd.run() }
    }
}

// MARK: - Arrow key capture
//
// SwiftUI has no first-class arrow-key handler for a non-focused list, so we install a
// local NSEvent monitor while the palette is on screen.

private struct KeyCaptureView: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(onUp: onUp, onDown: onDown)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(onUp: onUp, onDown: onDown)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?

        func install(onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
            remove()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 126: onUp(); return nil     // up arrow
                case 125: onDown(); return nil   // down arrow
                default: return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { remove() }
    }
}
