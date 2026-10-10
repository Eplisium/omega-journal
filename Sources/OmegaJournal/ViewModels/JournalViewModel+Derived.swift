import Foundation
import SwiftUI
import OmegaJournalCore

extension JournalViewModel {
    // MARK: - Derived collections

    /// Resolves an entry across every lifecycle collection so Archive, Hidden,
    /// and Trash readers/editors never depend on the active list being present.
    func entry(id: String?) -> JournalEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
            ?? archivedEntries.first { $0.id == id }
            ?? trashedEntries.first { $0.id == id }
            ?? hiddenEntries.first { $0.id == id }
    }

    var selectedEntry: JournalEntry? { entry(id: selectedEntryId) }
    var editingEntry: JournalEntry? { entry(id: editingEntryId) }
    var isEditing: Bool { editingEntryId != nil }
    var entryCount: Int { entries.count }
    /// The Journal workspace's transient query result. Never use this for
    /// global counts, Calendar, goals, or reflective analytics.
    var libraryEntries: [JournalEntry] { searchResults ?? entries }
    var isSearchingLibrary: Bool { searchResults != nil }

    /// Entries after the advanced filter is applied — what the list actually shows.
    var filteredEntries: [JournalEntry] {
        filter.isActive ? libraryEntries.filter(filter.matches) : libraryEntries
    }

    /// Filtered entries bucketed into date sections for the grouped list UI.
    var groupedEntries: [EntrySection] {
        sections(for: filteredEntries, fallbackTitle: "Entries")
    }

    /// Whether the current sort is chronological, so date sections make sense.
    var groupsByDate: Bool { sortOrder == .dateDesc || sortOrder == .dateAsc }

    /// Splits an already-sorted entry list into display sections. Section order
    /// always follows list order (see `EntryGrouping`), so "Latest" can never
    /// show an older month above a newer entry again.
    func sections(for list: [JournalEntry], fallbackTitle: String, groupByDate: Bool? = nil) -> [EntrySection] {
        let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = list.map { EntryGroupItem(id: $0.id, date: $0.createdAt, isPinned: $0.isPinned) }
        return EntryGrouping.sections(for: items, groupByDate: groupByDate ?? groupsByDate, fallbackTitle: fallbackTitle)
            .map { EntrySection(title: $0.title, entries: $0.ids.compactMap { byId[$0] }) }
    }

    struct EntrySection: Identifiable {
        let title: String
        let entries: [JournalEntry]
        var id: String { title }
    }

    // MARK: - Reflection scope

    /// Private entries contribute to reflective views only after an explicit
    /// inclusion choice and an active biometric session.
    var effectiveAnalyticsVisibility: AnalyticsVisibility {
        analyticsVisibility == .includePrivate && BiometricAuth.shared.isAuthenticated
            ? .includePrivate
            : .visibleOnly
    }

    var analyticsVisibilityLabel: String { effectiveAnalyticsVisibility.label }

    /// Calendar always shows the full active journal, subject to the clearly
    /// communicated privacy choice. It is never narrowed by library search.
    var calendarEntries: [JournalEntry] {
        reflectionEntries(period: .allTime)
    }

    /// Insights uses its own selected period and privacy scope, independently
    /// from Journal search and filters.
    var scopedAnalyticsEntries: [JournalEntry] {
        reflectionEntries(period: analyticsPeriod)
    }

    func reflectionEntries(
        period: AnalyticsPeriod,
        relativeTo reference: Date = Date()
    ) -> [JournalEntry] {
        let records = entries.map {
            AnalyticsRecord(id: $0.id, date: $0.createdAt, isPrivate: $0.isHidden)
        }
        let includedIds = Set(
            OmegaAnalytics.filteredRecords(
                records,
                period: period,
                visibility: effectiveAnalyticsVisibility,
                relativeTo: reference
            )
            .map(\.id)
        )
        return entries.filter { includedIds.contains($0.id) }
    }
}
