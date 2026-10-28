import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Regression tests for audit group D (browse / calendar / insights / today /
/// stats core / entry model).
@Suite("Audit fixes D")
@MainActor
struct AuditFixesDTests {
    static func gregorian(_ tz: String = "UTC") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12, cal: Calendar = gregorian()) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    static func entry(title: String = "T", body: String = "", tags: [String] = [], hidden: Bool = false,
                      createdAt: Date = Date(), attachments: Int = 0) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title
        e.body = body
        e.tags = tags
        e.isHidden = hidden
        e.createdAt = createdAt
        e.attachments = (0..<attachments).map {
            Attachment(id: "a\($0)", entryId: e.id, filename: "f\($0).png", mimeType: "image/png", createdAt: createdAt)
        }
        return e
    }

    // MARK: 3 — word count excludes stamp comment

    @Test("wordCount ignores the trailing stamp comment")
    func wordCountIgnoresStamp() {
        let body = "hello there world\n\n<!-- stamp: loc=Paris%2C%20France; wx=Sunny -->"
        #expect(Self.entry(body: body).wordCount == 3)
        #expect(Self.entry(body: "one two\tthree\nfour").wordCount == 4)
        #expect(Self.entry(body: "").wordCount == 0)
    }

    // MARK: 7 — quoted phrases stay one term

    @Test("quoted phrase is one search term")
    func quotedPhraseTerm() {
        #expect(SearchQuery.parse("\"exact phrase\" other").terms == ["exact phrase", "other"])
        #expect(SearchQuery.parse("tag:work \"exact phrase\"").terms == ["exact phrase"])
        let q = SearchQuery.parse("\"exact phrase\"")
        func rec(_ body: String) -> SearchQuery.Record {
            SearchQuery.Record(id: "1", title: "t", body: body, tags: [], moodName: "Good", moodValue: 4, createdAt: Date())
        }
        #expect(q.matches(rec("an exact phrase here"), hiddenLocked: false))
        #expect(!q.matches(rec("phrase then exact"), hiddenLocked: false))
    }

    // MARK: 8 — streaks survive a midnight DST transition

    @Test("streak runs do not break across a midnight DST jump")
    func streakAcrossDST() {
        let cal = Self.gregorian("America/Sao_Paulo")
        let days = Set((2...6).map { Self.date(2018, 11, $0, cal: cal) })
        #expect(StreakHistory.runs(days: days, calendar: cal).map(\.length) == [5])
    }

    // MARK: 10 — DayKey always Gregorian

    @Test("DayKey uses Gregorian digits under non-Gregorian calendars")
    func dayKeyGregorian() {
        var jp = Calendar(identifier: .japanese)
        jp.timeZone = TimeZone(identifier: "UTC")!
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC")!
        let d = Self.date(2026, 3, 4)
        #expect(DayKey.string(from: d, calendar: jp) == "2026-03-04")
        #expect(DayKey.string(from: d, calendar: buddhist) == "2026-03-04")
        #expect(DayKey.string(from: d, calendar: Self.gregorian()) == "2026-03-04")
        let back = DayKey.date(from: "2026-03-04", calendar: jp)
        #expect(back.map { DayKey.string(from: $0, calendar: Self.gregorian()) } == "2026-03-04")
        // Time zone is still honoured.
        let tokyo = Self.gregorian("Asia/Tokyo")
        #expect(DayKey.string(from: Self.date(2026, 3, 4, hour: 20), calendar: tokyo) == "2026-03-05")
    }

    // MARK: 13 — future dates are not "Today"

    @Test("future dates bucket as Upcoming, not Today")
    func futureBucket() {
        let cal = Self.gregorian()
        let now = Self.date(2026, 3, 10)
        #expect(EntryGrouping.bucketTitle(for: Self.date(2026, 3, 10, hour: 23), now: now, calendar: cal) == "Today")
        #expect(EntryGrouping.bucketTitle(for: Self.date(2026, 3, 12), now: now, calendar: cal) == "Upcoming")
    }

    // MARK: 14 — Feb 29 surfaces on Feb 28 of non-leap years

    @Test("On This Day includes Feb 29 memories on Feb 28 of a non-leap year")
    func leapDayOnThisDay() {
        let cal = Self.gregorian()
        let leap = Self.date(2024, 2, 29)
        let regular = Self.date(2025, 2, 28)
        let groups = OnThisDayGrouping.group([leap, regular], date: { $0 }, reference: Self.date(2027, 2, 28), calendar: cal)
        #expect(groups.map(\.year) == [2025, 2024])
        // In a leap year Feb 29 has its own day.
        let leapYear = OnThisDayGrouping.group([leap, regular], date: { $0 }, reference: Self.date(2028, 2, 28), calendar: cal)
        #expect(leapYear.map(\.year) == [2025])
    }

    // MARK: 15 — Last 7 / 30 days cover exactly 7 / 30 days

    @Test("Last 7/30 day ranges start 6/29 days back, like AnalyticsPeriod")
    func lastNDays() {
        let cal = Self.gregorian()
        let now = Self.date(2026, 3, 10)
        let sod = cal.startOfDay(for: now)
        #expect(SmartFolder.DateRange.last7.start(now: now, calendar: cal) == cal.date(byAdding: .day, value: -6, to: sod))
        #expect(SmartFolder.DateRange.last30.start(now: now, calendar: cal) == cal.date(byAdding: .day, value: -29, to: sod))
        let cur = Calendar.current
        let today = cur.startOfDay(for: Date())
        #expect(EntryFilter.DateRange.last7.startDate == cur.date(byAdding: .day, value: -6, to: today))
        #expect(EntryFilter.DateRange.last30.startDate == cur.date(byAdding: .day, value: -29, to: today))
    }

    // MARK: 1 — Today hero card masks locked hidden entries

    @Test("Today hero hides preview and tags of a locked hidden entry")
    func todayHeroMasking() {
        let e = Self.entry(title: "Secret", body: "private words", tags: ["diary"], hidden: true)
        let locked = TodayHeroContent(entry: e, hiddenLocked: true)
        #expect(locked.isMasked)
        #expect(locked.tags.isEmpty)
        #expect(!locked.preview.contains("private"))
        let unlocked = TodayHeroContent(entry: e, hiddenLocked: false)
        #expect(unlocked.preview == "private words")
        #expect(unlocked.tags == ["diary"])
        let visible = TodayHeroContent(entry: Self.entry(body: "open", tags: ["x"]), hiddenLocked: true)
        #expect(visible.preview == "open" && visible.tags == ["x"])
    }

    // MARK: 2 — filter facets and tag list respect masking

    @Test("EntryFilter content facets never match locked hidden entries")
    func filterMasking() {
        let hidden = Self.entry(body: "one two three four", tags: ["work"], hidden: true, attachments: 1)
        var f = EntryFilter()
        f.tags = ["work"]
        #expect(f.matches(hidden, hiddenLocked: false))
        #expect(!f.matches(hidden, hiddenLocked: true))
        f = EntryFilter(); f.minWords = 2
        #expect(f.matches(hidden, hiddenLocked: false))
        #expect(!f.matches(hidden, hiddenLocked: true))
        f = EntryFilter(); f.withAttachmentsOnly = true
        #expect(f.matches(hidden, hiddenLocked: false))
        #expect(!f.matches(hidden, hiddenLocked: true))
        // Title/mood/date facets still apply to masked cards.
        f = EntryFilter(); f.moods = [hidden.mood]
        #expect(f.matches(hidden, hiddenLocked: true))
    }

    @Test("tag collection includes descendants and excludes locked hidden entries")
    func tagCollection() {
        let child = Self.entry(tags: ["work/alpha"])
        let exact = Self.entry(tags: ["Work"])
        let other = Self.entry(tags: ["workshop"])
        let hidden = Self.entry(tags: ["work"], hidden: true)
        let all = [child, exact, other, hidden]
        #expect(EntryFilter.entries(all, taggedWith: "work", hiddenLocked: true).map(\.id) == [child.id, exact.id])
        #expect(EntryFilter.entries(all, taggedWith: "work", hiddenLocked: false).map(\.id) == [child.id, exact.id, hidden.id])
    }

    // MARK: 3 — shared word counter

    @Test("countWords strips the stamp and uses editor whitespace rules")
    func countWords() {
        #expect(JournalEntry.countWords("a b\n\n<!-- stamp: wx=Rain -->") == 2)
        #expect(JournalEntry.countWords("a\u{00A0}b") == MarkdownLogic.wordCount("a\u{00A0}b"))
        #expect(JournalEntry.countWords("") == 0)
    }

    // MARK: 4/5 — Insights drill-through sheet coordination

    @Test("entry dismissal stops editing using the remembered entry id")
    func drillThroughDismissStopsEditing() {
        var p = DrillThroughPresentation()
        p.presentEntry(id: "e1")
        #expect(p.presentedEntry?.entryID == "e1")
        p.presentedEntry = nil   // sheet(item:) clears the binding before onDismiss runs
        #expect(p.entryDismissed(editingEntryId: "e1") == true)
        #expect(p.entryDismissed(editingEntryId: "e1") == false)
        p.presentEntry(id: "e2")
        p.presentedEntry = nil
        #expect(p.entryDismissed(editingEntryId: "other") == false)
    }

    @Test("opening an entry from the day sheet dismisses it first")
    func drillThroughFromDaySheet() {
        var p = DrillThroughPresentation()
        p.presentedDay = DayEntriesRoute(day: Self.date(2026, 3, 4))
        p.presentEntry(id: "e1")
        #expect(p.presentedDay == nil)
        #expect(p.presentedEntry == nil, "must not stack a second sheet while the day sheet is up")
        let pending = p.dayDismissed()
        #expect(pending == "e1")
        #expect(p.dayDismissed() == nil)
        p.presentEntry(id: pending!)
        #expect(p.presentedEntry?.entryID == "e1")
    }

    // MARK: 6 — heatmap stats only cover the grid window

    @Test("heatmap stats ignore days outside the grid; coverage capped at 100%")
    func heatmapWindowStats() {
        let cal = Self.gregorian()
        let today = cal.startOfDay(for: Self.date(2026, 3, 10))
        let start = cal.date(byAdding: .day, value: -2, to: today)!
        let old = cal.date(byAdding: .day, value: -40, to: today)!
        let counts: [Date: Int] = [today: 2, start: 1, old: 9]
        let s = HeatmapView.windowStats(counts: counts, windowStart: start, today: today, calendar: cal)
        #expect(s.total == 3)
        #expect(s.activeDays == 2)
        #expect(s.maxDay == 2)
        #expect(s.coverage == 67)
        let full: [Date: Int] = Dictionary(uniqueKeysWithValues: (0...40).map { (cal.date(byAdding: .day, value: -$0, to: today)!, 1) })
        #expect(HeatmapView.windowStats(counts: full, windowStart: start, today: today, calendar: cal).coverage == 100)
    }

    // MARK: 8 — current streak across DST

    @Test("current streak survives a midnight DST jump")
    func currentStreakDST() {
        let cal = Self.gregorian("America/Sao_Paulo")
        let days = Set((2...6).map { Self.date(2018, 11, $0, cal: cal) })
        #expect(StreakHistory.currentLength(days: days, today: Self.date(2018, 11, 6, cal: cal), calendar: cal) == 5)
        #expect(StreakHistory.currentLength(days: days, today: Self.date(2018, 11, 7, cal: cal), calendar: cal) == 5)
        #expect(StreakHistory.currentLength(days: days, today: Self.date(2018, 11, 8, cal: cal), calendar: cal) == 0)
    }

    // MARK: 9 — years ago ignores time of day

    @Test("years ago counts calendar years even when the old entry was later in the day")
    func yearsAgo() {
        let cal = Self.gregorian()
        let now = Self.date(2026, 3, 4, hour: 8)
        #expect(OnThisDayGrouping.yearsAgo(Self.date(2025, 3, 4, hour: 22), reference: now, calendar: cal) == 1)
        #expect(OnThisDayGrouping.yearsAgo(Self.date(2023, 3, 4, hour: 23), reference: now, calendar: cal) == 3)
    }

    // MARK: 11 — weekday header ids are unique

    @Test("calendar weekday headers have unique ids despite repeated symbols")
    func weekdayHeaderIds() {
        var cal = Self.gregorian()
        cal.firstWeekday = 2
        let headers = CalendarView.weekdayHeaders(calendar: cal)
        #expect(headers.count == 7)
        #expect(Set(headers.map(\.id)).count == 7)
        #expect(headers.map(\.symbol) == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(headers.first?.id == 2)
    }

    // MARK: 12 — section ids never collide with Pinned

    @Test("a collection titled Pinned does not collide with the pinned section")
    func pinnedSectionIdentity() {
        let now = Self.date(2026, 3, 4)
        let items = [EntryGroupItem(id: "a", date: now, isPinned: true),
                     EntryGroupItem(id: "b", date: now, isPinned: false)]
        let sections = EntryGrouping.sections(for: items, groupByDate: false, fallbackTitle: "Pinned",
                                              now: now, calendar: Self.gregorian())
        #expect(sections.count == 2)
        #expect(sections.map(\.title) == ["Pinned", "Pinned"])
        #expect(Set(sections.map(\.id)).count == 2)
        #expect(sections.map(\.isPinned) == [true, false])
    }

    @Test("upcoming entries keep list order")
    func upcomingKeepsListOrder() {
        let cal = Self.gregorian()
        let now = Self.date(2026, 3, 10)
        let items = [EntryGroupItem(id: "f", date: Self.date(2026, 3, 20), isPinned: false),
                     EntryGroupItem(id: "t", date: now, isPinned: false)]
        let sections = EntryGrouping.sections(for: items, groupByDate: true, fallbackTitle: "x", now: now, calendar: cal)
        #expect(sections.map(\.title) == ["Upcoming", "Today"])
    }

    // MARK: 14 — VM On This Day uses the leap-day rule

    @Test("VM onThisDay matches Feb 29 on Feb 28 of a non-leap year")
    func vmOnThisDayLeap() {
        let cal = Self.gregorian()
        let leap = Self.entry(createdAt: Self.date(2024, 2, 29))
        let same = Self.entry(createdAt: Self.date(2025, 2, 28))
        let thisYear = Self.entry(createdAt: Self.date(2027, 2, 28, hour: 6))
        let out = JournalViewModel.onThisDay(in: [leap, same, thisYear], reference: Self.date(2027, 2, 28), calendar: cal)
        #expect(out.map(\.id) == [same.id, leap.id])
    }

    // MARK: 17 — mood menu checkmark follows the row's entry

    @Test("mood menu checkmark reflects the row entry's mood")
    func moodMenuIcon() {
        #expect(EntryRow.moodMenuIcon(for: .good, current: .good) == "checkmark")
        #expect(EntryRow.moodMenuIcon(for: .bad, current: .good) == nil)
    }

    // MARK: 18/21 — command palette

    @Test("palette entry subtitle omits word count for locked hidden entries")
    func paletteSubtitleMasking() {
        let hidden = Self.entry(body: "one two three", hidden: true)
        #expect(!CommandPaletteView.entrySubtitle(for: hidden, hiddenLocked: true).contains("3w"))
        #expect(CommandPaletteView.entrySubtitle(for: hidden, hiddenLocked: false).contains("3w"))
    }

    @Test("palette command ids are stable across renders")
    func paletteStableIds() {
        let a = CommandPaletteView.Command(title: "Go", subtitle: "s", icon: "i", group: "Navigate") {}
        let b = CommandPaletteView.Command(title: "Go", subtitle: "s", icon: "i", group: "Navigate") {}
        #expect(a.id == b.id)
        let e1 = CommandPaletteView.Command(title: "Untitled", subtitle: "", icon: "i", group: "Entries", key: "1") {}
        let e2 = CommandPaletteView.Command(title: "Untitled", subtitle: "", icon: "i", group: "Entries", key: "2") {}
        #expect(e1.id != e2.id)
        let c1 = CommandPaletteView.Command(title: "Untitled", subtitle: "", icon: "i", group: "In entries", key: "1") {}
        #expect(c1.id != e1.id)
    }

    // MARK: 19 — deterministic productive day/hour ties

    @Test("most productive weekday/hour break ties deterministically")
    func productiveTies() {
        let cal = Self.gregorian()
        // Sunday 2026-03-01 09:00 and Monday 2026-03-02 21:00: one each.
        let samples = [ActivitySample(date: Self.date(2026, 3, 2, hour: 21), words: 1),
                       ActivitySample(date: Self.date(2026, 3, 1, hour: 9), words: 1)]
        for _ in 0..<20 {
            #expect(ActivityStats.mostProductiveWeekday(samples, calendar: cal) == "Sunday")
            #expect(ActivityStats.mostProductiveHour(samples, calendar: cal) == 9)
        }
    }
}
