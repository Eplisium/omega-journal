import Foundation
import SwiftUI
import Testing
@testable import OmegaJournal
import OmegaJournalCore

@Suite("W1UI: command palette ranking")
struct W1UIPaletteRankingTests {
    typealias R = UIPaletteRanking

    private func order(_ q: String, _ items: [(String, String)]) -> [String] {
        let scored = items.compactMap { item -> (String, Int)? in
            R.score(q, title: item.0, subtitle: item.1).map { (item.0, $0.score) }
        }
        return R.ranked(scored)
    }

    @Test("tiers: exact > prefix > word prefix > substring > fuzzy")
    func tiers() throws {
        let exact = try #require(R.match("mood", in: "Mood"))
        let prefix = try #require(R.match("mood", in: "Mood journal"))
        let word = try #require(R.match("mood", in: "Sort by Mood"))
        let sub = try #require(R.match("ood", in: "Sort by Mood"))
        let fuzzy = try #require(R.match("nft", in: "New from Template"))
        #expect(exact.score > prefix.score)
        #expect(prefix.score > word.score)
        #expect(word.score > sub.score)
        #expect(sub.score > fuzzy.score)
        #expect(fuzzy.score < R.Tier.contentHit.rawValue)
    }

    @Test("scattered letters no longer match")
    func noScatter() {
        // d…r…e…a…m spread through unrelated words used to match.
        #expect(R.match("dream", in: "Delete Forever and Remove All Mail") == nil)
        #expect(R.match("tra", in: "Go to Archive") == nil)
        #expect(R.match("xyz", in: "New Entry") == nil)
    }

    @Test("a matching entry outranks commands that only match loosely")
    func entriesBeatNoise() {
        let items = [
            ("Go to Trash", "Navigate"), ("Sort by Date", "Change list order"),
            ("Theme: Paper", "Change appearance"), ("Dream journal", "🙂 Nov 10"),
            ("Export as PDF", "Printable book"),
        ]
        #expect(order("dream", items) == ["Dream journal"])
        #expect(order("pdf", items).first == "Export as PDF")
        #expect(order("theme", items) == ["Theme: Paper"])
    }

    @Test("subtitles count only for real words, below title matches")
    func subtitles() throws {
        let viaSubtitle = try #require(R.score("navigate", title: "Go to Trash", subtitle: "Navigate"))
        let viaTitle = try #require(R.score("trash", title: "Go to Trash", subtitle: "Navigate"))
        #expect(viaSubtitle.score < viaTitle.score)
        #expect(viaSubtitle.ranges.isEmpty)
        // No fuzzy matching through subtitles.
        #expect(R.score("ngt", title: "Go to Trash", subtitle: "Navigate") == nil)
    }

    @Test("multi-word queries match words anywhere")
    func multiWord() throws {
        let m = try #require(R.match("export pdf", in: "Export as PDF"))
        #expect(m.ranges == [0..<6, 10..<13])
    }

    @Test("highlight ranges cover the matched text")
    func ranges() throws {
        #expect(try #require(R.match("trash", in: "Go to Trash")).ranges == [6..<11])
        #expect(try #require(R.match("nft", in: "New from Template")).ranges == [0..<1, 4..<5, 9..<10])
        // Word-start occurrence is preferred over an earlier mid-word one.
        #expect(try #require(R.match("art", in: "Start art")).ranges == [6..<9])
    }

    @Test("ties keep their original order")
    func stable() {
        #expect(R.ranked([("a", 5), ("b", 7), ("c", 5)]) == ["b", "a", "c"])
    }
}

@Suite("W1UI: command palette rows")
@MainActor
struct W1UIPaletteRowTests {
    @Test("highlighted title keeps every character and emphasises matches")
    func highlightedTitle() {
        let attributed = CommandPaletteView.highlightedTitle("Go to Trash", ranges: [6..<11], accent: .red, base: .gray)
        #expect(String(attributed.characters) == "Go to Trash")
        let emphasised = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
        #expect(emphasised == ["Trash"])
        // Out-of-range offsets are clamped, never crash.
        let clamped = CommandPaletteView.highlightedTitle("Hi", ranges: [1..<9], accent: .red, base: .gray)
        #expect(String(clamped.characters) == "Hi")
    }

    @Test("entry rows open, command rows run")
    func entryKind() {
        let entry = CommandPaletteView.Command(title: "Day", subtitle: "", icon: "doc", group: "Entries", key: "1") {}
        let hit = CommandPaletteView.Command(title: "Day", subtitle: "", icon: "doc", group: "In entries", key: "1") {}
        let cmd = CommandPaletteView.Command(title: "New Entry", subtitle: "", icon: "doc", group: "Create") {}
        #expect(entry.isEntry && hit.isEntry && !cmd.isEntry)
    }
}
