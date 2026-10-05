import Combine
import Foundation
import SwiftUI
import AppKit
import OmegaJournalCore

extension JournalViewModel {
    // MARK: - Saved searches

    func persistSavedSearches() {
        db.setSetting(SavedSearchStore.settingKey, value: SavedSearchStore.encode(savedSearches))
    }

    /// Saves the current search box + first tag/mood filter under `name`.
    /// A same-named search is replaced; an empty search with no filter is ignored.
    func saveCurrentSearch(name: String) {
        let new = SavedSearch(
            name: name, query: searchText,
            tag: filter.tags.sorted().first,
            mood: filter.moods.sorted { $0.rawValue < $1.rawValue }.first?.label)
        let updated = SavedSearchStore.adding(new, to: savedSearches)
        guard updated != savedSearches else { return }
        savedSearches = updated
        persistSavedSearches()
    }

    func deleteSavedSearch(_ s: SavedSearch) {
        savedSearches.removeAll { $0.id == s.id }
        persistSavedSearches()
    }

    func applySavedSearch(_ s: SavedSearch) {
        var f = EntryFilter.empty
        if let tag = s.tag { f.tags = [tag] }
        if let label = s.mood, let m = Mood.allCases.first(where: { $0.label == label }) { f.moods = [m] }
        filter = f
        searchText = s.query
        refreshQuery()
    }

    // MARK: - Backlinks

    /// Entries whose body links to `entry` via `[[Title]]`. Hidden entries only
    /// count while the biometric session is unlocked; trashed entries never do.
    func backlinks(for entry: JournalEntry) -> [JournalEntry] {
        let unlocked = BiometricAuth.shared.isAuthenticated
        let pool = entries + archivedEntries + (unlocked ? hiddenEntries : [])
        let linkable = pool.map { LinkableEntry(id: $0.id, title: $0.title, body: $0.body, isHidden: $0.isHidden) }
        let ids = Set(WikiLinks.backlinks(toTitle: entry.title, in: linkable, excludingId: entry.id, includeHidden: unlocked).map(\.id))
        return pool.filter { ids.contains($0.id) }
    }

    // MARK: - Wiki link resolution

    /// Lower-cased titles `[[links]]` can resolve to. Trashed entries never
    /// resolve; hidden entries only while the biometric session is unlocked.
    func linkableTitles() -> Set<String> {
        let unlocked = BiometricAuth.shared.isAuthenticated
        let pool = (entries + archivedEntries + hiddenEntries).filter { unlocked || !$0.isHidden }
        return Set(pool.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    /// Opens the entry a `[[title]]` link points at (case-insensitive; the most
    /// recently created wins when titles collide). Returns false, with a toast,
    /// when nothing resolves.
    @discardableResult
    func openLinkedEntry(titled title: String) -> Bool {
        let unlocked = BiometricAuth.shared.isAuthenticated
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool = (entries + archivedEntries + hiddenEntries).filter { unlocked || !$0.isHidden }
        guard let target = pool.filter({ $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted })
                .max(by: { $0.createdAt < $1.createdAt }) else {
            showToast("No entry titled “\(title)”", isError: true)
            return false
        }
        flushBeforeImmediateMutation()
        select(target)
        return true
    }

    // MARK: - Reviews

    /// Creates a weekly/monthly review draft entry (tag "review") from the
    /// current period's entries. Hidden entries are only summarised while unlocked.
    @discardableResult
    func createReviewEntry(period: ReviewPeriod, reference: Date = Date()) -> JournalEntry {
        let unlocked = BiometricAuth.shared.isAuthenticated
        let pool = entries + (unlocked ? hiddenEntries : [])
        let values = pool.map {
            ReviewEntry(title: $0.title, body: $0.body, mood: $0.mood.rawValue, tags: $0.tags,
                        createdAt: $0.createdAt, isFavorite: $0.isFavorite, isPinned: $0.isPinned, isHidden: $0.isHidden)
        }
        let draft = ReviewGenerator.draft(period: period, entries: values, reference: reference, includeHidden: unlocked)
        flushBeforeImmediateMutation()
        return createEntry(title: draft.title, body: draft.body, tags: ["review"])
    }

    func recomputeMoodCounts() {
        var counts: [Mood: Int] = [:]
        for e in entries { counts[e.mood, default: 0] += 1 }
        moodCounts = counts
    }
}
