#!/bin/bash
set -e

# Resolve the project directory from this script's own location so the repo
# can be checked out at any path (issue #1: hardcoding $HOME/OmegaJournal
# broke clones like ~/omega-journal).
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="OmegaJournal"
APP_BUNDLE="$PROJECT_DIR/Omega Journal.app"

# The icon-generation heredoc below needs the project dir as well; hand it
# over via the environment so arbitrary checkout locations work (issue #1).
export OMEGA_JOURNAL_PROJECT_DIR="$PROJECT_DIR"

# Prefer the newest binary. A plain `find | head -1` can pick a stale
# release build over a just-compiled debug binary and ship old SQL.
BINARY=$(find "$BUILD_DIR" -name "$APP_NAME" -type f -not -path "*/dSYM/*" -not -path "*/DWARF/*" -print0 \
    | xargs -0 ls -t 2>/dev/null | head -1)
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
    <key>NSMicrophoneUsageDescription</key><string>Omega Journal uses the microphone only when you record a voice memo to attach to an entry. Recordings are stored encrypted on this Mac.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Generate icon
echo "Generating Omega Journal icon..."
swift "$PROJECT_DIR/make_icon.swift"

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
