import SwiftUI

// MARK: - Settings sections

/// Settings navigation destinations. To add a new settings area:
///   1. Add a case here — `title`, `icon`, and `subtitle` come from the enum
///   2. Build its pane from `SettingsCard` + the row components below
///   3. Add the case to the switch in `SettingsView.content`
/// Everything else (sidebar entry, header, styling) is automatic.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case goals = "Writing Goals"
    case data = "Data & Storage"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .goals: "target"
        case .data: "externaldrive.fill"
        case .about: "info.circle.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: "Themes, colors, and personalization"
        case .goals: "Targets that shape your writing rhythm"
        case .data: "Export, import, and manage your library"
        case .about: "Keyboard shortcuts and app info"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: JournalViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var goals = GoalManager.shared

    @State private var section: SettingsSection
    @State private var customAccent = ThemeManager.shared.accentColor
    @State private var customBackground = ThemeManager.shared.backgroundColor
    @State private var customSidebar = ThemeManager.shared.sidebarColor
    @State private var customCard = ThemeManager.shared.cardColor
    @State private var showEmptyTrashConfirmation = false
    @AppStorage(ShellPrefs.lockOnResignKey) private var lockOnResign = true

    init(vm: JournalViewModel, initialSection: SettingsSection = .appearance) {
        self._vm = ObservedObject(wrappedValue: vm)
        self._section = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.2)
            content
        }
        .frame(width: 680, height: 540)
        .background(theme.backgroundColor)
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

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor, theme.accentColor.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 30, height: 30)
                    Text("Ω")
                        .font(.system(size: 115, weight: .bold, design: .serif))
                        .foregroundColor(theme.onAccentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Settings")
                        .font(.system(size: 113, weight: .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text("Omega Journal")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryTextColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { s in
                    SidebarRow(section: s, isSelected: section == s) { section = s }
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: 186)
        .frame(maxHeight: .infinity)
        .background(theme.sidebarColor.opacity(0.45))
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.rawValue)
                        .font(.system(size: 117, weight: .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text(section.subtitle)
                        .font(.system(size: 111))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.secondaryTextColor)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(theme.secondaryTextColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Close settings")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider().opacity(0.2)

            ScrollView {
                Group {
                    switch section {
                    case .appearance: appearancePane
                    case .goals: goalsPane
                    case .data: dataPane
                    case .about: aboutPane
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Appearance

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                title: "Theme",
                icon: "paintpalette",
                footnote: "Pick a preset, then fine-tune it with custom colors below."
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
                    ForEach(ThemePresets.all.keys.sorted(), id: \.self) { name in
                        themePresetButton(name)
                    }
                }
            }

            SettingsCard(title: "Custom Colors", icon: "eyedropper") {
                SettingsRow(title: "Accent") {
                    ColorPicker("Accent color", selection: $customAccent, supportsOpacity: false)
                        .labelsHidden()
                }
                SettingsRowDivider()
                SettingsRow(title: "Background") {
                    ColorPicker("Background color", selection: $customBackground, supportsOpacity: false)
                        .labelsHidden()
                }
                SettingsRowDivider()
                SettingsRow(title: "Sidebar") {
                    ColorPicker("Sidebar color", selection: $customSidebar, supportsOpacity: false)
                        .labelsHidden()
                }
                SettingsRowDivider()
                SettingsRow(title: "Cards") {
                    ColorPicker("Card color", selection: $customCard, supportsOpacity: false)
                        .labelsHidden()
                }
                SettingsRowDivider()
                HStack {
                    Spacer()
                    SettingsPillButton(title: "Apply Custom Theme", icon: "checkmark.circle.fill", prominent: true) {
                        theme.applyCustom(
                            accent: customAccent,
                            background: customBackground,
                            sidebar: customSidebar,
                            card: customCard
                        )
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func themePresetButton(_ name: String) -> some View {
        let preset = ThemePresets.all[name]!
        let isSelected = theme.themeName == name
        return Button { theme.applyTheme(named: name) } label: {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    preset.background
                    preset.card
                    preset.accent
                }
                .frame(height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(name)
                    .font(.system(size: 111, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(theme.titleTextColor)
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? theme.accentColor.opacity(0.15) : theme.cardColor.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? theme.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Goals

    private var goalsPane: some View {
        SettingsCard(
            title: "Writing Goals",
            icon: "target",
            footnote: "Targets appear in the sidebar and drive your streak. Click any target to type a new one — press Return or click away to save."
        ) {
            ForEach(Array(goals.goals.enumerated()), id: \.element.id) { index, goal in
                if index > 0 { SettingsRowDivider() }
                HStack(spacing: 10) {
                    Image(systemName: goal.type.icon)
                        .font(.system(size: 13))
                        .foregroundColor(theme.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(goal.type.rawValue)
                            .font(.system(size: 112, weight: .medium))
                            .foregroundColor(theme.titleTextColor)
                        Text(goal.displayProgress)
                            .font(.system(size: 110))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    Spacer(minLength: 12)
                    GoalTargetField(
                        target: goal.target,
                        unit: goal.type.unit,
                        label: "\(goal.type.rawValue) target"
                    ) { newValue in
                        goals.updateGoal(type: goal.type, target: newValue)
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }

    // MARK: Data

    private var dataPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                title: "Privacy & Security",
                icon: "lock.shield",
                footnote: "Encrypted (AES-256-GCM, key in your Keychain): entry bodies, attachments, and automatic backups. NOT encrypted: titles, tags, moods, timestamps, and word counts — they are stored as plain metadata so search and filtering stay fast. Anyone with access to your Mac account could read those fields. Hidden entries are masked in the app and need Touch ID or your password to reveal."
            ) {
                SettingsRow(
                    title: "Lock hidden entries when I switch apps",
                    subtitle: "Re-masks hidden entries whenever Omega Journal loses focus."
                ) {
                    Toggle("Lock hidden entries when I switch apps", isOn: $lockOnResign)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Export", icon: "square.and.arrow.up") {
                HStack(spacing: 8) {
                    SettingsPillButton(title: "Markdown", icon: "arrow.down.doc") {
                        ImportExportPanels.exportMarkdown(vm: vm)
                    }
                    SettingsPillButton(title: "JSON", icon: "curlybraces") {
                        ImportExportPanels.exportJSON(vm: vm)
                    }
                    SettingsPillButton(title: "PDF", icon: "doc.richtext") {
                        ImportExportPanels.exportPDF(vm: vm)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }

            SettingsCard(
                title: "Import",
                icon: "square.and.arrow.down",
                footnote: "Accepts a JSON backup exported from Omega Journal, or a set of markdown files."
            ) {
                HStack {
                    SettingsPillButton(title: "Import Entries…", icon: "tray.and.arrow.down") {
                        ImportExportPanels.showImportPanel(vm: vm)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }

            SettingsCard(title: "Storage", icon: "internaldrive") {
                SettingsValueRow(title: "Entries", value: "\(vm.entries.count)")
                SettingsRowDivider()
                SettingsValueRow(title: "Archived", value: "\(vm.archivedEntries.count)")
                SettingsRowDivider()
                SettingsValueRow(title: "In Trash", value: "\(vm.trashedEntries.count)")
                SettingsRowDivider()
                SettingsValueRow(title: "Total words", value: vm.totalWordCount.formatted())
                SettingsRowDivider()
                SettingsRow(
                    title: "Database",
                    subtitle: "~/Library/Application Support/OmegaJournal"
                ) {
                    SettingsPillButton(title: "Reveal in Finder", icon: "folder") {
                        NSWorkspace.shared.open(
                            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("OmegaJournal")
                        )
                    }
                }
            }

            if !vm.trashedEntries.isEmpty {
                SettingsCard(title: "Danger Zone", icon: "exclamationmark.triangle") {
                    SettingsRow(
                        title: "Empty Trash",
                        subtitle: "Permanently delete \(vm.trashedEntries.count) \(vm.trashedEntries.count == 1 ? "entry" : "entries") and their attachments."
                    ) {
                        SettingsPillButton(title: "Empty Trash", icon: "trash", destructive: true) {
                            showEmptyTrashConfirmation = true
                        }
                    }
                }
            }
        }
    }

    // MARK: About

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor, theme.accentColor.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)
                    Text("Ω")
                        .font(.system(size: 116, weight: .bold, design: .serif))
                        .foregroundColor(theme.onAccentColor)
                }
                Text("Omega Journal")
                    .font(.system(size: 117, weight: .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text("A fast, private, local-first journal for macOS.")
                    .font(.system(size: 111))
                    .foregroundColor(theme.secondaryTextColor)
                Text("Version \(appVersion)")
                    .font(.system(size: 110, design: .rounded))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            SettingsCard(title: "Keyboard Shortcuts", icon: "keyboard") {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 6
                ) {
                    shortcut("⌘N", "New entry")
                    shortcut("⇧⌘N", "New from template")
                    shortcut("⌥⌘N", "New from today's prompt")
                    shortcut("⌘K", "Command palette")
                    shortcut("⌘F", "Find (in entry or list)")
                    shortcut("⌥⌘F", "Search all entries")
                    shortcut("⌘,", "Settings")
                    shortcut("⌘[ / ⌘]", "Previous / next entry")
                    shortcut("⌘E", "Edit selected entry")
                    shortcut("⌃⌘F", "Zen mode")
                    shortcut("⌘B / ⌘I", "Bold / Italic")
                    shortcut("⌘1…⌘4", "Today / Journal / Calendar / Insights")
                    shortcut("⌘⏎", "Finish editing")
                    shortcut("⎋", "Close editor or palette")
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 110, design: .rounded))
                .foregroundColor(theme.bodyTextColor)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.secondaryTextColor.opacity(0.13)))
            Text(label)
                .font(.system(size: 111))
                .foregroundColor(theme.secondaryTextColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}

// MARK: - Settings card

/// The one container for settings content: a small section header (icon chip +
/// name) above a rounded card body, with an optional footnote underneath.
/// Build every settings pane from these so new areas stay consistent.
private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var footnote: String?
    let content: Content

    @ObservedObject private var theme = ThemeManager.shared

    init(
        title: String,
        icon: String,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.accentColor.opacity(0.14))
                    )
                Text(title)
                    .font(.system(size: 111, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(theme.secondaryTextColor)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardColor.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        theme.colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08),
                        lineWidth: 1
                    )
            )

            if let footnote {
                Text(footnote)
                    .font(.system(size: 110))
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.leading, 2)
            }
        }
    }
}

// MARK: - Settings rows

/// Standard settings row: label (+ optional subtitle/icon) on the left, any
/// trailing control on the right. Pair with `SettingsRowDivider` between rows.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    let trailing: Trailing

    @ObservedObject private var theme = ThemeManager.shared

    init(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 112, weight: .medium))
                    .foregroundColor(theme.titleTextColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 110))
                        .foregroundColor(theme.secondaryTextColor)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 5)
    }
}

/// Read-only label/value row for stats and metadata.
private struct SettingsValueRow: View {
    let title: String
    let value: String

    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 111))
                .foregroundColor(theme.secondaryTextColor)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 111, design: .rounded))
                .foregroundColor(theme.bodyTextColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }
}

/// Hairline between rows inside a `SettingsCard`.
private struct SettingsRowDivider: View {
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Rectangle()
            .fill(theme.secondaryTextColor.opacity(0.12))
            .frame(height: 1)
    }
}

