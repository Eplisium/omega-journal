#!/bin/bash
# Shared packaging helpers for build_app.sh, scripts/make_release.sh and scripts/make_mas.sh.
# Source it after setting OJ_PROJECT_DIR (repo root). Bash 3.2 compatible (macOS /bin/bash).
#
# Single sources of truth:
#   VERSION                          marketing version (CFBundleShortVersionString)
#   OMEGA_JOURNAL_BUILD_NUMBER       CFBundleVersion override; default `git rev-list --count HEAD`
#   packaging/Info.plist.template    every Info.plist key
#   packaging/*.entitlements         per-channel entitlements
#   packaging/PrivacyInfo.xcprivacy  privacy manifest (both channels)
#   packaging/container-migration.plist  App Store only
#   packaging/Widgets-Info.plist.template + OmegaJournalWidgets.entitlements  widget extension
#   packaging/appintents-const-protocols.json  protocols whose conformers the compiler
#                                    describes for the App Intents metadata processor
#
# Every bundle contains:
#   Contents/MacOS/OmegaJournal                       the app
#   Contents/Resources/Metadata.appintents            App Intents metadata (oj_appintents_metadata)
#   Contents/PlugIns/OmegaJournalWidgets.appex        WidgetKit extension (oj_assemble_widget)

: "${OJ_PROJECT_DIR:?OJ_PROJECT_DIR must be set before sourcing oj-packaging.sh}"
OJ_PACKAGING_DIR="$OJ_PROJECT_DIR/packaging"
OJ_PRODUCTION_BUNDLE_ID="com.eplisium.omega-journal"
OJ_TEAM_ID="WWC5HJN6AL"
OJ_APP_NAME="Omega Journal"
OJ_EXECUTABLE="OmegaJournal"
OJ_WIDGET_EXECUTABLE="OmegaJournalWidgets"
OJ_WIDGET_APPEX="$OJ_WIDGET_EXECUTABLE.appex"
OJ_WIDGET_EXTENSION_POINT="com.apple.widgetkit-extension"
# App Intents whose metadata must end up in Metadata.appintents (checked after extraction).
OJ_APP_INTENTS="NewJournalEntryIntent QuickCaptureIntent OpenTodayIntent OpenOnThisDayIntent TodaysWritingProgressIntent"

