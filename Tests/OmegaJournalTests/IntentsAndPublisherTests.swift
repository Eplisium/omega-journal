import AppIntents
import Darwin
import Foundation
import Testing
import OmegaJournalShared
@testable import OmegaJournal

/// App Intents and widget deep links reach the journal only through
/// `AppCommandInbox`, drained by ContentView after the launch gate.
@Suite("Intents command routing", .serialized)
@MainActor
struct IntentsCommandRoutingTests {
    private static func makeIsolatedDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omega-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    @Test("commands queue until drained, then the inbox is empty")
    func inboxQueues() {
        AppCommandInbox.removeAll()
        AppCommandInbox.submit(.showToday)
        AppCommandInbox.submit(.showOnThisDay)
        #expect(AppCommandInbox.pendingCount == 2)
        #expect(AppCommandInbox.drain() == [.showToday, .showOnThisDay])
        #expect(AppCommandInbox.pendingCount == 0)
    }

    @Test("deep links map to commands; foreign links are refused")
    func deepLinks() throws {
        AppCommandInbox.removeAll()
        defer { AppCommandInbox.removeAll() }
        let accepted: Set<String> = ["omegajournal-qa-test"]
        #expect(AppCommandInbox.open(try #require(URL(string: "omegajournal-qa-test://today")), acceptedSchemes: accepted))
        #expect(AppCommandInbox.open(try #require(URL(string: "omegajournal-qa-test://new")), acceptedSchemes: accepted))
        #expect(!AppCommandInbox.open(try #require(URL(string: "omegajournal://today")), acceptedSchemes: accepted),
                "a QA build must not answer production links")
        #expect(!AppCommandInbox.open(try #require(URL(string: "omegajournal-qa-test://wipe")), acceptedSchemes: accepted))
        #expect(AppCommandInbox.drain() == [.showToday, .newEntry(title: nil, body: nil, mood: nil)])
    }

    @Test("navigation commands select the sidebar item")
    func navigation() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        var selection: SidebarItem? = .all
        AppCommandHandling.perform(.showToday, vm: vm, selection: &selection)
        #expect(selection == .today)
        AppCommandHandling.perform(.showOnThisDay, vm: vm, selection: &selection)
        #expect(selection == .onThisDay)
    }

    @Test("new entry command creates an entry with title, text and mood")
    func newEntry() throws {
        try Self.makeIsolatedDatabase()
        let vm = JournalViewModel()
        var selection: SidebarItem? = .today
        let before = Set(vm.entries.map(\.id))
        AppCommandHandling.perform(.newEntry(title: "  From Shortcuts ", body: "Hello\n", mood: .great),
                                   vm: vm, selection: &selection)
        let created = try #require(vm.entries.first { !before.contains($0.id) })
        #expect(created.title == "From Shortcuts")
        #expect(created.body == "Hello")
        #expect(created.mood == .great)
        #expect(vm.db.fetchEntry(id: created.id)?.mood == .great)
        #expect(selection == .all)
        vm.db.hardDeleteEntry(id: created.id)
    }

    @Test("mood options map onto every journal mood")
    func moods() {
        let mapped = Set(JournalMoodOption.allCases.map(\.mood))
        #expect(mapped.count == JournalMoodOption.allCases.count)
        #expect(JournalMoodOption.caseDisplayRepresentations.count == JournalMoodOption.allCases.count)
    }

    @Test("intents that touch the journal open the app; progress does not need it")
    func openAppPolicy() {
        #expect(NewJournalEntryIntent.openAppWhenRun)
        #expect(QuickCaptureIntent.openAppWhenRun)
        #expect(OpenTodayIntent.openAppWhenRun)
        #expect(OpenOnThisDayIntent.openAppWhenRun)
        #expect(TodaysWritingProgressIntent.openAppWhenRun == false)
    }

    @Test("every intent has an App Shortcut whose phrases name the app")
    func shortcutsCoverIntents() {
        let shortcuts = OmegaJournalShortcuts.appShortcuts
        #expect(shortcuts.count == 5)
    }

    @Test("progress intent without an App Group answers without data")
    func progressWithoutGroup() {
        // Test bundles have no OJAppGroupIdentifier: nothing to read, nothing leaked.
        let state = WritingProgressSource.currentState()
        #expect(state.hasData == false)
    }
}

/// The app writes the snapshot from its in-memory entries; hidden entries'
/// content must never reach the file.
@Suite("Widget snapshot publisher", .serialized)
@MainActor
struct WidgetSnapshotPublisherTests {
    static func entry(_ title: String, _ body: String, hidden: Bool = false, created: Date = Date()) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title
        e.body = body
        e.isHidden = hidden
        e.createdAt = created
        e.updatedAt = created
        return e
    }

    @Test("facts skip word counting for hidden and past entries")
    func facts() {
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        let facts = WidgetSnapshotPublisher.facts(from: [
            Self.entry("t", "one two three", created: now),
            Self.entry("h", "secret words here", hidden: true, created: now),
            Self.entry("o", "old words", created: old),
        ], now: now)
        #expect(facts.map(\.wordCount) == [3, 0, 0])
        #expect(facts.map(\.isHidden) == [false, true, false])
    }

    @Test("published file never contains titles or bodies")
    func noContentInFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-pub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = WidgetSnapshotPublisher.makeSnapshot(entries: [
            Self.entry("Visible title XYZZY", "visible body PLUGH words"),
            Self.entry("Hidden title FROBOZZ", "hidden body GRUE", hidden: true),
        ], goals: GoalManager.shared)
        let store = WidgetSnapshotStore(directory: dir)
        try store.write(snapshot)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        for secret in ["XYZZY", "PLUGH", "FROBOZZ", "GRUE", "title", "body"] {
            #expect(!text.contains(secret), "snapshot leaked \(secret)")
        }
        #expect(snapshot.days[0].words == 4)
        #expect(snapshot.days[0].entries == 1)
    }

    @Test("test runs without a test App Group never publish")
    func testModeSkips() {
        let publisher = WidgetSnapshotPublisher()
        publisher.environment = ["OMEGA_JOURNAL_TEST_DATABASE_PATH": "/tmp/x.sqlite3"]
        publisher.infoDictionary = ["OJAppGroupIdentifier": OmegaJournalAppGroup.productionIdentifier]
        if case .publish = publisher.decision {
            Issue.record("test mode must not publish to the production group")
        }
        publisher.environment = [:]
        publisher.infoDictionary = nil
        if case .publish = publisher.decision {
            Issue.record("builds without an App Group must not publish")
        }
    }

    @Test("same numbers twice: one write, one reload")
    func dedupes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-pub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH",
               FileManager.default.temporaryDirectory.appendingPathComponent("oj-\(UUID().uuidString).sqlite3").path, 1)
        let vm = JournalViewModel()
        let publisher = WidgetSnapshotPublisher()
        publisher.storeOverride = WidgetSnapshotStore(directory: dir)
        var reloads = 0
        publisher.reloadTimelines = { reloads += 1 }
        let now = Date()
        #expect(publisher.publishNow(vm, now: now) != nil)
        #expect(publisher.publishNow(vm, now: now.addingTimeInterval(5)) == nil)
        #expect(reloads == 1)
        #expect(WidgetSnapshotStore(directory: dir).read() != nil)
    }
}
