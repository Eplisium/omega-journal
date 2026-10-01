import Foundation

// MARK: - Theme preset data (pure)

/// A curated theme, expressed as `#RRGGBB` strings so it is testable without UI frameworks.
public struct ThemePreset: Equatable, Sendable, Identifiable {
    public let name: String
    public let isDark: Bool
    public let accent: String
    public let background: String
    public let sidebar: String
    public let card: String
    /// Opaque text colors (title ≥ body ≥ secondary in emphasis).
    public let title: String
    public let body: String
    public let secondary: String
    public let blurb: String

    public var id: String { name }

    public init(name: String, isDark: Bool, accent: String, background: String, sidebar: String,
                card: String, title: String, body: String, secondary: String, blurb: String) {
        self.name = name; self.isDark = isDark; self.accent = accent; self.background = background
        self.sidebar = sidebar; self.card = card; self.title = title; self.body = body
        self.secondary = secondary; self.blurb = blurb
    }
}

public enum ThemePresets {
    public static let customName = "Custom"
    public static let defaultName = "Purple"
    public static let defaultLightName = "Paper"
    public static let defaultDarkName = "Purple"

    /// Ordered gallery list (Custom is not a preset; it is user-defined colors).
    public static let all: [ThemePreset] = [
        ThemePreset(name: "Purple", isDark: true, accent: "#9d6bff", background: "#1a0d2e", sidebar: "#140823",
                    card: "#241245", title: "#FFFFFF", body: "#EAE4F5", secondary: "#B5A6D0",
                    blurb: "The signature violet glow"),
        ThemePreset(name: "Midnight", isDark: true, accent: "#4a9eff", background: "#0a0e1a", sidebar: "#060912",
                    card: "#121828", title: "#FFFFFF", body: "#E6EAF2", secondary: "#A3ADC2",
                    blurb: "Deep blue-black"),
        ThemePreset(name: "Paper", isDark: false, accent: "#6b3fd6", background: "#faf8f4", sidebar: "#f0ece4",
                    card: "#ffffff", title: "#1c1626", body: "#2f2840", secondary: "#5b5368",
                    blurb: "Clean light page"),
        ThemePreset(name: "Sepia", isDark: false, accent: "#9a4f1c", background: "#f4ecd8", sidebar: "#e9dfc6",
                    card: "#fbf5e6", title: "#2e2112", body: "#4a3a26", secondary: "#6b5a43",
                    blurb: "Warm, bookish light"),
        ThemePreset(name: "Forest", isDark: true, accent: "#4ec9a0", background: "#0a1e16", sidebar: "#06140e",
                    card: "#102a1f", title: "#FFFFFF", body: "#E3F0E9", secondary: "#9FB9AB",
                    blurb: "Mossy green"),
        ThemePreset(name: "Ocean", isDark: true, accent: "#00b4d8", background: "#0a1628", sidebar: "#060e1c",
                    card: "#132240", title: "#FFFFFF", body: "#E2EAF5", secondary: "#9DB0CC",
                    blurb: "Cool teal depths"),
        ThemePreset(name: "Rose", isDark: true, accent: "#e056a0", background: "#1c0a1a", sidebar: "#15050f",
                    card: "#281030", title: "#FFFFFF", body: "#F3E3EE", secondary: "#C4A3B8",
                    blurb: "Soft magenta dusk"),
        ThemePreset(name: "Mono", isDark: true, accent: "#a0a8b4", background: "#161618", sidebar: "#0e0e10",
                    card: "#202024", title: "#FFFFFF", body: "#E8E8EA", secondary: "#A4A4AA",
                    blurb: "Neutral graphite"),
        ThemePreset(name: "High Contrast", isDark: true, accent: "#ffd60a", background: "#000000", sidebar: "#000000",
                    card: "#101010", title: "#FFFFFF", body: "#FFFFFF", secondary: "#D9D9D9",
                    blurb: "Maximum legibility"),
    ]

    public static func preset(named name: String) -> ThemePreset? {
        all.first { $0.name == name }
    }

    public static var darkPresets: [ThemePreset] { all.filter(\.isDark) }
    public static var lightPresets: [ThemePreset] { all.filter { !$0.isDark } }
}
