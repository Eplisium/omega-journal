import Foundation
import Testing
import OmegaJournalCore
import OmegaJournalShared

/// The widget snapshot is the only journal data that leaves the encrypted
/// database (into the App Group container), so these tests pin down exactly
/// what it may contain: counts, streak, prompt and a date. Never text.
@Suite("Widget snapshot model")
struct WidgetSnapshotTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Wednesday 2026-10-28 15:00 New York.
    static let now: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15))!
    }()

    static func day(_ offset: Int, hour: Int = 10) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: offset, to: start)!)!
    }

    static func prompt(_ date: Date) -> String {
        "Prompt for \(calendar.component(.day, from: date))"
    }

    static func build(_ facts: [WidgetEntryFact], goal: Int = 250, mode: StreakMode = .dailyWithRest) -> WidgetSnapshot {
        WidgetSnapshotBuilder.build(facts: facts, dailyWordGoal: goal, streakMode: mode,
                                    prompt: prompt, now: now, calendar: calendar)
    }

    // MARK: Builder

    @Test("today's words and entries count visible entries only")
    func todayCountsVisibleOnly() {
        let snapshot = Self.build([
            WidgetEntryFact(createdAt: Self.day(0), wordCount: 120, isHidden: false),
            WidgetEntryFact(createdAt: Self.day(0, hour: 12), wordCount: 30, isHidden: false),
            WidgetEntryFact(createdAt: Self.day(0, hour: 13), wordCount: 900, isHidden: true),
            WidgetEntryFact(createdAt: Self.day(0, hour: 14), wordCount: 500, isHidden: false, isTrashed: true),
            WidgetEntryFact(createdAt: Self.day(0, hour: 14), wordCount: 400, isHidden: false, isArchived: true),
        ])
        let today = snapshot.days[0]
        #expect(today.words == 150)
        #expect(today.entries == 2)
        #expect(today.writtenToday)
        #expect(today.prompt == "Prompt for 28")
    }

    @Test("a hidden-only day does not count toward the streak or last-written date")
    func hiddenEntriesInvisible() {
        let snapshot = Self.build([
            WidgetEntryFact(createdAt: Self.day(-1), wordCount: 10, isHidden: false),
            WidgetEntryFact(createdAt: Self.day(0), wordCount: 10, isHidden: true),
        ])
        #expect(snapshot.days[0].streak == 1, "yesterday only; today's hidden entry must not extend it")
        #expect(snapshot.days[0].writtenToday == false)
        #expect(snapshot.lastWrittenAt == Self.day(-1))
    }

    @Test("daily streak counts consecutive days ending today")
    func dailyStreak() {
        let facts = (-4...0).map { WidgetEntryFact(createdAt: Self.day($0), wordCount: 5, isHidden: false) }
        let snapshot = Self.build(facts)
        #expect(snapshot.days[0].streak == 5)
        #expect(snapshot.streakUnit == "day")
    }

    @Test("lookahead rows: words reset, streak decays, prompt advances")
    func lookahead() {
        let snapshot = Self.build([WidgetEntryFact(createdAt: Self.day(0), wordCount: 80, isHidden: false),
                                   WidgetEntryFact(createdAt: Self.day(-1), wordCount: 80, isHidden: false)])
        #expect(snapshot.days.count == WidgetSnapshotBuilder.defaultDaysAhead + 1)
        let tomorrow = snapshot.days[1]
        #expect(Self.calendar.isDate(tomorrow.dayStart, inSameDayAs: Self.day(1)))
        #expect(tomorrow.words == 0)
        #expect(tomorrow.writtenToday == false)
        #expect(tomorrow.streak == 2, "streak still alive tomorrow until the day ends")
        #expect(tomorrow.prompt == "Prompt for 29")
        // Each row matches what the app itself would show on that day.
        let writingDays: Set<Date> = [Self.calendar.startOfDay(for: Self.day(0)), Self.calendar.startOfDay(for: Self.day(-1))]
        for row in snapshot.days {
            let expected = StreakCalculator.summary(writingDays: writingDays, mode: .dailyWithRest, weeklyTarget: 3,
                                                    today: row.dayStart, calendar: Self.calendar).current
            #expect(row.streak == expected)
        }
        #expect(snapshot.days.last?.streak == 0, "a week without writing breaks the streak")
    }

    @Test("future-dated entries are planned, not written")
    func futureEntries() {
        let snapshot = Self.build([WidgetEntryFact(createdAt: Self.day(2), wordCount: 50, isHidden: false)])
        #expect(snapshot.days[0].words == 0)
        #expect(snapshot.lastWrittenAt == nil)
        #expect(snapshot.days[2].words == 50)
    }

    @Test("goal is at least 1")
    func goalFloor() {
        #expect(Self.build([], goal: 0).dailyWordGoal == 1)
    }

    @Test("the JSON has only counts, dates and the prompt")
    func jsonHasNoContentFields() throws {
        let snapshot = Self.build([WidgetEntryFact(createdAt: Self.day(0), wordCount: 42, isHidden: false)])
        let data = try WidgetSnapshotStore.encode(snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "generatedAt", "dailyWordGoal", "streakUnit", "lastWrittenAt", "days"])
        let day = try #require((object["days"] as? [[String: Any]])?.first)
        #expect(Set(day.keys) == ["dayStart", "words", "entries", "streak", "writtenToday", "prompt"])
    }

    // MARK: Display

    @Test("display state for now, tomorrow and after the lookahead")
    func displayStates() {
        let snapshot = Self.build([WidgetEntryFact(createdAt: Self.day(0), wordCount: 300, isHidden: false)])
        let today = WidgetDisplay.state(for: snapshot, at: Self.now, calendar: Self.calendar)
        #expect(today.hasData)
        #expect(today.words == 300)
        #expect(today.goalMet)
        #expect(today.progress == 1)
        #expect(today.lastWrittenText == "Today")

        let tomorrow = WidgetDisplay.state(for: snapshot, at: Self.day(1, hour: 0), calendar: Self.calendar)
        #expect(tomorrow.words == 0)
        #expect(tomorrow.lastWrittenText == "Yesterday")

        let later = WidgetDisplay.state(for: snapshot, at: Self.day(30), calendar: Self.calendar)
        #expect(later.hasData == false, "past the lookahead the widget asks to open the app")
    }

    @Test("unknown snapshot versions are ignored")
    func versionMismatch() {
        var snapshot = Self.build([])
        snapshot.version = 99
        #expect(WidgetDisplay.state(for: snapshot, at: Self.now, calendar: Self.calendar).hasData == false)
        #expect(WidgetDisplay.state(for: nil, at: Self.now).hasData == false)
    }

    @Test("relative last-written text", arguments: [
        (0, "Today"), (1, "Yesterday"), (5, "5 days ago"), (20, "2 weeks ago"), (90, "3 months ago"), (800, "2 years ago"),
    ])
    func lastWritten(daysAgo: Int, expected: String) {
        let text = WidgetDisplay.lastWrittenText(Self.day(-daysAgo), relativeTo: Self.now, calendar: Self.calendar)
        #expect(text == expected)
        #expect(WidgetDisplay.lastWrittenText(nil, relativeTo: Self.now) == "No entries yet")
    }

    @Test("timeline: now plus each upcoming midnight")
    func timeline() {
        let snapshot = Self.build([])
        let dates = WidgetDisplay.timelineDates(for: snapshot, now: Self.now, calendar: Self.calendar)
        #expect(dates.first == Self.now)
        #expect(dates.count == WidgetSnapshotBuilder.defaultDaysAhead + 1)
        #expect(dates.dropFirst().allSatisfy { Self.calendar.startOfDay(for: $0) == $0 && $0 > Self.now })
        #expect(WidgetDisplay.timelineDates(for: nil, now: Self.now) == [Self.now])
    }

    @Test("progress sentence speaks counts only")
    func progressSentence() {
        let state = WidgetDisplayState(date: Self.now, words: 120, goal: 250, streak: 3, streakUnit: "day",
                                       writtenToday: true, prompt: "secret prompt?", lastWrittenText: "Today", hasData: true)
        #expect(WidgetDisplay.progressSentence(state) == "120 words today. 130 to go for your 250-word goal. Streak: 3 days.")
        #expect(!WidgetDisplay.progressSentence(state).contains("secret"))
        #expect(WidgetDisplay.progressSentence(.empty(at: Self.now)).contains("Open Omega Journal"))
    }

    // MARK: Store

    @Test("store round trip; corrupt or missing files read as nil")
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-widget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WidgetSnapshotStore(directory: dir)
        #expect(store.read() == nil)
        let snapshot = Self.build([WidgetEntryFact(createdAt: Self.day(0), wordCount: 7, isHidden: false)])
        try store.write(snapshot)
        #expect(store.read() == snapshot)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)
    }
}

