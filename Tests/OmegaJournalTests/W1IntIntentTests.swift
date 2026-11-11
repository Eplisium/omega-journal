import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

@Suite("W1Int Siri entity privacy")
struct W1IntIntentCatalogTests {
    static let day: TimeInterval = 86_400
    static let base = Date(timeIntervalSince1970: 1_765_800_000) // 2025-12-15 12:00 UTC
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static let records: [IntentEntryRecord] = [
        IntentEntryRecord(id: "a", title: "Morning run", searchText: "felt strong by the river", createdAt: base,
                          mood: 5, moodName: "great", tags: ["fitness", "outdoors"], journalId: "J1"),
        IntentEntryRecord(id: "b", title: "Therapy notes", searchText: "river of worries", createdAt: base.addingTimeInterval(-day),
                          mood: 2, moodName: "bad", tags: ["private-tag"], journalId: "J1", isHidden: true),
        IntentEntryRecord(id: "c", title: "Old draft", searchText: "river", createdAt: base.addingTimeInterval(-2 * day),
                          tags: ["fitness"], journalId: "J2", isTrashed: true),
        IntentEntryRecord(id: "d", title: "Run club", searchText: "met people", createdAt: base.addingTimeInterval(-3 * day),
                          mood: 4, moodName: "good", tags: ["fitness/club"], journalId: "J2", isArchived: true),
    ]

    @Test func hiddenRecordsNeverCarryBodyOrTags() {
        let hidden = Self.records[1]
        #expect(hidden.searchText.isEmpty)
        #expect(hidden.tags.isEmpty)
    }

    @Test func lockedHiddenAndTrashedAreLeftOut() {
        let ids = IntentEntryCatalog.visible(Self.records, hiddenLocked: true, appLocked: false).map(\.id)
        #expect(ids == ["a", "d"])
        let unlocked = IntentEntryCatalog.visible(Self.records, hiddenLocked: false, appLocked: false).map(\.id)
        #expect(unlocked == ["a", "b", "d"])
    }

    @Test func appLockHidesEverything() {
        #expect(IntentEntryCatalog.visible(Self.records, hiddenLocked: false, appLocked: true).isEmpty)
        #expect(IntentEntryCatalog.find(IntentEntryFilter(), in: Self.records, hiddenLocked: false, appLocked: true).isEmpty)
        #expect(IntentEntryCatalog.tags(in: Self.records, hiddenLocked: false, appLocked: true).isEmpty)
        #expect(IntentEntryCatalog.entries(ids: ["a"], in: Self.records, hiddenLocked: false, appLocked: true).isEmpty)
    }

    @Test func lookupByIdRespectsTheLock() {
        #expect(IntentEntryCatalog.entries(ids: ["b", "a", "c"], in: Self.records, hiddenLocked: true, appLocked: false).map(\.id) == ["a"])
        let unlocked = IntentEntryCatalog.entries(ids: ["b"], in: Self.records, hiddenLocked: false, appLocked: false)
        #expect(unlocked.map(\.id) == ["b"])
        #expect(unlocked.first?.tags == [])
        #expect(unlocked.first?.title == "Therapy notes")
    }

    @Test func titleSearchMatchesTitlesOnly() {
        #expect(IntentEntryCatalog.titleMatches("run", in: Self.records, hiddenLocked: true, appLocked: false).map(\.id) == ["d", "a"]
                || IntentEntryCatalog.titleMatches("run", in: Self.records, hiddenLocked: true, appLocked: false).map(\.id) == ["a", "d"])
        // "Run club" starts with the query, so it ranks first.
        #expect(IntentEntryCatalog.titleMatches("run", in: Self.records, hiddenLocked: true, appLocked: false).first?.id == "d")
        #expect(IntentEntryCatalog.titleMatches("river", in: Self.records, hiddenLocked: false, appLocked: false).isEmpty)
        #expect(IntentEntryCatalog.titleMatches("therapy", in: Self.records, hiddenLocked: true, appLocked: false).isEmpty)
    }

    @Test func findUsesBodyOnlyForOrdinaryEntries() {
        let f = IntentEntryFilter(text: "river")
        // Hidden "b" mentions the river in its body: never matched, even unlocked. Trashed "c" never.
        #expect(IntentEntryCatalog.find(f, in: Self.records, hiddenLocked: false, appLocked: false).map(\.id) == ["a"])
        #expect(IntentEntryCatalog.find(IntentEntryFilter(text: "therapy"), in: Self.records, hiddenLocked: false, appLocked: false)
            .map(\.id) == ["b"])
        #expect(IntentEntryCatalog.find(IntentEntryFilter(text: "therapy"), in: Self.records, hiddenLocked: true, appLocked: false).isEmpty)
        #expect(IntentEntryCatalog.find(IntentEntryFilter(text: "river -strong"), in: Self.records, hiddenLocked: false, appLocked: false).isEmpty)
    }

    @Test func findByTagNotebookAndDates() {
        let byTag = IntentEntryCatalog.find(IntentEntryFilter(tag: "#Fitness"), in: Self.records, hiddenLocked: false, appLocked: false)
        #expect(byTag.map(\.id) == ["a", "d"])
        // A hidden entry's tags are never searchable.
        #expect(IntentEntryCatalog.find(IntentEntryFilter(tag: "private-tag"), in: Self.records, hiddenLocked: false, appLocked: false).isEmpty)
        #expect(IntentEntryCatalog.find(IntentEntryFilter(journalId: "J2"), in: Self.records, hiddenLocked: false, appLocked: false)
            .map(\.id) == ["d"])
        let range = IntentEntryFilter(from: Self.base.addingTimeInterval(-Self.day), to: Self.base.addingTimeInterval(-Self.day))
        #expect(IntentEntryCatalog.find(range, in: Self.records, hiddenLocked: false, appLocked: false, calendar: Self.utc).map(\.id) == ["b"])
        #expect(IntentEntryCatalog.find(IntentEntryFilter(limit: 1), in: Self.records, hiddenLocked: false, appLocked: false).count == 1)
    }

    @Test func tagListSkipsHiddenAndTrashed() {
        let tags = IntentEntryCatalog.tags(in: Self.records, hiddenLocked: false, appLocked: false)
        #expect(tags.map(\.name) == ["fitness", "fitness/club", "outdoors"])
        #expect(!tags.contains { $0.name == "private-tag" })
    }

    @Test func todaysEntrySkipsHiddenArchivedAndTrashed() {
        let now = Self.base.addingTimeInterval(3_600)
        let recs = [
            IntentEntryRecord(id: "x", title: "", createdAt: Self.base.addingTimeInterval(-60)),
            IntentEntryRecord(id: "y", title: "", createdAt: Self.base.addingTimeInterval(60), isHidden: true),
            IntentEntryRecord(id: "z", title: "", createdAt: Self.base.addingTimeInterval(120), isArchived: true),
            IntentEntryRecord(id: "w", title: "", createdAt: Self.base.addingTimeInterval(-Self.day)),
        ]
        #expect(IntentEntryCatalog.todaysEntryId(in: recs, now: now, calendar: Self.utc) == "x")
        #expect(IntentEntryCatalog.todaysEntryId(in: Array(recs.dropFirst()), now: now, calendar: Self.utc) == nil)
    }

    @Test func appendingKeepsTheStampLast() {
        let body = PlaceStampCodec.join(stamp: PlaceStamp(location: "Paris", weather: "Sunny"), rest: "First thought.\n")
        let out = IntentEntryCatalog.appending("  Second thought. ", to: body)
        let (stamp, rest) = PlaceStampCodec.split(out)
        #expect(rest == "First thought.\n\nSecond thought.")
        #expect(stamp?.location == "Paris")
        #expect(stamp?.weather == "Sunny")
        #expect(IntentEntryCatalog.appending("Hi", to: "") == "Hi")
        #expect(IntentEntryCatalog.appending("   ", to: "Keep") == "Keep")
    }

    @Test func moodOptionRoundTrips() {
        #expect((1...5).map { JournalMoodOption(rawMood: $0) } == [.awful, .bad, .neutral, .good, .great])
    }
}

