import AppKit
import SwiftUI
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

// Regression tests for the 2026-11-05 editor/reader audit (track "editor").
// Every DB-backed test uses its own `DatabaseManager(databasePath:attachmentsPath:)`
// in a UUID temp dir, after pointing the process-wide test env at a throwaway
// dir so no singleton can open the real journal.

@MainActor
private func makeIsolatedVM() -> (JournalViewModel, URL) {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-fix-editor-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    TestSharedEnvironment.pin()
    let db = DatabaseManager(databasePath: dir.appendingPathComponent("db.sqlite3").path,
                             attachmentsPath: dir.appendingPathComponent("att").path)
    return (JournalViewModel(database: db), dir)
}

@MainActor
private func settle(_ window: NSWindow, _ hosting: NSView, rounds: Int = 4) {
    for _ in 0..<rounds {
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

@MainActor
private func bodyTextViews(in view: NSView) -> [NSTextView] {
    var out: [NSTextView] = []
    if let s = view as? NSScrollView, let t = s.documentView as? NSTextView { out.append(t) }
    for sub in view.subviews { out += bodyTextViews(in: sub) }
    return out
}

@MainActor
private func editableTextFields(in view: NSView) -> [NSTextField] {
    var out: [NSTextField] = []
    if let f = view as? NSTextField, f.isEditable { out.append(f) }
    for sub in view.subviews { out += editableTextFields(in: sub) }
    return out
}

@MainActor
private func hostWindow<V: View>(_ root: V, width: CGFloat = 900, height: CGFloat = 600) -> (NSWindow, NSView) {
    let hosting = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = hosting
    settle(window, hosting)
    return (window, hosting)
}

// MARK: - editor-1 / editor-7: hosted editor focus and undo

@MainActor
@Suite("Editor: Format menu focus and undo", .serialized)
struct EditorBehaviorHostedTests {

    // editor-1
    @Test("a Format-menu command while the Title field has focus leaves the body alone")
    func formatCommandWhileTitleFocused() throws {
        let (vm, _) = makeIsolatedVM()
        let entry = vm.createEntry(title: "", body: "hello")
        defer { vm.stopEditing(); vm.editorMode = .write; vm.db.hardDeleteEntry(id: entry.id) }
        vm.editorMode = .write
        let (window, hosting) = hostWindow(EditorView(vm: vm, entry: entry))
        defer { window.contentView = nil }
        let body = try #require(bodyTextViews(in: hosting).first)
        let title = try #require(editableTextFields(in: hosting).first { $0.placeholderString == "Title" })
        window.makeFirstResponder(title)
        settle(window, hosting)
        #expect(window.firstResponder !== body, "title should own focus")
        NotificationCenter.default.post(name: .formatCommand, object: MarkdownCommand.bold)
        NotificationCenter.default.post(name: .formatCommand, object: MarkdownCommand.heading1)
        settle(window, hosting)
        #expect(body.string == "hello", "body edited while typing in the title: \(body.string.debugDescription)")
        vm.flushPendingSave()
        #expect(vm.db.fetchEntry(id: entry.id)?.body == "hello")
    }

    // editor-1 (control: the guard must not block the normal case)
    @Test("a Format-menu command applies when the body text view has focus")
    func formatCommandWhileBodyFocused() throws {
        let (vm, _) = makeIsolatedVM()
        let entry = vm.createEntry(title: "Focused", body: "hello")
        defer { vm.stopEditing(); vm.editorMode = .write; vm.db.hardDeleteEntry(id: entry.id) }
        vm.editorMode = .write
        let (window, hosting) = hostWindow(EditorView(vm: vm, entry: entry))
        defer { window.contentView = nil }
        let body = try #require(bodyTextViews(in: hosting).first)
        window.makeFirstResponder(body)
        body.setSelectedRange(NSRange(location: 0, length: 0))
        settle(window, hosting)
        NotificationCenter.default.post(name: .formatCommand, object: MarkdownCommand.heading1)
        settle(window, hosting)
        #expect(body.string == "# hello")
    }

    // editor-1 (pure policy)
    @Test("menu-command focus policy: body or no text focus accepts; another text input refuses")
    func menuCommandPolicy() {
        let body = NSTextView()
        let fieldEditor = NSTextView()
        #expect(MarkdownEditorController.menuCommandTargetsBody(focused: nil, body: body))
        #expect(MarkdownEditorController.menuCommandTargetsBody(focused: body, body: body))
        #expect(MarkdownEditorController.menuCommandTargetsBody(focused: NSView(), body: body))
        #expect(!MarkdownEditorController.menuCommandTargetsBody(focused: fieldEditor, body: body))
        #expect(!MarkdownEditorController.menuCommandTargetsBody(focused: NSTextField(), body: body))
    }

    // editor-7
    private struct DetailLikeHost: View {
        var vm: JournalViewModel
        var body: some View {
            if let entry = vm.editingEntry {
                EditorView(vm: vm, entry: entry).id(entry.id)   // same keying as DetailView / zenEditor
            }
        }
    }

    @Test("⌘Z after switching entries does not offer the previous editor's typing")
    func undoAfterRealEntrySwitch() throws {
        let (vm, _) = makeIsolatedVM()
        vm.editorMode = .write
        let a = vm.createEntry(title: "A", body: "alpha")
        let b = vm.createEntry(title: "B", body: "bravo")
        defer { vm.stopEditing(); vm.db.hardDeleteEntry(id: a.id); vm.db.hardDeleteEntry(id: b.id) }
        vm.startEditing(try #require(vm.entry(id: a.id)))
        let (window, hosting) = hostWindow(DetailLikeHost(vm: vm))
        defer { window.contentView = nil }
        let tvA = try #require(bodyTextViews(in: hosting).first)
        window.makeFirstResponder(tvA)
        tvA.setSelectedRange(NSRange(location: (tvA.string as NSString).length, length: 0))
        tvA.insertText(" typed", replacementRange: tvA.selectedRange())
        settle(window, hosting)
        #expect(tvA.undoManager?.canUndo == true, "typing in A is undoable while A is open")
        vm.flushPendingSave()
        #expect(vm.db.fetchEntry(id: a.id)?.body == "alpha typed")

        vm.startEditing(try #require(vm.entry(id: b.id)))
        settle(window, hosting)
        let tvB = try #require(bodyTextViews(in: hosting).first)
        #expect(tvB !== tvA)
        window.makeFirstResponder(tvB)
        settle(window, hosting)
        let canUndo = tvB.undoManager?.canUndo ?? false
        let name = tvB.undoManager?.undoActionName ?? "-"
        if canUndo { tvB.undoManager?.undo() }
        settle(window, hosting)
        #expect(!canUndo, "Edit ▸ Undo \(name) is offered in B for typing done in A")
        #expect(tvB.string == "bravo")
        vm.flushPendingSave()
        #expect(vm.db.fetchEntry(id: a.id)?.body == "alpha typed")
        #expect(vm.db.fetchEntry(id: b.id)?.body == "bravo")
    }

    @Observable final class SwitchModel {
        var key = "A"
        var textA = "entry one"
        var textB = "entry two"
    }

    private struct SwitchHost: View {
        @Bindable var model: SwitchModel
        let controller = MarkdownEditorController()
        var body: some View {
            if model.key == "A" {
                MarkdownTextEditor(text: $model.textA, font: .systemFont(ofSize: 14), controller: controller).id("A")
            } else {
                MarkdownTextEditor(text: $model.textB, font: .systemFont(ofSize: 14), controller: controller).id("B")
            }
        }
    }

    @Test("a torn-down text view leaves nothing on the shared window undo stack")
    func undoAfterTextViewTeardown() throws {
        _ = NSApplication.shared
        let model = SwitchModel()
        let (window, hosting) = hostWindow(SwitchHost(model: model), width: 600, height: 400)
        defer { window.contentView = nil }
        let a = try #require(bodyTextViews(in: hosting).first)
        window.makeFirstResponder(a)
        a.setSelectedRange(NSRange(location: (a.string as NSString).length, length: 0))
        a.insertText(" typed in A", replacementRange: a.selectedRange())
        settle(window, hosting)
        #expect(model.textA == "entry one typed in A")
        #expect(window.undoManager?.canUndo == true)
        model.key = "B"
        settle(window, hosting)
        let b = try #require(bodyTextViews(in: hosting).first)
        #expect(b !== a)
        window.makeFirstResponder(b)
        settle(window, hosting)
        let canUndoInB = b.undoManager?.canUndo ?? false
        if canUndoInB { b.undoManager?.undo() }
        settle(window, hosting)
        #expect(!canUndoInB, "the new editor offers to undo typing from a destroyed one")
        #expect(b.string == "entry two")
        #expect(model.textB == "entry two")
        // Typing in B is still undoable as usual.
        b.insertText("!", replacementRange: NSRange(location: (b.string as NSString).length, length: 0))
        settle(window, hosting)
        #expect(b.undoManager?.canUndo == true)
    }

    // editor-5 (shiftLines selection math, through the real Tab handler)
    private final class TextBox { var text: String; init(_ t: String) { text = t } }

    private struct PlainEditorHost: View {
        @Binding var text: String
        let controller = MarkdownEditorController()
        var body: some View {
            MarkdownTextEditor(text: $text, font: .systemFont(ofSize: 14), controller: controller)
        }
    }

    @Test("Tab on a multi-line CRLF selection indents every line and keeps the line break out of the selection")
    func tabIndentsCRLFBlock() throws {
        _ = NSApplication.shared
        let box = TextBox("- a\r\n\r\n- b\r\nrest")
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let (window, hosting) = hostWindow(PlainEditorHost(text: binding), width: 600, height: 400)
        defer { window.contentView = nil }
        let tv = try #require(bodyTextViews(in: hosting).first)
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: 9))   // "- a\r\n\r\n- b"
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        settle(window, hosting)
        #expect(tv.string == "  - a\r\n\r\n  - b\r\nrest", "got \(tv.string.debugDescription)")
        let selected = (tv.string as NSString).substring(with: tv.selectedRange())
        #expect(selected == "  - a\r\n\r\n  - b", "selection \(selected.debugDescription)")
    }
}

// MARK: - editor-2 / editor-3 / editor-4: attachments

@MainActor
@Suite("Editor: attachments", .serialized)
struct EditorBehaviorAttachmentTests {

    // editor-2 / vm-9
    @Test("attaching to / removing from an archived entry updates the entry the reader and editor show")
    func archivedAttachmentsStayCurrent() throws {
        let (vm, _) = makeIsolatedVM()
        let created = vm.createEntry(title: "Archived", body: "x")
        defer { vm.db.hardDeleteEntry(id: created.id) }
        vm.stopEditing()
        vm.toggleArchive(try #require(vm.entry(id: created.id)))
        let archived = try #require(vm.entry(id: created.id))
        #expect(archived.isArchived)
        let saved = vm.addAttachment(to: archived, data: Data("hi".utf8), filename: "note.txt", mimeType: "text/plain")
        #expect(saved != nil)
        #expect(vm.db.fetchEntry(id: created.id)?.attachments.count == 1, "stored")
        #expect(vm.entry(id: created.id)?.attachments.count == 1, "archived reader/editor still shows 0 attachments")
        // Removal straight after (no reload in between).
        let att = try #require(vm.entry(id: created.id)?.attachments.first)
        vm.deleteAttachment(att)
        #expect(vm.db.fetchEntry(id: created.id)?.attachments.isEmpty == true, "removed from storage")
        #expect(vm.entry(id: created.id)?.attachments.isEmpty == true, "archived reader still lists the removed attachment")
    }

    // editor-2 / vm-9: every collection holding the entry
    @Test("hidden-list and search-result copies of the entry get the attachment too")
    func hiddenAndSearchCopiesStayCurrent() throws {
        let (vm, _) = makeIsolatedVM()
        let created = vm.createEntry(title: "Zebracorn attachment probe", body: "x")
        defer {
            vm.searchText = ""
            vm.refreshQuery()
            vm.db.hardDeleteEntry(id: created.id)
        }
        vm.stopEditing()
        vm.db.setHidden(id: created.id, hidden: true)
        vm.reload()
        vm.searchText = "Zebracorn"
        vm.refreshQuery()
        #expect(vm.hiddenEntries.contains { $0.id == created.id })
        #expect(vm.searchResults?.contains { $0.id == created.id } == true)
        let entry = try #require(vm.entry(id: created.id))
        let saved = try #require(vm.addAttachment(to: entry, data: Data("hi".utf8), filename: "a.txt", mimeType: "text/plain"))
        #expect(vm.entries.first { $0.id == created.id }?.attachments.map(\.id) == [saved.id])
        #expect(vm.hiddenEntries.first { $0.id == created.id }?.attachments.map(\.id) == [saved.id])
        #expect(vm.searchResults?.first { $0.id == created.id }?.attachments.map(\.id) == [saved.id])
        vm.deleteAttachment(saved)
        #expect(vm.hiddenEntries.first { $0.id == created.id }?.attachments.isEmpty == true)
        #expect(vm.searchResults?.first { $0.id == created.id }?.attachments.isEmpty == true)
    }

    // editor-3
    @Test("the inserted image reference uses the stored (sanitized) filename, so it resolves")
    func imageRefUsesStoredName() throws {
        let (vm, _) = makeIsolatedVM()
        let created = vm.createEntry(title: "Img", body: "")
        defer { vm.stopEditing(); vm.db.hardDeleteEntry(id: created.id) }
        // Finder shows "Notes 10/11.png"; the POSIX name (url.lastPathComponent) is "Notes 10:11.png".
        let saved = vm.addAttachment(to: created, data: Data([0x89, 0x50, 0x4E, 0x47]),
                                     filename: " Notes 10:11.png ", mimeType: "image/png")
        let stored = try #require(vm.entry(id: created.id)?.attachments.first)
        #expect(saved?.id == stored.id)
        #expect(stored.filename == "Notes 1011.png")
        let inserted = try #require(EditorView.inlineImageMarkdown(for: saved))
        let ref = try #require(ImageRefs.refs(in: inserted).first)
        let resolved = vm.entry(id: created.id)?.attachments.first { $0.filename == ref.filename && $0.isImage }
        #expect(resolved?.id == stored.id, "ref '\(ref.filename)' must match stored '\(stored.filename)'")
        // Non-images never get an inline reference.
        let file = vm.addAttachment(to: created, data: Data("x".utf8), filename: "notes.txt", mimeType: "text/plain")
        #expect(file != nil)
        #expect(EditorView.inlineImageMarkdown(for: file) == nil)
    }

    // editor-3: a failed save inserts nothing
    @Test("a failed attachment save returns nil, so no dangling image reference is inserted")
    func failedSaveInsertsNoReference() throws {
        let (vm, dir) = makeIsolatedVM()
        let created = vm.createEntry(title: "Fail", body: "")
        let attDir = dir.appendingPathComponent("att")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: attDir.path)
            vm.stopEditing(); vm.db.hardDeleteEntry(id: created.id)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: attDir.path)
        let saved = vm.addAttachment(to: created, data: Data([0x89, 0x50, 0x4E, 0x47]), filename: "x.png", mimeType: "image/png")
        #expect(saved == nil)
        #expect(EditorView.inlineImageMarkdown(for: saved) == nil)
        #expect(vm.entry(id: created.id)?.attachments.isEmpty == true)
    }

    // editor-4
    @Test("two images with the same name are stored under unique names and each ref shows its own picture")
    func duplicateFilenamesAreUniquePerEntry() throws {
        let (vm, _) = makeIsolatedVM()
        let e = vm.createEntry(title: "Two shots", body: "")
        let other = vm.createEntry(title: "Elsewhere", body: "")
        defer { vm.stopEditing(); vm.db.hardDeleteEntry(id: e.id); vm.db.hardDeleteEntry(id: other.id) }
        let first = try #require(vm.addAttachment(to: e, data: Data([0x89, 0x50, 0x4E, 0x47, 1]), filename: "image.png", mimeType: "image/png"))
        let second = try #require(vm.addAttachment(to: e, data: Data([0x89, 0x50, 0x4E, 0x47, 2]), filename: "image.png", mimeType: "image/png"))
        let third = try #require(vm.addAttachment(to: e, data: Data([0x89, 0x50, 0x4E, 0x47, 3]), filename: "image.png", mimeType: "image/png"))
        #expect(first.filename == "image.png")
        #expect(second.filename == "image 2.png")
        #expect(third.filename == "image 3.png")
        // Another entry's "image.png" is unaffected (names are unique per entry).
        let elsewhere = try #require(vm.addAttachment(to: other, data: Data([0x89, 0x50, 0x4E, 0x47, 4]), filename: "image.png", mimeType: "image/png"))
        #expect(elsewhere.filename == "image.png")
        let atts = try #require(vm.entry(id: e.id)?.attachments)
        #expect(atts.count == 3)
        let body = [first, second, third].compactMap { EditorView.inlineImageMarkdown(for: $0) }.joined(separator: "\n")
        // MarkdownBodyView's resolution rule, verbatim.
        let resolved = ImageRefs.refs(in: body).map { ref in atts.first { $0.filename == ref.filename && $0.isImage }?.id }
        #expect(resolved == [first.id, second.id, third.id])
        // An old ref keyed by the original name still resolves (to the first image).
        let legacy = ImageRefs.refs(in: ImageRefs.markdown(alt: "", filename: "image.png")).first
        #expect(atts.first { $0.filename == legacy?.filename && $0.isImage }?.id == first.id)
        // The stored bytes really belong to each name.
        #expect(vm.db.readAttachmentData(second) == Data([0x89, 0x50, 0x4E, 0x47, 2]))
    }

    @Test("unique attachment names: Finder-style numbering before the extension")
    func uniqueNameHelper() {
        #expect(DatabaseManager.uniqueAttachmentFilename("image.png", existing: []) == "image.png")
        #expect(DatabaseManager.uniqueAttachmentFilename("image.png", existing: ["image.png"]) == "image 2.png")
        #expect(DatabaseManager.uniqueAttachmentFilename("image.png", existing: ["image.png", "image 2.png"]) == "image 3.png")
        #expect(DatabaseManager.uniqueAttachmentFilename("notes", existing: ["notes"]) == "notes 2")
        #expect(DatabaseManager.uniqueAttachmentFilename("a.tar.gz", existing: ["a.tar.gz"]) == "a.tar 2.gz")
        #expect(DatabaseManager.uniqueAttachmentFilename(".env", existing: [".env"]) == ".env 2")
    }
}

// MARK: - editor-5 / 6 / 8 / 9 / 10: markdown logic

@MainActor
@Suite("Editor: markdown commands")
struct EditorBehaviorMarkdownTests {

    private func textView(_ s: String, selection: NSRange) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tv.string = s
        tv.setSelectedRange(selection)
        return tv
    }

    private func selectedText(_ tv: NSTextView) -> String {
        (tv.string as NSString).substring(with: tv.selectedRange())
    }

    // editor-5
    @Test("line-prefix commands on a CRLF line touch only that line, and toggle off cleanly")
    func crlfLinePrefix() {
        #expect(OmegaCore.applyLinePrefix("# ", to: "a\r\n") == "# a\r\n")
        #expect(OmegaCore.applyLinePrefix("- ", to: "- a\r\n- b\r\n") == "a\r\nb\r\n")
        let tv = textView("a\r\nb\r\nc", selection: NSRange(location: 0, length: 0))
        tv.applyMarkdownCommand(.heading1)
        #expect(tv.string == "# a\r\nb\r\nc")
        let tv2 = textView("- x\r\ny", selection: NSRange(location: 0, length: 0))
        tv2.applyMarkdownCommand(.bulletList)   // toggle OFF the existing bullet
        #expect(tv2.string == "x\r\ny")
    }

    // editor-5
    @Test("Toggle Task on a CRLF line keeps the next line and leaves the line break unselected")
    func crlfToggleTask() {
        let tv = textView("- [ ] a\r\nnext", selection: NSRange(location: 0, length: 0))
        tv.applyMarkdownCommand(.toggleTask)
        #expect(tv.string == "- [x] a\r\nnext")
        #expect(selectedText(tv) == "- [x] a")
    }

    // editor-5
    @Test("shiftBlock treats a blank CRLF line like a blank LF line")
    func crlfShiftBlock() {
        #expect(MarkdownLogic.shiftBlock("- a\r\n\r\n- b\r\n", outdenting: false) == "  - a\r\n\r\n  - b\r\n")
        #expect(MarkdownLogic.shiftBlock("  - a\r\n  - b\r\n", outdenting: true) == "- a\r\n- b\r\n")
        // LF behaviour unchanged.
        #expect(MarkdownLogic.shiftBlock("- a\n\n- b\n", outdenting: false) == "  - a\n\n  - b\n")
    }

    @Test("block line split: CRLF and LF trailing breaks are measured in UTF-16")
    func blockLineSplit() {
        let crlf = MarkdownLogic.splitBlockLines("a\r\nb\r\n")
        #expect(crlf.lines == ["a\r", "b\r"])
        #expect(crlf.trailingBreakLength == 2)
        let lf = MarkdownLogic.splitBlockLines("a\nb\n")
        #expect(lf.lines == ["a", "b"])
        #expect(lf.trailingBreakLength == 1)
        let none = MarkdownLogic.splitBlockLines("a\nb")
        #expect(none.lines == ["a", "b"])
        #expect(none.trailingBreakLength == 0)
    }

    // editor-6
    @Test("reader outline and line count work for CRLF bodies")
    func outlineCRLF() {
        let body = "# One\r\ntext\r\n## Two\r\nmore\r\n## Three\r\n"
        let headings = MarkdownOutline.headings(in: body)
        #expect(headings.map(\.title) == ["One", "Two", "Three"])
        #expect(headings.map(\.line) == [0, 2, 4])
        #expect(headings.map(\.level) == [1, 2, 2])
        #expect(MarkdownOutline.lineCount(in: body) == 6)
        #expect(MarkdownOutline.lineCount(in: "a\nb") == 2)
        #expect(MarkdownOutline.lineCount(in: "") == 1)
        // Same answers for the LF version of the body.
        let lf = body.replacingOccurrences(of: "\r\n", with: "\n")
        #expect(MarkdownOutline.headings(in: lf) == headings)
    }

    // editor-8
    @Test("⌘I on a selected **bold** span makes it bold-italic, not plain italic")
    func italicOnBold() {
        let tv = textView("a **word** b", selection: NSRange(location: 2, length: 8))
        tv.applyMarkdownCommand(.italic)
        #expect(tv.string == "a ***word*** b")
        tv.applyMarkdownCommand(.italic)   // and back
        #expect(tv.string == "a **word** b")
    }

    // editor-8
    @Test("⌘B on a double-click-selected bold word un-bolds it and keeps the word selected")
    func boldToggleWithMarkersOutside() {
        let tv = textView("a **word** b", selection: NSRange(location: 4, length: 4))
        tv.applyMarkdownCommand(.bold)
        #expect(tv.string == "a word b")
        #expect(selectedText(tv) == "word")
        tv.applyMarkdownCommand(.bold)     // and bold again
        #expect(tv.string == "a **word** b")
    }

    // editor-8
    @Test("star parity: bold vs italic on combined ***runs***, markers inside or outside the selection")
    func starParity() {
        // Inside the selection.
        var tv = textView("***w***", selection: NSRange(location: 0, length: 7))
        tv.applyMarkdownCommand(.italic)
        #expect(tv.string == "**w**")
        tv = textView("***w***", selection: NSRange(location: 0, length: 7))
        tv.applyMarkdownCommand(.bold)
        #expect(tv.string == "*w*")
        tv = textView("*w*", selection: NSRange(location: 0, length: 3))
        tv.applyMarkdownCommand(.bold)
        #expect(tv.string == "***w***")
        // Outside the selection.
        tv = textView("a *word* b", selection: NSRange(location: 3, length: 4))
        tv.applyMarkdownCommand(.italic)
        #expect(tv.string == "a word b")
        tv = textView("a *word* b", selection: NSRange(location: 3, length: 4))
        tv.applyMarkdownCommand(.bold)
        #expect(tv.string == "a ***word*** b")
        #expect(selectedText(tv) == "word")
        tv = textView("a ***word*** b", selection: NSRange(location: 5, length: 4))
        tv.applyMarkdownCommand(.bold)
        #expect(tv.string == "a *word* b")
        tv = textView("a **word** b", selection: NSRange(location: 4, length: 4))
        tv.applyMarkdownCommand(.italic)
        #expect(tv.string == "a ***word*** b")
    }

    // editor-8: the other inline styles and the plain cases keep working
    @Test("plain wrap/unwrap, empty selections and code/strike markers outside the selection")
    func wrapRegressions() {
        var tv = textView("hello", selection: NSRange(location: 0, length: 5))
        tv.applyMarkdownCommand(.bold)
        #expect(tv.string == "**hello**")
        #expect(selectedText(tv) == "**hello**")
        tv.applyMarkdownCommand(.bold)
        #expect(tv.string == "hello")
        tv = textView("ab", selection: NSRange(location: 1, length: 0))
        tv.applyMarkdownCommand(.bold)
        #expect(tv.string == "a****b")
        #expect(tv.selectedRange() == NSRange(location: 3, length: 0))
        tv.applyMarkdownCommand(.bold)     // empty markers toggle back off
        #expect(tv.string == "ab")
        #expect(tv.selectedRange() == NSRange(location: 1, length: 0))
        tv = textView("a ~~word~~ b", selection: NSRange(location: 4, length: 4))
        tv.applyMarkdownCommand(.strikethrough)
        #expect(tv.string == "a word b")
        #expect(selectedText(tv) == "word")
        tv = textView("a `code` b", selection: NSRange(location: 3, length: 4))
        tv.applyMarkdownCommand(.code)
        #expect(tv.string == "a code b")
        tv = textView("a `code` b", selection: NSRange(location: 2, length: 6))
        tv.applyMarkdownCommand(.code)
        #expect(tv.string == "a code b")
        tv = textView("x", selection: NSRange(location: 0, length: 1))
        tv.applyMarkdownCommand(.code)
        #expect(tv.string == "`x`")
        // A bullet "* " is not an italic marker.
        tv = textView("* item", selection: NSRange(location: 2, length: 4))
        tv.applyMarkdownCommand(.italic)
        #expect(tv.string == "* *item*")
    }

    // editor-9
    @Test("list/heading prefix skips blank separator lines and still toggles off")
    func linePrefixBlankLines() {
        #expect(OmegaCore.applyLinePrefix("- ", to: "a\n\nb\n") == "- a\n\n- b\n")
        #expect(OmegaCore.applyLinePrefix("- ", to: "- a\n\n- b\n") == "a\n\nb\n")
        #expect(OmegaCore.applyLinePrefix("# ", to: "a\r\n\r\nb\r\n") == "# a\r\n\r\n# b\r\n")
        #expect(OmegaCore.applyLinePrefix("- ", to: "a\n   \nb") == "- a\n   \n- b")
        // A lone empty line still gets the prefix (caret on an empty line).
        #expect(OmegaCore.applyLinePrefix("# ", to: "") == "# ")
        #expect(OmegaCore.applyLinePrefix("# ", to: "\n") == "# \n")
    }

    // editor-10
    @Test("typing ( right before an emoji types a plain ( like before any other character")
    func autoPairBeforeEmoji() {
        let sel = NSRange(location: 0, length: 0)
        #expect(MarkdownLogic.autoPairEdit(typed: "(", in: "a", selection: sel) == nil)
        #expect(MarkdownLogic.autoPairEdit(typed: "(", in: "漢", selection: sel) == nil)
        #expect(MarkdownLogic.autoPairEdit(typed: "(", in: "😀", selection: sel) == nil)
        #expect(MarkdownLogic.autoPairEdit(typed: "[", in: "👩‍💻 x", selection: sel) == nil)
        // Still pairs before blanks/closers and at the end of the text, also after an emoji.
        #expect(MarkdownLogic.autoPairEdit(typed: "(", in: "😀", selection: NSRange(location: 2, length: 0)) != nil)
        #expect(MarkdownLogic.autoPairEdit(typed: "(", in: "😀 x", selection: NSRange(location: 2, length: 0)) != nil)
        #expect(MarkdownLogic.autoPairEdit(typed: "`", in: "😀", selection: NSRange(location: 2, length: 0)) != nil)
        // Never after a backtick (so ``` fences type normally).
        #expect(MarkdownLogic.autoPairEdit(typed: "`", in: "`", selection: NSRange(location: 1, length: 0)) == nil)
    }
}