@Suite("Widget links and App Group policy")
struct WidgetLinkTests {
    @Test("routes round-trip through their URLs")
    func roundTrip() {
        for link in OmegaJournalLink.allCases {
            #expect(OmegaJournalLink.parse(link.url(), acceptedSchemes: ["omegajournal"]) == link)
            let qa = link.url(scheme: "omegajournal-qa-x")
            #expect(OmegaJournalLink.parse(qa, acceptedSchemes: ["omegajournal-qa-x"]) == link)
        }
        #expect(OmegaJournalLink.newEntry.url().absoluteString == "omegajournal://new")
    }

    @Test("foreign schemes, unknown routes and payloads are rejected or ignored")
    func rejects() throws {
        let accepted: Set<String> = ["omegajournal"]
        #expect(OmegaJournalLink.parse(try #require(URL(string: "omegajournal-qa-x://new")), acceptedSchemes: accepted) == nil)
        #expect(OmegaJournalLink.parse(try #require(URL(string: "https://new")), acceptedSchemes: accepted) == nil)
        #expect(OmegaJournalLink.parse(try #require(URL(string: "omegajournal://delete-all")), acceptedSchemes: accepted) == nil)
        #expect(OmegaJournalLink.parse(try #require(URL(string: "OMEGAJOURNAL://Today")), acceptedSchemes: accepted) == .today)
        #expect(OmegaJournalLink.parse(try #require(URL(string: "omegajournal:on-this-day")), acceptedSchemes: accepted) == .onThisDay)
        #expect(OmegaJournalLink.parse(try #require(URL(string: "omegajournal://new?body=hi#x")), acceptedSchemes: accepted) == .newEntry)
    }

