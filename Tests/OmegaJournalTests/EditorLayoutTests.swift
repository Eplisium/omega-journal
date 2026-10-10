import AppKit
import SwiftUI
import Testing
@testable import OmegaJournal

/// Width invariants for the hosted editor. Context: live, the scroll area was
/// 918pt wide while its text view was 1318pt, so wrapped lines ran past the
/// pane's right edge. That overflow only reproduced in the full app hierarchy
/// (not in this isolated host), so these tests guard the invariants, and the
/// fix (`WrappingScrollView.tile` + `OmegaTextView.setFrameSize` clamp) was
/// verified against the running app with an Accessibility frame dump.
@MainActor
@Suite("Editor layout")
struct EditorLayoutTests {
    private struct Host: View {
        @State var text = String(repeating: "Today I wrote something long enough to wrap several times. ", count: 20)
        let controller = MarkdownEditorController()
        var columnWidth: Double = 0
        var body: some View {
            MarkdownTextEditor(text: $text, font: .systemFont(ofSize: 15),
                               columnWidth: columnWidth, controller: controller)
        }
    }

    private func host(width: CGFloat, columnWidth: Double = 0) -> (NSWindow, NSHostingView<Host>) {
        let hosting = NSHostingView(rootView: Host(columnWidth: columnWidth))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func editor(in view: NSView) -> (NSScrollView, NSTextView)? {
        if let s = view as? NSScrollView, let t = s.documentView as? NSTextView { return (s, t) }
        for sub in view.subviews { if let found = editor(in: sub) { return found } }
        return nil
    }

    private func settle(_ window: NSWindow, _ hosting: NSView) {
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
    }

    private func assertFits(_ window: NSWindow, _ hosting: NSView, _ label: String) {
        settle(window, hosting)
        guard let (scroll, text) = editor(in: hosting) else {
            Issue.record("\(label): editor not found"); return
        }
        let visible = scroll.contentSize.width
        #expect(abs(text.frame.width - visible) <= 1, "\(label): text view \(text.frame.width) vs visible \(visible)")
        let container = text.textContainer!.containerSize.width + text.textContainerInset.width * 2
        #expect(container <= visible + 1, "\(label): text column \(container) wider than visible \(visible)")
    }

    @Test("text view matches the visible width once hosted in SwiftUI")
    func hostedWidth() {
        let (window, hosting) = host(width: 700)
        assertFits(window, hosting, "700")
    }

    @Test("text view tracks window shrink and grow")
    func resize() {
        let (window, hosting) = host(width: 1000)
        assertFits(window, hosting, "1000")
        window.setContentSize(NSSize(width: 360, height: 500))
        assertFits(window, hosting, "360")
        window.setContentSize(NSSize(width: 1300, height: 500))
        assertFits(window, hosting, "1300")
    }

    @Test("centred column stays inside the visible pane")
    func centredColumn() {
        let (window, hosting) = host(width: 1100, columnWidth: 640)
        assertFits(window, hosting, "column 640")
    }
}
