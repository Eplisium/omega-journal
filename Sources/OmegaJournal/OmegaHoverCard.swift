import SwiftUI

// MARK: - Shared Hover Card / Tooltip chrome
// Used by action-button tooltips and the Insights calendar day hovers.

enum OmegaHoverChrome {
    static let fill = Color(red: 0.11, green: 0.10, blue: 0.16)
    static let cornerRadius: CGFloat = 10
    static let arrowWidth: CGFloat = 10
    static let arrowHeight: CGFloat = 5
}

/// Dark glass card with accent border — shared look for tooltips & calendar hovers.
struct OmegaHoverCard<Content: View>: View {
    let accent: Color
    var showsArrow: Bool = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if showsArrow {
                Triangle()
                    .fill(OmegaHoverChrome.fill)
                    .frame(width: OmegaHoverChrome.arrowWidth, height: OmegaHoverChrome.arrowHeight)
                    .overlay(
                        Triangle()
                            .stroke(accent.opacity(0.55), lineWidth: 1)
                            .frame(width: OmegaHoverChrome.arrowWidth, height: OmegaHoverChrome.arrowHeight)
                    )
                    // Triangle points down by default; flip it up so the arrow
                    // indicates the button above when the tooltip renders below it.
                    .rotationEffect(.degrees(180))
                    .offset(y: -1)
            }
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: OmegaHoverChrome.cornerRadius, style: .continuous)
                            .fill(OmegaHoverChrome.fill)
                        RoundedRectangle(cornerRadius: OmegaHoverChrome.cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.14), Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        RoundedRectangle(cornerRadius: OmegaHoverChrome.cornerRadius, style: .continuous)
                            .strokeBorder(accent.opacity(0.55), lineWidth: 1)
                    }
                )
                .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 6)
                .shadow(color: accent.opacity(0.22), radius: 8, x: 0, y: 2)
        }
        .compositingGroup()
    }
}

// MARK: - Custom Tooltip

struct CustomTooltip: View {
    let text: String
    let color: Color

    var body: some View {
        OmegaHoverCard(accent: color) {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: - Tooltip Container

struct TooltipContainer<Content: View>: View {
    let tooltip: String
    let color: Color
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false
    @State private var showTip = false

    var body: some View {
        content()
            .onHover { hovering in
                if hovering {
                    isHovered = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        if isHovered { showTip = true }
                    }
                } else {
                    isHovered = false
                    showTip = false
                }
            }
            // Tooltips render *below* the button. The action buttons live in the
            // window's top toolbar, so an above-the-button tooltip (the old default)
            // was clipped by the title bar. An overlay aligned to the bottom escapes
            // the button's bounds into the content area below, where it's fully visible.
            .overlay(alignment: .bottom) {
                if showTip && !tooltip.isEmpty {
                    CustomTooltip(text: tooltip, color: color)
                        .offset(y: 38)
                        .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .top)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.82), value: showTip)
            .zIndex(showTip ? 1000 : 0)
    }
}
