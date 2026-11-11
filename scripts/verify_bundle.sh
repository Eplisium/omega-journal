#!/bin/bash
# Validates a packaged "Omega Journal.app" without needing any signing identity.
#
#   scripts/verify_bundle.sh ["Omega Journal.app"] [--channel direct|appstore] [--bundle-id <id>]
#
# Works on ad-hoc signed bundles (CI: `OMEGA_JOURNAL_SIGN_IDENTITY=- bash build_app.sh`), on
# Apple Development / Developer ID builds, and on `scripts/make_mas.sh --dev` output.
# Defaults: the repo-root app, the channel and bundle id recorded in its Info.plist
# (production id or <production id>.qa-<name>).
#
# Checks:
#   Info.plist        plutil -lint, bundle id, executable, LSMinimumSystemVersion 14.0, version
#                     matches VERSION, export-compliance key, channel/App Group/URL scheme keys,
#                     usage strings for every privacy-sensitive framework the binary links
#   Binaries          minimum OS 14.0 recorded in LC_BUILD_VERSION (app and widget)
#   Signature         codesign --verify --deep --strict (ad-hoc is fine)
#   Entitlements      codesign -d --entitlements -: valid plist, microphone, App Group, sandbox
#                     off for direct / on for App Store
#   Widget            Contents/PlugIns/OmegaJournalWidgets.appex: Info.plist, extension point,
#                     bundle id, executable, sandbox + App Group entitlements
#   Privacy manifest  Contents/Resources/PrivacyInfo.xcprivacy present, valid, identical to
#                     packaging/PrivacyInfo.xcprivacy, no tracking, a reason for every API type
#   Resources         AppIcon.icns, Metadata.appintents
#
# Prints one line per check and exits non-zero if any check failed (all checks always run).
# Bash 3.2 compatible (macOS /bin/bash). Read-only: never launches or modifies the bundle.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTION_ID="com.eplisium.omega-journal"
TEAM_ID="WWC5HJN6AL"
EXECUTABLE="OmegaJournal"
WIDGET_EXECUTABLE="OmegaJournalWidgets"
WIDGET_POINT="com.apple.widgetkit-extension"
MIN_OS="14.0"
PB=/usr/libexec/PlistBuddy

APP="$PROJECT_DIR/Omega Journal.app"
CHANNEL=""
BUNDLE_ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="${2:-}"; shift;;
        --bundle-id) BUNDLE_ID="${2:-}"; shift;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0;;
        -*) echo "unknown option: $1" >&2; exit 2;;
        *) APP="$1";;
    esac
    shift
done
APP="${APP%/}"

FAILURES=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n%s\n' "$*"; }
# check "<description>" <command...>: passes when the command succeeds.
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi; }
# expect "<description>" "<actual>" "<expected>"
expect() {
    if [ "$2" = "$3" ]; then pass "$1 = $3"; else fail "$1: expected '$3', got '${2:-<missing>}'"; fi
}
plist_get() { $PB -c "Print :$2" "$1" 2>/dev/null; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/oj-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ ! -d "$APP" ]; then
    echo "No bundle at $APP (build one with: OMEGA_JOURNAL_SIGN_IDENTITY=- bash build_app.sh)" >&2
    exit 1
fi
INFO="$APP/Contents/Info.plist"
APPEX="$APP/Contents/PlugIns/$WIDGET_EXECUTABLE.appex"
WINFO="$APPEX/Contents/Info.plist"
echo "Verifying $APP"

# ---------------------------------------------------------------- Info.plist
section "Info.plist"
if ! plutil -lint -s "$INFO" 2>/dev/null; then
    fail "Info.plist missing or invalid ($INFO)"
    echo ""; echo "verify_bundle: 1+ failures"; exit 1
fi
pass "plutil -lint"
[ -n "$BUNDLE_ID" ] || BUNDLE_ID="$(plist_get "$INFO" CFBundleIdentifier)"
case "$BUNDLE_ID" in
    "$PRODUCTION_ID"|"$PRODUCTION_ID".qa-*) pass "bundle id $BUNDLE_ID";;
    *) fail "bundle id must be $PRODUCTION_ID or $PRODUCTION_ID.qa-<name> (got '$BUNDLE_ID')";;
esac
expect "CFBundleIdentifier" "$(plist_get "$INFO" CFBundleIdentifier)" "$BUNDLE_ID"
expect "CFBundleExecutable" "$(plist_get "$INFO" CFBundleExecutable)" "$EXECUTABLE"
expect "CFBundlePackageType" "$(plist_get "$INFO" CFBundlePackageType)" "APPL"
expect "LSMinimumSystemVersion" "$(plist_get "$INFO" LSMinimumSystemVersion)" "$MIN_OS"
expect "ITSAppUsesNonExemptEncryption" "$(plist_get "$INFO" ITSAppUsesNonExemptEncryption)" "false"
check "executable Contents/MacOS/$EXECUTABLE present" test -x "$APP/Contents/MacOS/$EXECUTABLE"
want_version="$(tr -d ' \t\r\n' < "$PROJECT_DIR/VERSION" 2>/dev/null)"
expect "CFBundleShortVersionString (VERSION file)" "$(plist_get "$INFO" CFBundleShortVersionString)" "$want_version"
build="$(plist_get "$INFO" CFBundleVersion)"
if [[ "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then pass "CFBundleVersion $build"; else fail "CFBundleVersion '$build' is not 1-3 dot-separated integers"; fi
[ -n "$CHANNEL" ] || CHANNEL="$(plist_get "$INFO" OJDistributionChannel)"
case "$CHANNEL" in
    direct|appstore) expect "OJDistributionChannel" "$(plist_get "$INFO" OJDistributionChannel)" "$CHANNEL";;
    *) fail "OJDistributionChannel must be direct or appstore (got '$CHANNEL')";;
