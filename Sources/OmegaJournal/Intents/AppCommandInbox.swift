import SwiftUI
import OmegaJournalShared

// MARK: - Commands from outside the window

/// Something Shortcuts, Siri, Spotlight or a widget asked the app to do.
/// Never carries entry content out of the app; text only flows *in*.
enum AppCommand: Equatable {
    case newEntry(title: String?, body: String?, mood: Mood?)
    case showToday
    case showOnThisDay
    /// Siri / Shortcuts "Open entry" (id from a `JournalEntryEntity`).
    case openEntry(id: String)
    /// "Append to today's entry".
    case appendToToday(text: String)
    /// "Log mood".
    case logMood(Mood)

    init(link: OmegaJournalLink) {
        switch link {
        case .newEntry: self = .newEntry(title: nil, body: nil, mood: nil)
        case .today: self = .showToday
        case .onThisDay: self = .showOnThisDay
        }
    }
}

extension Notification.Name {
    /// `AppCommandInbox` has new commands; the payload stays in the inbox.
    static let appCommand = Notification.Name("OmegaJournal.appCommand")
}

/// Hand-off between App Intents / URL opens and the journal window.
///
/// Intents can run (and URLs arrive) while `LaunchGateView` is still waiting
/// for the encryption key, i.e. before `ContentView` and its view model exist
/// and before the database may be touched. Commands queue here and
/// `AppCommandHandling` drains them once the journal is open, exactly like
/// `QuickCaptureInbox` does for the menu-bar popover.
@MainActor
enum AppCommandInbox {
    private static var items: [AppCommand] = []

    static var pendingCount: Int { items.count }

    static func submit(_ command: AppCommand) {
        items.append(command)
        NotificationCenter.default.post(name: .appCommand, object: nil)
    }

    static func drain() -> [AppCommand] {
        defer { items.removeAll() }
        return items
    }

    static func removeAll() { items.removeAll() }

    /// URL schemes this build answers to (from Info.plist; production default).
    static var acceptedSchemes: Set<String> {
        var schemes: Set<String> = [OmegaJournalLink.productionScheme]
        if let own = Bundle.main.object(forInfoDictionaryKey: OmegaJournalLink.schemeInfoKey) as? String,
           !own.isEmpty, !own.hasPrefix("@") {
            schemes = [own]
        }
        return schemes
    }

    /// Queues the command for a deep link; false for unknown URLs.
    @discardableResult
    static func open(_ url: URL, acceptedSchemes: Set<String> = AppCommandInbox.acceptedSchemes) -> Bool {
        guard let link = OmegaJournalLink.parse(url, acceptedSchemes: acceptedSchemes) else { return false }
        NSApp?.activate(ignoringOtherApps: true)
        submit(AppCommand(link: link))
        return true
    }
}

// MARK: - Window-side handling

