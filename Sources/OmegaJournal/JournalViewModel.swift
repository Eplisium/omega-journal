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
    var moodCounts: [Mood: Int] = [:]
    @Published var trashedEntries: [JournalEntry] = []
    @Published var archivedEntries: [JournalEntry] = []
    @Published var hiddenEntries: [JournalEntry] = []
    @Published var templates: [EntryTemplate] = []
    @Published var allTags: [(tag: String, count: Int)] = []
    /// Search results are intentionally separate from the active-library snapshot so
    /// Calendar, sidebar counts, goals, and Insights never become search-dependent.
    @Published var searchResults: [JournalEntry]?

    // Selection & editing
    @Published var selectedEntryId: String?
    @Published var editingEntryId: String?

    // Search & filtering
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .dateDesc
    @Published var filter: EntryFilter = .empty
    /// Named search + tag/mood filter combinations (stored as JSON in settings).
    @Published var savedSearches: [SavedSearch] = []

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
    var searchDebounce: Task<Void, Never>?
    var saveDebounce: Task<Void, Never>?
    /// Editor save indicator: `.pending` while a debounced autosave is queued.
    enum SaveState: Equatable { case idle, pending, saved }
    @Published var saveState: SaveState = .idle
    var undoStack: [UndoAction] = []
    /// Undo history is bounded: an unbounded stack of id arrays only grows.
    static let maxUndoDepth = 50
    var cancellables: Set<AnyCancellable> = []

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

    static func matchesVisibleFields(_ entry: JournalEntry, query: String) -> Bool {
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

    static func matchesSearchableFields(_ entry: JournalEntry, query: String) -> Bool {
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

    func sortInPlace() {
        sort(&entries)
        if var results = searchResults {
            sort(&results)
            searchResults = results
        }
    }

    func sort(_ collection: inout [JournalEntry]) {
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
    var writingDaysCache: (key: [Double], days: Set<Date>)?

    var writingDays: Set<Date> {
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

}
