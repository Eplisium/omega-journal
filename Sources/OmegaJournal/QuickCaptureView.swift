import SwiftUI

/// Pure helpers for menu-bar quick capture (unit-tested).
enum QuickCapture {
    static let notificationKey = "text"
    static let insertedKey = "shell.menuBarQuickCapture"
    static let tag = "quick"

    /// Trimmed capture text, or nil when there is nothing worth saving.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Notification.Name {
    static let quickCapture = Notification.Name("OmegaJournal.quickCapture")
}

/// Small popover for the menu-bar extra. It never touches the database itself:
/// it posts `.quickCapture`, and ContentView's single view model saves the
/// entry through the normal `createEntry` path.
struct QuickCaptureView: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick capture")
                .font(OmegaTheme.font(.caption, .semibold))
            TextEditor(text: $text)
                .font(OmegaTheme.font(.body))
                .frame(width: 280, height: 110)
                .focused($focused)
                .accessibilityLabel("Quick capture text")
            HStack {
                Button("Open Journal") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(QuickCapture.normalized(text) == nil)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func save() {
        guard let body = QuickCapture.normalized(text) else { return }
        NotificationCenter.default.post(name: .quickCapture, object: nil,
                                        userInfo: [QuickCapture.notificationKey: body])
        text = ""
    }
}
