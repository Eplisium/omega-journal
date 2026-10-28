import SwiftUI
import WidgetKit
import OmegaJournalCore
import OmegaJournalShared

// MARK: - Widget snapshot publishing

/// Writes the privacy-safe widget snapshot to the App Group container and
/// asks WidgetKit to reload, debounced, whenever the journal's numbers change.
///
/// Rules (see `OmegaJournalAppGroup.publishDecision`):
/// - only builds that packaging gave an `OJAppGroupIdentifier` publish;
/// - test/QA runs (`OMEGA_JOURNAL_TEST_DATABASE_PATH`) publish only to an
///   explicit non-production `OMEGA_JOURNAL_TEST_APP_GROUP`;
/// - hidden entries contribute nothing (`WidgetEntryFact.countsForWidget`).
@MainActor
final class WidgetSnapshotPublisher {
    static let shared = WidgetSnapshotPublisher()

    /// Debounce between the last change and the write.
    var delay: Duration = .seconds(2)
    /// Seams for tests.
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    var storeOverride: WidgetSnapshotStore?
    var reloadTimelines: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }

    private var pending: Task<Void, Never>?
    private var lastPublished: WidgetSnapshot?

    var decision: OmegaJournalAppGroup.PublishDecision {
        OmegaJournalAppGroup.publishDecision(
            bundleGroup: OmegaJournalAppGroup.identifier(infoDictionary: infoDictionary),
            environment: environment)
    }

    /// Publishes after `delay` unless another change arrives first.
    func schedule(_ vm: JournalViewModel) {
        guard storeOverride != nil || isPublishing else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self, weak vm] in
            guard let self else { return }
            try? await Task.sleep(for: self.delay)
            guard !Task.isCancelled, let vm else { return }
            self.publishNow(vm)
        }
    }

    private var isPublishing: Bool {
        if case .publish = decision { return true }
        return false
    }

    /// Builds and writes the snapshot now. Returns the snapshot when written.
    @discardableResult
    func publishNow(_ vm: JournalViewModel, now: Date = Date()) -> WidgetSnapshot? {
        pending?.cancel()
        pending = nil
        let store: WidgetSnapshotStore
        if let storeOverride {
            store = storeOverride
        } else {
            guard case .publish(let group) = decision, let groupStore = WidgetSnapshotStore.appGroup(group) else {
                return nil
            }
            store = groupStore
        }
        let snapshot = Self.makeSnapshot(entries: vm.entries, goals: GoalManager.shared, now: now)
        // Same numbers as last time: skip the disk write and the widget reload.
        if let lastPublished, Self.sameContent(lastPublished, snapshot) { return nil }
        do {
            try store.write(snapshot)
        } catch {
            return nil
        }
        lastPublished = snapshot
        reloadTimelines()
        return snapshot
    }

    static func sameContent(_ a: WidgetSnapshot, _ b: WidgetSnapshot) -> Bool {
        var a = a
        a.generatedAt = b.generatedAt
        return a == b
    }

    /// Facts for the builder. Word counts are only computed for entries the
    /// snapshot can show (today onwards), because `wordCount` parses the body.
    static func facts(from entries: [JournalEntry], now: Date = Date(),
                      calendar: Calendar = .current) -> [WidgetEntryFact] {
        let today = calendar.startOfDay(for: now)
        return entries.map { entry in
            WidgetEntryFact(createdAt: entry.createdAt,
                            wordCount: entry.createdAt >= today && !entry.isHidden ? entry.wordCount : 0,
                            isHidden: entry.isHidden, isTrashed: entry.isTrashed, isArchived: entry.isArchived)
        }
    }

    static func makeSnapshot(entries: [JournalEntry], goals: GoalManager, now: Date = Date()) -> WidgetSnapshot {
        let goal = goals.goals.first(where: { $0.type == .dailyWords })?.target ?? WritingGoal.GoalType.dailyWords.defaultValue
        return WidgetSnapshotBuilder.build(
            facts: facts(from: entries, now: now), dailyWordGoal: goal, streakMode: goals.streakMode,
            weeklyStreakTarget: goals.weeklyStreakTarget, prompt: PromptGenerator.prompt(for:), now: now)
    }

    /// Cheap change detector evaluated in ContentView's body: no body parsing.
    static func fingerprint(of entries: [JournalEntry], goals: GoalManager) -> Int {
        var hasher = Hasher()
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(entry.createdAt)
            hasher.combine(entry.updatedAt)
            hasher.combine(entry.isHidden)
        }
        hasher.combine(goals.goals.first(where: { $0.type == .dailyWords })?.target)
        hasher.combine(goals.streakMode.rawValue)
        hasher.combine(goals.weeklyStreakTarget)
        return hasher.finalize()
    }
}

/// Attached to ContentView (which exists only after the launch gate adopted
/// the key). `fingerprint` is computed by ContentView's body, so this works
/// whether the view model is observed via Combine or Observation.
struct WidgetSnapshotPublishing: ViewModifier {
    let vm: JournalViewModel
    let fingerprint: Int

    func body(content: Content) -> some View {
        content
            .onAppear { WidgetSnapshotPublisher.shared.schedule(vm) }
            .onChange(of: fingerprint) { _, _ in WidgetSnapshotPublisher.shared.schedule(vm) }
            // New day: today's words reset and the prompt changes.
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                WidgetSnapshotPublisher.shared.schedule(vm)
            }
            // Leaving the app: make sure the widget has the latest numbers.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                WidgetSnapshotPublisher.shared.publishNow(vm)
            }
    }
}