    @Test("URL scheme per bundle id", arguments: [
        ("com.eplisium.omega-journal", "omegajournal"),
        ("com.eplisium.omega-journal.qa-widgets", "omegajournal-qa-widgets"),
        ("com.eplisium.omega-journal.QA_x", "omegajournal-qa-x"),
        ("com.example.other", "omegajournal"),
    ])
    func schemes(bundleId: String, expected: String) {
        #expect(OmegaJournalLink.scheme(forBundleIdentifier: bundleId) == expected)
    }

    @Test("App Group id comes from Info.plist, never from an unreplaced token")
    func groupFromInfo() {
        #expect(OmegaJournalAppGroup.identifier(infoDictionary: ["OJAppGroupIdentifier": "WWC5HJN6AL.x"]) == "WWC5HJN6AL.x")
        #expect(OmegaJournalAppGroup.identifier(infoDictionary: ["OJAppGroupIdentifier": "@APP_GROUP@"]) == nil)
        #expect(OmegaJournalAppGroup.identifier(infoDictionary: [:]) == nil)
        #expect(OmegaJournalAppGroup.identifier(infoDictionary: nil) == nil)
    }

    @Test("test runs never publish to the production group")
    func publishPolicy() {
        let prod = OmegaJournalAppGroup.productionIdentifier
        let testDB = ["OMEGA_JOURNAL_TEST_DATABASE_PATH": "/tmp/j.sqlite3"]
        #expect(OmegaJournalAppGroup.publishDecision(bundleGroup: prod, environment: [:]) == .publish(groupIdentifier: prod))
        #expect(OmegaJournalAppGroup.publishDecision(bundleGroup: nil, environment: [:]) != .publish(groupIdentifier: prod))
        if case .publish = OmegaJournalAppGroup.publishDecision(bundleGroup: prod, environment: testDB) {
            Issue.record("test database must not publish without an explicit test group")
        }
        var env = testDB
        env["OMEGA_JOURNAL_TEST_APP_GROUP"] = prod
        if case .publish = OmegaJournalAppGroup.publishDecision(bundleGroup: prod, environment: env) {
            Issue.record("test runs must refuse the production group")
        }
        env["OMEGA_JOURNAL_TEST_APP_GROUP"] = "WWC5HJN6AL.com.eplisium.omega-journal.qa-x"
        #expect(OmegaJournalAppGroup.publishDecision(bundleGroup: prod, environment: env)
                == .publish(groupIdentifier: "WWC5HJN6AL.com.eplisium.omega-journal.qa-x"))
    }
}
