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
            let entries = await entriesForExport(vm: vm)
            save(vm: vm, suggested: "OmegaJournal-\(stamp()).md", type: .plainText) { url in
                try ExportManager.exportMarkdown(entries, to: url)
            }
        }
    }

    static func exportJSON(vm: JournalViewModel) {
        Task {
            let entries = await entriesForExport(vm: vm)
            save(vm: vm, suggested: "OmegaJournal-\(stamp()).json", type: .json) { url in
                try ExportManager.exportJSON(entries, to: url)
            }
        }
    }

    @MainActor
    static func exportPDF(vm: JournalViewModel) {
        Task {
            let entries = await entriesForExport(vm: vm)
            save(vm: vm, suggested: "OmegaJournal-\(stamp()).pdf", type: .pdf) { url in
                try ExportManager.exportPDF(entries, to: url)
            }
        }
    }

    /// Unlocks hidden entries for a full export; if auth is cancelled, hidden entries are omitted.
    private static func entriesForExport(vm: JournalViewModel) async -> [JournalEntry] {
        let hasHidden = vm.entries.contains(where: \.isHidden)
        if hasHidden && !BiometricAuth.shared.isAuthenticated {
            if await BiometricAuth.shared.authenticate() {
                return vm.entries
            }
            return vm.entries.filter { !$0.isHidden }
        }
        return vm.entries
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
    private static func save(vm: JournalViewModel, suggested: String, type: UTType, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export Journal"
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(url)
            vm.showToast("Exported to \(url.lastPathComponent)")
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
