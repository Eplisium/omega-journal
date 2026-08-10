import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: JournalViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var goals = GoalManager.shared

    @State private var tab: Tab = .appearance
    @State private var customAccent = ThemeManager.shared.accentColor
    @State private var customBackground = ThemeManager.shared.backgroundColor
    @State private var customSidebar = ThemeManager.shared.sidebarColor
    @State private var customCard = ThemeManager.shared.cardColor

    enum Tab: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case goals = "Goals"
        case data = "Data"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appearance: "paintpalette"
            case .goals: "target"
            case .data: "externaldrive"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 14))
                            Text(t.rawValue).font(.system(size: 10))
                        }
                        .foregroundColor(tab == t ? theme.accentColor : theme.secondaryTextColor)
                        .frame(width: 72, height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(tab == t ? theme.accentColor.opacity(0.14) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider().opacity(0.25)

            ScrollView {
                Group {
                    switch tab {
                    case .appearance: appearanceTab
                    case .goals: goalsTab
                    case .data: dataTab
                    case .about: aboutTab
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 540, height: 480)
        .background(theme.backgroundColor)
    }

    // MARK: Appearance

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Theme")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(ThemePresets.all.keys.sorted(), id: \.self) { name in
                    let preset = ThemePresets.all[name]!
                    Button { theme.applyTheme(named: name) } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 0) {
                                preset.background
                                preset.card
                                preset.accent
                            }
                            .frame(height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(name)
                                .font(.system(size: 11, weight: theme.themeName == name ? .semibold : .regular))
                                .foregroundColor(theme.titleTextColor)
                        }
                        .padding(7)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(theme.themeName == name ? theme.accentColor.opacity(0.15) : theme.cardColor.opacity(0.4))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(theme.themeName == name ? theme.accentColor : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().opacity(0.2)

            sectionTitle("Custom Colors")
            VStack(spacing: 8) {
                colorRow("Accent", $customAccent)
                colorRow("Background", $customBackground)
                colorRow("Sidebar", $customSidebar)
                colorRow("Cards", $customCard)
            }
            Button("Apply Custom Theme") {
                theme.applyCustom(accent: customAccent, background: customBackground, sidebar: customSidebar, card: customCard)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func colorRow(_ label: String, _ binding: Binding<Color>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(theme.bodyTextColor)
            Spacer()
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
        }
    }

    // MARK: Goals

    private var goalsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Writing Goals")
            Text("Targets appear in the sidebar and drive your streak.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryTextColor)

            ForEach(goals.goals) { goal in
                HStack(spacing: 10) {
                    Image(systemName: goal.type.icon)
                        .font(.system(size: 13))
                        .foregroundColor(theme.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(goal.type.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.titleTextColor)
                        Text(goal.displayProgress)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { goal.target },
                            set: { goals.updateGoal(type: goal.type, target: $0) }
                        ),
                        in: 1...10000,
                        step: goal.type.unit == "words" ? 50 : 1
                    ) {
                        Text("\(goal.target)")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(theme.titleTextColor)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardColor.opacity(0.45)))
            }
        }
    }

    // MARK: Data

    private var dataTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Export")
            HStack(spacing: 8) {
                dataButton("Markdown", "arrow.down.doc") { ImportExportPanels.exportMarkdown(vm: vm) }
                dataButton("JSON", "curlybraces") { ImportExportPanels.exportJSON(vm: vm) }
                dataButton("PDF", "doc.richtext") { ImportExportPanels.exportPDF(vm: vm) }
            }

            Divider().opacity(0.2)

            sectionTitle("Import")
            dataButton("Import Entries…", "square.and.arrow.down") {
                ImportExportPanels.showImportPanel(vm: vm)
            }
            Text("Accepts a JSON backup exported from Omega Journal, or a set of markdown files.")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryTextColor)

            Divider().opacity(0.2)

            sectionTitle("Storage")
            statRow("Entries", "\(vm.entries.count)")
            statRow("Archived", "\(vm.archivedEntries.count)")
            statRow("In Trash", "\(vm.trashedEntries.count)")
            statRow("Total words", vm.totalWordCount.formatted())
            statRow("Database", "~/Library/Application Support/OmegaJournal")

            Button {
                NSWorkspace.shared.open(
                    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("OmegaJournal")
                )
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accentColor)

            if !vm.trashedEntries.isEmpty {
                Divider().opacity(0.2)
                Button(role: .destructive) {
                    vm.emptyTrash()
                } label: {
                    Label("Empty Trash (\(vm.trashedEntries.count))", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dataButton(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.accentColor.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(theme.secondaryTextColor)
            Spacer()
            Text(value).font(.system(size: 11, design: .rounded)).foregroundColor(theme.bodyTextColor)
        }
    }

    // MARK: About

    private var aboutTab: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [theme.accentColor, theme.accentColor.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                Text("Ω").font(.system(size: 32, weight: .bold, design: .serif)).foregroundColor(.white)
            }
            Text("Omega Journal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.titleTextColor)
            Text("A fast, private, local-first journal for macOS.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryTextColor)

            Divider().opacity(0.2).padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 5) {
                shortcut("⌘N", "New entry")
                shortcut("⇧⌘N", "New from template")
                shortcut("⌥⌘N", "New from today's prompt")
                shortcut("⌘K", "Command palette")
                shortcut("⌘F", "Search")
                shortcut("⌘E", "Edit selected entry")
                shortcut("⌃⌘F", "Zen mode")
                shortcut("⌘B / ⌘I", "Bold / Italic")
                shortcut("⌘1…⌘4", "All / Calendar / Insights / Favorites")
                shortcut("⌘⏎", "Finish editing")
                shortcut("⎋", "Close editor or palette")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(theme.bodyTextColor)
                .frame(width: 68, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.secondaryTextColor.opacity(0.13)))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryTextColor)
            Spacer()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.7)
            .foregroundColor(theme.secondaryTextColor)
    }
}
