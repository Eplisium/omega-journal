import Foundation

// MARK: - WCAG contrast (pure, no AppKit)

/// An sRGB color with components in 0...1, parsed from `#RRGGBB` hex.
public struct ThemeRGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// Parses `#RRGGBB` / `RRGGBB` (an 8-digit `#RRGGBBAA` alpha is ignored).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(r: Double((rgb >> 16) & 0xFF) / 255,
                  g: Double((rgb >> 8) & 0xFF) / 255,
                  b: Double(rgb & 0xFF) / 255)
    }

    public var hex: String {
        func c(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// WCAG relative luminance.
    public var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Composites `self` at `alpha` over `background`.
    public func blended(alpha: Double, over background: ThemeRGB) -> ThemeRGB {
        ThemeRGB(r: r * alpha + background.r * (1 - alpha),
                 g: g * alpha + background.g * (1 - alpha),
                 b: b * alpha + background.b * (1 - alpha))
    }

    public static let white = ThemeRGB(r: 1, g: 1, b: 1)
    public static let black = ThemeRGB(r: 0, g: 0, b: 0)
}

public enum ContrastChecker {
    /// WCAG AA threshold for normal body text.
    public static let minimumBodyRatio = 4.5

    /// WCAG contrast ratio, 1...21.
    public static func ratio(_ a: ThemeRGB, _ b: ThemeRGB) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Ratio from hex strings; nil when either fails to parse.
    public static func ratio(hex a: String, _ b: String) -> Double? {
        guard let ca = ThemeRGB(hex: a), let cb = ThemeRGB(hex: b) else { return nil }
        return ratio(ca, cb)
    }

    public static func meetsBodyText(_ fg: ThemeRGB, on bg: ThemeRGB) -> Bool {
        ratio(fg, bg) >= minimumBodyRatio
    }

    /// Whether a background reads as light (drives dark vs. light text).
    public static func isLight(_ bg: ThemeRGB) -> Bool {
        // Same threshold as the app's historical scheme detection.
        0.2126 * bg.r + 0.7152 * bg.g + 0.0722 * bg.b > 0.55
    }

    /// Body text the app derives for a custom background: 78–90% black on light, 90% white on dark.
    public static func derivedBodyText(on bg: ThemeRGB) -> ThemeRGB {
        isLight(bg) ? ThemeRGB.black.blended(alpha: 0.78, over: bg) : ThemeRGB.white.blended(alpha: 0.9, over: bg)
    }

    /// Lowest body-text contrast across the surfaces text is drawn on.
    public static func worstBodyContrast(background: ThemeRGB, card: ThemeRGB, sidebar: ThemeRGB) -> Double {
        // Text color is chosen from the background; it is drawn on all three surfaces.
        let text = derivedBodyText(on: background)
        return min(ratio(text, background), ratio(text, card), ratio(text, sidebar))
    }
}
