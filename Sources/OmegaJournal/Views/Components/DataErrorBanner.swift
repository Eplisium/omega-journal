import SwiftUI

/// Shown above the entry list when part of the journal could not be read
/// (`JournalViewModel.readError`). Says plainly that nothing was deleted, so
/// a failed read never looks like an empty journal, and offers Try Again.
///
/// Mount (the list view, above the rows):
///
///     if let message = vm.readError {
///         DataErrorBanner(message: message, onRetry: vm.retryReading)
///     }
struct DataErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    private let theme = ThemeManager.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: OmegaTheme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.warningColor)
                .accessibilityHidden(true)
            Text(message)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.bodyTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: OmegaTheme.Spacing.s)
            Button("Try Again", action: onRetry)
                .buttonStyle(.plain)
                .font(OmegaTheme.font(.meta, .semibold))
                .foregroundColor(theme.accentColor)
                .help("Read your journal again")
                .accessibilityHint("Reads your journal again")
        }
        .padding(.horizontal, OmegaTheme.Spacing.m)
        .padding(.vertical, OmegaTheme.Spacing.s)
        .background(theme.warningColor.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Problem reading your journal")
        .accessibilityValue(message)
    }
}
