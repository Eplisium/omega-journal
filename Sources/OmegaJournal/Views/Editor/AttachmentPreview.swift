import AppKit
import ImageIO

/// Helpers for showing and opening attachments without holding plaintext longer
/// than needed: capped thumbnails (decoding a multi-megapixel photo per row on
/// every redraw is costly), an in-memory cache, and delayed removal of the
/// decrypted temp copies handed to external apps.
enum AttachmentPreview {

    /// Decodes `data` to an image no larger than `maxPixel` on its longest side,
    /// keeping aspect ratio. Smaller images are returned at their own size
    /// (never upscaled). Returns nil for data that is not a decodable image.
    static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard maxPixel > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var cg: CGImage?
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int, max(w, h) <= maxPixel {
            cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let cg else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    // MARK: Cache

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()

    static func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    static func store(_ image: NSImage, for key: String) { cache.setObject(image, forKey: key as NSString) }

    // MARK: Temp copies

    /// Removes a decrypted temp file and the private folder it lives in after
    /// `delay` seconds (the external app has read it by then). The launch/quit
    /// sweep in `JournalCrypto` remains the backstop.
    static func scheduleTempCleanup(of file: URL, after delay: TimeInterval = 120) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            let fm = FileManager.default
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: file.deletingLastPathComponent())
        }
    }
}
