import SwiftUI
import OmegaJournalCore

/// Backlinks + unlinked mentions under an entry in the reader. Hidden entries never appear while locked
/// (the view model's pool already excludes them); their snippets are never built.
struct BacklinksPanel: View {
    @ObservedObject var vm: JournalViewModel
    let entry: JournalEntry
    var onShowGraph: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var showMentions = false

    var body: some View {
        let backlinks = vm.backlinks(for: entry)
        let mentions = showMentions ? vm.unlinkedMentions(for: entry) : []
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.s) {
            Divider().opacity(0.2)
            HStack {
                Text("LINKED FROM (\(backlinks.count))")
                    .font(OmegaTheme.font(.meta, .semibold)).tracking(0.7)
                    .foregroundColor(theme.secondaryTextColor)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onShowGraph) {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(OmegaTheme.font(.meta, .medium)).foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open link graph")
            }
            if backlinks.isEmpty {
                Text("No entries link here yet. Type [[\(entry.displayTitle)]] in another entry to connect them.")
                    .font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
            } else {
                ForEach(backlinks) { other in linkRow(other, action: nil) }
            }

            if !entry.title.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { withAnimation(OmegaTheme.Motion.quick.animation(reduceMotion: OmegaTheme.reduceMotionEnabled)) { showMentions.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(showMentions ? 90 : 0))
                            .font(OmegaTheme.font(.meta, .bold))
                        Text(showMentions ? "Unlinked mentions (\(mentions.count))" : "Show unlinked mentions")
                            .font(OmegaTheme.font(.meta, .medium))
                    }.foregroundColor(theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showMentions ? "expanded" : "collapsed")
                if showMentions {
                    if mentions.isEmpty {
                        Text("Nothing mentions this title without linking.").font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
                    }
                    ForEach(mentions) { other in
                        linkRow(other, action: ("Link it", { vm.linkMention(in: other, to: entry) }))
                    }
                }
            }
        }
    }

    private func linkRow(_ other: JournalEntry, action: (String, () -> Void)?) -> some View {
        HStack(spacing: OmegaTheme.Spacing.s) {
            Button { vm.select(other) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(other.displayTitle).font(OmegaTheme.font(.caption, .medium)).foregroundColor(theme.titleTextColor).lineLimit(1)
                    Text(other.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(other.displayTitle)")
            if let action {
                OmegaChip(title: action.0, systemImage: "link", tone: .accent, action: action.1)
            }
        }
        .padding(.horizontal, OmegaTheme.Spacing.m).padding(.vertical, OmegaTheme.Spacing.s)
        .background(RoundedRectangle(cornerRadius: OmegaTheme.Radius.control, style: .continuous).fill(theme.cardColor.opacity(0.4)))
    }
}
