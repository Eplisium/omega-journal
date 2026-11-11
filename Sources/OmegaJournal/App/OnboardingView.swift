import SwiftUI
import OmegaJournalCore

// MARK: - First-run tour & What's new

@MainActor
@Observable
final class OnboardingState {
    static let completedKey = "onboarding.completed"
    static let lastSeenVersionKey = "onboarding.lastSeenVersion"
    /// Revision of the highlights in `WhatsNewView`, compared against what the user last saw.
    /// Bump it whenever the highlights change. It is an internal counter, not the app version
    /// (1.x builds already stored "2.0", so it only ever moves up from there).
    static let whatsNewVersion = "2.3"

    var isPresentingTour = false
    var isPresentingWhatsNew = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hasCompleted: Bool { defaults.bool(forKey: Self.completedKey) }

    /// First launch → the tour. Returning users → "What's new" once per newer version.
    /// A user who already has entries but never saw the tour is treated as returning (no tour).
    func evaluateOnLaunch(hasEntries: Bool) {
        if !hasCompleted {
            if hasEntries {
                defaults.set(true, forKey: Self.completedKey)
                defaults.set(Self.whatsNewVersion, forKey: Self.lastSeenVersionKey)
                isPresentingWhatsNew = true
            } else {
                isPresentingTour = true
            }
            return
        }
        if ReleaseNotes.shouldShowWhatsNew(lastSeenVersion: defaults.string(forKey: Self.lastSeenVersionKey),
                                           current: Self.whatsNewVersion, hasCompletedOnboarding: true) {
            isPresentingWhatsNew = true
        }
    }

    func completeTour() {
        defaults.set(true, forKey: Self.completedKey)
        defaults.set(Self.whatsNewVersion, forKey: Self.lastSeenVersionKey)
        isPresentingTour = false
    }

    func dismissWhatsNew() {
        defaults.set(Self.whatsNewVersion, forKey: Self.lastSeenVersionKey)
        isPresentingWhatsNew = false
    }
}

struct OnboardingTourView: View {
    var onboarding: OnboardingState
    var onStartWriting: () -> Void

    private let theme = ThemeManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private struct Card { let icon: String; let title: String; let message: String }
    private let cards = [
        Card(icon: "lock.shield", title: "Private by design",
             message: "Everything stays on this Mac. Entry bodies are encrypted, and hidden entries need Touch ID or your password to read."),
        Card(icon: "square.and.pencil", title: "Write without friction",
             message: "Markdown, templates, tags and moods. ⌘N starts an entry, ⌥⌘J starts one from anywhere, and ⌘K finds anything."),
        Card(icon: "point.3.connected.trianglepath.dotted", title: "Organize your way",
             message: "Notebooks, nested tags, smart folders and [[links]] between entries — then reflect with the calendar and insights."),
    ]

    var body: some View {
        VStack(spacing: OmegaTheme.Spacing.xl) {
            OmegaEmptyState(systemImage: cards[page].icon, title: cards[page].title, message: cards[page].message)
                .id(page)
                .transition(reduceMotion ? .identity : .opacity)
            HStack(spacing: 6) {
                ForEach(cards.indices, id: \.self) { i in
                    Circle().fill(i == page ? theme.accentColor : theme.secondaryTextColor.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(page + 1) of \(cards.count)")
            HStack {
                Button("Skip") { onboarding.completeTour() }
                    .buttonStyle(.plain).foregroundColor(theme.secondaryTextColor)
                Spacer()
                if page > 0 { Button("Back") { go(page - 1) } }
                if page < cards.count - 1 {
                    Button("Next") { go(page + 1) }.buttonStyle(.borderedProminent).tint(theme.accentColor)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Write my first entry") { onboarding.completeTour(); onStartWriting() }
                        .buttonStyle(.borderedProminent).tint(theme.accentColor)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .font(OmegaTheme.font(.body))
        }
        .padding(OmegaTheme.Spacing.xl)
        .frame(width: 480, height: 420)
        .background(theme.backgroundColor)
        .accessibilityAddTraits(.isModal)
    }

    private func go(_ i: Int) {
        withAnimation(OmegaTheme.Motion.standard.animation(reduceMotion: reduceMotion)) { page = i }
    }
}

struct WhatsNewView: View {
    var onboarding: OnboardingState
    private let theme = ThemeManager.shared

    static let items: [(String, String, String)] = [
        ("sun.max", "A calmer Today", "Today's prompt and your writing come first; the rest stays quiet below."),
        ("textformat.size", "Text size", "Make the whole app larger or smaller in Settings › Appearance."),
        ("gearshape", "A proper Settings window", "⌘, opens Settings in its own window, one pane per area."),
        ("command", "Smarter command palette", "Best matches first, with the matching words highlighted. ⌘↩ edits an entry."),
        ("chart.bar", "Clearer Insights", "Fewer numbers, each with its unit, and charts with labelled axes."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.l) {
            Text("What's new in Omega Journal")
                .font(OmegaTheme.font(.title, .bold, design: .serif)).foregroundColor(theme.titleTextColor)
                .accessibilityAddTraits(.isHeader)
            ForEach(Self.items, id: \.1) { item in
                HStack(alignment: .top, spacing: OmegaTheme.Spacing.m) {
                    Image(systemName: item.0).font(OmegaTheme.font(.bodyLarge)).foregroundColor(theme.accentColor).frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1).font(OmegaTheme.font(.body, .semibold)).foregroundColor(theme.titleTextColor)
                        Text(item.2).font(OmegaTheme.font(.caption)).foregroundColor(theme.secondaryTextColor)
                    }
                }
            }
            HStack { Spacer(); Button("Got it") { onboarding.dismissWhatsNew() }
                .buttonStyle(.borderedProminent).tint(theme.accentColor).keyboardShortcut(.defaultAction) }
        }
        .padding(OmegaTheme.Spacing.xl)
        .frame(width: 460)
        .background(theme.backgroundColor)
    }
}
