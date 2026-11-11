import AppIntents
import Foundation
import OmegaJournalCore

// MARK: - Entities for Siri, Shortcuts and Apple Intelligence
//
// Entries, notebooks and tags as `AppEntity` types. Every query goes through
// `IntentJournalBridge`, which only answers while the journal window is open
// (the launch gate has adopted the encryption key) and the whole-app lock is
// off, and filters with `IntentEntryCatalog` (see the privacy rules there).
//
// Keep display strings literal: the packaging scripts read them from the
// compiler's const-value output.

/// Thrown when a query or intent needs the journal but it isn't open/unlocked.
nonisolated enum JournalIntentError: Error, CustomLocalizedStringResourceConvertible {
    case journalNotOpen
    case entryNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .journalNotOpen: "Open Omega Journal and unlock it first."
        case .entryNotFound: "That entry isn't available."
        }
    }
}

// MARK: Entry

struct JournalEntryEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Journal Entry", numericFormat: "\(placeholder: .int) journal entries")
    static let defaultQuery = JournalEntryQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Date")
    var date: Date

    @Property(title: "Mood")
    var mood: JournalMoodOption

    /// Always empty for hidden entries.
    @Property(title: "Tags")
    var tags: [String]

    init(id: String, title: String, date: Date, mood: JournalMoodOption, tags: [String]) {
        self.id = id
        self.title = title
        self.date = date
        self.mood = mood
        self.tags = tags
    }

    init(_ s: IntentEntrySummary) {
        self.init(id: s.id, title: s.displayTitle, date: s.date,
                  mood: JournalMoodOption(rawMood: s.mood), tags: s.isHidden ? [] : s.tags)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(date.formatted(date: .abbreviated, time: .omitted))",
            image: .init(systemName: "book.pages"))
    }
}

extension JournalMoodOption {
    nonisolated init(rawMood: Int) {
        switch rawMood {
        case ...1: self = .awful
        case 2: self = .bad
        case 4: self = .good
        case 5...: self = .great
        default: self = .neutral
        }
    }
}

struct JournalEntryQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [JournalEntryEntity] {
        let snap = try await IntentJournalBridge.snapshot()
        return IntentEntryCatalog.entries(ids: identifiers, in: snap.records, hiddenLocked: snap.hiddenLocked, appLocked: false)
            .map(JournalEntryEntity.init)
    }

    func entities(matching string: String) async throws -> [JournalEntryEntity] {
        let snap = try await IntentJournalBridge.snapshot()
        return IntentEntryCatalog.titleMatches(string, in: snap.records, hiddenLocked: snap.hiddenLocked, appLocked: false)
            .map(JournalEntryEntity.init)
    }

    func suggestedEntities() async throws -> [JournalEntryEntity] {
        // Suggestions are shown without the user asking, so hidden entries
        // stay out of them even while unlocked.
        let snap = try await IntentJournalBridge.snapshot()
        return IntentEntryCatalog.visible(snap.records, hiddenLocked: true, appLocked: false)
            .prefix(12).map { JournalEntryEntity(IntentEntryCatalog.summary($0)) }
    }
}

// MARK: Notebook

struct NotebookEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Notebook"
    static let defaultQuery = NotebookQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "book.closed"))
    }
}

struct NotebookQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NotebookEntity] {
        let all = try await IntentJournalBridge.notebooks()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [NotebookEntity] {
        let q = string.trimmingCharacters(in: .whitespaces).lowercased()
        let all = try await IntentJournalBridge.notebooks()
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
    }

    func suggestedEntities() async throws -> [NotebookEntity] {
        try await IntentJournalBridge.notebooks()
    }
}

// MARK: Tag

struct TagEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tag"
    static let defaultQuery = TagQuery()

    /// The tag itself, without `#`.
    let id: String

    @Property(title: "Entries")
    var entryCount: Int

    init(id: String, entryCount: Int) {
        self.id = id
        self.entryCount = entryCount
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "#\(id)", image: .init(systemName: "number"))
    }
}

struct TagQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TagEntity] {
        let all = try await IntentJournalBridge.tags()
        return identifiers.compactMap { id in all.first { $0.id == IntentEntryCatalog.normalizedTag(id) } }
    }

    func entities(matching string: String) async throws -> [TagEntity] {
        let q = IntentEntryCatalog.normalizedTag(string)
        let all = try await IntentJournalBridge.tags()
        return q.isEmpty ? all : all.filter { $0.id.contains(q) }
    }

    func suggestedEntities() async throws -> [TagEntity] {
        Array(try await IntentJournalBridge.tags().prefix(30))
    }
}

// MARK: - Bridge to the open journal

/// What the entity queries read. Registered by `AppCommandHandling` when the
/// journal window appears (so the database is open and the key adopted).
@MainActor
protocol IntentJournalSource: AnyObject {
    /// Every stored entry as a privacy-trimmed record (hidden: no body, no tags).
    func intentEntryRecords() -> [IntentEntryRecord]
    func intentNotebooks() -> [(id: String, name: String)]
    var intentHiddenLocked: Bool { get }
    var intentAppLocked: Bool { get }
}

@MainActor
enum IntentJournalBridge {
    private static weak var source: (any IntentJournalSource)?

    static func attach(_ s: any IntentJournalSource) { source = s }
    static func detach() { source = nil }
    static var isAttached: Bool { source != nil }

    struct Snapshot {
        let records: [IntentEntryRecord]
        let hiddenLocked: Bool
    }

    /// Records the caller may filter; throws while the journal is closed or app-locked.
    static func snapshot() throws -> Snapshot {
        guard let s = source, !s.intentAppLocked else { throw JournalIntentError.journalNotOpen }
        return Snapshot(records: s.intentEntryRecords(), hiddenLocked: s.intentHiddenLocked)
    }

    static func notebooks() throws -> [NotebookEntity] {
        guard let s = source, !s.intentAppLocked else { throw JournalIntentError.journalNotOpen }
        return s.intentNotebooks().map { NotebookEntity(id: $0.id, name: $0.name) }
    }

    static func tags() throws -> [TagEntity] {
        let snap = try snapshot()
        return IntentEntryCatalog.tags(in: snap.records, hiddenLocked: snap.hiddenLocked, appLocked: false)
            .map { TagEntity(id: $0.name, entryCount: $0.count) }
    }
}

extension JournalViewModel: IntentJournalSource {
    func intentEntryRecords() -> [IntentEntryRecord] {
        db.fetchAllEntriesForExport().map { e in
            IntentEntryRecord(id: e.id, title: e.title,
                              searchText: e.isHidden ? "" : EntryStampCodec.split(e.body).rest,
                              createdAt: e.createdAt, mood: e.mood.rawValue, moodName: e.mood.label.lowercased(),
                              tags: e.isHidden ? [] : e.tags, journalId: e.journalId,
                              isHidden: e.isHidden, isTrashed: e.isTrashed, isArchived: e.isArchived)
        }
    }

    func intentNotebooks() -> [(id: String, name: String)] {
        db.fetchJournals().map { ($0.id, $0.name) }
    }

    var intentHiddenLocked: Bool { !BiometricAuth.shared.isAuthenticated }

    var intentAppLocked: Bool {
        let lock = AppLockManager.shared
        return lock.isEnabled && lock.isLocked
    }
}
