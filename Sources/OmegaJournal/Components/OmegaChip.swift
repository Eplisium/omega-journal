import SwiftUI

/// Small pill for tags, filters and status. Pass `action` to make it tappable.
struct OmegaChip: View {
    enum Tone { case neutral, accent, success, warning, danger }

    let title: String
    var systemImage: String? = nil
    var tone: Tone = .neutral
    var isSelected: Bool = false
    var action: (() -> Void)? = nil

    @ObservedObject private var theme = ThemeManager.shared

    private var color: Color {
        switch tone {
        case .neutral: theme.secondaryTextColor
        case .accent: theme.accentColor
        case .success: theme.successColor
        case .warning: theme.warningColor
        case .danger: theme.dangerColor
        }
    }

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: OmegaTheme.Spacing.xs) {
            if let systemImage { Image(systemName: systemImage).font(OmegaTheme.font(.meta, .semibold)) }
            Text(title).font(OmegaTheme.font(.meta, .medium)).lineLimit(1)
        }
        .foregroundColor(isSelected ? theme.onAccentColor : color)
        .padding(.horizontal, OmegaTheme.Spacing.s)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(isSelected ? theme.accentColor : color.opacity(0.14))
        )
        .accessibilityElement(children: .combine)
    }
}
