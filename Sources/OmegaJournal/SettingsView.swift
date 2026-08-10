import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings View

struct SettingsView: View {
    @State private var dbPath = DatabaseManager.shared.databasePath

    var body: some View {
        TabView {
            Form {
                LabeledContent("Database location") {
                    VStack(alignment: .trailing) {
                        Text(dbPath).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (dbPath as NSString).deletingLastPathComponent) }
                    }
                }
                LabeledContent("Total entries") { Text("\(DatabaseManager.shared.entryCount())") }
            }
            .tabItem { Label("General", systemImage: "gear") }

            ThemesTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            ExportTab()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }

            GoalsSettingsTab()
                .tabItem { Label("Goals", systemImage: "target") }

            NotificationsTab()
                .tabItem { Label("Reminders", systemImage: "bell") }

            BackupTab()
                .tabItem { Label("Backup", systemImage: "externaldrive") }

            TagsSettingsTab()
                .tabItem { Label("Tags", systemImage: "tag") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Themes Tab

struct ThemesTab: View {
    @ObservedObject private var theme = ThemeManager.shared
    @State private var accent: Color = .accentColor
    @State private var background: Color = .black
    @State private var sidebar: Color = .black
    @State private var card: Color = .gray

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(ThemePresets.all.keys).sorted(), id: \.self) { name in
                            presetButton(name)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("Preset themes", systemImage: "swatchpalette")
                        .font(.system(size: 13, weight: .medium))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        ColorPicker("Accent", selection: $accent, supportsOpacity: false)
                        ColorPicker("Background", selection: $background, supportsOpacity: false)
                        ColorPicker("Sidebar", selection: $sidebar, supportsOpacity: false)
                        ColorPicker("Card", selection: $card, supportsOpacity: false)
                        Text("Custom colors save automatically as a 'Custom' theme.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("Custom colors", systemImage: "eyedropper")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .padding(20)
        }
        .onAppear {
            accent = theme.accentColor
            background = theme.backgroundColor
            sidebar = theme.sidebarColor
            card = theme.cardColor
        }
        .onChange(of: accent) { _, _ in applyCustom() }
        .onChange(of: background) { _, _ in applyCustom() }
        .onChange(of: sidebar) { _, _ in applyCustom() }
        .onChange(of: card) { _, _ in applyCustom() }
    }

    private func applyCustom() {
        theme.applyCustom(accent: accent, background: background, sidebar: sidebar, card: card)
    }

    private func presetButton(_ name: String) -> some View {
        let preset = ThemePresets.all[name]!
        let selected = theme.themeName == name
        return Button {
            theme.applyTheme(named: name)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    HStack(spacing: 3) {
                        ForEach(preset.swatchColors, id: \.self) { c in
                            Circle()
                                .fill(c)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                        }
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.accentColor)
                        .font(.system(size: 14))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OmegaTheme.cardRadius)
                    .strokeBorder(
                        selected ? theme.accentColor : Color.secondary.opacity(0.12),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Export Tab

struct ExportTab: View {
    @State private var exportMessage = ""
    @State private var showDateRange = false
    @State private var exportAllTime = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export your journal entries.")
                        .font(.system(size: 13))
                    Toggle("Export all entries", isOn: $exportAllTime)
                        .font(.system(size: 13))
                    HStack(spacing: 12) {
                        Button {
                            exportAs(.markdown)
                        } label: {
                            Label("Markdown", systemImage: "doc.text")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            exportAs(.json)
                        } label: {
                            Label("JSON", systemImage: "curlybraces")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.bordered)

                        Button {
                            exportAs(.pdf)
                        } label: {
                            Label("PDF", systemImage: "doc.richtext")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                    if !exportMessage.isEmpty {
                        Text(exportMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
            } label: {
                Label("Export journal", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(20)
    }

    private enum ExportFormat {
        case markdown, json, pdf
    }

    private func exportAs(_ format: ExportFormat) {
        let entries = DatabaseManager.shared.fetchAllEntriesForExport()

        switch format {
        case .markdown:
            let panel = NSSavePanel()
            panel.title = "Export as Markdown"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "Omega-Journal-Export.md"
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try ExportManager.exportMarkdown(entries, to: url)
                    exportMessage = "Exported \(entries.count) entries to \(url.lastPathComponent)"
                } catch {
                    exportMessage = "Export failed: \(error.localizedDescription)"
                }
            }

        case .json:
            let panel = NSSavePanel()
            panel.title = "Export as JSON"
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Omega-Journal-Export.json"
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try ExportManager.exportJSON(entries, to: url)
                    exportMessage = "Exported \(entries.count) entries to \(url.lastPathComponent)"
                } catch {
                    exportMessage = "Export failed: \(error.localizedDescription)"
                }
            }

        case .pdf:
            let panel = NSSavePanel()
            panel.title = "Export as PDF"
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "Omega-Journal-Export.pdf"
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try ExportManager.exportPDF(entries, to: url)
                    exportMessage = "Exported \(entries.count) entries to \(url.lastPathComponent)"
                } catch {
                    exportMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Goals Settings Tab

struct GoalsSettingsTab: View {
    @ObservedObject private var goals = GoalManager.shared
    @ObservedObject private var theme = ThemeManager.shared
    @State private var dailyWords = ""
    @State private var dailyEntries = ""
    @State private var weeklyEntries = ""
    @State private var weeklyWords = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Daily word goal") {
                    TextField("250", text: $dailyWords)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveGoal(.dailyWords, dailyWords) }
                }
                LabeledContent("Daily entry goal") {
                    TextField("1", text: $dailyEntries)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveGoal(.dailyEntries, dailyEntries) }
                }
                LabeledContent("Weekly entry goal") {
                    TextField("5", text: $weeklyEntries)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveGoal(.weeklyEntries, weeklyEntries) }
                }
                LabeledContent("Weekly word goal") {
                    TextField("1500", text: $weeklyWords)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveGoal(.weeklyWords, weeklyWords) }
                }
            } header: {
                Text("Writing Goals")
            } footer: {
                Text("Goals are tracked daily and weekly. Progress resets automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Current progress
            Section("Current Progress") {
                ForEach(goals.goals) { goal in
                    HStack {
                        Image(systemName: goal.type.icon)
                            .foregroundColor(theme.accentColor)
                            .frame(width: 20)
                        Text(goal.type.rawValue)
                        Spacer()
                        Text(goal.displayProgress)
                            .foregroundColor(.secondary)
                        if goal.isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            let db = DatabaseManager.shared
            dailyWords = db.getSetting("goal_dailyWords", defaultValue: "250")
            dailyEntries = db.getSetting("goal_dailyEntries", defaultValue: "1")
            weeklyEntries = db.getSetting("goal_weeklyEntries", defaultValue: "5")
            weeklyWords = db.getSetting("goal_weeklyWords", defaultValue: "1500")
        }
    }

    private func saveGoal(_ type: WritingGoal.GoalType, _ value: String) {
        if let target = Int(value), target > 0 {
            GoalManager.shared.updateGoal(type: type, target: target)
        }
    }
}

// MARK: - Notifications Tab

struct NotificationsTab: View {
    @ObservedObject private var notifications = NotificationManager.shared
    @State private var hour: Int = 20
    @State private var minute: Int = 0

    var body: some View {
        Form {
            Section {
                Toggle("Daily writing reminder", isOn: Binding(
                    get: { notifications.reminderEnabled },
                    set: { notifications.setReminder(enabled: $0) }
                ))

                if notifications.reminderEnabled {
                    DatePicker("Reminder time",
                               selection: Binding(
                                   get: { buildDate() },
                                   set: { date in
                                       let cal = Calendar.current
                                       hour = cal.component(.hour, from: date)
                                       minute = cal.component(.minute, from: date)
                                       notifications.setReminder(enabled: true, hour: hour, minute: minute)
                                   }
                               ),
                               displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("Get a daily prompt notification to keep your writing habit going.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    if notifications.isAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Notifications enabled")
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.orange)
                        Text("Notifications not authorized")
                        Spacer()
                        Button("Grant Permission") {
                            notifications.requestPermission()
                        }
                    }
                }

                Button("Test Notification") {
                    notifications.testNotification()
                }
                .disabled(!notifications.isAuthorized)
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            hour = notifications.reminderHour
            minute = notifications.reminderMinute
        }
    }

    private func buildDate() -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }
}

// MARK: - Backup Tab

struct BackupTab: View {
    @State private var backupMessage = ""
    @State private var backupPath = ""
    @State private var isBackingUp = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "externaldrive.fill")
                        .foregroundColor(theme.accentColor)
                    Text("Auto-backup runs once per day on app launch.")
                        .font(.system(size: 13))
                }

                LabeledContent("Last backup") {
                    Text(DatabaseManager.shared.getSetting("lastBackupDate", defaultValue: "Never"))
                        .foregroundColor(.secondary)
                }

                Button {
                    performBackup()
                } label: {
                    if isBackingUp {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Backup Now", systemImage: "arrow.down.doc.fill")
                    }
                }
                .disabled(isBackingUp)

                if !backupMessage.isEmpty {
                    Text(backupMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Database Backup")
            } footer: {
                Text("Backups are stored in ~/Library/Application Support/OmegaJournal/backups/. The last 7 backups are kept.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Show Backups in Finder") {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let backupDir = appSupport.appendingPathComponent("OmegaJournal/backups", isDirectory: true)
                    try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(backupDir)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func performBackup() {
        isBackingUp = true
        Task {
            if let url = DatabaseManager.shared.backupDatabase() {
                backupMessage = "Backup saved to \(url.lastPathComponent)"
            } else {
                backupMessage = "Backup failed"
            }
            isBackingUp = false
        }
    }
}

// MARK: - Tags Settings Tab

struct TagsSettingsTab: View {
    @ObservedObject private var theme = ThemeManager.shared
    @State private var tags: [(tag: String, count: Int)] = []
    @State private var editingTag: String?
    @State private var editName = ""
    @State private var showDeleteConfirm = false
    @State private var tagToDelete: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage Tags")
                .font(.system(size: 15, weight: .semibold))
            Text("Rename or delete tags across all entries.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            if tags.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tag.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No tags yet")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(tags, id: \.tag) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "number")
                                .foregroundColor(theme.accentColor.opacity(0.7))
                                .font(.system(size: 11))
                                .frame(width: 16)

                            if editingTag == item.tag {
                                TextField("Tag name", text: $editName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)
                                    .onSubmit { renameTag(from: item.tag, to: editName) }
                                Button("Save") { renameTag(from: item.tag, to: editName) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                Button("Cancel") { editingTag = nil }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(item.tag)
                                    .font(.system(size: 13))
                                Spacer()
                                Text("\(item.count) \(item.count == 1 ? "entry" : "entries")")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Button {
                                    editingTag = item.tag
                                    editName = item.tag
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                Button {
                                    tagToDelete = item.tag
                                    showDeleteConfirm = true
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.red.opacity(0.7))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .onAppear { loadTags() }
        .alert("Delete Tag", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let tag = tagToDelete {
                    DatabaseManager.shared.deleteTag(tag)
                    loadTags()
                }
            }
        } message: {
            Text("Are you sure you want to delete the tag \"\(tagToDelete ?? "")\"? It will be removed from all entries.")
        }
    }

    private func loadTags() {
        tags = DatabaseManager.shared.tagsWithCounts()
    }

    private func renameTag(from old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != old else { editingTag = nil; return }
        DatabaseManager.shared.renameTag(from: old, to: trimmed)
        editingTag = nil
        loadTags()
    }
}
