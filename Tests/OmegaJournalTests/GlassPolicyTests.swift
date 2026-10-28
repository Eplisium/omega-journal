import Foundation
import Testing
@testable import OmegaJournal

@Suite("Liquid Glass surface policy")
struct GlassPolicyTests {
    static let navigation: [GlassSurface] = [.windowToolbar, .floatingPanel, .toolbarControl, .primaryAction]
    static let content: [GlassSurface] = [.contentCard, .entryRow, .readingColumn]

    @Test func everySurfaceIsClassified() {
        #expect(Set(Self.navigation + Self.content) == Set(GlassSurface.allCases))
        for s in Self.navigation { #expect(s.layer == .navigation) }
        for s in Self.content { #expect(s.layer == .content) }
    }

    @Test(arguments: [14, 15])
    func noGlassBeforeMacOS26(os: Int) {
        #expect(!GlassPolicy.isGlassAvailable(osMajorVersion: os))
        for s in GlassSurface.allCases {
            #expect(!GlassPolicy.usesGlass(s, osMajorVersion: os), "\(s) must keep the solid look on macOS \(os)")
        }
    }

    @Test(arguments: [26, 27])
    func navigationLayerGetsGlassOnMacOS26AndLater(os: Int) {
        #expect(GlassPolicy.isGlassAvailable(osMajorVersion: os))
        for s in Self.navigation { #expect(GlassPolicy.usesGlass(s, osMajorVersion: os)) }
    }

    @Test(arguments: [14, 15, 26, 27])
    func contentNeverGetsGlass(os: Int) {
        for s in Self.content {
            #expect(!GlassPolicy.usesGlass(s, osMajorVersion: os), "\(s) is content and stays solid")
        }
    }

    @Test func tintIsAFaintWashOnPanelsAndFullOnPrimaryActions() {
        #expect(GlassPolicy.tintOpacity(for: .floatingPanel, reduceTransparency: false) > 0)
        #expect(GlassPolicy.tintOpacity(for: .floatingPanel, reduceTransparency: false) <= 0.15)
        #expect(GlassPolicy.tintOpacity(for: .primaryAction, reduceTransparency: false) == 1)
        #expect(GlassPolicy.tintOpacity(for: .toolbarControl, reduceTransparency: false) == 0)
    }

    @Test func reduceTransparencyDropsTheDecorativeWashButKeepsPrimaryTint() {
        #expect(GlassPolicy.tintOpacity(for: .floatingPanel, reduceTransparency: true) == 0)
        #expect(GlassPolicy.tintOpacity(for: .primaryAction, reduceTransparency: true) == 1)
    }

    @Test func increaseContrastBordersFloatingPanelsOnly() {
        #expect(GlassPolicy.drawsContrastBorder(on: .floatingPanel, increaseContrast: true))
        #expect(!GlassPolicy.drawsContrastBorder(on: .floatingPanel, increaseContrast: false))
        #expect(!GlassPolicy.drawsContrastBorder(on: .toolbarControl, increaseContrast: true))
    }

    @Test func modalDimIsLighterOnlyForTranslucentGlass() {
        let old = GlassPolicy.modalDimOpacity(glass: false, reduceTransparency: false)
        #expect(GlassPolicy.modalDimOpacity(glass: true, reduceTransparency: false) < old)
        #expect(GlassPolicy.modalDimOpacity(glass: true, reduceTransparency: true) == old)
        #expect(GlassPolicy.modalDimOpacity(glass: false, reduceTransparency: true) == old)
    }

    @Test func runtimeSupportMatchesTheRunningOS() {
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        for s in GlassSurface.allCases {
            #expect(GlassSupport.usesGlass(s) == GlassPolicy.usesGlass(s, osMajorVersion: os))
        }
    }
}
