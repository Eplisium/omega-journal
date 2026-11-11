import Foundation
import Testing
@testable import OmegaJournal

/// Follow-ups applied while landing the 2026-11 audit fix wave: small fixes
/// at the seams between the tracks (editor goal ring vs. goal SQL window,
/// DB tag-tree rename guard vs. case-insensitive `TagPath.renamed`).
@Suite("Goal ring window and rename guard", .serialized)
struct GoalRingAndRenameGuardTests {

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// The editor's goal ring must use the same `[startOfToday, endOfToday)`
    /// window as `wordCountSum`; a future-dated entry open in the editor must
    /// not subtract its words from "other words" and add its live words.
    @Test("goal ring counts only entries dated today, never future-dated ones")
    func goalRingWindow() {
        let cal = Self.utc
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 14))!
        let morning = cal.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 0, minute: 5))!
        let yesterday = cal.date(byAdding: .day, value: -1, to: morning)!
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 9))!
        let nextWeek = cal.date(byAdding: .day, value: 7, to: now)!
        #expect(EditorView.countsTowardToday(createdAt: morning, now: now, calendar: cal))
        #expect(EditorView.countsTowardToday(createdAt: now, now: now, calendar: cal))
        #expect(!EditorView.countsTowardToday(createdAt: yesterday, now: now, calendar: cal))
        #expect(!EditorView.countsTowardToday(createdAt: tomorrow, now: now, calendar: cal))
        #expect(!EditorView.countsTowardToday(createdAt: nextWeek, now: now, calendar: cal))
    }

    /// A real `evaluatePolicy` inside the test runner never returns (nobody can
    /// answer it), which hung parallel runs. Without an override it refuses.
    @MainActor
    @Test("in the test runner an unanswered unlock prompt refuses instead of hanging")
    func promptRefusesInTestRunner() async {
        #expect(BiometricAuth.isTestRunnerProcess)
        let auth = BiometricAuth(forTesting: ())
        #expect(await auth.authenticate() == false)
        #expect(!auth.isAuthenticated && !auth.isAuthenticating)
        auth.evaluateOverride = { true }
        #expect(await auth.authenticate())
        auth.lock()
    }

    /// `TagPath.renamed` now matches case-insensitively, so the "beneath
    /// itself" guard must too: `work` -> `Work/sub` would otherwise re-root
    /// the tag under itself and the result would depend on tag order.
    @Test("renaming a tag beneath itself is rejected regardless of case")
    func renameBeneathItselfAnyCase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oj-fixparent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        TestSharedEnvironment.pin()
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        var a = JournalEntry.new(); a.title = "A"; a.tags = ["work"]
        var b = JournalEntry.new(); b.title = "B"; b.tags = ["work/alpha"]
        db.saveEntry(a)
        db.saveEntry(b)

        #expect(db.renameTagTree(from: "work", to: "Work/sub") == 0)
        #expect(db.renameTagTree(from: "WORK", to: "work/sub") == 0)
        #expect(db.fetchEntry(id: a.id)?.tags == ["work"])
        #expect(db.fetchEntry(id: b.id)?.tags == ["work/alpha"])

        // A case-only rename is not "beneath itself" and still works.
        #expect(db.renameTagTree(from: "work", to: "Work") == 2)
        #expect(db.fetchEntry(id: a.id)?.tags == ["Work"])
        #expect(db.fetchEntry(id: b.id)?.tags == ["Work/alpha"])
    }
}
