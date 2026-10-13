import AppKit
import SwiftUI
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Wave 2 Editor track: geometry of the full `EditorView` (not just the text
/// view) inside the detail column, and mode switches that must not rebuild the
/// text view. Live context: at the 940pt minimum window the detail column is
/// ~458pt, but the editor's fixed-size top bar demanded ~540pt, so the whole
/// split view overflowed the window — prose, the formatting row and the save
/// status were clipped at the right edge (AX: detail 481…1020 in a 940 window).
@MainActor
@Suite("Wave 2 editor layout", .serialized)
struct Wave2EditorLayoutTests {
    private func makeVM() -> JournalViewModel {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oj-w2e-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", dir.appendingPathComponent("db.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", dir.appendingPathComponent("att").path, 1)
        return JournalViewModel()
    }

    private static let body = String(repeating: "Synthetic sentence that wraps across the pane. ", count: 60)

    private func host(_ vm: JournalViewModel, _ entry: JournalEntry, width: CGFloat) -> (NSWindow, NSView) {
        let hosting = NSHostingView(rootView: EditorView(vm: vm, entry: entry))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        settle(window, hosting)
        return (window, hosting)
    }

    private func settle(_ window: NSWindow, _ hosting: NSView) {
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func textViews(in view: NSView) -> [(NSScrollView, NSTextView)] {
        var out: [(NSScrollView, NSTextView)] = []
        if let s = view as? NSScrollView, let t = s.documentView as? NSTextView { out.append((s, t)) }
        for sub in view.subviews { out += textViews(in: sub) }
        return out
    }

    private func windowFrame(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }

    @Test("the editor fits the 458pt detail column of a 940pt window", arguments: [458.0, 940.0])
    func editorFitsDetailColumn(width: Double) throws {
        let vm = makeVM()
        let entry = vm.createEntry(title: "Fit", body: Self.body)
        defer { vm.stopEditing(); vm.db.hardDeleteEntry(id: entry.id) }
        vm.editorMode = .write
        let (window, hosting) = host(vm, entry, width: width)
        defer { window.contentView = nil }
        let (scroll, _) = try #require(textViews(in: hosting).first)
        let f = windowFrame(scroll)
        #expect(f.minX >= -0.5, "editor starts left of the window: \(f)")
        #expect(f.maxX <= width + 0.5, "editor runs past the window's right edge: \(f) in \(width)")
        _ = window
    }

    @Test("split below the adaptive minimum falls back to one readable pane")
    func narrowSplitFallsBack() throws {
        let vm = makeVM()
        let entry = vm.createEntry(title: "Split", body: Self.body)
        defer { vm.stopEditing(); vm.editorMode = .write; vm.db.hardDeleteEntry(id: entry.id) }
        vm.editorMode = .split
        let (window, hosting) = host(vm, entry, width: 458)
        defer { window.contentView = nil }
        let (scroll, _) = try #require(textViews(in: hosting).first)
        // Squeezed side-by-side would leave ~228pt; the fallback keeps the full width.
        #expect(windowFrame(scroll).width > 400, "split squeezed the writing pane to \(windowFrame(scroll).width)")
        _ = window
    }

    @Test("wide split shows both panes side by side")
    func wideSplitIsSideBySide() throws {
        let vm = makeVM()
        let entry = vm.createEntry(title: "Split wide", body: Self.body)
        defer { vm.stopEditing(); vm.editorMode = .write; vm.db.hardDeleteEntry(id: entry.id) }
        vm.editorMode = .split
        let (window, hosting) = host(vm, entry, width: 940)
        defer { window.contentView = nil }
        let (scroll, _) = try #require(textViews(in: hosting).first)
        let w = windowFrame(scroll).width
        #expect(w < 520 && w > 300, "expected roughly half of 940, got \(w)")
        _ = window
    }

    @Test("write → preview → split → write keeps the same text view, caret and text")
    func modeSwitchKeepsTextView() throws {
        let vm = makeVM()
        let entry = vm.createEntry(title: "Modes", body: Self.body)
        defer { vm.stopEditing(); vm.editorMode = .write; vm.db.hardDeleteEntry(id: entry.id) }
        vm.editorMode = .write
        let (window, hosting) = host(vm, entry, width: 1100)
        defer { window.contentView = nil }
        let (_, original) = try #require(textViews(in: hosting).first)
        original.setSelectedRange(NSRange(location: 42, length: 0))
        let before = original.string
        for mode in [JournalViewModel.EditorMode.preview, .split, .write] {
            vm.editorMode = mode
            settle(window, hosting)
        }
        let (_, after) = try #require(textViews(in: hosting).first)
        #expect(after === original, "switching modes rebuilt the NSTextView (caret, scroll and focus lost)")
        #expect(after.selectedRange().location == 42)
        #expect(after.string == before)
    }

    @Test("format shortcuts do not edit the hidden source while previewing")
    func previewIgnoresFormatting() throws {
        let vm = makeVM()
        let entry = vm.createEntry(title: "Preview", body: "plain words")
        defer { vm.stopEditing(); vm.editorMode = .write; vm.db.hardDeleteEntry(id: entry.id) }
        vm.editorMode = .preview
        let (window, hosting) = host(vm, entry, width: 900)
        defer { window.contentView = nil }
        NotificationCenter.default.post(name: .formatCommand, object: MarkdownCommand.heading1)
        settle(window, hosting)
        if let (_, tv) = textViews(in: hosting).first {
            #expect(tv.string == "plain words")
        }
        vm.editorMode = .write
        settle(window, hosting)
        NotificationCenter.default.post(name: .formatCommand, object: MarkdownCommand.heading1)
        settle(window, hosting)
        let (_, tv) = try #require(textViews(in: hosting).first)
        #expect(tv.string == "# plain words")
    }

    // MARK: Footer save state

    private func saveStateFrame(isZen: Bool, pending: Bool, width: CGFloat) -> (NSRect?, NSWindow) {
        final class Box { var frame: CGRect? }
        let box = Box()
        let footer = WritingFooterView(
            wordCount: 1234, charCount: 7890, selectionWords: 0, readingTime: "6 min read", attachmentCount: 2,
            sessionStart: Date(), sessionStartWords: 0, ring: WritingSessionMath.goalRing(otherWordsToday: 100, liveEntryWords: 50, target: 500),
            sprint: nil, sprintFinished: false, isZen: isZen, saveState: pending ? .pending : .saved,
            onStartSprint: { _ in }, onStopSprint: {}, onSaveIndicatorFrame: { box.frame = $0 })
        let hosting = NSHostingView(rootView: footer.frame(width: width))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        settle(window, hosting)
        return (box.frame, window)
    }

    @Test("save state stays visible in narrow columns and in Zen mode",
          arguments: [(360.0, false), (360.0, true), (458.0, false), (900.0, true)])
    func saveStateAlwaysVisible(width: Double, zen: Bool) throws {
        _ = NSApplication.shared
        let (frame, window) = saveStateFrame(isZen: zen, pending: false, width: width)
        let f = try #require(frame, "no save-state element (zen=\(zen), width=\(width))")
        #expect(f.width > 10, "save state squeezed to \(f.width)")
        #expect(f.minX >= -0.5 && f.maxX <= width + 0.5, "save state clipped: \(f) in \(width)")
        _ = window
    }

    @Test("save indicator wording")
    func saveIndicatorWording() {
        #expect(EditorSaveIndicator.label(isPending: true) == "Saving…")
        #expect(EditorSaveIndicator.label(isPending: false) == "Saved")
        #expect(EditorSaveIndicator.accessibilityLabel(isPending: false) == "All changes saved")
    }
}
