import SwiftUI
import OmegaJournalCore
import AppKit

// MARK: - App Entry Point

@main
struct OmegaJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Not @AppStorage: see QuickCapturePresence for the launch hang this caused.
    @State private var quickCapture = QuickCapturePresence()

    var body: some Scene {
        WindowGroup {
            LaunchGateView()
                .frame(minWidth: 940, minHeight: 620)
                .modifier(AppURLHandling()) // omegajournal:// links (widget); queued until unlocked
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 780)
        .commands { menuCommands }

        MenuBarExtra("Quick Capture", systemImage: "square.and.pencil", isInserted: quickCapture.binding) {
            QuickCaptureView()
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: Menus

    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Entry") { post(.newEntry) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New from Template…") { post(.newFromTemplate) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New from Today's Prompt") { post(.newFromPrompt) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Entries…") { post(.importEntries) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandMenu("Format") {
            formatButton("Bold", .bold, "b", [.command])
            formatButton("Italic", .italic, "i", [.command])
            formatButton("Strikethrough", .strikethrough, "x", [.command, .shift])
            formatButton("Inline Code", .code, "e", [.command, .shift])
            Divider()
            formatButton("Heading 1", .heading1, "1", [.command, .control])
            formatButton("Heading 2", .heading2, "2", [.command, .control])
            formatButton("Heading 3", .heading3, "3", [.command, .control])
            Divider()
            formatButton("Bullet List", .bulletList, "8", [.command, .shift])
            formatButton("Numbered List", .numberedList, "7", [.command, .shift])
            formatButton("Checklist", .checkbox, "l", [.command, .shift])
            formatButton("Toggle Task Done", .toggleTask, "d", [.command, .shift])
            formatButton("Quote", .quote, "'", [.command, .shift])
            Divider()
            formatButton("Link", .link, "k", [.command, .shift])
            formatButton("Code Block", .codeBlock, "j", [.command, .shift])
            formatButton("Divider", .divider, "-", [.command, .shift])
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { post(.showSettings) }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find") { post(.findInEntryOrList) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Search All Entries") { post(.searchAllEntries) }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }

        CommandMenu("Entry") {
            Button("Edit Entry") { post(.editSelectedEntry) }
                .keyboardShortcut("e", modifiers: .command)
            Button("Pin / Unpin") { post(.togglePinSelected) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Favorite / Unfavorite") { post(.toggleFavoriteSelected) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Archive / Unarchive") { post(.toggleArchiveSelected) }
                .keyboardShortcut("a", modifiers: [.command, .control])
            Button("Duplicate") { post(.duplicateSelected) }
                .keyboardShortcut("d", modifiers: [.command, .control])
            Button("Export Entry…") { post(.exportSelected) }
                .keyboardShortcut("e", modifiers: [.command, .control])
            Divider()
            Button("Next Entry") { post(.selectNextEntry) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Entry") { post(.selectPreviousEntry) }
                .keyboardShortcut("[", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("Command Palette") { post(.toggleCommandPalette) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Zen Mode") { post(.toggleZenMode) }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Divider()
            Button("Today") { post(.showToday) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Journal") { post(.showJournal) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Calendar") { post(.showCalendar) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Insights") { post(.showInsights) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Lock Hidden Entries") { post(.lockHiddenEntries) }
                .keyboardShortcut("l", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            // App Store: support page + privacy policy, no GitHub. Direct: GitHub help/issues + privacy policy.
            ForEach(MASSandboxHelpMenu.items(for: AppEnvironment.channel)) { item in
                Button(item.title) {
                    switch item.action {
                    case .open(let url): NSWorkspace.shared.open(url)
                    case .showShortcuts: post(.showShortcuts)
                    }
                }
            }
        }
    }

    private func formatButton(_ title: String, _ command: MarkdownCommand, _ key: KeyEquivalent, _ modifiers: EventModifiers) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .formatCommand, object: command)
        }
        .keyboardShortcut(key, modifiers: modifiers)
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        GlobalHotkey.shared.syncRegistration()
    }

    /// Dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Entry", action: #selector(dockNewEntry), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func dockNewEntry() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .newEntry, object: nil)
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Touch ID / password dialogs resign the app — don't lock mid-prompt.
        guard !BiometricAuth.shared.isAuthenticating else { return }
        // Default ON (preserves the original behaviour); Settings can disable it.
        let lockOnResign = UserDefaults.standard.object(forKey: ShellPrefs.lockOnResignKey) as? Bool ?? true
        guard lockOnResign else { return }
        NotificationCenter.default.post(name: .lockHiddenEntries, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Warn before quitting while a save has failed. `quitDecision()` first
    /// flushes and retries, so this only asks when text is genuinely unsaved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard case .confirm(let count) = QuitGuard.check?() ?? .terminate else { return .terminateNow }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = SaveUnsavedPresentation.quitAlertTitle
            alert.informativeText = SaveUnsavedPresentation.quitAlertMessage(unsavedCount: count)
            alert.addButton(withTitle: SaveUnsavedPresentation.quitCancelButton)
            alert.addButton(withTitle: SaveUnsavedPresentation.quitAnywayButton)
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Make sure any debounced autosave has landed before the process goes
        // away. ContentView owns the one-and-only JournalViewModel (a
        // @LazyState), so ask it to flush via notification — the delegate has
        // no reference to the view-owned model. SwiftUI's onReceive handlers
        // run synchronously, so the save completes before DatabaseManager.shared
        // deinits and closes the database.
        NotificationCenter.default.post(name: .quitTimeSave, object: nil)
        DatabaseManager.shared.purgeExpiredTrash()
    }
}

/// Bridge from the AppDelegate to the view-owned JournalViewModel.
@MainActor enum QuitGuard {
    static var check: (() -> SaveQuitDecision)?
}

enum ShellPrefs {
    static let lockOnResignKey = "shell.lockHiddenOnResignActive"
    // Sidebar disclosure state (@AppStorage).
    static let sidebarCollapsedTags = "shell.sidebar.collapsedTags"
    static let sidebarLibraryExpanded = "shell.sidebar.libraryExpanded"
    static let sidebarMoodsExpanded = "shell.sidebar.moodsExpanded"
    static let sidebarNotebooksExpanded = "shell.sidebar.notebooksExpanded"
    static let sidebarReflectExpanded = "shell.sidebar.reflectExpanded"
    static let sidebarSmartExpanded = "shell.sidebar.smartExpanded"
    static let sidebarStorageExpanded = "shell.sidebar.storageExpanded"
    static let sidebarTagsExpanded = "shell.sidebar.tagsExpanded"
}
