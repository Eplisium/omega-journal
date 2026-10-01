import Foundation
import Testing
import OmegaJournalCore

@Suite("Organization core (pure)")
struct OrganizationCoreTests {
    private func rec(_ id: String, title: String = "T", body: String = "", tags: [String] = [], mood: Int = 3,
                     hidden: Bool = false, image: Bool = false, words: Int = 10, at: Date = Date()) -> SearchQuery.Record {
        SearchQuery.Record(id: id, title: title, body: body, tags: tags, moodName: "Good", moodValue: mood, createdAt: at,
                           attachmentCount: image ? 1 : 0, hasImage: image, wordCount: words, isHidden: hidden)
    }

    @Test("operator parser extracts operators and free text")
    func parse() {
        let q = SearchQuery.parse("tag:work mood:good has:image before:2026-03-01 after:2026-01-01 budget plan")
        #expect(q.tags == ["work"])
        #expect(q.has == [.image])
        #expect(q.before != nil && q.after != nil)
        #expect(q.text == "budget plan")
        #expect(SearchQuery.parse("plain words").hasOperators == false)
    }

    @Test("operators filter records")
    func matching() {
        let q = SearchQuery.parse("tag:work has:image")
        #expect(q.matches(rec("1", tags: ["work"], image: true), hiddenLocked: false))
        #expect(!q.matches(rec("2", tags: ["work"]), hiddenLocked: false))
        #expect(!q.matches(rec("3", tags: ["home"], image: true), hiddenLocked: false))
    }

    @Test("locked hidden entries never match on body or tags")
    func hiddenSearchMasked() {
        let h = rec("h", title: "Plain", body: "secret garden", tags: ["secret"], hidden: true)
        #expect(!SearchQuery.parse("garden").matches(h, hiddenLocked: true))
        #expect(!SearchQuery.parse("tag:secret").matches(h, hiddenLocked: true))
        #expect(SearchQuery.parse("garden").matches(h, hiddenLocked: false))
        #expect(SearchSnippet.forRecord(h, terms: ["garden"], hiddenLocked: true) == nil)
        #expect(SearchSnippet.forRecord(h, terms: ["garden"], hiddenLocked: false) != nil)
    }

    @Test("snippet highlights match")
    func snippet() throws {
        let s = try #require(SearchSnippet.make(from: "A long walk in the garden at dusk", terms: ["garden"]))
        let r = try #require(s.highlights.first)
        #expect((s.text as NSString).substring(with: r).lowercased() == "garden")
    }

    @Test("recent searches dedupe, cap and round-trip")
    func recents() {
        var list: [String] = []
        for i in 0..<12 { list = RecentSearches.adding("q\(i)", to: list) }
        list = RecentSearches.adding("q5", to: list)
        #expect(list.count == RecentSearches.maxCount && list.first == "q5")
        #expect(RecentSearches.decode(RecentSearches.encode(list)) == list)
    }

    @Test("tag paths and tree")
    func tags() {
        #expect(TagPath.normalize(" #Work/ /Alpha, ") != nil)
        #expect(TagPath.parent(of: "a/b/c") == "a/b")
        #expect(TagPath.isSameOrDescendant("a/b", of: "a") && !TagPath.isSameOrDescendant("ab", of: "a"))
        #expect(TagPath.renamed("a/b", from: "a", to: "z") == "z/b")
        let tree = TagTree.build(entryTags: [["a/b"], ["a"], ["a/c", "x"]])
        let a = tree.first { $0.path == "a" }
        #expect(a?.totalCount == 3 && a?.ownCount == 1 && a?.children.count == 2)
        #expect(TagTree.flatten(tree, collapsed: ["a"]).contains { $0.path == "a/b" } == false)
        #expect(TagPath.suggestions(prefix: "alp", from: ["work/alpha", "beta"], excluding: []) == ["work/alpha"])
    }

    @Test("link graph excludes hidden entries when locked")
    func graphHidden() {
        let es = [
            LinkableEntry(id: "a", title: "Alpha", body: "see [[Beta]] and [[Secret]]"),
            LinkableEntry(id: "b", title: "Beta", body: "back to [[Alpha]]"),
            LinkableEntry(id: "s", title: "Secret", body: "[[Alpha]]", isHidden: true),
        ]
        let locked = LinkGraph.build(entries: es)
        #expect(locked.nodes.map(\.id).sorted() == ["a", "b"])
        #expect(!locked.edges.contains { $0.from == "s" || $0.to == "s" })
        let open = LinkGraph.build(entries: es, includeHidden: true)
        #expect(open.nodes.count == 3)
    }

