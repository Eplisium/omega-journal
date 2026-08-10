import SwiftUI
import UserNotifications

// MARK: - App

@main
struct OmegaJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Entry") { NotificationCenter.default.post(name: .newEntry, object: nil) }
                    .keyboardShortcut("n", modifiers: .command)

                Button("New Entry from Prompt") { NotificationCenter.default.post(name: .newEntryFromPrompt, object: nil) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Delete Entry") { NotificationCenter.default.post(name: .deleteEntry, object: nil) }
                    .keyboardShortcut(.delete, modifiers: .command)

                Divider()

                Button("Edit Entry") { NotificationCenter.default.post(name: .editEntry, object: nil) }
                    .keyboardShortcut("e", modifiers: .command)

                Button("Toggle Pin") { NotificationCenter.default.post(name: .togglePin, object: nil) }
                    .keyboardShortcut("p", modifiers: .command)

                Button("Toggle Favorite") { NotificationCenter.default.post(name: .toggleFavorite, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                // Markdown formatting shortcuts
                Button("Bold") { NotificationCenter.default.post(name: .formatBold, object: nil) }
                    .keyboardShortcut("b", modifiers: .command)

                Button("Italic") { NotificationCenter.default.post(name: .formatItalic, object: nil) }
                    .keyboardShortcut("i", modifiers: .command)

                Button("Inline Code") { NotificationCenter.default.post(name: .formatCode, object: nil) }
                    .keyboardShortcut("`", modifiers: .command)

                Button("Insert Heading") { NotificationCenter.default.post(name: .formatHeading, object: nil) }
                    .keyboardShortcut("h", modifiers: .command)

                Button("Insert List") { NotificationCenter.default.post(name: .formatList, object: nil) }
                    .keyboardShortcut("l", modifiers: .command)

                Button("Insert Link") { NotificationCenter.default.post(name: .formatLink, object: nil) }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Focus Search") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
        Settings { SettingsView() }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission on first launch
        let hasAsked = DatabaseManager.shared.getSetting("hasAskedNotifications", defaultValue: "false")
        if hasAsked != "true" {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
            DatabaseManager.shared.setSetting("hasAskedNotifications", value: "true")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newEntry = Notification.Name("newEntry")
    static let newEntryFromPrompt = Notification.Name("newEntryFromPrompt")
    static let deleteEntry = Notification.Name("deleteEntry")
    static let editEntry = Notification.Name("editEntry")
    static let togglePin = Notification.Name("togglePin")
    static let toggleFavorite = Notification.Name("toggleFavorite")
    static let focusSearch = Notification.Name("focusSearch")
    static let formatBold = Notification.Name("formatBold")
    static let formatItalic = Notification.Name("formatItalic")
    static let formatCode = Notification.Name("formatCode")
    static let formatHeading = Notification.Name("formatHeading")
    static let formatList = Notification.Name("formatList")
    static let formatLink = Notification.Name("formatLink")
}

// MARK: - Theme Constants

enum OmegaTheme {
    // MARK: Spacing & Layout
    static let contentMaxWidth: CGFloat = 720
    static let contentPadding: CGFloat = 48
    static let cardPadding: CGFloat = 18
    static let cardRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 8
    static let sidebarWidth: CGFloat = 260

    // MARK: Typography
    static let titleFont = Font.system(size: 34, weight: .bold, design: .serif)
    static let bodyFont = Font.system(size: 16, design: .serif)
    static let headerFont = Font.system(size: 11, weight: .semibold)
    static let sectionTitleFont = Font.system(size: 13, weight: .semibold)
    static let metaFont = Font.system(size: 12)
    static let captionFont = Font.system(size: 11)

    // MARK: Surfaces
    static func cardBackground(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }
    static func cardBorder(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
    static func hairline(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }

    // MARK: Shadows
    static let cardShadow = Color.black.opacity(0.15)
    static let cardShadowRadius: CGFloat = 4
    static let cardShadowY: CGFloat = 2

    // MARK: Interactive
    static func hoverFill(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }
    static func selectedFill(accent: Color) -> Color { accent.opacity(0.14) }
    static func accentSoft(accent: Color) -> Color { accent.opacity(0.20) }

    // MARK: Buttons
    static let toolbarButtonSize: CGFloat = 28
    static let toolbarIconSize: CGFloat = 13
}
