import SwiftUI
import OmegaJournalCore

/// Backlinks + unlinked mentions under an entry in the reader. Hidden entries never appear while locked
/// (the view model's pool already excludes them); their snippets are never built.
///
/// Quiet by default: the "Linked from" list shows only when something links
/// here, unlinked mentions are one small link (only when there are some), and
/// the graph stays one click away.
struct BacklinksPanel: View {
    var vm: JournalViewModel
    let entry: JournalEntry
    var onShowGraph: () -> Void

    private let theme = ThemeManager.shared
    @State private var showMentions = false
    /// Unlinked mentions, computed off the first frame (scans every body).
    @State private var mentions: [JournalEntry]?

    /// Recompute mentions when the entry, its title or the hidden lock changes.
    private struct MentionKey: Equatable {
        let id: String
        let title: String
        let hiddenLocked: Bool
    }

    private var hasTitle: Bool { !entry.title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let backlinks = vm.backlinks(for: entry)
        let presentation = UIBacklinksPresentation(backlinkCount: backlinks.count,
                                                   mentionCount: mentions?.count, hasTitle: hasTitle)
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.s) {
            Divider().opacity(0.15)
                .padding(.bottom, OmegaTheme.Spacing.xs)
            if presentation.showsLinkedFrom {
                Text(presentation.linkedFromHeading)
                    .font(OmegaTheme.font(.meta, .semibold))
                    .foregroundColor(theme.secondaryTextColor)
                    .accessibilityAddTraits(.isHeader)
                ForEach(backlinks) { other in linkRow(other, action: nil) }
            }

            if showMentions, let mentions, !mentions.isEmpty {
                Text("Mentioned without a link")
                    .font(OmegaTheme.font(.meta, .semibold))
                    .foregroundColor(theme.secondaryTextColor)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, presentation.showsLinkedFrom ? OmegaTheme.Spacing.s : 0)
                ForEach(mentions) { other in
                    linkRow(other, action: ("Link it", { link(other) }))
                }
            }

            footer(presentation)
        }
        .task(id: MentionKey(id: entry.id, title: entry.title, hiddenLocked: vm.hiddenLocked)) {
            mentions = nil
            showMentions = false
            guard hasTitle else { return }
            // Let the reader draw first; the scan reads every entry's body.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            mentions = vm.unlinkedMentions(for: entry)
        }
    }

    /// Links the first plain mention in `other`, then refreshes the list.
    private func link(_ other: JournalEntry) {
        vm.linkMention(in: other, to: entry)
        mentions = vm.unlinkedMentions(for: entry)
    }

    /// One quiet line: the mentions link (only when there are some) and Graph.
    private func footer(_ presentation: UIBacklinksPresentation) -> some View {
        HStack(spacing: OmegaTheme.Spacing.m) {
            if let title = presentation.mentionsLinkTitle {
                Button {
                    withAnimation(OmegaTheme.Motion.quick.animation(reduceMotion: OmegaTheme.reduceMotionEnabled)) {
                        showMentions.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showMentions ? 90 : 0))
                            .font(OmegaTheme.font(.meta, .semibold))
                        Text(title).font(OmegaTheme.font(.meta, .medium))
                    }
                    .foregroundColor(theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(showMentions ? "expanded" : "collapsed")
                .help("Entries that mention this title without linking to it")
            }
            Spacer(minLength: 0)
            Button(action: onShowGraph) {
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open link graph")
            .help("See how your entries link together")
        }
        .padding(.top, OmegaTheme.Spacing.xs)
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
