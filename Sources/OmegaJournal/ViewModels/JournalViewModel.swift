import Foundation
import SwiftUI
import AppKit
import OmegaJournalCore

// MARK: - Journal View Model

@MainActor
@Observable
final class JournalViewModel {
    // Library
    var entries: [JournalEntry] = [] {
        didSet {
            entriesRevision &+= 1
            recomputeMoodCounts()
        }
    }
    /// Bumped on every change to `entries`; a background search compares it
    /// before publishing so it never shows results for an older library.
    @ObservationIgnored var entriesRevision = 0
    /// Bumped by every search run; only the newest may publish.
    @ObservationIgnored var searchGeneration = 0
    /// Precomputed per-mood counts of active entries (sidebar badges) so views
    /// don't re-filter the whole library for every mood on every render.
    var moodCounts: [Mood: Int] = [:]
    var trashedEntries: [JournalEntry] = []
    var archivedEntries: [JournalEntry] = []
    var hiddenEntries: [JournalEntry] = []
    var templates: [EntryTemplate] = []
    var allTags: [(tag: String, count: Int)] = []
    /// Search results are intentionally separate from the active-library snapshot so
    /// Calendar, sidebar counts, goals, and Insights never become search-dependent.
    var searchResults: [JournalEntry]?

    // Selection & editing
    var selectedEntryId: String?
    /// Every path that closes the editor (Done, trash, hide, bulk trash, a
    /// move out of scope, a restore) also leaves Zen and settles the save
    /// indicator here, so the next editor never opens straight into
    /// full-window Zen with a stale "Saved"/"Saving…" footer.
    var editingEntryId: String? {
        didSet {
            // The blank-draft marker belongs to one editor session only.
            if newDraftId != nil, newDraftId != editingEntryId { newDraftId = nil }
            guard editingEntryId == nil, oldValue != nil else { return }
            if isZenMode { isZenMode = false }
            let settled = currentFailureState ?? .idle
            if saveState != settled { saveState = settled }
        }
    }

    // Search & filtering
    var searchText: String = ""
    /// Persisted on every real change once `init` finishes (see
    /// `persistsViewState`); loading the saved value never writes it back.
    var sortOrder: SortOrder = .dateDesc {
        didSet {
            guard persistsViewState, sortOrder != oldValue else { return }
            db.setSetting(Self.sortOrderSettingKey, value: sortOrder.rawValue)
        }
    }
    var filter: EntryFilter = .empty {
        didSet {
            guard persistsViewState, filter != oldValue else { return }
            if let data = try? JSONEncoder().encode(filter), let text = String(data: data, encoding: .utf8) {
                db.setSetting(Self.filterSettingKey, value: text)
            }
        }
    }
    /// Named search + tag/mood filter combinations (stored as JSON in settings).
    var savedSearches: [SavedSearch] = []
    /// Notebooks. `activeJournalId == nil` means "All journals".
    var journals: [Journal] = []
    var activeJournalId: String?
    var tagColors: [String: String] = [:]
    var smartFolders: [SmartFolder] = []
    var smartFolderCounts: [String: Int] = [:]
    var recentSearches: [String] = []
    var journalCounts: [String: Int] = [:]
    var tagTree: [TagNode] = []
    /// Set when part of the journal could not be read (fixed wording, never
    /// raw SQLite text); a list that failed to load is then kept as it was
    /// instead of being shown empty. Cleared by the next complete `reload()`.
    /// Shown by `DataErrorBanner`; Retry calls `retryReading()`.
    var readError: String?
    /// The notebook the lists were last loaded for: a failed reload keeps the
    /// previous lists only when they belong to the same notebook.
    @ObservationIgnored var loadedJournalId: String??

    // Reflection scope
    var analyticsPeriod: AnalyticsPeriod = .thirtyDays
    var analyticsVisibility: AnalyticsVisibility = .visibleOnly

    // UI state
    var editorMode: EditorMode = .write
    var isZenMode = false
    var showCommandPalette = false
    var toast: Toast?

    /// Set of entry ids selected for bulk actions (multi-select mode in the list).
    var bulkSelection: Set<String> = []
    var isBulkSelecting = false

