import Foundation
import Testing
@testable import OmegaJournal
import OmegaJournalCore

/// Fixed calendar/locale/zone so results never depend on this Mac.
private enum Fixture {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        return c
    }
    static let locale = Locale(identifier: "en_US")
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    /// Wednesday, Nov 11 2026, 3 PM.
    static let now = date(2026, 11, 11, 15)
    static func text(_ d: Date, time: Bool = false) -> String {
        UIRowMetaFormat.dateText(for: d, now: now, calendar: calendar, locale: locale, includeTime: time)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
}

@Suite("W1UI: entry row meta")
struct W1UIRowMetaTests {
    @Test("today shows only the time")
    func today() {
        #expect(Fixture.text(Fixture.date(2026, 11, 11, 9)) == "9:00 AM")
        #expect(Fixture.text(Fixture.date(2026, 11, 11, 21)) == "9:00 PM")
        #expect(Fixture.text(Fixture.date(2026, 11, 11, 0, 5), time: true) == "12:05 AM")
    }

    @Test("yesterday and this week are relative words")
    func recent() {
        #expect(Fixture.text(Fixture.date(2026, 11, 10, 21)) == "Yesterday")
        #expect(Fixture.text(Fixture.date(2026, 11, 10, 21), time: true) == "Yesterday, 9:00 PM")
        #expect(Fixture.text(Fixture.date(2026, 11, 9, 8)) == "Monday")
        #expect(Fixture.text(Fixture.date(2026, 11, 5, 8)) == "Thursday")
        #expect(Fixture.text(Fixture.date(2026, 11, 5, 8), time: true) == "Thursday, 8:00 AM")
    }

    @Test("older this year: month and day; other years add the year")
    func older() {
        #expect(Fixture.text(Fixture.date(2026, 11, 4)) == "Nov 4")
        #expect(Fixture.text(Fixture.date(2026, 11, 4), time: true) == "Nov 4")
        #expect(Fixture.text(Fixture.date(2026, 1, 2)) == "Jan 2")
        #expect(Fixture.text(Fixture.date(2025, 11, 10)) == "Nov 10, 2025")
        // Upcoming (dated ahead) entries show their date, never a time.
        #expect(Fixture.text(Fixture.date(2026, 11, 12, 9)) == "Nov 12")
        #expect(Fixture.text(Fixture.date(2027, 1, 3)) == "Jan 3, 2027")
    }

    @Test("word counts are spelled out — never \"33w\"")
    func words() {
        let en = Locale(identifier: "en_US")
        #expect(UIRowMetaFormat.wordCountText(1, locale: en) == "1 word")
        #expect(UIRowMetaFormat.wordCountText(33, locale: en) == "33 words")
        #expect(UIRowMetaFormat.wordCountText(1204, locale: en) == "1,204 words")
        #expect(UIRowMetaFormat.wordCountText(0, locale: en) == "0 words")
    }
}

@Suite("W1UI: reader backlinks presentation")
struct W1UIBacklinksTests {
    @Test("nothing links here: no \"Linked from (0)\" block")
    func emptyIsQuiet() {
        let p = UIBacklinksPresentation(backlinkCount: 0, mentionCount: 0, hasTitle: true)
        #expect(!p.showsLinkedFrom)
        #expect(p.mentionsLinkTitle == nil)
    }

    @Test("backlinks show with a counted heading")
    func linked() {
        #expect(UIBacklinksPresentation(backlinkCount: 1, mentionCount: nil, hasTitle: true).linkedFromHeading
                == "Linked from 1 entry")
        let p = UIBacklinksPresentation(backlinkCount: 3, mentionCount: nil, hasTitle: true)
        #expect(p.showsLinkedFrom)
        #expect(p.linkedFromHeading == "Linked from 3 entries")
        #expect(p.mentionsLinkTitle == nil, "unknown mention count shows no link yet")
    }

    @Test("unlinked mentions: a small link only when there are some")
    func mentions() {
        #expect(UIBacklinksPresentation(backlinkCount: 0, mentionCount: 1, hasTitle: true).mentionsLinkTitle
                == "1 unlinked mention")
        #expect(UIBacklinksPresentation(backlinkCount: 0, mentionCount: 4, hasTitle: true).mentionsLinkTitle
                == "4 unlinked mentions")
        #expect(UIBacklinksPresentation(backlinkCount: 0, mentionCount: 4, hasTitle: false).mentionsLinkTitle == nil)
    }
}

@Suite("W1UI: mood faces")
struct W1UIMoodFaceTests {
    @Test("five distinct faces; Bad is a frown, not the confused face")
    func distinct() {
        #expect(Set(UIMoodGlyph.faces).count == 5)
        #expect(UIMoodGlyph.face(forLevel: 2) == "🙁")
        #expect(!UIMoodGlyph.faces.contains("😕"))
        #expect(UIMoodGlyph.face(forLevel: 3) == "😐")
    }

    @Test("out-of-range chart values clamp instead of drawing nothing")
    func clamps() {
        #expect(UIMoodGlyph.face(forLevel: 0) == UIMoodGlyph.face(forLevel: 1))
        #expect(UIMoodGlyph.face(forLevel: 9) == UIMoodGlyph.face(forLevel: 5))
    }

    @Test("app moods use the shared table with matching labels")
    func appMoods() {
        for mood in Mood.allCases {
            #expect(mood.face == UIMoodGlyph.face(forLevel: mood.rawValue))
            #expect(mood.label == UIMoodGlyph.label(forLevel: mood.rawValue))
        }
    }
}
