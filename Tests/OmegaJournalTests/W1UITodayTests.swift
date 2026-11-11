import Foundation
import Testing
@testable import OmegaJournal
import OmegaJournalCore

@Suite("W1UI: Today page copy")
struct W1UITodayTests {
    @Test("date line carries the streak only from two days up")
    func dateLine() {
        #expect(UITodayCopy.dateLine(dateText: "Wednesday, November 11", streak: 0, unit: "day") == "Wednesday, November 11")
        #expect(UITodayCopy.dateLine(dateText: "Wednesday, November 11", streak: 1, unit: "day") == "Wednesday, November 11")
        #expect(UITodayCopy.dateLine(dateText: "Wednesday, November 11", streak: 4, unit: "day")
                == "Wednesday, November 11 · 4-day streak")
        #expect(UITodayCopy.dateLine(dateText: "Monday, May 4", streak: 3, unit: "week") == "Monday, May 4 · 3-week streak")
    }

    @Test("accessible date line spells the streak out")
    func accessibility() {
        #expect(UITodayCopy.dateLineAccessibility(dateText: "Monday, May 4", streak: 5, unit: "day")
                == "Monday, May 4. Writing streak: 5 days.")
        #expect(UITodayCopy.dateLineAccessibility(dateText: "Monday, May 4", streak: 1, unit: "day") == "Monday, May 4")
    }

    @Test("hero headings")
    func headings() {
        #expect(UITodayCopy.promptHeading == "Today's prompt")
        #expect(UITodayCopy.entryHeading == "Today's entry")
    }
}
