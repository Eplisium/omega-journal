import AppIntents
import Foundation
import OmegaJournalShared

// MARK: - App Intents (Shortcuts, Siri, Spotlight)
//
// Privacy rules for every intent here:
// - Nothing returns entry titles or bodies. "Today's Progress" answers from
//   the widget snapshot (counts, streak, prompt), which excludes hidden entries.
// - Anything that touches the journal opens the app and goes through
//   `AppCommandInbox` / `QuickCaptureInbox`, which wait for the launch gate
//   (encryption key adopted) before the database is touched.
//
// SwiftPM does not run Xcode's App Intents metadata extraction; the packaging
// scripts do (`oj_appintents_metadata` in scripts/lib/oj-packaging.sh). Keep
// titles, phrases and enum display names as literals: they are read from the
// compiler's const-value output, not at runtime.

/// Mood choices for the "New Journal Entry" parameter.
nonisolated enum JournalMoodOption: String, AppEnum {
    case awful, bad, neutral, good, great

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mood"
    static let caseDisplayRepresentations: [JournalMoodOption: DisplayRepresentation] = [
        .awful: "Awful",
        .bad: "Bad",
        .neutral: "Neutral",
        .good: "Good",
        .great: "Great",
    ]

    var mood: Mood {
        switch self {
        case .awful: .awful
        case .bad: .bad
        case .neutral: .neutral
        case .good: .good
        case .great: .great
        }
    }
}

struct NewJournalEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "New Journal Entry"
    static let description = IntentDescription(
        "Opens Omega Journal and starts a new entry, optionally with a title, text and mood.")
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var entryTitle: String?

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String?

    @Parameter(title: "Mood")
    var mood: JournalMoodOption?

    static var parameterSummary: some ParameterSummary {
        Summary("New journal entry \(\.$entryTitle)") {
            \.$text
            \.$mood
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppCommandInbox.submit(.newEntry(title: entryTitle, body: text, mood: mood?.mood))
        return .result()
    }
}

struct QuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Capture"
    static let description = IntentDescription(
        "Saves a short note to your journal as a new entry tagged #quick, without leaving what you're doing for long.")
    static let openAppWhenRun = true

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What do you want to capture?")
    var text: String

    @Parameter(title: "Mood")
    var mood: JournalMoodOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$text) in Omega Journal") {
            \.$mood
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let body = QuickCapture.normalized(text) else {
            return .result(dialog: "Nothing to capture.")
        }
        // Queued until the journal is unlocked, then saved like a menu-bar capture.
        QuickCaptureInbox.submit(QuickCaptureItem(body: body, mood: mood?.mood ?? .neutral, tags: [QuickCapture.tag]))
        return .result(dialog: "Captured to Omega Journal.")
    }
}

struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today"
    static let description = IntentDescription("Opens Omega Journal on the Today page.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppCommandInbox.submit(.showToday)
        return .result()
    }
}

struct OpenOnThisDayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open On This Day"
    static let description = IntentDescription("Opens Omega Journal on the entries you wrote on this date in earlier years.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppCommandInbox.submit(.showOnThisDay)
        return .result()
    }
}

struct TodaysWritingProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Writing Progress"
    static let description = IntentDescription(
        "Tells you how many words you wrote today and your current streak. Never reads out what you wrote.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let state = WritingProgressSource.currentState()
        return .result(value: state.words, dialog: "\(WidgetDisplay.progressSentence(state))")
    }
}

/// Reads the privacy-safe widget snapshot (no database, no encryption key).
enum WritingProgressSource {
    static func currentState(now: Date = Date()) -> WidgetDisplayState {
        guard let group = OmegaJournalAppGroup.identifier(infoDictionary: Bundle.main.infoDictionary),
              let store = WidgetSnapshotStore.appGroup(group) else { return .empty(at: now) }
        return WidgetDisplay.state(for: store.read(), at: now)
    }
}

// MARK: - Zero-setup shortcuts

nonisolated struct OmegaJournalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewJournalEntryIntent(),
            phrases: [
                "New entry in \(.applicationName)",
                "Start a \(.applicationName) entry",
                "Write in \(.applicationName)",
            ],
            shortTitle: "New Entry",
            systemImageName: "square.and.pencil")
        AppShortcut(
            intent: QuickCaptureIntent(),
            phrases: [
                "Quick capture in \(.applicationName)",
                "Capture a thought in \(.applicationName)",
            ],
            shortTitle: "Quick Capture",
            systemImageName: "bolt")
        AppShortcut(
            intent: OpenTodayIntent(),
            phrases: [
                "Open today in \(.applicationName)",
                "Show today's page in \(.applicationName)",
            ],
            shortTitle: "Today",
            systemImageName: "sun.max")
        AppShortcut(
            intent: OpenOnThisDayIntent(),
            phrases: [
                "Show on this day in \(.applicationName)",
                "Open on this day in \(.applicationName)",
            ],
            shortTitle: "On This Day",
            systemImageName: "clock.arrow.circlepath")
        AppShortcut(
            intent: TodaysWritingProgressIntent(),
            phrases: [
                "How much did I write today in \(.applicationName)",
                "Check my \(.applicationName) streak",
                "\(.applicationName) progress",
            ],
            shortTitle: "Today's Progress",
            systemImageName: "flame")
    }

    static let shortcutTileColor: ShortcutTileColor = .purple
}
