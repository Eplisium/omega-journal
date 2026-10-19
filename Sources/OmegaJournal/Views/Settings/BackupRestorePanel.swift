import SwiftUI
import AppKit
import OmegaJournalCore

// MARK: - Data safety settings (backup folder, restore, integrity, exports, imports, app lock)
//
// Each panel is one `SettingsCard` placed by `SettingsCatalog` (Privacy holds App
// Lock; Data holds the rest), so these share the look of every other settings card.

private struct PanelCard<Content: View>: View {
    let card: SettingsCardID
    var footnote: String?
    @ViewBuilder var content: Content
    var body: some View {
        SettingsCard(title: card.title, icon: card.icon, footnote: footnote) {
            VStack(alignment: .leading, spacing: OmegaTheme.Spacing.m) { content }
                .padding(.vertical, 3)
        }
    }
}

// MARK: App lock

struct AppLockPanel: View {
    @ObservedObject private var lock = AppLockManager.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        PanelCard(card: .appLock,
                  footnote: "Separate from the hidden-entries lock: this locks the whole app.") {
            SettingsRow(title: "Lock Omega Journal",
                        subtitle: "Ask for Touch ID or your Mac password when the app opens and after time away.") {
                Toggle("Lock Omega Journal", isOn: $lock.isEnabled).labelsHidden().toggleStyle(.switch)
            }
            if lock.isEnabled {
                SettingsRowDivider()
                SettingsRow(title: "Lock after") {
                    Picker("Lock after", selection: $lock.timeout) {
                        ForEach(AppLockTimeout.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}

// MARK: Backups

struct BackupPanel: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var folderState: MASSandboxBackupFolder.State = .notSet
    @State private var backups: [BackupInfo] = []
    @State private var status: String?
    @State private var statusIsError = false
    @State private var pendingRestore: BackupInfo?

    var body: some View {
        PanelCard(card: .backups,
                  footnote: "Backups are encrypted with your Keychain key and contain entries, tags and check-ins (not attachment files). A copy of each daily backup also goes to the folder you choose — iCloud Drive or an external disk both work. Restoring first snapshots your current journal.") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderCopy.title).font(OmegaTheme.font(.body, .medium))
                        .foregroundColor(folderCopy.isWarning ? theme.warningColor : theme.titleTextColor)
                    Text(folderCopy.detail)
                        .font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                        .lineLimit(folderCopy.isWarning ? 3 : 1).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: folderCopy.isWarning)
                }
                Spacer()
                Button(folderCopy.chooseLabel) { chooseFolder() }
                if folderState != .notSet { Button("Clear") { vm.db.setChosenBackupFolder(nil); refresh() } }
            }
            .accessibilityElement(children: .contain)
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

    private var folderCopy: MASSandboxBackupFolderCopy { MASSandboxBackupFolderCopy(state: folderState) }

    private func refresh() {
        folderState = vm.db.backupFolderState()
        backups = vm.db.backupInfos()
    }

    private func report(_ text: String, error: Bool = false) { status = text; statusIsError = error }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder for extra backup copies (iCloud Drive, external disk…)."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        // Re-picking after the sandbox lost access: start where the old folder was.
        if case .needsRepick(let last) = folderState, last.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            report("That folder isn't writable.", error: true); return
        }
        guard !DatabaseManager.samePath(url, vm.db.backupsDirectory) else {
            report("That is the journal's own backups folder — choose a different one.", error: true); return
        }
        guard vm.db.setChosenBackupFolder(url) else {
            report("Omega Journal couldn't get lasting permission for that folder. Try a different folder.", error: true); return
        }
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
            vm.reloadAfterRestore()
            CheckinStore.shared.reload()
            report("Restored \(b.date.formatted(date: .abbreviated, time: .shortened)).")
            refresh()
        } catch { report(error.localizedDescription, error: true) }
        pendingRestore = nil
    }
}

extension JournalViewModel {
    /// After the database file is swapped, every piece of state read from it must be
    /// re-read: notebooks (dropping an active notebook that no longer exists), smart
    /// folders, saved searches, persisted view state, templates, then the entry lists.
    func reloadAfterRestore() {
        loadPersistedViewState()
        loadOrganizationState()
        if let active = activeJournalId, !journals.contains(where: { $0.id == active }) {
            activeJournalId = nil
        }
        loadTemplates()
        reload()
    }
}

// MARK: Export / import

