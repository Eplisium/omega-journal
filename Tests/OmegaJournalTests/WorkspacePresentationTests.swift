import Foundation
import Testing
@testable import OmegaJournalCore

@Suite("Workspace presentation")
struct WorkspacePresentationTests {
    @Test("only Journal owns the entry collection column")
    func onlyJournalUsesEntryCollection() {
        #expect(JournalWorkspace.journal.usesEntryCollection)
        #expect(!JournalWorkspace.today.usesEntryCollection)
        #expect(!JournalWorkspace.calendar.usesEntryCollection)
        #expect(!JournalWorkspace.insights.usesEntryCollection)
        #expect(!JournalWorkspace.onThisDay.usesEntryCollection)
    }

    @Test("reflective workspaces are distinct from writing workspaces")
    func reflectiveWorkspacesAreMarked() {
        #expect(!JournalWorkspace.today.isReflective)
        #expect(!JournalWorkspace.journal.isReflective)
        #expect(JournalWorkspace.calendar.isReflective)
        #expect(JournalWorkspace.insights.isReflective)
        #expect(JournalWorkspace.onThisDay.isReflective)
    }
}

@Suite("Analytics presentation scope")
struct AnalyticsPresentationScopeTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private let reference = Date(timeIntervalSince1970: 1_725_408_000) // 2024-09-04 00:00:00 UTC

    @Test("rolling periods use inclusive calendar-day starts")
    func rollingPeriodsUseInclusiveDayStarts() {
        #expect(AnalyticsPeriod.sevenDays.startDate(relativeTo: reference, calendar: calendar) == Date(timeIntervalSince1970: 1_724_889_600))
        #expect(AnalyticsPeriod.thirtyDays.startDate(relativeTo: reference, calendar: calendar) == Date(timeIntervalSince1970: 1_722_902_400))
        #expect(AnalyticsPeriod.threeMonths.startDate(relativeTo: reference, calendar: calendar) == Date(timeIntervalSince1970: 1_717_459_200))
    }

    @Test("calendar year and all-time periods have honest boundaries")
    func calendarYearAndAllTimeBoundaries() {
        #expect(AnalyticsPeriod.year.startDate(relativeTo: reference, calendar: calendar) == Date(timeIntervalSince1970: 1_704_067_200))
        #expect(AnalyticsPeriod.allTime.startDate(relativeTo: reference, calendar: calendar) == nil)
    }

    @Test("visibility labels tell people what private data is included")
    func visibilityLabelsAreExplicit() {
        #expect(AnalyticsVisibility.visibleOnly.label == "Private entries excluded")
        #expect(AnalyticsVisibility.includePrivate.label == "Private entries included")
    }

    @Test("analytics filtering keeps the selected period and visibility scope honest")
    func analyticsFilteringHonorsPeriodAndPrivacy() {
        let records = [
            AnalyticsRecord(id: "outside", date: Date(timeIntervalSince1970: 1_722_816_000), isPrivate: false),
            AnalyticsRecord(id: "visible", date: Date(timeIntervalSince1970: 1_725_408_000), isPrivate: false),
            AnalyticsRecord(id: "private", date: Date(timeIntervalSince1970: 1_725_408_000), isPrivate: true),
            AnalyticsRecord(
                id: "future",
                date: calendar.date(byAdding: .day, value: 1, to: reference)!,
                isPrivate: false
            ),
        ]

        let visible = OmegaAnalytics.filteredRecords(
            records,
            period: .sevenDays,
            visibility: .visibleOnly,
            relativeTo: reference,
            calendar: calendar
        )
        #expect(visible.map(\.id) == ["visible"])

        let includingPrivate = OmegaAnalytics.filteredRecords(
            records,
            period: .sevenDays,
            visibility: .includePrivate,
            relativeTo: reference,
            calendar: calendar
        )
        #expect(includingPrivate.map(\.id) == ["visible", "private"])
    }
}

@Suite("Reading time")
struct ReadingTimeTests {
    @Test("empty entries do not inflate reading-time totals")
    func emptyEntriesHaveZeroReadingMinutes() {
        #expect(OmegaCore.readingMinutes(forWordCount: 0) == 0)
        #expect(OmegaCore.readingMinutes(forWordCount: 1) == 1)
        #expect(OmegaCore.readingMinutes(forWordCount: 220) == 1)
        #expect(OmegaCore.readingMinutes(forWordCount: 221) == 2)
    }
}

@Suite("Bulk storage actions")
struct BulkStorageActionTests {
    @Test("each storage context exposes only meaningful bulk actions")
    func actionsMatchTheEntryLifecycle() {
        #expect(BulkEntryActions.available(in: .library) == [
            .favorite, .tag, .archive, .moveToTrash,
        ])
        #expect(BulkEntryActions.available(in: .archive) == [
            .unarchive, .moveToTrash,
        ])
        #expect(BulkEntryActions.available(in: .trash) == [
            .restoreFromTrash, .deleteForever,
        ])
        #expect(BulkEntryActions.available(in: .hidden) == [
            .favorite, .tag, .archive, .unarchive, .moveToTrash,
        ])
    }

    @Test("only permanent deletion is marked destructive and irreversible")
    func permanentDeleteIsTheOnlyIrreversibleBulkAction() {
        #expect(!BulkEntryAction.moveToTrash.isIrreversible)
        #expect(!BulkEntryAction.restoreFromTrash.isIrreversible)
        #expect(BulkEntryAction.deleteForever.isIrreversible)
    }
}
