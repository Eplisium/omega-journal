import Foundation
import SwiftUI

/// Shared AppStorage keys for reading-view preferences (Settings writes, reader reads).
enum ReadingPreferences {
    static let maxWidthKey = "readingMaxWidth"
    static let fontDesignKey = "readingFontDesign"
    static let defaultMaxWidth: Double = 760

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
}
