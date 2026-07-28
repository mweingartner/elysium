#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRATCH="$ROOT/.build/debug-app"
OUTPUT="$ROOT/dist/Elysium Debug.app"
DEBUG_CONTROL_MARKER="elysium_debug_control_build_marker_v1"
BUILD_LOG_DIR=""

die() { echo "package-debug-app failed: $*" >&2; exit 1; }
cleanup() {
    [ -z "$BUILD_LOG_DIR" ] || rm -rf -- "$BUILD_LOG_DIR"
}
trap cleanup EXIT INT TERM

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
binary_contains_debug_marker() {
    local binary="$1"
    if /usr/bin/nm "$binary" 2>/dev/null | /usr/bin/awk -v marker="$DEBUG_CONTROL_MARKER" '
        index($0, marker) { found = 1 }
        END { exit(found ? 0 : 1) }
    '; then
        return 0
    fi
    /usr/bin/strings "$binary" | /usr/bin/awk -v marker="$DEBUG_CONTROL_MARKER" '
        index($0, marker) { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

[ "$#" -eq 0 ] || die "usage: scripts/package-debug-app.sh"
[ -f "$ROOT/packaging/DebugInfo.plist" ] && [ ! -L "$ROOT/packaging/DebugInfo.plist" ] \
    || die "missing packaging/DebugInfo.plist"
/usr/bin/plutil -lint "$ROOT/packaging/DebugInfo.plist" >/dev/null \
    || die "DebugInfo.plist is invalid"
bash "$ROOT/scripts/verify-pack-assets.sh" >/dev/null \
    || die "managed pack asset verification failed"

# This dedicated scratch directory prevents the compile-time debug capability from contaminating
# the ordinary .build/release product consumed by scripts/package-app.sh and scripts/pipeline.sh.
rm -rf -- "$SCRATCH"
mkdir -p "$SCRATCH"
BUILD_LOG_DIR="$(mktemp -d /tmp/elysium-debug-package.XXXXXX)"
chmod 700 "$BUILD_LOG_DIR"
BUILD_FLAGS=(
    --scratch-path "$SCRATCH"
    -c release
    -Xswiftc -DELYSIUM_DEBUG_CONTROL
    -Xswiftc -warnings-as-errors
)
build_product() {
    local product="$1"
    local log="$BUILD_LOG_DIR/$product.log"
    if ! (cd "$ROOT" && ELYSIUM_DEBUG_CONTROL_BUILD=1 \
        swift build "${BUILD_FLAGS[@]}" --product "$product") \
        >"$log" 2>&1; then
        sed -n '1,240p' "$log" >&2
        die "optimized debug build failed for $product"
    fi
    if grep -F 'warning:' "$log" >/dev/null; then
        sed -n '1,240p' "$log" >&2
        die "optimized debug build emitted a warning for $product"
    fi
}
build_product Elysium
build_product elydebug

BIN_DIR="$(cd "$ROOT" && ELYSIUM_DEBUG_CONTROL_BUILD=1 \
    swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
case "$BIN_DIR" in
    "$SCRATCH"/*) ;;
    *) die "SwiftPM returned a binary directory outside the isolated scratch path" ;;
esac
APP_INPUT="$BIN_DIR/Elysium"
HELPER_INPUT="$BIN_DIR/elydebug"
for binary in "$APP_INPUT" "$HELPER_INPUT"; do
    [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] \
        || die "missing regular executable: $binary"
done
binary_contains_debug_marker "$APP_INPUT" \
    || die "Elysium debug executable is missing $DEBUG_CONTROL_MARKER"
if binary_contains_debug_marker "$HELPER_INPUT"; then
    die "elydebug helper unexpectedly contains $DEBUG_CONTROL_MARKER"
fi

mkdir -p "$ROOT/dist"
rm -rf -- "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Helpers" "$OUTPUT/Contents/Resources"
cp "$ROOT/packaging/DebugInfo.plist" "$OUTPUT/Contents/Info.plist"
cp "$ROOT/packaging/AppIcon.icns" "$OUTPUT/Contents/Resources/"
cp "$ROOT/packaging/logo.png" "$OUTPUT/Contents/Resources/"
cp "$ROOT/packaging/title-bg.png" "$OUTPUT/Contents/Resources/"
PACK_ASSETS=(
    "Faithful 64x - December 2025 Release.zip"
    "Faithful 64x - Ore Borders 64x.zip"
    "Faithful 64x - Static Lanterns.zip"
    "FAITHFUL-LICENSE.txt"
    "FAITHFUL-ADDONS-CREDITS.txt"
)
for name in "${PACK_ASSETS[@]}"; do
    asset="$ROOT/packaging/$name"
    [ -f "$asset" ] && [ ! -L "$asset" ] || die "missing managed pack asset: $name"
    cp "$asset" "$OUTPUT/Contents/Resources/$name"
done

STAGED_APP="$OUTPUT/Contents/MacOS/ElysiumDebug"
STAGED_HELPER="$OUTPUT/Contents/Helpers/elydebug"
cp "$APP_INPUT" "$STAGED_APP"
cp "$HELPER_INPUT" "$STAGED_HELPER"
chmod 755 "$STAGED_APP" "$STAGED_HELPER"
cmp -s "$APP_INPUT" "$STAGED_APP" || die "staged ElysiumDebug differs before signing"
cmp -s "$HELPER_INPUT" "$STAGED_HELPER" || die "staged elydebug differs before signing"
binary_contains_debug_marker "$STAGED_APP" \
    || die "staged ElysiumDebug is missing $DEBUG_CONTROL_MARKER"
if binary_contains_debug_marker "$STAGED_HELPER"; then
    die "staged elydebug unexpectedly contains $DEBUG_CONTROL_MARKER"
fi

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$OUTPUT/Contents/Info.plist")" = \
    "ElysiumDebug" ] || die "unexpected debug executable name"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUTPUT/Contents/Info.plist")" = \
    "com.briangao.elysium.debug" ] || die "unexpected debug bundle identifier"

/usr/bin/codesign --force --sign - --identifier com.briangao.elysium.debug.elydebug \
    "$STAGED_HELPER" >/dev/null
/usr/bin/codesign --force --sign - --identifier com.briangao.elysium.debug "$OUTPUT" >/dev/null
/usr/bin/codesign --verify --strict "$STAGED_HELPER" >/dev/null 2>&1 \
    || die "elydebug helper signature verification failed"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$OUTPUT" >/dev/null 2>&1 \
    || die "debug app signature verification failed"
binary_contains_debug_marker "$STAGED_APP" \
    || die "signed ElysiumDebug is missing $DEBUG_CONTROL_MARKER"
if binary_contains_debug_marker "$STAGED_HELPER"; then
    die "signed elydebug unexpectedly contains $DEBUG_CONTROL_MARKER"
fi

echo "DEBUG PACKAGE PASS path=$OUTPUT app_sha256=$(sha256 "$STAGED_APP") helper_sha256=$(sha256 "$STAGED_HELPER") install=not_performed"
