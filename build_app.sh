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
#   OMEGA_JOURNAL_BUNDLE_ID=<prod id>.qa-x  QA build under its own bundle id, App Group and URL
#                                          scheme, written to .build/packaging/qa/<id>/ instead
#                                          of the repo root (never registers as the real app)
#
# The bundle embeds the widget extension (Contents/PlugIns/OmegaJournalWidgets.appex,
# sandboxed) and App Intents metadata (Contents/Resources/Metadata.appintents).
#
# Distribution builds: scripts/make_release.sh (DMG) and scripts/make_mas.sh (App Store).
set -euo pipefail

# Resolve the project directory from this script's own location so the repo
# can be checked out at any path (issue #1).
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OJ_PROJECT_DIR="$PROJECT_DIR"
# shellcheck source=scripts/lib/oj-packaging.sh
source "$PROJECT_DIR/scripts/lib/oj-packaging.sh"

BUNDLE_ID="${OMEGA_JOURNAL_BUNDLE_ID:-$OJ_PRODUCTION_BUNDLE_ID}"
if [ "$BUNDLE_ID" = "$OJ_PRODUCTION_BUNDLE_ID" ]; then
    APP_BUNDLE="$PROJECT_DIR/$OJ_APP_NAME.app"
else
    case "$BUNDLE_ID" in "$OJ_PRODUCTION_BUNDLE_ID".qa-*) ;; *) oj_die "OMEGA_JOURNAL_BUNDLE_ID must be $OJ_PRODUCTION_BUNDLE_ID or $OJ_PRODUCTION_BUNDLE_ID.qa-<name>";; esac
    APP_BUNDLE="$PROJECT_DIR/.build/packaging/qa/$BUNDLE_ID/$OJ_APP_NAME.app"
    mkdir -p "$(dirname "$APP_BUNDLE")"
fi
VERSION="$(oj_version)"
BUILD_NUMBER="$(oj_build_number)"

# Build the release binary here and package that exact file (guessing "the newest
# binary under .build" shipped stale code more than once).
oj_build_binary "${OMEGA_JOURNAL_ARCHS:-host}"
oj_check_binary_sdk "$OJ_BINARY" warn

oj_assemble_bundle "$APP_BUNDLE" "$OJ_BINARY" direct "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER"

# Sign with a STABLE identity when one exists. The journal's encryption key lives in
# the login Keychain, whose access list remembers the app by its code signature.
# Ad-hoc signatures change on every build, so every rebuild re-prompted for the login
# password. With a certificate identity, "Always Allow" survives rebuilds.
SIGN_IDENTITY="${OMEGA_JOURNAL_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(oj_find_codesign_identity "Apple Development: " || true)"
fi
ENT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oj-ent.XXXXXX")"
trap 'rm -rf "$ENT_DIR"' EXIT
ENTITLEMENTS="$ENT_DIR/OmegaJournal-Direct.entitlements"
WIDGET_ENTITLEMENTS="$ENT_DIR/OmegaJournalWidgets.entitlements"
oj_prepare_entitlements "$OJ_PACKAGING_DIR/OmegaJournal-Direct.entitlements" "$ENTITLEMENTS" "$BUNDLE_ID"
oj_prepare_entitlements "$OJ_PACKAGING_DIR/OmegaJournalWidgets.entitlements" "$WIDGET_ENTITLEMENTS" "$BUNDLE_ID"
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    if ! oj_sign_app "$APP_BUNDLE" "$SIGN_IDENTITY" "$ENTITLEMENTS" --runtime --widget-entitlements "$WIDGET_ENTITLEMENTS"; then
        oj_warn "signing with '$SIGN_IDENTITY' failed; falling back to ad-hoc (Keychain will re-prompt)."
        oj_sign_app "$APP_BUNDLE" - "$ENTITLEMENTS" --runtime --widget-entitlements "$WIDGET_ENTITLEMENTS"
    fi
else
    echo "No development identity found; signing ad-hoc (Keychain will prompt after each rebuild)."
    echo "Ad-hoc builds have no team id, so the widget may not be able to read the App Group."
    oj_sign_app "$APP_BUNDLE" - "$ENTITLEMENTS" --runtime --widget-entitlements "$WIDGET_ENTITLEMENTS"
fi
oj_verify_widget "$APP_BUNDLE" "$BUNDLE_ID"

echo ""
echo "=== $OJ_APP_NAME.app created ==="
echo "Location: $APP_BUNDLE"
echo "Version:  $VERSION ($BUILD_NUMBER), channel direct, bundle id $BUNDLE_ID"
echo "Widget:   Contents/PlugIns/$OJ_WIDGET_APPEX ($(oj_widget_bundle_id "$BUNDLE_ID")), App Group $(oj_app_group "$BUNDLE_ID")"
echo "Size:     $(du -sh "$APP_BUNDLE" | cut -f1)"
