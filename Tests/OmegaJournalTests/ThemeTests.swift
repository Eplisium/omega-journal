import Foundation
import Testing
@testable import OmegaJournalCore

@Suite("Theme contrast and presets")
struct ThemeTests {
    @Test func contrastExtremes() {
        #expect(abs(ContrastChecker.ratio(.black, .white) - 21) < 0.001)
        #expect(abs(ContrastChecker.ratio(.white, .white) - 1) < 0.001)
        #expect(ContrastChecker.ratio(hex: "#000000", "#FFFFFF") != nil)
        #expect(ContrastChecker.ratio(hex: "nope", "#FFFFFF") == nil)
    }

    @Test func contrastKnownValue() throws {
        // #777777 on white is the classic ~4.48:1 (fails AA); #767676 passes (~4.54).
        let a = try #require(ContrastChecker.ratio(hex: "#777777", "#FFFFFF"))
        let b = try #require(ContrastChecker.ratio(hex: "#767676", "#FFFFFF"))
        #expect(a < 4.5 && a > 4.4)
        #expect(b >= 4.5)
    }

    @Test func contrastIsSymmetric() throws {
        let a = try #require(ContrastChecker.ratio(hex: "#9d6bff", "#1a0d2e"))
        let b = try #require(ContrastChecker.ratio(hex: "#1a0d2e", "#9d6bff"))
        #expect(abs(a - b) < 1e-9)
    }

    @Test func hexRoundTrip() throws {
        let c = try #require(ThemeRGB(hex: "#9d6bff"))
        #expect(c.hex == "#9D6BFF")
        #expect(ThemeRGB(hex: "12345") == nil)
        #expect(ThemeRGB(hex: "#GGGGGG") == nil)
    }

    @Test func derivedTextWarnsOnMidTones() throws {
        let dark = try #require(ThemeRGB(hex: "#1a0d2e"))
        let mid = try #require(ThemeRGB(hex: "#808080"))
        #expect(ContrastChecker.worstBodyContrast(background: dark, card: dark, sidebar: dark) >= 4.5)
        #expect(ContrastChecker.worstBodyContrast(background: mid, card: mid, sidebar: mid) < 4.5)
    }

    @Test func presetNamesUniqueAndValid() {
        let names = ThemePresets.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.count == 9)
        #expect(!names.contains(ThemePresets.customName))
        #expect(ThemePresets.preset(named: ThemePresets.defaultName) != nil)
        #expect(ThemePresets.preset(named: ThemePresets.defaultLightName)?.isDark == false)
        #expect(ThemePresets.preset(named: ThemePresets.defaultDarkName)?.isDark == true)
    }

    @Test func purpleDefaultUnchanged() throws {
        let p = try #require(ThemePresets.preset(named: "Purple"))
        #expect(p.accent == "#9d6bff" && p.background == "#1a0d2e" && p.sidebar == "#140823" && p.card == "#241245")
    }

    @Test(arguments: ThemePresets.all)
    func presetColorsValid(preset: ThemePreset) {
        for hex in [preset.accent, preset.background, preset.sidebar, preset.card,
                    preset.title, preset.body, preset.secondary] {
            #expect(ThemeRGB(hex: hex) != nil, "\(preset.name): bad hex \(hex)")
        }
    }

    @Test(arguments: ThemePresets.all)
    func presetTextMeetsMinimumContrast(preset: ThemePreset) throws {
        let surfaces = [preset.background, preset.sidebar, preset.card]
        for s in surfaces {
            #expect(try #require(ContrastChecker.ratio(hex: preset.body, s)) >= 4.5, "\(preset.name) body on \(s)")
            #expect(try #require(ContrastChecker.ratio(hex: preset.title, s)) >= 4.5, "\(preset.name) title on \(s)")
            #expect(try #require(ContrastChecker.ratio(hex: preset.secondary, s)) >= 4.5, "\(preset.name) secondary on \(s)")
        }
        // Accent is used for links/icons on the background: UI-component minimum is 3:1.
        #expect(try #require(ContrastChecker.ratio(hex: preset.accent, preset.background)) >= 3.0, "\(preset.name) accent")
        if preset.name == "High Contrast" {
            #expect(try #require(ContrastChecker.ratio(hex: preset.body, preset.background)) >= 7.0)
        }
    }

    @Test func presetDarknessMatchesBackground() throws {
        for p in ThemePresets.all {
            let bg = try #require(ThemeRGB(hex: p.background))
            #expect(ContrastChecker.isLight(bg) == !p.isDark, "\(p.name)")
        }
    }
}