// MARK: - Settings pill button

/// Capsule action button used across settings. `prominent` fills with the
/// accent color for primary actions; `destructive` tints red.
private struct SettingsPillButton: View {
    let title: String
    let icon: String
    var prominent: Bool = false
    var destructive: Bool = false
    let action: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 111, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(background))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovered)
    }

    private var foreground: Color {
        if destructive { return Color.red.opacity(isHovered ? 1.0 : 0.9) }
        if prominent { return .white }
        return theme.accentColor
    }

    private var background: Color {
        if destructive { return Color.red.opacity(isHovered ? 0.22 : 0.13) }
        if prominent { return theme.accentColor.opacity(isHovered ? 1.0 : 0.85) }
        return theme.accentColor.opacity(isHovered ? 0.22 : 0.14)
    }
}

// MARK: - Goal target field

/// Click-to-edit numeric field for goal targets. Commits on Return or when
/// focus leaves; values clamp to 1...10000. Replaces the old Stepper, whose
/// arrows silently failed and looked out of place.
private struct GoalTargetField: View {
    let target: Int
    let unit: String
    var label: String = "Target"
    let onCommit: (Int) -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var text: String
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    init(
        target: Int,
        unit: String,
        label: String = "Target",
        onCommit: @escaping (Int) -> Void
    ) {
        self.target = target
        self.unit = unit
        self.label = label
        self.onCommit = onCommit
        self._text = State(initialValue: String(target))
    }

