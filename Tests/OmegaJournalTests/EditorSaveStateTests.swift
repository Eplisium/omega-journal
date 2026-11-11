import Testing
import Foundation
@testable import OmegaJournal

@Suite("Editor save state and body updates", .serialized)
@MainActor
struct EditorSaveStateTests {
    private func makeVM() -> JournalViewModel {
        TestSharedEnvironment.pin()
        return JournalViewModel()
    }

    @Test("autosave goes pending, flush marks saved, stopEditing resets")
    func stateMachine() throws {
        let vm = makeVM()
        let created = vm.createEntry(title: "Save state", body: "x")
        let id = created.id
        defer { vm.db.hardDeleteEntry(id: id) }
        var e = try #require(vm.entries.first { $0.id == id })
        #expect(vm.saveState == .idle)
        e.body = "hello"
        vm.autoSave(e)
        #expect(vm.saveState == .pending)
        vm.flushPendingSave()
        #expect(vm.saveState == .saved)
        vm.stopEditing()
        #expect(vm.saveState == .idle)
    }

    @Test("updateBody wins over a pending autosave snapshot")
    func updateBodyBeatsStaleAutosave() throws {
        let vm = makeVM()
        let created = vm.createEntry(title: "T", body: "x")
        let id = created.id
        defer { vm.db.hardDeleteEntry(id: id) }
        var e = try #require(vm.entries.first { $0.id == id })
        e.title = "T"; e.body = "- [ ] a"
        vm.autoSave(e)
        vm.updateBody("- [x] a", for: vm.entries.first { $0.id == id }!)
        #expect(vm.entries.first { $0.id == id }?.body == "- [x] a")
        #expect(vm.db.fetchEntry(id: id)?.body == "- [x] a")
    }
}
