import Foundation
import Testing
@testable import OmegaJournal

@Suite("Wiki link wiring", .serialized)
@MainActor
struct WikiLinkWiringTests {
    private func makeVM() -> JournalViewModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omega-wl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", root.appendingPathComponent("j.sqlite3").path, 1)
        setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", root.appendingPathComponent("att").path, 1)
        return JournalViewModel()
    }

    private func cleanup(_ vm: JournalViewModel) {
        for e in vm.db.fetchAllEntriesForExport() where e.title.hasPrefix("VM WL ") { vm.db.hardDeleteEntry(id: e.id) }
        vm.reload()
    }

    @Test("linkableTitles covers active/archived, not trashed or locked-hidden")
    func titles() {
        let vm = makeVM(); defer { cleanup(vm) }
        BiometricAuth.shared.lock()
        var a = JournalEntry.new(); a.title = "VM WL Rome"
        var t = JournalEntry.new(); t.title = "VM WL Trashed"; t.deletedAt = Date()
        var h = JournalEntry.new(); h.title = "VM WL Secret"; h.isHidden = true
        for e in [a, t, h] { vm.db.saveEntry(e) }
        vm.reload()
        let titles = vm.linkableTitles()
        #expect(titles.contains("vm wl rome"))
        #expect(!titles.contains("vm wl trashed"))
        #expect(!titles.contains("vm wl secret"))
    }

    @Test("openLinkedEntry selects a case-insensitive match; unknown titles fail with a toast")
    func opening() {
        let vm = makeVM(); defer { cleanup(vm) }
        var a = JournalEntry.new(); a.title = "VM WL Trip"
        vm.db.saveEntry(a); vm.reload()
        #expect(vm.openLinkedEntry(titled: "  vm wl TRIP "))
        #expect(vm.selectedEntryId == a.id)
        #expect(vm.openLinkedEntry(titled: "VM WL nothing here") == false)
        #expect(vm.toast?.isError == true)
    }
}
