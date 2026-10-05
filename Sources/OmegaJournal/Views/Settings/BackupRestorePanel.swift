import SwiftUI
import AppKit
import OmegaJournalCore

// MARK: - Data safety settings (backup folder, restore, integrity, encrypted export, import, app lock)

struct DataSafetyPanels: View {
    @ObservedObject var vm: JournalViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.l) {
            AppLockPanel()
            BackupPanel(vm: vm)
            ExportImportPanel(vm: vm)
        }
    }
}

private struct PanelCard<Content: View>: View {
    let title: String, icon: String
    var footnote: String?
    @ViewBuilder var content: Content
    @ObservedObject private var theme = ThemeManager.shared
    var body: some View {
        OmegaCard {
            VStack(alignment: .leading, spacing: OmegaTheme.Spacing.m) {
                OmegaSectionHeader(title: title, systemImage: icon)
                content
                if let footnote {
                    Text(footnote).font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: App lock

struct AppLockPanel: View {
    @ObservedObject private var lock = AppLockManager.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        PanelCard(title: "App Lock", icon: "lock.app.dashed",
                  footnote: "Requires Touch ID or your Mac password when Omega Journal opens and after the chosen time away. Separate from the Hidden-entries lock.") {
            Toggle("Lock Omega Journal", isOn: $lock.isEnabled).toggleStyle(.switch)
            if lock.isEnabled {
                Picker("Lock", selection: $lock.timeout) {
                    ForEach(AppLockTimeout.allCases) { Text($0.label).tag($0) }
                }
            }
        }
    }
}

// MARK: Backups

struct BackupPanel: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var folder: URL?
    @State private var backups: [BackupInfo] = []
    @State private var status: String?
    @State private var statusIsError = false
    @State private var pendingRestore: BackupInfo?

    var body: some View {
        PanelCard(title: "Backups", icon: "externaldrive.badge.timemachine",
                  footnote: "Backups are encrypted with your Keychain key and contain entries, tags and check-ins (not attachment files). A copy of each daily backup also goes to the folder you choose — iCloud Drive or an external disk both work. Restoring first snapshots your current journal.") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extra backup folder").font(OmegaTheme.font(.body, .medium)).foregroundColor(theme.titleTextColor)
                    Text(folder?.path ?? "Not set — backups stay on this Mac only")
                        .font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…") { chooseFolder() }
                if folder != nil { Button("Clear") { vm.db.setChosenBackupFolder(nil); refresh() } }
            }
            HStack {
                Button { backupNow() } label: { Label("Back up now", systemImage: "arrow.clockwise.icloud") }
                Button { checkIntegrity() } label: { Label("Check integrity", systemImage: "checkmark.shield") }
                Spacer()
            }
            if let status {
                Text(status).font(OmegaTheme.captionFont)
                    .foregroundColor(statusIsError ? theme.dangerColor : theme.successColor)
            }
            if backups.isEmpty {
                Text("No backups yet.").font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
            } else {
                VStack(spacing: 6) {
                    ForEach(backups.prefix(8)) { b in
                        HStack {
                            Image(systemName: b.isExternal ? "externaldrive" : "internaldrive").foregroundColor(theme.accentColor).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(OmegaTheme.font(.caption, .medium)).foregroundColor(theme.titleTextColor)
                                Text("\(b.kind) · \(ByteCountFormatter.string(fromByteCount: b.bytes, countStyle: .file))\(b.isExternal ? " · extra folder" : "")")
                                    .font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                            }
                            Spacer()
                            Button("Verify") { verify(b) }
                            Button("Restore…") { pendingRestore = b }
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) { if let b = pendingRestore { restore(b) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current journal is snapshotted first (kept in backups as “Before restore”). Entries made after this backup will not be in the restored journal.")
        }
    }

    private func refresh() {
        folder = vm.db.chosenBackupFolder
        backups = vm.db.backupInfos()
    }

    private func report(_ text: String, error: Bool = false) { status = text; statusIsError = error }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder for extra backup copies (iCloud Drive, external disk…)."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            report("That folder isn't writable.", error: true); return
        }
        vm.db.setChosenBackupFolder(url)
        refresh()
        report("Daily backups will also be copied to “\(url.lastPathComponent)”.")
    }

    private func backupNow() {
        if vm.db.backupNow() != nil { report("Backup complete."); refresh() }
        else { report("Backup failed — see the error message.", error: true) }
    }

    private func checkIntegrity() {
        let r = vm.db.integrityReport()
        report(r.ok ? "Integrity check passed — your journal database is healthy." : "Problems found: " + r.details.prefix(3).joined(separator: "; "), error: !r.ok)
    }

    private func verify(_ b: BackupInfo) {
        do {
            let v = try vm.db.verifyBackup(at: b.url)
            report("Backup is valid: \(v.entryCount) entries, schema v\(v.schemaVersion).")
        } catch { report(error.localizedDescription, error: true) }
    }

    private func restore(_ b: BackupInfo) {
        vm.flushBeforeImmediateMutation()
        do {
            try vm.db.restoreBackup(from: b.url)
            vm.reload()
            CheckinStore.shared.reload()
            report("Restored \(b.date.formatted(date: .abbreviated, time: .shortened)).")
            refresh()
        } catch { report(error.localizedDescription, error: true) }
        pendingRestore = nil
    }
}

// MARK: Export / import

struct ExportImportPanel: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var passphrase = ""
    @State private var confirm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.l) {
            PanelCard(title: "More exports", icon: "square.and.arrow.up.on.square",
                      footnote: "Markdown folder: one .md per entry with front matter + attachments folder. Website: self-contained HTML you can open or host anywhere. Hidden entries need authentication to be included.") {
                HStack(spacing: 8) {
                    Button { ImportExportPanels.exportMarkdownFolder(vm: vm) } label: { Label("Markdown folder", systemImage: "folder") }
                    Button { ImportExportPanels.exportHTMLSite(vm: vm) } label: { Label("Static website", systemImage: "globe") }
                    Button { ImportExportPanels.exportEntryPDF(vm: vm) } label: { Label("Selected entry PDF", systemImage: "doc.richtext") }
                    Spacer(minLength: 0)
                }
            }
            PanelCard(title: "Encrypted export", icon: "lock.doc",
                      footnote: "Sealed with AES-256-GCM using a key derived from your passphrase (PBKDF2). Anyone with the file and passphrase can read it — there is no recovery if you forget it.") {
                SecureField("Passphrase", text: $passphrase).textFieldStyle(.roundedBorder)
                SecureField("Repeat passphrase", text: $confirm).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Export…") { ImportExportPanels.exportEncrypted(vm: vm, passphrase: passphrase) }
                        .disabled(passphrase.count < 8 || passphrase != confirm)
                    Button("Import encrypted…") { ImportExportPanels.importEncrypted(vm: vm, passphrase: passphrase) }
                        .disabled(passphrase.isEmpty)
                    Spacer()
                    if !passphrase.isEmpty && passphrase.count < 8 {
                        Text("Use at least 8 characters").font(OmegaTheme.metaFont).foregroundColor(theme.warningColor)
                    }
                }
            }
            PanelCard(title: "Import from other apps", icon: "tray.and.arrow.down",
                      footnote: "Day One: Export → JSON. Obsidian / notes: pick the vault or folder; front-matter title, date and tags are honored and images are attached. Duplicates are skipped and imports are never hidden.") {
                HStack(spacing: 8) {
                    Button { ImportExportPanels.importDayOne(vm: vm) } label: { Label("Day One JSON…", systemImage: "book") }
                    Button { ImportExportPanels.importNotesFolder(vm: vm) } label: { Label("Obsidian / notes folder…", systemImage: "folder.badge.plus") }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: Reflection settings (check-ins, review reminders, AI assist)

struct ReflectionSettingsPanels: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var aiEnabled = SmartAssist.isEnabled()

    var body: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.l) {
            PanelCard(title: "Review reminders", icon: "bell.badge",
                      footnote: "Notifications are generic — they never include entry text. Tapping one lets you save the review as an entry in one click.") {
                ReviewScheduleControls()
            }
            ReviewCard(vm: vm)
            PanelCard(title: "On-device AI assist", icon: "sparkles",
                      footnote: "Off by default. Uses Apple's on-device model only (macOS 26+ with Apple Intelligence) — nothing is sent over the network. Hidden entries are never used.") {
                if SmartAssist.availability.isAvailable {
                    Toggle("Suggest titles, tags and summaries", isOn: $aiEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: aiEnabled) { _, on in SmartAssist.setEnabled(on) }
                } else if case .unavailable(let why) = SmartAssist.availability {
                    Text(why).font(OmegaTheme.captionFont).foregroundColor(theme.secondaryTextColor)
                }
            }
        }
    }
}
