import SwiftUI
import OmegaJournalCore

// MARK: - Settings sections

/// Settings navigation destinations. Which cards each pane shows (and in what
/// order) comes from `SettingsCatalog` in OmegaJournalCore. To add a setting:
///   1. Add a `SettingsCardID` case there (group, title, icon, storage keys)
///   2. Render it in `SettingsView.cardView(_:)` from `SettingsCard` + rows
/// The sidebar entry, header and pane placement follow automatically.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case goals = "Writing"
    case privacy = "Privacy & Security"
    case data = "Data & Backups"
    case about = "About"

    var id: String { rawValue }

    var group: SettingsGroup {
        switch self {
        case .appearance: .appearance
        case .goals: .writing
        case .privacy: .privacy
        case .data: .data
        case .about: .about
        }
    }

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
        case .appearance: "Theme, colors, and how entries read"
        case .goals: "Daily goals, quick capture, and reviews"
        case .privacy: "Encryption, app lock, hidden entries, and Spotlight"
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
    /// back into its own size) and captured once per presentation. When the app
    /// is not active (Settings opened from the menu while another app is key)
    /// there is no main/key window; fall back to any visible journal window and
    /// then to the minimum window size — never a guessed larger size, which made
    /// the sheet hang off the bottom of a small window.
    static var preferredSize: CGSize {
        let focused = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 }.map { $0.sheetParent ?? $0 }
        let visible = NSApp.windows.filter {
            $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) && $0.styleMask.contains(.titled)
        }
        return SettingsSheetSizing.size(forHost: (focused + visible).first?.frame.size)
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
                VStack(alignment: .leading, spacing: 18) {
                    if section == .about { aboutHeader }
                    ForEach(SettingsCatalog.cards(in: section.group)) { card in
                        cardView(card)
                    }
                }
                .padding(20)
            }
            // New identity per pane: switching panes starts at the top instead of
            // keeping the previous pane's scroll offset.
            .id(section)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Cards

    /// One settings card; placement and order come from `SettingsCatalog`.
    @ViewBuilder
    private func cardView(_ card: SettingsCardID) -> some View {
        switch card {
        case .theme: themeCard(card)
        case .systemAppearance: systemAppearanceCard(card)
        case .reading: readingCard(card)
        case .customColors: customColorsCard(card)
        case .writingGoals: goalsCard(card)
        case .quickCapture: quickCaptureCard(card)
        case .reviewReminders: ReviewRemindersPanel()
        case .periodicReview: PeriodicReviewPanel(vm: vm)
        case .aiAssist: AIAssistPanel()
        case .whatsProtected: protectionCard(card)
        case .appLock: AppLockPanel()
        case .hiddenEntries: hiddenEntriesCard(card)
        case .backups: BackupPanel(vm: vm)
        case .export: exportCard(card)
        case .moreExports: MoreExportsPanel(vm: vm)
        case .encryptedExport: EncryptedExportPanel(vm: vm)
        case .importEntries: importCard(card)
        case .importOtherApps: ImportOtherAppsPanel(vm: vm)
        case .storage: storageCard(card)
        case .dangerZone: if !vm.trashedEntries.isEmpty { emptyTrashCard(card) }
        case .shortcuts: shortcutsCard(card)
        }
    }

    // MARK: Appearance

    private func themeCard(_ card: SettingsCardID) -> some View {
        SettingsCard(
            title: card.title,
            icon: card.icon,
            footnote: "Each card previews the sidebar, an entry card and the accent color. Use Custom Colors below to make your own."
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
    }

    private func systemAppearanceCard(_ card: SettingsCardID) -> some View {
        SettingsCard(
            title: card.title,
            icon: card.icon,
            footnote: "When on, Omega Journal switches between your light and dark theme whenever macOS does."
        ) {
            SettingsRow(title: "Match macOS light and dark mode") {
                Toggle("Match macOS light and dark mode", isOn: Binding(
                    get: { theme.followSystem },
                    set: { theme.setFollowSystem($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if theme.followSystem {
                SettingsRowDivider()
                SettingsRow(title: "Theme in light mode") {
                    Picker("Theme in light mode", selection: Binding(
                        get: { theme.lightPresetName },
                        set: { theme.setPair(light: $0) }
                    )) {
                        ForEach(ThemePresets.lightPresets) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                SettingsRowDivider()
                SettingsRow(title: "Theme in dark mode") {
                    Picker("Theme in dark mode", selection: Binding(
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
    }

    private func readingCard(_ card: SettingsCardID) -> some View {
        SettingsCard(
            title: card.title,
            icon: card.icon,
            footnote: "Applies when reading an entry. A narrower column is easier on the eyes for long entries."
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
    }

    private func customColorsCard(_ card: SettingsCardID) -> some View {
        SettingsCard(title: card.title, icon: card.icon) {
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

    // MARK: Writing

    private func goalsCard(_ card: SettingsCardID) -> some View {
        SettingsCard(
            title: card.title,
            icon: card.icon,
            footnote: "Your progress shows on Today. Click a target to type a new one, then press Return or click away to save."
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

    private func quickCaptureCard(_ card: SettingsCardID) -> some View {
        SettingsCard(
            title: card.title,
            icon: card.icon,
            footnote: "Quick notes are saved as normal entries tagged #quick."
        ) {
            SettingsRow(
                title: "Menu bar quick capture",
                subtitle: "Jot a thought from the menu bar without opening the journal."
            ) {
                Toggle("Menu bar quick capture", isOn: $menuBarQuickCapture)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsRow(
                title: "New-entry shortcut from any app (⌥⌘J)",
                subtitle: "Opens Omega Journal with a fresh entry."
            ) {
                Toggle("New-entry shortcut from any app", isOn: $globalHotkeyEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: globalHotkeyEnabled) { _, _ in GlobalHotkey.shared.syncRegistration() }
            }
        }
    }

    // MARK: Privacy

    private func protectionCard(_ card: SettingsCardID) -> some View {
        SettingsCard(title: card.title, icon: card.icon) {
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
    }

    private func hiddenEntriesCard(_ card: SettingsCardID) -> some View {
        SettingsCard(
            title: card.title,
            icon: card.icon,
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

    // MARK: Data

    private func exportCard(_ card: SettingsCardID) -> some View {
        SettingsCard(
            title: card.title,
            icon: card.icon,
            footnote: "JSON is a complete backup you can import again later. Markdown and PDF are for reading or sharing."
        ) {
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
    }

    private func importCard(_ card: SettingsCardID) -> some View {
        SettingsCard(
            title: card.title,
            icon: card.icon,
            footnote: "Accepts a JSON backup exported from Omega Journal, or a set of Markdown files."
        ) {
            HStack {
                SettingsPillButton(title: "Import Entries…", icon: "tray.and.arrow.down") {
                    ImportExportPanels.showImportPanel(vm: vm)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
        }
    }

    private func storageCard(_ card: SettingsCardID) -> some View {
        SettingsCard(title: card.title, icon: card.icon) {
            SettingsValueRow(title: "Entries", value: "\(vm.entries.count)")
            SettingsRowDivider()
            SettingsValueRow(title: "Archived", value: "\(vm.archivedEntries.count)")
            SettingsRowDivider()
            SettingsValueRow(title: "In Trash", value: "\(vm.trashedEntries.count)")
            SettingsRowDivider()
            SettingsValueRow(title: "Total words", value: vm.totalWordCount.formatted())
            SettingsRowDivider()
            // The journal this window actually uses (a relocated or test
            // database lives elsewhere — never point at a hard-coded folder).
            SettingsRow(
                title: "Journal location",
                subtitle: SettingsStorageLocation.displayFolder(forDatabasePath: vm.db.dbPath)
            ) {
                SettingsPillButton(title: "Show in Finder", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: vm.db.dbPath)])
                }
            }
        }
    }

    private func emptyTrashCard(_ card: SettingsCardID) -> some View {
        SettingsCard(title: card.title, icon: card.icon) {
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

    // MARK: About

    private var aboutHeader: some View {
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
    }

    private func shortcutsCard(_ card: SettingsCardID) -> some View {
        SettingsCard(title: card.title, icon: card.icon) {
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
