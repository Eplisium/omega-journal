#!/bin/bash
# Builds the Mac App Store package: scripts/make_mas.sh [options]
#
#   scripts/make_mas.sh                 build + sign + verify → dist/OmegaJournal-<ver>-<build>.pkg
#   scripts/make_mas.sh --validate      … then `xcrun altool --validate-app` (App Store Connect checks)
#   scripts/make_mas.sh --upload        … then validate and upload to App Store Connect (TestFlight)
#   scripts/make_mas.sh --dev           smoke-test mode (also --dry-run or OMEGA_JOURNAL_MAS_DEV=1):
#                                       sandboxed bundle signed with Apple Development, QA bundle id,
#                                       no provisioning profile, no .pkg. Never touches the real journal.
#
# Production mode needs (see docs/app-store/SUBMISSION.md for how to create them):
#   OMEGA_JOURNAL_MAS_PROFILE              path to the "Mac App Store Connect" .provisionprofile
#                                          for com.eplisium.omega-journal
#   OMEGA_JOURNAL_MAS_WIDGET_PROFILE       path to the "Mac App Store Connect" .provisionprofile
#                                          for the widget extension, App ID
#                                          com.eplisium.omega-journal.widgets (App Groups
#                                          capability). App Store extensions need their own
#                                          profile, embedded in the .appex.
#   (or OMEGA_JOURNAL_MAS_SKIP_WIDGET=1    ship without the widget extension until that
#                                          profile exists; App Intents are unaffected)
#   OMEGA_JOURNAL_MAS_APP_IDENTITY         default: first "Apple Distribution: …" or
#                                          "3rd Party Mac Developer Application: …" identity
#   OMEGA_JOURNAL_MAS_INSTALLER_IDENTITY   default: first "3rd Party Mac Developer Installer: …" or
#                                          "Mac Installer Distribution: …" identity
#   ASC_KEY_ID, ASC_ISSUER_ID              App Store Connect API key (only for --validate/--upload);
#                                          key file AuthKey_<ASC_KEY_ID>.p8 in ~/.appstoreconnect/private_keys
#                                          (or set ASC_KEY_PATH to the .p8 file)
# Optional:
#   OMEGA_JOURNAL_BUILD_NUMBER   CFBundleVersion (default: git commit count; must grow per upload)
#   OMEGA_JOURNAL_DIST_DIR       output folder (default: dist/)
#   OMEGA_JOURNAL_ARCHS=host     dev mode only: skip the universal build
#   OMEGA_JOURNAL_MAS_QA_BUNDLE_ID   dev mode bundle id (default com.eplisium.omega-journal.qa-pipeline)
#   --migration-probe <Name>     dev mode only: embed a manifest that moves
#                                ~/Library/Application Support/<Name> (a fake folder) and
#                                ~/Library/Preferences/<QA bundle id>.plist into the QA container,
#                                to prove the manifest format live
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OJ_PROJECT_DIR="$PROJECT_DIR"
# shellcheck source=lib/oj-packaging.sh
source "$PROJECT_DIR/scripts/lib/oj-packaging.sh"
cd "$PROJECT_DIR"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

DEV="${OMEGA_JOURNAL_MAS_DEV:-0}"
VALIDATE=0
UPLOAD=0
PROBE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dev|--dry-run) DEV=1;;
        --validate) VALIDATE=1;;
        --upload) UPLOAD=1; VALIDATE=1;;
        --migration-probe) PROBE="${2:-}"; shift;;
        -h|--help) usage; exit 0;;
        *) usage; oj_die "unknown option: $1";;
    esac
    shift
done
[ "$DEV" = "1" ] || [ "$DEV" = "0" ] || DEV=1

VERSION="$(oj_version)"
BUILD_NUMBER="$(oj_build_number)"
DIST="${OMEGA_JOURNAL_DIST_DIR:-$PROJECT_DIR/dist}"
ENT_SRC="$OJ_PACKAGING_DIR/OmegaJournal-AppStore.entitlements"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/oj-mas.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Friendly preflight: list everything missing at once, before the long build.
# ---------------------------------------------------------------------------
MISSING=()
need() { MISSING+=("$1"); }

