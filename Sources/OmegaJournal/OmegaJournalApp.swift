import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct OmegaJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 780)
        .commands { menuCommands }
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
            formatButton("Quote", .quote, "'", [.command, .shift])
            Divider()
            formatButton("Link", .link, "k", [.command, .shift])
            formatButton("Code Block", .codeBlock, "j", [.command, .shift])
            formatButton("Divider", .divider, "-", [.command, .shift])
        }

        CommandMenu("View") {
            Button("Command Palette") { post(.toggleCommandPalette) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Search") { post(.focusSearch) }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Zen Mode") { post(.toggleZenMode) }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Divider()
            Button("Calendar") { post(.showCalendar) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Insights") { post(.showInsights) }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            Button("Lock Hidden Entries") { post(.lockHiddenEntries) }
                .keyboardShortcut("l", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button("Omega Journal Help") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Eplisium/omega-journal")!)
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
        NotificationCenter.default.post(name: .lockHiddenEntries, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Make sure any debounced autosave has landed before the process goes away.
        DatabaseManager.shared.purgeExpiredTrash()
    }
}
