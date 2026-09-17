#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KUBIKOS_FILE="KUBIKOS Cubic World - Elysium Theme.zip"
KUBIKOS_RELATIVE="packaging/$KUBIKOS_FILE"
KUBIKOS_OUTPUT="$ROOT/$KUBIKOS_RELATIVE"
EXPECTED_SOURCE_SHA256="4eb52b835610aca19a79681a81a744fc9a69b8414426e2f18a270e20f229e24e"
DEFAULT_UNITY_PACKAGE="/Users/Shared/UnrealEngine/Launcher/VaultCache/FabLibrary/KUBIKOS_-_Cube_World-7bbf72cf/unity/kubikos_3d_cube_world.unitypackage"
UNITY_PACKAGE="${ELYSIUM_KUBIKOS_UNITYPACKAGE:-$DEFAULT_UNITY_PACKAGE}"
BUILD_LOG=""

die() { echo "prepare-kubikos-theme failed: $*" >&2; exit 1; }
cleanup() {
    [ -z "$BUILD_LOG" ] || rm -f -- "$BUILD_LOG"
}
trap cleanup EXIT INT TERM
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

[ -f "$ROOT/scripts/build-kubikos-theme.swift" ] && [ ! -L "$ROOT/scripts/build-kubikos-theme.swift" ] || \
    die "missing safe KUBIKOS theme builder"
[ -f "$ROOT/scripts/verify-pack-assets.sh" ] && [ ! -L "$ROOT/scripts/verify-pack-assets.sh" ] || \
    die "missing safe pack verifier"

# The generated derivative must remain an ignored local build input. Checking both
# Git's index and ignore rules prevents a packaging run from normalizing an
# accidentally tracked/public archive.
if git -C "$ROOT" ls-files --error-unmatch -- "$KUBIKOS_RELATIVE" >/dev/null 2>&1; then
    die "$KUBIKOS_RELATIVE must not be tracked"
fi
git -C "$ROOT" check-ignore -q -- "$KUBIKOS_RELATIVE" || \
    die "$KUBIKOS_RELATIVE must be ignored"

[ -f "$UNITY_PACKAGE" ] && [ ! -L "$UNITY_PACKAGE" ] || \
    die "missing regular licensed Unity package; set ELYSIUM_KUBIKOS_UNITYPACKAGE or install it at $DEFAULT_UNITY_PACKAGE"
[ "$(stat -f '%l' "$UNITY_PACKAGE")" = "1" ] || \
    die "licensed Unity package must not be hard-linked"
[ "$(sha256 "$UNITY_PACKAGE")" = "$EXPECTED_SOURCE_SHA256" ] || \
    die "licensed Unity package hash does not match the reviewed source"
[ ! -L "$KUBIKOS_OUTPUT" ] || die "generated KUBIKOS output must not be a symlink"

BUILD_LOG="$(mktemp /tmp/elysium-kubikos-theme-build.XXXXXX)"
if ! (cd "$ROOT" && swift build -c release --product elythemegen) >"$BUILD_LOG" 2>&1; then
    sed -n '1,240p' "$BUILD_LOG" >&2
    die "release elythemegen build failed"
fi
if grep -F 'warning:' "$BUILD_LOG" >/dev/null; then
    sed -n '1,240p' "$BUILD_LOG" >&2
    die "release elythemegen build emitted a warning"
fi
BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)"
case "$BIN_DIR" in
    "$ROOT"/.build/*) ;;
    *) die "SwiftPM returned an unexpected release binary directory" ;;
esac
REGISTRY_EXPORT="$BIN_DIR/elythemegen"
[ -f "$REGISTRY_EXPORT" ] && [ ! -L "$REGISTRY_EXPORT" ] && [ -x "$REGISTRY_EXPORT" ] || \
    die "missing safe release elythemegen executable"

swift "$ROOT/scripts/build-kubikos-theme.swift" \
    --unitypackage "$UNITY_PACKAGE" \
    --registry-export "$REGISTRY_EXPORT" \
    --output "$KUBIKOS_OUTPUT"
[ -f "$KUBIKOS_OUTPUT" ] && [ ! -L "$KUBIKOS_OUTPUT" ] || \
    die "builder did not produce a regular KUBIKOS archive"
bash "$ROOT/scripts/verify-pack-assets.sh"
echo "KUBIKOS_THEME_PREPARED archive=$KUBIKOS_OUTPUT"
