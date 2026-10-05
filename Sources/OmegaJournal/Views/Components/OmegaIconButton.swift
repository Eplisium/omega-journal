import SwiftUI

/// Icon-only button. `accessibilityLabel` is required so VoiceOver never hears "button".
struct OmegaIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var size: OmegaTheme.TypeSize = .bodyLarge
    var isActive: Bool = false
    var action: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var hovering = false

    init(systemImage: String, accessibilityLabel: String, size: OmegaTheme.TypeSize = .bodyLarge,
         isActive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.size = size
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(OmegaTheme.font(size, .medium))
                .foregroundColor(isActive ? theme.accentColor : theme.secondaryTextColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: OmegaTheme.Radius.control, style: .continuous)
                        .fill(theme.titleTextColor.opacity(hovering ? 0.10 : (isActive ? 0.06 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
