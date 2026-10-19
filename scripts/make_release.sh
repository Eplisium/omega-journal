#!/bin/bash
# Builds the direct-download DMG (GitHub Releases): scripts/make_release.sh [version]
#
# The version comes from the VERSION file at the repo root; passing one is only a
# sanity check (the script stops if it differs, so the DMG name, the app and the tag agree).
#
# Output: dist/Omega-Journal-<version>.dmg (+ .sha256). The app is assembled in
# .build/packaging/direct/, so the local dev "Omega Journal.app" (and its Keychain
# "Always Allow") is left alone.
#
# What it builds:
#   - universal binary (arm64 + x86_64)
#   - channel "direct", bundle id com.eplisium.omega-journal, NOT sandboxed
#   - hardened runtime + packaging/OmegaJournal-Direct.entitlements (microphone for
#     voice memos; the 1.0.2 DMG lacked it, so recording silently failed)
#
# Ad-hoc signed by default (users need "Open Anyway" on first launch).
#
# Notarized build (no Gatekeeper warning):
#   1. One time: create a "Developer ID Application" certificate (Xcode → Settings →
#      Accounts → Manage Certificates → + ), then store notary credentials:
#        xcrun notarytool store-credentials omega-notary --apple-id <you> --team-id <TEAMID>
#      (prompts for an app-specific password from account.apple.com)
#   2. OMEGA_JOURNAL_SIGN_IDENTITY="Developer ID Application: …" \
#      OMEGA_JOURNAL_NOTARY_PROFILE=omega-notary scripts/make_release.sh
#
# Other knobs:
#   OMEGA_JOURNAL_BUILD_NUMBER   CFBundleVersion (default: git commit count)
#   OMEGA_JOURNAL_DIST_DIR       output folder (default: dist/)
#   OMEGA_JOURNAL_ARCHS=host     skip the universal build (local smoke tests only)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OJ_PROJECT_DIR="$PROJECT_DIR"
# shellcheck source=lib/oj-packaging.sh
source "$PROJECT_DIR/scripts/lib/oj-packaging.sh"
cd "$PROJECT_DIR"

VERSION="$(oj_version)"
if [ -n "${1:-}" ] && [ "$1" != "$VERSION" ]; then
    oj_die "asked for version $1 but VERSION says $VERSION. Update the VERSION file (single source of truth) and rerun."
fi
BUILD_NUMBER="$(oj_build_number)"
IDENTITY="${OMEGA_JOURNAL_SIGN_IDENTITY:--}"
ARCHS="${OMEGA_JOURNAL_ARCHS:-universal}"
DIST="${OMEGA_JOURNAL_DIST_DIR:-$PROJECT_DIR/dist}"
ENTITLEMENTS="$OJ_PACKAGING_DIR/OmegaJournal-Direct.entitlements"

oj_build_binary "$ARCHS"
oj_check_binary_sdk "$OJ_BINARY" warn

STAGE_APP_DIR="$PROJECT_DIR/.build/packaging/direct"
APP="$STAGE_APP_DIR/$OJ_APP_NAME.app"
mkdir -p "$STAGE_APP_DIR"
oj_assemble_bundle "$APP" "$OJ_BINARY" direct "$OJ_PRODUCTION_BUNDLE_ID" "$VERSION" "$BUILD_NUMBER"

if [ "$IDENTITY" = "-" ]; then
    # No secure timestamp for ad-hoc signatures.
    oj_sign_app "$APP" - "$ENTITLEMENTS" --runtime
else
    # Notarization requires the hardened runtime and a secure timestamp.
    oj_sign_app "$APP" "$IDENTITY" "$ENTITLEMENTS" --runtime --timestamp
fi

# Guard the shipped bug: the hardened runtime must come with the microphone entitlement.
[ "$(oj_entitlement "$APP" ':com.apple.security.device.audio-input')" = "true" ] \
    || oj_die "signed app is missing com.apple.security.device.audio-input (voice memos would fail)"
[ -z "$(oj_entitlement "$APP" ':com.apple.security.app-sandbox')" ] \
    || oj_die "direct build must not be sandboxed"
[[ "$(codesign -d --verbose=2 "$APP" 2>&1)" == *"flags="*"runtime"* ]] \
    || oj_die "hardened runtime flag missing from signature"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/oj-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/Omega-Journal-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Omega Journal $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ -n "${OMEGA_JOURNAL_NOTARY_PROFILE:-}" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$OMEGA_JOURNAL_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Built $DMG ($VERSION build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/$OJ_EXECUTABLE"))"
cat "$DMG.sha256"
