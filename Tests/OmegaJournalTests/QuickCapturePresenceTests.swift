import Testing
import Foundation
import Combine
@testable import OmegaJournal

/// Regression guard for the launch hang: `MenuBarExtra(isInserted:)` used to
/// bind straight to an `@AppStorage` on the App struct, which re-evaluated the
/// whole scene graph on every UserDefaults write (window/split-view frame
/// autosave included) and spun the main thread at 100% before the window
/// appeared. `QuickCapturePresence` must only publish on a real change of its
/// own key.
@MainActor
@Suite("Quick capture menu bar presence")
struct QuickCapturePresenceTests {

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
        var publishes = 0
        let sub = presence.objectWillChange.sink { publishes += 1 }
        defer { sub.cancel() }

        // Simulates window / split-view frame autosave churn during layout.
        for i in 0..<50 { d.set("frame \(i)", forKey: "NSWindow Frame Test") }
        presence.syncFromDefaults()
        // Rewriting the same value is also not a change.
        d.set(true, forKey: QuickCapture.insertedKey)
        presence.syncFromDefaults()

        #expect(publishes == 0)
        #expect(presence.isInserted == true)
    }

    @Test("a real settings change publishes once and is picked up")
    func realChangePublishes() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let presence = QuickCapturePresence(defaults: d)
        var publishes = 0
        let sub = presence.objectWillChange.sink { publishes += 1 }
        defer { sub.cancel() }

        d.set(false, forKey: QuickCapture.insertedKey)   // Settings toggle off
        presence.syncFromDefaults()
        #expect(presence.isInserted == false)
        #expect(publishes == 1)
    }

    @Test("binding writes persist only when the value changes")
    func bindingDedupesWrites() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let presence = QuickCapturePresence(defaults: d)
        var publishes = 0
        let sub = presence.objectWillChange.sink { publishes += 1 }
        defer { sub.cancel() }

        let binding = presence.binding
        binding.wrappedValue = true          // redundant write from SwiftUI
        #expect(publishes == 0)
        #expect(d.object(forKey: QuickCapture.insertedKey) == nil)

        binding.wrappedValue = false         // user removed the item
        #expect(publishes == 1)
        #expect(d.bool(forKey: QuickCapture.insertedKey) == false)
        #expect(presence.isInserted == false)
    }
}
