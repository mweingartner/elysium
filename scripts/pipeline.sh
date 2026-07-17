#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

if [ "$#" -ne 0 ]; then
    echo "usage: bash scripts/pipeline.sh" >&2
    exit 64
fi

SNAPSHOT_TOOL="$ROOT/scripts/release-source-snapshot.py"
DIST_APP="$ROOT/dist/Elysium.app"
DIST_EXECUTABLE="$DIST_APP/Contents/MacOS/Elysium"
INSTALLED_APP="/Applications/Elysium.app"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/Elysium"
TMP="$(mktemp -d /tmp/elysium-automated-release.XXXXXX)" || exit 1
trap 'rm -rf -- "$TMP"' EXIT INT TERM

fail() {
    local stage="$1" status="$2"
    [ "$status" -ne 0 ] || status=1
    echo "AUTOMATED RELEASE FAIL stage=$stage exit=$status; later stages not run" >&2
    exit "$status"
}

snapshot() { "$SNAPSHOT_TOOL" "$ROOT"; }
SOURCE_AUTHORITY="$(snapshot)" || fail source-security 1
revalidate_source() {
    local current
    current="$(snapshot)" || return 1
    [ "$current" = "$SOURCE_AUTHORITY" ]
}

run_stage() {
    local number="$1" id="$2" label="$3" pass_suffix="$4"
    shift 4
    "$@"
    local status=$?
    [ "$status" -eq 0 ] || fail "$id" "$status"
    revalidate_source || fail "$id" 98
    echo "[$number/9] $label ... PASS$pass_suffix"
}