print_missing_and_exit() {
    {
        echo ""
        echo "Omega Journal can't be packaged for the Mac App Store yet. Missing:"
        local item
        for item in "${MISSING[@]}"; do printf '  • %s\n' "$item"; done
        echo ""
        echo "Step-by-step: docs/app-store/SUBMISSION.md (section \"Certificates, App ID and profile\")."
        echo "To smoke-test the sandboxed bundle without any of these: scripts/make_mas.sh --dev"
    } >&2
    exit 1
}

PROFILE_PLIST="$WORK/profile.plist"
check_profile() {
    local profile="$1" identity_sha1="$2" want_id="${3:-$OJ_PRODUCTION_BUNDLE_ID}"
    if ! security cms -D -i "$profile" > "$PROFILE_PLIST" 2>/dev/null; then
        need "OMEGA_JOURNAL_MAS_PROFILE ($profile) is not a readable provisioning profile."
        return
    fi
    local pb=/usr/libexec/PlistBuddy appid team platform expiry now
    appid="$($pb -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    # iOS-style profiles use the un-prefixed key; read it only to name the wrong profile.
    [ -n "$appid" ] || appid="$($pb -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    team="$($pb -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST" 2>/dev/null || true)"
    platform="$($pb -c 'Print :Platform:0' "$PROFILE_PLIST" 2>/dev/null || true)"
    if [ "$appid" != "$OJ_TEAM_ID.$want_id" ]; then
        need "Provisioning profile $(basename "$profile") is for '$appid'; it must be for the explicit App ID $OJ_TEAM_ID.$want_id."
    fi
    [ "$team" = "$OJ_TEAM_ID" ] || need "Provisioning profile team is '$team'; expected $OJ_TEAM_ID."
    [ "$platform" = "OSX" ] || need "Provisioning profile platform is '$platform'; it must be a macOS profile."
    if $pb -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" >/dev/null 2>&1; then
        need "That is a development profile (it lists devices). Create a \"Mac App Store Connect\" distribution profile."
    fi
    if $pb -c 'Print :ProvisionsAllDevices' "$PROFILE_PLIST" >/dev/null 2>&1; then
        need "That is a Developer ID profile. Create a \"Mac App Store Connect\" distribution profile."
    fi
    expiry="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -n "$expiry" ] && [[ "$expiry" < "$now" ]]; then
        need "Provisioning profile expired on $expiry. Regenerate it in Certificates, Identifiers & Profiles."
    fi
    if [ -n "$identity_sha1" ]; then
        local count i found=0 sha
        count="$(plutil -extract DeveloperCertificates raw -o - "$PROFILE_PLIST" 2>/dev/null || echo 0)"
        i=0
        while [ "$i" -lt "$count" ]; do
            sha="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$PROFILE_PLIST" | base64 -D | shasum -a 1 | awk '{print toupper($1)}')"
            [ "$sha" = "$identity_sha1" ] && found=1
            i=$((i + 1))
        done
        [ "$found" = "1" ] || need "The provisioning profile doesn't include the signing certificate '$APP_IDENTITY'. Edit the profile, tick that certificate, download it again."
    fi
}

if [ "$DEV" = "1" ]; then
    [ "$VALIDATE" = "0" ] || oj_die "--validate/--upload need a real App Store build; drop --dev."
    BUNDLE_ID="${OMEGA_JOURNAL_MAS_QA_BUNDLE_ID:-$OJ_PRODUCTION_BUNDLE_ID.qa-pipeline}"
    # Hard rule: dev mode must never create (and burn) the production container.
    [ "$BUNDLE_ID" != "$OJ_PRODUCTION_BUNDLE_ID" ] || oj_die "dev mode refuses the production bundle id"
    case "$BUNDLE_ID" in "$OJ_PRODUCTION_BUNDLE_ID".*) ;; *) oj_die "QA bundle id must start with $OJ_PRODUCTION_BUNDLE_ID.";; esac
    APP_IDENTITY="${OMEGA_JOURNAL_MAS_APP_IDENTITY:-$(oj_find_codesign_identity "Apple Development: " || true)}"
    [ -n "$APP_IDENTITY" ] || APP_IDENTITY="-"
    ARCHS="${OMEGA_JOURNAL_ARCHS:-universal}"