    @Test("unlinked mentions skip hidden when locked and already-linked entries")
    func mentions() {
        let es = [
            LinkableEntry(id: "t", title: "Garden", body: ""),
            LinkableEntry(id: "m", title: "x", body: "I love my garden"),
            LinkableEntry(id: "l", title: "y", body: "[[Garden]] is linked"),
            LinkableEntry(id: "h", title: "z", body: "hidden garden talk", isHidden: true),
        ]
        let locked = UnlinkedMentions.find(forTitle: "Garden", in: es, excludingId: "t", includeHidden: false).map(\.id)
        #expect(locked == ["m"])
        let open = Set(UnlinkedMentions.find(forTitle: "Garden", in: es, excludingId: "t", includeHidden: true).map(\.id))
        #expect(open == ["m", "h"])
    }

    @Test("layout is deterministic and finite")
    func layout() {
        let g = LinkGraph.build(entries: [LinkableEntry(id: "a", title: "A", body: "[[B]]"), LinkableEntry(id: "b", title: "B", body: "")])
        var l = GraphLayout(graph: g, width: 400, height: 300)
        l.settle()
        for p in l.positions.values { #expect(p.x.isFinite && p.y.isFinite) }
        #expect(l.positions.count == 2)
    }

    @Test("smart folders match criteria, mask hidden, persist")
    func smartFolders() {
        var f = SmartFolder(name: "Work", tags: ["work"], hasAttachment: true)
        let recs = [rec("1", tags: ["work"], image: true), rec("2", tags: ["work"]), rec("h", tags: ["work"], hidden: true, image: true)]
        #expect(f.count(in: recs, hiddenLocked: false) == 2)
        #expect(f.count(in: recs, hiddenLocked: true) == 1)
        f.hasAttachment = false; f.minWords = 50
        #expect(f.count(in: recs, hiddenLocked: false) == 0)
        let s = SmartFolderStore.encode([f])
        #expect(SmartFolderStore.decode(s) == [f])
        #expect(SmartFolder(name: "").hasCriteria == false)
    }

    @Test("outline and release notes")
    func misc() {
        let body = "# One\ntext\n```\n# not heading\n```\n## Two\n### Three"
        #expect(MarkdownOutline.headings(in: body).map(\.title) == ["One", "Two", "Three"])
        #expect(!MarkdownOutline.shouldShow(headings: [], wordCount: 1000))
        #expect(ReleaseNotes.shouldShowWhatsNew(lastSeenVersion: "1.0", current: "2.0", hasCompletedOnboarding: true))
        #expect(!ReleaseNotes.shouldShowWhatsNew(lastSeenVersion: "2.0", current: "2.0", hasCompletedOnboarding: true))
    }

    @Test("spotlight policy drops hidden, trashed and untitled; drag payload round-trips")
    func spotlight() {
        let c = [SpotlightPolicy.Candidate(id: "1", title: "Ok", isHidden: false, isTrashed: false),
                 SpotlightPolicy.Candidate(id: "2", title: "Secret", isHidden: true, isTrashed: false),
                 SpotlightPolicy.Candidate(id: "3", title: "Gone", isHidden: false, isTrashed: true),
                 SpotlightPolicy.Candidate(id: "4", title: "  ", isHidden: false, isTrashed: false)]
        #expect(SpotlightPolicy.indexable(c).map(\.id) == ["1"])
        #expect(EntryDragPayload.decode(EntryDragPayload.encode(["a", "b"])) == ["a", "b"])
        #expect(!ContentMasking.canShowContent(isHidden: true, hiddenLocked: true))
    }

    @Test("streak ring milestones, progress and caption")
    func streakRing() {
        #expect(StreakRing.nextMilestone(after: 0) == 3)
        #expect(StreakRing.nextMilestone(after: 3) == 7)
        #expect(StreakRing.nextMilestone(after: 365) == 730)
        #expect(StreakRing.progress(current: 0) == 0)
        #expect(StreakRing.progress(current: 5) == 0.5)          // 3 → 7
        #expect((0...1).contains(StreakRing.progress(current: 400)))
        #expect(StreakRing.progress(current: -4) == 0)
        #expect(StreakRing.caption(current: 6, unit: "day") == "1 more day to 7")
        #expect(StreakRing.caption(current: 4, unit: "week") == "3 more weeks to 7")
    }

    @Test("pinned smart folders round-trip and old data without isPinned still decodes")
    func pinnedFolders() throws {
        var f = SmartFolder(name: "Pin", tags: ["a"])
        f.isPinned = true
        #expect(SmartFolderStore.decode(SmartFolderStore.encode([f])).first?.isPinned == true)
        let legacy = #"[{"id":"x","name":"Old","query":"","tags":["t"],"moods":[],"dateRange":"any","hasAttachment":false,"minWords":0}]"#
        let decoded = SmartFolderStore.decode(legacy)
        #expect(decoded.count == 1 && decoded[0].isPinned == false && decoded[0].tags == ["t"])
    }
}