oj_die() { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
oj_note() { printf '==> %s\n' "$*"; }
oj_warn() { printf '\033[33mWarning:\033[0m %s\n' "$*" >&2; }

# Marketing version from the VERSION file (e.g. 1.1.0).
oj_version() {
    local v
    v="$(tr -d ' \t\r\n' < "$OJ_PROJECT_DIR/VERSION" 2>/dev/null)" || true
    [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || oj_die "VERSION file missing or invalid (got '$v'); expected e.g. 1.1.0"
    printf '%s\n' "$v"
}

# Monotonic build number (CFBundleVersion). App Store Connect rejects a build whose
# number is not higher than the last upload for the same version, so the default is the
# commit count, which only grows on main.
oj_build_number() {
    local n="${OMEGA_JOURNAL_BUILD_NUMBER:-}"
    if [ -z "$n" ]; then
        n="$(git -C "$OJ_PROJECT_DIR" rev-list --count HEAD 2>/dev/null || true)"
        if [ -z "$n" ]; then
            oj_warn "not a git checkout and OMEGA_JOURNAL_BUILD_NUMBER unset; using build number 1"
            n=1
        fi
    fi
    [[ "$n" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || oj_die "OMEGA_JOURNAL_BUILD_NUMBER must be 1-3 dot-separated integers (got '$n')"
    printf '%s\n' "$n"
}

oj_sdk_path() { xcrun --sdk macosx --show-sdk-path; }

# App Group shared by the app and its widget: <team id>.<app bundle id>. Mirrors
# OmegaJournalAppGroup in Sources/OmegaJournalShared. QA bundle ids get their own group,
# so a QA build can never overwrite the real widget's snapshot.
oj_app_group() { printf '%s.%s\n' "$OJ_TEAM_ID" "$1"; }

# URL scheme for a bundle id: production -> omegajournal, <production>.qa-x -> omegajournal-qa-x.
# Mirrors OmegaJournalLink.scheme(forBundleIdentifier:) (unit-tested there).
oj_url_scheme() {
    local id="$1"
    if [ "$id" = "$OJ_PRODUCTION_BUNDLE_ID" ]; then printf 'omegajournal\n'; return; fi
    case "$id" in
        "$OJ_PRODUCTION_BUNDLE_ID".*)
            printf 'omegajournal-%s\n' "$(printf '%s' "${id#"$OJ_PRODUCTION_BUNDLE_ID".}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')";;
        *) printf 'omegajournal\n';;
    esac
}

oj_widget_bundle_id() { printf '%s.widgets\n' "$1"; }

# swift build arguments for a release binary.
#   $1 = host | universal
# The -isysroot linker flag works around a SwiftPM/swift-build quirk: it links with
# --sysroot only, so ld records the *deployment target* (14.0) as the SDK version in
# LC_BUILD_VERSION. App Store Connect reads that field to enforce the minimum SDK, so a
# binary that claims "built with the macOS 14 SDK" would be rejected.
oj_swift_build_args() {
    local sdk
    sdk="$(oj_sdk_path)"
    OJ_SWIFT_ARGS=(-c release --package-path "$OJ_PROJECT_DIR"
        -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk"
        # App Intents: have the compiler describe AppIntent/AppShortcutsProvider/AppEnum
        # conformers (*.swiftconstvalues), as Xcode does; oj_appintents_metadata feeds
        # them to appintentsmetadataprocessor.
        -Xswiftc -emit-const-values
        -Xswiftc -const-gather-protocols-list -Xswiftc "$OJ_PACKAGING_DIR/appintents-const-protocols.json")
    if [ "$1" = "universal" ]; then
        OJ_SWIFT_ARGS+=(--arch arm64 --arch x86_64)
    fi
}

# Builds the release binaries and sets OJ_BINARY (app) and OJ_WIDGET_BINARY (widget
# extension) to their paths.
#   $1 = host | universal
oj_build_binary() {
    local mode="${1:-host}"
    oj_swift_build_args "$mode"
    oj_note "Building release binaries ($mode)..."
    # The compiler leaves an unchanged *.swiftconstvalues file untouched (old mtime)
    # when a file without App Intents changes, which tripped the stale guard in
    # oj_appintents_metadata. Removing the app module's release const values makes
    # the build re-emit them, so the guard only fires on a real missed recompile.
    find "$OJ_PROJECT_DIR/.build" -path '*/Release/*' -path "*/$OJ_EXECUTABLE-*" \
        -name '*.swiftconstvalues' -delete 2>/dev/null || true
    swift build "${OJ_SWIFT_ARGS[@]}" || oj_die "swift build failed"
    local bin_dir bin
    bin_dir="$(swift build "${OJ_SWIFT_ARGS[@]}" --show-bin-path)"
    OJ_BINARY="$bin_dir/$OJ_EXECUTABLE"
    OJ_WIDGET_BINARY="$bin_dir/$OJ_WIDGET_EXECUTABLE"
    for bin in "$OJ_BINARY" "$OJ_WIDGET_BINARY"; do
        [ -x "$bin" ] || oj_die "release binary not found at $bin"
        if [ "$mode" = "universal" ]; then
            local archs
            archs="$(lipo -archs "$bin")"
            case " $archs " in
                *" arm64 "*) ;; *) oj_die "universal build of $(basename "$bin") is missing arm64 (got: $archs)";;
            esac
            case " $archs " in
                *" x86_64 "*) ;; *) oj_die "universal build of $(basename "$bin") is missing x86_64 (got: $archs)";;
            esac
        fi
    done
    oj_note "Binary: $OJ_BINARY ($(lipo -archs "$OJ_BINARY"))"
    oj_note "Widget: $OJ_WIDGET_BINARY ($(lipo -archs "$OJ_WIDGET_BINARY"))"
}

