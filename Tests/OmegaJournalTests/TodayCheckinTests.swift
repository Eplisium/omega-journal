import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

// Issue #4: the check-in and habit inputs are mounted on Today as one folded line.

@Suite("Today check-in: summary line")
struct TodayCheckinSummaryTests {
    @Test("the folded line counts what's logged and what's done")
    func line() {
        #expect(CheckinSummary.line(metricsLogged: 0, metricCount: 3, habitsDone: 0, habitCount: 0) == "Nothing logged yet")
        #expect(CheckinSummary.line(metricsLogged: 2, metricCount: 3, habitsDone: 0, habitCount: 0) == "2 of 3 logged")
        #expect(CheckinSummary.line(metricsLogged: 2, metricCount: 3, habitsDone: 1, habitCount: 2) == "2 of 3 logged · 1 of 2 habits done")
        #expect(CheckinSummary.line(metricsLogged: 0, metricCount: 0, habitsDone: 1, habitCount: 1) == "1 of 1 habit done")
        #expect(CheckinSummary.line(metricsLogged: 0, metricCount: 0, habitsDone: 0, habitCount: 0) == "Add something to track")
        // Never more logged than exist.
        #expect(CheckinSummary.line(metricsLogged: 5, metricCount: 3, habitsDone: 0, habitCount: 0) == "3 of 3 logged")
    }

    @Test("complete only when everything tracked is logged and done")
    func complete() {
        #expect(CheckinSummary.isComplete(metricsLogged: 3, metricCount: 3, habitsDone: 2, habitCount: 2))
        #expect(!CheckinSummary.isComplete(metricsLogged: 3, metricCount: 3, habitsDone: 1, habitCount: 2))
        #expect(!CheckinSummary.isComplete(metricsLogged: 2, metricCount: 3, habitsDone: 0, habitCount: 0))
        #expect(!CheckinSummary.isComplete(metricsLogged: 0, metricCount: 0, habitsDone: 0, habitCount: 0))
    }
}

@Suite("Today check-in: store and settings", .serialized)
@MainActor
struct TodayCheckinStoreTests {
    @Test("today's summary counts existing metrics and habits only, per day")
    func storeSummary() throws {
        let (root, db) = DataSafetyTests.makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckinStore(db: db)
        let today = CheckinStore.todayKey()
        #expect(store.metrics.count == 3)   // built-in sleep, energy, stress
        #expect(store.summary(day: today).text == "Nothing logged yet")

        store.setValue(CheckinMetric.sleepId, 7.5)
        store.setValue(CheckinMetric.energyId, 4)
        #expect(store.loggedMetricCount(day: today) == 2)

        #expect(store.addMetric(name: "Water", kind: .number, unit: "cups"))
        let water = try #require(store.metrics.first { $0.name == "Water" })
        store.setValue(water.id, 6)
        #expect(store.summary(day: today).text == "3 of 4 logged")
        // A removed metric's value no longer counts.
        store.removeMetric(water.id)
        #expect(store.summary(day: today).text == "2 of 3 logged")

        #expect(store.addHabit(name: "Walk"))
        #expect(store.addHabit(name: "Read"))
        let walk = try #require(store.habits.first { $0.name == "Walk" })
        store.toggleHabit(walk.id)
        #expect(store.summary(day: today).text == "2 of 3 logged · 1 of 2 habits done")
        #expect(!store.summary(day: today).isComplete)

        store.setValue(CheckinMetric.stressId, 2)
        for habit in store.habits where !store.isDone(habit.id) { store.toggleHabit(habit.id) }
        #expect(store.summary(day: today).isComplete)

        // Another day starts empty.
        #expect(store.summary(day: "1999-01-01").text == "Nothing logged yet · 0 of 2 habits done")
    }

    @Test("the Today toggle lives in Settings › Writing")
    func settingsCard() {
        #expect(SettingsCardID.dailyCheckin.group == .writing)
        #expect(SettingsCatalog.card(forStorageKey: TodayCheckinPrefs.showKey) == .dailyCheckin)
        #expect(SettingsCatalog.cards(in: .writing).first == .writingGoals)
    }
}
