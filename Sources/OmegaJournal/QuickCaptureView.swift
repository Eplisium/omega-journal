import SwiftUI
import OmegaJournalCore

/// Pure helpers for menu-bar quick capture (unit-tested).
enum QuickCapture {
    static let notificationKey = "text"
    static let insertedKey = "shell.menuBarQuickCapture"
    static let tag = "quick"
    static let moodKey = "mood"
    static let tagsKey = "tags"

    /// Tags for a capture: always includes `quick`, plus any extra the user typed
    /// (comma/space separated, nested `a/b` allowed). De-duplicated, order preserved.
    static func tags(from raw: String) -> [String] {
        var out = [tag]
        for part in raw.split(whereSeparator: { $0 == "," || $0 == " " }) {
            if let t = TagPath.normalize(String(part)), !out.contains(t) { out.append(t) }
        }
        return out
    }

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
    @State private var mood: Mood = .neutral
    @State private var tagText = ""
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
            HStack(spacing: 4) {
                ForEach(Mood.allCases) { m in
                    Button { mood = m } label: {
                        Text(m.emoji).frame(width: 28, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(mood == m ? m.color.opacity(0.28) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mood: \(m.label)")
                    .accessibilityAddTraits(mood == m ? .isSelected : [])
                }
            }
            TextField("Extra tags (optional)", text: $tagText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Extra tags")
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
                                        userInfo: [QuickCapture.notificationKey: body,
                                                   QuickCapture.moodKey: mood.rawValue,
                                                   QuickCapture.tagsKey: QuickCapture.tags(from: tagText)])
        text = ""
        tagText = ""
    }
}