else
    [ -z "$PROBE" ] || oj_die "--migration-probe is only for --dev builds"
    BUNDLE_ID="$OJ_PRODUCTION_BUNDLE_ID"
    ARCHS=universal
    APP_IDENTITY="${OMEGA_JOURNAL_MAS_APP_IDENTITY:-$(oj_find_codesign_identity "Apple Distribution: " "3rd Party Mac Developer Application: " || true)}"
    INSTALLER_IDENTITY="${OMEGA_JOURNAL_MAS_INSTALLER_IDENTITY:-$(oj_find_any_identity "3rd Party Mac Developer Installer: " "Mac Installer Distribution: " || true)}"
    APP_SHA1=""
    if [ -z "$APP_IDENTITY" ]; then
        need "An \"Apple Distribution\" certificate (Certificates, Identifiers & Profiles → Certificates → + → Apple Distribution), installed in your login keychain."
    else
        APP_SHA1="$(oj_identity_sha1 "$APP_IDENTITY")"
        [ -n "$APP_SHA1" ] || need "Signing identity '$APP_IDENTITY' was not found in the keychain."
        case "$APP_IDENTITY" in
            "Apple Distribution: "*|"3rd Party Mac Developer Application: "*|[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*) ;;
            *) need "'$APP_IDENTITY' can't sign for the App Store. Use an \"Apple Distribution\" certificate (or scripts/make_mas.sh --dev for a local smoke test)." ;;
        esac
    fi
    if [ -z "$INSTALLER_IDENTITY" ]; then
        need "A \"Mac Installer Distribution\" certificate (Certificates → + → Mac Installer Distribution), installed in your login keychain. It signs the .pkg."
    elif [[ "$(security find-identity -v 2>/dev/null)" != *"\"$INSTALLER_IDENTITY\""* ]]; then
        need "Installer identity '$INSTALLER_IDENTITY' was not found in the keychain (security find-identity -v)."
    fi
    PROFILE="${OMEGA_JOURNAL_MAS_PROFILE:-}"
    if [ -z "$PROFILE" ]; then
        need "OMEGA_JOURNAL_MAS_PROFILE=/path/to/OmegaJournal_MAS.provisionprofile (Profiles → + → Mac App Store Connect → App ID com.eplisium.omega-journal → your Apple Distribution certificate)."
    elif [ ! -f "$PROFILE" ]; then
        need "OMEGA_JOURNAL_MAS_PROFILE points to '$PROFILE', which doesn't exist."
    else
        check_profile "$PROFILE" "$APP_SHA1"
    fi
    WIDGET_PROFILE="${OMEGA_JOURNAL_MAS_WIDGET_PROFILE:-}"
    if [ "${OMEGA_JOURNAL_MAS_SKIP_WIDGET:-0}" = "1" ]; then
        oj_warn "OMEGA_JOURNAL_MAS_SKIP_WIDGET=1: this package will not contain the widget extension."
    elif [ -z "$WIDGET_PROFILE" ]; then
        need "OMEGA_JOURNAL_MAS_WIDGET_PROFILE=/path/to/OmegaJournalWidgets_MAS.provisionprofile (Identifiers → + → App IDs → $(oj_widget_bundle_id "$OJ_PRODUCTION_BUNDLE_ID") with the App Groups capability; then Profiles → + → Mac App Store Connect → that App ID → your Apple Distribution certificate). Or set OMEGA_JOURNAL_MAS_SKIP_WIDGET=1 to ship without the widget."
    elif [ ! -f "$WIDGET_PROFILE" ]; then
        need "OMEGA_JOURNAL_MAS_WIDGET_PROFILE points to '$WIDGET_PROFILE', which doesn't exist."
    else
        check_profile "$WIDGET_PROFILE" "$APP_SHA1" "$(oj_widget_bundle_id "$OJ_PRODUCTION_BUNDLE_ID")"
    fi
    if [ "$VALIDATE" = "1" ]; then
        [ -n "${ASC_KEY_ID:-}" ] || need "ASC_KEY_ID (App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys; role App Manager)."
        [ -n "${ASC_ISSUER_ID:-}" ] || need "ASC_ISSUER_ID (shown above the keys list on the same page)."
        if [ -n "${ASC_KEY_ID:-}" ]; then
            if [ -n "${ASC_KEY_PATH:-}" ]; then
                [ -f "$ASC_KEY_PATH" ] || need "ASC_KEY_PATH points to '$ASC_KEY_PATH', which doesn't exist."
            else
                found_key=0
                for d in ./private_keys "$HOME/private_keys" "$HOME/.private_keys" "$HOME/.appstoreconnect/private_keys" "${API_PRIVATE_KEYS_DIR:-/nonexistent}"; do
                    [ -f "$d/AuthKey_${ASC_KEY_ID}.p8" ] && found_key=1
                done
                [ "$found_key" = "1" ] || need "The API key file AuthKey_${ASC_KEY_ID}.p8 in ~/.appstoreconnect/private_keys/ (or set ASC_KEY_PATH). It can only be downloaded once."
            fi
        fi
    fi
    [ "${#MISSING[@]}" -eq 0 ] || print_missing_and_exit
