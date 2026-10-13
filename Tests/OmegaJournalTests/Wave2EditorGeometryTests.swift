import AppKit
import SwiftUI
import Testing
@testable import OmegaJournal

/// Wave 2 Editor track: geometry invariants after *live* changes (the
/// existing EditorLayoutTests only cover a fixed column at creation time):
/// column-width and font-size changes on a hosted editor, and typewriter
/// padding following a vertical window resize.
@MainActor
@Suite("Wave 2 editor geometry after live changes", .serialized)
struct Wave2EditorGeometryTests {
    private struct Host: View {
        @State var text = (0..<80).map { "Synthetic line \($0) that is long enough to wrap in a narrow pane." }.joined(separator: "\n")
        let controller = MarkdownEditorController()
        var columnWidth: Double = 0
        var fontSize: CGFloat = 15
        var typewriter = false
        var body: some View {
            MarkdownTextEditor(text: $text, font: .systemFont(ofSize: fontSize), isTypewriterMode: typewriter,
                               columnWidth: columnWidth, controller: controller)
        }
    }

    private func make(_ root: Host, width: CGFloat, height: CGFloat = 500) -> (NSWindow, NSHostingView<Host>) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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

    private func editor(in view: NSView) -> (NSScrollView, NSTextView)? {
        if let s = view as? NSScrollView, let t = s.documentView as? NSTextView { return (s, t) }
        for sub in view.subviews { if let f = editor(in: sub) { return f } }
        return nil
    }

    /// Usable text column (container minus padding) and the visible width.
    private func columns(_ hosting: NSView) throws -> (column: CGFloat, visible: CGFloat, inset: CGFloat) {
        let (scroll, text) = try #require(editor(in: hosting))
        let container = text.textContainer!
        let column = container.size.width - container.lineFragmentPadding * 2
        return (column, scroll.contentSize.width, text.textContainerInset.width)
    }

    @Test("changing the column width re-centres the column inside the viewport")
    func columnWidthChange() throws {
        let (window, hosting) = make(Host(columnWidth: 0), width: 1100)
        defer { window.contentView = nil }
        let full = try columns(hosting)
        #expect(full.column > 1000)

        hosting.rootView = Host(columnWidth: 600)
        settle(window, hosting)
        let narrow = try columns(hosting)
        #expect(abs(narrow.column + narrow.inset * 2 + 0 - narrow.visible) <= 1 + 10, "column \(narrow) not centred")
        #expect(narrow.column <= 600 + 1)
        #expect(narrow.column >= 560, "column \(narrow.column) much narrower than requested 600")

        // Window narrower than the column: the column shrinks to the viewport.
        window.setContentSize(NSSize(width: 420, height: 500))
        settle(window, hosting)
        let squeezed = try columns(hosting)
        #expect(squeezed.column + squeezed.inset * 2 <= squeezed.visible + 1)
        #expect(squeezed.column > 380)

        hosting.rootView = Host(columnWidth: 0)
        window.setContentSize(NSSize(width: 1100, height: 500))
        settle(window, hosting)
        #expect(try columns(hosting).column > 1000, "column did not grow back to the pane")
    }

    @Test("font-size changes keep the text inside the viewport")
    func fontSizeChange() throws {
        let (window, hosting) = make(Host(columnWidth: 640, fontSize: 13), width: 900)
        defer { window.contentView = nil }
        for size in [22.0, 13.0, 19.0] {
            hosting.rootView = Host(columnWidth: 640, fontSize: size)
            settle(window, hosting)
            let (scroll, text) = try #require(editor(in: hosting))
            #expect(abs(text.frame.width - scroll.contentSize.width) <= 1, "size \(size): text view \(text.frame.width) vs \(scroll.contentSize.width)")
            let used = text.layoutManager!.usedRect(for: text.textContainer!)
            #expect(used.maxX <= text.textContainer!.size.width + 1, "size \(size): glyphs past the container")
        }
    }

    @Test("typewriter padding follows a vertical resize")
    func typewriterFollowsHeight() throws {
        let (window, hosting) = make(Host(typewriter: true), width: 700, height: 500)
        defer { window.contentView = nil }
        for height in [800.0, 360.0] {
            window.setContentSize(NSSize(width: 700, height: height))
            settle(window, hosting)
            let (scroll, text) = try #require(editor(in: hosting))
            let viewport = scroll.contentView.bounds.height
            #expect(abs(text.textContainerInset.height - max(12, viewport / 2)) <= 1,
                    "height \(height): inset \(text.textContainerInset.height) vs viewport/2 \(viewport / 2)")
        }
    }
}
