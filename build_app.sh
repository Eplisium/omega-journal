#!/bin/bash
# Local dev build: packages "Omega Journal.app" in the repo root for daily use.
#
#   bash build_app.sh
#
# Channel "direct", NOT sandboxed, hardened runtime + packaging/OmegaJournal-Direct.entitlements
# (microphone for voice memos), signed with your Apple Development identity so the
# Keychain "Always Allow" for the journal key survives rebuilds.
#   OMEGA_JOURNAL_SIGN_IDENTITY="<name>"   pick an identity explicitly ("-" = ad-hoc)
#   OMEGA_JOURNAL_ARCHS=universal          build arm64 + x86_64 (default: this Mac only)
#
# Distribution builds: scripts/make_release.sh (DMG) and scripts/make_mas.sh (App Store).
set -euo pipefail

# Resolve the project directory from this script's own location so the repo
# can be checked out at any path (issue #1).
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OJ_PROJECT_DIR="$PROJECT_DIR"
# shellcheck source=scripts/lib/oj-packaging.sh
source "$PROJECT_DIR/scripts/lib/oj-packaging.sh"

APP_BUNDLE="$PROJECT_DIR/$OJ_APP_NAME.app"
VERSION="$(oj_version)"
BUILD_NUMBER="$(oj_build_number)"

# Build the release binary here and package that exact file (guessing "the newest
# binary under .build" shipped stale code more than once).
oj_build_binary "${OMEGA_JOURNAL_ARCHS:-host}"
oj_check_binary_sdk "$OJ_BINARY" warn

oj_assemble_bundle "$APP_BUNDLE" "$OJ_BINARY" direct "$OJ_PRODUCTION_BUNDLE_ID" "$VERSION" "$BUILD_NUMBER"

# Sign with a STABLE identity when one exists. The journal's encryption key lives in
# the login Keychain, whose access list remembers the app by its code signature.
# Ad-hoc signatures change on every build, so every rebuild re-prompted for the login
# password. With a certificate identity, "Always Allow" survives rebuilds.
SIGN_IDENTITY="${OMEGA_JOURNAL_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(oj_find_codesign_identity "Apple Development: " || true)"
fi
ENTITLEMENTS="$OJ_PACKAGING_DIR/OmegaJournal-Direct.entitlements"
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    if ! oj_sign_app "$APP_BUNDLE" "$SIGN_IDENTITY" "$ENTITLEMENTS" --runtime; then
        oj_warn "signing with '$SIGN_IDENTITY' failed; falling back to ad-hoc (Keychain will re-prompt)."
        oj_sign_app "$APP_BUNDLE" - "$ENTITLEMENTS" --runtime
    fi
else
    echo "No development identity found; signing ad-hoc (Keychain will prompt after each rebuild)."
    oj_sign_app "$APP_BUNDLE" - "$ENTITLEMENTS" --runtime
fi

echo ""
echo "=== $OJ_APP_NAME.app created ==="
echo "Location: $APP_BUNDLE"
echo "Version:  $VERSION ($BUILD_NUMBER), channel direct"
echo "Size:     $(du -sh "$APP_BUNDLE" | cut -f1)"
