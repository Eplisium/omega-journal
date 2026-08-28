import SwiftUI
import AppKit

// MARK: - Shared Hover Card / Tooltip chrome
// Used by action-button tooltips and the Insights calendar day hovers.

enum OmegaHoverChrome {
    static let fill = Color(red: 0.11, green: 0.10, blue: 0.16)
    static let cornerRadius: CGFloat = 10
}

/// Dark glass card with accent border — shared look for tooltips & calendar hovers.
struct OmegaHoverCard<Content: View>: View {
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
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
            .compositingGroup()
    }
}

// MARK: - Custom Tooltip

struct CustomTooltip: View {
    let text: String
    let color: Color
    /// Pre-measured single-line width (already clamped to `maxTextWidth`);
    /// longer text wraps to at most three lines inside it.
    let textWidth: CGFloat

    static let maxTextWidth: CGFloat = 240

    var body: some View {
        OmegaHoverCard(accent: color) {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(width: textWidth)
        }
    }
}

// MARK: - Window-level tooltip panel
// Tooltips render in a borderless, non-activating panel instead of a SwiftUI
// overlay, so no ScrollView, split pane, or .clipped() container can crop
// them — and the card is clamped to the visible screen frame.

@MainActor
final class TooltipPanelController {
    static let shared = TooltipPanelController()

    private struct PanelContent: View {
        let tooltip: CustomTooltip
        var body: some View { tooltip.padding(Self.shadowPadding) }
        static let shadowPadding: CGFloat = 20
    }

    private var panel: NSPanel?
    private var hostingView: NSHostingView<PanelContent>?
    private var observers: [NSObjectProtocol] = []

    private static let gap: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    func show(text: String, accent: Color, anchorScreenRect: CGRect, screen: NSScreen?) {
        let measured = Self.measureNaturalTextWidth(text)
        let tooltip = CustomTooltip(
            text: text,
            color: accent,
            textWidth: measured >= CustomTooltip.maxTextWidth
                ? CustomTooltip.maxTextWidth
                : measured + 2
        )

        func fitted(_ tooltip: CustomTooltip) -> CGSize {
            let view = hostingView ?? {
                let created = NSHostingView<PanelContent>(rootView: PanelContent(tooltip: tooltip))
                hostingView = created
                return created
            }()
            view.rootView = PanelContent(tooltip: tooltip)
            view.layoutSubtreeIfNeeded()
            return view.fittingSize
        }

        let size = fitted(tooltip)
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let cardWidth = max(0, size.width - 2 * PanelContent.shadowPadding)
        let cardHeight = max(0, size.height - 2 * PanelContent.shadowPadding)

        var centerX = anchorScreenRect.midX
        centerX = min(max(centerX, visible.minX + Self.screenMargin + cardWidth / 2),
                      visible.maxX - Self.screenMargin - cardWidth / 2)
        if visible.width > 0 && visible.width < cardWidth { centerX = visible.midX }

        let belowY = anchorScreenRect.minY - Self.gap - cardHeight
        let fitsBelow = belowY >= visible.minY + Self.screenMargin
        guard let hostingView, cardWidth > 0, cardHeight > 0 else { return }

        let cardRect = CGRect(
            x: centerX - cardWidth / 2,
            y: fitsBelow ? belowY : anchorScreenRect.maxY + Self.gap,
            width: cardWidth,
            height: cardHeight
        )

        let panel = ensurePanel()
        panel.contentView = hostingView
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(
            x: cardRect.minX - PanelContent.shadowPadding,
            y: cardRect.minY - PanelContent.shadowPadding
        ))
        panel.orderFront(nil)
        observeAnchorChanges()
    }

    func hide() {
        panel?.orderOut(nil)
        removeObservers()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }

    /// Tooltips describe a fixed anchor; if its window moves, resizes, or
    /// closes while the card is up, dismiss rather than drift.
    private func observeAnchorChanges() {
        guard observers.isEmpty else { return }
        let names = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.willCloseNotification,
        ]
        let center = NotificationCenter.default
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            })
        }
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private static func measureNaturalTextWidth(_ text: String) -> CGFloat {
        let base = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let rounded = base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: 11) } ?? base
        return ceil((text as NSString).size(withAttributes: [.font: rounded]).width)
    }
}

// MARK: - Tooltip Container

private struct WindowAccessor: NSViewRepresentable {
    @Binding var hostWindow: NSWindow?
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if hostWindow !== view.window { hostWindow = view.window }
            if anchorView !== view { anchorView = view }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if hostWindow !== view.window { hostWindow = view.window }
            if anchorView !== view { anchorView = view }
        }
    }
}

struct TooltipContainer<Content: View>: View {
    let tooltip: String
    let color: Color?
    @ViewBuilder let content: () -> Content
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false
    @State private var anchorView: NSView?
    @State private var hostWindow: NSWindow?

    private var accent: Color { color ?? theme.accentColor }

    var body: some View {
        Group {
            if tooltip.isEmpty {
                base
            } else {
                base.accessibilityHint(tooltip)
            }
        }
    }

    private var base: some View {
        content()
            .background(WindowAccessor(hostWindow: $hostWindow, anchorView: $anchorView))
            .onHover { hovering in
                if hovering {
                    isHovered = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        guard isHovered, !tooltip.isEmpty,
                              let view = anchorView, let window = view.window else { return }
                        // Pure AppKit geometry: no SwiftUI coordinate-space ambiguity.
                        let inWindow = view.convert(view.bounds, to: nil)
                        TooltipPanelController.shared.show(
                            text: tooltip,
                            accent: accent,
                            anchorScreenRect: window.convertToScreen(inWindow),
                            screen: window.screen ?? NSScreen.main
                        )
                    }
                } else {
                    isHovered = false
                    TooltipPanelController.shared.hide()
                }
            }
    }
}

extension View {
    /// Themed hover tooltip — the in-app replacement for `.help`. The card
    /// renders in a window-level panel so it can never be clipped by scroll
    /// views or split panes, and it is clamped to the visible screen.
    func omegaTooltip(_ text: String, accent: Color? = nil) -> some View {
        TooltipContainer(tooltip: text, color: accent) { self }
    }
}
