import AppIntents
import Foundation
import OmegaJournalCore

// MARK: - Entry intents (Siri, Shortcuts, Apple Intelligence)
//
// Reading intents (Find entries) answer in place and return entities, which
// carry title, date, mood and tags only — never bodies. Writing intents queue
// an `AppCommand` and open the app, so text only ever flows *into* the journal
// and nothing touches the database before the launch gate is done.

struct OpenEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Entry"
    static let description = IntentDescription("Opens an entry in Omega Journal.")
    static let openAppWhenRun = true

    @Parameter(title: "Entry", requestValueDialog: "Which entry?")
    var entry: JournalEntryEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$entry)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppCommandInbox.submit(.openEntry(id: entry.id))
        return .result()
    }
}

struct FindEntriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Entries"
    static let description = IntentDescription(
        "Finds journal entries by words, tag, notebook or date. Returns titles, dates, moods and tags — never what you wrote.")
    static let openAppWhenRun = false

    @Parameter(title: "Containing")
    var text: String?

    @Parameter(title: "Tag")
    var tag: TagEntity?

    @Parameter(title: "Notebook")
    var notebook: NotebookEntity?

    @Parameter(title: "From")
    var from: Date?

    @Parameter(title: "To")
    var to: Date?

    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 200))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find entries containing \(\.$text)") {
            \.$tag
            \.$notebook
            \.$from
            \.$to
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[JournalEntryEntity]> & ProvidesDialog {
        let snap = try IntentJournalBridge.snapshot()
        let filter = IntentEntryFilter(text: text, tag: tag?.id, journalId: notebook?.id, from: from, to: to, limit: limit)
        let found = IntentEntryCatalog.find(filter, in: snap.records, hiddenLocked: snap.hiddenLocked, appLocked: false)
        let entities = found.map(JournalEntryEntity.init)
        let dialog: IntentDialog = switch entities.count {
        case 0: "No matching entries."
        case 1: "Found 1 entry."
        default: "Found \(entities.count) entries."
        }
        return .result(value: entities, dialog: dialog)
    }
}

struct AppendToTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Append to Today's Entry"
    static let description = IntentDescription(
        "Adds text to the end of the entry you wrote today, or starts today's entry if there isn't one yet.")
    static let openAppWhenRun = true

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What do you want to add?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Append \(\.$text) to today's entry")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let clean = AppIntentText.clean(text) else { return .result(dialog: "Nothing to add.") }
        AppCommandInbox.submit(.appendToToday(text: clean))
        return .result(dialog: "Added to today's entry.")
    }
}

struct LogMoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Mood"
    static let description = IntentDescription(
        "Sets the mood of today's entry, or starts today's entry with that mood if there isn't one yet.")
    static let openAppWhenRun = true

    @Parameter(title: "Mood", requestValueDialog: "How are you feeling?")
    var mood: JournalMoodOption

    static var parameterSummary: some ParameterSummary {
        Summary("Log mood \(\.$mood)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppCommandInbox.submit(.logMood(mood.mood))
        return .result(dialog: "Mood logged.")
    }
}
