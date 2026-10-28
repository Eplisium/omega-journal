import SwiftUI
import WidgetKit
import OmegaJournalShared

// MARK: - Palette

/// Omega Journal's default purple theme (ThemeManager defaults: accent
/// #9d6bff, background #1a0d2e, card #241245). Fixed, because the widget
/// cannot read the app's settings database.
public enum OmegaWidgetPalette {
    public static let accent = Color(red: 0x9d / 255, green: 0x6b / 255, blue: 0xff / 255)
    public static let accentSoft = Color(red: 0xc9 / 255, green: 0xb0 / 255, blue: 0xff / 255)
    public static let backgroundTop = Color(red: 0x2e / 255, green: 0x17 / 255, blue: 0x5a / 255)
    public static let backgroundBottom = Color(red: 0x14 / 255, green: 0x08 / 255, blue: 0x23 / 255)
    public static let track = Color.white.opacity(0.12)
    public static let streak = Color(red: 1.0, green: 0.62, blue: 0.32)
    public static let success = Color(red: 0x4a / 255, green: 0xde / 255, blue: 0x80 / 255)
}

/// Gradient + soft accent glow behind both widget sizes.
public struct OmegaWidgetBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(colors: [OmegaWidgetPalette.backgroundTop, OmegaWidgetPalette.backgroundBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [OmegaWidgetPalette.accent.opacity(0.35), .clear],
                           center: .topTrailing, startRadius: 4, endRadius: 170)
        }
    }
}

// MARK: - Building blocks

/// Progress ring with today's word count in the middle.
struct WordRing: View {
    let state: WidgetDisplayState
    var lineWidth: CGFloat = 9
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var fullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        ZStack {
            Circle()
                .stroke(fullColor ? OmegaWidgetPalette.track : Color.primary.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, state.progress))
                .stroke(ringStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            VStack(spacing: 0) {
                if state.goalMet {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(fullColor ? OmegaWidgetPalette.success : Color.primary)
                }
                Text(state.words, format: .number)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(fullColor ? Color.white : Color.primary)
                Text("of \(state.goal)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(fullColor ? Color.white.opacity(0.6) : Color.secondary)
            }
            .padding(lineWidth + 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.words) of \(state.goal) words today")
    }

    private var ringStyle: AnyShapeStyle {
        guard fullColor else { return AnyShapeStyle(Color.primary) }
        return AnyShapeStyle(AngularGradient(colors: [OmegaWidgetPalette.accentSoft, OmegaWidgetPalette.accent,
                                                      OmegaWidgetPalette.accentSoft],
                                             center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
    }
}

/// Flame + "6 days".
struct StreakLabel: View {
    let state: WidgetDisplayState
    var compact = false
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let fullColor = renderingMode == .fullColor
        HStack(spacing: 4) {
            Image(systemName: state.streak > 0 ? "flame.fill" : "flame")
                .foregroundStyle(fullColor ? OmegaWidgetPalette.streak : Color.primary)
                .widgetAccentable()
            Text(state.streak > 0 ? state.streakText : "No streak yet")
                .foregroundStyle(fullColor ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: compact ? 12 : 13, weight: .semibold, design: .rounded))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.streak > 0 ? "Streak \(state.streakText)" : "No streak yet")
    }
}

struct LastWrittenLabel: View {
    let state: WidgetDisplayState
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
            Text(state.hasData ? "Last entry · \(state.lastWrittenText)" : state.lastWrittenText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(renderingMode == .fullColor ? Color.white.opacity(0.62) : Color.secondary)
    }
}

/// App mark used in the medium header.
struct OmegaMark: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(renderingMode == .fullColor ? OmegaWidgetPalette.accentSoft : Color.primary)
                .widgetAccentable()
            Text("Omega Journal")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(renderingMode == .fullColor ? Color.white.opacity(0.75) : Color.secondary)
        }
    }
}

// MARK: - Small

/// Small widget: streak, word ring, last written.
public struct OmegaSmallWidgetView: View {
    let state: WidgetDisplayState

    public init(state: WidgetDisplayState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StreakLabel(state: state, compact: true)
            WordRing(state: state, lineWidth: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            LastWrittenLabel(state: state)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Medium

/// Medium widget: ring on the left; streak, today's prompt and a New Entry
/// link on the right.
public struct OmegaMediumWidgetView: View {
    let state: WidgetDisplayState
    let newEntryURL: URL
    let linksEnabled: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// `linksEnabled: false` draws the New Entry button without its `Link`
    /// (ImageRenderer cannot draw links; used for previews and tests).
    public init(state: WidgetDisplayState, newEntryURL: URL, linksEnabled: Bool = true) {
        self.state = state
        self.newEntryURL = newEntryURL
        self.linksEnabled = linksEnabled
    }

    public var body: some View {
        let fullColor = renderingMode == .fullColor
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 6) {
                WordRing(state: state, lineWidth: 9)
                    .frame(width: 96, height: 96)
                Text(state.goalMet ? "Goal reached" : "words today")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(fullColor ? Color.white.opacity(0.6) : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    OmegaMark()
                    Spacer(minLength: 4)
                    StreakLabel(state: state, compact: true)
                }
                Text("TODAY'S PROMPT")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(fullColor ? OmegaWidgetPalette.accentSoft : Color.secondary)
                    .padding(.top, 2)
                Text(state.prompt)
                    .font(.system(size: 13, weight: .medium, design: .serif))
                    .foregroundStyle(fullColor ? Color.white : Color.primary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(alignment: .center) {
                    LastWrittenLabel(state: state)
                    Spacer(minLength: 4)
                    if linksEnabled {
                        Link(destination: newEntryURL) { newEntryButton(fullColor: fullColor) }
                            .accessibilityLabel("New journal entry")
                    } else {
                        newEntryButton(fullColor: fullColor)
                    }
                }
            }
        }
    }
}

extension OmegaMediumWidgetView {
    fileprivate func newEntryButton(fullColor: Bool) -> some View {
        Label("New Entry", systemImage: "square.and.pencil")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(fullColor ? Color.white : Color.primary)
            .background(Capsule().fill(fullColor ? OmegaWidgetPalette.accent.opacity(0.85)
                                                 : Color.primary.opacity(0.12)))
    }
}

// MARK: - Preview frame (tests, screenshots)

/// Draws a widget the way the desktop does (background + rounded corners) so
/// it can be rendered with ImageRenderer outside WidgetKit.
public struct OmegaWidgetPreviewFrame<Content: View>: View {
    public static var smallSize: CGSize { CGSize(width: 170, height: 170) }
    public static var mediumSize: CGSize { CGSize(width: 364, height: 170) }

    let size: CGSize
    let content: Content

    public init(size: CGSize, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }

    public var body: some View {
        content
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(OmegaWidgetBackground())
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}