fi

# ---------------------------------------------------------------------------
# Build + assemble
# ---------------------------------------------------------------------------
oj_build_binary "$ARCHS"
if [ "$DEV" = "1" ]; then
    oj_check_binary_sdk "$OJ_BINARY" warn
    STAGE_DIR="$PROJECT_DIR/.build/packaging/appstore-dev"
else
    oj_check_binary_sdk "$OJ_BINARY"
    STAGE_DIR="$PROJECT_DIR/.build/packaging/appstore"
fi
mkdir -p "$STAGE_DIR"
APP="$STAGE_DIR/$OJ_APP_NAME.app"

MIGRATION="$OJ_PACKAGING_DIR/container-migration.plist"
ENTITLEMENTS="$WORK/OmegaJournal-AppStore.entitlements"
oj_prepare_entitlements "$ENT_SRC" "$ENTITLEMENTS" "$BUNDLE_ID"
# Widget extension: sandbox + App Group; production adds the identifiers its own
# provisioning profile grants (application-identifier must match <app id>.widgets).
WIDGET_ENTITLEMENTS="$WORK/OmegaJournalWidgets.entitlements"
oj_prepare_entitlements "$OJ_PACKAGING_DIR/OmegaJournalWidgets.entitlements" "$WIDGET_ENTITLEMENTS" "$BUNDLE_ID"
SKIP_WIDGET="${OMEGA_JOURNAL_MAS_SKIP_WIDGET:-0}"
if [ "$DEV" = "0" ] && [ "$SKIP_WIDGET" != "1" ]; then
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.application-identifier string $OJ_TEAM_ID.$(oj_widget_bundle_id "$BUNDLE_ID")" \
        -c "Add :com.apple.developer.team-identifier string $OJ_TEAM_ID" "$WIDGET_ENTITLEMENTS" >/dev/null