    let db: DatabaseManager
    @ObservationIgnored var searchDebounce: Task<Void, Never>?
    @ObservationIgnored var saveDebounce: Task<Void, Never>?
    /// The exact snapshot `saveDebounce` will persist. Flushing writes THIS —
    /// not whatever `editingEntry` happens to be by then — so switching,
    /// creating, trashing or reloading can never drop or misdirect an edit.
    @ObservationIgnored var pendingSave: JournalEntry?
    /// Editor save indicator: `.pending` while a debounced autosave is queued,
    /// `.failed(reason)` while any snapshot in `unsavedSnapshots` is unsaved.
    typealias SaveState = SaveStatus
    var saveState: SaveState = .idle
    /// Snapshots whose write failed, by entry id. They are never dropped on
    /// failure: each flush, the next edit, and the explicit Retry action try
    /// them again, and `reload()` re-applies them so stale storage cannot
    /// replace text the user typed.
    @ObservationIgnored var unsavedSnapshots: [String: JournalEntry] = [:] {
        didSet {
            // Publish only real changes: every successful write clears its id,
            // which must not wake every observer on each keystroke save.
            let ids = Set(unsavedSnapshots.keys)
            if ids != unsavedEntryIds { unsavedEntryIds = ids }
            let reasons = unsavedReasons.filter { ids.contains($0.key) }
            if reasons != unsavedReasons { unsavedReasons = reasons }
        }
    }
    /// Ids of entries with an unsaved snapshot. Published so views outside the
    /// editor (reader banner, list rows, sidebar) keep showing the failure
    /// after the editor closes and the toast is gone.
    private(set) var unsavedEntryIds: Set<String> = []
    /// Failure reason per unsaved entry (fixed wording, never content).
    var unsavedReasons: [String: SaveFailureReason] = [:]
    /// Last tag rename/delete, applied to unsaved snapshots and published so an
    /// open editor rewrites its own tag list the same way.
    private(set) var lastTagRewrite: SaveTagRewrite?
    /// Bumped on every tag rewrite (even a repeat of the same one) so an open
    /// editor reacts to each rewrite, as it did to every `$lastTagRewrite` emit.
    private(set) var tagRewriteGeneration = 0
    /// Reason for the most recent failed snapshot write.
    var lastSaveFailure: SaveFailureReason?
    /// The failure toast is shown once per failure episode, not per retry.
    @ObservationIgnored var saveFailureAnnounced = false
    /// Test seam: replaces the database write used for autosave snapshots and
    /// retries. Throwing simulates a failed write without corrupting a DB.
    @ObservationIgnored var saveWriterOverride: ((JournalEntry) throws -> Void)?
    @ObservationIgnored var undoStack: [UndoAction] = []
    /// Undo history is bounded: an unbounded stack of id arrays only grows.
    static let maxUndoDepth = 50
    /// False until `init` finishes, so loading saved view state never
    /// re-persists it (the Combine sinks this replaces used `dropFirst`).
    @ObservationIgnored var persistsViewState = false
    /// The blank entry the open editor session created (⌘N, a Calendar day),
    /// until it is given any content. Only this draft may be discarded
    /// outright; any other entry that ends up empty goes to Trash instead.
    @ObservationIgnored var newDraftId: String?
    /// Distinct writing days, cached against a cheap fingerprint so keystroke-driven
    /// `entries` updates don't redo calendar math (see `writingDays`).
    @ObservationIgnored var writingDaysCache: (key: [Double], days: Set<Date>)?

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
    enum UndoAction {
        case restoreTrashed(ids: [String])
        case unarchive(ids: [String])
    }

    /// `database` is a test seam: suites that must not share rows with the
    /// singleton (parallel suites assert an empty library) pass a private one.
    init(database: DatabaseManager = .shared) {
        db = database
        // Surface database write failures that used to be swallowed. The
        // reporter is installed before reload() so launch-time failures
        // (migration, reconciliation) still reach the user.
        db.onError = { [weak self] message in
            self?.showToast(message, isError: true)
        }
        loadPersistedViewState()
        loadOrganizationState()
        reload()
        loadTemplates()
        persistsViewState = true
        // Lock/unlock changes which tags may appear in the sidebar and what a
        // hidden entry may match on, so re-derive tag counts and re-run the
        // active search whenever the biometric session really changes
        // (delivered asynchronously on the main queue, after the change).
        // This covers every lock path (idle relock, App Lock, resign-active)
        // without every mutation site needing to remember to do it.
        BiometricAuth.shared.observeSessionChanges(owner: self) { [weak self] in
            self?.sessionDidChange()
        }
    }

    /// Delivered after every real lock-state change.
    func sessionDidChange() {
        refreshTagCounts()
        refreshQuery()
    }

    // MARK: - Persisted view state

    static let sortOrderSettingKey = "ui_sortOrder"
    static let filterSettingKey = "ui_entryFilter"

