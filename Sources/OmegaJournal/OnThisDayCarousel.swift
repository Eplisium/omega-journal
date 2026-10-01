import SwiftUI
import OmegaJournalCore

// MARK: - On This Day v2

/// Multi-year memory carousel ("1 year ago", "2 years ago"…). Hidden entries are masked
/// (only appear when the privacy scope and biometric session allow, via `vm.calendarEntries`).
/// Embed standalone: `OnThisDayCarousel(vm: vm, onOpenEntry: …)`. Renders nothing when empty
/// unless `showWhenEmpty` is set.
struct OnThisDayCarousel: View {
    @ObservedObject var vm: JournalViewModel
    var showWhenEmpty = false
    let onOpenEntry: (JournalEntry) -> Void
    @ObservedObject private var theme = ThemeManager.shared

    private var groups: [OnThisDayYear<JournalEntry>] { vm.onThisDayByYear }

    static func yearsAgoLabel(_ years: Int) -> String {
        years == 1 ? "A year ago" : "\(years) years ago"
    }

    var body: some View {
        if groups.isEmpty {
            if showWhenEmpty {
                OmegaCard {
                    OmegaSectionHeader(title: "On this day", subtitle: "Nothing from past years yet", systemImage: "clock.arrow.circlepath")
                }
            }
        } else {
            let thisYear = Calendar.current.component(.year, from: Date())
            OmegaCard {
                VStack(alignment: .leading, spacing: OmegaTheme.Spacing.m) {
                    OmegaSectionHeader(title: "On this day", subtitle: "\(groups.reduce(0) { $0 + $1.items.count }) memories across \(groups.count) \(groups.count == 1 ? "year" : "years")",
                                       systemImage: "clock.arrow.circlepath")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: OmegaTheme.Spacing.m) {
                            ForEach(groups, id: \.year) { group in
                                ForEach(group.items) { entry in
                                    memory(entry, label: Self.yearsAgoLabel(thisYear - group.year), year: group.year)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func memory(_ entry: JournalEntry, label: String, year: Int) -> some View {
        Button { onOpenEntry(entry) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label).font(OmegaTheme.font(.meta, .semibold)).foregroundColor(theme.accentColor)
                    Spacer()
                    Text(String(year)).font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                }
                Text(entry.displayTitle)
                    .font(OmegaTheme.serifTitleFont)
                    .foregroundColor(theme.titleTextColor)
                    .lineLimit(2)
                Text(entry.isHidden ? "Hidden entry" : entry.preview)
                    .font(OmegaTheme.captionFont)
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(4)
                Spacer(minLength: 0)
                Text("\(entry.mood.emoji) \(entry.mood.label)")
                    .font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
            }
            .padding(OmegaTheme.Spacing.m)
            .frame(width: 230, height: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: OmegaTheme.Radius.card, style: .continuous).fill(theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: OmegaTheme.Radius.card, style: .continuous).strokeBorder(theme.borderColor))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(entry.displayTitle)")
    }
}
