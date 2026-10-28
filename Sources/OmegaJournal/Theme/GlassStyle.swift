import SwiftUI

// MARK: - Liquid Glass adoption
//
// macOS 26 gives standard toolbars, sidebars, menus and sheets Liquid Glass
// for free, but this app draws much of its own chrome. These helpers put glass
// on the custom surfaces that belong to the floating / navigation layer and
// keep everything on the content layer solid, following Apple's HIG:
//
//   glass  — window toolbar band, floating panels (⌘K palette, hover cards,
//            toasts, floating search helpers), header controls (reader and
//            calendar controls, list search field) and primary actions.
//   solid  — content: entry text and the reading column, entry rows, and
//            content cards (Today hero, progress, Insights/Calendar cards,
//            Settings cards). Glass there would cost legibility.
//
// Every macOS 26 API sits behind `if #available(macOS 26.0, *)`; on macOS
// 14/15 each helper renders the app's previous look unchanged.

/// A piece of custom chrome, classified by HIG layer.
nonisolated enum GlassSurface: String, CaseIterable, Sendable {
    /// The window toolbar band above the workspace.
    case windowToolbar
    /// Panels that float above content: command palette, hover cards, toasts,
    /// the floating search-operator strip.
    case floatingPanel
    /// Controls in a header/tool bar (icon clusters, menus, steppers, search field).
    case toolbarControl
    /// The one emphasized action of a surface (Edit, New Entry, Continue writing).
    case primaryAction
    /// Cards that hold the user's content or stats.
    case contentCard
    /// Rows in the entry list.
    case entryRow
    /// The reader/editor text column.
    case readingColumn

    enum Layer: Sendable { case navigation, content }

    var layer: Layer {
        switch self {
        case .windowToolbar, .floatingPanel, .toolbarControl, .primaryAction: .navigation
        case .contentCard, .entryRow, .readingColumn: .content
        }
    }
}

/// Pure decisions about where and how glass renders (unit-tested).
nonisolated enum GlassPolicy {
    /// First macOS release with Liquid Glass.
    static let minimumMajorVersion = 26

    static func isGlassAvailable(osMajorVersion: Int) -> Bool {
        osMajorVersion >= minimumMajorVersion
    }

    /// Glass only on the navigation layer, and only where the OS has it.
    /// Reduce Transparency does not switch glass off: the system renders a
    /// frosted, more opaque glass for it on its own.
    static func usesGlass(_ surface: GlassSurface, osMajorVersion: Int) -> Bool {
        isGlassAvailable(osMajorVersion: osMajorVersion) && surface.layer == .navigation
    }

    /// Accent tint mixed into a glass surface. Floating panels get a faint wash
    /// so they read as Omega Journal's, controls stay neutral, and primary
    /// actions are fully tinted (prominent glass). Reduce Transparency drops the
    /// decorative wash on panels so the frosted glass stays as calm as possible.
    static func tintOpacity(for surface: GlassSurface, reduceTransparency: Bool) -> Double {
        switch surface {
        case .floatingPanel: reduceTransparency ? 0 : 0.10
        case .primaryAction: 1
        case .windowToolbar, .toolbarControl, .contentCard, .entryRow, .readingColumn: 0
        }
    }

    /// Increase Contrast keeps a visible hairline around glass panels, whose
    /// edges otherwise rely on refraction alone.
    static func drawsContrastBorder(on surface: GlassSurface, increaseContrast: Bool) -> Bool {
        increaseContrast && surface == .floatingPanel
    }

    /// Opacity of the dimming layer behind a modal floating panel (⌘K). Glass
    /// needs some of the content behind it to show, so the dim is lighter
    /// there; without glass (or with Reduce Transparency) keep the old dim.
    static func modalDimOpacity(glass: Bool, reduceTransparency: Bool) -> Double {
        glass && !reduceTransparency ? 0.28 : 0.35
    }
}

/// Runtime glue between the policy and this process.
enum GlassSupport {
    static var osMajorVersion: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    static func usesGlass(_ surface: GlassSurface) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return GlassPolicy.usesGlass(surface, osMajorVersion: osMajorVersion)
    }
}

// MARK: - View helpers

