import SwiftUI

// MARK: - Design Tokens
//
// Single source of truth for typography, spacing, radii, elevation and motion.
// Colors come from `ThemeManager` (live, theme-aware); everything else is static.
// Views should use these tokens instead of literal sizes so later phases stay consistent.

enum OmegaTheme {
    // MARK: Type scale
    //
    // Minimum size for any text is `TypeSize.meta` (11 pt). Use `OmegaTheme.font(_:)`
    // for weight/design variants and the named presets below for the common cases.

    enum TypeSize: CGFloat, CaseIterable {
        case meta = 11
        case caption = 12
        case body = 13
        case bodyLarge = 15
        case heading = 17
        case title = 22
        case display = 32

        /// Nearest token for an arbitrary legacy point size (never below `.meta`).
        static func nearest(to size: CGFloat) -> TypeSize {
            allCases.min { abs($0.rawValue - size) < abs($1.rawValue - size) } ?? .body
        }
    }

    static func font(_ size: TypeSize, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        Font.system(size: size.rawValue, weight: weight, design: design)
    }

    static let metaFont = font(.meta)
    static let captionFont = font(.caption, .semibold)
    static let bodyFont = font(.body)
    static let bodyLargeFont = font(.bodyLarge)
    static let headingFont = font(.heading, .semibold)
    static let titleFont = font(.title, .bold, design: .serif)
    static let displayFont = font(.display, .light)
    static let serifTitleFont = font(.heading, .semibold, design: .serif)

    // MARK: Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Radii

    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let sheet: CGFloat = 16
    }

    // Legacy geometry aliases (kept so existing call sites compile unchanged).
    static let cardRadius: CGFloat = Radius.card
    static let controlRadius: CGFloat = Radius.control
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = Spacing.l

    // MARK: Elevation

    enum Elevation: Int, CaseIterable {
        case flat, raised, floating, modal

        var radius: CGFloat {
            switch self { case .flat: 0; case .raised: 6; case .floating: 14; case .modal: 28 }
        }
        var y: CGFloat {
            switch self { case .flat: 0; case .raised: 2; case .floating: 6; case .modal: 12 }
        }
        /// Shadow opacity; light themes use softer shadows.
        func opacity(isDark: Bool) -> Double {
            let base: Double
            switch self { case .flat: base = 0; case .raised: base = 0.22; case .floating: base = 0.32; case .modal: base = 0.45 }
            return isDark ? base : base * 0.45
        }
    }

    // MARK: Motion
    //
    // Presets return `nil` when Reduce Motion is on so `withAnimation`/`.animation` become no-ops.

    enum Motion {
        case quick, standard, spring, gentle

        func animation(reduceMotion: Bool) -> Animation? {
            if reduceMotion { return nil }
            switch self {
            case .quick: return .easeOut(duration: 0.12)
            case .standard: return .easeInOut(duration: 0.2)
            case .spring: return .spring(response: 0.35, dampingFraction: 0.78)
            case .gentle: return .easeOut(duration: 0.35)
            }
        }
    }

    /// Reads the system Reduce Motion preference outside a View (e.g. in action closures).
    static var reduceMotionEnabled: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

// MARK: - View helpers

extension View {
    /// Applies an elevation preset using the live theme.
    func omegaElevation(_ level: OmegaTheme.Elevation) -> some View {
        modifier(OmegaElevationModifier(level: level))
    }

    /// Animates `value` with a motion preset that honors Reduce Motion.
    func omegaAnimation<V: Equatable>(_ motion: OmegaTheme.Motion, value: V) -> some View {
        modifier(OmegaAnimationModifier(motion: motion, value: value))
    }
}

private struct OmegaElevationModifier: ViewModifier {
    let level: OmegaTheme.Elevation
    @ObservedObject private var theme = ThemeManager.shared

    func body(content: Content) -> some View {
        content.shadow(
            color: Color.black.opacity(level.opacity(isDark: theme.isDark)),
            radius: level.radius, x: 0, y: level.y
        )
    }
}

private struct OmegaAnimationModifier<V: Equatable>: ViewModifier {
    let motion: OmegaTheme.Motion
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

// MARK: - Mouse-reactive glow
//
// A card-level hover effect: a soft accent glow under the cursor and a brightened
// border while the pointer is over the card. Intentionally subtle; no scale change
// when Reduce Motion is on.

struct HoverGlowModifier: ViewModifier {
    var radius: CGFloat = OmegaTheme.Radius.card
    var glowStrength: Double = 0.14
    var borderStrength: Double = 0.35
    var lift: Bool = true

    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
                    .fill(theme.accentColor.opacity(hovering ? glowStrength * 0.6 : 0))
                    .blur(radius: 12)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        hovering ? theme.accentColor.opacity(borderStrength) : theme.borderColor,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .scaleEffect(hovering && lift && !reduceMotion ? 1.003 : 1)
            .shadow(color: theme.accentColor.opacity(hovering ? glowStrength * 0.5 : 0), radius: hovering ? 10 : 0, x: 0, y: 3)
            .onHover { hovering = $0 }
            .animation(OmegaTheme.Motion.quick.animation(reduceMotion: reduceMotion), value: hovering)
    }
}

extension View {
    /// Adds a subtle mouse-reactive accent glow + border bloom to a card.
    func hoverGlow(radius: CGFloat = OmegaTheme.Radius.card, glow: Double = 0.30, border: Double = 0.45, lift: Bool = true) -> some View {
        modifier(HoverGlowModifier(radius: radius, glowStrength: glow, borderStrength: border, lift: lift))
    }
}
