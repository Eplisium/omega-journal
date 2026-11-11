import Foundation
import Testing
import OmegaJournalCore
@testable import OmegaJournal

// Wave 1 / data-perf: every live view model hears every lock-state change.
// One that already shows the current lock state must skip the re-derive (a
// burst of flips used to queue a full tag-count + search pass per flip per
// view model), while a real change — or anything derived under another lock
// state in between — still re-derives at once. Uses the per-VM lock-state
// seam: BiometricAuth.shared is process-global and parallel suites poll it.

@Suite("W1Data session changes: re-derive only what is stale", .serialized)
@MainActor
struct W1DataSessionTests {
    init() { TestSharedEnvironment.pin() }

    private func makeVM() -> (URL, JournalViewModel) {
        let (root, db) = DataSafetyTests.makeDB()
        let vm = JournalViewModel(database: db)
        return (root, vm)
    }

    @Test("a flip and flip back before delivery changes nothing and costs nothing")
    func burstIsSkipped() {
        let (root, vm) = makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.sessionUnlockedOverride = true
        _ = vm.createEntry(title: "Plain", body: "quokka", tags: ["open"], isHidden: false)
        vm.stopEditing()
        vm.searchText = "quokka"
        vm.refreshQuery()
        vm.refreshTagCounts()
        #expect(vm.searchResults?.count == 1)

        // Sentinel: a skipped delivery leaves it alone.
        vm.searchResults = []
        vm.sessionUnlockedOverride = false
        vm.sessionUnlockedOverride = true
        vm.sessionDidChange()
        vm.sessionDidChange()
        #expect(vm.searchResults == [], "nothing was stale, so nothing was redone")

        // A real change re-derives.
        vm.sessionUnlockedOverride = false
        vm.sessionDidChange()
        #expect(vm.searchResults?.count == 1)
    }

    @Test("a lock change re-derives counts, the tag tree and search")
    func realChangeRederives() throws {
        let (root, vm) = makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.sessionUnlockedOverride = true
        _ = vm.createEntry(title: "Secret", body: "wombat", tags: ["w1-secret"], isHidden: true)
        vm.stopEditing()
        vm.searchText = "wombat"
        vm.refreshQuery()
        vm.refreshTagCounts()
        #expect(vm.allTags.contains { $0.tag == "w1-secret" })
        #expect(vm.tagTree.contains { $0.path == "w1-secret" })
        #expect(vm.searchResults?.count == 1)

        vm.sessionUnlockedOverride = false
        vm.sessionDidChange()
        #expect(!vm.allTags.contains { $0.tag == "w1-secret" })
        #expect(!vm.tagTree.contains { $0.path == "w1-secret" })
        #expect(vm.searchResults?.isEmpty == true, "a locked hidden entry matches on title only")

        vm.sessionUnlockedOverride = true
        vm.sessionDidChange()
        #expect(vm.allTags.contains { $0.tag == "w1-secret" })
        #expect(vm.searchResults?.count == 1)
    }

    @Test("something derived under the other lock state in between is still fixed")
    func staleOrganizationIsRederived() {
        let (root, vm) = makeVM()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.sessionUnlockedOverride = false
        _ = vm.createEntry(title: "Secret", body: "x", tags: ["w1-tree"], isHidden: true)
        vm.stopEditing()
        vm.refreshTagCounts()
        #expect(!vm.tagTree.contains { $0.path == "w1-tree" })

        // Unlocked for a moment: the tree is rebuilt with the hidden tag…
        vm.sessionUnlockedOverride = true
        vm.refreshOrganization()
        #expect(vm.tagTree.contains { $0.path == "w1-tree" })
        // …then locked again before any notification arrives. The delivery
        // must not skip: the tree on screen was built unlocked.
        vm.sessionUnlockedOverride = false
        vm.sessionDidChange()
        #expect(!vm.tagTree.contains { $0.path == "w1-tree" })
    }
}
