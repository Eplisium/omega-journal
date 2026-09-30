import Testing
import AppKit
import Foundation
@testable import OmegaJournal

@Suite("Attachment preview helpers")
@MainActor
struct AttachmentPreviewTests {
    private func pngData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test("thumbnails are capped to the max pixel size, keeping aspect")
    func thumbnailCap() throws {
        let t = try #require(AttachmentPreview.thumbnail(from: pngData(width: 2000, height: 1000), maxPixel: 300))
        let rep = try #require(t.representations.first)
        #expect(max(rep.pixelsWide, rep.pixelsHigh) <= 300)
        #expect(rep.pixelsWide == 300 && rep.pixelsHigh == 150)
    }

    @Test("small images are not upscaled; garbage yields nil")
    func smallAndGarbage() throws {
        let t = try #require(AttachmentPreview.thumbnail(from: pngData(width: 40, height: 20), maxPixel: 300))
        #expect(t.representations.first?.pixelsWide == 40)
        #expect(AttachmentPreview.thumbnail(from: Data([1, 2, 3]), maxPixel: 300) == nil)
    }

    @Test("cache returns the same image for the same key")
    func cache() throws {
        let key = "test-\(UUID().uuidString)"
        #expect(AttachmentPreview.cached(key) == nil)
        let img = try #require(AttachmentPreview.thumbnail(from: pngData(width: 10, height: 10), maxPixel: 50))
        AttachmentPreview.store(img, for: key)
        #expect(AttachmentPreview.cached(key) === img)
    }

    @Test("temp file and its private folder are removed after the delay")
    func tempCleanup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omega-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pic.png")
        try Data([1]).write(to: file)
        AttachmentPreview.scheduleTempCleanup(of: file, after: 0.15)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