stage_security() { bash scripts/security-scan.sh; }
stage_build() {
    scripts/prepush-release-build.sh "$TMP/release-build.log" || return $?
    RELEASE_EXECUTABLE="$(cd .build/release && pwd -P)/Elysium"
    [ -f "$RELEASE_EXECUTABLE" ] && [ ! -L "$RELEASE_EXECUTABLE" ] || return 1
    RELEASE_SHA256="$(shasum -a 256 "$RELEASE_EXECUTABLE" | awk '{print $1}')"
    [[ "$RELEASE_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    stat -f '%d:%i:%z:%m:%c' "$RELEASE_EXECUTABLE" > "$TMP/release.identity"
    printf '%s\n' "$RELEASE_EXECUTABLE" > "$TMP/release.path"
    printf '%s\n' "$RELEASE_SHA256" > "$TMP/release.sha"
}
release_unchanged() {
    local executable expected identity
    executable="$(sed -n '1p' "$TMP/release.path")"
    expected="$(sed -n '1p' "$TMP/release.sha")"
    identity="$(sed -n '1p' "$TMP/release.identity")"
    [ -f "$executable" ] && [ ! -L "$executable" ] &&
        [ "$(stat -f '%d:%i:%z:%m:%c' "$executable")" = "$identity" ] &&
        [ "$(shasum -a 256 "$executable" | awk '{print $1}')" = "$expected" ]
}
stage_surface() {
    release_unchanged && scripts/verify-elysium-storage-release-surface.sh &&
        scripts/security-check-binary.sh "$(sed -n '1p' "$TMP/release.path")" && release_unchanged
}
stage_xctest() {
    swift test 2>&1 | tee "$TMP/xctest.log"
    local status=${PIPESTATUS[0]}
    [ "$status" -eq 0 ] || return "$status"
    XCTEST_COUNT="$(perl -ne '$n=$1 if /Executed ([1-9][0-9]*) tests?/; $n=$1 if /Test run with ([1-9][0-9]*) tests?/; END { print $n // 0 }' "$TMP/xctest.log")"
    [ "$XCTEST_COUNT" -gt 0 ] && release_unchanged
}
stage_smoke() {
    swift run -c release elysmoke 2>&1 | tee "$TMP/elysmoke.log"
    local status=${PIPESTATUS[0]}
    [ "$status" -eq 0 ] && grep -Fxq '457 passed, 0 failed' "$TMP/elysmoke.log" && release_unchanged
}
stage_package() {
    release_unchanged || return 1
    scripts/package-app.sh --executable "$(sed -n '1p' "$TMP/release.path")" \
        --output "$DIST_APP" --manifest-stdout --expected-hash "$(sed -n '1p' "$TMP/release.sha")" \
        > "$TMP/package-manifest.txt" || return $?
    PACKAGE_SHA256="$(sed -n 's/^post_sign_executable_sha256=//p' "$TMP/package-manifest.txt")"
    [[ "$PACKAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$PACKAGE_SHA256" > "$TMP/package.sha"
    [ -f "$DIST_EXECUTABLE" ] && [ ! -L "$DIST_EXECUTABLE" ] &&
        [ "$(shasum -a 256 "$DIST_EXECUTABLE" | awk '{print $1}')" = "$PACKAGE_SHA256" ] || return 1
    stat -f '%d:%i:%z:%m:%c' "$DIST_EXECUTABLE" > "$TMP/package.identity"
    release_unchanged
}
package_unchanged() {
    [ -f "$DIST_EXECUTABLE" ] && [ ! -L "$DIST_EXECUTABLE" ] &&
        [ "$(stat -f '%d:%i:%z:%m:%c' "$DIST_EXECUTABLE")" = "$(sed -n '1p' "$TMP/package.identity")" ] &&
        [ "$(shasum -a 256 "$DIST_EXECUTABLE" | awk '{print $1}')" = "$(sed -n '1p' "$TMP/package.sha")" ]
}
stage_appkit() {
    release_unchanged && package_unchanged || return 1
    scripts/appkit-text-entry-integration.sh --no-build --executable "$(sed -n '1p' "$TMP/release.path")" \
        --prepackaged-app "$DIST_APP" --prepackaged-manifest "$TMP/package-manifest.txt" \
        --expected-hash "$(sed -n '1p' "$TMP/release.sha")" \
        --expected-packaged-hash "$(sed -n '1p' "$TMP/package.sha")" \
        --timeout 90 2>&1 | tee "$TMP/appkit.log"
    local status=${PIPESTATUS[0]}
    [ "$status" -eq 0 ] &&
        [ "$(grep -Fxc 'AppKit text-entry integration: PASS fields=2 clipboard_access=0 foreground_driver=verified cleanup=verified' "$TMP/appkit.log")" -eq 1 ] &&
        [ "$(grep -Fc 'AppKit text-entry integration:' "$TMP/appkit.log")" -eq 1 ] &&
        release_unchanged && package_unchanged
}
stage_install() {
    release_unchanged && package_unchanged || return 1
    /usr/bin/pkill -x Elysium 2>/dev/null || true
    rm -rf -- "$INSTALLED_APP" || return 1
    /usr/bin/ditto "$DIST_APP" "$INSTALLED_APP" || return 1
    [ -f "$INSTALLED_EXECUTABLE" ] && [ ! -L "$INSTALLED_EXECUTABLE" ] &&
        [ "$(shasum -a 256 "$INSTALLED_EXECUTABLE" | awk '{print $1}')" = "$(sed -n '1p' "$TMP/package.sha")" ]
}
codesign_field() {
    awk -v prefix="$2=" '
        index($0, prefix) == 1 { count += 1; value = substr($0, length(prefix) + 1) }
        END { if (count != 1) exit 1; print value }
    ' "$1"
}
codesign_requirement() {
    /usr/bin/codesign -d -r- "$1" 2>&1 | sed -n 's/^# designated => //p; s/^designated => //p' | tail -1
}
stage_installed_identity() {
    release_unchanged && package_unchanged || return 1
    [ "$(shasum -a 256 "$INSTALLED_EXECUTABLE" | awk '{print $1}')" = "$(sed -n '1p' "$TMP/package.sha")" ] || return 1
    /usr/bin/codesign --verify --deep --strict "$INSTALLED_APP" || return 1
    local installed_codesign_details="$TMP/installed-codesign-details.txt"
    /usr/bin/codesign -d --verbose=4 "$INSTALLED_APP" >"$installed_codesign_details" 2>&1 || return 1
    [ -f "$installed_codesign_details" ] && [ ! -L "$installed_codesign_details" ] &&
        [ -r "$installed_codesign_details" ] || return 1
    local package_id package_cdhash package_requirement
    package_id="$(sed -n 's/^bundle_id=//p' "$TMP/package-manifest.txt")"
    package_cdhash="$(sed -n 's/^cdhash=//p' "$TMP/package-manifest.txt")"
    package_requirement="$(sed -n 's/^designated_requirement=//p' "$TMP/package-manifest.txt")"
    [ "$package_id" = "com.briangao.elysium" ] && [ -n "$package_cdhash" ] && [ -n "$package_requirement" ] &&
        [ "$(codesign_field "$installed_codesign_details" Identifier)" = "$package_id" ] &&
        [ "$(codesign_field "$installed_codesign_details" CDHash)" = "$package_cdhash" ] &&
        [ "$(codesign_requirement "$INSTALLED_APP")" = "$package_requirement" ] &&
        [ "$(grep -Ec '^Sealed Resources version=' "$installed_codesign_details")" -eq 1 ]
}

run_stage 1 source-security 'Source security' '' stage_security
run_stage 2 release-build 'Warning-free release build' '' stage_build
run_stage 3 release-surface-binary 'Release surface and binary' '' stage_surface
stage_xctest; status=$?; [ "$status" -eq 0 ] || fail full-xctest "$status"
revalidate_source || fail full-xctest 98
echo "[4/9] Full XCTest ... PASS tests=$XCTEST_COUNT"
run_stage 5 elysmoke 'Elysmoke' ' checks=457 failures=0' stage_smoke
run_stage 6 package 'Package signed application' '' stage_package
run_stage 7 packaged-appkit 'Packaged AppKit text entry' ' fields=2 clipboard_access=0' stage_appkit
run_stage 8 install 'Install /Applications/Elysium.app' '' stage_install
run_stage 9 installed-identity-codesign 'Installed identity and codesign' '' stage_installed_identity
revalidate_source || fail installed-identity-codesign 98
release_unchanged && package_unchanged || fail installed-identity-codesign 99
FINAL_SHA="$(sed -n '1p' "$TMP/package.sha")"
[ "$(shasum -a 256 "$INSTALLED_EXECUTABLE" | awk '{print $1}')" = "$FINAL_SHA" ] || fail installed-identity-codesign 99
echo "AUTOMATED RELEASE PASS path=/Applications/Elysium.app executable_sha256=$FINAL_SHA"
