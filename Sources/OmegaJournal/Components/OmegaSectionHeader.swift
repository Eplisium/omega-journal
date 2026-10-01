import SwiftUI

/// Section title with optional icon, subtitle and trailing accessory.
struct OmegaSectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: OmegaTheme.Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(OmegaTheme.font(.caption, .semibold))
                    .foregroundColor(theme.accentColor)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OmegaTheme.headingFont)
                    .foregroundColor(theme.titleTextColor)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(OmegaTheme.metaFont)
                        .foregroundColor(theme.secondaryTextColor)
                }
            }
            Spacer(minLength: OmegaTheme.Spacing.s)
            trailing()
        }
    }
}

extension OmegaSectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}