# Prints the lowest SDK version recorded in the binary's LC_BUILD_VERSION commands.
oj_binary_sdk_version() {
    vtool -show-build "$1" 2>/dev/null | awk '$1=="sdk"{print $2}' | sort -t. -k1,1n -k2,2n | head -1
}

# Fails (or warns, with $2=warn) when the binary does not record the current SDK.
oj_check_binary_sdk() {
    local bin="$1" mode="${2:-fail}" want got
    want="$(xcrun --sdk macosx --show-sdk-version)"
    got="$(oj_binary_sdk_version "$bin")"
    if [ "${got%%.*}" != "${want%%.*}" ]; then
        local msg="binary records SDK '$got' but the active SDK is '$want' (App Store Connect checks this)"
        [ "$mode" = "warn" ] && oj_warn "$msg" || oj_die "$msg"
    fi
}

# Generates AppIcon.icns with make_icon.swift into $1 without touching the repo-root app.
oj_make_icon() {
    local dest="$1" tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/oj-icon.XXXXXX")"
    mkdir -p "$tmp/$OJ_APP_NAME.app/Contents/Resources"
    OMEGA_JOURNAL_PROJECT_DIR="$tmp" swift "$OJ_PROJECT_DIR/make_icon.swift" >/dev/null \
        || { rm -rf "$tmp"; oj_die "icon generation (make_icon.swift) failed"; }
    [ -f "$tmp/$OJ_APP_NAME.app/Contents/Resources/AppIcon.icns" ] \
        || { rm -rf "$tmp"; oj_die "make_icon.swift did not produce AppIcon.icns"; }
    cp "$tmp/$OJ_APP_NAME.app/Contents/Resources/AppIcon.icns" "$dest"
    rm -rf "$tmp"
}

# Writes Info.plist from the template.
#   $1 = output path, $2 = channel (direct|appstore), $3 = bundle id, $4 = version, $5 = build
oj_write_info_plist() {
    local out="$1" channel="$2" bundle_id="$3" version="$4" build="$5"
    case "$channel" in direct|appstore) ;; *) oj_die "unknown channel '$channel'";; esac
    sed -e "s/@BUNDLE_ID@/$bundle_id/g" \
        -e "s/@BUILD_NUMBER@/$build/" \
        -e "s/@VERSION@/$version/" \
        -e "s/@CHANNEL@/$channel/" \
        -e "s/@APP_GROUP@/$(oj_app_group "$bundle_id")/" \
        -e "s/@URL_SCHEME@/$(oj_url_scheme "$bundle_id")/g" \
        -e "s/@YEAR@/$(date +%Y)/" \
        "$OJ_PACKAGING_DIR/Info.plist.template" > "$out"
    if grep -q '@[A-Z_]*@' "$out"; then oj_die "unreplaced token in $out"; fi
    oj_add_toolchain_keys "$out"
}

# Adds the DT* toolchain keys to an Info.plist.
oj_add_toolchain_keys() {
    local out="$1"
    # Toolchain keys Xcode normally writes. App Store Connect uses them to check the build
    # came from a released Xcode/SDK; without them uploads can fail "Invalid toolchain".
    local pb=/usr/libexec/PlistBuddy sdkver sdkbuild xcver xcbuild xcnum osbuild
    sdkver="$(xcrun --sdk macosx --show-sdk-version)"
    sdkbuild="$(xcrun --sdk macosx --show-sdk-build-version)"
    xcver="$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')"
    xcbuild="$(xcodebuild -version 2>/dev/null | awk 'NR==2{print $3}')"
    xcnum="$(printf '%s' "$xcver" | awk -F. '{printf "%02d%d%d", $1, $2, $3}')"
    osbuild="$(sw_vers -buildVersion)"
    $pb -c "Add :DTPlatformName string macosx" \
        -c "Add :DTPlatformVersion string $sdkver" \
        -c "Add :DTPlatformBuild string $sdkbuild" \
        -c "Add :DTSDKName string macosx$sdkver" \
        -c "Add :DTSDKBuild string $sdkbuild" \
        -c "Add :DTXcode string $xcnum" \
        -c "Add :DTXcodeBuild string $xcbuild" \
        -c "Add :DTCompiler string com.apple.compilers.llvm.clang.1_0" \
        -c "Add :BuildMachineOSBuild string $osbuild" \
        "$out" >/dev/null
    plutil -lint -s "$out" || oj_die "generated Info.plist is invalid: $out"
}

