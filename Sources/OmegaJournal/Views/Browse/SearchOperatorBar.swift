import SwiftUI
import OmegaJournalCore

/// Operator chips (tag:/mood:/before:/after:/has:image) and recent searches under the search field.
struct SearchOperatorBar: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared

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
        .padding(.bottom, 4)
    }

    private func append(_ op: String) {
        var t = vm.searchText
        if !t.isEmpty && !t.hasSuffix(" ") { t += " " }
        vm.searchText = t + op
        vm.searchTextChanged()
    }
}