esac
GROUP="$TEAM_ID.$BUNDLE_ID"
expect "OJAppGroupIdentifier" "$(plist_get "$INFO" OJAppGroupIdentifier)" "$GROUP"
if [ "$BUNDLE_ID" = "$PRODUCTION_ID" ]; then
    want_scheme="omegajournal"
else
    want_scheme="omegajournal-$(printf '%s' "${BUNDLE_ID#"$PRODUCTION_ID".}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
fi
expect "OJURLScheme" "$(plist_get "$INFO" OJURLScheme)" "$want_scheme"
expect "CFBundleURLSchemes[0]" "$(plist_get "$INFO" CFBundleURLTypes:0:CFBundleURLSchemes:0)" "$want_scheme"
if grep -q '@[A-Z_]*@' "$INFO"; then fail "unreplaced @TOKEN@ in Info.plist"; else pass "no unreplaced template tokens"; fi

# Usage strings. The microphone string is always required (voice memos). Others are
# required as soon as the binary links the framework that triggers the permission prompt;
# a missing string crashes the app at the first request.
usage_string() {
    local key="$1" why="$2" value
    value="$(plist_get "$INFO" "$key")"
    if [ "${#value}" -ge 20 ]; then pass "$key ($why)"; else fail "$key missing or too short ($why)"; fi
}
usage_string NSMicrophoneUsageDescription "voice memos"
LINKED="$(otool -L "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null)"
for pair in Speech:NSSpeechRecognitionUsageDescription Contacts:NSContactsUsageDescription \
            EventKit:NSCalendarsFullAccessUsageDescription CoreLocation:NSLocationUsageDescription \
            Photos:NSPhotoLibraryUsageDescription AVFoundation:NSCameraUsageDescription; do
    fw="${pair%%:*}"; key="${pair#*:}"
    case "$LINKED" in
        *"/$fw.framework/"*)
            # AVFoundation alone does not mean camera access: only demand the camera string
            # when the sources ask for video capture.
            if [ "$fw" = "AVFoundation" ] && ! grep -rqE 'AVMediaType\.video|AVCaptureDevice[^)]*\.video|for: *\.video' "$PROJECT_DIR/Sources" 2>/dev/null; then
                continue
            fi
            usage_string "$key" "links $fw";;
    esac
done