    func loadPersistedViewState() {
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

    // MARK: - Loading

    func reload() {
        // A queued autosave must land before rows are re-read, or the reload
        // would replace the edit in memory with stale storage. Only the
        // pending snapshot is written, never other in-memory state.
        persistPendingSnapshot()
        let failuresBefore = db.readFailureCount
        // One shared attachments/tags scan for all scopes plus the single
        // tagsWithCounts query below.
        let fetched = db.fetchScopesChecked([
            (.active, sortOrder),
            (.trashed, .dateDesc),
            (.archived, sortOrder),
        ], journalId: activeJournalId)
        // A scope that could not be read keeps what is on screen (same
        // notebook only) rather than turning into an empty journal.
        let sameNotebook = loadedJournalId == .some(activeJournalId)
        func pick(_ scope: DatabaseManager.EntryScope, _ current: [JournalEntry]) -> [JournalEntry] {
            if fetched.failed.contains(scope), sameNotebook, !current.isEmpty { return current }
            return fetched.entries[scope] ?? []
        }
        entries = pick(.active, entries)
        trashedEntries = pick(.trashed, trashedEntries)
        archivedEntries = pick(.archived, archivedEntries)
        if fetched.failed.isEmpty { loadedJournalId = .some(activeJournalId) }
        // `.hidden` is exactly the hidden rows of active + archived (neither
        // includes the trash), so it is derived instead of fetched and
        // decrypted a second time.
        hiddenEntries = Self.hiddenScope(active: entries, archived: archivedEntries)
        reapplyUnsavedSnapshots()
        // While the biometric session is locked, hidden entries must not
        // advertise their tags in the sidebar/filter chips.
        allTags = db.tagsWithCounts(includeHidden: BiometricAuth.shared.isAuthenticated, journalId: activeJournalId)
        refreshOrganization()
        GoalManager.shared.loadGoals()
        refreshQuery()
        dropDanglingSelectionAndEditor()
        noteReadOutcome(since: failuresBefore, complete: true)
    }

    static let readErrorMessage =
        "Part of your journal couldn’t be read just now. Nothing was deleted — try again in a moment."

    /// Shows or clears `readError` after a refresh. Only a complete reload
    /// can clear it; a targeted refresh can only raise it.
    func noteReadOutcome(since failuresBefore: Int, complete: Bool) {
        if db.readFailureCount != failuresBefore {
            if readError == nil {
                OmegaLog.viewModel.error("Showing the read-error banner after a failed refresh")
            }
            readError = Self.readErrorMessage
        } else if complete {
            readError = nil
        }
    }

    /// The banner's Retry: reads everything again.
    func retryReading() {
        reload()
    }

    /// The reloaded scope may no longer contain the selected or edited entry
    /// (moved to another notebook, a restored backup without it, a notebook
    /// switch). Drop those ids so the editor closes for good instead of
    /// popping back open once the entry is in scope again. The pending
    /// autosave was already persisted at the top of `reload()`.
    func dropDanglingSelectionAndEditor() {
        if let selected = selectedEntryId, entry(id: selected) == nil { selectedEntryId = nil }
        if let editing = editingEntryId, entry(id: editing) == nil { editingEntryId = nil }
    }

    func loadTemplates() {
        templates = db.templates()
    }

    /// Sidebar tag counts, excluding hidden entries' tags while the biometric
    /// session is locked. Every mutation path refreshes counts through this so
    /// the privacy rule holds regardless of where the refresh happens.
    func refreshTagCounts() {
        allTags = db.tagsWithCounts(includeHidden: BiometricAuth.shared.isAuthenticated, journalId: activeJournalId)
        refreshOrganization()
    }

    /// Re-runs the search box query over the active list.
    ///
    /// Every search surface uses the same grammar (`SearchQuery`: all words,
    /// `"exact phrase"`, `-exclusion`, operators), matched over the decrypted
    /// in-memory library. FTS5 (titles and tags only — bodies never reach the
    /// on-disk index) just ranks the matches: its hits come first, the rest
    /// keep list order. Locked hidden entries match on title only.
    ///
    /// Synchronous (callers and tests read `searchResults` right after); the
    /// typing path, `searchTextChanged`, runs the same match off the main
    /// actor instead. Supersedes any search still running in the background.
    func refreshQuery() {
        searchGeneration &+= 1
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchResults = nil
            return
        }
        let parsed = SearchQuery.parse(q)
        let matched = Self.indexedMatches(PreparedSearchQuery(parsed), in: entries, hiddenLocked: hiddenLocked)
        publishSearch(matched, parsed: parsed)
    }

    /// FTS ranking on top of the in-memory matches (ids only — nothing is
    /// decrypted for ranking).
    private func publishSearch(_ matched: [JournalEntry], parsed: SearchQuery) {
        let ftsText = parsed.terms.joined(separator: " ")
        guard !ftsText.isEmpty else {
            searchResults = matched
            return
        }
        let ranked = db.ftsRankedIds(ftsText, scope: .active, journalId: activeJournalId)
        searchResults = Self.rankedFirst(matched, rankedIds: ranked)
    }

    /// The query matched over `pool` with prepared terms and per-body cached
    /// search eligibility. Same answer as `SearchQuery.matches` per entry
    /// (see `IndexSearchText`). Pure; safe off the main actor. With
    /// `stopsWhenCancelled` it returns early (a partial list the caller must
    /// discard) once the surrounding task is cancelled.
    nonisolated static func indexedMatches(_ prepared: PreparedSearchQuery, in pool: [JournalEntry],
                                           hiddenLocked: Bool, stopsWhenCancelled: Bool = false) -> [JournalEntry] {
        guard !prepared.isEmpty else { return pool }
        var out: [JournalEntry] = []
        for (i, entry) in pool.enumerated() {
            if stopsWhenCancelled, i & 255 == 255, Task.isCancelled { break }
            if prepared.matches(entry.indexedSearchRecord, hiddenLocked: hiddenLocked) { out.append(entry) }
        }
        return out
    }

