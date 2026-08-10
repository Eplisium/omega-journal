import Foundation

// MARK: - Entry Template

/// A reusable skeleton for a new entry — a title-less body with pre-filled prompts and tags.
struct EntryTemplate: Identifiable, Hashable {
    let id: String
    var name: String
    var body: String
    var tags: [String]
    var icon: String
    var sortOrder: Int

    init(id: String = UUID().uuidString, name: String, body: String, tags: [String] = [], icon: String = "doc.text", sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.body = body
        self.tags = tags
        self.icon = icon
        self.sortOrder = sortOrder
    }

    /// Seeded into the database on first launch of schema v5.
    static let builtIns: [EntryTemplate] = [
        EntryTemplate(
            name: "Daily Reflection",
            body: """
            ## Highlights
            -

            ## Challenges
            -

            ## Grateful for
            -

            ## Tomorrow
            -
            """,
            tags: ["daily"],
            icon: "sun.max"
        ),
        EntryTemplate(
            name: "Gratitude",
            body: """
            Three things I'm grateful for today:

            1.
            2.
            3.

            Why they mattered:
            """,
            tags: ["gratitude"],
            icon: "heart"
        ),
        EntryTemplate(
            name: "Weekly Review",
            body: """
            # Week in Review

            ## What went well


            ## What didn't


            ## Lessons learned


            ## Focus for next week
            -
            """,
            tags: ["weekly", "review"],
            icon: "calendar.badge.clock"
        ),
        EntryTemplate(
            name: "Dream Log",
            body: """
            **Setting:**

            **What happened:**

            **How it felt:**

            **Possible meaning:**
            """,
            tags: ["dreams"],
            icon: "moon.stars"
        ),
        EntryTemplate(
            name: "Decision Log",
            body: """
            **Decision:**

            **Options considered:**
            -

            **What I chose and why:**

            **How I'll know it worked:**
            """,
            tags: ["decisions"],
            icon: "arrow.triangle.branch"
        ),
        EntryTemplate(
            name: "Blank",
            body: "",
            tags: [],
            icon: "doc"
        ),
    ]
}