    var body: some View {
        HStack(spacing: 5) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 112, weight: .semibold, design: .rounded))
                .foregroundColor(theme.titleTextColor)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .focused($isFocused)
                .onSubmit(commit)
            Text(unit)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryTextColor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.secondaryTextColor.opacity(isFocused ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? theme.accentColor.opacity(0.7)
                        : theme.secondaryTextColor.opacity(isHovered ? 0.28 : 0.16),
                    lineWidth: 1
                )
        )
        .onHover { isHovered = $0 }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .onChange(of: target) { _, newValue in
            // Keep the field in sync when the target changes elsewhere,
            // without stomping on in-progress typing.
            if !isFocused, text != "\(newValue)" { text = "\(newValue)" }
        }
        .accessibilityLabel(label)
    }

    private func commit() {
        // Digits-only parse so values pasted with separators ("1,500") work.
        let parsed = Int(text.filter(\.isNumber)) ?? target
        let clamped = max(1, min(parsed, 10000))
        text = "\(clamped)"
        if clamped != target {
            onCommit(clamped)
        }
    }
}

// MARK: - Sidebar row

/// Navigation row for the settings sidebar: icon + label with selected and
/// hover states.
private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryTextColor)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 111, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.titleTextColor : theme.bodyTextColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? theme.accentColor.opacity(0.16)
                            : (isHovered ? theme.secondaryTextColor.opacity(0.08) : .clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
