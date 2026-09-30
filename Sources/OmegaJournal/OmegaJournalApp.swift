import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct OmegaJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage(QuickCapture.insertedKey) private var showQuickCapture = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 780)
        .commands { menuCommands }

        MenuBarExtra("Quick Capture", systemImage: "square.and.pencil", isInserted: $showQuickCapture) {
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
            Button("Omega Journal Help") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Eplisium/omega-journal")!)
            }
            Button("Keyboard Shortcuts") { post(.showShortcuts) }
            Button("Report an Issue…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Eplisium/omega-journal/issues")!)
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

    func applicationWillTerminate(_ notification: Notification) {
        // Make sure any debounced autosave has landed before the process goes
        // away. ContentView owns the one-and-only JournalViewModel (a
        // @StateObject), so ask it to flush via notification — the delegate has
        // no reference to the view-owned model. SwiftUI's onReceive handlers
        // run synchronously, so the save completes before DatabaseManager.shared
        // deinits and closes the database.
        NotificationCenter.default.post(name: .quitTimeSave, object: nil)
        DatabaseManager.shared.purgeExpiredTrash()
    }
}

enum ShellPrefs {
    static let lockOnResignKey = "shell.lockHiddenOnResignActive"
}
