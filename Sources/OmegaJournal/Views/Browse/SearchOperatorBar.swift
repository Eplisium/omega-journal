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

    var body: some View {
        let empty = vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(inserts, id: \.self) { op in
                        OmegaChip(title: op) { append(op) }
                            .accessibilityLabel("Add \(op) filter")
                    }
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
            if floating {
                theme.backgroundColor
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 6, y: 3)
            }
        }
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