// MARK: - browse-9: reader width setting

@MainActor
@Suite("Editor: reader maximum width", .serialized)
struct EditorBehaviorReaderWidthTests {

    @Test("the reader column follows Settings › Reading › Maximum width (clamped)")
    func readerUsesMaxWidthSetting() throws {
        let (vm, _) = makeIsolatedVM()
        let entry = vm.createEntry(title: "Width", body: "text")
        defer { vm.stopEditing(); vm.db.hardDeleteEntry(id: entry.id) }
        let defaults = UserDefaults.standard
        let key = ReadingPreferences.maxWidthKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        #expect(Double(ReadView(vm: vm, entry: entry).readerMaxWidth) == ReadingPreferences.defaultMaxWidth)
        defaults.set(1100.0, forKey: key)
        #expect(Double(ReadView(vm: vm, entry: entry).readerMaxWidth) == 1100)
        defaults.set(600.0, forKey: key)
        #expect(Double(ReadView(vm: vm, entry: entry).readerMaxWidth) == 600)
        defaults.set(5000.0, forKey: key)
        #expect(Double(ReadView(vm: vm, entry: entry).readerMaxWidth) == ReadingPreferences.widthRange.upperBound)
        defaults.set(0.0, forKey: key)
        #expect(Double(ReadView(vm: vm, entry: entry).readerMaxWidth) == ReadingPreferences.defaultMaxWidth)
    }
}
