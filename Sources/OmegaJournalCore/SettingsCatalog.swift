import Foundation

// MARK: - Settings layout (pure)
//
// The single source of truth for which card lives in which Settings pane, in
// what order. `SettingsView` renders panes straight from this table, so a card
// can never silently drop out of the UI or show up in two places, and tests can
// prove every stored preference is still reachable after a regroup.

public enum SettingsGroup: String, CaseIterable, Sendable {
    case appearance, writing, privacy, data, about
}

public enum SettingsCardID: String, CaseIterable, Sendable, Identifiable {
    // Appearance
    case theme, systemAppearance, reading, customColors
    // Writing
    case writingGoals, quickCapture, reviewReminders, periodicReview, aiAssist
    // Privacy
    case whatsProtected, appLock, hiddenEntries
    // Data
    case backups, export, moreExports, encryptedExport, importEntries, importOtherApps, storage, dangerZone
    // About
    case shortcuts

    public var id: String { rawValue }

    public var group: SettingsGroup {
        switch self {
        case .theme, .systemAppearance, .reading, .customColors: .appearance
        case .writingGoals, .quickCapture, .reviewReminders, .periodicReview, .aiAssist: .writing
        case .whatsProtected, .appLock, .hiddenEntries: .privacy
        case .backups, .export, .moreExports, .encryptedExport, .importEntries, .importOtherApps,
             .storage, .dangerZone: .data
        case .shortcuts: .about
        }
    }

    /// Plain-language card heading shown above the card.
    public var title: String {
        switch self {
        case .theme: "Theme"
        case .systemAppearance: "Light & Dark Mode"
        case .reading: "Reading"
        case .customColors: "Custom Colors"
        case .writingGoals: "Writing Goals"
        case .quickCapture: "Quick Capture"
        case .reviewReminders: "Review Reminders"
        case .periodicReview: "Weekly & Monthly Review"
        case .aiAssist: "On-Device Writing Help"
        case .whatsProtected: "What's Protected"
        case .appLock: "App Lock"
        case .hiddenEntries: "Hidden Entries & Spotlight"
        case .backups: "Backups"
        case .export: "Export"
        case .moreExports: "More Export Formats"
        case .encryptedExport: "Password-Protected Export"
        case .importEntries: "Import"
        case .importOtherApps: "Import from Other Apps"
        case .storage: "Storage"
        case .dangerZone: "Empty Trash"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    /// SF Symbol shown in the card header.
    public var icon: String {
        switch self {
        case .theme: "paintpalette"
        case .systemAppearance: "circle.lefthalf.filled"
        case .reading: "textformat"
        case .customColors: "eyedropper"
        case .writingGoals: "target"
        case .quickCapture: "bolt"
        case .reviewReminders: "bell.badge"
        case .periodicReview: "calendar.badge.clock"
        case .aiAssist: "sparkles"
        case .whatsProtected: "lock.doc"
        case .appLock: "lock.app.dashed"
        case .hiddenEntries: "lock.shield"
        case .backups: "externaldrive.badge.timemachine"
        case .export: "square.and.arrow.up"
        case .moreExports: "square.and.arrow.up.on.square"
        case .encryptedExport: "lock.doc"
        case .importEntries: "square.and.arrow.down"
        case .importOtherApps: "tray.and.arrow.down"
        case .storage: "internaldrive"
        case .dangerZone: "exclamationmark.triangle"
        case .shortcuts: "keyboard"
        }
    }

    /// Persisted preference keys (UserDefaults or the settings table) edited by
    /// this card. Theme and goal state live in their own managers and are not
    /// listed. Used to prove a regroup never orphans a stored value.
    public var storageKeys: [String] {
        switch self {
        case .reading: ["readingFontDesign", "readingShowCover", "readingMaxWidth"]
        case .quickCapture: ["shell.menuBarQuickCapture", "shell.globalHotkeyEnabled"]
        case .aiAssist: ["smartAssistEnabled"]
        case .appLock: ["appLockEnabled", "appLockTimeoutSeconds"]
        case .hiddenEntries: ["shell.lockHiddenOnResignActive", "spotlight.indexTitles"]
        default: []
        }
    }
}

public enum SettingsCatalog {
    /// Cards of one pane, in display order (the `SettingsCardID` declaration order).
    public static func cards(in group: SettingsGroup) -> [SettingsCardID] {
        SettingsCardID.allCases.filter { $0.group == group }
    }

    /// The card that edits `key`, if any.
    public static func card(forStorageKey key: String) -> SettingsCardID? {
        SettingsCardID.allCases.first { $0.storageKeys.contains(key) }
    }
}

// MARK: - Settings sheet sizing (pure)

public enum SettingsSheetSizing {
    /// The journal window's minimum frame (940×620 content + title bar/toolbar).
    /// Used when no host window can be found, so the sheet can never be taller
    /// or wider than the smallest window it might attach to.
    public static let fallbackHost = CGSize(width: 940, height: 672)
    public static let preferredMinimum = CGSize(width: 680, height: 540)
    public static let maximum = CGSize(width: 900, height: 760)

    /// Uses most of the host window, clamped to a comfortable range, and never
    /// exceeds the host minus room for the toolbar the sheet hangs below.
    public static func size(forHost host: CGSize?) -> CGSize {
        let h = host ?? fallbackHost
        let width = min(maximum.width, max(preferredMinimum.width, h.width - 120), h.width - 40)
        let height = min(maximum.height, max(preferredMinimum.height, h.height - 100), h.height - 80)
        return CGSize(width: max(320, width), height: max(320, height))
    }
}

// MARK: - Storage location (pure)

public enum SettingsStorageLocation {
    /// Folder holding the journal database, with the home directory shown as `~`.
    public static func displayFolder(forDatabasePath path: String,
                                     home: String = NSHomeDirectory()) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        guard !home.isEmpty else { return folder }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        if folder == base { return "~" }
        if folder.hasPrefix(base + "/") { return "~" + folder.dropFirst(base.count) }
        return folder
    }
}
