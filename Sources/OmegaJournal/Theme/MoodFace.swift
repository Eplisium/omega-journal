import OmegaJournalCore

extension Mood {
    /// The mood's face from the single `UIMoodGlyph` table. Use this (not a
    /// literal) anywhere a mood is drawn so every surface agrees.
    nonisolated var face: String { UIMoodGlyph.face(forLevel: rawValue) }
}
