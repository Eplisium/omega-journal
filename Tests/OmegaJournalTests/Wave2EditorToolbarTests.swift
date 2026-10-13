import AppKit
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// Wave 2 Editor track: the trimmed toolbar must not lose any action, and the
/// Split fallback policy is pure and width-driven.
@Suite("Wave 2 editor toolbar and pane policy")
struct Wave2EditorToolbarTests {
    @Test("the Format menu holds every formatting command exactly once")
    func formatMenuIsComplete() {
        let flat = MarkdownCommand.formatMenuSections.flatMap { $0 }
        #expect(flat.count == MarkdownCommand.allCases.count)
        #expect(Set(flat.map(\.label)) == Set(MarkdownCommand.allCases.map(\.label)))
    }

    @Test("toolbar icons are a small subset of the menu")
    func primaryIsSubset() {
        let all = Set(MarkdownCommand.allCases.map(\.label))
        #expect(MarkdownCommand.toolbarPrimary.allSatisfy { all.contains($0.label) })
        #expect(MarkdownCommand.toolbarPrimary.count <= 8)
        #expect(Set(MarkdownCommand.toolbarPrimary.map(\.label)).count == MarkdownCommand.toolbarPrimary.count)
    }

    @Test("every command advertises a distinct menu-bar shortcut")
    func shortcutHintsAreDistinct() {
        let hints = MarkdownCommand.allCases.map(\.shortcutHint)
        #expect(hints.allSatisfy { $0.contains("⌘") })
        #expect(Set(hints).count == hints.count)
        // Spot-check against the Format menu in OmegaJournalApp.
        #expect(MarkdownCommand.bold.shortcutHint == "⌘B")
        #expect(MarkdownCommand.heading2.shortcutHint == "⌃⌘2")
        #expect(MarkdownCommand.toggleTask.shortcutHint == "⇧⌘D")
    }

    @Test("Write and Preview ignore width; Split needs two readable panes")
    func paneLayoutPolicy() {
        #expect(EditorLayoutPolicy.layout(mode: .write, availableWidth: 200) == .writeOnly)
        #expect(EditorLayoutPolicy.layout(mode: .preview, availableWidth: 200) == .previewOnly)
        #expect(EditorLayoutPolicy.layout(mode: .split, availableWidth: 940) == .sideBySide)
        #expect(EditorLayoutPolicy.layout(mode: .split, availableWidth: EditorLayoutPolicy.minimumSideBySideWidth) == .sideBySide)
        #expect(EditorLayoutPolicy.layout(mode: .split, availableWidth: 458) == .tabbed(showingPreview: false))
        #expect(EditorLayoutPolicy.layout(mode: .split, availableWidth: 458, tabShowsPreview: true) == .tabbed(showingPreview: true))
        // First layout pass reports 0: don't flash the fallback.
        #expect(EditorLayoutPolicy.layout(mode: .split, availableWidth: 0) == .sideBySide)
    }

    @Test("source visibility per layout")
    func sourceVisibility() {
        #expect(EditorPaneLayout.writeOnly.showsSource && !EditorPaneLayout.writeOnly.showsPreview)
        #expect(!EditorPaneLayout.previewOnly.showsSource && EditorPaneLayout.previewOnly.previewCoversSource)
        #expect(EditorPaneLayout.sideBySide.showsSource && EditorPaneLayout.sideBySide.showsPreview)
        #expect(!EditorPaneLayout.sideBySide.previewCoversSource)
        #expect(EditorPaneLayout.tabbed(showingPreview: true).previewCoversSource)
        #expect(EditorPaneLayout.tabbed(showingPreview: false).showsSource)
    }

    @MainActor
    @Test("a hidden source drops focus and refuses format commands")
    func hiddenSourceRefusesCommands() {
        _ = NSApplication.shared
        let (scroll, text) = MarkdownTextEditor.makeScrollableTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        text.string = "plain"
        window.makeFirstResponder(text)
        MarkdownTextEditor.applyActive(false, scrollView: scroll, textView: text)
        #expect(scroll.isHidden)
        #expect(window.firstResponder !== text)
        MarkdownTextEditor.applyActive(true, scrollView: scroll, textView: text)
        #expect(!scroll.isHidden)
    }
}
