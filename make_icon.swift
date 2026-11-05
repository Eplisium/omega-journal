import AppKit

// Builds AppIcon.icns from the master artwork `packaging/AppIcon-1024.png`
// (1024×1024, transparent, icon body on the macOS 824px grid with its shadow).
// The master is the "Ω book + ribbon" mark from the 2026-11 rebrand; replace
// that PNG to change the icon. Nothing is drawn here.
//
// Env:
//   OMEGA_JOURNAL_ICON_SOURCE   master PNG (default: <repo>/packaging/AppIcon-1024.png)
//   OMEGA_JOURNAL_PROJECT_DIR   where "Omega Journal.app/Contents/Resources" lives
//                               (oj_make_icon points it at a temp dir)

let env = ProcessInfo.processInfo.environment
let repoDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let sourceURL = URL(fileURLWithPath: env["OMEGA_JOURNAL_ICON_SOURCE"]
    ?? repoDir.appendingPathComponent("packaging/AppIcon-1024.png").path)
let projectDir = URL(fileURLWithPath: env["OMEGA_JOURNAL_PROJECT_DIR"] ?? repoDir.path)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_icon: \(message)\n".utf8))
    exit(1)
}

guard let source = NSImage(contentsOf: sourceURL),
      let master = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("can't read icon master at \(sourceURL.path)") }
guard master.width >= 1024, master.height >= 1024 else {
    fail("icon master must be at least 1024×1024 (got \(master.width)×\(master.height))")
}

/// Exact-pixel PNG. (NSImage.lockFocus renders at the screen's backing scale,
/// so a "16×16" file could come out 32×32.)
func png(_ image: CGImage, pixels: Int) -> Data {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("can't create a \(pixels)px bitmap") }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let scaled = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    else { fail("can't encode the \(pixels)px PNG") }
    return data
}

let iconsetPath = projectDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetPath)
do {
    try FileManager.default.createDirectory(at: iconsetPath, withIntermediateDirectories: true)
} catch { fail("can't create \(iconsetPath.path): \(error)") }

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    do {
        try png(master, pixels: px).write(to: iconsetPath.appendingPathComponent("\(name).png"))
    } catch { fail("can't write \(name).png: \(error)") }
}

let icnsPath = projectDir.appendingPathComponent("Omega Journal.app/Contents/Resources/AppIcon.icns")
try? FileManager.default.createDirectory(at: icnsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconsetPath.path, "-o", icnsPath.path]
do { try p.run() } catch { fail("can't run iconutil: \(error)") }
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetPath)
guard p.terminationStatus == 0 else { fail("iconutil failed (\(p.terminationStatus))") }
print("Icon generated: \(icnsPath.path)")