# Assembles a bundle.
#   $1 = .app path, $2 = binary, $3 = channel, $4 = bundle id, $5 = version, $6 = build,
#   $7 = optional container-migration manifest to embed (App Store only)
oj_assemble_bundle() {
    local app="$1" bin="$2" channel="$3" bundle_id="$4" version="$5" build="$6" migration="${7:-}"
    oj_note "Assembling $(basename "$app") ($channel, $bundle_id, $version ($build))"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin" "$app/Contents/MacOS/$OJ_EXECUTABLE"
    oj_write_info_plist "$app/Contents/Info.plist" "$channel" "$bundle_id" "$version" "$build"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    oj_make_icon "$app/Contents/Resources/AppIcon.icns"
    cp "$OJ_PACKAGING_DIR/PrivacyInfo.xcprivacy" "$app/Contents/Resources/PrivacyInfo.xcprivacy"
    if [ -n "$migration" ]; then
        [ "$channel" = "appstore" ] || oj_die "container-migration.plist belongs in App Store builds only"
        plutil -lint -s "$migration" || oj_die "invalid migration manifest: $migration"
        cp "$migration" "$app/Contents/Resources/container-migration.plist"
    fi
    oj_appintents_metadata "$app" "$bundle_id"
    [ -n "${OJ_WIDGET_BINARY:-}" ] || oj_die "OJ_WIDGET_BINARY unset; run oj_build_binary first"
    oj_assemble_widget "$app" "$OJ_WIDGET_BINARY" "$bundle_id" "$version" "$build"
}

