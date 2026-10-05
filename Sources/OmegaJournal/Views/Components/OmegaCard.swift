import SwiftUI

/// A themed surface. `level` picks the theme surface (1 = card, 2/3 = raised).
struct OmegaCard<Content: View>: View {
    var level: Int = 1
    var padding: CGFloat = OmegaTheme.cardPadding
    var elevation: OmegaTheme.Elevation = .flat
    var hoverable: Bool = false
    @ViewBuilder var content: () -> Content

    @ObservedObject private var theme = ThemeManager.shared

    private var fill: Color {
        switch level {
        case 0: theme.surface0
        case 1: theme.surface1
        case 2: theme.surface2
        default: theme.surface3
        }
    }

    var body: some View {
        let card = content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OmegaTheme.Radius.card, style: .continuous).fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OmegaTheme.Radius.card, style: .continuous)
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            )
            .omegaElevation(elevation)
        if hoverable { card.hoverGlow() } else { card }
    }
}
