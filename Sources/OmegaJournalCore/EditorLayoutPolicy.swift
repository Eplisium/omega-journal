import Foundation

/// Editor track (wave 2): pure layout policy for the editor's Write / Split /
/// Preview modes. The view adapts this to SwiftUI; tests cover it directly.
public enum EditorPaneMode: String, Sendable, CaseIterable {
    case write, split, preview
}

/// What the content area actually shows for a mode at a given width.
public enum EditorPaneLayout: Equatable, Sendable {
    /// Source only (Write mode).
    case writeOnly
    /// Rendered preview only (Preview mode). The source stays mounted but hidden.
    case previewOnly
    /// Source and preview side by side (Split with enough room).
    case sideBySide
    /// Split mode in a pane too narrow for two readable columns: one pane at a
    /// time with a Source / Preview tab switch instead of two squeezed panes.
    case tabbed(showingPreview: Bool)

    /// The source text view is visible (and may take keyboard focus/format commands).
    public var showsSource: Bool {
        switch self {
        case .writeOnly, .sideBySide: true
        case .previewOnly: false
        case .tabbed(let preview): !preview
        }
    }

    /// The rendered preview is visible.
    public var showsPreview: Bool {
        switch self {
        case .writeOnly: false
        case .previewOnly, .sideBySide: true
        case .tabbed(let preview): preview
        }
    }

    /// The preview is drawn over (instead of beside) the source, which stays
    /// mounted underneath so its caret, scroll position and undo survive.
    public var previewCoversSource: Bool { showsPreview && !showsSource }
}

public enum EditorLayoutPolicy {
    /// Narrowest readable column for either Split pane (≈ 40 characters of body text).
    public static let minimumSplitPaneWidth: Double = 300
    /// Hairline between the two Split panes.
    public static let splitDividerWidth: Double = 1

    /// Total content width needed before Split shows two panes.
    public static var minimumSideBySideWidth: Double { minimumSplitPaneWidth * 2 + splitDividerWidth }

    public static func layout(mode: EditorPaneMode, availableWidth: Double, tabShowsPreview: Bool = false) -> EditorPaneLayout {
        switch mode {
        case .write: return .writeOnly
        case .preview: return .previewOnly
        case .split:
            // Unknown width (first layout pass reports 0): assume room, the
            // next pass corrects it without remounting the source view.
            if availableWidth <= 0 || availableWidth >= minimumSideBySideWidth { return .sideBySide }
            return .tabbed(showingPreview: tabShowsPreview)
        }
    }
}

/// Footer save indicator. The save state stays visible in every editor mode,
/// including Zen (it used to be replaced by an "exit zen" hint there).
public enum EditorSaveIndicator {
    public static func label(isPending: Bool) -> String { isPending ? "Saving…" : "Saved" }
    public static func accessibilityLabel(isPending: Bool) -> String { isPending ? "Saving" : "All changes saved" }
}