# Writes a linker dependency-info file (ld -dependency_info format) listing the SDK
# stubs of every system framework the binary links. appintentsmetadataprocessor reads
# it to confirm the target links AppIntents.framework; SwiftPM does not produce one.
#   $1 = binary, $2 = output file
oj_write_link_dependency_info() {
    local bin="$1" out="$2" sdk lib name
    sdk="$(oj_sdk_path)"
    printf '\000@(#)PROGRAM:ld PROJECT:oj-packaging\n\000' > "$out"
    otool -L "$bin" | awk '/\.framework\//{print $1}' | sort -u | while read -r lib; do
        name="$(basename "$lib")"
        case "$lib" in
            /System/Library/Frameworks/*)
                printf '\020%s\000' "$sdk/System/Library/Frameworks/$name.framework/$name.tbd" >> "$out";;
        esac
    done
}

# Generates Contents/Resources/Metadata.appintents from the release build, the way
# Xcode's ExtractAppIntentsMetadata build phase does. Without it the App Intents and
# App Shortcuts never show up in Shortcuts, Spotlight or Siri.
#   $1 = .app (binary already copied in), $2 = bundle id
oj_appintents_metadata() {
    local app="$1" bundle_id="$2" work arch consts toolchain xcode_build processor
    processor="$(xcrun -f appintentsmetadataprocessor 2>/dev/null)" \
        || oj_die "appintentsmetadataprocessor not found (needs Xcode, not just the Command Line Tools)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/oj-appintents.XXXXXX")"
    # Release const values of the app module (swift-build layout:
    # .build/out/Intermediates.noindex/OmegaJournal.build/Release/OmegaJournal-*.build/
    # Objects-normal/<arch>/; native layout: .build/<triple>/release/OmegaJournal.build/).
    find "$OJ_PROJECT_DIR/.build" -name '*.swiftconstvalues' 2>/dev/null \
        | grep -E "/$OJ_EXECUTABLE(-[A-Za-z]+)?\.build/" | grep -E '/(Release|release)/' > "$work/all-consts.txt" || true
    # Per architecture but describing the same source: prefer arm64.
    arch="arm64"
    consts="$work/consts.txt"
    grep -E '/arm64/|/arm64-apple' "$work/all-consts.txt" > "$consts" || true
    if [ ! -s "$consts" ]; then
        arch="$(uname -m)"
        cp "$work/all-consts.txt" "$consts"
    fi
    if [ ! -s "$consts" ] || ! tr '\n' '\0' < "$consts" | xargs -0 grep -l 'AppShortcutsProvider' >/dev/null 2>&1; then
        rm -rf "$work"
        oj_die "no App Intents const values for $OJ_EXECUTABLE (expected *.swiftconstvalues from -emit-const-values under .build)"
    fi
    find "$OJ_PROJECT_DIR/Sources/$OJ_EXECUTABLE" -name '*.swift' | sort > "$work/sources.txt"
    # Stale guard: the const values must be at least as new as every app source file.
    local newest_const stale
    newest_const="$(tr '\n' '\0' < "$consts" | xargs -0 ls -t | head -1)"
    stale="$(find "$OJ_PROJECT_DIR/Sources/$OJ_EXECUTABLE" -name '*.swift' -newer "$newest_const" | head -1)"
    if [ -n "$stale" ]; then
        rm -rf "$work"
        oj_die "App Intents const values are older than $stale; the release build did not recompile"
    fi
    : > "$work/empty.txt"
    oj_write_link_dependency_info "$app/Contents/MacOS/$OJ_EXECUTABLE" "$work/link-deps.dat"
    toolchain="$(cd "$(dirname "$(xcrun -f swiftc)")/../.." && pwd)"
    xcode_build="$(xcodebuild -version 2>/dev/null | awk 'NR==2{print $3}')"
    oj_note "Extracting App Intents metadata ($arch const values)"
    "$processor" \
        --toolchain-dir "$toolchain" \
        --module-name "$OJ_EXECUTABLE" \
        --sdk-root "$(oj_sdk_path)" \
        --xcode-version "$xcode_build" \
        --platform-family macOS \
        --deployment-target 14.0 \
        --bundle-identifier "$bundle_id" \
        --output "$app/Contents/Resources" \
        --target-triple "$arch-apple-macos14.0" \
        --binary-file "$app/Contents/MacOS/$OJ_EXECUTABLE" \
        --dependency-file "$work/link-deps.dat" \
        --stringsdata-file "$work/ExtractedAppShortcutsMetadata.stringsdata" \
        --source-file-list "$work/sources.txt" \
        --metadata-file-list "$work/empty.txt" \
        --static-metadata-file-list "$work/empty.txt" \
        --swift-const-vals-list "$consts" \
        --compile-time-extraction \
        --deployment-aware-processing \
        --no-app-shortcuts-localization \
        > "$work/processor.log" 2>&1 || { cat "$work/processor.log" >&2; rm -rf "$work"; oj_die "appintentsmetadataprocessor failed"; }
    if grep -q "warning\|error" "$work/processor.log"; then grep "warning\|error" "$work/processor.log" >&2; fi
    rm -rf "$work"
    oj_verify_appintents_metadata "$app"
}

# Fails unless Metadata.appintents lists every intent in OJ_APP_INTENTS and the
# App Shortcuts provider.
oj_verify_appintents_metadata() {
    local data="$1/Contents/Resources/Metadata.appintents/extract.actionsdata" intent
    [ -f "$data" ] || oj_die "Metadata.appintents missing from $(basename "$1")"
    for intent in $OJ_APP_INTENTS; do
        plutil -extract "actions.$intent" json -o /dev/null "$data" 2>/dev/null \
            || oj_die "Metadata.appintents does not describe $intent"
    done
    [ "$(plutil -extract autoShortcuts raw -o - "$data" 2>/dev/null)" -ge 5 ] 2>/dev/null \
        || oj_die "Metadata.appintents has no App Shortcuts (AppShortcutsProvider not extracted)"
}

# Assembles Contents/PlugIns/OmegaJournalWidgets.appex.
#   $1 = .app, $2 = widget binary, $3 = APP bundle id, $4 = version, $5 = build
oj_assemble_widget() {
    local app="$1" bin="$2" bundle_id="$3" version="$4" build="$5" appex out
    appex="$app/Contents/PlugIns/$OJ_WIDGET_APPEX"
    oj_note "Embedding widget extension ($(oj_widget_bundle_id "$bundle_id"))"
    rm -rf "$appex"
    mkdir -p "$appex/Contents/MacOS"
    cp "$bin" "$appex/Contents/MacOS/$OJ_WIDGET_EXECUTABLE"
    out="$appex/Contents/Info.plist"
    sed -e "s/@WIDGET_BUNDLE_ID@/$(oj_widget_bundle_id "$bundle_id")/" \
        -e "s/@BUILD_NUMBER@/$build/" \
        -e "s/@VERSION@/$version/" \
        -e "s/@APP_GROUP@/$(oj_app_group "$bundle_id")/" \
        -e "s/@URL_SCHEME@/$(oj_url_scheme "$bundle_id")/" \
        -e "s/@YEAR@/$(date +%Y)/" \
        "$OJ_PACKAGING_DIR/Widgets-Info.plist.template" > "$out"
    if grep -q '@[A-Z_]*@' "$out"; then oj_die "unreplaced token in $out"; fi
    oj_add_toolchain_keys "$out"
    printf 'XPC!????' > "$appex/Contents/PkgInfo"
}

# Copies an entitlements file and points its application-groups at the group for
# this bundle id (production keeps WWC5HJN6AL.com.eplisium.omega-journal).
#   $1 = source, $2 = destination, $3 = APP bundle id
oj_prepare_entitlements() {
    local src="$1" dst="$2" bundle_id="$3" pb=/usr/libexec/PlistBuddy
    cp "$src" "$dst"
    if $pb -c 'Print :com.apple.security.application-groups' "$dst" >/dev/null 2>&1; then
        $pb -c 'Delete :com.apple.security.application-groups' \
            -c 'Add :com.apple.security.application-groups array' \
            -c "Add :com.apple.security.application-groups:0 string $(oj_app_group "$bundle_id")" "$dst" >/dev/null
    fi
    plutil -lint -s "$dst" || oj_die "invalid entitlements: $dst"
}

# First code-signing identity whose name starts with one of the given prefixes.
oj_find_codesign_identity() {
    local ids prefix match
    ids="$(security find-identity -v -p codesigning 2>/dev/null)"
    for prefix in "$@"; do
        match="$(printf '%s\n' "$ids" | sed -n "s/.*\"\\($prefix[^\"]*\\)\".*/\\1/p" | head -1)"
        if [ -n "$match" ]; then printf '%s\n' "$match"; return 0; fi
    done
    return 1
}

