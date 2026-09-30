import Combine
import Foundation
import SwiftUI
import AppKit
import OmegaJournalCore

// MARK: - Journal View Model

@MainActor
final class JournalViewModel: ObservableObject {
    // Library
    @Published var entries: [JournalEntry] = [] {
        didSet { recomputeMoodCounts() }
    }
    /// Precomputed per-mood counts of active entries (sidebar badges) so views
    /// don't re-filter the whole library for every mood on every render.
    private(set) var moodCounts: [Mood: Int] = [:]
    @Published var trashedEntries: [JournalEntry] = []
    @Published var archivedEntries: [JournalEntry] = []
    @Published var hiddenEntries: [JournalEntry] = []
    @Published var templates: [EntryTemplate] = []
    @Published var allTags: [(tag: String, count: Int)] = []
    /// Search results are intentionally separate from the active-library snapshot so
    /// Calendar, sidebar counts, goals, and Insights never become search-dependent.
    @Published private(set) var searchResults: [JournalEntry]?

    // Selection & editing
    @Published var selectedEntryId: String?
    @Published var editingEntryId: String?

    // Search & filtering
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .dateDesc
    @Published var filter: EntryFilter = .empty
    /// Named search + tag/mood filter combinations (stored as JSON in settings).
    @Published private(set) var savedSearches: [SavedSearch] = []

    // Reflection scope
    @Published var analyticsPeriod: AnalyticsPeriod = .thirtyDays
    @Published var analyticsVisibility: AnalyticsVisibility = .visibleOnly

    // UI state
    @Published var editorMode: EditorMode = .write
    @Published var isZenMode = false
    @Published var showCommandPalette = false
    @Published var toast: Toast?

    /// Set of entry ids selected for bulk actions (multi-select mode in the list).
    @Published var bulkSelection: Set<String> = []
    @Published var isBulkSelecting = false

    let db = DatabaseManager.shared
    private var searchDebounce: Task<Void, Never>?
    private var saveDebounce: Task<Void, Never>?
    /// Editor save indicator: `.pending` while a debounced autosave is queued.
    enum SaveState: Equatable { case idle, pending, saved }
    @Published private(set) var saveState: SaveState = .idle
    private var undoStack: [UndoAction] = []
    /// Undo history is bounded: an unbounded stack of id arrays only grows.
    static let maxUndoDepth = 50
    private var cancellables: Set<AnyCancellable> = []

