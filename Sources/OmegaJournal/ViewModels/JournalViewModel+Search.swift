import Foundation
import SwiftUI
import AppKit
import OmegaJournalCore

extension JournalViewModel {
    // MARK: - Saved searches

    func persistSavedSearches() {
        db.setSetting(SavedSearchStore.settingKey, value: SavedSearchStore.encode(savedSearches))
    }

    /// Saves the current search box + first tag/mood filter under `name`
    /// (the legacy saved-search record, promoted to a smart folder on load).
    /// A same-named search is replaced; an empty search with no filter is
    /// ignored. The list's "Save this search" saves the FULL filter instead:
    /// see `saveSearchAsSmartFolder(name:replacingExisting:)`.
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

    // MARK: - Save this search (smart folder)

    /// What "Save this search" did.
    enum SearchSaveOutcome: Equatable {
        case saved(SmartFolder)
        /// A smart folder already has this name (case-insensitively) and
        /// nothing changed: ask, then call again with `replacingExisting`.
        case needsReplaceConfirmation(existing: SmartFolder)
        /// Nothing was saved; a toast says why.
        case nothingSaved
    }

    /// Filter facets a smart folder can't hold. They are named to the user
    /// when saving, never silently dropped (the folder would list more than
    /// the search it was saved from).
    nonisolated static func unsupportedSmartFolderFacets(_ filter: EntryFilter) -> [String] {
        var facets: [String] = []
        if filter.favoritesOnly { facets.append("Favorites") }
        if filter.pinnedOnly { facets.append("Pinned") }
        return facets
    }

    /// Saves the search box and every filter facet a smart folder supports
    /// (all tags and moods, date range, minimum words, attachments) as a smart
    /// folder named `name`. Facets it can't hold are reported in the toast;
    /// a search with nothing saveable only toasts. A folder with the same
    /// name is replaced only with `replacingExisting` — it then keeps its id,
    /// so its place in the sidebar and its pin survive.
    @discardableResult
    func saveSearchAsSmartFolder(name: String, replacingExisting: Bool = false) -> SearchSaveOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsupported = Self.unsupportedSmartFolderFacets(filter)
        let unsupportedText = unsupported.joined(separator: " or ")
        var folder = smartFolderFromCurrentFilter(name: trimmed)
        guard folder.hasCriteria else {
            showToast(unsupported.isEmpty
                      ? "Nothing to save — type a search or choose a filter first"
                      : "Smart folders can't filter by \(unsupportedText), so nothing was saved",
                      isError: true)
            return .nothingSaved
        }
        guard !trimmed.isEmpty else {
            showToast("Name the search to save it", isError: true)
            return .nothingSaved
        }
        if let existing = smartFolders.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            guard replacingExisting else { return .needsReplaceConfirmation(existing: existing) }
            let draft = folder
            folder = SmartFolder(id: existing.id, name: trimmed, query: draft.query, tags: draft.tags,
                                 moods: draft.moods, dateRange: draft.dateRange,
                                 hasAttachment: draft.hasAttachment, minWords: draft.minWords)
            folder.isPinned = existing.isPinned
        }
        guard saveSmartFolder(folder) else {
            // Unchanged list: the identical folder is already saved, or the
            // folder limit dropped the new one.
            if smartFolders.contains(folder) {
                showToast("“\(trimmed)” is already saved")
                return .saved(folder)
            }
            showToast("You already have \(SmartFolderStore.maxCount) smart folders — delete one to save this search",
                      isError: true)
            return .nothingSaved
        }
        if unsupported.isEmpty {
            showToast("Saved “\(trimmed)” to Smart Folders")
        } else {
            showToast("Saved “\(trimmed)” — smart folders can't filter by \(unsupportedText), so "
                      + (unsupported.count == 1 ? "that filter was" : "those filters were") + " left out",
                      isError: true)
        }
        return .saved(folder)
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
        let unlocked = isSessionUnlocked
        // `entries`/`archivedEntries` already include hidden rows (masked in
        // the UI); adding `hiddenEntries` listed each hidden linker twice.
        let pool = Self.uniqueById(entries + archivedEntries)
        let linkable = pool.map { LinkableEntry(id: $0.id, title: $0.title, body: $0.body, isHidden: $0.isHidden) }
        let ids = Set(WikiLinks.backlinks(toTitle: entry.title, in: linkable, excludingId: entry.id, includeHidden: unlocked).map(\.id))
        return pool.filter { ids.contains($0.id) }
    }

    // MARK: - Wiki link resolution

    /// Lower-cased titles `[[links]]` can resolve to. Trashed entries never
    /// resolve; hidden entries only while the biometric session is unlocked.
    func linkableTitles() -> Set<String> {
        let unlocked = isSessionUnlocked
        let pool = (entries + archivedEntries + hiddenEntries).filter { unlocked || !$0.isHidden }
        return Set(pool.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    /// Opens the entry a `[[title]]` link points at (case-insensitive; the most
    /// recently created wins when titles collide). Returns false, with a toast,
    /// when nothing resolves.
    @discardableResult
    func openLinkedEntry(titled title: String) -> Bool {
        let unlocked = isSessionUnlocked
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
        let unlocked = isSessionUnlocked
        // `entries` already contains active hidden rows; the generator drops
        // them while locked. Adding `hiddenEntries` double-counted them.
        let pool = Self.uniqueById(entries)
        let values = pool.map {
            ReviewEntry(title: $0.title, body: $0.body, mood: $0.mood.rawValue, tags: $0.tags,
                        createdAt: $0.createdAt, isFavorite: $0.isFavorite, isPinned: $0.isPinned, isHidden: $0.isHidden)
        }
        let draft = ReviewGenerator.draft(period: period, entries: values, reference: reference, includeHidden: unlocked)
        flushBeforeImmediateMutation()
        return createEntry(title: draft.title, body: draft.body, tags: ["review"])
    }

    /// Keeps the first occurrence of each id, preserving order.
    static func uniqueById(_ source: [JournalEntry]) -> [JournalEntry] {
        var seen = Set<String>()
        return source.filter { seen.insert($0.id).inserted }
    }

    /// Parses the `.reviewRequested` notification payload (`userInfo["period"]`).
    nonisolated static func reviewPeriod(fromRequest userInfo: [AnyHashable: Any]?) -> ReviewPeriod? {
        (userInfo?["period"] as? String).flatMap(ReviewPeriod.init(rawValue:))
    }

    /// A tapped weekly/monthly review reminder: save (or reopen) that period's
    /// review entry. Returns nil when the payload carries no valid period.
    @discardableResult
    func handleReviewRequest(userInfo: [AnyHashable: Any]?) -> JournalEntry? {
        guard let period = Self.reviewPeriod(fromRequest: userInfo) else { return nil }
        flushBeforeImmediateMutation()
        return saveReviewAsEntry(period)
    }

    func recomputeMoodCounts() {
        var counts: [Mood: Int] = [:]
        for e in entries { counts[e.mood, default: 0] += 1 }
        moodCounts = counts
    }
}
