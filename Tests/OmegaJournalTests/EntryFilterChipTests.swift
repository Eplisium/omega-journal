import Testing
@testable import OmegaJournal

@Suite("Entry filter chips")
struct EntryFilterChipTests {
    @Test("empty filter has no chips")
    func empty() {
        #expect(EntryFilter.empty.chips.isEmpty)
    }

    @Test("every active facet yields exactly one chip per value, in a stable order")
    func chipsPerFacet() {
        var f = EntryFilter()
        f.tags = ["work", "life"]
        f.moods = [.great]
        f.dateRange = .last7
        f.favoritesOnly = true
        f.minWords = 100
        let labels = f.chips.map(\.label)
        #expect(labels.first == "Last 7 days")
        #expect(labels.contains("Favorites"))
        #expect(labels.contains("#life") && labels.contains("#work"))
        #expect(labels.firstIndex(of: "#life")! < labels.firstIndex(of: "#work")!)
        #expect(labels.last == "100+ words")
        #expect(f.chips.count == 6)
    }

    @Test("removing each chip clears only that facet and ends at empty")
    func removeAll() {
        var f = EntryFilter()
        f.tags = ["work"]
        f.moods = [.good, .bad]
        f.pinnedOnly = true
        f.withAttachmentsOnly = true
        f.dateRange = .thisYear
        f.minWords = 50
        let start = f.chips.count
        var removed = 0
        while let chip = f.chips.first {
            let next = f.removing(chip.facet)
            #expect(next.chips.count == f.chips.count - 1)
            #expect(!next.chips.contains(chip))
            f = next
            removed += 1
        }
        #expect(removed == start)
        #expect(f == .empty)
        #expect(!f.isActive)
    }
}
