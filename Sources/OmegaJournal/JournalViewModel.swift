import Foundation
import SwiftUI
import OmegaJournalCore

// MARK: - Journal View Model

@MainActor
final class JournalViewModel: ObservableObject {
    // Library
    @Published var entries: [JournalEntry] = []
    @Published var trashedEntries: [JournalEntry] = []
    @Published var archivedEntries: [JournalEntry] = []
    @Published var templates: [EntryTemplate] = []
    @Published var allTags: [(tag: String, count: Int)] = []

    // Selection & editing
    @Published var selectedEntryId: String?
    @Published var editingEntryId: String?

    // Search & filtering
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .dateDesc
    @Published var filter: EntryFilter = .empty

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
    private var undoStack: [UndoAction] = []

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
        reload()
        loadTemplates()
    }

    // MARK: - Loading

    func reload() {
        entries = db.fetchAllEntries(search: "", sort: sortOrder, scope: .active)
        trashedEntries = db.fetchAllEntries(sort: .dateDesc, scope: .trashed)
        archivedEntries = db.fetchAllEntries(sort: sortOrder, scope: .archived)
        allTags = db.tagsWithCounts()
        GoalManager.shared.loadGoals()
    }

    func loadTemplates() {
        templates = db.templates()
    }

    /// Re-runs whichever query matches the current search box contents.
    func refreshQuery() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            entries = db.fetchAllEntries(sort: sortOrder, scope: .active)
        } else {
            var results = db.fullTextSearch(q, scope: .active)
            if results.isEmpty {
                results = db.fetchAllEntries(search: q, sort: sortOrder, scope: .active)
            }
            entries = results
        }
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

    /// Targeted update — refresh a single entry in place without a full reload.
    private func updateEntry(_ entry: JournalEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        }
        sortInPlace()
    }

    private func sortInPlace() {
        let order = sortOrder
        entries.sort { a, b in
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

    var selectedEntry: JournalEntry? { entries.first { $0.id == selectedEntryId } }
    var editingEntry: JournalEntry? { entries.first { $0.id == editingEntryId } }
    var isEditing: Bool { editingEntryId != nil }
    var entryCount: Int { entries.count }

    /// Entries after the advanced filter is applied — what the list actually shows.
    var filteredEntries: [JournalEntry] {
        filter.isActive ? entries.filter(filter.matches) : entries
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
            buckets.append(("Pinned", -1, pinned))
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
        entry.tags = tags
        db.saveEntry(entry)
        entries.insert(entry, at: 0)
        sortInPlace()
        selectedEntryId = entry.id
        editingEntryId = entry.id
        allTags = db.tagsWithCounts()
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
        selectedEntryId = entry.id
        editingEntryId = entry.id
    }

    /// Duplicates an entry as a fresh draft.
    func duplicate(_ entry: JournalEntry) {
        createEntry(title: entry.title.isEmpty ? "" : "\(entry.title) (copy)", body: entry.body, tags: entry.tags)
        showToast("Duplicated entry")
    }

    // MARK: - Selection & editing

    func toggleSelection(_ entry: JournalEntry) {
        selectedEntryId = (selectedEntryId == entry.id) ? nil : entry.id
    }

    func select(_ entry: JournalEntry) { selectedEntryId = entry.id }

    func startEditing(_ entry: JournalEntry) {
        selectedEntryId = entry.id
        editingEntryId = entry.id
    }

    func stopEditing() {
        // Discard entries that were never given any content.
        if let e = editingEntry, e.title.isEmpty && e.body.isEmpty {
            db.hardDeleteEntry(id: e.id)
            entries.removeAll { $0.id == e.id }
            if selectedEntryId == e.id { selectedEntryId = nil }
        }
        editingEntryId = nil
        isZenMode = false
        allTags = db.tagsWithCounts()
        GoalManager.shared.loadGoals()
    }

    func autoSave(_ entry: JournalEntry) {
        // Update in-memory immediately so the UI stays responsive; persist on a debounce.
        var updated = entry
        updated.updatedAt = Date()
        if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
            entries[idx] = updated
        }
        saveDebounce?.cancel()
        saveDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.db.saveEntry(updated)
                self.allTags = self.db.tagsWithCounts()
                GoalManager.shared.loadGoals()
            }
        }
    }

    /// Forces any pending debounced save to disk right away.
    func flushPendingSave() {
        saveDebounce?.cancel()
        if let e = editingEntry { db.saveEntry(e) }
    }

    // MARK: - Entry mutations

    func togglePin(_ entry: JournalEntry) {
        var u = entry; u.isPinned.toggle(); u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
        showToast(u.isPinned ? "Pinned" : "Unpinned")
    }

    func toggleFavorite(_ entry: JournalEntry) {
        var u = entry; u.isFavorite.toggle(); u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
        showToast(u.isFavorite ? "Added to favorites" : "Removed from favorites")
    }

    func setMood(_ mood: Mood, for entry: JournalEntry) {
        var u = entry; u.mood = mood; u.updatedAt = Date()
        db.saveEntry(u)
        updateEntry(u)
    }

    // MARK: - Trash & archive

    /// Moves an entry to the trash (recoverable for 30 days).
    func deleteEntry(_ entry: JournalEntry) {
        db.trashEntry(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        archivedEntries.removeAll { $0.id == entry.id }
        if selectedEntryId == entry.id { selectedEntryId = nil }
        if editingEntryId == entry.id { editingEntryId = nil }
        trashedEntries = db.fetchAllEntries(sort: .dateDesc, scope: .trashed)
        undoStack.append(.restoreTrashed(ids: [entry.id]))
        showToast("Moved to Trash", actionLabel: "Undo")
        GoalManager.shared.loadGoals()
    }

    func restoreFromTrash(_ entry: JournalEntry) {
        db.restoreEntry(id: entry.id)
        trashedEntries.removeAll { $0.id == entry.id }
        reload()
        showToast("Restored “\(entry.displayTitle)”")
    }

    func deleteForever(_ entry: JournalEntry) {
        db.hardDeleteEntry(id: entry.id)
        trashedEntries.removeAll { $0.id == entry.id }
        showToast("Deleted permanently", isError: true)
    }

    func emptyTrash() {
        let count = trashedEntries.count
        db.emptyTrash()
        trashedEntries = []
        showToast("Emptied Trash (\(count) \(count == 1 ? "entry" : "entries"))", isError: true)
    }

    func toggleArchive(_ entry: JournalEntry) {
        let newValue = !entry.isArchived
        db.setArchived(id: entry.id, archived: newValue)
        if selectedEntryId == entry.id { selectedEntryId = nil }
        reload()
        if newValue { undoStack.append(.unarchive(ids: [entry.id])) }
        showToast(newValue ? "Archived" : "Unarchived", actionLabel: newValue ? "Undo" : nil)
    }

    // MARK: - Bulk actions

    func toggleBulkSelection(_ id: String) {
        if bulkSelection.contains(id) { bulkSelection.remove(id) } else { bulkSelection.insert(id) }
    }

    func clearBulkSelection() {
        bulkSelection.removeAll()
        isBulkSelecting = false
    }

    func bulkDelete() {
        let ids = Array(bulkSelection)
        guard !ids.isEmpty else { return }
        for id in ids { db.trashEntry(id: id) }
        entries.removeAll { ids.contains($0.id) }
        if let sel = selectedEntryId, ids.contains(sel) { selectedEntryId = nil }
        trashedEntries = db.fetchAllEntries(sort: .dateDesc, scope: .trashed)
        undoStack.append(.restoreTrashed(ids: ids))
        clearBulkSelection()
        showToast("Moved \(ids.count) entries to Trash", actionLabel: "Undo")
    }

    func bulkArchive() {
        let ids = Array(bulkSelection)
        guard !ids.isEmpty else { return }
        for id in ids { db.setArchived(id: id, archived: true) }
        undoStack.append(.unarchive(ids: ids))
        clearBulkSelection()
        reload()
        showToast("Archived \(ids.count) entries", actionLabel: "Undo")
    }

    func bulkFavorite() {
        let ids = bulkSelection
        guard !ids.isEmpty else { return }
        for id in ids {
            guard var e = entries.first(where: { $0.id == id }) else { continue }
            e.isFavorite = true
            db.saveEntry(e)
            updateEntry(e)
        }
        let n = ids.count
        clearBulkSelection()
        showToast("Favorited \(n) entries")
    }

    func bulkAddTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !bulkSelection.isEmpty else { return }
        let ids = bulkSelection
        for id in ids {
            guard var e = entries.first(where: { $0.id == id }), !e.tags.contains(trimmed) else { continue }
            e.tags.append(trimmed)
            e.updatedAt = Date()
            db.saveEntry(e)
            updateEntry(e)
        }
        let n = ids.count
        allTags = db.tagsWithCounts()
        clearBulkSelection()
        showToast("Tagged \(n) entries with #\(trimmed)")
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

    func performUndo() {
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .restoreTrashed(let ids):
            for id in ids { db.restoreEntry(id: id) }
            showToast("Restored \(ids.count) \(ids.count == 1 ? "entry" : "entries")")
        case .unarchive(let ids):
            for id in ids { db.setArchived(id: id, archived: false) }
            showToast("Unarchived \(ids.count) \(ids.count == 1 ? "entry" : "entries")")
        }
        reload()
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

    var writingStreak: Int {
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.createdAt) })
        guard !days.isEmpty else { return 0 }
        var streak = 0
        var date = cal.startOfDay(for: Date())
        // A streak is still "alive" if the user wrote yesterday but not yet today.
        if !days.contains(date) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: date), days.contains(yesterday) else { return 0 }
            date = yesterday
        }
        while days.contains(date) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        }
        return streak
    }

    var longestStreak: Int {
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.createdAt) })
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var best = 1, cur = 1
        for i in 1..<sorted.count {
            if let next = cal.date(byAdding: .day, value: 1, to: sorted[i - 1]), next == sorted[i] {
                cur += 1; best = max(best, cur)
            } else { cur = 1 }
        }
        return best
    }

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
        let cal = Calendar.current
        let today = Date()
        let month = cal.component(.month, from: today)
        let day = cal.component(.day, from: today)
        let thisYear = cal.component(.year, from: today)
        return entries.filter { e in
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

    /// Imports entries from a previously exported JSON file. Returns the number added.
    @discardableResult
    func importJSON(from url: URL) -> Int {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let export = try decoder.decode(ExportManager.JSONExport.self, from: data)
            let existing = Set(db.fetchAllEntries(scope: .all).map(\.id))
            var added = 0
            for je in export.entries where !existing.contains(je.id) {
                let entry = JournalEntry(
                    id: je.id, title: je.title, body: je.body,
                    mood: Mood(rawValue: je.mood) ?? .neutral,
                    tags: je.tags, createdAt: je.createdAt, updatedAt: je.updatedAt,
                    isPinned: je.isPinned, isFavorite: je.isFavorite,
                    isArchived: false, deletedAt: nil, attachments: []
                )
                db.saveEntry(entry)
                added += 1
            }
            reload()
            showToast(added == 0 ? "Nothing new to import" : "Imported \(added) entries")
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

    /// Imports a folder of markdown files, one entry per file.
    @discardableResult
    func importMarkdown(from urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let parsed = Self.parseMarkdownImport(
                text: text,
                fallbackTitle: url.deletingPathExtension().lastPathComponent
            )
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            var entry = JournalEntry.new()
            entry.title = parsed.title
            entry.body = parsed.body
            entry.tags = ["imported"]
            entry.createdAt = created
            entry.updatedAt = created
            db.saveEntry(entry)
            added += 1
        }
        reload()
        showToast(added == 0 ? "No markdown files imported" : "Imported \(added) markdown files")
        return added
    }
}
