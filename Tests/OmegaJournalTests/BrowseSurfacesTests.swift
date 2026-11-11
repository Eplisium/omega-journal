import AppKit
import Foundation
import PDFKit
import SwiftUI
import Testing
import OmegaJournalCore
@testable import OmegaJournal

/// Regression tests for the browse-track audit fixes (Browse / Settings /
/// Today). Every DB test uses a private UUID temp database; the env vars keep
/// any `.shared` singleton off the real journal.
@MainActor
enum BrowseSupport {
    static func makeVM() throws -> (JournalViewModel, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oj-fix-browse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        TestSharedEnvironment.pin()
        let db = DatabaseManager(databasePath: root.appendingPathComponent("private.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("private-att").path)
        return (JournalViewModel(database: db), root)
    }

    static func entry(title: String = "T", body: String = "", hidden: Bool = false,
                      archived: Bool = false, trashed: Bool = false, createdAt: Date = Date()) -> JournalEntry {
        var e = JournalEntry.new()
        e.title = title
        e.body = body
        e.isHidden = hidden
        e.isArchived = archived
        e.deletedAt = trashed ? Date() : nil
        e.createdAt = createdAt
        return e
    }

    static func calendar(_ tz: String = "America/New_York") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
}

// MARK: - browse-4

@Suite("Browse: Today hero word count")
@MainActor
struct BrowseTodayHeroTests {
    @Test("the hero card never shows a locked hidden entry's word count")
    func heroMasksWordCount() {
        let words = Array(repeating: "secret", count: 1_240).joined(separator: " ")
        let hidden = BrowseSupport.entry(title: "Private", body: words, hidden: true)
        let locked = TodayHeroContent(entry: hidden, hiddenLocked: true)
        #expect(locked.isMasked)
        #expect(locked.wordCountText == nil, "locked hidden entry leaks its length: \(locked.wordCountText ?? "")")
        let unlocked = TodayHeroContent(entry: hidden, hiddenLocked: false)
        #expect(unlocked.wordCountText == "\(1_240.formatted()) words")
        let one = TodayHeroContent(entry: BrowseSupport.entry(body: "hello"), hiddenLocked: true)
        #expect(one.wordCountText == "1 word")
    }
}

// MARK: - browse-5

@Suite("Browse: toasts are hosted at the window level", .serialized)
@MainActor
struct BrowseToastHostTests {
    @Test("the detail pane no longer hosts its own toast (it would show twice)")
    func detailViewHasNoToast() throws {
        let (vm, _) = try BrowseSupport.makeVM()
        var selection: SidebarItem? = .all
        let detail = DetailView(vm: vm, selection: Binding(get: { selection }, set: { selection = $0 }))
        let typeName = String(describing: type(of: detail.body))
        #expect(!typeName.contains("ToastView"))
        #expect(!typeName.contains("WindowToastHost"))
    }

    @Test("the window and the Settings sheet both host the toast")
    func windowAndSettingsHostToast() throws {
        let (vm, _) = try BrowseSupport.makeVM()
        let content = ContentView(viewModel: vm)
        #expect(String(describing: type(of: content.body)).contains("WindowToastHost"))
        let settings = SettingsView(vm: vm)
        #expect(String(describing: type(of: settings.body)).contains("WindowToastHost"))
    }

    @Test("only the frontmost host for a window draws the toast")
    func frontmostHostOnly() {
        let stack = ToastHostStack()
        let windowVM = NSObject(), otherWindowVM = NSObject()
        let window = UUID(), settings = UUID(), other = UUID()
        stack.push(window, owner: ObjectIdentifier(windowVM))
        stack.push(other, owner: ObjectIdentifier(otherWindowVM))
        #expect(stack.isFrontmost(window, owner: ObjectIdentifier(windowVM)))
        // Settings sheet opens over the window: it takes over, nothing twice.
        stack.push(settings, owner: ObjectIdentifier(windowVM))
        #expect(stack.isFrontmost(settings, owner: ObjectIdentifier(windowVM)))
        #expect(!stack.isFrontmost(window, owner: ObjectIdentifier(windowVM)))
        // Another window's own host is unaffected.
        #expect(stack.isFrontmost(other, owner: ObjectIdentifier(otherWindowVM)))
        // Sheet closes: the window host draws again.
        stack.remove(settings, owner: ObjectIdentifier(windowVM))
        #expect(stack.isFrontmost(window, owner: ObjectIdentifier(windowVM)))
        stack.remove(window, owner: ObjectIdentifier(windowVM))
        #expect(!stack.isFrontmost(window, owner: ObjectIdentifier(windowVM)))
    }

    @Test("dismissing a toast with an action runs Undo")
    func undoStaysWired() throws {
        let (vm, _) = try BrowseSupport.makeVM()
        let e = vm.createEntry(title: "BRF undo", body: "x")
        vm.stopEditing()
        vm.deleteEntry(e)
        let toast = try #require(vm.toast)
        #expect(toast.actionLabel == "Undo")
        WindowToastHost.handleAction(toast, vm: vm)
        #expect(vm.db.fetchEntry(id: e.id)?.isTrashed == false)
        #expect(vm.toast?.id != toast.id)
    }
}

// MARK: - browse-6

@Suite("Browse: reading exports skip Trash", .serialized)
@MainActor
struct BrowseExportTests {
    @Test("single-file Markdown and PDF exports leave trashed entries out")
    func markdownAndPDFSkipTrash() throws {
        let (vm, root) = try BrowseSupport.makeVM()
        _ = vm.createEntry(title: "BRF kept", body: "keptbodyword")
        vm.stopEditing()
        let gone = vm.createEntry(title: "BRF deleted", body: "deletedsecretbody")
        vm.stopEditing()
        vm.deleteEntry(gone)
        let all = ImportExportPanels.fullExportEntries(vm: vm)
        // Backups (JSON / encrypted) still carry the trash.
        #expect(all.contains { $0.id == gone.id })

        let md = root.appendingPathComponent("export.md")
        try ImportExportPanels.writeMarkdownExport(all, to: md)
        let text = try String(contentsOf: md, encoding: .utf8)
        #expect(text.contains("keptbodyword"))
        #expect(!text.contains("deletedsecretbody"), "a trashed entry was written into the Markdown export")

        let pdf = root.appendingPathComponent("export.pdf")
        try ImportExportPanels.writePDFExport(all, to: pdf)
        let pdfText = PDFDocument(url: pdf)?.string ?? ""
        #expect(pdfText.contains("keptbodyword"))
        #expect(!pdfText.contains("deletedsecretbody"), "a trashed entry was printed into the PDF export")

        #expect(ImportExportPanels.readingExportEntries(all).allSatisfy { !$0.isTrashed })
    }
}

// MARK: - browse-7

@Suite("Browse: Save this search", .serialized)
@MainActor
struct BrowseSaveSearchTests {
    private func reset(_ vm: JournalViewModel) {
        vm.filter = .empty
        vm.searchText = ""
    }

    @Test("every facet the smart folder supports is saved")
    func savesFullFilter() throws {
        let (vm, _) = try BrowseSupport.makeVM()
        defer { reset(vm) }
        vm.searchText = "  garden  "
        vm.filter.tags = ["brtag", "alpha"]
        vm.filter.moods = [.good, .bad]
        vm.filter.dateRange = .last7
        vm.filter.minWords = 50
        vm.filter.withAttachmentsOnly = true
        let outcome = vm.saveSearchAsSmartFolder(name: "BR Recent")
        guard case .saved(let saved) = outcome else { Issue.record("not saved: \(outcome)"); return }
        vm.loadOrganizationState()
        let folder = try #require(vm.smartFolders.first { $0.name == "BR Recent" })
        #expect(folder.id == saved.id)
        #expect(folder.query == "garden")
        #expect(folder.tags == ["alpha", "brtag"])
        #expect(folder.moods == [Mood.bad.rawValue, Mood.good.rawValue].sorted())
        #expect(folder.dateRange == .last7)
        #expect(folder.minWords == 50)
        #expect(folder.hasAttachment)
        #expect(vm.toast?.isError == false)
    }

    @Test("a filter smart folders can't express is named in a toast, never silently dropped")
    func unsupportedFacets() throws {
        let (vm, _) = try BrowseSupport.makeVM()
        defer { reset(vm) }
        // Favorites only: nothing a smart folder can hold.
        vm.filter.favoritesOnly = true
        #expect(vm.filter.isActive)
        #expect(vm.saveSearchAsSmartFolder(name: "BR Faves") == .nothingSaved)
        #expect(!vm.smartFolders.contains { $0.name == "BR Faves" })
        let toast = try #require(vm.toast)
        #expect(toast.isError && toast.message.contains("Favorites"))

        // Favorites + Pinned + a tag: the tag is saved, the rest is reported.
        vm.filter.pinnedOnly = true
        vm.filter.tags = ["brtag"]
        guard case .saved = vm.saveSearchAsSmartFolder(name: "BR Tagged") else { Issue.record("not saved"); return }
        #expect(vm.smartFolders.first { $0.name == "BR Tagged" }?.tags == ["brtag"])
        let partial = try #require(vm.toast)
        #expect(partial.message.contains("Favorites") && partial.message.contains("Pinned"))

        // Nothing at all.
        reset(vm)
        #expect(vm.saveSearchAsSmartFolder(name: "BR Empty") == .nothingSaved)
        #expect(vm.toast?.isError == true)
    }

    @Test("saving over an existing smart folder's name asks first, then keeps its id and pin")
    func overwriteNeedsConfirmation() throws {
        let (vm, _) = try BrowseSupport.makeVM()
        defer { reset(vm) }
        var original = SmartFolder(name: "Work log", tags: ["work"], minWords: 100)
        original.isPinned = true
        #expect(vm.saveSmartFolder(original))
        vm.searchText = "standup"
        let outcome = vm.saveSearchAsSmartFolder(name: "work LOG")
        #expect(outcome == .needsReplaceConfirmation(existing: try #require(vm.smartFolder(id: original.id))))
        // Nothing changed yet.
        #expect(vm.smartFolder(id: original.id)?.tags == ["work"])
        #expect(vm.smartFolders.count == 1)

        guard case .saved(let replaced) = vm.saveSearchAsSmartFolder(name: "work LOG", replacingExisting: true) else {
            Issue.record("replace failed"); return
        }
        #expect(replaced.id == original.id)
        #expect(vm.smartFolders.count == 1)
        let stored = try #require(vm.smartFolder(id: original.id))
        #expect(stored.query == "standup" && stored.tags.isEmpty && stored.minWords == 0)
        #expect(stored.isPinned, "replacing a folder dropped its pin")
    }
}

// MARK: - browse-8 (palette half)

@Suite("Browse: palette entry commands follow the lifecycle")
@MainActor
struct BrowsePaletteTests {
    typealias A = CommandPaletteView.EntryAction

    @Test("library, archived and trashed selections get their own commands")
    func actionsByLifecycle() {
        let library = BrowseSupport.entry()
        #expect(CommandPaletteView.entryActions(for: library) == [.edit, .togglePin, .toggleFavorite, .duplicate, .archive, .moveToTrash])
        let archived = BrowseSupport.entry(archived: true)
        let archivedActions = CommandPaletteView.entryActions(for: archived)
        #expect(archivedActions.contains(.unarchive) && !archivedActions.contains(.archive))
        #expect(A.unarchive.title(for: archived) == "Unarchive Entry")
        let trashed = BrowseSupport.entry(archived: true, trashed: true)
        #expect(CommandPaletteView.entryActions(for: trashed) == [.restore, .deleteForever])
        #expect(A.restore.title(for: trashed) == "Restore from Trash")
        #expect(A.deleteForever.title(for: trashed) == "Delete Forever")
    }
}

// MARK: - browse-11

@Suite("Browse: Today rolls over")
@MainActor
struct BrowseTodayRolloverTests {
    let cal = BrowseSupport.calendar()

    @Test("the Today schedule ticks at midnight and at every greeting change")
    func boundaries() {
        let d = { BrowseSupport.date(2026, 11, $0, $1, $2, cal: cal) }
        #expect(TodayRolloverSchedule.nextBoundary(after: d(5, 23, 58), calendar: cal) == d(6, 0, 0))
        #expect(TodayRolloverSchedule.nextBoundary(after: d(6, 0, 0), calendar: cal) == d(6, 5, 0))
        #expect(TodayRolloverSchedule.nextBoundary(after: d(6, 6, 30), calendar: cal) == d(6, 12, 0))
        #expect(TodayRolloverSchedule.nextBoundary(after: d(6, 12, 0), calendar: cal) == d(6, 17, 0))
        #expect(TodayRolloverSchedule.nextBoundary(after: d(6, 21, 59), calendar: cal) == d(6, 22, 0))
        let ticks = Array(TodayRolloverSchedule(calendar: cal).entries(from: d(5, 23, 58), mode: .normal).prefix(4))
        #expect(ticks == [d(5, 23, 58), d(6, 0, 0), d(6, 5, 0), d(6, 12, 0)])
    }

    @Test("a skipped midnight (DST) still rolls the day over")
    func dstMidnight() {
        let sp = BrowseSupport.calendar("America/Sao_Paulo")
        // 2018-11-04 00:00 did not exist in São Paulo (clocks jumped to 01:00).
        let before = BrowseSupport.date(2018, 11, 3, 23, 30, cal: sp)
        let next = TodayRolloverSchedule.nextBoundary(after: before, calendar: sp)
        #expect(next > before)
        #expect(!sp.isDate(next, inSameDayAs: before))
    }

    @Test("greeting, date and today's entry follow the clock, not the first render")
    func followsTheClock() {
        let late = BrowseSupport.date(2026, 11, 5, 23, 58, cal: cal)
        let morning = BrowseSupport.date(2026, 11, 6, 8, 0, cal: cal)
        #expect(TodayView.greeting(at: late, calendar: cal) == "Still awake?")
        #expect(TodayView.greeting(at: morning, calendar: cal) == "Good morning")
        let yesterday = BrowseSupport.entry(title: "late night", createdAt: late.addingTimeInterval(-60))
        #expect(TodayView.todaysEntry(in: [yesterday], now: late, calendar: cal)?.id == yesterday.id)
        #expect(TodayView.todaysEntry(in: [yesterday], now: morning, calendar: cal) == nil)
    }

    @Test("the Today page is driven by the rollover schedule")
    func todayUsesTimeline() throws {
        let (vm, _) = try BrowseSupport.makeVM()
        let view = TodayView(vm: vm, openJournal: {}, openCalendar: {}, openInsights: {}, openEntry: { _ in })
        #expect(String(describing: type(of: view.body)).contains("TodayRolloverSchedule"))
    }
}

// MARK: - Settings Danger Zone (browse-1 wording)

@Suite("Browse: Empty Trash wording names the notebook scope")
struct BrowseEmptyTrashCopyTests {
    @Test("all notebooks vs one notebook")
    func scopeWording() {
        #expect(EmptyTrashCopy.cardSubtitle(count: 1, notebookName: nil) == "Permanently delete 1 entry and its attachments.")
        #expect(EmptyTrashCopy.cardSubtitle(count: 3, notebookName: nil) == "Permanently delete 3 entries and their attachments.")
        let scoped = EmptyTrashCopy.cardSubtitle(count: 2, notebookName: "Work")
        #expect(scoped.contains("“Work”") && scoped.contains("Other notebooks"))
        #expect(EmptyTrashCopy.dialogMessage(notebookName: nil).contains("every entry currently in Trash"))
        let message = EmptyTrashCopy.dialogMessage(notebookName: "Work")
        #expect(message.contains("“Work”") && message.contains("other notebooks"))
    }
}
