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

: "${OJ_PROJECT_DIR:?OJ_PROJECT_DIR must be set before sourcing oj-packaging.sh}"
OJ_PACKAGING_DIR="$OJ_PROJECT_DIR/packaging"
OJ_PRODUCTION_BUNDLE_ID="com.eplisium.omega-journal"
OJ_TEAM_ID="WWC5HJN6AL"
OJ_APP_NAME="Omega Journal"
OJ_EXECUTABLE="OmegaJournal"

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
        -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk")
    if [ "$1" = "universal" ]; then
        OJ_SWIFT_ARGS+=(--arch arm64 --arch x86_64)
    fi
}

# Builds the release binary and sets OJ_BINARY to its path.
#   $1 = host | universal
oj_build_binary() {
    local mode="${1:-host}"
    oj_swift_build_args "$mode"
    oj_note "Building release binary ($mode)..."
    swift build "${OJ_SWIFT_ARGS[@]}" || oj_die "swift build failed"
    local bin_dir
    bin_dir="$(swift build "${OJ_SWIFT_ARGS[@]}" --show-bin-path)"
    OJ_BINARY="$bin_dir/$OJ_EXECUTABLE"
    [ -x "$OJ_BINARY" ] || oj_die "release binary not found at $OJ_BINARY"
    if [ "$mode" = "universal" ]; then
        local archs
        archs="$(lipo -archs "$OJ_BINARY")"
        case " $archs " in
            *" arm64 "*) ;; *) oj_die "universal build is missing arm64 (got: $archs)";;
        esac
        case " $archs " in
            *" x86_64 "*) ;; *) oj_die "universal build is missing x86_64 (got: $archs)";;
        esac
    fi
    oj_note "Binary: $OJ_BINARY ($(lipo -archs "$OJ_BINARY"))"
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
    sed -e "s/@BUNDLE_ID@/$bundle_id/" \
        -e "s/@BUILD_NUMBER@/$build/" \
        -e "s/@VERSION@/$version/" \
        -e "s/@CHANNEL@/$channel/" \
        -e "s/@YEAR@/$(date +%Y)/" \
        "$OJ_PACKAGING_DIR/Info.plist.template" > "$out"
    if grep -q '@[A-Z_]*@' "$out"; then oj_die "unreplaced token in $out"; fi

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

# Signs a single-binary bundle (no --deep: there is nothing nested to sign, and --deep
# applies the app's entitlements to nested code, which Apple discourages).
#   $1 = .app, $2 = identity ("-" = ad-hoc), $3 = entitlements file, then flags:
#   --runtime (hardened runtime), --timestamp (secure timestamp; needs network)
oj_sign_app() {
    local app="$1" identity="$2" ent="$3"; shift 3
    local args=(--force --sign "$identity" --entitlements "$ent")
    local flag
    for flag in "$@"; do
        case "$flag" in
            --runtime) args+=(--options runtime);;
            --timestamp) args+=(--timestamp);;
            *) oj_die "oj_sign_app: unknown flag $flag";;
        esac
    done
    [ "$identity" = "-" ] && oj_note "Signing ad-hoc" || oj_note "Signing with: $identity"
    codesign "${args[@]}" "$app" || return 1
    codesign --verify --strict --verbose=1 "$app" || oj_die "codesign --verify --strict failed for $app"
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
