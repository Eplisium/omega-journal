import Combine
import Foundation
import OmegaJournalCore
import SwiftUI

// MARK: - Theme Manager
//
// Owns the live palette. Presets come from `ThemePresets` (OmegaJournalCore);
// "Custom" keeps user-picked colors. Persisted via getSetting/setSetting using
// the original keys (themeName, accentColor, backgroundColor, sidebarColor,
// cardColor) plus new optional keys, so older databases load unchanged.

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager(db: .shared)

    // Settings keys
    static let followSystemKey = "themeFollowSystem"
    static let lightPresetKey = "themeLightPreset"
    static let darkPresetKey = "themeDarkPreset"
    static func accentOverrideKey(_ preset: String) -> String { "themeAccentOverride.\(preset)" }

    @Published var accentColor: Color
    @Published var backgroundColor: Color
    @Published var sidebarColor: Color
    @Published var cardColor: Color
    @Published var titleTextColor: Color
    @Published var bodyTextColor: Color
    @Published var secondaryTextColor: Color
    @Published var themeName: String
    @Published var colorScheme: ColorScheme
    @Published private(set) var followSystem: Bool
    @Published private(set) var lightPresetName: String
    @Published private(set) var darkPresetName: String
    /// Per-preset accent overrides (preset name -> hex).
    @Published private(set) var accentOverrides: [String: String]

    private var cancellables = Set<AnyCancellable>()

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
        let name = db.getSetting(SettingKey.themeName, defaultValue: ThemePresets.defaultName)
        let accentHex = db.getSetting(SettingKey.accentColor, defaultValue: "#9d6bff")
        let bgHex = db.getSetting(SettingKey.backgroundColor, defaultValue: "#1a0d2e")
        let sidebarHex = db.getSetting(SettingKey.sidebarColor, defaultValue: "#140823")
        let cardHex = db.getSetting(SettingKey.cardColor, defaultValue: "#241245")
        let initialAccent = Color(hex: accentHex) ?? Color(hex: "#9d6bff")!
        let initialBackground = Color(hex: bgHex) ?? Color(hex: "#1a0d2e")!
        let initialSidebar = Color(hex: sidebarHex) ?? Color(hex: "#140823")!
        let initialCard = Color(hex: cardHex) ?? Color(hex: "#241245")!
        let initialScheme = ThemeManager.scheme(for: initialBackground)
        let textColors = ThemeManager.textColors(for: initialScheme)

        // A saved name that is no longer a preset (retired themes) keeps its saved colors as Custom.
        themeName = (ThemePresets.preset(named: name) != nil || name == ThemePresets.customName) ? name : ThemePresets.customName
        accentColor = initialAccent
        backgroundColor = initialBackground
        sidebarColor = initialSidebar
        cardColor = initialCard
        colorScheme = initialScheme
        titleTextColor = textColors.title
        bodyTextColor = textColors.body
        secondaryTextColor = textColors.secondary
        followSystem = db.bool(Self.followSystemKey)
        lightPresetName = db.getSetting(Self.lightPresetKey, defaultValue: ThemePresets.defaultLightName)
        darkPresetName = db.getSetting(Self.darkPresetKey, defaultValue: ThemePresets.defaultDarkName)
        var overrides: [String: String] = [:]
        for p in ThemePresets.all {
            let v = db.getSetting(Self.accentOverrideKey(p.name), defaultValue: "")
            if !v.isEmpty, ThemeRGB(hex: v) != nil { overrides[p.name] = v }
        }
        accentOverrides = overrides

        // Re-derive text colors (and follow the system light/dark pair) when appearance changes.
        NSApp.publisher(for: \.effectiveAppearance)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.followSystem {
                    self.applySystemPair()
                } else {
                    self.refreshScheme()
                }
            }
            .store(in: &cancellables)

        if followSystem { applySystemPair(persistSelection: false) } else { applyPresetText() }
    }

    // MARK: Derived semantic colors

    /// Text/icon color for content drawn on top of the accent color.
    var onAccentColor: Color { ThemeManager.onAccent(for: accentColor) }

    static func onAccent(for color: Color) -> Color {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let c = ThemeRGB(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
        let l = c.relativeLuminance
        // Contrast vs white = 1.05/(l+.05); vs black = (l+.05)/.05 — pick the better.
        return (l + 0.05) / 0.05 > 1.05 / (l + 0.05) ? .black : .white
    }

    var isDark: Bool { colorScheme == .dark }

    /// Surface levels: 0 = window background, 1 = cards, 2/3 = raised layers (a step toward the text color).
    var surface0: Color { backgroundColor }
    var surface1: Color { cardColor }
    var surface2: Color { surface(mixing: 0.05) }
    var surface3: Color { surface(mixing: 0.10) }

    private func surface(mixing amount: Double) -> Color {
        let base = NSColor(cardColor).usingColorSpace(.sRGB) ?? .gray
        let target: NSColor = isDark ? .white : .black
        return Color(nsColor: base.blended(withFraction: amount, of: target) ?? base)
    }

    var successColor: Color { isDark ? Color(hex: "#4ade80")! : Color(hex: "#15803d")! }
    var warningColor: Color { isDark ? Color(hex: "#fbbf24")! : Color(hex: "#b45309")! }
    var dangerColor: Color { isDark ? Color(hex: "#f87171")! : Color(hex: "#b91c1c")! }

    /// Hairline border color derived from the text color.
    var borderColor: Color { titleTextColor.opacity(isDark ? 0.08 : 0.12) }

    // MARK: Presets

    var currentPreset: ThemePreset? {
        themeName == ThemePresets.customName ? nil : ThemePresets.preset(named: themeName)
    }

    func accentOverride(for preset: String) -> Color? {
        accentOverrides[preset].flatMap { Color(hex: $0) }
    }

    /// Accent shown for a preset in the gallery (override if set).
    func effectiveAccentHex(for preset: ThemePreset) -> String {
        accentOverrides[preset.name] ?? preset.accent
    }

    func applyTheme(named name: String) {
        guard let preset = ThemePresets.preset(named: name) else { return }
        // Picking a preset while following the system updates that side of the pair.
        if followSystem {
            if preset.isDark { darkPresetName = name } else { lightPresetName = name }
            persistPair()
        }
        apply(preset)
        persist()
    }

    private func apply(_ preset: ThemePreset) {
        themeName = preset.name
        accentColor = Color(hex: effectiveAccentHex(for: preset)) ?? Color(hex: preset.accent)!
        backgroundColor = Color(hex: preset.background)!
        sidebarColor = Color(hex: preset.sidebar)!
        cardColor = Color(hex: preset.card)!
        colorScheme = preset.isDark ? .dark : .light
        titleTextColor = Color(hex: preset.title)!
        bodyTextColor = Color(hex: preset.body)!
        secondaryTextColor = Color(hex: preset.secondary)!
    }

    private func applyPresetText() {
        if let p = currentPreset, p.background.lowercased() == backgroundColor.toHex().lowercased() {
            apply(p)
            // Keep a saved accent (override) as stored.
            if let hex = Color(hex: effectiveAccentHex(for: p)) { accentColor = hex }
        }
    }

    /// Sets or clears (nil) the accent override for a preset; applies live if it is the active preset.
    func setAccentOverride(_ color: Color?, for presetName: String) {
        if let color {
            accentOverrides[presetName] = color.toHex()
            db.setSetting(Self.accentOverrideKey(presetName), value: color.toHex())
        } else {
            accentOverrides[presetName] = nil
            db.setSetting(Self.accentOverrideKey(presetName), value: "")
        }
        if themeName == presetName, let p = ThemePresets.preset(named: presetName) {
            accentColor = Color(hex: effectiveAccentHex(for: p)) ?? accentColor
            persist()
        }
    }

    func applyCustom(accent: Color, background: Color, sidebar: Color, card: Color) {
        themeName = ThemePresets.customName
        accentColor = accent
        backgroundColor = background
        sidebarColor = sidebar
        cardColor = card
        colorScheme = ThemeManager.scheme(for: backgroundColor)
        applyTextColors()
        persist()
    }

    // MARK: Follow system

    func setFollowSystem(_ on: Bool) {
        followSystem = on
        db.setBool(Self.followSystemKey, on, asDigit: true)
        if on {
            // Seed the matching side of the pair from the current preset.
            if let p = currentPreset {
                if p.isDark { darkPresetName = p.name } else { lightPresetName = p.name }
            }
            persistPair()
            applySystemPair()
        }
    }

    func setPair(light: String? = nil, dark: String? = nil) {
        if let light, ThemePresets.preset(named: light)?.isDark == false { lightPresetName = light }
        if let dark, ThemePresets.preset(named: dark)?.isDark == true { darkPresetName = dark }
        persistPair()
        if followSystem { applySystemPair() }
    }

    static func systemIsDark() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func applySystemPair(persistSelection: Bool = true) {
        let name = Self.systemIsDark() ? darkPresetName : lightPresetName
        guard let preset = ThemePresets.preset(named: name) else { return }
        apply(preset)
        if persistSelection { persist() }
    }

    private func persistPair() {
        db.setSetting(Self.lightPresetKey, value: lightPresetName)
        db.setSetting(Self.darkPresetKey, value: darkPresetName)
    }

    // MARK: Contrast

    /// Worst-case body-text contrast for the given custom colors (for the editor warning).
    static func contrast(background: Color, sidebar: Color, card: Color) -> Double {
        func rgb(_ c: Color) -> ThemeRGB {
            let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
            return ThemeRGB(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
        }
        return ContrastChecker.worstBodyContrast(background: rgb(background), card: rgb(card), sidebar: rgb(sidebar))
    }

    // MARK: Internals

    func refreshScheme() {
        if let p = currentPreset, p.background.lowercased() == backgroundColor.toHex().lowercased() {
            colorScheme = p.isDark ? .dark : .light
            titleTextColor = Color(hex: p.title)!
            bodyTextColor = Color(hex: p.body)!
            secondaryTextColor = Color(hex: p.secondary)!
        } else {
            colorScheme = ThemeManager.scheme(for: backgroundColor)
            applyTextColors()
        }
    }

    private static func scheme(for color: Color) -> ColorScheme {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let c = ThemeRGB(r: nsColor.redComponent, g: nsColor.greenComponent, b: nsColor.blueComponent)
        return ContrastChecker.isLight(c) ? .light : .dark
    }

    private static func textColors(for scheme: ColorScheme) -> (title: Color, body: Color, secondary: Color) {
        switch scheme {
        case .dark:
            (.white, Color.white.opacity(0.9), Color.white.opacity(0.65))
        case .light:
            (Color.black.opacity(0.9), Color.black.opacity(0.78), Color.black.opacity(0.65))
        @unknown default:
            (.white, Color.white.opacity(0.9), Color.white.opacity(0.65))
        }
    }

    private func applyTextColors() {
        let textColors = Self.textColors(for: colorScheme)
        titleTextColor = textColors.title
        bodyTextColor = textColors.body
        secondaryTextColor = textColors.secondary
    }

    private func persist() {
        db.setSetting(SettingKey.themeName, value: themeName)
        db.setSetting(SettingKey.accentColor, value: accentColor.toHex())
        db.setSetting(SettingKey.backgroundColor, value: backgroundColor.toHex())
        db.setSetting(SettingKey.sidebarColor, value: sidebarColor.toHex())
        db.setSetting(SettingKey.cardColor, value: cardColor.toHex())
    }
}

// MARK: - Color Hex Extensions

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
