import Foundation
import Testing
@testable import OmegaJournalCore

@Suite("Core saved searches, backlinks, reviews")
struct CoreFeaturesTests {
    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }
    // Wed 2026-09-30 12:00 UTC
    private let ref = Date(timeIntervalSince1970: 1_790_769_600)

    @Test("saved search JSON round-trips and same name replaces")
    func savedRoundTrip() {
        var list = SavedSearchStore.adding(SavedSearch(name: "Work", query: "meeting", tag: "work"), to: [])
        list = SavedSearchStore.adding(SavedSearch(name: "work", query: "standup"), to: list)
        #expect(list.count == 1 && list[0].query == "standup")
        #expect(SavedSearchStore.decode(SavedSearchStore.encode(list)) == list)
        #expect(SavedSearchStore.decode("garbage").isEmpty)
    }

    @Test("empty saved search is rejected; blank name falls back")
    func savedRejects() {
        #expect(SavedSearchStore.adding(SavedSearch(name: "x", query: "  "), to: []).isEmpty)
        #expect(SavedSearchStore.adding(SavedSearch(name: " ", query: "cats"), to: [])[0].name == "cats")
    }

    @Test("backlinks: case-insensitive, aliases, ignore code, hidden excluded")
    func backlinks() {
        let entries = [
            LinkableEntry(id: "1", title: "Garden", body: "x"),
            LinkableEntry(id: "2", title: "A", body: "see [[garden]] today"),
            LinkableEntry(id: "3", title: "B", body: "```\n[[Garden]]\n```\nand `[[Garden]]`"),
            LinkableEntry(id: "4", title: "C", body: "[[Garden|my plot]]", isHidden: true),
            LinkableEntry(id: "5", title: "D", body: "[[Garden]] self", isHidden: false),
        ]
        #expect(WikiLinks.backlinks(toTitle: "Garden", in: entries, excludingId: "5").map(\.id) == ["2"])
        #expect(WikiLinks.backlinks(toTitle: "Garden", in: entries, excludingId: "5", includeHidden: true).map(\.id) == ["2", "4"])
        #expect(WikiLinks.backlinks(toTitle: "", in: entries).isEmpty)
    }

    @Test("resolveWikiLinks resolves known titles and ignores hidden targets")
    func resolve() {
        let entries = [LinkableEntry(id: "1", title: "Garden", body: ""),
                       LinkableEntry(id: "2", title: "Secret", body: "", isHidden: true)]
        let r = WikiLinks.resolveWikiLinks(in: "[[GARDEN]] [[Secret]] [[Nope]]", entries: entries)
        #expect(r.map(\.entryId) == ["1", nil, nil])
    }

    @Test("review excludes hidden entries unless asked and stays in period")
    func review() {
        let c = Self.cal
        let day = { (back: Int) in c.date(byAdding: .day, value: -back, to: self.ref)! }
        let es = [
            ReviewEntry(title: "Good day", body: "one two three", mood: 5, tags: ["joy", "work"], createdAt: day(0), isFavorite: true),
            ReviewEntry(title: "Meh", body: "four", mood: 2, tags: ["work"], createdAt: day(1)),
            ReviewEntry(title: "Private", body: "secret", mood: 1, tags: ["hush"], createdAt: day(0), isHidden: true),
            ReviewEntry(title: "Old", body: "old", mood: 3, tags: ["old"], createdAt: day(40)),
        ]
        let d = ReviewGenerator.draft(period: .week, entries: es, reference: ref, calendar: c)
        #expect(d.entryCount == 2)
        #expect(d.body.contains("#work (2)"))
        #expect(d.body.contains("[[Good day]]"))
        #expect(!d.body.contains("Private") && !d.body.contains("hush") && !d.body.contains("#old"))
        #expect(d.body.contains("4 words"))
        let all = ReviewGenerator.draft(period: .week, entries: es, reference: ref, includeHidden: true, calendar: c)
        #expect(all.entryCount == 3 && all.body.contains("#hush"))
        let month = ReviewGenerator.draft(period: .month, entries: es, reference: ref, calendar: c)
        #expect(month.title == "Monthly review: September 2026")
    }

    @Test("empty period yields a gentle draft")
    func emptyReview() {
        let d = ReviewGenerator.draft(period: .month, entries: [], reference: ref, calendar: Self.cal)
        #expect(d.entryCount == 0 && d.body.contains("That's fine"))
    }
}
