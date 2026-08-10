import SwiftUI

// MARK: - Detail View

struct DetailView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?

    var body: some View {
        Group {
            if selection == .insights {
                InsightsView(vm: vm)
            } else if selection == .onThisDay {
                OnThisDayView(vm: vm)
            } else if let eid = vm.editingEntryId, let entry = vm.entries.first(where: { $0.id == eid }) {
                EditorView(vm: vm, entry: entry)
            } else if let entry = vm.selectedEntry {
                ReadView(entry: entry, vm: vm)
            } else {
                EmptyDetail(vm: vm)
            }
        }
    }
}

// MARK: - Empty Detail

struct EmptyDetail: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.10))
                    .frame(width: 110, height: 110)
                Image(systemName: "book.pages")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(theme.accentColor.opacity(0.7))
            }

            VStack(spacing: 8) {
                Text("Select an entry or create a new one")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.secondary)
                Text("⌘N to start writing")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Divider()
                .frame(maxWidth: 280)

            VStack(spacing: 14) {
                Text("Today's prompt")
                    .font(OmegaTheme.headerFont)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text(PromptGenerator.today())
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)
                    .lineSpacing(3)
                    .frame(maxWidth: 380)
                Button { vm.createEntryFromPrompt() } label: {
                    Label("Write on this prompt", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Start a new entry pre-filled with today's prompt")
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            // Writing goals progress
            GoalProgressView()
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }
}

// MARK: - Goal Progress View

struct GoalProgressView: View {
    @ObservedObject private var goals = GoalManager.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 10) {
            Text("Today's Goals")
                .font(OmegaTheme.headerFont)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)

            HStack(spacing: 16) {
                ForEach(goals.goals.prefix(2)) { goal in
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .stroke(theme.cardColor.opacity(0.6), lineWidth: 4)
                                .frame(width: 44, height: 44)
                            Circle()
                                .trim(from: 0, to: goal.progress)
                                .stroke(goal.isComplete ? Color.green : theme.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .frame(width: 44, height: 44)
                                .rotationEffect(.degrees(-90))
                            if goal.isComplete {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.green)
                            }
                        }
                        Text(goal.displayProgress)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(goal.type.rawValue)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            }
        }
    }
}
