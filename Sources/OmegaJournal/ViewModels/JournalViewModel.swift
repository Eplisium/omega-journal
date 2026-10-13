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
    /// Notebooks. `activeJournalId == nil` means "All journals".
    @Published var journals: [Journal] = []
    @Published var activeJournalId: String?
    @Published var tagColors: [String: String] = [:]
    @Published var smartFolders: [SmartFolder] = []
    @Published var smartFolderCounts: [String: Int] = [:]
    @Published var recentSearches: [String] = []
    @Published var journalCounts: [String: Int] = [:]
    @Published var tagTree: [TagNode] = []

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

    let db: DatabaseManager
    var searchDebounce: Task<Void, Never>?
    var saveDebounce: Task<Void, Never>?
    /// The exact snapshot `saveDebounce` will persist. Flushing writes THIS —
    /// not whatever `editingEntry` happens to be by then — so switching,
    /// creating, trashing or reloading can never drop or misdirect an edit.
    var pendingSave: JournalEntry?
    /// Editor save indicator: `.pending` while a debounced autosave is queued,
    /// `.failed(reason)` while any snapshot in `unsavedSnapshots` is unsaved.
    typealias SaveState = SaveStatus
    @Published var saveState: SaveState = .idle
    /// Snapshots whose write failed, by entry id. They are never dropped on
    /// failure: each flush, the next edit, and the explicit Retry action try
    /// them again, and `reload()` re-applies them so stale storage cannot
    /// replace text the user typed.
    var unsavedSnapshots: [String: JournalEntry] = [:]
    /// Reason for the most recent failed snapshot write.
    var lastSaveFailure: SaveFailureReason?
    /// The failure toast is shown once per failure episode, not per retry.
    var saveFailureAnnounced = false
    /// Test seam: replaces the database write used for autosave snapshots and
    /// retries. Throwing simulates a failed write without corrupting a DB.
    var saveWriterOverride: ((JournalEntry) throws -> Void)?
    var undoStack: [UndoAction] = []
    /// Undo history is bounded: an unbounded stack of id arrays only grows.
    static let maxUndoDepth = 50
    var cancellables: Set<AnyCancellable> = []
    /// Distinct writing days, cached against a cheap fingerprint so keystroke-driven
    /// `entries` updates don't redo calendar math (see `writingDays`).
    var writingDaysCache: (key: [Double], days: Set<Date>)?

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
                self.refreshTagCounts()
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
        // A queued autosave must land before rows are re-read, or the reload
        // would replace the edit in memory with stale storage. Only the
        // pending snapshot is written, never other in-memory state.
        persistPendingSnapshot()
        // One shared attachments/tags scan for all four scopes (was 8 full-table
        // scans per reload) plus the single tagsWithCounts query below.
        let scopes = db.fetchScopes([
            (.active, sortOrder),
            (.trashed, .dateDesc),
            (.archived, sortOrder),
            (.hidden, .dateDesc),
        ], journalId: activeJournalId)
        entries = scopes[.active] ?? []
        trashedEntries = scopes[.trashed] ?? []
        archivedEntries = scopes[.archived] ?? []
        hiddenEntries = scopes[.hidden] ?? []
        reapplyUnsavedSnapshots()
        // While the biometric session is locked, hidden entries must not
        // advertise their tags in the sidebar/filter chips.
        allTags = db.tagsWithCounts(includeHidden: BiometricAuth.shared.isAuthenticated, journalId: activeJournalId)
        refreshOrganization()
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
        allTags = db.tagsWithCounts(includeHidden: BiometricAuth.shared.isAuthenticated, journalId: activeJournalId)
        refreshOrganization()
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
        let parsed = SearchQuery.parse(q)
        if parsed.hasOperators {
            // Operator queries (tag:/mood:/before:/after:/has:) run over the decrypted in-memory set.
            searchResults = operatorMatches(parsed, in: entries)
            return
        }
        let fts = db.fullTextSearch(q, scope: .active, journalId: activeJournalId).filter { entry in
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
        let parsed = SearchQuery.parse(query)
        if parsed.hasOperators { return operatorMatches(parsed, in: source) }
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
            await MainActor.run { self?.refreshQuery(); if let q = self?.searchText, q.count >= 3 { self?.recordRecentSearch(q) } }
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

    // MARK: - Creating entries

    @discardableResult
    func createEntry(title: String = "", body: String = "", tags: [String] = [],
                     journalId: String? = nil, isHidden: Bool = false) -> JournalEntry {
        flushPendingSave()
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
        flushPendingSave()
        if let e = editingEntry {
            if e.title.isEmpty && e.body.isEmpty && unsavedSnapshots[e.id] == nil {
                // Discard entries that were never given any content.
                db.hardDeleteEntry(id: e.id)
                entries.removeAll { $0.id == e.id }
                searchResults?.removeAll { $0.id == e.id }
                archivedEntries.removeAll { $0.id == e.id }
                trashedEntries.removeAll { $0.id == e.id }
                hiddenEntries.removeAll { $0.id == e.id }
                if selectedEntryId == e.id { selectedEntryId = nil }
            }
        }
        editingEntryId = nil
        // A failed save stays visible (and retryable) after the editor closes.
        saveState = currentFailureState ?? .idle
        isZenMode = false
        refreshTagCounts()
        GoalManager.shared.loadGoals()
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
        return ok
    }

    // MARK: Save failure handling

    /// `.failed(reason)` while anything is unsaved, else nil.
    var currentFailureState: SaveState? {
        unsavedSnapshots.isEmpty ? nil : .failed(lastSaveFailure ?? .writeFailed)
    }

    /// The single write path for autosave snapshots and retries.
    func writeEntrySnapshot(_ entry: JournalEntry) throws {
        if let override = saveWriterOverride {
            try override(entry)
            return
        }
        try db.saveEntryChecked(entry)
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
            unsavedSnapshots[snapshot.id] = snapshot
            lastSaveFailure = Self.saveFailureReason(for: error, db: db)
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
        flushPendingSave()
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
