import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

/// core-11: tag colour validation. core-9: tag identity is case-insensitive
/// everywhere (filter, tree, rename).
@Suite("Tag colours and identity")
struct TagColorAndIdentityTests {
    @Test("core-11 normalizedHex rejects full-width hex digits; every accepted colour renders")
    func fullwidthHex() {
        #expect(TagColors.normalizedHex("#ＡＢＣ１２３") == nil)
        #expect(TagColors.normalizedHex("ＡＢＣ１２３") == nil)
        #expect(TagColors.normalizedHex("#12345６") == nil)
        #expect(TagColors.rgb(hex: "#ＡＢＣ１２３") == nil)
        for raw in ["#abc123", "ABC123", " #8b5cf6 "] {
            let n = TagColors.normalizedHex(raw)
            #expect(n != nil, "\(raw)")
            #expect(n.flatMap { TagColors.rgb(hex: $0) } != nil, "\(raw)")
        }
        #expect(TagColors.normalizedHex("#abc123") == "#ABC123")
        #expect(TagColors.palette.allSatisfy { TagColors.normalizedHex($0) == $0 })
    }

    @Test("core-9 the tag tree groups paths case-insensitively, like the tag filter")
    func treeGroupsCaseInsensitively() throws {
        let entryTags = [["Work/alpha"], ["work"]]
        let tree = TagTree.build(entryTags: entryTags)
        #expect(tree.count == 1, "tree roots: \(tree.map { "\($0.path)=\($0.totalCount)" })")
        let root = try #require(tree.first)
        #expect(root.totalCount == 2)
        #expect(root.ownCount == 1)
        // The node shows the spelling used as a real tag; the child keeps its own.
        #expect(root.path == "work")
        #expect(root.children.map(\.path) == ["Work/alpha"])
        // The filter treats them as one tag too, so the badge and the list agree.
        let q = SearchQuery.parse("tag:\(root.path)")
        let recs = entryTags.map {
            SearchQuery.Record(id: UUID().uuidString, title: "", body: "", tags: $0, moodName: "good", moodValue: 4, createdAt: Date())
        }
        #expect(recs.filter { q.matches($0, hiddenLocked: true) }.count == root.totalCount)
    }

    @Test("core-9 own counts and spellings when one tag appears in several cases")
    func ownCountsAcrossCases() throws {
        let tree = TagTree.build(entryTags: [["Work"], ["work"], ["WORK/x"], ["Home", "home"]])
        let work = try #require(tree.first { $0.path.lowercased() == "work" })
        #expect(work.path == "Work")              // first spelling used as a tag
        #expect(work.ownCount == 2 && work.totalCount == 3)
        #expect(work.children.map(\.path) == ["WORK/x"])
        let home = try #require(tree.first { $0.path.lowercased() == "home" })
        #expect(home.ownCount == 1 && home.totalCount == 1)   // one entry, counted once
        #expect(tree.count == 2)
        // Distinct tags stay distinct.
        #expect(TagTree.build(entryTags: [["work"], ["workshop"]]).count == 2)
    }

    @Test("core-9 TagPath.renamed re-roots every spelling of the old tag and keeps the rest")
    func renamedIsCaseInsensitive() {
        #expect(TagPath.renamed("Work/alpha", from: "work", to: "job") == "job/alpha")
        #expect(TagPath.renamed("WORK", from: "work", to: "job") == "job")
        #expect(TagPath.renamed("work/Alpha/Beta", from: "WORK/alpha", to: "x") == "x/Beta")
        #expect(TagPath.renamed("workshop", from: "work", to: "job") == nil)
        #expect(TagPath.renamed("work", from: "work/alpha", to: "job") == nil)
        #expect(TagPath.renamed("other/work", from: "work", to: "job") == nil)
        #expect(TagPath.renamed("a/b", from: "a", to: "z") == "z/b")
        #expect(TagPath.renamed("a", from: "a", to: "z") == "z")
    }

    @Test("core-9 unsaved-snapshot rename rewrite follows the same case-insensitive rule")
    func snapshotRewriteMatches() {
        #expect(SaveTagRewrite.rename(from: "a", to: "b").apply(to: ["A", "a/x", "Ab", "c"]) == ["b", "b/x", "Ab", "c"])
        #expect(SaveTagRewrite.rename(from: "work", to: "job").apply(to: ["Work/alpha", "work"]) == ["job/alpha", "job"])
    }
}

@Suite("Case-insensitive tag rename in the journal", .serialized)
@MainActor
struct TagRenameCaseInsensitiveDBTests {
    @Test("core-9 renaming `work` also moves `Work/alpha` (no spelling left behind)")
    func renameTreeMovesEveryCase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oj-fixcore-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        TestSharedEnvironment.pin()
        let db = DatabaseManager(databasePath: root.appendingPathComponent("j.sqlite3").path,
                                 attachmentsPath: root.appendingPathComponent("att").path)
        var a = JournalEntry.new(); a.title = "A"; a.tags = ["Work/alpha"]
        var b = JournalEntry.new(); b.title = "B"; b.tags = ["work"]
        db.saveEntry(a)
        db.saveEntry(b)
        #expect(db.renameTagTree(from: "work", to: "job") == 2)
        #expect(db.fetchEntry(id: a.id)?.tags == ["job/alpha"])
        #expect(db.fetchEntry(id: b.id)?.tags == ["job"])
        let names = Set(db.allTagNames())
        #expect(names.isSuperset(of: ["job", "job/alpha"]))
        #expect(!names.contains { $0.lowercased().hasPrefix("work") }, "\(names)")
    }
}
