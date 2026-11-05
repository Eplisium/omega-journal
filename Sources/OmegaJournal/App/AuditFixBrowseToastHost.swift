import SwiftUI
import OmegaJournalCore

// MARK: - Toast host
//
// `vm.toast` used to be drawn only by DetailView, which exists only in the
// Journal workspace. On Today, Calendar, Insights and On This Day, export and
// import results, errors, Undo and "Hidden entries locked" never appeared, and
// Settings toasted into the pane its own sheet was covering. Now the window
// hosts the toast once (ContentView), and a sheet that covers the window
// (Settings, the tag manager) hosts it as well. `ToastHostStack` lets only the
// frontmost of a window's hosts draw, so a toast never shows twice.

/// Which of a window's toast hosts draws `vm.toast`: the one shown last. Keyed
/// by view model, so each window (each has its own model) is independent.
@MainActor
@Observable
final class ToastHostStack {
    static let shared = ToastHostStack()

    private var hosts: [ObjectIdentifier: [UUID]] = [:]

    func push(_ host: UUID, owner: ObjectIdentifier) {
        var list = hosts[owner, default: []]
        list.removeAll { $0 == host }
        list.append(host)
        hosts[owner] = list
    }

    func remove(_ host: UUID, owner: ObjectIdentifier) {
        guard var list = hosts[owner] else { return }
        list.removeAll { $0 == host }
        hosts[owner] = list.isEmpty ? nil : list
    }

    func isFrontmost(_ host: UUID, owner: ObjectIdentifier) -> Bool {
        hosts[owner]?.last == host
    }
}

/// Draws the view model's toast at the top of the view it modifies, while it
/// is the frontmost host for that view model.
struct WindowToastHost: ViewModifier {
    var vm: JournalViewModel
    @State private var hostID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let stack = ToastHostStack.shared

    func body(content: Content) -> some View {
        let owner = ObjectIdentifier(vm)
        content
            .overlay(alignment: .top) {
                // The animation is scoped to the toast layer; on the whole
                // window it would also animate whatever changed alongside it.
                ZStack(alignment: .top) {
                    if stack.isFrontmost(hostID, owner: owner), let toast = vm.toast {
                        ToastView(toast: toast) { Self.handleAction(toast, vm: vm) }
                            .padding(.top, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: vm.toast)
            }
            .onAppear { stack.push(hostID, owner: owner) }
            .onDisappear { stack.remove(hostID, owner: owner) }
    }

    /// The toast's button: runs Undo when the toast carries an action, then
    /// dismisses it. Undo reports what it restored in a toast of its own,
    /// which stays up.
    static func handleAction(_ toast: JournalViewModel.Toast, vm: JournalViewModel) {
        if toast.actionLabel != nil { vm.performUndo() }
        if vm.toast == toast { vm.toast = nil }
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: JournalViewModel.Toast
    let onAction: () -> Void
    private let theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(OmegaTheme.font(.caption))
                .foregroundColor(toast.isError ? .orange : .green)
            Text(toast.message)
                .font(OmegaTheme.font(.caption, .medium))
                .foregroundColor(theme.titleTextColor)
            if let label = toast.actionLabel {
                Button(label, action: onAction)
                    .buttonStyle(.plain)
                    .font(OmegaTheme.font(.meta, .semibold))
                    .foregroundColor(theme.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .ojGlass(.floatingPanel, in: Capsule(), tint: theme.accentColor) { toast in
            toast
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
}
