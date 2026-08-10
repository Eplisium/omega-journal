import SwiftUI

// MARK: - Content View

struct ContentView: View {
    @StateObject private var vm = JournalViewModel()
    @ObservedObject private var theme = ThemeManager.shared
    @State private var sidebarSelection: SidebarItem? = .all

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm, selection: $sidebarSelection)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { vm.createEntry() } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .help("New Entry (⌘N)")
                    }
                }
        } content: {
            EntryListView(vm: vm, selection: $sidebarSelection)
        } detail: {
            DetailView(vm: vm, selection: $sidebarSelection)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(theme.accentColor)
        .preferredColorScheme(theme.colorScheme)
        .background(theme.backgroundColor)
        .onAppear { _ = ThemeManager.shared }
    }
}

// MARK: - Sidebar Item

enum SidebarItem: Hashable {
    case all, favorites, thisWeek, mood(Mood), insights, onThisDay, tag(String)
}
