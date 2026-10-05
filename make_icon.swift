import AppKit

let size = CGSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()

// Deep gradient background (indigo to dark purple)
let bg = NSGradient(colors: [
    NSColor(srgbRed: 0.25, green: 0.30, blue: 0.55, alpha: 1.0),
    NSColor(srgbRed: 0.12, green: 0.15, blue: 0.35, alpha: 1.0),
    NSColor(srgbRed: 0.06, green: 0.08, blue: 0.20, alpha: 1.0)
])
bg?.draw(in: NSRect(origin: .zero, size: size), angle: -90)

// Subtle radial glow
let glow = NSBezierPath(ovalIn: NSRect(x: 200, y: 200, width: 624, height: 624))
NSColor(srgbRed: 0.35, green: 0.40, blue: 0.70, alpha: 0.15).setFill()
glow.fill()

// Draw large Omega symbol (Ω)
let omegaFont = NSFont(name: "Georgia-Bold", size: 580) ?? NSFont.systemFont(ofSize: 580, weight: .bold)
let omegaAttr: [NSAttributedString.Key: Any] = [
    .font: omegaFont,
    .foregroundColor: NSColor.white,
    .shadow: {
        let s = NSShadow()
        s.shadowColor = NSColor(srgbRed: 0.20, green: 0.25, blue: 0.50, alpha: 0.6)
        s.shadowBlurRadius = 20
        s.shadowOffset = NSSize(width: 0, height: -4)
        return s
    }()
]
let omegaStr = NSAttributedString(string: "Ω", attributes: omegaAttr)
let omegaSize = omegaStr.size()
let omegaRect = NSRect(
    x: (size.width - omegaSize.width) / 2,
    y: (size.height - omegaSize.height) / 2 - 20,
    width: omegaSize.width,
    height: omegaSize.height
)
omegaStr.draw(with: omegaRect, options: [.usesLineFragmentOrigin], context: nil)

// Small "JOURNAL" text at bottom
let labelFont = NSFont(name: "HelveticaNeue-Light", size: 36) ?? NSFont.systemFont(ofSize: 36, weight: .light)
let labelAttr: [NSAttributedString.Key: Any] = [
    .font: labelFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.5)
]
let labelStr = NSAttributedString(string: "JOURNAL", attributes: labelAttr)
let labelSize = labelStr.size()
let labelRect = NSRect(
    x: (size.width - labelSize.width) / 2,
    y: 100,
    width: labelSize.width,
    height: labelSize.height
)
labelStr.draw(with: labelRect, options: [.usesLineFragmentOrigin], context: nil)

img.unlockFocus()

// Build iconset
let projectDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMEGA_JOURNAL_PROJECT_DIR"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OmegaJournal").path)
let iconsetPath = projectDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetPath)
try! FileManager.default.createDirectory(at: iconsetPath, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let s = NSImage(size: CGSize(width: px, height: px))
    s.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: CGSize(width: px, height: px)))
    s.unlockFocus()
    let data = NSBitmapImageRep(data: s.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! data.write(to: iconsetPath.appendingPathComponent("\(name).png"))
}

let icnsPath = projectDir
    .appendingPathComponent("Omega Journal.app/Contents/Resources/AppIcon.icns")
let p = Process(); p.launchPath = "/usr/bin/iconutil"
p.arguments = ["-c", "icns", iconsetPath.path, "-o", icnsPath.path]
p.launch(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetPath)
print("Icon generated: \(icnsPath.path)")
