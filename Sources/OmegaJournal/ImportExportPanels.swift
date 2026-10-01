import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Import / Export Panels
//
// The original `ExportManager.showExportPanel` returned a status string from inside
// `panel.begin`'s async completion handler, so it always returned "". These helpers use
// `runModal()` and report the outcome through the view model's toast instead.

@MainActor
enum ImportExportPanels {

    // MARK: Export

    static func exportMarkdown(vm: JournalViewModel) {
        Task {
            let (entries, omitted) = await entriesForExport(vm: vm)
            guard !entries.isEmpty else {
                vm.showToast("Nothing to export — the journal is empty", isError: true)
                return
            }
            save(vm: vm, suggested: "OmegaJournal-\(stamp()).md", type: .plainText, omittedHidden: omitted) { url in
                try ExportManager.exportMarkdown(entries, to: url)
            }
        }
    }

    static func exportJSON(vm: JournalViewModel) {
        Task {
            let (entries, omitted) = await entriesForExport(vm: vm)
            guard !entries.isEmpty else {
                vm.showToast("Nothing to export — the journal is empty", isError: true)
                return
            }
            save(vm: vm, suggested: "OmegaJournal-\(stamp()).json", type: .json, omittedHidden: omitted) { url in
                try ExportManager.exportJSON(entries, to: url, attachmentData: { vm.db.readAttachmentData($0) },
                                             revisionData: { vm.db.exportRevisions(for: $0) })
            }
        }
    }

    @MainActor
    static func exportPDF(vm: JournalViewModel) {
        Task {
            let (entries, omitted) = await entriesForExport(vm: vm)
            save(vm: vm, suggested: "OmegaJournal-\(stamp()).pdf", type: .pdf, omittedHidden: omitted) { url in
                try ExportManager.exportPDF(entries, to: url)
            }
        }
    }

    /// Unlocks hidden entries for a full export; if auth is cancelled, hidden
    /// entries are omitted. Includes archived and trashed entries so backups
    /// capture the complete lifecycle state.
    /// Returns the entries plus how many hidden entries were left out.
    private static func entriesForExport(vm: JournalViewModel) async -> (entries: [JournalEntry], omittedHidden: Int) {
        var all = vm.entries + vm.archivedEntries + vm.trashedEntries
        var seen = Set<String>()
        all.removeAll { !seen.insert($0.id).inserted }
        let hasHidden = all.contains(where: \.isHidden)
        if hasHidden && !BiometricAuth.shared.isAuthenticated {
            if await BiometricAuth.shared.authenticate() {
                return (all, 0)
            }
            let visible = all.filter { !$0.isHidden }
            return (visible, all.count - visible.count)
        }
        return (all, 0)
    }

    // MARK: Phase 5 exports

