import Foundation
import SwiftUI
import OmegaJournalCore

extension JournalViewModel {
    static let activeJournalSettingKey = "ui_activeJournal"
    static let promotedSavedSearchesKey = "smart_folders_promoted_v1"

    // MARK: - Hidden-entry gate

    /// True while hidden entries must stay masked in every derived surface.
    var hiddenLocked: Bool { !isSessionUnlocked }

    /// Whether hidden entries are unlocked for this view model: the
    /// biometric session, or (debug builds, tests only) a per-VM override so
    /// tests never flip the process-wide `BiometricAuth.shared` that
    /// parallel suites share.
    var isSessionUnlocked: Bool {
        #if DEBUG
        if let override = sessionUnlockedOverride { return override }
        #endif
        return BiometricAuth.shared.isAuthenticated
    }

    // MARK: - Loading

    func loadOrganizationState() {
        journals = db.fetchJournals()
        let stored = db.getSetting(Self.activeJournalSettingKey)
        activeJournalId = (!stored.isEmpty && journals.contains { $0.id == stored }) ? stored : nil
        smartFolders = SmartFolderStore.decode(db.getSetting(SmartFolderStore.settingKey))
        recentSearches = RecentSearches.decode(db.getSetting(RecentSearches.settingKey))
        // Saved searches become smart folders once (idempotent): later deletions of a folder
        // also delete its saved search, so nothing is resurrected.
        let moodValues = Dictionary(uniqueKeysWithValues: Mood.allCases.map { ($0.label, $0.rawValue) })
        var changed = false
        for saved in savedSearches where !smartFolders.contains(where: { $0.id == saved.id }) {
            let folder = SmartFolder(from: saved, moodValues: moodValues)
            let next = SmartFolderStore.upserting(folder, into: smartFolders)
            if next != smartFolders { smartFolders = next; changed = true }
        }
        if changed { persistSmartFolders() }
    }

    /// Recomputes derived organization state (tag colors/tree, smart-folder and journal counts).
    func refreshOrganization() {
        tagColors = db.tagColors()
        let locked = hiddenLocked
        organizationDerivedLocked = locked
        let visible = entries.filter { ContentMasking.canShowContent(isHidden: $0.isHidden, hiddenLocked: locked) }
        tagTree = TagTree.build(entryTags: visible.map(\.tags))
        var counts: [String: Int] = [:]
        if !smartFolders.isEmpty {
            let records = entries.map(\.searchRecord)
            for folder in smartFolders {
                counts[folder.id] = Self.smartFolderMatches(folder, records: records, pool: entries, hiddenLocked: locked).count
            }
        }
        smartFolderCounts = counts
        journalCounts = db.journalEntryCounts(includeHidden: !locked)
        SpotlightIndexer.shared.scheduleReindex(db: db)
    }

    // MARK: - Smart folders

    func persistSmartFolders() {
        db.setSetting(SmartFolderStore.settingKey, value: SmartFolderStore.encode(smartFolders))
    }

    @discardableResult
    func saveSmartFolder(_ folder: SmartFolder) -> Bool {
        let next = SmartFolderStore.upserting(folder, into: smartFolders)
        guard next != smartFolders else { return false }
        smartFolders = next
        persistSmartFolders()
        refreshOrganization()
        return true
    }

    func deleteSmartFolder(_ folder: SmartFolder) {
        smartFolders.removeAll { $0.id == folder.id }
        persistSmartFolders()
        if savedSearches.contains(where: { $0.id == folder.id }) {
            savedSearches.removeAll { $0.id == folder.id }
            persistSavedSearches()
        }
        smartFolderCounts[folder.id] = nil
    }

    func togglePinSmartFolder(_ folder: SmartFolder) {
        guard let i = smartFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        smartFolders[i].isPinned.toggle()
        persistSmartFolders()
    }

    func smartFolder(id: String) -> SmartFolder? { smartFolders.first { $0.id == id } }

