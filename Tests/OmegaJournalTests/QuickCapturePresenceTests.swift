import Testing
import Foundation
import Observation
@testable import OmegaJournal

/// Regression guard for the launch hang: `MenuBarExtra(isInserted:)` used to
/// bind straight to an `@AppStorage` on the App struct, which re-evaluated the
/// whole scene graph on every UserDefaults write (window/split-view frame
/// autosave included) and spun the main thread at 100% before the window
/// appeared. `QuickCapturePresence` must only publish on a real change of its
/// own key. `@Observable` setters notify even on equal values, so these tests
/// count actual Observation change notifications on `isInserted`.
@MainActor
@Suite("Quick capture menu bar presence")
struct QuickCapturePresenceTests {

    /// Records whether Observation reported a change to `isInserted` while
    /// `body` ran. One registration catches the first notification, so
    /// "no change" means no notification at all.
    private func changesInsertion(_ presence: QuickCapturePresence, during body: () -> Void) -> Bool {
        let flag = ChangeFlag()
        withObservationTracking { _ = presence.isInserted } onChange: { flag.set() }
        body()
        return flag.fired
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "omega.qc.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("defaults to inserted and reads a stored value")
    func initialValue() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        #expect(QuickCapturePresence(defaults: d).isInserted == true)
        d.set(false, forKey: QuickCapture.insertedKey)
        #expect(QuickCapturePresence(defaults: d).isInserted == false)
    }

    @Test("unrelated defaults writes never republish")
    func unrelatedWritesAreIgnored() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let presence = QuickCapturePresence(defaults: d)

        let changed = changesInsertion(presence) {
            // Simulates window / split-view frame autosave churn during layout.
            for i in 0..<50 { d.set("frame \(i)", forKey: "NSWindow Frame Test") }
            presence.syncFromDefaults()
            // Rewriting the same value is also not a change.
            d.set(true, forKey: QuickCapture.insertedKey)
            presence.syncFromDefaults()
        }

        #expect(changed == false)
        #expect(presence.isInserted == true)
    }

    @Test("a real settings change publishes once and is picked up")
    func realChangePublishes() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let presence = QuickCapturePresence(defaults: d)

        let changed = changesInsertion(presence) {
            d.set(false, forKey: QuickCapture.insertedKey)   // Settings toggle off
            presence.syncFromDefaults()
        }
        #expect(presence.isInserted == false)
        #expect(changed == true)
        // A second sync of the same value does not notify again.
        #expect(changesInsertion(presence) { presence.syncFromDefaults() } == false)
    }

    @Test("binding writes persist only when the value changes")
    func bindingDedupesWrites() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let presence = QuickCapturePresence(defaults: d)

        let binding = presence.binding
        // Redundant write from SwiftUI.
        #expect(changesInsertion(presence) { binding.wrappedValue = true } == false)
        #expect(d.object(forKey: QuickCapture.insertedKey) == nil)

        // User removed the item.
        #expect(changesInsertion(presence) { binding.wrappedValue = false } == true)
        #expect(d.bool(forKey: QuickCapture.insertedKey) == false)
        #expect(presence.isInserted == false)
    }
}

/// Set from Observation's `@Sendable` onChange callback.
nonisolated private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var fired: Bool { lock.withLock { value } }
}