extension View {
    /// Liquid Glass on `shape` for a navigation-layer surface; otherwise
    /// `fallback` receives the view and draws the previous look.
    @ViewBuilder
    func ojGlass<S: Shape, Fallback: View>(
        _ surface: GlassSurface,
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        @ViewBuilder fallback: (Self) -> Fallback
    ) -> some View {
        if #available(macOS 26.0, *), GlassSupport.usesGlass(surface) {
            modifier(OJGlassEffect(surface: surface, shape: shape, tint: tint, interactive: interactive))
        } else {
            fallback(self)
        }
    }

    /// Glass when available; the view unchanged otherwise.
    func ojGlass<S: Shape>(_ surface: GlassSurface, in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        ojGlass(surface, in: shape, tint: tint, interactive: interactive) { $0 }
    }

    /// Applies `transform` only when `surface` does NOT get glass — for the
    /// hand-drawn fills, borders and padding that glass replaces.
    @ViewBuilder
    func ojUnlessGlass<V: View>(_ surface: GlassSurface, @ViewBuilder _ transform: (Self) -> V) -> some View {
        if GlassSupport.usesGlass(surface) { self } else { transform(self) }
    }

    /// Button style for a header/primary action, applied to the `Button`.
    /// macOS 26: an interactive glass capsule (or circle) — accent-tinted for
    /// the prominent action, neutral otherwise — at a shared control height so
    /// neighbouring controls line up. Before macOS 26: `.plain`, with the
    /// label's own chrome (pair with `ojUnlessGlass`/`ojAccentCapsule`).
    @ViewBuilder
    func ojGlassButtonStyle(prominent: Bool, circle: Bool = false,
                            height: CGFloat = OJGlassMetrics.controlHeight) -> some View {
        if #available(macOS 26.0, *), GlassSupport.usesGlass(prominent ? .primaryAction : .toolbarControl) {
            buttonStyle(OJGlassButtonStyle(prominent: prominent, circle: circle, height: height))
        } else {
            buttonStyle(.plain)
        }
    }

    /// The pre-glass accent capsule behind a primary action's label. On glass
    /// the `.glassProminent` button style draws the (accent-tinted) capsule.
    func ojAccentCapsule(_ fill: Color, horizontal: CGFloat, vertical: CGFloat) -> some View {
        ojUnlessGlass(.primaryAction) { label in
            label
                .padding(.horizontal, horizontal)
                .padding(.vertical, vertical)
                .background(Capsule().fill(fill))
        }
    }

    /// Wraps a run of header controls (icon buttons, a menu) in one glass
    /// capsule, the way macOS 26 groups toolbar items. Unchanged before.
    @ViewBuilder
    func ojGlassCluster(horizontal: CGFloat = 2, vertical: CGFloat = 2) -> some View {
        if GlassSupport.usesGlass(.toolbarControl) {
            padding(.horizontal, horizontal)
                .padding(.vertical, vertical)
                .frame(minHeight: OJGlassMetrics.controlHeight)
                .ojGlass(.toolbarControl, in: Capsule())
        } else {
            self
        }
    }

    /// A header bar above scrolling content. On macOS 26 it is a
    /// `safeAreaBar`: content scrolls beneath the floating glass controls with
    /// the system scroll-edge effect keeping them legible. Before that the bar
    /// stays stacked above the content (the caller draws it there).
    @ViewBuilder
    func ojHeaderBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26.0, *), GlassSupport.usesGlass(.toolbarControl) {
            safeAreaBar(edge: .top, spacing: 0) { bar() }
        } else {
            self
        }
    }

    /// Lets the themed workspace background run under the window toolbar so
    /// the system's glass toolbar controls float over it, instead of an opaque
    /// grey title band. Unchanged on macOS 14/15.
    @ViewBuilder
    func ojGlassWindowToolbar() -> some View {
        if GlassSupport.usesGlass(.windowToolbar) {
            toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}

/// Shared sizes for glass header controls.
enum OJGlassMetrics {
    /// Height of a header control (capsule button, icon cluster, menu).
    static let controlHeight: CGFloat = 34
    /// Icon button inside a cluster (cluster padding brings it to `controlHeight`).
    static let clusterIcon: CGFloat = 30
}

@available(macOS 26.0, *)
private struct OJGlassButtonStyle: ButtonStyle {
    let prominent: Bool
    let circle: Bool
    let height: CGFloat
    private let theme = ThemeManager.shared
    @Environment(\.isEnabled) private var isEnabled

    init(prominent: Bool, circle: Bool, height: CGFloat) {
        self.prominent = prominent
        self.circle = circle
        self.height = height
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(Capsule())
        return configuration.label
            .padding(.horizontal, circle ? 0 : (prominent && height > 32 ? 16 : 12))
            .frame(minWidth: circle ? height : nil, minHeight: height)
            .contentShape(shape)
            .ojGlass(prominent ? .primaryAction : .toolbarControl, in: shape,
                     tint: prominent ? theme.accentColor : nil, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Groups neighbouring glass shapes so they blend and morph together
/// (`GlassEffectContainer`); a plain pass-through before macOS 26.
struct OJGlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *), GlassSupport.usesGlass(.toolbarControl) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

@available(macOS 26.0, *)
private struct OJGlassEffect<S: Shape>: ViewModifier {
    let surface: GlassSurface
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let theme = ThemeManager.shared

    func body(content: Content) -> some View {
        let strength = GlassPolicy.tintOpacity(for: surface, reduceTransparency: reduceTransparency)
        let wash: Color? = tint.map { strength >= 1 ? $0 : $0.opacity(strength) }
        var glass = Glass.regular.tint(strength > 0 ? wash : nil)
        if interactive { glass = glass.interactive() }
        return content
            .glassEffect(glass, in: shape)
            .overlay {
                if GlassPolicy.drawsContrastBorder(on: surface, increaseContrast: contrast == .increased) {
                    shape.stroke(theme.titleTextColor.opacity(0.35), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}
