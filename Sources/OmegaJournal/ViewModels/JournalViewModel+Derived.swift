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
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, Int, [JournalEntry])] = []

        func bucketIndex(for date: Date) -> (String, Int) {
            if cal.isDateInToday(date) { return ("Today", 0) }
            if cal.isDateInYesterday(date) { return ("Yesterday", 1) }
            if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), date >= weekAgo {
                return ("Earlier This Week", 2)
            }
            if let monthAgo = cal.date(byAdding: .day, value: -30, to: now), date >= monthAgo {
                return ("Earlier This Month", 3)
            }
            let year = cal.component(.year, from: date)
            let month = cal.component(.month, from: date)
            let label = date.formatted(.dateTime.month(.wide).year())
            return (label, 1000 - (year * 12 + month))
        }

        let pinned = filteredEntries.filter(\.isPinned)
        let rest = filteredEntries.filter { !$0.isPinned }

        if !pinned.isEmpty {
            // Rank must beat every other bucket — month buckets use
            // 1000 - (year*12+month), which goes deeply negative for old dates.
            buckets.append(("Pinned", Int.min, pinned))
        }
        for entry in rest {
            let (label, rank) = bucketIndex(for: entry.createdAt)
            if let idx = buckets.firstIndex(where: { $0.0 == label }) {
                buckets[idx].2.append(entry)
            } else {
                buckets.append((label, rank, [entry]))
            }
        }
        return buckets
            .sorted { $0.1 < $1.1 }
            .map { EntrySection(title: $0.0, entries: $0.2) }
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
