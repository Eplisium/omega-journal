import Foundation
import SwiftUI

// MARK: - Theme Manager

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var accentColor: Color
    @Published var backgroundColor: Color
    @Published var sidebarColor: Color
    @Published var cardColor: Color
    @Published var titleTextColor: Color
    @Published var bodyTextColor: Color
    @Published var secondaryTextColor: Color
    @Published var themeName: String
    @Published var colorScheme: ColorScheme

    private init() {
        let db = DatabaseManager.shared
        let name = db.getSetting("themeName", defaultValue: "Purple")
        let accentHex = db.getSetting("accentColor", defaultValue: "#9d6bff")
        let bgHex = db.getSetting("backgroundColor", defaultValue: "#1a0d2e")
        let sidebarHex = db.getSetting("sidebarColor", defaultValue: "#140823")
        let cardHex = db.getSetting("cardColor", defaultValue: "#241245")
        themeName = name
        accentColor = Color(hex: accentHex) ?? Color(hex: "#9d6bff")!
        backgroundColor = Color(hex: bgHex) ?? Color(hex: "#1a0d2e")!
        sidebarColor = Color(hex: sidebarHex) ?? Color(hex: "#140823")!
        cardColor = Color(hex: cardHex) ?? Color(hex: "#241245")!
        titleTextColor = .white
        bodyTextColor = Color.white.opacity(0.9)
        secondaryTextColor = Color.white.opacity(0.55)
        colorScheme = ThemeManager.scheme(for: Color(hex: bgHex) ?? Color(hex: "#1a0d2e")!)

        // Auto-switch when system appearance changes
        NSApp.publisher(for: \.effectiveAppearance)
            .sink { [weak self] _ in
                guard let self else { return }
                self.colorScheme = ThemeManager.scheme(for: self.backgroundColor)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    func applyTheme(named name: String) {
        guard let preset = ThemePresets.all[name] else { return }
        themeName = name
        accentColor = preset.accent
        backgroundColor = preset.background
        sidebarColor = preset.sidebar
        cardColor = preset.card
        colorScheme = ThemeManager.scheme(for: backgroundColor)
        persist()
    }

    func applyCustom(accent: Color, background: Color, sidebar: Color, card: Color) {
        themeName = "Custom"
        accentColor = accent
        backgroundColor = background
        sidebarColor = sidebar
        cardColor = card
        colorScheme = ThemeManager.scheme(for: backgroundColor)
        persist()
    }

    func refreshScheme() {
        colorScheme = ThemeManager.scheme(for: backgroundColor)
    }

    private static func scheme(for color: Color) -> ColorScheme {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let luminance = (0.2126 * nsColor.redComponent) +
            (0.7152 * nsColor.greenComponent) +
            (0.0722 * nsColor.blueComponent)
        return luminance > 0.55 ? .light : .dark
    }

    private func persist() {
        let db = DatabaseManager.shared
        db.setSetting("themeName", value: themeName)
        db.setSetting("accentColor", value: accentColor.toHex())
        db.setSetting("backgroundColor", value: backgroundColor.toHex())
        db.setSetting("sidebarColor", value: sidebarColor.toHex())
        db.setSetting("cardColor", value: cardColor.toHex())
    }
}

// MARK: - Theme Presets

struct ThemePreset {
    let name: String
    let accent: Color
    let background: Color
    let sidebar: Color
    let card: Color
    let swatchColors: [Color]
}

enum ThemePresets {
    static let all: [String: ThemePreset] = [
        "Purple": ThemePreset(
            name: "Purple",
            accent: Color(hex: "#9d6bff")!,
            background: Color(hex: "#1a0d2e")!,
            sidebar: Color(hex: "#140823")!,
            card: Color(hex: "#241245")!,
            swatchColors: [Color(hex: "#9d6bff")!, Color(hex: "#1a0d2e")!]
        ),
        "Midnight": ThemePreset(
            name: "Midnight",
            accent: Color(hex: "#4a9eff")!,
            background: Color(hex: "#0a0e1a")!,
            sidebar: Color(hex: "#060912")!,
            card: Color(hex: "#121828")!,
            swatchColors: [Color(hex: "#4a9eff")!, Color(hex: "#0a0e1a")!]
        ),
        "Brave": ThemePreset(
            name: "Brave",
            accent: Color(hex: "#FB542B")!,
            background: Color(hex: "#17191F")!,
            sidebar: Color(hex: "#101216")!,
            card: Color(hex: "#242830")!,
            swatchColors: [Color(hex: "#FB542B")!, Color(hex: "#17191F")!]
        ),
        "Forest": ThemePreset(
            name: "Forest",
            accent: Color(hex: "#4ec9a0")!,
            background: Color(hex: "#0a1e16")!,
            sidebar: Color(hex: "#06140e")!,
            card: Color(hex: "#102a1f")!,
            swatchColors: [Color(hex: "#4ec9a0")!, Color(hex: "#0a1e16")!]
        ),
        "Sunset": ThemePreset(
            name: "Sunset",
            accent: Color(hex: "#ff7e5f")!,
            background: Color(hex: "#1f0d12")!,
            sidebar: Color(hex: "#17080c")!,
            card: Color(hex: "#2e1620")!,
            swatchColors: [Color(hex: "#ff7e5f")!, Color(hex: "#1f0d12")!]
        ),
        "Rose": ThemePreset(
            name: "Rose",
            accent: Color(hex: "#e056a0")!,
            background: Color(hex: "#1c0a1a")!,
            sidebar: Color(hex: "#15050f")!,
            card: Color(hex: "#281030")!,
            swatchColors: [Color(hex: "#e056a0")!, Color(hex: "#1c0a1a")!]
        ),
        "Graphite": ThemePreset(
            name: "Graphite",
            accent: Color(hex: "#8899aa")!,
            background: Color(hex: "#161618")!,
            sidebar: Color(hex: "#0e0e10")!,
            card: Color(hex: "#202024")!,
            swatchColors: [Color(hex: "#8899aa")!, Color(hex: "#161618")!]
        ),
        "Ocean": ThemePreset(
            name: "Ocean",
            accent: Color(hex: "#00b4d8")!,
            background: Color(hex: "#0a1628")!,
            sidebar: Color(hex: "#060e1c")!,
            card: Color(hex: "#132240")!,
            swatchColors: [Color(hex: "#00b4d8")!, Color(hex: "#0a1628")!]
        ),
        "Ember": ThemePreset(
            name: "Ember",
            accent: Color(hex: "#ff4500")!,
            background: Color(hex: "#1a0a0a")!,
            sidebar: Color(hex: "#120505")!,
            card: Color(hex: "#2a1414")!,
            swatchColors: [Color(hex: "#ff4500")!, Color(hex: "#1a0a0a")!]
        ),
        "Mint": ThemePreset(
            name: "Mint",
            accent: Color(hex: "#6ee7b7")!,
            background: Color(hex: "#0a1a14")!,
            sidebar: Color(hex: "#061210")!,
            card: Color(hex: "#142a22")!,
            swatchColors: [Color(hex: "#6ee7b7")!, Color(hex: "#0a1a14")!]
        ),
    ]
}

// MARK: - Color Hex Extensions

import Combine

extension Color {
    init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        let r, g, b, a: Double
        guard let hexNum = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            r = Double((hexNum >> 16) & 0xFF) / 255.0
            g = Double((hexNum >> 8) & 0xFF) / 255.0
            b = Double(hexNum & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((hexNum >> 24) & 0xFF) / 255.0
            g = Double((hexNum >> 16) & 0xFF) / 255.0
            b = Double((hexNum >> 8) & 0xFF) / 255.0
            a = Double(hexNum & 0xFF) / 255.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHex() -> String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