struct MoreExportsPanel: View {
    @ObservedObject var vm: JournalViewModel
    var body: some View {
        PanelCard(card: .moreExports,
                  footnote: "Markdown folder: one .md file per entry plus an attachments folder. Static website: self-contained HTML you can open or host anywhere. Hidden entries are only included after you unlock them.") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button { ImportExportPanels.exportMarkdownFolder(vm: vm) } label: { Label("Markdown folder", systemImage: "folder") }
        Button { ImportExportPanels.exportHTMLSite(vm: vm) } label: { Label("Static website", systemImage: "globe") }
        Button { ImportExportPanels.exportEntryPDF(vm: vm) } label: { Label("Selected entry as PDF", systemImage: "doc.richtext") }
    }
}

struct EncryptedExportPanel: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var passphrase = ""
    @State private var confirm = ""

    var body: some View {
        PanelCard(card: .encryptedExport,
                  footnote: "Locked with a password you choose (AES-256-GCM). Anyone with the file and the password can read it, and there is no way to recover a forgotten password.") {
            SecureField("Password", text: $passphrase).textFieldStyle(.roundedBorder)
            SecureField("Repeat password", text: $confirm).textFieldStyle(.roundedBorder)
            HStack {
                Button("Export…") { ImportExportPanels.exportEncrypted(vm: vm, passphrase: passphrase) }
                    .disabled(passphrase.count < 8 || passphrase != confirm)
                Button("Import encrypted…") { ImportExportPanels.importEncrypted(vm: vm, passphrase: passphrase) }
                    .disabled(passphrase.isEmpty)
                Spacer()
                if !passphrase.isEmpty && passphrase.count < 8 {
                    Text("Use at least 8 characters").font(OmegaTheme.metaFont).foregroundColor(theme.warningColor)
                } else if passphrase.count >= 8 && !confirm.isEmpty && passphrase != confirm {
                    Text("Passwords don't match").font(OmegaTheme.metaFont).foregroundColor(theme.warningColor)
                }
            }
        }
    }
}

struct ImportOtherAppsPanel: View {
    @ObservedObject var vm: JournalViewModel
    var body: some View {
        PanelCard(card: .importOtherApps,
                  footnote: "Day One: choose Export → JSON in Day One. Obsidian or notes: pick the vault or folder; titles, dates and tags in front matter are kept and images are attached. Duplicates are skipped and imported entries are never hidden.") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button { ImportExportPanels.importDayOne(vm: vm) } label: { Label("Day One JSON…", systemImage: "book") }
        Button { ImportExportPanels.importNotesFolder(vm: vm) } label: { Label("Obsidian / notes folder…", systemImage: "folder.badge.plus") }
    }
}

// MARK: Reflection settings (review reminders, AI assist)

struct ReviewRemindersPanel: View {
    var body: some View {
        PanelCard(card: .reviewReminders,
                  footnote: "Notifications are generic — they never include entry text. Click one to save the review as an entry.") {
            ReviewScheduleControls()
        }
    }
}

/// Settings version of the Today review card, drawn as a regular settings card
/// (the shared `ReviewCard` uses the large dashboard header, which looked out of
/// place between settings cards).
struct PeriodicReviewPanel: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var period: ReviewPeriod = .week

    var body: some View {
        let draft = vm.reviewDraft(period)
        let span = period == .week ? "week" : "month"
        PanelCard(card: .periodicReview,
                  footnote: "Saves a summary of the period's entries as a new entry you can add to.") {
            SettingsRow(title: "Period") {
                Picker("Review period", selection: $period) {
                    ForEach(ReviewPeriod.allCases) { Text($0 == .week ? "This week" : "This month").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsRowDivider()
            SettingsRow(
                title: draft.entryCount == 0 ? "Nothing written yet this \(span)" : "\(draft.entryCount) \(draft.entryCount == 1 ? "entry" : "entries") this \(span)",
                subtitle: draft.entryCount == 0 ? "Write something first, then come back." : nil
            ) {
                SettingsPillButton(title: "Save Review as Entry", icon: "square.and.arrow.down") {
                    vm.saveReviewAsEntry(period)
                }
                .disabled(draft.entryCount == 0)
                .opacity(draft.entryCount == 0 ? 0.45 : 1)
            }
        }
    }
}

struct AIAssistPanel: View {
    @ObservedObject private var theme = ThemeManager.shared
    @State private var aiEnabled = SmartAssist.isEnabled()

    var body: some View {
        PanelCard(card: .aiAssist,
                  footnote: "Off by default. Uses Apple's on-device model only (macOS 26+ with Apple Intelligence) — nothing leaves your Mac. Hidden entries are never used.") {
            if SmartAssist.availability.isAvailable {
                SettingsRow(title: "Suggest titles, tags and summaries") {
                    Toggle("Suggest titles, tags and summaries", isOn: $aiEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: aiEnabled) { _, on in SmartAssist.setEnabled(on) }
                }
            } else if case .unavailable(let why) = SmartAssist.availability {
                Text(why).font(OmegaTheme.captionFont).foregroundColor(theme.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