# ---------------------------------------------------------------- binaries
section "Binaries"
min_os() { vtool -show-build "$1" 2>/dev/null | awk '$1=="minos"{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
expect "app minimum OS (LC_BUILD_VERSION)" "$(min_os "$APP/Contents/MacOS/$EXECUTABLE")" "$MIN_OS"
if [ -x "$APPEX/Contents/MacOS/$WIDGET_EXECUTABLE" ]; then
    expect "widget minimum OS (LC_BUILD_VERSION)" "$(min_os "$APPEX/Contents/MacOS/$WIDGET_EXECUTABLE")" "$MIN_OS"
fi

# ---------------------------------------------------------------- signature + entitlements
section "Signature and entitlements"
check "codesign --verify --deep --strict" codesign --verify --deep --strict "$APP"
APP_ENT="$WORK/app.entitlements"
codesign -d --entitlements - --xml "$APP" > "$APP_ENT" 2>/dev/null
if [ -s "$APP_ENT" ] && plutil -lint -s "$APP_ENT" 2>/dev/null; then
    pass "app entitlements readable (codesign -d --entitlements -)"
else
    fail "app has no readable entitlements (codesign -d --entitlements -)"
fi
ent() { $PB -c "Print :$2" "$1" 2>/dev/null; }
expect "app com.apple.security.device.audio-input" "$(ent "$APP_ENT" com.apple.security.device.audio-input)" "true"
expect "app com.apple.security.application-groups[0]" "$(ent "$APP_ENT" com.apple.security.application-groups:0)" "$GROUP"
sandbox="$(ent "$APP_ENT" com.apple.security.app-sandbox)"
if [ "$CHANNEL" = "appstore" ]; then
    expect "app com.apple.security.app-sandbox (App Store)" "$sandbox" "true"
    expect "app files.user-selected.read-write (App Store)" "$(ent "$APP_ENT" com.apple.security.files.user-selected.read-write)" "true"
    expect "app files.bookmarks.app-scope (App Store)" "$(ent "$APP_ENT" com.apple.security.files.bookmarks.app-scope)" "true"
else
    if [ "$sandbox" = "true" ]; then fail "direct build must not be sandboxed"; else pass "app not sandboxed (direct)"; fi
fi
for forbidden in com.apple.security.network.client com.apple.security.network.server \
                 com.apple.security.cs.disable-library-validation com.apple.security.get-task-allow; do
    if [ "$(ent "$APP_ENT" "$forbidden")" = "true" ]; then fail "unexpected entitlement $forbidden"; else pass "no $forbidden"; fi
done

# ---------------------------------------------------------------- widget extension
section "Widget extension"
if [ ! -d "$APPEX" ]; then
    fail "widget extension missing ($APPEX)"
else
    pass "Contents/PlugIns/$WIDGET_EXECUTABLE.appex present"
    check "widget Info.plist plutil -lint" plutil -lint -s "$WINFO"
    expect "widget NSExtensionPointIdentifier" "$(plist_get "$WINFO" NSExtension:NSExtensionPointIdentifier)" "$WIDGET_POINT"
    expect "widget CFBundleIdentifier" "$(plist_get "$WINFO" CFBundleIdentifier)" "$BUNDLE_ID.widgets"
    expect "widget CFBundlePackageType" "$(plist_get "$WINFO" CFBundlePackageType)" "XPC!"
    expect "widget LSMinimumSystemVersion" "$(plist_get "$WINFO" LSMinimumSystemVersion)" "$MIN_OS"
    expect "widget OJAppGroupIdentifier" "$(plist_get "$WINFO" OJAppGroupIdentifier)" "$GROUP"
    expect "widget version matches app" "$(plist_get "$WINFO" CFBundleShortVersionString) ($(plist_get "$WINFO" CFBundleVersion))" \
        "$(plist_get "$INFO" CFBundleShortVersionString) ($build)"
    check "widget executable present" test -x "$APPEX/Contents/MacOS/$WIDGET_EXECUTABLE"
    WENT="$WORK/widget.entitlements"
    codesign -d --entitlements - --xml "$APPEX" > "$WENT" 2>/dev/null
    expect "widget com.apple.security.app-sandbox" "$(ent "$WENT" com.apple.security.app-sandbox)" "true"
    expect "widget com.apple.security.application-groups[0]" "$(ent "$WENT" com.apple.security.application-groups:0)" "$GROUP"
    for forbidden in com.apple.security.network.client com.apple.security.device.audio-input \
                     com.apple.security.files.user-selected.read-write; do
        if [ "$(ent "$WENT" "$forbidden")" = "true" ]; then fail "widget must not have $forbidden"; else pass "widget has no $forbidden"; fi
    done
fi

# ---------------------------------------------------------------- privacy manifest
section "Privacy manifest"
PRIV="$APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [ ! -f "$PRIV" ]; then
    fail "PrivacyInfo.xcprivacy missing from Contents/Resources"
else
    check "PrivacyInfo.xcprivacy plutil -lint" plutil -lint -s "$PRIV"
    check "identical to packaging/PrivacyInfo.xcprivacy" cmp -s "$PRIV" "$PROJECT_DIR/packaging/PrivacyInfo.xcprivacy"
    expect "NSPrivacyTracking" "$(plist_get "$PRIV" NSPrivacyTracking)" "false"
    expect "NSPrivacyTrackingDomains count" "$(plutil -extract NSPrivacyTrackingDomains raw -o - "$PRIV" 2>/dev/null)" "0"
    expect "NSPrivacyCollectedDataTypes count (data not collected)" \
        "$(plutil -extract NSPrivacyCollectedDataTypes raw -o - "$PRIV" 2>/dev/null)" "0"
    n="$(plutil -extract NSPrivacyAccessedAPITypes raw -o - "$PRIV" 2>/dev/null || echo 0)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
        i=0
        while [ "$i" -lt "$n" ]; do
            type="$(plist_get "$PRIV" "NSPrivacyAccessedAPITypes:$i:NSPrivacyAccessedAPIType")"
            reasons="$(plutil -extract "NSPrivacyAccessedAPITypes.$i.NSPrivacyAccessedAPITypeReasons" raw -o - "$PRIV" 2>/dev/null)"
            case "$type" in
                NSPrivacyAccessedAPICategory*)
                    if [ "${reasons:-0}" -ge 1 ] 2>/dev/null; then pass "$type has $reasons reason(s)"; else fail "$type has no reason codes"; fi;;
                *) fail "NSPrivacyAccessedAPITypes[$i] has an unknown type '$type'";;
            esac
            i=$((i + 1))
        done
    else
        fail "NSPrivacyAccessedAPITypes is empty (the app uses UserDefaults and file timestamps)"
    fi
fi

# ---------------------------------------------------------------- resources
section "Resources"
check "AppIcon.icns present" test -s "$APP/Contents/Resources/AppIcon.icns"
check "Metadata.appintents present" test -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [ "$CHANNEL" = "direct" ]; then
    check "no container-migration.plist in a direct build" test ! -e "$APP/Contents/Resources/container-migration.plist"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "verify_bundle: $FAILURES check(s) failed"
    exit 1
fi
echo "verify_bundle: all checks passed ($CHANNEL, $BUNDLE_ID)"