    /// Passphrase-protected full export (.ojenc).
    static func exportEncrypted(vm: JournalViewModel, passphrase: String) {
        Task {
            let (entries, omitted) = await entriesForExport(vm: vm)
            guard !entries.isEmpty else { vm.showToast("Nothing to export — the journal is empty", isError: true); return }
            let panel = NSSavePanel()
            panel.title = "Encrypted Export"
            panel.nameFieldStringValue = "OmegaJournal-\(stamp()).\(ExportManager.encryptedExtension)"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try ExportManager.exportEncrypted(entries, to: url, passphrase: passphrase, attachmentData: { vm.db.readAttachmentData($0) })
                vm.showToast("Encrypted export saved" + (omitted > 0 ? " — \(omitted) hidden not included" : ""), isError: omitted > 0)
            } catch { vm.showToast("Export failed: \(error.localizedDescription)", isError: true) }
        }
    }

    private static func chooseFolder(_ message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func exportMarkdownFolder(vm: JournalViewModel) {
        Task {
            let (entries, omitted) = await entriesForExport(vm: vm)
            let live = entries.filter { !$0.isTrashed }
            guard !live.isEmpty else { vm.showToast("Nothing to export", isError: true); return }
            guard let parent = chooseFolder("Choose where to create the “Omega Journal Markdown” folder.", prompt: "Export Here") else { return }
            let dir = parent.appendingPathComponent("Omega Journal Markdown \(stamp())", isDirectory: true)
            do {
                let n = try ExportManager.exportMarkdownFolder(live, to: dir, attachmentData: { vm.db.readAttachmentData($0) })
                vm.showToast("Exported \(n) markdown files" + (omitted > 0 ? " — \(omitted) hidden not included" : ""), isError: omitted > 0)
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            } catch { vm.showToast("Export failed: \(error.localizedDescription)", isError: true) }
        }
    }

    static func exportHTMLSite(vm: JournalViewModel) {
        Task {
            let (entries, omitted) = await entriesForExport(vm: vm)
            let live = entries.filter { !$0.isTrashed }
            guard !live.isEmpty else { vm.showToast("Nothing to export", isError: true); return }
            guard let parent = chooseFolder("Choose where to create the website folder.", prompt: "Export Here") else { return }
            let dir = parent.appendingPathComponent("Omega Journal Site \(stamp())", isDirectory: true)
            do {
                let n = try ExportManager.exportHTMLSite(live, to: dir, attachmentData: { vm.db.readAttachmentData($0) })
                vm.showToast("Exported \(n) pages — open index.html" + (omitted > 0 ? " (\(omitted) hidden not included)" : ""), isError: omitted > 0)
                NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("index.html")])
            } catch { vm.showToast("Export failed: \(error.localizedDescription)", isError: true) }
        }
    }

    /// Themed PDF of the selected entry (asks for authentication first when hidden).
    @MainActor
    static func exportEntryPDF(vm: JournalViewModel) {
        guard let entry = vm.selectedEntry else { vm.showToast("No entry selected", isError: true); return }
        Task {
            if entry.isHidden, !(await BiometricAuth.shared.authenticate()) { return }
            let safeName = entry.displayTitle.replacingOccurrences(of: "/", with: "-").prefix(60)
            save(vm: vm, suggested: "\(safeName).pdf", type: .pdf) { url in
                try ExportManager.exportEntryPDF(entry, to: url, accent: NSColor(ThemeManager.shared.accentColor))
            }
        }
    }

    // MARK: Phase 5 imports

    static func importDayOne(vm: JournalViewModel) {
        let panel = NSOpenPanel()
        panel.message = "Choose a Day One JSON export (the .json file or its unzipped folder)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.json, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.importDayOneJSON(from: url)
    }

    static func importNotesFolder(vm: JournalViewModel) {
        guard let url = chooseFolder("Choose an Obsidian vault or a folder of .md / .txt notes.", prompt: "Import") else { return }
        vm.importNotesFolder(from: url)
    }

    static func importEncrypted(vm: JournalViewModel, passphrase: String) {
        let panel = NSOpenPanel()
        panel.message = "Choose an encrypted Omega Journal export (.ojenc)."
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.importEncryptedExport(from: url, passphrase: passphrase)
    }

    /// Exports only the currently selected entry.
    static func exportCurrentEntry(vm: JournalViewModel) {
        guard let entry = vm.selectedEntry else {
            vm.showToast("No entry selected", isError: true)
            return
        }
        let safeName = entry.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .prefix(60)
        save(vm: vm, suggested: "\(safeName).md", type: .plainText) { url in
            try ExportManager.exportMarkdown([entry], to: url)
        }
    }

    @MainActor
    private static func save(vm: JournalViewModel, suggested: String, type: UTType, omittedHidden: Int = 0, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export Journal"
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return } // cancelled — no toast
        do {
            try write(url)
            if omittedHidden > 0 {
                vm.showToast("Exported to \(url.lastPathComponent) — \(omittedHidden) hidden \(omittedHidden == 1 ? "entry was" : "entries were") NOT included (authentication cancelled)", isError: true)
            } else {
                vm.showToast("Exported to \(url.lastPathComponent)")
            }
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            vm.showToast("Export failed: “\(url.deletingLastPathComponent().lastPathComponent)” is not writable. Try your Documents or Desktop folder.", isError: true)
        } catch {
            vm.showToast("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Import

    @MainActor
    static func showImportPanel(vm: JournalViewModel) {
        let panel = NSOpenPanel()
        panel.title = "Import Entries"
        panel.message = "Choose a JSON backup or one or more markdown files."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .plainText, UTType(filenameExtension: "md") ?? .plainText]

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let jsonURLs = urls.filter { $0.pathExtension.lowercased() == "json" }
        let mdURLs = urls.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }

        for url in jsonURLs { vm.importJSON(from: url) }
        if !mdURLs.isEmpty { vm.importMarkdown(from: mdURLs) }
        let ignored = urls.count - jsonURLs.count - mdURLs.count
        if ignored > 0, !(jsonURLs.isEmpty && mdURLs.isEmpty) {
            vm.showToast("\(ignored) unsupported \(ignored == 1 ? "file was" : "files were") ignored", isError: true)
        }
        if jsonURLs.isEmpty && mdURLs.isEmpty {
            vm.showToast("No importable files selected", isError: true)
        }
    }

    private static func stamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }
}
