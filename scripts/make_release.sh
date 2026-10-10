#!/bin/bash
# Builds a distributable DMG: scripts/make_release.sh [version]
#
# Ad-hoc signed by default (no personal identity in a public download; users
# need "Open Anyway" on first launch).
#
# Notarized build (no Gatekeeper warning):
#   1. One time: create a "Developer ID Application" certificate (Xcode →
#      Settings → Accounts → Manage Certificates → + ), then store notary
#      credentials:  xcrun notarytool store-credentials omega-notary \
#                      --apple-id <you> --team-id <TEAMID>   (prompts for an
#                      app-specific password from account.apple.com)
#   2. OMEGA_JOURNAL_SIGN_IDENTITY="Developer ID Application: …" \
#      OMEGA_JOURNAL_NOTARY_PROFILE=omega-notary scripts/make_release.sh 1.0.2
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /dev/stdin <<<"$(sed -n '/<plist/,/<\/plist>/p' build_app.sh)" 2>/dev/null || echo 1.0.0)}"
export OMEGA_JOURNAL_SIGN_IDENTITY="${OMEGA_JOURNAL_SIGN_IDENTITY:--}"

bash build_app.sh

APP="$PROJECT_DIR/Omega Journal.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
if [ "$OMEGA_JOURNAL_SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  # Notarization requires the hardened runtime and a secure timestamp.
  codesign --force --deep --options runtime --timestamp --sign "$OMEGA_JOURNAL_SIGN_IDENTITY" "$APP"
fi
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

if [ -n "${OMEGA_JOURNAL_NOTARY_PROFILE:-}" ]; then
  codesign --force --timestamp --sign "$OMEGA_JOURNAL_SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$OMEGA_JOURNAL_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Built $DMG"
cat "$DMG.sha256"
