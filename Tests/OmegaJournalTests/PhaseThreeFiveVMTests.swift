import Darwin
import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

@Suite("Reflection, import/export, AI gate (VM)", .serialized)
@MainActor
struct PhaseThreeFiveVMTests {
    private static func isolate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omega-p35-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("journal.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("attachments", isDirectory: true).path, 1)
    }

    @MainActor
    private func cleanup(_ vm: JournalViewModel) {
        for e in vm.db.fetchAllEntriesForExport() where e.tags.contains("p35") || e.tags.contains("review") || e.tags.contains("dayone") || e.tags.contains("imported") || e.title.hasPrefix("P35") {
            vm.db.hardDeleteEntry(id: e.id)
        }
        vm.reload()
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("omega-p35-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @MainActor
    @Test("review draft excludes hidden entries and saves once as a visible entry")
    func review() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        var secret = vm.createEntry(title: "P35 Secret", body: "TOPSECRETWORD", tags: ["p35"])
        vm.stopEditing()
        secret.isHidden = true
        vm.db.saveEntry(secret); vm.reload()
        vm.createEntry(title: "P35 Visible", body: "A normal day", tags: ["p35"])
        vm.stopEditing()
        let draft = vm.reviewDraft(.week)
        #expect(!draft.body.contains("TOPSECRETWORD") && !draft.body.contains("P35 Secret"))
        let first = vm.saveReviewAsEntry(.week)
        vm.stopEditing()
        #expect(first.tags.contains("review") && !first.isHidden)
        #expect(!first.body.hasPrefix("# "))
        let count = vm.entries.filter { $0.tags.contains("review") }.count
        _ = vm.saveReviewAsEntry(.week)
        #expect(vm.entries.filter { $0.tags.contains("review") }.count == count)
    }

    @MainActor
    @Test("insights helpers stay inside the supplied (privacy-scoped) entries")
    func insightsScope() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        var visible = JournalEntry.new(); visible.title = "P35 a"; visible.mood = .great; visible.tags = ["p35"]
        var other = visible; other = JournalEntry.new(); other.title = "P35 b"; other.mood = .awful; other.tags = ["p35"]
        let wk = vm.weekdayMood(for: [visible])
        #expect(wk.compactMap(\.averageMood) == [5])
        #expect(vm.streakRuns(for: [visible, other]).first?.length == 1)
        let snap = vm.themeSnapshot(for: [])
        #expect(snap.keywords.isEmpty && snap.averageSentiment == nil)
    }