fi
if [ "$DEV" = "1" ]; then
    # The real manifest would MOVE the real journal into the QA container. Dev builds
    # embed either nothing or a probe manifest for a fake folder.
    if [ -n "$PROBE" ]; then
        [[ "$PROBE" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$PROBE" != "OmegaJournal" ] \
            || oj_die "--migration-probe needs a plain folder name other than OmegaJournal"
        MIGRATION="$WORK/container-migration.plist"
        plutil -create xml1 "$MIGRATION"
        plutil -insert Move -array "$MIGRATION"
        # Same two entry shapes as the real manifest: a folder in Application Support
        # and this (QA) bundle id's preferences file.
        plutil -insert Move.0 -string "\${ApplicationSupport}/$PROBE" "$MIGRATION"
        plutil -insert Move.1 -string "\${Library}/Preferences/$BUNDLE_ID.plist" "$MIGRATION"
    else
        MIGRATION=""
    fi
    # These three need a provisioning profile; without one the app would not launch.
    for key in com.apple.application-identifier com.apple.developer.team-identifier keychain-access-groups; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$ENTITLEMENTS" >/dev/null
    done
fi

oj_assemble_bundle "$APP" "$OJ_BINARY" appstore "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER" "$MIGRATION"
APPEX="$APP/Contents/PlugIns/$OJ_WIDGET_APPEX"
if [ "$SKIP_WIDGET" = "1" ]; then
    rm -rf "$APP/Contents/PlugIns"
fi
if [ "$DEV" = "1" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Omega Journal (QA)" "$APP/Contents/Info.plist"
else
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    [ ! -d "$APPEX" ] || cp "$WIDGET_PROFILE" "$APPEX/Contents/embedded.provisionprofile"
fi

# Hardened runtime is optional for the Mac App Store but harmless; keep parity with the DMG.
# oj_sign_app signs the widget extension first, then the app (no --deep).
if [ "$DEV" = "1" ]; then
    oj_sign_app "$APP" "$APP_IDENTITY" "$ENTITLEMENTS" --runtime --widget-entitlements "$WIDGET_ENTITLEMENTS"
else
    oj_sign_app "$APP" "$APP_IDENTITY" "$ENTITLEMENTS" --runtime --timestamp --widget-entitlements "$WIDGET_ENTITLEMENTS"
fi

# ---------------------------------------------------------------------------
# Verify the bundle
# ---------------------------------------------------------------------------
oj_note "Verifying bundle"
pb=/usr/libexec/PlistBuddy
plist="$APP/Contents/Info.plist"
[ "$($pb -c 'Print :OJDistributionChannel' "$plist")" = "appstore" ] || oj_die "OJDistributionChannel is not appstore"
[ "$($pb -c 'Print :CFBundleIdentifier' "$plist")" = "$BUNDLE_ID" ] || oj_die "unexpected bundle id"
[ "$($pb -c 'Print :ITSAppUsesNonExemptEncryption' "$plist")" = "false" ] || oj_die "ITSAppUsesNonExemptEncryption must be false"
[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ] || oj_die "PrivacyInfo.xcprivacy missing"
[ "$(oj_entitlement "$APP" ':com.apple.security.app-sandbox')" = "true" ] || oj_die "App Sandbox entitlement missing"
[ "$(oj_entitlement "$APP" ':com.apple.security.device.audio-input')" = "true" ] || oj_die "audio-input entitlement missing"
ENT_XML="$(oj_dump_entitlements "$APP")"
case "$ENT_XML" in *com.apple.security.network.*) oj_die "network entitlement present; the app must not have one";; esac
if [ "$SKIP_WIDGET" = "1" ]; then
    [ ! -d "$APPEX" ] || oj_die "OMEGA_JOURNAL_MAS_SKIP_WIDGET=1 but $OJ_WIDGET_APPEX is present"
    oj_verify_appintents_metadata "$APP"
else
    oj_verify_widget "$APP" "$BUNDLE_ID" runtime
    case "$(oj_dump_entitlements "$APPEX")" in *com.apple.security.network.*) oj_die "widget extension has a network entitlement";; esac
fi

if [ "$DEV" = "1" ]; then
    echo ""
    echo "=== Mac App Store DEV bundle (sandboxed, NOT for upload) ==="
    echo "App:        $APP"
    echo "Bundle id:  $BUNDLE_ID   (container: ~/Library/Containers/$BUNDLE_ID)"
    echo "Signed by:  $APP_IDENTITY"
    if [ -d "$APPEX" ]; then
        echo "Widget:     $OJ_WIDGET_APPEX ($(oj_widget_bundle_id "$BUNDLE_ID"), sandboxed, App Group $(oj_app_group "$BUNDLE_ID"))"
        echo "            no provisioning profile in dev mode; an App Store upload needs OMEGA_JOURNAL_MAS_WIDGET_PROFILE"
    fi
    if [ -n "$PROBE" ]; then
        echo "Migration:  probe manifest: ~/Library/Application Support/$PROBE and"
        echo "            ~/Library/Preferences/$BUNDLE_ID.plist move into the container on first launch"
    else
        echo "Migration:  none embedded (the real manifest would move the real journal)"
    fi
    QA_DATA="\$HOME/Library/Containers/$BUNDLE_ID/Data/tmp/ojqa"
    echo "Launch it with throwaway test data only (sandboxed apps can only write inside the container):"
    echo "  open -n \"$APP\" \\"
    echo "    --env OMEGA_JOURNAL_TEST_DATABASE_PATH=\"$QA_DATA/journal.sqlite3\" \\"
    echo "    --env OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH=\"$QA_DATA/attachments\""
    echo "Use 'open' (LaunchServices): launched from a shell, macOS attributes the container migration to"
    echo "the shell and App Data protection blocks the folder move."
    echo "Clean up afterwards: in Finder, move ~/Library/Containers/$BUNDLE_ID to the Trash"
    echo "(Terminal is usually refused by App Data protection)."
    exit 0
fi

[ -f "$APP/Contents/Resources/container-migration.plist" ] || oj_die "container-migration.plist missing"
[ "$(oj_entitlement "$APP" ':com.apple.application-identifier')" = "$OJ_TEAM_ID.$OJ_PRODUCTION_BUNDLE_ID" ] \
    || oj_die "application-identifier entitlement does not match $OJ_TEAM_ID.$OJ_PRODUCTION_BUNDLE_ID"
security cms -D -i "$APP/Contents/embedded.provisionprofile" > "$WORK/embedded.plist" 2>/dev/null \
    || oj_die "embedded.provisionprofile is unreadable"
[ "$($pb -c 'Print :Entitlements:com.apple.application-identifier' "$WORK/embedded.plist")" = "$OJ_TEAM_ID.$OJ_PRODUCTION_BUNDLE_ID" ] \
    || oj_die "embedded profile app id does not match the entitlements"
if [ -d "$APPEX" ]; then
    [ "$(oj_entitlement "$APPEX" ':com.apple.application-identifier')" = "$OJ_TEAM_ID.$(oj_widget_bundle_id "$OJ_PRODUCTION_BUNDLE_ID")" ] \
        || oj_die "widget application-identifier entitlement does not match its App ID"
    security cms -D -i "$APPEX/Contents/embedded.provisionprofile" > "$WORK/widget-embedded.plist" 2>/dev/null \
        || oj_die "widget embedded.provisionprofile is unreadable"
    [ "$($pb -c 'Print :Entitlements:com.apple.application-identifier' "$WORK/widget-embedded.plist")" = "$OJ_TEAM_ID.$(oj_widget_bundle_id "$OJ_PRODUCTION_BUNDLE_ID")" ] \
        || oj_die "widget embedded profile app id does not match its entitlements"
fi
oj_note "Entitlements:"
printf '%s\n' "$ENT_XML" | plutil -p - 2>/dev/null || printf '%s\n' "$ENT_XML"

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------
mkdir -p "$DIST"
PKG="$DIST/OmegaJournal-$VERSION-$BUILD_NUMBER.pkg"
rm -f "$PKG"
oj_note "productbuild → $PKG"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
pkgutil --check-signature "$PKG" || oj_die "installer signature check failed"

ALTOOL_AUTH=(--api-key "${ASC_KEY_ID:-}" --api-issuer "${ASC_ISSUER_ID:-}")
[ -z "${ASC_KEY_PATH:-}" ] || ALTOOL_AUTH+=(--p8-file-path "$ASC_KEY_PATH")
if [ "$VALIDATE" = "1" ]; then
    oj_note "Validating with App Store Connect (altool --validate-app)"
    xcrun altool --validate-app "$PKG" "${ALTOOL_AUTH[@]}" --output-format normal \
        || oj_die "App Store Connect validation failed (see messages above)"
fi
if [ "$UPLOAD" = "1" ]; then
    oj_note "Uploading to App Store Connect (altool --upload-package)"
    xcrun altool --upload-package "$PKG" "${ALTOOL_AUTH[@]}" --show-progress --output-format normal \
        || oj_die "upload failed (see messages above)"
    echo "Uploaded. The build appears in App Store Connect → TestFlight after processing (usually 5-30 min)."
fi

echo ""
echo "=== Mac App Store package ready ==="
echo "Package:  $PKG"
echo "Version:  $VERSION ($BUILD_NUMBER)"
echo "App:      $APP"
[ "$VALIDATE" = "1" ] || echo "Next:     scripts/make_mas.sh --upload   (or upload $PKG with Transporter)"
