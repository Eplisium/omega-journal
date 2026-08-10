import SwiftUI

// MARK: - Action Button

struct ActionButton: View {
    let icon: String, color: Color, active: Bool
    let tooltip: String
    let isDestructive: Bool
    let action: () -> Void
    @State private var hover = false

    init(icon: String, color: Color, active: Bool, tooltip: String = "", isDestructive: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.color = color
        self.active = active
        self.tooltip = tooltip
        self.isDestructive = isDestructive
        self.action = action
    }

    private var hoverBackground: Color {
        if isDestructive && hover {
            return Color.red.opacity(0.18)
        }
        if active && hover {
            return color.opacity(0.18)
        }
        return hover ? Color(nsColor: .controlBackgroundColor) : Color.clear
    }

    private var iconColor: Color {
        if isDestructive && hover { return .red }
        if active { return color }
        return .secondary
    }

    var body: some View {
        TooltipContainer(tooltip: tooltip, color: isDestructive ? .red : color) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hoverBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                hover
                                    ? (isDestructive ? Color.red.opacity(0.35) : color.opacity(active ? 0.45 : 0.25))
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .scaleEffect(hover ? 1.08 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(.easeInOut(duration: 0.15), value: hover)
        }
    }
}