@Suite("W1Int Siri commands", .serialized)
@MainActor
struct W1IntIntentCommandTests {
    private func makeVM() throws -> (JournalViewModel, URL) {
        TestSharedEnvironment.pin()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w1int-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        return (JournalViewModel(database: db), root)
    }

    @Test func appendGoesToTodaysEntryOrStartsOne() throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        var selection: SidebarItem? = .calendar
        AppCommandHandling.appendToToday("First", vm: vm, selection: &selection)
        #expect(selection == .all)
        #expect(vm.entries.count == 1)
        let id = try #require(vm.entries.first?.id)
        vm.stopEditing()
        AppCommandHandling.appendToToday("Second", vm: vm, selection: &selection)
        #expect(vm.entries.count == 1)
        #expect(vm.db.fetchEntry(id: id)?.body == "First\n\nSecond")
    }

    @Test func appendWhileEditingDoesNotLoseText() throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = vm.createEntry(body: "Draft")
        #expect(vm.editingEntryId == entry.id)
        var selection: SidebarItem?
        AppCommandHandling.appendToToday("Added", vm: vm, selection: &selection)
        #expect(vm.db.fetchEntry(id: entry.id)?.body == "Draft\n\nAdded")
        #expect(vm.editingEntryId == entry.id)
        #expect(vm.entry(id: entry.id)?.body == "Draft\n\nAdded")
    }

    @Test func appendNeverWritesIntoAHiddenEntry() throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = vm.createEntry(body: "Secret", isHidden: true)
        vm.stopEditing()
        var selection: SidebarItem?
        AppCommandHandling.appendToToday("Public note", vm: vm, selection: &selection)
        #expect(vm.db.fetchEntry(id: hidden.id)?.body == "Secret")
        #expect(vm.db.fetchAllEntriesForExport().contains { $0.body == "Public note" && !$0.isHidden })
    }

    @Test func logMoodSetsTodaysEntryOrCreatesACheckIn() throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        var selection: SidebarItem?
        AppCommandHandling.logMood(.good, vm: vm, selection: &selection)
        let created = try #require(vm.db.fetchAllEntriesForExport().first)
        #expect(created.mood == .good)
        #expect(created.title == "Mood check-in")
        AppCommandHandling.logMood(.awful, vm: vm, selection: &selection)
        #expect(vm.db.fetchAllEntriesForExport().count == 1)
        #expect(vm.db.fetchEntry(id: created.id)?.mood == .awful)
    }

    @Test(.lockState) func bridgeAnswersOnlyWhileAttached() async throws {
        let (vm, root) = try makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        IntentJournalBridge.detach()
        #expect(throws: JournalIntentError.self) { try IntentJournalBridge.snapshot() }
        vm.createEntry(title: "Visible", body: "words")
        vm.createEntry(title: "Secret title", body: "secret words", tags: ["x"], isHidden: true)
        vm.stopEditing()
        IntentJournalBridge.attach(vm)
        defer { IntentJournalBridge.detach() }
        let snap = try IntentJournalBridge.snapshot()
        let hidden = try #require(snap.records.first { $0.title == "Secret title" })
        #expect(hidden.searchText.isEmpty && hidden.tags.isEmpty)
        #expect(snap.records.first { $0.title == "Visible" }?.searchText == "words")
    }
}
