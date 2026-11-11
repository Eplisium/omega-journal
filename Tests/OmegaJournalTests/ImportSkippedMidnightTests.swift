import Foundation
import Testing
@testable import OmegaJournalCore

/// core-8: date-only (and other local) front-matter dates on a day whose
/// midnight DST skips. Explicit time-zone calendars; the process time zone is
/// never changed.
@Suite("Import dates on a skipped midnight")
struct ImportSkippedMidnightTests {
    static func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    @Test("core-8 parseDate keeps a date-only value on the Santiago DST-start day (01:00, same day)")
    func dateOnlyOnSkippedMidnight() throws {
        let c = Self.cal("America/Santiago")
        let normal = try #require(ImportParsers.parseDate("2019-09-07", calendar: c))
        #expect(normal == c.date(from: DateComponents(year: 2019, month: 9, day: 7)))
        #expect(c.component(.hour, from: normal) == 0)

        let jump = try #require(ImportParsers.parseDate("2019-09-08", calendar: c))
        #expect(DayKey.string(from: jump, calendar: c) == "2019-09-08")
        #expect(jump == c.startOfDay(for: jump))
        #expect(c.component(.hour, from: jump) == 1)
    }

    @Test("core-8 other midnight-DST zones and a wall-clock time inside the gap")
    func otherZonesAndGapTimes() throws {
        for (tz, key) in [("Asia/Beirut", "2019-03-31"), ("America/Havana", "2019-03-10"),
                          ("America/Asuncion", "2019-10-06")] {
            let c = Self.cal(tz)
            let d = try #require(ImportParsers.parseDate(key, calendar: c), "\(tz) \(key)")
            #expect(DayKey.string(from: d, calendar: c) == key, "\(tz)")
        }
        let c = Self.cal("America/Santiago")
        let gap = try #require(ImportParsers.parseDate("2019-09-08 00:30", calendar: c))
        #expect(DayKey.string(from: gap, calendar: c) == "2019-09-08")
        // Ordinary times are read exactly as before.
        let plain = try #require(ImportParsers.parseDate("2019-09-08 14:05:09", calendar: c))
        #expect(plain == c.date(from: DateComponents(year: 2019, month: 9, day: 8, hour: 14, minute: 5, second: 9)))
        #expect(ImportParsers.parseDate("2019-09-08T00:30:00Z", calendar: c)
                == Date(timeIntervalSince1970: 1_567_902_600))
    }

    @Test("core-8 invalid dates still fail")
    func invalidStillNil() {
        let c = Self.cal("America/Santiago")
        #expect(ImportParsers.parseDate("not a date", calendar: c) == nil)
        #expect(ImportParsers.parseDate("2019-13-01", calendar: c) == nil)
        #expect(ImportParsers.parseDate("", calendar: c) == nil)
    }

    @Test("core-8 a markdown note dated on the DST-start day keeps its date, not the file date")
    func markdownNoteKeepsDate() {
        let c = Self.cal("America/Santiago")
        let fallback = Date(timeIntervalSince1970: 1_800_000_000)
        let note = ImportParsers.parseMarkdownNote(text: "---\ntitle: Spring\ndate: 2019-09-08\n---\nbody",
                                                   fallbackTitle: "file", fallbackDate: fallback, calendar: c)
        #expect(note.createdAt != fallback)
        #expect(DayKey.string(from: note.createdAt, calendar: c) == "2019-09-08")
    }
}
