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

@Suite("W1UI: What's new")
@MainActor
struct W1UIWhatsNewTests {
    @Test("revision moves up so people who saw 2.2 get the new highlights")
    func bumped() {
        #expect(OnboardingState.whatsNewVersion == "2.3")
        #expect(ReleaseNotes.shouldShowWhatsNew(lastSeenVersion: "2.2", current: OnboardingState.whatsNewVersion,
                                                hasCompletedOnboarding: true))
    }

    @Test("highlights stay short")
    func short() {
        #expect((3...6).contains(WhatsNewView.items.count))
        for item in WhatsNewView.items { #expect(item.2.count <= 90, "\(item.1) is too long") }
    }
}
