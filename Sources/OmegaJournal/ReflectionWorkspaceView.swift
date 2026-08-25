import SwiftUI

// MARK: - Full-width reflective workspaces

/// Hosts destinations that should never compete with the Journal collection
/// column. The Journal workspace remains the single dedicated list/detail flow.
struct ReflectionWorkspaceView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?

    var body: some View {
        Group {
            switch selection {
            case .calendar:
                CalendarView(vm: vm)
            case .insights:
                InsightsView(vm: vm)
            case .onThisDay:
                OnThisDayView(vm: vm, onOpenEntry: openJournalEntry)
            case .today, .none:
                today
            default:
                today
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var today: some View {
        TodayView(
            vm: vm,
            openJournal: { selection = .all },
            openCalendar: { selection = .calendar },
            openInsights: { selection = .insights },
            openEntry: openJournalEntry
        )
    }

    private func openJournalEntry(_ entry: JournalEntry) {
        selection = .all
        vm.select(entry)
    }
}
