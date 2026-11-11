import SwiftUI
import OmegaJournalCore

/// Operator chips (tag:/mood:/before:/after:/has:image) and recent searches under the search field.
///
/// `floating`: drawn as an overlay strip on top of the list (with its own
/// background and a hairline) so showing it never moves the rows beneath.
struct SearchOperatorBar: View {
    var vm: JournalViewModel
    var floating = false
    private let theme = ThemeManager.shared

    private let inserts = ["tag:", "mood:", "before:", "after:", "has:image"]
    @State private var showTips = false

    var body: some View {
        let empty = vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(inserts, id: \.self) { op in
                        OmegaChip(title: op) { append(op) }
                            .accessibilityLabel("Add \(op) filter")
                    }
                    OmegaChip(title: "Tips", systemImage: "questionmark.circle") { showTips.toggle() }
                        .accessibilityLabel("Search tips")
                        .help("How to search: phrases, exclusions and filters")
                        .popover(isPresented: $showTips, arrowEdge: .bottom) { SearchTipsView() }
                    if empty {
                        ForEach(vm.recentSearches, id: \.self) { q in
                            OmegaChip(title: q, systemImage: "clock") { vm.searchText = q; vm.searchTextChanged() }
                                .accessibilityLabel("Recent search \(q)")
                        }
                        if !vm.recentSearches.isEmpty {
                            OmegaChip(title: "Clear", systemImage: "xmark") { vm.clearRecentSearches() }
                                .accessibilityLabel("Clear recent searches")
                        }
                    }
                }
                .padding(.horizontal, OmegaTheme.Spacing.m)
            }
        }
        .padding(.top, floating ? 6 : 0)
        .padding(.bottom, floating ? 6 : 4)
        .background {
            if floating && !GlassSupport.usesGlass(.floatingPanel) {
                theme.backgroundColor
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 6, y: 3)
            }
        }
        // macOS 26: the floating strip is a glass panel inset over the list.
        .modifier(FloatingGlassStrip(enabled: floating, tint: theme.accentColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search operators")
    }

    private func append(_ op: String) {
        var t = vm.searchText
        if !t.isEmpty && !t.hasSuffix(" ") { t += " " }
        vm.searchText = t + op
        vm.searchTextChanged()
    }
}

/// The search grammar in one glance (`SearchQuery`). Same rules in the list,
/// Archive / Hidden / Trash, the command palette and smart folders.
struct SearchTipsView: View {
    private let theme = ThemeManager.shared

    static let tips: [(syntax: String, meaning: String)] = [
        ("rain walk", "Entries with every word, in any order"),
        ("\"rainy walk\"", "That exact phrase"),
        ("-work", "Leave out entries that mention it"),
        ("-\"day job\"", "Leave out an exact phrase"),
        ("tag:travel  #travel", "Tagged travel (or travel/…)"),
        ("mood:good", "By mood name or 1–5"),
        ("after:2026-01  before:today", "By date: day, month, year, today, yesterday"),
        ("has:image", "Also has:attachment, has:link, has:task"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search tips")
                .font(OmegaTheme.font(.caption, .semibold))
                .foregroundColor(theme.titleTextColor)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Self.tips, id: \.syntax) { tip in
                    GridRow {
                        Text(tip.syntax)
                            .font(OmegaTheme.font(.meta, design: .monospaced))
                            .foregroundColor(theme.accentColor)
                            .textSelection(.enabled)
                        Text(tip.meaning)
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.bodyTextColor)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Hidden entries match on their title only while they're locked.")
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
    }
}

/// Floating search helper as an inset glass panel (macOS 26 only).
private struct FloatingGlassStrip: ViewModifier {
    let enabled: Bool
    let tint: Color

    func body(content: Content) -> some View {
        if enabled && GlassSupport.usesGlass(.floatingPanel) {
            content
                .ojGlass(.floatingPanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous), tint: tint)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        } else {
            content
        }
    }
}
