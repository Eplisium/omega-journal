import Foundation

// MARK: - Mood faces (pure, single source)
//
// "Bad" used 😕 (a confused face) which reads as neutral next to 😐, so the
// five moods did not look ordered. One table now drives every mood face:
// each step is a distinct, clearly ordered expression.

public enum UIMoodGlyph {
    /// Faces for mood levels 1 (awful) … 5 (great).
    public static let faces = ["😞", "🙁", "😐", "🙂", "😄"]
    public static let labels = ["Awful", "Bad", "Neutral", "Good", "Great"]

    /// Face for a mood level (1…5); out-of-range values clamp, so a rounded
    /// chart value never draws an empty label.
    public static func face(forLevel level: Int) -> String {
        faces[min(max(level, 1), 5) - 1]
    }

    public static func label(forLevel level: Int) -> String {
        labels[min(max(level, 1), 5) - 1]
    }
}