# First identity of any kind (installer certs are not code-signing identities).
oj_find_any_identity() {
    local ids prefix match
    ids="$(security find-identity -v 2>/dev/null)"
    for prefix in "$@"; do
        match="$(printf '%s\n' "$ids" | sed -n "s/.*\"\\($prefix[^\"]*\\)\".*/\\1/p" | head -1)"
        if [ -n "$match" ]; then printf '%s\n' "$match"; return 0; fi
    done
    return 1
}

# SHA-1 of a code-signing identity (as listed by `security find-identity`).
oj_identity_sha1() {
    security find-identity -v 2>/dev/null | awk -v name="\"$1\"" 'index($0, name){print $2; exit}'
}

# Signs the bundle inside-out: the widget extension first (with its own sandboxed
# entitlements), then the app. No --deep: it would sign the extension with the APP's
# entitlements, and Apple discourages it for distribution.
#   $1 = .app, $2 = identity ("-" = ad-hoc), $3 = app entitlements file, then flags:
#   --runtime (hardened runtime), --timestamp (secure timestamp; needs network),
#   --widget-entitlements <file> (required when the bundle contains the widget)
oj_sign_app() {
    local app="$1" identity="$2" ent="$3"; shift 3
    local args=(--force --sign "$identity")
    local widget_ent="" appex="$app/Contents/PlugIns/$OJ_WIDGET_APPEX"
    while [ $# -gt 0 ]; do
        case "$1" in
            --runtime) args+=(--options runtime);;
            --timestamp) args+=(--timestamp);;
            --widget-entitlements) widget_ent="${2:-}"; shift;;
            *) oj_die "oj_sign_app: unknown flag $1";;
        esac
        shift
    done
    [ "$identity" = "-" ] && oj_note "Signing ad-hoc" || oj_note "Signing with: $identity"
    if [ -d "$appex" ]; then
        [ -n "$widget_ent" ] || oj_die "oj_sign_app: $OJ_WIDGET_APPEX present but no --widget-entitlements"
        codesign "${args[@]}" --entitlements "$widget_ent" "$appex" || return 1
        codesign --verify --strict --verbose=1 "$appex" || oj_die "codesign --verify --strict failed for $appex"
    fi
    codesign "${args[@]}" --entitlements "$ent" "$app" || return 1
    codesign --verify --deep --strict --verbose=1 "$app" || oj_die "codesign --verify --deep --strict failed for $app"
}