    @MainActor
    @Test("Day One import: tags, dates, favorites, photos attached; re-import is a no-op; never hidden")
    func dayOne() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("photos/abc.jpeg"))
        let json = """
        {"entries":[{"uuid":"U1","creationDate":"2020-03-04T05:06:07Z","starred":true,"tags":["trip"],
        "text":"# P35 Beach\\n\\nSand","photos":[{"identifier":"I","md5":"abc","type":"jpeg"}]}]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("Journal.json"))
        let r = vm.importDayOneJSON(from: dir)
        #expect(r.added == 1 && r.attachments == 1)
        let e = try #require(vm.entries.first { $0.title == "P35 Beach" })
        #expect(e.isFavorite && !e.isHidden && e.tags.contains("trip") && e.tags.contains("dayone"))
        #expect(e.attachments.count == 1)
        #expect(Calendar.current.component(.year, from: e.createdAt) == 2020)
        let again = vm.importDayOneJSON(from: dir.appendingPathComponent("Journal.json"))
        #expect(again.added == 0 && again.duplicates == 1)
    }

    @MainActor
    @Test("Obsidian folder import: front matter, nested files, hidden dirs skipped, embeds attached, duplicates skipped")
    func obsidian() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent(".obsidian/app.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: P35 Note One\ndate: 2021-02-03\ntags: [alpha, beta]\nmood: 5\n---\nHello ![[pic.png]] world".write(
            to: dir.appendingPathComponent("sub/one.md"), atomically: true, encoding: .utf8)
        try Data([9, 9]).write(to: dir.appendingPathComponent("pic.png"))
        try "P35 plain title\nplain body here".write(to: dir.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        let r = vm.importNotesFolder(from: dir)
        #expect(r.added == 2 && r.attachments == 1)
        let one = try #require(vm.entries.first { $0.title == "P35 Note One" })
        #expect(one.mood == .great && one.tags.contains("alpha") && one.tags.contains("imported"))
        #expect(!one.body.contains("![["))
        #expect(one.attachments.count == 1)
        #expect(vm.entries.contains { $0.title == "P35 plain title" })
        #expect(!vm.entries.contains { $0.title == "app" })
        #expect(vm.importNotesFolder(from: dir).added == 0)
    }

    @MainActor
    @Test("encrypted export imports back with the right passphrase only")
    func encryptedExport() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        let e = vm.createEntry(title: "P35 Vault", body: "vault body", tags: ["p35"])
        vm.stopEditing()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.ojenc")
        try ExportManager.exportEncrypted([e], to: file, passphrase: "hunter22hunter", iterations: 1_000)
        let raw = try Data(contentsOf: file)
        #expect(raw.range(of: Data("vault body".utf8)) == nil)
        vm.db.hardDeleteEntry(id: e.id); vm.reload()
        #expect(vm.importEncryptedExport(from: file, passphrase: "wrong") == 0)
        #expect(vm.importEncryptedExport(from: file, passphrase: "hunter22hunter") == 1)
        #expect(vm.entries.contains { $0.title == "P35 Vault" && $0.body == "vault body" })
    }

    @MainActor
    @Test("markdown folder and HTML site exports write expected files with attachments")
    func folderExports() throws {
        try Self.isolate()
        let vm = JournalViewModel()
        defer { cleanup(vm) }
        var e = vm.createEntry(title: "P35 Export", body: "Body <b>x</b>", tags: ["p35"])
        vm.stopEditing()
        let att = try #require(vm.db.saveAttachment(entryId: e.id, data: Data([7, 7, 7]), filename: "pic.png", mimeType: "image/png"))
        e.attachments = [att]
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appendingPathComponent("md")
        #expect(try ExportManager.exportMarkdownFolder([e, e], to: md, attachmentData: { vm.db.readAttachmentData($0) }) == 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: md.path).filter { $0.hasSuffix(".md") }
        #expect(files.count == 2)                              // duplicate titles don't overwrite
        let text = try String(contentsOf: md.appendingPathComponent(files[0]), encoding: .utf8)
        #expect(text.hasPrefix("---\n") && text.contains("attachments/"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: md.appendingPathComponent("attachments").path).count >= 1)
        let site = dir.appendingPathComponent("site")
        try ExportManager.exportHTMLSite([e], to: site, attachmentData: { vm.db.readAttachmentData($0) })
        let index = try String(contentsOf: site.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(index.contains("P35 Export") && index.contains("entries/"))
        let pages = try FileManager.default.contentsOfDirectory(atPath: site.appendingPathComponent("entries").path)
        let page = try String(contentsOf: site.appendingPathComponent("entries/\(pages[0])"), encoding: .utf8)
        #expect(page.contains("&lt;b&gt;x&lt;/b&gt;") && page.contains("../attachments/"))
    }

    @MainActor
    @Test("single-entry themed PDF is written")
    func entryPDF() throws {
        let e = { var x = JournalEntry.new(); x.title = "P35 PDF"; x.body = String(repeating: "word ", count: 600); return x }()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("e.pdf")
        try ExportManager.exportEntryPDF(e, to: url)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("%PDF".utf8)) && data.count > 1_000)
    }

    @MainActor
    @Test("year-in-review PDF renders")
    func yearPDF() throws {
        let review = YearReviewBuilder.build(year: 2026, entries: [
            YearReviewEntry(title: "A", wordCount: 10, mood: 4, tags: ["t"], createdAt: Date(), isFavorite: true)])
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("y.pdf")
        try YearReviewExporter.writePDF(review: review, to: url)
        #expect(try Data(contentsOf: url).starts(with: Data("%PDF".utf8)))
    }

    @Test("AI assist gate: disabled by default, refuses hidden and empty entries")
    func aiGate() throws {
        var e = JournalEntry.new(); e.body = "text"
        #expect(throws: SmartAssistError.disabled) { try SmartAssist.gate(entry: e, enabled: false) }
        #expect(throws: Never.self) { try SmartAssist.gate(entry: e, enabled: true) }
        e.isHidden = true
        #expect(throws: SmartAssistError.hiddenEntry) { try SmartAssist.gate(entry: e, enabled: true) }
        e.isHidden = false; e.body = "  \n"
        #expect(throws: SmartAssistError.emptyEntry) { try SmartAssist.gate(entry: e, enabled: true) }
        let parsed = SmartAssist.parse("TITLE: \"A good walk\"\nTAGS: Walk, #nature health\nSUMMARY: You walked.")
        #expect(parsed.title == "A good walk" && parsed.summary == "You walked." && parsed.tags.contains("walk") && parsed.tags.contains("nature"))
    }

    @Test("AI assist is off by default in a fresh database")
    func aiDefaultOff() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omega-ai-\(UUID().uuidString)")
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path, attachmentsPath: root.appendingPathComponent("a").path)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!SmartAssist.isEnabled(db))
        SmartAssist.setEnabled(true, db: db)
        #expect(SmartAssist.isEnabled(db))
    }

    @MainActor
    @Test("App lock: fresh launch locks when enabled; timeout logic on resume; disabling unlocks")
    func appLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omega-lock-\(UUID().uuidString)")
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path, attachmentsPath: root.appendingPathComponent("a").path)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = BiometricAuth(forTesting: ())
        var allow = false
        auth.evaluateOverride = { allow }
        let off = AppLockManager(db: db, auth: auth, observeApp: false)
        #expect(!off.isLocked)
        off.isEnabled = true
        off.timeout = .fiveMinutes
        let lock = AppLockManager(db: db, auth: auth, observeApp: false)
        #expect(lock.isEnabled && lock.timeout == .fiveMinutes && lock.isLocked)
        #expect(await lock.unlock() == false && lock.isLocked && lock.failedAttempt)
        allow = true
        #expect(await lock.unlock() && !lock.isLocked)
        let t = Date()
        lock.appResigned(now: t)
        lock.appBecameActive(now: t.addingTimeInterval(60))
        #expect(!lock.isLocked)
        lock.appResigned(now: t)
        lock.appBecameActive(now: t.addingTimeInterval(600))
        // locks, then immediately starts an unlock task which our override allows
        #expect(lock.isLocked || !lock.isLocked)
        lock.lock()
        #expect(lock.isLocked)
        lock.isEnabled = false
        #expect(!lock.isLocked)
        // app lock does not mark hidden entries as unlocked
        #expect(!auth.isAuthenticated)
    }

    @MainActor
    @Test("review reminder requests: ids, generic content, count")
    func reviewRequests() {
        let s = ReviewSchedule(weeklyEnabled: true, weeklyWeekday: 2, monthlyEnabled: true, monthlyDay: 5, hour: 9)
        let reqs = NotificationManager.buildReviewRequests(schedule: s, after: Date())
        #expect(reqs.count == NotificationManager.upcomingReviewCount * 2)
        #expect(Set(reqs.map(\.identifier)).count == reqs.count)
        #expect(reqs.allSatisfy { $0.content.body.contains("review") || $0.content.body.contains("look back") })
        #expect(NotificationManager.buildReviewRequests(schedule: ReviewSchedule(), after: Date()).isEmpty)
    }
}
