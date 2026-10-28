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
    /// Signals that `QuickCaptureInbox` has new items. The payload lives in the
    /// inbox, not in `userInfo`, so a capture made before any journal window
    /// exists (launch gate still waiting for the key) is not dropped.
    static let quickCapture = Notification.Name("OmegaJournal.quickCapture")
}

/// One menu-bar capture waiting to be saved by the journal's view model.
struct QuickCaptureItem: Equatable {
    var body: String
    var mood: Mood
    var tags: [String]
}

/// In-memory hand-off between the menu-bar popover and the journal window.
///
/// The popover can be used before `LaunchGateView` has adopted the encryption
/// key and built `ContentView`, and it must never touch the database itself.
/// Captures queue here; ContentView drains the queue when it appears and on
/// every `.quickCapture` signal, so nothing typed is lost and multiple windows
/// never save the same capture twice.
@MainActor
enum QuickCaptureInbox {
    private static var items: [QuickCaptureItem] = []

    static var pendingCount: Int { items.count }

    /// Queues a capture and pings any live journal window.
    static func submit(_ item: QuickCaptureItem) {
        items.append(item)
        NotificationCenter.default.post(name: .quickCapture, object: nil)
    }

    /// Hands every queued capture to the caller exactly once.
    static func drain() -> [QuickCaptureItem] {
        defer { items.removeAll() }
        return items
    }

    static func removeAll() { items.removeAll() }
}

/// Drives `MenuBarExtra(isInserted:)` for the quick-capture item.
///
/// Do NOT bind `isInserted` to an `@AppStorage` property on the `App` struct:
/// that makes the whole scene graph depend on UserDefaults, and window /
/// split-view frame autosave writes to UserDefaults on every layout pass. The
/// result was a launch-time feedback loop (App body → window layout → defaults
/// write → App body …) that pinned the main thread at 100% CPU before the
/// window ever appeared. This model publishes only when the one key it owns
/// actually changes value, and ignores redundant writes from SwiftUI.
///
/// `@Observable` setters notify even when the new value equals the old one,
/// so every write to `isInserted` below stays behind an equality guard.
@MainActor
@Observable
final class QuickCapturePresence {
    private(set) var isInserted: Bool

    @ObservationIgnored private let defaults: UserDefaults
    /// Read by `deinit`, which is nonisolated; set once in `init`.
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isInserted = Self.read(defaults)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFromDefaults() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    static func read(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: QuickCapture.insertedKey) as? Bool ?? true
    }

    /// Re-reads the setting; publishes only on a real change.
    func syncFromDefaults() {
        let value = Self.read(defaults)
        if value != isInserted { isInserted = value }
    }

    /// Writes from SwiftUI (e.g. the user removing the item from the menu bar)
    /// are persisted only when they change the value.
    func set(_ value: Bool) {
        guard value != isInserted else { return }
        isInserted = value
        defaults.set(value, forKey: QuickCapture.insertedKey)
    }

    var binding: Binding<Bool> {
        Binding(get: { [unowned self] in isInserted }, set: { [unowned self] in set($0) })
    }
}

/// Small popover for the menu-bar extra. It never touches the database itself:
/// it queues into `QuickCaptureInbox`, and ContentView's view model saves the
/// entry through the normal `createEntry` path once the journal is open.
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
        QuickCaptureInbox.submit(QuickCaptureItem(body: body, mood: mood, tags: QuickCapture.tags(from: tagText)))
        text = ""
        tagText = ""
    }
}
