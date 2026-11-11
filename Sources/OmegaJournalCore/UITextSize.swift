import Foundation

// MARK: - App-wide text size (pure)
//
// Settings › Appearance › Text size scales every `OmegaTheme` type token
// (sidebar, lists, reader chrome, meta lines) by one factor. The editor keeps
// its own point-size control; its chosen size is multiplied by the same factor
// so "Large" makes the whole app — writing included — easier to read.

public enum UITextSize: String, CaseIterable, Sendable, Identifiable {
    case small
    case standard = "default"
    case large
    case extraLarge

    /// UserDefaults key (read before the journal key exists, so it never
    /// touches the database — safe for the launch gate).
    public static let storageKey = "appearance.textSize"

    /// Smallest point size any token may reach. Meta text is 11 pt at Default
    /// and never shrinks below it, even at Small.
    public static let absoluteMinimum: Double = 11

    public var id: String { rawValue }

    /// Picker label, sentence case.
    public var label: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }

    /// Multiplier applied to every base point size.
    public var scale: Double {
        switch self {
        case .small: 0.92
        case .standard: 1.0
        case .large: 1.12
        case .extraLarge: 1.25
        }
    }

    /// `base` scaled for this size, rounded to the nearest half point and
    /// never below `absoluteMinimum`. Default returns `base` unchanged.
    public func scaled(_ base: Double) -> Double {
        guard self != .standard else { return base }
        let raw = (base * scale * 2).rounded() / 2
        return max(Self.absoluteMinimum, raw)
    }

    /// Editor body size: the editor's own control picks the base (13–22 pt),
    /// the app-wide size scales it. Same rounding as every other token.
    public func editorPointSize(base: Double) -> Double { scaled(base) }

    /// Stored value → size; unknown or missing values fall back to Default.
    public static func from(stored raw: String?) -> UITextSize {
        raw.flatMap(UITextSize.init(rawValue:)) ?? .standard
    }
}
