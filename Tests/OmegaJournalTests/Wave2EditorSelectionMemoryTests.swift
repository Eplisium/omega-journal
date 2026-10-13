import AppKit
import SwiftUI
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Wave 2 Editor track: a new text view for the same entry (Zen swap, reopen)
/// resumes at the old caret with focus, instead of jumping to the end.
@Suite("Wave 2 editor selection memory")
struct Wave2EditorSelectionMemoryTests {
    @Test("remembers per key and clamps to the current text length")
    func clamps() {
        var m = EditorSelectionMemory()
        m.remember(.init(location: 40, length: 10, wasFocused: true), for: "a")
        #expect(m.restore(for: "a", textLength: 100) == .init(location: 40, length: 10, wasFocused: true))
        #expect(m.restore(for: "a", textLength: 45) == .init(location: 40, length: 5, wasFocused: true))
        #expect(m.restore(for: "a", textLength: 20) == .init(location: 20, length: 0, wasFocused: true))
        #expect(m.restore(for: "b", textLength: 100) == nil)
        m.forget("a")
        #expect(m.restore(for: "a", textLength: 100) == nil)
    }

    @Test("bounded: the oldest entries are dropped first")
    func bounded() {
        var m = EditorSelectionMemory(capacity: 2)
        m.remember(.init(location: 1, length: 0, wasFocused: false), for: "a")
        m.remember(.init(location: 2, length: 0, wasFocused: false), for: "b")
        m.remember(.init(location: 1, length: 0, wasFocused: false), for: "a") // refresh a
        m.remember(.init(location: 3, length: 0, wasFocused: false), for: "c")
        #expect(m.restore(for: "b", textLength: 10) == nil)
        #expect(m.restore(for: "a", textLength: 10)?.location == 1)
        #expect(m.order == ["a", "c"])
    }

    private struct Host: View {
        @State var text = String(repeating: "Synthetic words for caret memory. ", count: 40)
        let controller = MarkdownEditorController()
        var show: Bool
        var key: String
        var body: some View {
            if show {
                MarkdownTextEditor(text: $text, font: .systemFont(ofSize: 15), controller: controller,
                                   selectionMemoryKey: key)
            } else {
                Color.clear
            }
        }
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let t = view as? NSTextView { return t }
        for sub in view.subviews { if let t = textView(in: sub) { return t } }
        return nil
    }

    private func settle(_ window: NSWindow, _ hosting: NSView) {
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor
    @Test("a rebuilt text view for the same entry resumes caret and focus")
    func rebuildResumes() throws {
        _ = NSApplication.shared
        let key = "wave2-\(UUID().uuidString)"
        defer { MarkdownTextEditor.selectionMemory.forget(key) }
        let hosting = NSHostingView(rootView: Host(show: true, key: key))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        settle(window, hosting)
        let first = try #require(textView(in: hosting))
        first.setSelectedRange(NSRange(location: 123, length: 4))
        window.makeFirstResponder(first)

        #expect(window.firstResponder === first)
        hosting.rootView = Host(show: false, key: key)   // e.g. entering Zen
        settle(window, hosting)
        hosting.rootView = Host(show: true, key: key)    // the new editor
        settle(window, hosting)

        let second = try #require(textView(in: hosting))
        #expect(second !== first)
        #expect(second.selectedRange() == NSRange(location: 123, length: 4))
        #expect(window.firstResponder === second, "focus was not restored to the new text view")
    }

    @MainActor
    @Test("no key, no memory: a new text view starts fresh")
    func noKeyNoMemory() throws {
        _ = NSApplication.shared
        let (scroll, text) = MarkdownTextEditor.makeScrollableTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        text.string = "abc"
        text.setSelectedRange(NSRange(location: 1, length: 0))
        let before = MarkdownTextEditor.selectionMemory.order
        window.contentView = nil
        #expect(MarkdownTextEditor.selectionMemory.order == before)
    }
}
