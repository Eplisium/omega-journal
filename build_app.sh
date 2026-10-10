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

# Build the release binary here and package that exact file. Guessing "the
# newest binary under .build" shipped stale code more than once: SwiftPM's
# build layout moved (.build/<triple>/… → .build/out/Products/…) and old
# products from either layout can be newer than the code you meant to ship.
echo "Building release binary..."
swift build -c release --package-path "$PROJECT_DIR"
BIN_DIR="$(swift build -c release --package-path "$PROJECT_DIR" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
if [ ! -x "$BINARY" ]; then echo "Error: release binary not found at $BINARY"; exit 1; fi
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
# Sign with a STABLE identity when one exists. The journal's encryption key
# lives in the login Keychain, whose access list remembers the app by its
# code signature. Ad-hoc signatures change on every build, so every rebuild
# re-triggered "Omega Journal wants to use your confidential information"
# and blocked launch until the login password was typed. With a certificate
# identity, "Always Allow" survives rebuilds.
#   OMEGA_JOURNAL_SIGN_IDENTITY="<name>"  pick one explicitly ("-" = ad-hoc)
SIGN_IDENTITY="${OMEGA_JOURNAL_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    echo "Signing identity: $SIGN_IDENTITY"
    if ! codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"; then
        echo "Warning: signing with '$SIGN_IDENTITY' failed; falling back to ad-hoc (Keychain will re-prompt)."
        codesign --force --deep --sign - "$APP_BUNDLE"
    fi
else
    echo "No development identity found; signing ad-hoc (Keychain will prompt after each rebuild)."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi
codesign --verify --strict "$APP_BUNDLE"

echo ""
echo "=== Omega Journal.app created ==="
echo "Location: $APP_BUNDLE"
echo "Size: $(du -sh "$APP_BUNDLE" | cut -f1)"
