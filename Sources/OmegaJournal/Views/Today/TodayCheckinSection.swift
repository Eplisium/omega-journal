import SwiftUI
import OmegaJournalCore

// MARK: - Check-in on Today

/// Sleep, energy, stress, custom metrics and habits, folded into one quiet line
/// under today's writing. Opening it shows the check-in card and the habit strip;
/// the open/closed state is remembered. Hidden from Today with
/// Settings › Writing › Daily Check-in.
struct TodayCheckinSection: View {
    var store: CheckinStore = .shared
    /// The page clock (`TodayView`'s rollover schedule), so the line resets at midnight.
    var now: Date = Date()

    @AppStorage(TodayCheckinPrefs.expandedKey) private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let theme = ThemeManager.shared

    var body: some View {
        let summary = store.summary(day: CheckinStore.todayKey(now))
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(OmegaTheme.Motion.quick.animation(reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "heart.text.square")
                        .font(OmegaTheme.font(.body, .semibold))
                        .foregroundColor(theme.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily check-in")
                            .font(OmegaTheme.font(.caption, .semibold))
                            .foregroundColor(theme.titleTextColor)
                        Text(summary.text)
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    Spacer(minLength: 8)
                    if summary.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.accentColor)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.right")
                        .font(OmegaTheme.font(.meta, .semibold))
                        .foregroundColor(theme.secondaryTextColor)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.cardColor.opacity(0.42)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .omegaTooltip(expanded ? "Fold the check-in away" : "Log sleep, energy, stress and habits")
            .accessibilityLabel("Daily check-in")
            .accessibilityValue(summary.text + (summary.isComplete ? ", all done" : ""))
            .accessibilityHint(expanded ? "Collapses the check-in" : "Shows sleep, energy, stress and habits for today")
            .accessibilityAddTraits(expanded ? .isSelected : [])

            if expanded {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        CheckinCard(store: store).frame(minWidth: 380, maxWidth: .infinity)
                        HabitStrip(store: store).frame(minWidth: 260, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        CheckinCard(store: store)
                        HabitStrip(store: store)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}
