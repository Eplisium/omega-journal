import SwiftUI
import OmegaJournalCore

// MARK: - Detail Pane
//
// The Journal workspace's right-hand column: editor, entry reader, and empty
// states. Calendar and Insights live in their own full-width workspaces.

struct DetailView: View {
    var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    private let theme = ThemeManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            theme.backgroundColor.ignoresSafeArea()

            // Toasts are drawn by the window (`WindowToastHost` in
            // ContentView), so they also show outside the Journal workspace.
            content
        }
        .animation(OmegaTheme.Motion.standard.animation(reduceMotion: reduceMotion), value: vm.selectedEntryId)
        .animation(OmegaTheme.Motion.standard.animation(reduceMotion: reduceMotion), value: vm.editingEntryId)
    }

    @ViewBuilder
    private var content: some View {
        if let entry = vm.editingEntry {
            EditorView(vm: vm, entry: entry)
                .id(entry.id)
        } else if let entry = vm.selectedEntry {
            ReadView(vm: vm, entry: entry, isTrash: selection == .trash)
                .id(entry.id)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
        } else {
            welcomeScreen
        }
    }


    // MARK: Welcome

    private var welcomeScreen: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 30)

                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [theme.accentColor.opacity(0.35), theme.accentColor.opacity(0.08)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(width: 74, height: 74)
                        Text("Ω")
                            .font(OmegaTheme.font(.bodyLarge, .light, design: .serif))
                            .foregroundColor(theme.accentColor)
                    }

                    Text(greeting)
                        .font(OmegaTheme.font(.caption, .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor)

                    Text(vm.entries.isEmpty
                         ? "Your journal is empty. Let's change that."
                         : vm.streakSummary.current > 0
                            ? "\(vm.entries.count) entries · \(StreakCopy.streakLine(vm.streakSummary))"
                            : "Pick an entry to read, or start something new.")
                        .font(OmegaTheme.font(.caption))
                        .foregroundColor(theme.secondaryTextColor)
                }

                // Today's prompt
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(OmegaTheme.font(.meta))
                            .foregroundColor(theme.accentColor)
                        Text("TODAY'S PROMPT")
                            .font(OmegaTheme.font(.meta, .semibold))
                            .tracking(0.7)
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    Text(PromptGenerator.today())
                        .font(OmegaTheme.font(.bodyLarge, .medium, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button { vm.createEntryFromPrompt() } label: {
                            Text("Write about this")
                                .font(OmegaTheme.font(.meta, .medium))
                                .foregroundColor(theme.onAccentColor)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(theme.accentColor))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .frame(maxWidth: 480, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.cardColor.opacity(0.5))
                )

                // Quick actions
                HStack(spacing: 10) {
                    quickAction("square.and.pencil", "New Entry", "⌘N") { vm.createEntry() }
                    quickAction("doc.badge.plus", "Template", "⇧⌘N") {
                        NotificationCenter.default.post(name: .newFromTemplate, object: nil)
                    }
                    quickAction("command", "Commands", "⌘K") { vm.showCommandPalette = true }
                    quickAction("calendar", "Calendar", "⌘3") { selection = .calendar }
                }

                // On this day
                if !vm.entries.isEmpty && !vm.reflectiveOnThisDay.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(OmegaTheme.font(.meta))
                                .foregroundColor(theme.accentColor)
                            Text("ON THIS DAY")
                                .font(OmegaTheme.font(.meta, .semibold))
                                .tracking(0.7)
                                .foregroundColor(theme.secondaryTextColor)
                        }
                        ForEach(vm.reflectiveOnThisDay.prefix(3)) { entry in
                            Button { vm.select(entry) } label: {
                                HStack(spacing: 8) {
                                    Text(entry.mood.face).font(OmegaTheme.font(.body))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.displayTitle)
                                            .font(OmegaTheme.font(.caption, .medium))
                                            .foregroundColor(theme.titleTextColor)
                                            .lineLimit(1)
                                        Text(entry.createdAt.formatted(.dateTime.year()))
                                            .font(OmegaTheme.font(.meta))
                                            .foregroundColor(theme.secondaryTextColor)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(OmegaTheme.font(.meta))
                                        .foregroundColor(theme.secondaryTextColor)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 7).fill(theme.cardColor.opacity(0.4)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 480, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.cardColor.opacity(0.5))
                    )
                }

                Spacer(minLength: 30)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .scrollContentBackground(.hidden)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Still awake?"
        }
    }

    private func quickAction(_ icon: String, _ label: String, _ shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(OmegaTheme.font(.bodyLarge, .light))
                    .foregroundColor(theme.accentColor)
                Text(label)
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(theme.bodyTextColor)
                Text(shortcut)
                    .font(OmegaTheme.font(.meta, design: .rounded))
                    .foregroundColor(theme.secondaryTextColor)
            }
            .frame(width: 84, height: 68)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.cardColor.opacity(0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
