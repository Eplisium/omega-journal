#!/bin/bash
set -e

PROJECT_DIR="$HOME/OmegaJournal"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="OmegaJournal"
APP_BUNDLE="$PROJECT_DIR/Omega Journal.app"

BINARY=$(find "$BUILD_DIR" -name "$APP_NAME" -type f -not -path "*/dSYM/*" -not -path "*/DWARF/*" | head -1)
if [ -z "$BINARY" ]; then echo "Error: Binary not found. Run 'swift build' first."; exit 1; fi
echo "Found binary: $BINARY"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Omega Journal</string>
    <key>CFBundleDisplayName</key><string>Omega Journal</string>
    <key>CFBundleIdentifier</key><string>com.eplisium.omega-journal</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>OmegaJournal</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Generate icon
echo "Generating Omega Journal icon..."
swift - << 'ICON'
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
let iconsetPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("OmegaJournal/AppIcon.iconset")
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

let icnsPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("OmegaJournal/Omega Journal.app/Contents/Resources/AppIcon.icns")
let p = Process(); p.launchPath = "/usr/bin/iconutil"
p.arguments = ["-c", "icns", iconsetPath.path, "-o", icnsPath.path]
p.launch(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetPath)
print("Icon generated: \(icnsPath.path)")
ICON

if [ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    echo "Icon added"
fi

echo "Codesigning..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 || true

echo ""
echo "=== Omega Journal.app created ==="
echo "Location: $APP_BUNDLE"
echo "Size: $(du -sh "$APP_BUNDLE" | cut -f1)"
