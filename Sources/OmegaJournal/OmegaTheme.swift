import SwiftUI

// MARK: - Design Tokens
//
// Shared typography and geometry constants so cards, charts, and headers stay
// visually consistent across views.

enum OmegaTheme {
    // Typography
    static let titleFont = Font.system(size: 20, weight: .bold, design: .serif)
    static let headingFont = Font.system(size: 15, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let metaFont = Font.system(size: 10)
    static let captionFont = Font.system(size: 10, weight: .semibold)

    // Geometry
    static let cardRadius: CGFloat = 11
    static let controlRadius: CGFloat = 7
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 16
}
// MARK: - Mouse-reactive glow
//
// A card-level hover effect: a soft accent glow blooms under the cursor and
// the border brightens while the pointer is over the card. Used by hero,
// stat, recent-writing, entry, and streak cards so the whole app feels alive.

struct HoverGlowModifier: ViewModifier {
    var radius: CGFloat = 11
    var glowStrength: Double = 0.18
    var borderStrength: Double = 0.35
    var lift: Bool = true

    @ObservedObject private var theme = ThemeManager.shared
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                // Bloom behind the card while hovered.
                RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
                    .fill(theme.accentColor.opacity(hovering ? glowStrength : 0))
                    .blur(radius: 14)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        hovering ? theme.accentColor.opacity(borderStrength) : theme.titleTextColor.opacity(0.06),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .scaleEffect(hovering && lift ? 1.008 : 1)
            .shadow(color: theme.accentColor.opacity(hovering ? glowStrength * 0.9 : 0), radius: hovering ? 16 : 0, x: 0, y: 4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

extension View {
    /// Adds a mouse-reactive accent glow + border bloom to a card.
    func hoverGlow(radius: CGFloat = 11, glow: Double = 0.30, border: Double = 0.45, lift: Bool = true) -> some View {
        modifier(HoverGlowModifier(radius: radius, glowStrength: glow, borderStrength: border, lift: lift))
    }
}