    /// Builds a folder from whatever the list is currently filtering on.
    func smartFolderFromCurrentFilter(name: String) -> SmartFolder {
        var f = SmartFolder(name: name, query: searchText.trimmingCharacters(in: .whitespaces))
        f.tags = filter.tags.sorted()
        f.moods = filter.moods.map(\.rawValue).sorted()
        f.hasAttachment = filter.withAttachmentsOnly
        f.minWords = filter.minWords
        f.dateRange = SmartFolder.DateRange(filterRange: filter.dateRange)
        return f
    }

    /// Entries matching a folder from a given pool, hidden-locked entries excluded.
    func smartFolderEntries(_ folder: SmartFolder, from pool: [JournalEntry]) -> [JournalEntry] {
        Self.smartFolderMatches(folder, records: pool.map(\.searchRecord), pool: pool, hiddenLocked: hiddenLocked)
    }

    /// `folder.matches` for every entry, with the folder's free-text query
    /// parsed once and matched on the indexed path: the folder's other
    /// criteria are checked with the query blanked, then the query with
    /// `PreparedSearchQuery` — the same two conditions `SmartFolder.matches`
    /// ANDs, without re-parsing the query per entry.
    static func smartFolderMatches(_ folder: SmartFolder, records: [SearchQuery.Record], pool: [JournalEntry],
                                   hiddenLocked: Bool, now: Date = Date()) -> [JournalEntry] {
        let trimmed = folder.query.trimmingCharacters(in: .whitespaces)
        var criteria = folder
        criteria.query = ""
        let prepared = trimmed.isEmpty ? nil : PreparedSearchQuery(SearchQuery.parse(trimmed, now: now))
        var out: [JournalEntry] = []
        for (record, entry) in zip(records, pool) where criteria.matches(record, hiddenLocked: hiddenLocked, now: now) {
            if let prepared, !prepared.matches(entry.indexedSearchRecord, hiddenLocked: hiddenLocked) { continue }
            out.append(entry)
        }
        return out
    }

    // MARK: - Recent searches

    func recordRecentSearch(_ query: String) {
        let next = RecentSearches.adding(query, to: recentSearches)
        guard next != recentSearches else { return }
        recentSearches = next
        db.setSetting(RecentSearches.settingKey, value: RecentSearches.encode(next))
    }

    func clearRecentSearches() {
        recentSearches = []
        db.setSetting(RecentSearches.settingKey, value: "[]")
    }

    // MARK: - Operator search

    var parsedSearch: SearchQuery { SearchQuery.parse(searchText) }

    /// Operator-aware search over an in-memory pool (hidden-locked entries expose title/mood/date only).
    func operatorMatches(_ query: SearchQuery, in pool: [JournalEntry]) -> [JournalEntry] {
        Self.indexedMatches(PreparedSearchQuery(query), in: pool, hiddenLocked: hiddenLocked)
    }

    /// Highlighted body snippet for a row, or nil when none applies / the entry is masked.
    func searchSnippet(for entry: JournalEntry) -> SearchSnippet? {
        let terms = parsedSearch.terms
        guard !terms.isEmpty else { return nil }
        return SearchSnippet.forRecord(entry.searchRecord, terms: terms, hiddenLocked: hiddenLocked)
    }

    /// Palette hits: entries whose body/tags/title match, with a snippet. Locked hidden entries match titles only.
    func contentSearchHits(_ raw: String, limit: Int = 8) -> [(entry: JournalEntry, snippet: SearchSnippet?)] {
        let q = SearchQuery.parse(raw)
        guard !q.isEmpty else { return [] }
        let locked = hiddenLocked
        let prepared = PreparedSearchQuery(q)
        var out: [(JournalEntry, SearchSnippet?)] = []
        for e in entries where prepared.matches(e.indexedSearchRecord, hiddenLocked: locked) {
            out.append((e, SearchSnippet.forRecord(e.searchRecord, terms: q.terms, hiddenLocked: locked)))
            if out.count == limit { break }
        }
        return out
    }
}

extension SmartFolder.DateRange {
    init(filterRange: EntryFilter.DateRange) {
        switch filterRange {
        case .any: self = .any
        case .today: self = .today
        case .last7: self = .last7
        case .last30: self = .last30
        case .thisMonth: self = .thisMonth
        case .thisYear: self = .thisYear
        }
    }
}
