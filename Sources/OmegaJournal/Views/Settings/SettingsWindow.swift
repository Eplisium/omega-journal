import SwiftUI
import OmegaJournalCore

// MARK: - Native Settings window
//
// Settings used to be a sheet inside the journal window: it covered the
// writing, sized itself from the host window and every window's sidebar
// opened its own copy on ⌘,. It is now the app's `Settings` scene — a proper
// macOS Settings window with a toolbar of panes, opened with ⌘, (the menu item
// SwiftUI provides) or `openSettings()`.
//
// The panes edit the journal through a `JournalViewModel`. Each journal
// window owns one; `SettingsHost` remembers which windows are open so the
// Settings window uses the most recently shown one. Until a journal window
// exists — i.e. before the launch gate has adopted the encryption key — the
// Settings window shows a placeholder and never touches the database.

/// Which pane the Settings window shows. Shared so the Help menu ("Keyboard
/// Shortcuts") and the sidebar can open the window on a given pane.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var section: SettingsSection

    init(section: SettingsSection = .appearance) {
        self.section = section
    }
}

/// The journal windows' view models, most recently shown last.
@MainActor
@Observable
final class SettingsHost {
    static let shared = SettingsHost()

    private var models: [JournalViewModel] = []

    /// The model the Settings window edits: the most recently shown window's.
    var activeModel: JournalViewModel? { models.last }

    func register(_ vm: JournalViewModel) {
        models.removeAll { $0 === vm }
        models.append(vm)
    }

    func unregister(_ vm: JournalViewModel) {
        models.removeAll { $0 === vm }
    }
}

/// Root of the `Settings` scene.
struct SettingsWindowRoot: View {
    private let host = SettingsHost.shared
    private let theme = ThemeManager.shared

    var body: some View {
        Group {
            if let vm = host.activeModel {
                // A journal window exists, so the launch gate has passed and
                // the app lock may be consulted (it reads the database).
                SettingsView(vm: vm)
                    .appLockGate(AppLockManager.shared)
            } else {
                placeholder
            }
        }
        .tint(theme.accentColor)
        .preferredColorScheme(theme.colorScheme)
    }

    private var placeholder: some View {
        VStack(spacing: OmegaTheme.Spacing.m) {
            Image(systemName: "book.closed")
                .font(OmegaTheme.font(.title, .light))
                .foregroundColor(theme.secondaryTextColor)
                .accessibilityHidden(true)
            Text("Open a journal window to change settings.")
                .font(OmegaTheme.font(.body))
                .foregroundColor(theme.secondaryTextColor)
        }
        .frame(width: SettingsWindowSizing.idealWidth, height: 240)
        .background(theme.backgroundColor)
        .accessibilityElement(children: .combine)
    }
}

/// Settings window size: wide enough for two theme cards per row, tall enough
/// to show a pane's first cards; resizable within these bounds.
enum SettingsWindowSizing {
    static let minWidth: CGFloat = 600
    static let idealWidth: CGFloat = 680
    static let maxWidth: CGFloat = 900
    static let minHeight: CGFloat = 420
    static let idealHeight: CGFloat = 600
    static let maxHeight: CGFloat = 1100
}

extension SettingsSection {
    /// Short toolbar label (the toolbar truncates long titles).
    var tabTitle: String {
        switch self {
        case .appearance: "Appearance"
        case .goals: "Writing"
        case .privacy: "Privacy"
        case .data: "Data"
        case .about: "About"
        }
    }
}