    /// Background half of the typing path: matches an immutable snapshot of
    /// the library off the main actor, then publishes on the main actor only
    /// if nothing changed meanwhile (same query, same library revision, no
    /// newer search). If the library changed, it falls back to the
    /// synchronous `refreshQuery()` so results are never stale.
    func refreshQueryInBackground() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            refreshQuery()
            return
        }
        searchGeneration &+= 1
        let generation = searchGeneration
        let revision = entriesRevision
        let pool = entries
        let locked = hiddenLocked
        let parsed = SearchQuery.parse(q)
        let matched = await Self.matchOffMain(PreparedSearchQuery(parsed), in: pool, hiddenLocked: locked)
        guard !Task.isCancelled, generation == searchGeneration,
              q == searchText.trimmingCharacters(in: .whitespaces) else { return }
        guard revision == entriesRevision, locked == hiddenLocked else {
            refreshQuery()
            return
        }
        publishSearch(matched, parsed: parsed)
    }

    @concurrent
    nonisolated static func matchOffMain(_ prepared: PreparedSearchQuery, in pool: [JournalEntry],
                                         hiddenLocked: Bool) async -> [JournalEntry] {
        indexedMatches(prepared, in: pool, hiddenLocked: hiddenLocked, stopsWhenCancelled: true)
    }

    /// `matches` with the ids in `rankedIds` moved to the front, in that order;
    /// the rest keep their order. Ids that aren't in `matches` are ignored, so
    /// ranking can never add a result.
    nonisolated static func rankedFirst(_ matches: [JournalEntry], rankedIds: [String]) -> [JournalEntry] {
        guard !rankedIds.isEmpty else { return matches }
        let byId = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var out: [JournalEntry] = []
        out.reserveCapacity(matches.count)
        for id in rankedIds { if let e = byId[id], seen.insert(id).inserted { out.append(e) } }
        for e in matches where seen.insert(e.id).inserted { out.append(e) }
        return out
    }

    /// Search grammar over already-decrypted entries (see `SearchQuery`).
    /// Locked hidden entries match on title only.
    static func searchMatches(_ source: [JournalEntry], query: String, unlocked: Bool) -> [JournalEntry] {
        let parsed = SearchQuery.parse(query)
        guard !parsed.isEmpty else { return source }
        return source.filter { parsed.matches($0.searchRecord, hiddenLocked: !unlocked) }
    }

    /// Applies the current query to a non-active storage collection (Archive,
    /// Hidden, Trash) with the same grammar as the journal list, so their
    /// search field never lies. Locked hidden entries match titles only.
    func entriesMatchingCurrentSearch(in source: [JournalEntry]) -> [JournalEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return source }
        let parsed = SearchQuery.parse(query)
        guard !parsed.isEmpty else { return source }
        return operatorMatches(parsed, in: source)
    }

    /// Debounced search — called on every keystroke. After 250 ms of quiet
    /// the query is matched off the main actor (`refreshQueryInBackground`);
    /// a newer keystroke cancels both the wait and the running match.
    func searchTextChanged() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.refreshQueryInBackground()
            guard !Task.isCancelled else { return }
            let q = self.searchText
            if q.count >= 3 { self.recordRecentSearch(q) }
        }
    }

    /// Replaces the entry in `collection` and returns the previous value.
    @discardableResult
    func replaceEntry(_ entry: JournalEntry, in collection: inout [JournalEntry]) -> JournalEntry? {
        guard let idx = collection.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let old = collection[idx]
        collection[idx] = entry
        return old
    }

    /// Whether replacing `old` with `new` can change its position under the
    /// current sort order. Typing changes body/updatedAt on every keystroke, so
    /// re-sorting unconditionally made each keystroke O(n log n).
    func sortKeyChanged(from old: JournalEntry, to new: JournalEntry) -> Bool {
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
    func updateEntry(_ entry: JournalEntry, refreshSearch: Bool = true) {
        // A draft that has had content at any point is no longer discardable.
        if entry.id == newDraftId, !Self.isBlank(entry) { newDraftId = nil }
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

    /// Re-sorts every collection `reload()` fetches with `sortOrder` (active
    /// and Archive) plus search results, so in-place and reloaded orders agree.
    func sortInPlace() {
        sort(&entries)
        sort(&archivedEntries)
        if var results = searchResults {
            sort(&results)
            searchResults = results
        }
    }

    func sort(_ collection: inout [JournalEntry]) {
        Self.sort(&collection, by: sortOrder)
    }

    /// The Hidden list: hidden entries of the active and archived scopes,
    /// in the `.hidden` fetch order (pinned first, newest first).
    static func hiddenScope(active: [JournalEntry], archived: [JournalEntry]) -> [JournalEntry] {
        var hidden = (active + archived).filter(\.isHidden)
        hidden.sort { storagePrecedes($0, $1, by: .dateDesc) }
        return hidden
    }

    /// Sorts with an explicit order (Trash and Hidden always use `.dateDesc`).
    static func sort(_ collection: inout [JournalEntry], by order: SortOrder) {
        collection.sort { precedes($0, $1, by: order) }
    }

    /// The list order: pinned first, then `order`.
    static func precedes(_ a: JournalEntry, _ b: JournalEntry, by order: SortOrder) -> Bool {
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

    /// The database's list order (`DatabaseManager.orderClause`), re-created
    /// in memory: pinned first, then `order` with SQLite's NOCASE title
    /// collation, then id. A row inserted with this lands exactly where a
    /// fresh fetch would put it.
    static func storagePrecedes(_ a: JournalEntry, _ b: JournalEntry, by order: SortOrder) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        func byId() -> Bool { a.id.utf8.lexicographicallyPrecedes(b.id.utf8) }
        switch order {
        case .dateDesc: return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : byId()
        case .dateAsc: return a.createdAt != b.createdAt ? a.createdAt < b.createdAt : byId()
        case .updatedDesc: return a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : byId()
        case .titleAsc, .titleDesc:
            let c = sqliteNoCaseCompare(a.title, b.title)
            if c == 0 { return byId() }
            return order == .titleAsc ? c < 0 : c > 0
        case .wordsDesc: return a.wordCount != b.wordCount ? a.wordCount > b.wordCount : byId()
        case .moodDesc:
            if a.mood != b.mood { return a.mood.rawValue > b.mood.rawValue }
            return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : byId()
        }
    }

    /// SQLite's built-in NOCASE collation: UTF-8 bytes compared with only
    /// ASCII A–Z folded; a shorter prefix sorts first.
    static func sqliteNoCaseCompare(_ a: String, _ b: String) -> Int {
        func fold(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5A) ? c | 0x20 : c }
        var ia = a.utf8.makeIterator()
        var ib = b.utf8.makeIterator()
        while true {
            switch (ia.next(), ib.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (x?, y?):
                let fx = fold(x), fy = fold(y)
                if fx != fy { return fx < fy ? -1 : 1 }
            }
        }
    }

    /// Inserts `entry` where a fresh fetch would put it, leaving every other
    /// row in place (no full re-sort).
    static func insert(_ entry: JournalEntry, into collection: inout [JournalEntry], by order: SortOrder) {
        let index = collection.firstIndex { storagePrecedes(entry, $0, by: order) } ?? collection.endIndex
        collection.insert(entry, at: index)
    }

    func setSortOrder(_ order: SortOrder) {
        sortOrder = order
        sortInPlace()
    }

    // MARK: - Creating entries

    @discardableResult
    func createEntry(title: String = "", body: String = "", tags: [String] = [],
                     journalId: String? = nil, isHidden: Bool = false) -> JournalEntry {
        flushPendingSave()
        // A new editor opening over an untouched blank draft discards it.
        discardUntouchedDraft()
        var entry = JournalEntry.new()
        entry.journalId = journalId ?? newEntryJournalId
        entry.title = title
        entry.body = body
        entry.tags = OmegaCore.normalizeTags(tags)
        entry.isHidden = isHidden
        db.saveEntry(entry)
        entries.insert(entry, at: 0)
        if isHidden { hiddenEntries.insert(entry, at: 0) }
        sortInPlace()
        if searchResults != nil { refreshQuery() }
        selectedEntryId = entry.id
        editingEntryId = entry.id
        if Self.isBlank(entry) { newDraftId = entry.id }
        refreshTagCounts()
        return entry
    }

    func createEntryFromPrompt() {
        let prompt = PromptGenerator.today()
        createEntry(title: prompt, body: "", tags: ["prompt"])
        showToast("New entry from today's prompt")
    }

    func createEntry(from template: EntryTemplate) {
        let filled = TemplateExpander.instantiate(
            name: template.name, body: template.body, tags: template.tags,
            context: TemplateContext(date: Date(), prompt: PromptGenerator.today(), moodLabel: Mood.neutral.label))
        createEntry(title: filled.title, body: filled.body, tags: filled.tags)
        showToast("Started “\(template.name)”")
    }

    /// Creates an entry back-dated to a specific day — used by the calendar view.
    func createEntry(on date: Date) {
        flushPendingSave()
        discardUntouchedDraft()
        var entry = JournalEntry.new()
        entry.journalId = newEntryJournalId
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
        newDraftId = entry.id
        refreshTagCounts()
    }

    /// Duplicates an entry as a fresh draft.
    @discardableResult
    func duplicate(_ entry: JournalEntry) -> Task<JournalEntry?, Never> {
        Task {
            guard await revealIfNeeded(entry) else { return nil }
            // A copy of a private entry must stay private and in its notebook.
            let copy = createEntry(title: entry.title.isEmpty ? "" : "\(entry.title) (copy)", body: entry.body,
                                   tags: entry.tags, journalId: entry.journalId, isHidden: entry.isHidden)
            showToast("Duplicated entry")
            return copy
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
        // Search results were computed unlocked; a locked hidden entry may now
        // match on its title only, so re-run the query before anything renders.
        refreshQuery()
    }

    // MARK: - Selection & editing

    func toggleSelection(_ entry: JournalEntry) {
        selectedEntryId = (selectedEntryId == entry.id) ? nil : entry.id
    }

    func select(_ entry: JournalEntry) { selectedEntryId = entry.id }

    func startEditing(_ entry: JournalEntry) {
        flushPendingSave()
        selectedEntryId = entry.id
        if entry.isHidden && !BiometricAuth.shared.isAuthenticated {
            Task {
                guard await BiometricAuth.shared.authenticate() else { return }
                openEditor(on: entry.id)
            }
            return
        }
        openEditor(on: entry.id)
    }

    /// Points the editor at `id`. An untouched blank draft it replaces is
    /// discarded first (it would otherwise linger as an empty "Untitled").
    private func openEditor(on id: String) {
        if editingEntryId != id {
            flushPendingSave()
            if discardUntouchedDraft() {
                refreshTagCounts()
                GoalManager.shared.loadGoals()
            }
        }
        editingEntryId = id
    }

    func stopEditing() {
        // Fold any pending debounced autosave into the database BEFORE the
        // editor tears down. EditorView's onDisappear flush can't do this —
        // editingEntryId is already nil by the time it runs, so that flush used
        // to be a no-op and the final keystrokes depended entirely on the
        // debounce Task surviving a fast "type → Done → quit".
        flushPendingSave()
        if !discardUntouchedDraft(), let e = editingEntry, !e.isTrashed,
           unsavedSnapshots[e.id] == nil, hasNoContent(e) {
            // An existing entry the user emptied is never destroyed on Done:
            // it goes to Trash (recoverable, with Undo) like any other delete.
            deleteEntry(e, toast: "Empty entry moved to Trash")
        }
        editingEntryId = nil
        // A failed save stays visible (and retryable) after the editor closes.
        saveState = currentFailureState ?? .idle
        isZenMode = false
        refreshTagCounts()
        GoalManager.shared.loadGoals()
    }

    // MARK: Blank drafts

    /// No text, tags, mood or attachment on the in-memory copy. Cheap enough
    /// for every keystroke (no storage access).
    static func isBlank(_ entry: JournalEntry) -> Bool {
        entry.title.isEmpty && entry.body.isEmpty && entry.tags.isEmpty
            && entry.mood == .neutral   // JournalEntry.new()'s mood
            && entry.attachments.isEmpty
    }

    /// `isBlank`, plus no attachment in storage: not every collection copy is
    /// refreshed when a voice memo or file is attached (archived entries).
    func hasNoContent(_ entry: JournalEntry) -> Bool {
        Self.isBlank(entry) && db.fetchAttachments(entryId: entry.id).isEmpty
    }

    /// The single discard rule: only a draft this editor session created
    /// blank, that never had content and has nothing unsaved.
    func isUntouchedNewDraft(_ entry: JournalEntry) -> Bool {
        entry.id == newDraftId && unsavedSnapshots[entry.id] == nil && hasNoContent(entry)
    }

    /// Permanently discards the open editor's draft if it is still untouched
    /// (Done, or another editor opening over it). Callers flush first.
    /// Returns whether it was discarded.
    @discardableResult
    func discardUntouchedDraft() -> Bool {
        guard let draft = editingEntry, isUntouchedNewDraft(draft) else { return false }
        db.hardDeleteEntry(id: draft.id)
        entries.removeAll { $0.id == draft.id }
        searchResults?.removeAll { $0.id == draft.id }
        archivedEntries.removeAll { $0.id == draft.id }
        trashedEntries.removeAll { $0.id == draft.id }
        hiddenEntries.removeAll { $0.id == draft.id }
        if selectedEntryId == draft.id { selectedEntryId = nil }
        newDraftId = nil
        return true
    }

    func autoSave(_ entry: JournalEntry) {
        // Update in-memory immediately so the UI stays responsive; persist on a debounce.
        var updated = entry
        updated.updatedAt = Date()
        // A snapshot queued for a different entry is persisted now, never
        // silently replaced.
        if let queued = pendingSave, queued.id != updated.id { persistPendingSnapshot() }
        updateEntry(updated, refreshSearch: false)
        // Keep a failure on screen while typing; the debounced write retries
        // and only a successful write turns it into "Saved".
        if !saveState.isFailed { saveState = .pending }
        saveDebounce?.cancel()
        pendingSave = updated
        saveDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.pendingSave != nil else { return }
                self.flushPendingSave()
                if self.searchResults != nil { self.refreshQuery() }
                self.refreshTagCounts()
                GoalManager.shared.loadGoals()
            }
        }
    }

    /// Forces any pending debounced save to disk right away, then retries any
    /// snapshot whose earlier write failed. `pending` only becomes `saved` when
    /// nothing is left unsaved; otherwise the state is `.failed(reason)`.
    func flushPendingSave() {
        persistPendingSnapshot()
        retryUnsavedSnapshots()
        updateSaveStateAfterWrite()
    }

    /// Cancels the debounce and writes its queued snapshot, if any. Never
    /// writes other in-memory state, so it cannot clobber newer storage. A
    /// failed write moves the snapshot into `unsavedSnapshots` (never dropped).
    @discardableResult
    func persistPendingSnapshot() -> Bool {
        saveDebounce?.cancel()
        saveDebounce = nil
        guard let snapshot = pendingSave else { return false }
        pendingSave = nil
        attemptSnapshotWrite(snapshot)
        return true
    }

    /// Explicit Retry (editor footer): writes the queued snapshot and every
    /// failed one again. Returns whether everything is now saved.
    @discardableResult
    func retryFailedSaves() -> Bool {
        let hadFailures = !unsavedSnapshots.isEmpty
        flushPendingSave()
        let ok = unsavedSnapshots.isEmpty
        if ok && hadFailures { showToast("Saved") }
        if !ok, let reason = lastSaveFailure {
            // The once-per-failure toast already fired; an explicit Retry that
            // fails again still needs feedback.
            showToast("Still not saved — \(reason.message). Your text is kept.", isError: true)
        }
        return ok
    }

    // MARK: Save failure handling

    /// Number of entries whose latest text is not in storage.
    var unsavedEntryCount: Int { unsavedEntryIds.count }

    /// Whether `entryId` has text that failed to save (row/list badge seam).
    func hasUnsavedChanges(entryId: String) -> Bool { unsavedEntryIds.contains(entryId) }

    /// Why `entryId`'s last write failed, or nil when it is saved.
    func unsavedFailureReason(entryId: String) -> SaveFailureReason? {
        guard unsavedEntryIds.contains(entryId) else { return nil }
        return unsavedReasons[entryId] ?? lastSaveFailure ?? .writeFailed
    }

    /// Quit check: writes the queued snapshot and retries failed ones, then
    /// asks for confirmation only if something is still unsaved.
    func quitDecision() -> SaveQuitDecision {
        flushPendingSave()
        return SaveQuitDecision.decide(unsavedCount: unsavedEntryCount)
    }

    /// Applies a tag rename/delete to every snapshot still held in memory
    /// (queued or failed). Retries write the snapshot's tags, so without this
    /// a pending retry would bring the old tag back.
    func applyTagRewriteToUnsavedSnapshots(_ rewrite: SaveTagRewrite) {
        if var queued = pendingSave {
            queued.tags = rewrite.apply(to: queued.tags)
            pendingSave = queued
        }
        for id in Array(unsavedSnapshots.keys) {
            guard let tags = unsavedSnapshots[id]?.tags else { continue }
            let rewritten = rewrite.apply(to: tags)
            if rewritten != tags { unsavedSnapshots[id]?.tags = rewritten }
        }
        lastTagRewrite = rewrite
        tagRewriteGeneration &+= 1
    }

    /// `.failed(reason)` while anything is unsaved, else nil.
    var currentFailureState: SaveState? {
        unsavedSnapshots.isEmpty ? nil : .failed(lastSaveFailure ?? .writeFailed)
    }

    /// The single write path for autosave snapshots and retries.
    func writeEntrySnapshot(_ entry: JournalEntry) throws {
        // The seam replaces only the raw write; the post-write check below
        // always runs, so an injected writer exercises the same rules.
        if let override = saveWriterOverride {
            try override(entry)
        } else {
            try db.saveEntryChecked(entry)
        }
        // saveEntry keeps an undecryptable stored body (it refuses to replace
        // ciphertext it cannot read) yet commits the metadata — so the write
        // "succeeds" while the new text was not stored. Treat that as failed.
        if !entry.body.isEmpty, db.isEntryUnreadable(entry.id), db.existingBodyState(id: entry.id).unreadable {
            throw SQLiteError.message("stored text can't be decrypted")
        }
    }

    /// Writes one snapshot. Success clears any older failed snapshot of the
    /// same entry (this one supersedes it); failure keeps it.
    @discardableResult
    func attemptSnapshotWrite(_ snapshot: JournalEntry) -> Bool {
        do {
            try writeEntrySnapshot(snapshot)
            unsavedSnapshots[snapshot.id] = nil
            return true
        } catch {
            let reason = Self.saveFailureReason(for: error, db: db)
            unsavedSnapshots[snapshot.id] = snapshot
            unsavedReasons[snapshot.id] = reason
            lastSaveFailure = reason
            return false
        }
    }

    static func saveFailureReason(for error: Error, db: DatabaseManager) -> SaveFailureReason {
        if db.isReadOnly { return .readOnly }
        if error is JournalCrypto.KeyError { return .encryptionUnavailable }
        return SaveFailureReason.classify(error.localizedDescription)
    }

    /// Retries every failed snapshot. Only the editor-owned fields (title,
    /// body, mood, tags) are layered onto the CURRENT stored row, so pin /
    /// favorite / archive / hide / trash changes that landed after the failure
    /// are never reverted by an old snapshot. A snapshot whose entry no longer
    /// exists anywhere (purged) is dropped.
    func retryUnsavedSnapshots() {
        guard !unsavedSnapshots.isEmpty else { return }
        for id in unsavedSnapshots.keys.sorted() {
            guard let snapshot = unsavedSnapshots[id] else { continue }
            let merged: JournalEntry
            if let stored = db.fetchEntry(id: id) {
                merged = Self.overlayEditorFields(of: snapshot, onto: stored)
            } else if entry(id: id) != nil {
                merged = snapshot
            } else {
                unsavedSnapshots[id] = nil
                continue
            }
            attemptSnapshotWrite(merged)
        }
    }

    static func overlayEditorFields(of snapshot: JournalEntry, onto base: JournalEntry) -> JournalEntry {
        var merged = base
        merged.title = snapshot.title
        merged.body = snapshot.body
        merged.mood = snapshot.mood
        merged.tags = snapshot.tags
        merged.updatedAt = max(base.updatedAt, snapshot.updatedAt)
        return merged
    }

    /// After a reload from storage, put unsaved text back into the in-memory
    /// collections so the list, reader and a reopened editor still show it.
    func reapplyUnsavedSnapshots() {
        for (id, snapshot) in unsavedSnapshots {
            guard let current = entry(id: id) else { continue }
            updateEntry(Self.overlayEditorFields(of: snapshot, onto: current), refreshSearch: false)
        }
    }

    /// Settles the indicator after a write attempt: failed while anything is
    /// unsaved (toast once on entering failure), otherwise pending → saved.
    func updateSaveStateAfterWrite() {
        if let failed = currentFailureState {
            if !saveFailureAnnounced, let reason = failed.failureReason {
                saveFailureAnnounced = true
                showToast(SaveStatusPresentation.failureToast(reason), isError: true)
            }
            saveState = failed
        } else {
            saveFailureAnnounced = false
            if saveState == .pending || saveState.isFailed { saveState = .saved }
        }
    }

    /// Saves every capture queued by the menu-bar popover. The user's current
    /// edit session is flushed first and resumed afterwards.
    @discardableResult
    func drainQuickCaptureInbox() -> [JournalEntry] {
        let items = QuickCaptureInbox.drain()
        guard !items.isEmpty else { return [] }
        let resumeId = editingEntryId
        let resumeDraft = newDraftId
        let resumeZen = isZenMode
        flushPendingSave()
        // The open editor is resumed below, so the captures' createEntry must
        // not treat it as an abandoned blank draft and discard it.
        editingEntryId = nil
        var created: [JournalEntry] = []
        for item in items {
            guard let body = QuickCapture.normalized(item.body) else { continue }
            var entry = createEntry(body: body, tags: item.tags.isEmpty ? [QuickCapture.tag] : item.tags)
            if item.mood != entry.mood {
                entry.mood = item.mood
                db.saveEntry(entry)
                updateEntry(entry)
            }
            // createEntry opened an editor on the capture; close it without
            // touching the resumed entry's state.
            editingEntryId = nil
            created.append(entry)
        }
        saveState = currentFailureState ?? .idle
        refreshTagCounts()
        GoalManager.shared.loadGoals()
        if let resumeId, let previous = entry(id: resumeId), !previous.isTrashed {
            startEditing(previous)
            if resumeDraft == resumeId { newDraftId = resumeDraft }
            if resumeZen && editingEntryId == resumeId { isZenMode = true }
        } else if let last = created.last {
            selectedEntryId = last.id
        }
        if !created.isEmpty {
            showToast(created.count == 1 ? "Saved quick capture" : "Saved \(created.count) quick captures")
        }
        return created
    }

    /// Replaces an entry's body immediately (e.g. ticking a task in the reader).
    /// Flushes any pending autosave first so a stale snapshot can't overwrite it.
    func updateBody(_ body: String, for entry: JournalEntry) {
        flushBeforeImmediateMutation()
        var u = entry
        u.body = body
        u.updatedAt = Date()
        // The new body supersedes an older unsaved snapshot's body.
        unsavedSnapshots[u.id]?.body = body
        if db.saveEntry(u), unsavedSnapshots[u.id]?.title == u.title { unsavedSnapshots[u.id] = nil }
        updateSaveStateAfterWrite()
        updateEntry(u)
        refreshTagCounts()
    }

}
