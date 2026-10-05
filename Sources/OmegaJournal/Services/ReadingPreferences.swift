import Foundation
import SwiftUI
import AppKit
import OmegaJournalCore

/// Shared AppStorage keys for reading-view preferences (Settings writes, reader reads).
enum ReadingPreferences {
    static let maxWidthKey = "readingMaxWidth"
    static let fontDesignKey = "readingFontDesign"
    static let defaultMaxWidth: Double = 760
    /// Show the entry's first image attachment as a cover above the title.
    static let showCoverKey = "readingShowCover"

    static let widthRange: ClosedRange<Double> = 520...1100
    /// Stored raw values for `fontDesignKey`.
    static let fontDesignOptions: [(raw: String, label: String)] = [
        ("default", "Sans"), ("serif", "Serif"), ("rounded", "Rounded"), ("monospaced", "Mono")
    ]

    /// Clamps a stored width into the supported range (bad/zero values → default).
    static func clampedWidth(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultMaxWidth }
        return min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Maps a stored raw value to a font design; unknown values fall back to default.
    static func fontDesign(from raw: String) -> Font.Design {
        switch raw {
        case "serif": .serif
        case "rounded": .rounded
        case "monospaced": .monospaced
        default: .default
        }
    }

    // MARK: Editor (focus / typewriter) preferences — persisted via @AppStorage (UserDefaults)

    static let editorFontKey = "editorFontChoice"
    static let editorLineHeightKey = "editorLineHeight"
    static let editorColumnWidthKey = "editorColumnWidth"
    static let editorTypewriterKey = "editorTypewriter"
    static let editorDimParagraphsKey = "editorDimParagraphs"
    static let editorDailyGoalRingKey = "editorShowGoalRing"

    /// NSFont for the editor body at `size` for a stored font choice.
    static func editorFont(_ choice: EditorFontChoice, size: CGFloat) -> NSFont {
        switch choice {
        case .system:
            return .systemFont(ofSize: size)
        case .serif:
            let base = NSFont.systemFont(ofSize: size)
            if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
            return NSFont(name: "Georgia", size: size) ?? base
        case .sans:
            return NSFont(name: "Helvetica Neue", size: size) ?? .systemFont(ofSize: size)
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}
