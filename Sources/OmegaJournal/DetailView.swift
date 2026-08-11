import SwiftUI

// MARK: - Detail Pane
//
// Routes the right-hand column between: editor, entry reader, calendar, insights,
// and the various empty states — plus the toast overlay.

struct DetailView: View {
    @ObservedObject var vm: JournalViewModel
    @Binding var selection: SidebarItem?
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack(alignment: .top) {
            theme.backgroundColor.ignoresSafeArea()

            content

            if let toast = vm.toast {
                ToastView(toast: toast) {
                    if toast.actionLabel != nil { vm.performUndo() }
                    vm.toast = nil
                }
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(5)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: vm.toast)
    }

    @ViewBuilder
    private var content: some View {
        if let entry = vm.editingEntry {
            EditorView(vm: vm, entry: entry)
                .id(entry.id)
        } else if selection == .calendar {
            CalendarView(vm: vm)
        } else if selection == .insights {
            InsightsView(vm: vm)
        } else if let entry = vm.selectedEntry ?? trashOrArchiveSelection {
            ReadView(vm: vm, entry: entry, isTrash: selection == .trash)
                .id(entry.id)
        } else {
            welcomeScreen
        }
    }

    /// Trash, archive, and hidden entries live outside `vm.entries`, so resolve them separately.
    private var trashOrArchiveSelection: JournalEntry? {
        guard let id = vm.selectedEntryId else { return nil }
        return vm.trashedEntries.first { $0.id == id }
            ?? vm.archivedEntries.first { $0.id == id }
            ?? vm.hiddenEntries.first { $0.id == id }
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
                            .font(.system(size: 34, weight: .light, design: .serif))
                            .foregroundColor(theme.accentColor)
                    }

                    Text(greeting)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundColor(theme.titleTextColor)

                    Text(vm.entries.isEmpty
                         ? "Your journal is empty. Let's change that."
                         : "\(vm.entries.count) entries · \(vm.totalWordCount.formatted()) words · \(vm.writingStreak) day streak")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryTextColor)
                }

                // Today's prompt
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundColor(theme.accentColor)
                        Text("TODAY'S PROMPT")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.7)
                            .foregroundColor(theme.secondaryTextColor)
                    }
                    Text(PromptGenerator.today())
                        .font(.system(size: 15, weight: .medium, design: .serif))
                        .foregroundColor(theme.titleTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button { vm.createEntryFromPrompt() } label: {
                            Text("Write about this")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
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
                    quickAction("calendar", "Calendar", "⌘2") { selection = .calendar }
                }

                // On this day
                if !vm.onThisDay.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 10))
                                .foregroundColor(theme.accentColor)
                            Text("ON THIS DAY")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.7)
                                .foregroundColor(theme.secondaryTextColor)
                        }
                        ForEach(vm.onThisDay.prefix(3)) { entry in
                            Button { vm.select(entry) } label: {
                                HStack(spacing: 8) {
                                    Text(entry.mood.emoji).font(.system(size: 13))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.displayTitle)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(theme.titleTextColor)
                                            .lineLimit(1)
                                        Text(entry.createdAt.formatted(.dateTime.year()))
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.secondaryTextColor)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
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
                    .font(.system(size: 15, weight: .light))
                    .foregroundColor(theme.accentColor)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.bodyTextColor)
                Text(shortcut)
                    .font(.system(size: 8.5, design: .rounded))
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

// MARK: - Toast

private struct ToastView: View {
    let toast: JournalViewModel.Toast
    let onAction: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(toast.isError ? .orange : .green)
            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.titleTextColor)
            if let label = toast.actionLabel {
                Button(label, action: onAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(theme.cardColor)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        )
        .overlay(
            Capsule().strokeBorder(theme.accentColor.opacity(0.2), lineWidth: 1)
        )
    }
}