/// Runs queued commands against the journal. Attached to ContentView, which
/// only exists after the launch gate adopted the key, so the database is safe
/// to touch here. Holds the view model as a plain reference (no observation
/// needed: everything is driven by the inbox notification).
struct AppCommandHandling: ViewModifier {
    let vm: JournalViewModel
    @Binding var selection: SidebarItem?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .appCommand)) { _ in run() }
            // Commands that arrived while the launch gate was still waiting.
            // The journal is open from here on, so Siri/Shortcuts entity
            // queries may read it (through the privacy filter).
            .onAppear {
                IntentJournalBridge.attach(vm)
                run()
            }
    }

    private func run() {
        for command in AppCommandInbox.drain() {
            Self.perform(command, vm: vm, selection: &selection)
        }
    }

    static func perform(_ command: AppCommand, vm: JournalViewModel, selection: inout SidebarItem?) {
        switch command {
        case .newEntry(let title, let body, let mood):
            selection = .all
            var entry = vm.createEntry(title: AppIntentText.clean(title) ?? "", body: AppIntentText.clean(body) ?? "")
            if let mood, mood != entry.mood {
                entry.mood = mood
                vm.db.saveEntry(entry)
                vm.updateEntry(entry)
            }
        case .showToday:
            selection = .today
        case .showOnThisDay:
            selection = .onThisDay
        case .openEntry(let id):
            openEntry(id: id, vm: vm, selection: &selection)
        case .appendToToday(let text):
            appendToToday(text, vm: vm, selection: &selection)
        case .logMood(let mood):
            logMood(mood, vm: vm, selection: &selection)
        }
    }

    private static func openEntry(id: String, vm: JournalViewModel, selection: inout SidebarItem?) {
        guard let entry = vm.db.fetchEntry(id: id), !entry.isTrashed else {
            vm.showToast("That entry isn't available anymore", isError: true)
            return
        }
        // The entry may live in another notebook than the one on screen.
        if let active = vm.activeJournalId, active != entry.journalId { vm.setActiveJournal(nil) }
        selection = entry.isArchived ? .archive : .all
        Task { @MainActor in
            // A hidden entry asks for Touch ID / password before it opens.
            guard await vm.revealIfNeeded(entry) else { return }
            vm.select(entry)
        }
    }

    /// Today's entry in the notebook on screen (never a hidden, archived or trashed one).
    static func todaysEntry(in vm: JournalViewModel, now: Date = Date()) -> JournalEntry? {
        let records = vm.entries.map {
            IntentEntryRecord(id: $0.id, title: $0.title, createdAt: $0.createdAt, journalId: $0.journalId,
                              isHidden: $0.isHidden, isTrashed: $0.isTrashed, isArchived: $0.isArchived)
        }
        return IntentEntryCatalog.todaysEntryId(in: records, now: now).flatMap { vm.entry(id: $0) }
    }

    static func appendToToday(_ text: String, vm: JournalViewModel, selection: inout SidebarItem?, now: Date = Date()) {
        guard let addition = AppIntentText.clean(text) else { return }
        // Fold any pending autosave in first so the append lands on top of it.
        vm.flushBeforeImmediateMutation()
        selection = .all
        guard let target = todaysEntry(in: vm, now: now) else {
            vm.createEntry(body: addition)
            return
        }
        // An open editor holds its own copy of the text; close it so it
        // can't write the old text back over the addition, then reopen.
        let wasEditing = vm.editingEntryId == target.id
        if wasEditing { vm.stopEditing() }
        guard var entry = vm.entry(id: target.id), !entry.isTrashed else {
            vm.createEntry(body: addition)
            return
        }
        entry.body = IntentEntryCatalog.appending(addition, to: entry.body)
        entry.updatedAt = now
        // A later retry of an unsaved snapshot must not drop the addition.
        vm.unsavedSnapshots[entry.id]?.body = entry.body
        vm.db.saveEntry(entry)
        vm.updateEntry(entry)
        vm.select(entry)
        if wasEditing { vm.startEditing(entry) }
        vm.showToast("Added to today's entry")
    }

    static func logMood(_ mood: Mood, vm: JournalViewModel, selection: inout SidebarItem?, now: Date = Date()) {
        selection = .all
        if let target = todaysEntry(in: vm, now: now) {
            vm.setMood(mood, for: target)
            vm.select(target)
            vm.showToast("Mood logged: \(mood.label)")
            return
        }
        var entry = vm.createEntry(title: "Mood check-in")
        entry.mood = mood
        vm.db.saveEntry(entry)
        vm.updateEntry(entry)
        vm.showToast("Mood logged: \(mood.label)")
    }
}

/// Routes `omegajournal://…` URLs (widget taps) into the inbox. Attached to
/// the window root (`LaunchGateView`) so links work while the gate is still
/// unlocking; it never touches the database itself.
struct AppURLHandling: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onOpenURL { url in AppCommandInbox.open(url) }
            // Deliver URLs to the existing window instead of opening a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}

enum AppIntentText {
    /// Trimmed text, or nil when empty.
    static func clean(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
