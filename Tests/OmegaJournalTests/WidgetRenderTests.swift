import AppKit
import Foundation
import SwiftUI
import Testing
import OmegaJournalShared
import OmegaJournalWidgetUI

/// Renders both widget sizes to PNG so they can be looked at without
/// installing the extension. Set OMEGA_JOURNAL_WIDGET_RENDER_DIR to keep the
/// images; otherwise they go to a temp folder that is deleted.
@Suite("Widget rendering", .serialized)
@MainActor
struct WidgetRenderTests {
    static func render<V: View>(_ view: V, size: CGSize, name: String) throws -> NSImage {
        let renderer = ImageRenderer(content: OmegaWidgetPreviewFrame(size: size) { view })
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "ImageRenderer produced no image for \(name)")
        #expect(image.size.width == size.width)
        #expect(image.size.height == size.height)

        let keep = ProcessInfo.processInfo.environment["OMEGA_JOURNAL_WIDGET_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let dir = keep ?? FileManager.default.temporaryDirectory.appendingPathComponent("oj-widget-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if keep == nil { try? FileManager.default.removeItem(at: dir) } }
        let cg = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        #expect(png.count > 2_000, "\(name) rendered suspiciously small")
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        return image
    }

    static let states: [(String, WidgetDisplayState)] = {
        let now = Date()
        return [
            ("in-progress", .sample(at: now)),
            ("goal-met", WidgetDisplayState(date: now, words: 1_284, goal: 500, streak: 23, streakUnit: "day",
                                            writtenToday: true,
                                            prompt: "Describe a small moment from today you want to remember in ten years.",
                                            lastWrittenText: "Today", hasData: true)),
            ("no-data", .empty(at: now)),
            ("weekly", WidgetDisplayState(date: now, words: 0, goal: 250, streak: 1, streakUnit: "week",
                                          writtenToday: false, prompt: "What are you looking forward to?",
                                          lastWrittenText: "3 days ago", hasData: true)),
        ]
    }()

    @Test("small widget renders every state")
    func small() throws {
        for (name, state) in Self.states {
            _ = try Self.render(OmegaSmallWidgetView(state: state), size: OmegaWidgetPreviewFrame<EmptyView>.smallSize,
                                name: "widget-small-\(name)")
        }
    }

    @Test("medium widget renders every state")
    func medium() throws {
        for (name, state) in Self.states {
            _ = try Self.render(OmegaMediumWidgetView(state: state, newEntryURL: OmegaJournalLink.newEntry.url(),
                                                      linksEnabled: false),
                                size: OmegaWidgetPreviewFrame<EmptyView>.mediumSize, name: "widget-medium-\(name)")
        }
    }
}
