import SwiftUI
import OmegaJournalCore

// MARK: - Settings sections

/// Settings navigation destinations. To add a new settings area:
///   1. Add a case here — `title`, `icon`, and `subtitle` come from the enum
///   2. Build its pane from `SettingsCard` + the row components below
///   3. Add the case to the switch in `SettingsView.content`
/// Everything else (sidebar entry, header, styling) is automatic.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case goals = "Writing"
    case privacy = "Privacy & Security"
    case data = "Data & Backups"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .goals: "target"
        case .privacy: "lock.shield.fill"
        case .data: "externaldrive.fill"
        case .about: "info.circle.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: "Themes, colors, and personalization"
        case .goals: "Goals, reminders, and quick capture"
        case .privacy: "Encryption, hidden entries, and Spotlight"
        case .data: "Backups, export, import, and storage"
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
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlightTitles = false
    @AppStorage(GlobalHotkey.enabledKey) private var globalHotkeyEnabled = true
    @AppStorage(ReadingPreferences.maxWidthKey) private var readingMaxWidth = ReadingPreferences.defaultMaxWidth
    @AppStorage(ReadingPreferences.fontDesignKey) private var readingFontDesign = "default"
    @AppStorage(ReadingPreferences.showCoverKey) private var readingShowCover = true
    @AppStorage(QuickCapture.insertedKey) private var menuBarQuickCapture = true

    /// Sized from the journal window (never the sheet itself, which would feed
    /// back into its own size) and captured once per presentation.
    static var preferredSize: CGSize {
        let candidates = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 }
        let host = candidates.map { $0.sheetParent ?? $0 }.first?.frame.size ?? CGSize(width: 1100, height: 760)
        return CGSize(width: min(900, max(680, host.width - 120)),
                      height: min(760, max(540, host.height - 100)))
    }

    @State private var sheetSize = SettingsView.preferredSize

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
        // Use the room the main window offers (the old fixed 680×540 sheet hid
        // most theme cards and data controls below the fold).
        .frame(width: sheetSize.width, height: sheetSize.height)
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
                        .font(OmegaTheme.font(.bodyLarge, .bold, design: .serif))
                        .foregroundColor(theme.onAccentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Settings")
                        .font(OmegaTheme.font(.body, .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text("Omega Journal")
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { s in
                    SettingsSidebarRow(section: s, isSelected: section == s) { section = s }
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
                        .font(OmegaTheme.font(.heading, .semibold))
                        .foregroundColor(theme.titleTextColor)
                    Text(section.subtitle)
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(OmegaTheme.font(.meta, .bold))
                        .foregroundColor(theme.secondaryTextColor)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(theme.secondaryTextColor.opacity(0.12)))
                }
                .accessibilityLabel("Close")
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
                    case .goals:
                        VStack(alignment: .leading, spacing: 18) { goalsPane; quickCaptureCard; ReflectionSettingsPanels(vm: vm) }
                    case .privacy: privacyPane
                    case .data:
                        VStack(alignment: .leading, spacing: 18) { dataPane; DataSafetyPanels(vm: vm) }
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
                footnote: "Pick a preset. Each card previews the sidebar, a card and the accent. Use Custom Colors below for your own."
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(ThemePresets.all) { preset in
                        themePresetButton(preset)
                    }
                }
                if let preset = theme.currentPreset {
                    SettingsRowDivider()
                    SettingsRow(
                        title: "Accent override",
                        subtitle: theme.accentOverrides[preset.name] == nil ? "Using \(preset.name)'s default accent" : "Custom accent for \(preset.name)"
                    ) {
                        HStack(spacing: 8) {
                            ColorPicker("Accent for \(preset.name)", selection: accentOverrideBinding(for: preset), supportsOpacity: false)
                                .labelsHidden()
                            if theme.accentOverrides[preset.name] != nil {
                                SettingsPillButton(title: "Reset", icon: "arrow.counterclockwise", prominent: false) {
                                    theme.setAccentOverride(nil, for: preset.name)
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard(
                title: "System Appearance",
                icon: "circle.lefthalf.filled",
                footnote: "When on, Omega Journal switches between your light and dark preset as macOS does."
            ) {
                SettingsRow(title: "Follow system appearance") {
                    Toggle("Follow system appearance", isOn: Binding(
                        get: { theme.followSystem },
                        set: { theme.setFollowSystem($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                if theme.followSystem {
                    SettingsRowDivider()
                    SettingsRow(title: "Light preset") {
                        Picker("Light preset", selection: Binding(
                            get: { theme.lightPresetName },
                            set: { theme.setPair(light: $0) }
                        )) {
                            ForEach(ThemePresets.lightPresets) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    SettingsRowDivider()
                    SettingsRow(title: "Dark preset") {
                        Picker("Dark preset", selection: Binding(
                            get: { theme.darkPresetName },
                            set: { theme.setPair(dark: $0) }
                        )) {
                            ForEach(ThemePresets.darkPresets) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
            }

            SettingsCard(
                title: "Reading",
                icon: "textformat",
                footnote: "Applies to the entry reader. A narrower column is easier on the eyes for long entries."
            ) {
                SettingsRow(title: "Font style") {
                    Picker("Reading font style", selection: $readingFontDesign) {
                        ForEach(ReadingPreferences.fontDesignOptions, id: \.raw) { option in
                            Text(option.label).tag(option.raw)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                SettingsRowDivider()
                SettingsRow(title: "Cover image", subtitle: "Show an entry's first image above its title") {
                    Toggle("Show cover image", isOn: $readingShowCover).labelsHidden().toggleStyle(.switch)
                }
                SettingsRowDivider()
                SettingsRow(title: "Maximum width", subtitle: "\(Int(ReadingPreferences.clampedWidth(readingMaxWidth))) pt") {
                    Slider(value: $readingMaxWidth, in: ReadingPreferences.widthRange, step: 20)
                        .frame(width: 200)
                        .accessibilityLabel("Reading maximum width")
                }
            }

            SettingsCard(
                title: "Quick Capture",
                icon: "square.and.pencil",
                footnote: "Jot a thought from the menu bar. It is saved as a normal entry tagged #quick."
            ) {
                SettingsRow(title: "Show menu bar quick capture") {
                    Toggle("Show menu bar quick capture", isOn: $menuBarQuickCapture)
                        .labelsHidden()
                        .toggleStyle(.switch)
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
                if customContrast < ContrastChecker.minimumBodyRatio {
                    SettingsRowDivider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.warningColor)
                            .accessibilityHidden(true)
                        Text("Low contrast: body text on these colors is \(String(format: "%.1f", customContrast)):1 (WCAG recommends at least 4.5:1). Try a darker or lighter background.")
                            .font(OmegaTheme.metaFont)
                            .foregroundColor(theme.warningColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
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

    private var customContrast: Double {
        ThemeManager.contrast(background: customBackground, sidebar: customSidebar, card: customCard)
    }

    private func accentOverrideBinding(for preset: ThemePreset) -> Binding<Color> {
        Binding(
            get: { theme.accentOverride(for: preset.name) ?? Color(hex: preset.accent) ?? theme.accentColor },
            set: { theme.setAccentOverride($0, for: preset.name) }
        )
    }

    /// Swatch card with a live mini-preview (sidebar, card, text lines, accent).
    private func themePresetButton(_ preset: ThemePreset) -> some View {
        let isSelected = theme.themeName == preset.name
        let accent = Color(hex: theme.effectiveAccentHex(for: preset)) ?? theme.accentColor
        let bg = Color(hex: preset.background) ?? .black
        let sidebar = Color(hex: preset.sidebar) ?? .black
        let card = Color(hex: preset.card) ?? .black
        let text = Color(hex: preset.body) ?? .white
        let secondary = Color(hex: preset.secondary) ?? .gray
        return Button { theme.applyTheme(named: preset.name) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 26)
                        .overlay(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Capsule().fill(accent).frame(width: 14, height: 4)
                                Capsule().fill(secondary.opacity(0.6)).frame(width: 14, height: 3)
                                Capsule().fill(secondary.opacity(0.6)).frame(width: 10, height: 3)
                            }
                            .padding(.top, 8)
                        }
                    ZStack(alignment: .topLeading) {
                        bg
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().fill(text).frame(width: 46, height: 5)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(card)
                                .frame(height: 24)
                                .overlay(alignment: .leading) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Capsule().fill(text.opacity(0.85)).frame(width: 52, height: 3)
                                        Capsule().fill(secondary).frame(width: 36, height: 3)
                                    }
                                    .padding(.leading, 6)
                                }
                            Capsule().fill(accent).frame(width: 30, height: 6)
                        }
                        .padding(8)
                    }
                }
                .frame(height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.borderColor, lineWidth: 1))

                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(OmegaTheme.font(.caption, isSelected ? .semibold : .medium))
                        .foregroundColor(theme.titleTextColor)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(OmegaTheme.font(.caption))
                            .foregroundColor(theme.accentColor)
                    }
                }
                Text(preset.blurb)
                    .font(OmegaTheme.metaFont)
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(1)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.14) : theme.cardColor.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? theme.accentColor : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) theme, \(preset.isDark ? "dark" : "light")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Goals

    private var goalsPane: some View {
        SettingsCard(
            title: "Writing Goals",
            icon: "target",
            footnote: "Daily targets show as progress on Today. Click any target to type a new one — press Return or click away to save."
        ) {
            ForEach(Array(goals.goals.enumerated()), id: \.element.id) { index, goal in
                if index > 0 { SettingsRowDivider() }
                HStack(spacing: 10) {
                    Image(systemName: goal.type.icon)
                        .font(OmegaTheme.font(.body))
                        .foregroundColor(theme.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(goal.type.rawValue)
                            .font(OmegaTheme.font(.caption, .medium))
                            .foregroundColor(theme.titleTextColor)
                        Text(goal.displayProgress)
                            .font(OmegaTheme.font(.meta))
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

    // MARK: Privacy

    private var privacyPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "What's protected", icon: "lock.doc") {
                SettingsRow(
                    title: "Encrypted on disk",
                    subtitle: "Entry text, attachments, and automatic backups (AES-256-GCM; the key lives in your Keychain)."
                ) { Image(systemName: "checkmark.shield.fill").foregroundColor(.green).accessibilityHidden(true) }
                SettingsRowDivider()
                SettingsRow(
                    title: "Stored as plain metadata",
                    subtitle: "Titles, tags, moods, dates, and word counts — so search and filters stay fast. Anyone signed in to your Mac account could read these."
                ) { Image(systemName: "info.circle").foregroundColor(theme.secondaryTextColor).accessibilityHidden(true) }
            }
            SettingsCard(
                title: "Hidden Entries & Spotlight",
                icon: "lock.shield",
                footnote: "Hidden entries are masked everywhere in the app and need Touch ID or your password to reveal."
            ) {
                SettingsRow(
                    title: "Lock hidden entries when I switch apps",
                    subtitle: "Re-masks hidden entries whenever Omega Journal loses focus."
                ) {
                    Toggle("Lock hidden entries when I switch apps", isOn: $lockOnResign)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRowDivider()
                SettingsRow(
                    title: "Show entry titles in Spotlight",
                    subtitle: "Off by default. Only titles of non-hidden entries are indexed — never bodies or tags."
                ) {
                    Toggle("Show entry titles in Spotlight", isOn: $spotlightTitles)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: spotlightTitles) { _, on in
                            if on { SpotlightIndexer.shared.scheduleReindex(db: vm.db) } else { SpotlightIndexer.shared.removeAll() }
                        }
                }
            }
        }
    }

    // MARK: Writing — quick capture

    private var quickCaptureCard: some View {
        SettingsCard(title: "Quick Capture", icon: "bolt") {
                SettingsRow(
                    title: "Global new-entry hotkey (⌥⌘J)",
                    subtitle: "Opens Omega Journal with a fresh entry from any app."
                ) {
                    Toggle("Global new-entry hotkey", isOn: $globalHotkeyEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: globalHotkeyEnabled) { _, _ in GlobalHotkey.shared.syncRegistration() }
                }
        }
    }

    // MARK: Data

    private var dataPane: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                        .font(OmegaTheme.font(.heading, .bold, design: .serif))
                        .foregroundColor(theme.onAccentColor)
                }
                Text("Omega Journal")
                    .font(OmegaTheme.font(.heading, .semibold))
                    .foregroundColor(theme.titleTextColor)
                Text("A fast, private, local-first journal for macOS.")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                Text("Version \(appVersion)")
                    .font(OmegaTheme.font(.meta, design: .rounded))
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
                .font(OmegaTheme.font(.meta, design: .rounded))
                .foregroundColor(theme.bodyTextColor)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.secondaryTextColor.opacity(0.13)))
            Text(label)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}