# Guards for the embedded widget extension (every channel):
#   appex present with the WidgetKit extension point and the expected bundle id,
#   extension sandboxed, app and extension entitled to the same App Group.
#   $1 = .app, $2 = APP bundle id, $3 = "runtime" to also require the hardened runtime
oj_verify_widget() {
    local app="$1" bundle_id="$2" want_runtime="${3:-}" appex group pb=/usr/libexec/PlistBuddy
    appex="$app/Contents/PlugIns/$OJ_WIDGET_APPEX"
    group="$(oj_app_group "$bundle_id")"
    [ -d "$appex" ] || oj_die "widget extension missing: $appex"
    [ "$($pb -c 'Print :NSExtension:NSExtensionPointIdentifier' "$appex/Contents/Info.plist")" = "$OJ_WIDGET_EXTENSION_POINT" ] \
        || oj_die "$OJ_WIDGET_APPEX is not a WidgetKit extension"
    [ "$($pb -c 'Print :CFBundleIdentifier' "$appex/Contents/Info.plist")" = "$(oj_widget_bundle_id "$bundle_id")" ] \
        || oj_die "$OJ_WIDGET_APPEX has the wrong bundle id"
    [ "$($pb -c 'Print :CFBundlePackageType' "$appex/Contents/Info.plist")" = "XPC!" ] \
        || oj_die "$OJ_WIDGET_APPEX must have CFBundlePackageType XPC!"
    [ "$(oj_entitlement "$appex" ':com.apple.security.app-sandbox')" = "true" ] \
        || oj_die "widget extension is not sandboxed (WidgetKit refuses to load it)"
    [ "$(oj_entitlement "$appex" ':com.apple.security.application-groups:0')" = "$group" ] \
        || oj_die "widget extension lacks the App Group entitlement $group"
    [ "$(oj_entitlement "$app" ':com.apple.security.application-groups:0')" = "$group" ] \
        || oj_die "app lacks the App Group entitlement $group"
    [ "$($pb -c 'Print :OJAppGroupIdentifier' "$app/Contents/Info.plist")" = "$group" ] \
        || oj_die "app Info.plist OJAppGroupIdentifier is not $group"
    [ "$($pb -c 'Print :OJAppGroupIdentifier' "$appex/Contents/Info.plist")" = "$group" ] \
        || oj_die "widget Info.plist OJAppGroupIdentifier is not $group"
    if [ "$want_runtime" = "runtime" ]; then
        [[ "$(codesign -d --verbose=2 "$appex" 2>&1)" == *"flags="*"runtime"* ]] \
            || oj_die "hardened runtime flag missing from the widget extension signature"
    fi
    oj_verify_appintents_metadata "$app"
}

# Prints the entitlements embedded in a signed bundle as XML.
oj_dump_entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null; }

# Reads a key from a signed bundle's entitlements (PlistBuddy syntax, e.g. ":com.apple.security.app-sandbox").
oj_entitlement() {
    local tmp val
    tmp="$(mktemp "${TMPDIR:-/tmp}/oj-ent.XXXXXX")"
    oj_dump_entitlements "$1" > "$tmp"
    val="$(/usr/libexec/PlistBuddy -c "Print $2" "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    printf '%s\n' "$val"
}
