#!/bin/bash
# Builds a distributable DMG: scripts/make_release.sh [version]
#
# The app is ad-hoc signed by default so no personal signing identity is
# embedded in a public download. To notarize instead, set
# OMEGA_JOURNAL_SIGN_IDENTITY to a "Developer ID Application: …" identity and
# run `xcrun notarytool submit … --wait` + `xcrun stapler staple` on the DMG.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /dev/stdin <<<"$(sed -n '/<plist/,/<\/plist>/p' build_app.sh)" 2>/dev/null || echo 1.0.0)}"
export OMEGA_JOURNAL_SIGN_IDENTITY="${OMEGA_JOURNAL_SIGN_IDENTITY:--}"

bash build_app.sh

APP="$PROJECT_DIR/Omega Journal.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
codesign --force --deep --sign "$OMEGA_JOURNAL_SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

DIST="$PROJECT_DIR/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/Omega-Journal-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Omega Journal $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Built $DMG"
cat "$DMG.sha256"
