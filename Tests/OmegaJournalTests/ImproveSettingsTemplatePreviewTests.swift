import Foundation
import Testing
@testable import OmegaJournal
import OmegaJournalCore

@Suite("Improve Settings: template picker preview")
struct ImproveSettingsTemplatePreviewTests {
    private let ctx: TemplateContext = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9))!
        return TemplateContext(date: date, prompt: "What surprised you?", moodLabel: "Okay",
                               calendar: cal, locale: Locale(identifier: "en_US"))
    }()

    private func builtIn(_ name: String) throws -> EntryTemplate {
        try #require(EntryTemplate.builtIns.first { $0.name == name })
    }

    private func summary(_ t: EntryTemplate) -> TemplatePickerSummary {
        TemplatePickerPreview.summary(name: t.name, body: t.body, tags: t.tags,
                                      knownPurpose: TemplatePickerPreview.builtInPurposes[t.name], context: ctx)
    }

    @Test("every built-in template has a plain-language purpose")
    func builtInPurposes() {
        for t in EntryTemplate.builtIns {
            let purpose = TemplatePickerPreview.builtInPurposes[t.name]
            #expect(purpose != nil, "\(t.name) has no purpose")
            #expect(!(purpose ?? "").contains("{{"))
        }
    }

    @Test("Daily Reflection: sub-headings become sections; page heading and variables are filled")
    func dailyReflection() throws {
        let s = summary(try builtIn("Daily Reflection"))
        #expect(s.sections == ["Highlights", "Challenges", "Grateful for", "Tomorrow"])
        #expect(s.entryTitle == "Daily Reflection")
        #expect(s.filledBody.hasPrefix("# Tuesday, October 13, 2026"))
        #expect(!s.filledBody.contains("{{"))
        #expect(s.tags == ["daily"])
        #expect(!s.isBlank)
    }

    @Test("bold labels and colon prompts count as sections", arguments: [
        ("Dream Log", ["Setting", "What happened", "How it felt", "Possible meaning"]),
        ("Decision Log", ["Decision", "Options considered", "What I chose and why", "How I'll know it worked"]),
        ("Gratitude", ["Why they mattered"]),
        ("Weekly Review", ["What went well", "What didn't", "Lessons learned", "Focus for next week"]),
    ])
    func labelledSections(name: String, expected: [String]) throws {
        #expect(summary(try builtIn(name)).sections == expected)
    }

    @Test("Blank creates an untitled, empty entry")
    func blank() throws {
        let s = summary(try builtIn("Blank"))
        #expect(s.entryTitle.isEmpty)
        #expect(s.isBlank)
        #expect(s.sections.isEmpty)
        #expect(s.displayName == "Blank")
    }

    /// The old picker card printed the raw template name, so a name like
    /// "{{weekday}} check-in" showed braces even though the entry title is filled in.
    @Test("variables in a template name are filled in for the list and the entry title")
    func variableName() {
        let s = TemplatePickerPreview.summary(name: "{{weekday}} check-in", body: "Mood: {{mood}}",
                                              tags: ["{{weekday}}"], context: ctx)
        #expect(s.displayName == "Tuesday check-in")
        #expect(s.entryTitle == "Tuesday check-in")
        #expect(s.tags == ["Tuesday"])
        #expect(s.filledBody == "Mood: Okay")
    }

    @Test("custom templates describe themselves from their content")
    func derivedPurpose() {
        let many = TemplatePickerPreview.summary(
            name: "Run log", body: "## Route\n## Distance\n## Pace\n## Weather\n## Notes", tags: [], context: ctx)
        #expect(many.purpose == "Prompts for Route, Distance, Pace, and 2 more.")
        let prose = TemplatePickerPreview.summary(
            name: "Morning", body: "Write three pages without stopping.", tags: [], context: ctx)
        #expect(prose.purpose == "Write three pages without stopping.")
        let empty = TemplatePickerPreview.summary(name: "Empty", body: "  \n", tags: [], context: ctx)
        #expect(empty.purpose.hasPrefix("An empty page"))
        #expect(empty.isBlank)
    }

    @Test("an edited built-in uses its own content, not the stock purpose")
    func editedBuiltIn() {
        // The picker passes `knownPurpose` only when name AND body still match a built-in.
        let s = TemplatePickerPreview.summary(name: "Gratitude", body: "## Person\n## Moment", tags: [], context: ctx)
        #expect(s.purpose == "Prompts for Person, Moment.")
    }

    @Test("headings inside code fences and a lone page title are handled")
    func fencesAndTitles() {
        #expect(TemplatePickerPreview.sections(in: "```\n## not a section\n```\n## Real") == ["Real"])
        #expect(TemplatePickerPreview.sections(in: "# Only a title\n\nSome text") == ["Only a title"])
        #expect(TemplatePickerPreview.sections(in: "- item:\n* other:") == [])
    }

    @Test("selection survives edits and falls back to the first template")
    func selectionResolution() {
        #expect(TemplatePickerPreview.resolveSelection(current: "b", available: ["a", "b"]) == "b")
        #expect(TemplatePickerPreview.resolveSelection(current: "gone", available: ["a", "b"]) == "a")
        #expect(TemplatePickerPreview.resolveSelection(current: nil, available: ["a"]) == "a")
        #expect(TemplatePickerPreview.resolveSelection(current: "a", available: []) == nil)
    }
}