    enum EditorMode: String, CaseIterable, Identifiable {
        case write = "Write"
        case split = "Split"
        case preview = "Preview"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .write: "pencil"
            case .split: "rectangle.split.2x1"
            case .preview: "eye"
            }
        }
    }

    /// A transient banner message shown at the top of the detail pane.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        var actionLabel: String?
        var isError = false

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    /// Something the user can undo via the toast's action button.
    private enum UndoAction {
        case restoreTrashed(ids: [String])
        case unarchive(ids: [String])
    }

    init() {
        // Surface database write failures that used to be swallowed. The
        // reporter is installed before reload() so launch-time failures
        // (migration, reconciliation) still reach the user.
        db.onError = { [weak self] message in
            self?.showToast(message, isError: true)
        }
        loadPersistedViewState()
        reload()
        loadTemplates()
        $sortOrder
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] order in
                self?.db.setSetting(Self.sortOrderSettingKey, value: order.rawValue)
            }
            .store(in: &cancellables)
        $filter
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] filter in
                guard let self else { return }
                if let data = try? JSONEncoder().encode(filter), let text = String(data: data, encoding: .utf8) {
                    self.db.setSetting(Self.filterSettingKey, value: text)
                }
            }
            .store(in: &cancellables)
        // Lock/unlock changes which tags may appear in the sidebar, so
        // re-derive tag counts whenever the biometric session changes. Combine
        // subscription keeps this in sync without every mutation site needing
        // to remember to do it.
        BiometricAuth.shared.$isAuthenticated
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.allTags = self.db.tagsWithCounts(includeHidden: BiometricAuth.shared.isAuthenticated)
            }
            .store(in: &cancellables)
    }

    // MARK: - Persisted view state

    static let sortOrderSettingKey = "ui_sortOrder"
    static let filterSettingKey = "ui_entryFilter"

    private func loadPersistedViewState() {
        if let order = SortOrder(rawValue: db.getSetting(Self.sortOrderSettingKey)) {
            sortOrder = order
        }
        let raw = db.getSetting(Self.filterSettingKey)
        if !raw.isEmpty, let data = raw.data(using: .utf8),
           let saved = try? JSONDecoder().decode(EntryFilter.self, from: data) {
            filter = saved
        }
        savedSearches = SavedSearchStore.decode(db.getSetting(SavedSearchStore.settingKey))
    }

    // MARK: - Saved searches

    private func persistSavedSearches() {
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

    private func recomputeMoodCounts() {
        var counts: [Mood: Int] = [:]
        for e in entries { counts[e.mood, default: 0] += 1 }
        moodCounts = counts
    }

    // MARK: - Loading

    func reload() {
        // One shared attachments/tags scan for all four scopes (was 8 full-table
        // scans per reload) plus the single tagsWithCounts query below.
        let scopes = db.fetchScopes([
            (.active, sortOrder),
            (.trashed, .dateDesc),
            (.archived, sortOrder),
            (.hidden, .dateDesc),
        ])
        entries = scopes[.active] ?? []
        trashedEntries = scopes[.trashed] ?? []
        archivedEntries = scopes[.archived] ?? []
        hiddenEntries = scopes[.hidden] ?? []
        // While the biometric session is locked, hidden entries must not
        // advertise their tags in the sidebar/filter chips.
        allTags = db.tagsWithCounts(includeHidden: BiometricAuth.shared.isAuthenticated)
        GoalManager.shared.loadGoals()
        refreshQuery()
    }

    func loadTemplates() {
        templates = db.templates()
    }

    /// Sidebar tag counts, excluding hidden entries' tags while the biometric
    /// session is locked. Every mutation path refreshes counts through this so
    /// the privacy rule holds regardless of where the refresh happens.
    func refreshTagCounts() {
        allTags = db.tagsWithCounts(includeHidden: BiometricAuth.shared.isAuthenticated)
    }

    /// Re-runs whichever query matches the current search box contents.
    ///
    /// Results are the union of the FTS hits and a substring pass over the
    /// decrypted in-memory library, so a body-only match is found even when the
    /// title/tags also match (and vice versa). Locked hidden entries never
    /// match on body or tags.
    func refreshQuery() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchResults = nil
            return
        }
        let unlocked = BiometricAuth.shared.isAuthenticated
        let fts = db.fullTextSearch(q, scope: .active).filter { entry in
            unlocked || !entry.isHidden || Self.matchesVisibleFields(entry, query: q)
        }
        var seen = Set(fts.map(\.id))
        var results = fts
        for entry in Self.searchMatches(entries, query: q, unlocked: unlocked) where seen.insert(entry.id).inserted {
            results.append(entry)
        }
        searchResults = results
    }

    /// Pure substring search over already-decrypted entries. Locked hidden
    /// entries match on title only.
    static func searchMatches(_ source: [JournalEntry], query: String, unlocked: Bool) -> [JournalEntry] {
        source.filter { entry in
            if entry.isHidden && !unlocked { return matchesVisibleFields(entry, query: query) }
            return matchesSearchableFields(entry, query: query)
        }
    }

    private static func matchesVisibleFields(_ entry: JournalEntry, query: String) -> Bool {
        entry.title.localizedCaseInsensitiveContains(query)
    }

    /// Applies the current query to a non-active storage collection. Active
    /// Journal search stays FTS-backed in `refreshQuery`; Archive, Hidden, and
    /// Trash use this in-memory pass so their search field never lies. Locked
    /// hidden entries intentionally match titles only.
    func entriesMatchingCurrentSearch(in source: [JournalEntry]) -> [JournalEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return source }
        return source.filter { entry in
            if entry.isHidden && !BiometricAuth.shared.isAuthenticated {
                return Self.matchesVisibleFields(entry, query: query)
            }
            return Self.matchesSearchableFields(entry, query: query)
        }
    }

    private static func matchesSearchableFields(_ entry: JournalEntry, query: String) -> Bool {
        entry.title.localizedCaseInsensitiveContains(query)
            || entry.body.localizedCaseInsensitiveContains(query)
            || entry.tags.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Debounced search — called on every keystroke, hits the DB at most every 250ms.
    func searchTextChanged() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refreshQuery() }
        }
    }

    /// Replaces the entry in `collection` and returns the previous value.
    @discardableResult
    private func replaceEntry(_ entry: JournalEntry, in collection: inout [JournalEntry]) -> JournalEntry? {
        guard let idx = collection.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let old = collection[idx]
        collection[idx] = entry
        return old
    }

    /// Whether replacing `old` with `new` can change its position under the
    /// current sort order. Typing changes body/updatedAt on every keystroke, so
    /// re-sorting unconditionally made each keystroke O(n log n).
    private func sortKeyChanged(from old: JournalEntry, to new: JournalEntry) -> Bool {
        if old.isPinned != new.isPinned { return true }
        switch sortOrder {
        case .dateDesc, .dateAsc: return old.createdAt != new.createdAt
        case .updatedDesc: return old.updatedAt != new.updatedAt
        case .titleAsc, .titleDesc: return old.displayTitle != new.displayTitle
        case .wordsDesc: return old.wordCount != new.wordCount
        case .moodDesc: return old.mood != new.mood || old.createdAt != new.createdAt
        }
    }

    /// Targeted update — refresh a single entry in every lifecycle collection
    /// that can display it, without paying for a full SQLite reload.
    private func updateEntry(_ entry: JournalEntry, refreshSearch: Bool = true) {
        if let old = replaceEntry(entry, in: &entries), sortKeyChanged(from: old, to: entry) {
            sort(&entries)
        }
        if let old = replaceEntry(entry, in: &archivedEntries), sortKeyChanged(from: old, to: entry) {
            sort(&archivedEntries)
        }
        replaceEntry(entry, in: &trashedEntries)
        replaceEntry(entry, in: &hiddenEntries)
        if var results = searchResults {
            if let old = replaceEntry(entry, in: &results), sortKeyChanged(from: old, to: entry) {
                sort(&results)
            }
            searchResults = results
        }
        if refreshSearch, searchResults != nil { refreshQuery() }
    }

    private func sortInPlace() {
        sort(&entries)
        if var results = searchResults {
            sort(&results)
            searchResults = results
        }
    }

    private func sort(_ collection: inout [JournalEntry]) {
        let order = sortOrder
        collection.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            switch order {
            case .dateDesc: return a.createdAt > b.createdAt
            case .dateAsc: return a.createdAt < b.createdAt
            case .updatedDesc: return a.updatedAt > b.updatedAt
            case .titleAsc: return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            case .titleDesc: return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedDescending
            case .wordsDesc: return a.wordCount > b.wordCount
            case .moodDesc:
                if a.mood != b.mood { return a.mood.rawValue > b.mood.rawValue }
                return a.createdAt > b.createdAt
            }
        }
    }

    func setSortOrder(_ order: SortOrder) {
        sortOrder = order
        sortInPlace()
    }

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

    // MARK: - Creating entries

    @discardableResult
    func createEntry(title: String = "", body: String = "", tags: [String] = []) -> JournalEntry {
        var entry = JournalEntry.new()
        entry.title = title
        entry.body = body
        entry.tags = OmegaCore.normalizeTags(tags)
        db.saveEntry(entry)
        entries.insert(entry, at: 0)
        sortInPlace()
        if searchResults != nil { refreshQuery() }
        selectedEntryId = entry.id
        editingEntryId = entry.id
        refreshTagCounts()
        return entry
    }

    func createEntryFromPrompt() {
        let prompt = PromptGenerator.today()
        createEntry(title: prompt, body: "", tags: ["prompt"])
        showToast("New entry from today's prompt")
    }

    func createEntry(from template: EntryTemplate) {
        createEntry(title: template.name == "Blank" ? "" : template.name, body: template.body, tags: template.tags)
        showToast("Started “\(template.name)”")
    }

    /// Creates an entry back-dated to a specific day — used by the calendar view.
    func createEntry(on date: Date) {
        var entry = JournalEntry.new()
        // Keep the current time-of-day but move to the requested calendar day.
        let cal = Calendar.current
        let time = cal.dateComponents([.hour, .minute, .second], from: Date())
        entry.createdAt = cal.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: time.second ?? 0, of: date) ?? date
        entry.updatedAt = entry.createdAt
        db.saveEntry(entry)
        entries.append(entry)
        sortInPlace()
        if searchResults != nil { refreshQuery() }
        selectedEntryId = entry.id
        editingEntryId = entry.id
    }

    /// Duplicates an entry as a fresh draft.
    func duplicate(_ entry: JournalEntry) {
        Task {
            guard await revealIfNeeded(entry) else { return }
            createEntry(title: entry.title.isEmpty ? "" : "\(entry.title) (copy)", body: entry.body, tags: entry.tags)
            showToast("Duplicated entry")
        }
    }

    func copyAsMarkdown(_ entry: JournalEntry) {
        Task {
            guard await revealIfNeeded(entry) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("# \(entry.displayTitle)\n\n\(entry.body)", forType: .string)
            showToast("Copied as Markdown")
        }
    }

    /// Prompts for biometrics when a hidden entry's content would otherwise leak.
    @discardableResult
    func revealIfNeeded(_ entry: JournalEntry) async -> Bool {
        if entry.isHidden && !BiometricAuth.shared.isAuthenticated {
            return await BiometricAuth.shared.authenticate()
        }
        return true
    }

    /// Re-masks every hidden entry. Safe to call from a walk-by — no auth required.
    /// Also fires from the idle-relock timer in BiometricAuth.
    func lockHiddenEntries() {
        guard BiometricAuth.shared.isAuthenticated else { return }
        flushPendingSave()
        if let editing = editingEntry, editing.isHidden {
            stopEditing()
        }
        BiometricAuth.shared.lock()
        showToast("Hidden entries locked")
        // Tag counts must re-derive immediately: the locked sidebar must not
        // advertise tags used on hidden entries (privacy rule in AGENTS.md).
        refreshTagCounts()
    }

    // MARK: - Selection & editing

    func toggleSelection(_ entry: JournalEntry) {
        selectedEntryId = (selectedEntryId == entry.id) ? nil : entry.id
    }

    func select(_ entry: JournalEntry) { selectedEntryId = entry.id }

    func startEditing(_ entry: JournalEntry) {
        selectedEntryId = entry.id
        if entry.isHidden && !BiometricAuth.shared.isAuthenticated {
            Task {
                guard await BiometricAuth.shared.authenticate() else { return }
                editingEntryId = entry.id
            }
            return
        }
        editingEntryId = entry.id
    }

    func stopEditing() {
        // Fold any pending debounced autosave into the database BEFORE the
        // editor tears down. EditorView's onDisappear flush can't do this —
        // editingEntryId is already nil by the time it runs, so that flush used
        // to be a no-op and the final keystrokes depended entirely on the
        // debounce Task surviving a fast "type → Done → quit".
        saveDebounce?.cancel()
        if let e = editingEntry {
            if e.title.isEmpty && e.body.isEmpty {
                // Discard entries that were never given any content.
                db.hardDeleteEntry(id: e.id)
                entries.removeAll { $0.id == e.id }
                searchResults?.removeAll { $0.id == e.id }
                archivedEntries.removeAll { $0.id == e.id }
                trashedEntries.removeAll { $0.id == e.id }
                hiddenEntries.removeAll { $0.id == e.id }
                if selectedEntryId == e.id { selectedEntryId = nil }
            } else {
                db.saveEntry(e)
            }
        }
        editingEntryId = nil
        saveState = .idle
        isZenMode = false
        refreshTagCounts()
        GoalManager.shared.loadGoals()
    }

    func autoSave(_ entry: JournalEntry) {
        // Update in-memory immediately so the UI stays responsive; persist on a debounce.
        var updated = entry
        updated.updatedAt = Date()
        updateEntry(updated, refreshSearch: false)
        saveState = .pending
        saveDebounce?.cancel()
        saveDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.db.saveEntry(updated)
                self.saveState = .saved
                if self.searchResults != nil { self.refreshQuery() }
                self.refreshTagCounts()
                GoalManager.shared.loadGoals()
            }
        }
    }

    /// Forces any pending debounced save to disk right away.
    func flushPendingSave() {
        saveDebounce?.cancel()
        if let e = editingEntry { db.saveEntry(e) }
        if saveState == .pending { saveState = .saved }
    }

    /// Replaces an entry's body immediately (e.g. ticking a task in the reader).
    /// Flushes any pending autosave first so a stale snapshot can't overwrite it.
    func updateBody(_ body: String, for entry: JournalEntry) {
        flushBeforeImmediateMutation()
        var u = entry
        u.body = body
        u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
        refreshTagCounts()
    }

    // MARK: - Entry mutations

    /// Immediate mutations must not race a pending debounced autosave: the
    /// debounce holds a full entry snapshot captured before the mutation, and
    /// letting it fire afterwards would silently revert pin/favorite/mood/
    /// archive/hide state. Flush first so storage reflects what is on screen,
    /// then apply the mutation on top.
    private func flushBeforeImmediateMutation() {
        saveDebounce?.cancel()
        if let e = editingEntry { db.saveEntry(e) }
    }

    func togglePin(_ entry: JournalEntry) {
        flushBeforeImmediateMutation()
        var u = entry; u.isPinned.toggle(); u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
        showToast(u.isPinned ? "Pinned" : "Unpinned")
    }

    func toggleFavorite(_ entry: JournalEntry) {
        flushBeforeImmediateMutation()
        var u = entry; u.isFavorite.toggle(); u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
        showToast(u.isFavorite ? "Added to favorites" : "Removed from favorites")
    }

    func setMood(_ mood: Mood, for entry: JournalEntry) {
        flushBeforeImmediateMutation()
        var u = entry; u.mood = mood; u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
    }

    // MARK: - Trash & archive

    /// Moves an entry to the trash (recoverable for 30 days).
    func deleteEntry(_ entry: JournalEntry) {
        // A pending autosave captured the pre-trash snapshot (deletedAt == nil);
        // letting it fire would overwrite deleted_at and resurrect the entry.
        saveDebounce?.cancel()
        db.trashEntry(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        searchResults?.removeAll { $0.id == entry.id }
        archivedEntries.removeAll { $0.id == entry.id }
        hiddenEntries.removeAll { $0.id == entry.id }
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        trashedEntries = db.fetchAllEntries(sort: .dateDesc, scope: .trashed)
        pushUndo(.restoreTrashed(ids: [entry.id]))
        refreshTagCounts()
        showToast("Moved to Trash", actionLabel: "Undo")
        GoalManager.shared.loadGoals()
    }

    func restoreFromTrash(_ entry: JournalEntry) {
        db.restoreEntry(id: entry.id)
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        reload()
        showToast("Restored “\(entry.displayTitle)”")
    }

    func deleteForever(_ entry: JournalEntry) {
        saveDebounce?.cancel()
        db.hardDeleteEntry(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        searchResults?.removeAll { $0.id == entry.id }
        archivedEntries.removeAll { $0.id == entry.id }
        trashedEntries.removeAll { $0.id == entry.id }
        hiddenEntries.removeAll { $0.id == entry.id }
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        refreshTagCounts()
        showToast("Deleted permanently", isError: true)
    }

    func emptyTrash() {
        saveDebounce?.cancel()
        let count = trashedEntries.count
        db.emptyTrash()
        trashedEntries = []
        if let selected = selectedEntryId, !entries.contains(where: { $0.id == selected }) {
            selectedEntryId = nil
        }
        if let editing = editingEntryId, entry(id: editing) == nil {
            editingEntryId = nil
        }
        refreshTagCounts()
        showToast("Emptied Trash (\(count) \(count == 1 ? "entry" : "entries"))", isError: true)
    }

    func toggleArchive(_ entry: JournalEntry) {
        // Archiving a trashed row would corrupt restore semantics (it would come
        // back pre-archived) and pollute the undo stack — refuse instead.
        guard !entry.isTrashed else { return }
        flushBeforeImmediateMutation()
        let newValue = !entry.isArchived
        db.setArchived(id: entry.id, archived: newValue)
        if selectedEntryId == entry.id { selectedEntryId = nil }
        reload()
        if newValue { pushUndo(.unarchive(ids: [entry.id])) }
        showToast(newValue ? "Archived" : "Unarchived", actionLabel: newValue ? "Undo" : nil)
    }

    func toggleHidden(_ entry: JournalEntry) {
        let newValue = !entry.isHidden
        // Unhiding reveals that the entry exists as a normal card — require auth.
        if !newValue && !BiometricAuth.shared.isAuthenticated {
            Task {
                guard await BiometricAuth.shared.authenticate() else { return }
                applyHidden(entry, hidden: false)
            }
            return
        }
        applyHidden(entry, hidden: newValue)
    }

    private func applyHidden(_ entry: JournalEntry, hidden: Bool) {
        flushBeforeImmediateMutation()
        db.setHidden(id: entry.id, hidden: hidden)
        // Close editor if hiding, but keep the entry selected so the card
        // stays visible (masked) in the list.
        if hidden && editingEntryId == entry.id { editingEntryId = nil }
        reload()
        showToast(hidden ? "Hidden" : "Unhidden")
    }

    // MARK: - Bulk actions

    func toggleBulkSelection(_ id: String) {
        if bulkSelection.contains(id) { bulkSelection.remove(id) } else { bulkSelection.insert(id) }
    }

    func clearBulkSelection() {
        bulkSelection.removeAll()
        isBulkSelecting = false
    }

    /// Keeps batch operations bounded to the rows currently visible in the
    /// Journal list whenever search or advanced filters change.
    func retainBulkSelection(in visibleIDs: [String]) {
        bulkSelection.formIntersection(Set(visibleIDs))
    }

    /// Restricts a bulk command to entries actually present in the intended
    /// lifecycle collection, so stale or missing IDs are never acted on.
    private func selectedIDs(in source: [JournalEntry]) -> [String] {
        let available = Set(source.map(\.id))
        return bulkSelection.filter(available.contains).sorted()
    }

    private var nonTrashedEntries: [JournalEntry] {
        entries + archivedEntries
    }

    /// Soft-deletes the selected active or archived entries. The operation is
    /// intentionally reversible via the toast's Undo action.
    func bulkMoveToTrash() {
        saveDebounce?.cancel()
        let ids = selectedIDs(in: nonTrashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        guard db.bulkTrash(ids: ids) else {
            showToast("Couldn't move the selection to Trash — nothing was changed", isError: true)
            reload()
            return
        }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        if let editing = editingEntryId, ids.contains(editing) { editingEntryId = nil }
        pushUndo(.restoreTrashed(ids: ids))
        clearBulkSelection()
        reload()
        showToast("Moved \(ids.count) \(ids.count == 1 ? "entry" : "entries") to Trash", actionLabel: "Undo")
    }

    /// Legacy name retained for existing callers. All bulk "Delete" actions
    /// outside Trash are recoverable moves to Trash.
    func bulkDelete() {
        bulkMoveToTrash()
    }

    func bulkArchive() {
        flushBeforeImmediateMutation()
        let ids = selectedIDs(in: entries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.setArchived(id: id, archived: true) }
        pushUndo(.unarchive(ids: ids))
        clearBulkSelection()
        reload()
        showToast("Archived \(ids.count) \(ids.count == 1 ? "entry" : "entries")", actionLabel: "Undo")
    }

    func bulkUnarchive() {
        flushBeforeImmediateMutation()
        let ids = selectedIDs(in: archivedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.setArchived(id: id, archived: false) }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        clearBulkSelection()
        reload()
        showToast("Unarchived \(ids.count) \(ids.count == 1 ? "entry" : "entries")")
    }

    func bulkRestoreFromTrash() {
        let ids = selectedIDs(in: trashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.restoreEntry(id: id) }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        clearBulkSelection()
        reload()
        showToast("Restored \(ids.count) \(ids.count == 1 ? "entry" : "entries")")
    }

    /// Irreversibly removes only selected entries that are already in Trash.
    /// The UI must obtain explicit confirmation before invoking this method.
    func bulkDeleteForever() {
        saveDebounce?.cancel()
        let ids = selectedIDs(in: trashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        for id in ids { db.hardDeleteEntry(id: id) }
        if let selected = selectedEntryId, ids.contains(selected) { selectedEntryId = nil }
        if let editing = editingEntryId, ids.contains(editing) { editingEntryId = nil }
        clearBulkSelection()
        reload()
        showToast("Deleted \(ids.count) \(ids.count == 1 ? "entry" : "entries") permanently", isError: true)
    }

    func bulkFavorite() {
        let ids = selectedIDs(in: nonTrashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        // Work from the in-memory (already decrypted) snapshot instead of
        // re-fetching + decrypting every row from SQLite.
        flushBeforeImmediateMutation()
        // One metadata-only transaction: no body re-encryption, all-or-nothing.
        guard let changed = db.bulkSetFavorite(ids: ids, favorite: true) else {
            showToast("Couldn't favorite the selection — nothing was changed", isError: true)
            reload()
            return
        }
        clearBulkSelection()
        reload()
        showToast(changed == 0 ? "Selected entries were already favorites" : "Favorited \(changed) \(changed == 1 ? "entry" : "entries")")
    }

    func bulkAddTag(_ tag: String) {
        // Commas are the text-column separator — never allow them inside a tag.
        guard let trimmed = OmegaCore.normalizeTags([tag]).first, !bulkSelection.isEmpty else { return }
        let ids = selectedIDs(in: nonTrashedEntries)
        guard !ids.isEmpty else {
            clearBulkSelection()
            return
        }
        flushBeforeImmediateMutation()
        guard let changed = db.bulkAddTag(ids: ids, tag: trimmed) else {
            showToast("Couldn't tag the selection — nothing was changed", isError: true)
            reload()
            return
        }
        clearBulkSelection()
        reload()
        showToast(changed == 0 ? "Selected entries already have #\(trimmed)" : "Tagged \(changed) \(changed == 1 ? "entry" : "entries") with #\(trimmed)")
    }

    // MARK: - Undo & toasts

    func showToast(_ message: String, actionLabel: String? = nil, isError: Bool = false) {
        let t = Toast(message: message, actionLabel: actionLabel, isError: isError)
        toast = t
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if self?.toast == t { self?.toast = nil }
            }
        }
    }

    private func pushUndo(_ action: UndoAction) {
        undoStack.append(action)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
    }

    var undoDepth: Int { undoStack.count }

    func performUndo() {
        guard let action = undoStack.popLast() else { return }
        // Report what actually changed: entries may since have been deleted
        // forever or restored by hand.
        switch action {
        case .restoreTrashed(let ids):
            let restorable = ids.filter { db.fetchEntry(id: $0)?.isTrashed == true }
            for id in restorable { db.restoreEntry(id: id) }
            showToast(Self.undoMessage(verb: "Restored", count: restorable.count, requested: ids.count))
        case .unarchive(let ids):
            let archived = ids.filter { db.fetchEntry(id: $0).map { $0.isArchived && !$0.isTrashed } == true }
            for id in archived { db.setArchived(id: id, archived: false) }
            showToast(Self.undoMessage(verb: "Unarchived", count: archived.count, requested: ids.count))
        }
        reload()
    }

    static func undoMessage(verb: String, count: Int, requested: Int) -> String {
        if count == 0 { return "Nothing to undo — those entries have changed since" }
        let noun = count == 1 ? "entry" : "entries"
        if count < requested { return "\(verb) \(count) of \(requested) \(requested == 1 ? "entry" : "entries")" }
        return "\(verb) \(count) \(noun)"
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

    // MARK: - Stats

    var moodThisWeek: [Mood: Int] {
        let w = Date().addingTimeInterval(-7 * 24 * 3600)
        var c: [Mood: Int] = [:]
        for e in entries where e.createdAt >= w { c[e.mood, default: 0] += 1 }
        return c
    }
    var totalWordCount: Int { entries.reduce(0) { $0 + $1.wordCount } }
    var averageMood: Double { entries.isEmpty ? 0 : Double(entries.reduce(0) { $0 + $1.mood.rawValue }) / Double(entries.count) }
    var entriesThisWeek: Int { entries.filter { $0.createdAt >= Date().addingTimeInterval(-7 * 24 * 3600) }.count }
    var favoriteCount: Int { entries.filter(\.isFavorite).count }
    var hiddenCount: Int { hiddenEntries.count }

    /// Distinct calendar days with an active entry. Cached against a cheap
    /// fingerprint so keystroke-driven `entries` updates don't redo calendar math.
    private var writingDaysCache: (key: [Double], days: Set<Date>)?

    private var writingDays: Set<Date> {
        let key = [Double(entries.count), entries.reduce(0) { $0 + $1.createdAt.timeIntervalSince1970 }]
        if let cache = writingDaysCache, cache.key == key { return cache.days }
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.createdAt) })
        writingDaysCache = (key, days)
        return days
    }

    /// Non-punitive streak: see `StreakCalculator` (one rest day per 7 is
    /// forgiven; weekly-goal mode counts weeks that hit the target).
    var streakSummary: StreakSummary {
        GoalManager.shared.streakSummary(writingDays: writingDays)
    }
    var writingStreak: Int { streakSummary.current }
    var longestStreak: Int { streakSummary.longest }
    var streakUnit: String { streakSummary.unit }
    /// Gentle "welcome back" copy, owned by Core so all views share one voice.
    var welcomeBackMessage: String { StreakCopy.welcomeBack(daysAway: streakSummary.daysSinceLastEntry) }

    var entriesThisMonth: Int {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .month, for: Date())?.start else { return 0 }
        return entries.filter { $0.createdAt >= start }.count
    }

    var averageWordsPerEntry: Int {
        entries.isEmpty ? 0 : totalWordCount / entries.count
    }

    var totalReadingTime: String {
        let total = entries.reduce(0) { $0 + $1.readingMinutes }
        if total < 60 { return "\(total) min" }
        return "\(total / 60)h \(total % 60)m"
    }

    /// The weekday the user journals on most, e.g. "Sunday".
    var mostProductiveDay: String {
        let cal = Calendar.current
        var counts: [Int: Int] = [:]
        for e in entries { counts[cal.component(.weekday, from: e.createdAt), default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return "—" }
        return cal.weekdaySymbols[best - 1]
    }

    /// The hour of day the user writes most often, e.g. "9 PM".
    var mostProductiveHour: String {
        var counts: [Int: Int] = [:]
        let cal = Calendar.current
        for e in entries { counts[cal.component(.hour, from: e.createdAt), default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return "—" }
        let suffix = best < 12 ? "AM" : "PM"
        let display = best % 12 == 0 ? 12 : best % 12
        return "\(display) \(suffix)"
    }

    /// Words written per day over the last `days`, for the writing-volume chart.
    func wordsPerDay(days: Int = 30) -> [WordPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var map: [Date: Int] = [:]
        for e in entries {
            let day = cal.startOfDay(for: e.createdAt)
            map[day, default: 0] += e.wordCount
        }
        return (0..<days).compactMap { i -> WordPoint? in
            guard let day = cal.date(byAdding: .day, value: -(days - 1 - i), to: today) else { return nil }
            return WordPoint(date: day, words: map[day] ?? 0)
        }
    }

    /// Entry counts per weekday (Sun…Sat) for the weekday-rhythm chart.
    var entriesByWeekday: [WeekdayCount] {
        let cal = Calendar.current
        var counts: [Int: Int] = [:]
        for e in entries { counts[cal.component(.weekday, from: e.createdAt), default: 0] += 1 }
        return (1...7).map { WeekdayCount(weekday: $0, symbol: cal.shortWeekdaySymbols[$0 - 1], count: counts[$0] ?? 0) }
    }

    // MARK: - Insights

    var analyticsEntryCount: Int { scopedAnalyticsEntries.count }
    var analyticsWordCount: Int { scopedAnalyticsEntries.reduce(0) { $0 + $1.wordCount } }
    var analyticsWritingDays: Int {
        Set(scopedAnalyticsEntries.map { Calendar.current.startOfDay(for: $0.createdAt) }).count
    }
    var analyticsAverageMood: Double? {
        guard !scopedAnalyticsEntries.isEmpty else { return nil }
        return Double(scopedAnalyticsEntries.reduce(0) { $0 + $1.mood.rawValue }) / Double(scopedAnalyticsEntries.count)
    }

    func wordsPerDay(for source: [JournalEntry], period: AnalyticsPeriod) -> [WordPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = period.startDate(relativeTo: today, calendar: cal)
            ?? source.map(\.createdAt).min().map(cal.startOfDay(for:))
            ?? today
        var map: [Date: Int] = [:]
        for entry in source {
            map[cal.startOfDay(for: entry.createdAt), default: 0] += entry.wordCount
        }
        var points: [WordPoint] = []
        var cursor = start
        while cursor <= today {
            points.append(WordPoint(date: cursor, words: map[cursor] ?? 0))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return points
    }

    func moodTrend(for source: [JournalEntry]) -> [MoodPoint] {
        let cal = Calendar.current
        var grouped: [Date: [JournalEntry]] = [:]
        for entry in source {
            grouped[cal.startOfDay(for: entry.createdAt), default: []].append(entry)
        }
        return grouped
            .map { day, entries in
                MoodPoint(
                    date: day,
                    avg: Double(entries.reduce(0) { $0 + $1.mood.rawValue }) / Double(entries.count)
                )
            }
            .sorted { $0.date < $1.date }
    }

    func moodDistribution(for source: [JournalEntry]) -> [MoodCount] {
        Mood.allCases
            .map { mood in MoodCount(mood: mood, count: source.filter { $0.mood == mood }.count) }
            .sorted { $0.mood.rawValue < $1.mood.rawValue }
    }

    func entriesByDay(for source: [JournalEntry]) -> [Date: [JournalEntry]] {
        let cal = Calendar.current
        var map: [Date: [JournalEntry]] = [:]
        for entry in source {
            map[cal.startOfDay(for: entry.createdAt), default: []].append(entry)
        }
        return map
    }

    func dailyInfo(for source: [JournalEntry]) -> [Date: DayInfo] {
        let grouped = entriesByDay(for: source)
        var result: [Date: DayInfo] = [:]
        for (date, entries) in grouped {
            let sortedEntries = entries.sorted { $0.createdAt > $1.createdAt }
            result[date] = DayInfo(
                date: date,
                count: sortedEntries.count,
                moods: sortedEntries.map(\.mood),
                titles: sortedEntries.prefix(3).map(\.displayTitle)
            )
        }
        return result
    }

    func moodTrend(days: Int = 30) -> [MoodPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var points: [MoodPoint] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -i, to: today),
                  let end = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let dayEntries = entries.filter { $0.createdAt >= day && $0.createdAt < end }
            guard !dayEntries.isEmpty else { continue }
            let avg = Double(dayEntries.reduce(0) { $0 + $1.mood.rawValue }) / Double(dayEntries.count)
            points.append(MoodPoint(date: day, avg: avg))
        }
        return points
    }

    func dailyCounts(daysBack: Int = 210) -> [Date: Int] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today) else { return [:] }
        var map: [Date: Int] = [:]
        for e in entries where e.createdAt >= start {
            map[cal.startOfDay(for: e.createdAt), default: 0] += 1
        }
        return map
    }

    struct DayInfo {
        let date: Date
        let count: Int
        let moods: [Mood]
        let titles: [String]
    }

    func dailyInfo(daysBack: Int = 210) -> [Date: DayInfo] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today) else { return [:] }
        var map: [Date: [JournalEntry]] = [:]
        for e in entries where e.createdAt >= start {
            map[cal.startOfDay(for: e.createdAt), default: []].append(e)
        }
        var result: [Date: DayInfo] = [:]
        for (date, dayEntries) in map {
            result[date] = DayInfo(
                date: date,
                count: dayEntries.count,
                moods: dayEntries.map(\.mood),
                titles: dayEntries.prefix(3).map(\.displayTitle)
            )
        }
        return result
    }

    var moodDistribution: [MoodCount] {
        Mood.allCases
            .map { m in MoodCount(mood: m, count: entries.filter { $0.mood == m }.count) }
            .sorted { $0.mood.rawValue < $1.mood.rawValue }
    }

    /// Entries bucketed by calendar day — powers the calendar month browser.
    func entriesByDay() -> [Date: [JournalEntry]] {
        let cal = Calendar.current
        var map: [Date: [JournalEntry]] = [:]
        for e in entries { map[cal.startOfDay(for: e.createdAt), default: []].append(e) }
        return map
    }

    // MARK: - On This Day

    /// Entries written on this month/day in any previous year.
    var onThisDay: [JournalEntry] {
        onThisDay(in: entries)
    }

    /// The privacy-aware memory surface used by Today and reflection pages.
    var reflectiveOnThisDay: [JournalEntry] {
        onThisDay(in: calendarEntries)
    }

    func onThisDay(in source: [JournalEntry]) -> [JournalEntry] {
        let cal = Calendar.current
        let today = Date()
        let month = cal.component(.month, from: today)
        let day = cal.component(.day, from: today)
        let thisYear = cal.component(.year, from: today)
        return source.filter { e in
            let eYear = cal.component(.year, from: e.createdAt)
            return eYear != thisYear &&
                cal.component(.month, from: e.createdAt) == month &&
                cal.component(.day, from: e.createdAt) == day
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Attachments

    func addAttachment(to entry: JournalEntry, data: Data, filename: String, mimeType: String) {
        guard let attachment = db.saveAttachment(entryId: entry.id, data: data, filename: filename, mimeType: mimeType) else {
            showToast("Couldn't attach \(filename)", isError: true)
            return
        }
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].attachments.append(attachment)
        }
        showToast("Attached \(filename)")
    }

    func deleteAttachment(_ attachment: Attachment) {
        db.deleteAttachment(id: attachment.id)
        for (i, entry) in entries.enumerated() {
            entries[i].attachments = entry.attachments.filter { $0.id != attachment.id }
        }
    }

    // MARK: - Import

    struct ImportReport: Equatable {
        var added = 0
        var duplicates = 0
        var skipped: [String] = []
    }

    /// Every stored entry, trashed included. Returns nil when the read looks
    /// failed (row count disagrees with COUNT(*)) so callers never treat an
    /// unreadable database as an empty one and re-insert over real data.
    private func allStoredEntries() -> [JournalEntry]? {
        let stored = db.fetchAllEntriesForExport()
        let expected = db.entryCount(scope: .all) + db.entryCount(scope: .trashed)
        return stored.count == expected ? stored : nil
    }

    private static func dupKey(title: String, createdAt: Date) -> String {
        "\(title)\u{1}\(Int((createdAt.timeIntervalSince1970 * 1000).rounded()))"
    }

    /// Imports entries from a previously exported JSON file. Returns the number added.
    /// Existing ids (active, archived, hidden OR trashed) are never overwritten.
    @discardableResult
    func importJSON(from url: URL) -> Int {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let export = try decoder.decode(ExportManager.JSONExport.self, from: data)
            guard let stored = allStoredEntries() else {
                showToast("Import aborted: couldn't read the existing journal safely", isError: true)
                return 0
            }
            flushBeforeImmediateMutation()
            var knownIDs = Set(stored.map(\.id))
            var added = 0
            var skipped = 0
            var pendingAttachments: [(id: String, items: [ExportManager.DecodedAttachment])] = []
            // One transaction for the whole file: a failure leaves the journal
            // untouched instead of half-imported, and there is one commit/FTS
            // pass instead of one per entry.
            let committed = db.inTransaction {
              for je in export.entries {
                guard knownIDs.insert(je.id).inserted else { skipped += 1; continue }
                let entry = JournalEntry(
                    id: je.id, title: je.title, body: je.body,
                    mood: Mood(rawValue: je.mood) ?? .neutral,
                    tags: OmegaCore.normalizeTags(je.tags),
                    createdAt: je.createdAt, updatedAt: je.updatedAt,
                    isPinned: je.isPinned, isFavorite: je.isFavorite,
                    isArchived: je.isArchived ?? false,
                    deletedAt: je.deletedAt,
                    isHidden: je.isHidden ?? false,
                    attachments: []
                )
                db.saveEntry(entry)
                added += 1
                let atts = ExportManager.decodeAttachments(je)
                if !atts.isEmpty { pendingAttachments.append((je.id, atts)) }
              }
            }
            guard committed else {
                reload()
                showToast("Import failed and was rolled back — no entries were added", isError: true)
                return 0
            }
            // Attachment files are written only after the entries committed.
            for (id, items) in pendingAttachments {
                for a in items { _ = db.saveAttachment(entryId: id, data: a.data, filename: a.filename, mimeType: a.mimeType) }
            }
            reload()
            if added == 0 {
                showToast("Nothing new to import (\(skipped) already in your journal)")
            } else {
                showToast("Imported \(added) \(added == 1 ? "entry" : "entries")" + (skipped > 0 ? ", skipped \(skipped) already present" : ""))
            }
            return added
        } catch {
            showToast("Import failed: \(error.localizedDescription)", isError: true)
            return 0
        }
    }

    /// Splits raw markdown into a title and body: a leading `# Heading` wins,
    /// otherwise the filename is the title. Pure, so it can be tested directly.
    static func parseMarkdownImport(text: String, fallbackTitle: String) -> (title: String, body: String) {
        OmegaCore.parseMarkdownImport(text: text, fallbackTitle: fallbackTitle)
    }

    /// Imports markdown files, one entry per file. Returns the number added;
    /// use `importMarkdownReport` for the skipped/duplicate breakdown.
    @discardableResult
    func importMarkdown(from urls: [URL]) -> Int {
        importMarkdownReport(from: urls).added
    }

    @discardableResult
    func importMarkdownReport(from urls: [URL]) -> ImportReport {
        var report = ImportReport()
        guard let stored = allStoredEntries() else {
            showToast("Import aborted: couldn't read the existing journal safely", isError: true)
            report.skipped = urls.map(\.lastPathComponent)
            return report
        }
        flushBeforeImmediateMutation()
        var keys = Set(stored.map { Self.dupKey(title: $0.title, createdAt: $0.createdAt) })
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                report.skipped.append(url.lastPathComponent)
                continue
            }
            let parsed = Self.parseMarkdownImport(
                text: text,
                fallbackTitle: url.deletingPathExtension().lastPathComponent
            )
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            guard keys.insert(Self.dupKey(title: parsed.title, createdAt: created)).inserted else {
                report.duplicates += 1
                continue
            }
            var entry = JournalEntry.new()
            entry.title = parsed.title
            entry.body = parsed.body
            entry.tags = OmegaCore.normalizeTags(["imported"])
            entry.createdAt = created
            entry.updatedAt = created
            db.saveEntry(entry)
            report.added += 1
        }
        reload()
        var parts: [String] = []
        parts.append(report.added == 0 ? "No markdown files imported" : "Imported \(report.added) markdown \(report.added == 1 ? "file" : "files")")
        if report.duplicates > 0 { parts.append("\(report.duplicates) already imported") }
        if !report.skipped.isEmpty {
            let names = report.skipped.prefix(3).joined(separator: ", ")
            parts.append("\(report.skipped.count) unreadable (\(names)\(report.skipped.count > 3 ? "…" : ""))")
        }
        showToast(parts.joined(separator: " · "), isError: !report.skipped.isEmpty)
        return report
    }
}
