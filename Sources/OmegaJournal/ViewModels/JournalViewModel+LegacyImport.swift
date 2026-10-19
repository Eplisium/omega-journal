import AppKit
import Foundation
import OmegaJournalCore

// MARK: - Import an existing journal folder (Mac App Store wave)

extension JournalViewModel {
    /// Copies the journal in a user-chosen folder (the old `OmegaJournal`
    /// folder of the direct/DMG build) into this empty journal, then reloads
    /// everything. Shows a friendly toast either way. Returns success.
    @discardableResult
    func importLegacyJournal(from folder: URL, defaults: UserDefaults = .standard) -> Bool {
        // Sandboxed: NSOpenPanel URLs are security-scoped.
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        flushBeforeImmediateMutation()
        guard unsavedSnapshots.isEmpty else {
            showToast("Some changes aren't saved yet, so nothing was imported. Retry saving first.", isError: true)
            return false
        }
        if editingEntryId != nil { stopEditing() }

        do {
            let summary = try db.importLegacyJournal(from: folder)
            reloadAfterRestore()
            if db === DatabaseManager.shared { CheckinStore.shared.reload() }
            selectedEntryId = nil
            Self.markLegacyImportOfferHandled(defaults: defaults)
            let noun = summary.entries == 1 ? "entry" : "entries"
            showToast("Imported your earlier journal — \(summary.entries) \(noun).")
            return true
        } catch let error as DatabaseManager.LegacyImportError {
            showToast(error.errorDescription ?? "The import didn't finish.", isError: true)
        } catch {
            showToast("The import didn't finish, and your journal was left as it was.", isError: true)
        }
        // A failed attempt reopened the original journal; re-read it.
        reloadAfterRestore()
        return false
    }

    /// Asks for the earlier version's journal folder, then imports it.
    func chooseAndImportLegacyJournal() {
        let panel = NSOpenPanel()
        panel.title = "Import Journal from an Earlier Version"
        panel.message = "Choose the \u{201C}OmegaJournal\u{201D} folder used by the earlier version (it's in your Library › Application Support folder and holds omega_journal.sqlite3). Your current journal must be empty."
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        // ~/Library is hidden in Finder; start right at the old folder.
        panel.showsHiddenFiles = true
        panel.directoryURL = AppEnvironment.legacyJournalDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLegacyJournal(from: url)
    }

    // MARK: One-time offer

    /// True when the one-time "import your earlier journal" offer should show.
    /// Only call once the launch gate has finished (reads the database).
    func shouldOfferLegacyImport(defaults: UserDefaults = .standard,
                                 isSandboxed: Bool = AppEnvironment.isSandboxed) -> Bool {
        let testMode = !(ProcessInfo.processInfo.environment[MASDataJournalLocation.testDatabaseEnvKey] ?? "").isEmpty
        return MASDataLegacyImportOffer.shouldOffer(
            isSandboxed: isSandboxed,
            isTestMode: testMode,
            journalIsEmpty: db.isJournalEmptyForImport(),
            dismissed: defaults.bool(forKey: MASDataLegacyImportOffer.dismissedDefaultsKey))
    }

    /// "Not now" (and any completed import): never offer again.
    static func markLegacyImportOfferHandled(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: MASDataLegacyImportOffer.dismissedDefaultsKey)
    }
}
