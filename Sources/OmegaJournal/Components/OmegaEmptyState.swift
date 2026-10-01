import SwiftUI

/// Centered empty/zero state with optional call to action.
struct OmegaEmptyState: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: OmegaTheme.Spacing.m) {
            ZStack {
                Circle().fill(theme.accentColor.opacity(0.12)).frame(width: 64, height: 64)
                Image(systemName: systemImage)
                    .font(OmegaTheme.font(.title, .light))
                    .foregroundColor(theme.accentColor)
            }
            .accessibilityHidden(true)
            Text(title)
                .font(OmegaTheme.headingFont)
                .foregroundColor(theme.titleTextColor)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(OmegaTheme.bodyFont)
                    .foregroundColor(theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentColor)
            }
        }
        .padding(OmegaTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
