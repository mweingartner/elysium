#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARNIS="$ROOT/Vendor/Arnis"
OUTPUT="${1:-}"
EXPECTED_COMMIT="c0fad13d9f262d470e5e16d91c163ec039dbd857"

die() { echo "build-arnis-helper failed: $*" >&2; exit 1; }
[ -n "$OUTPUT" ] || die "usage: build-arnis-helper.sh OUTPUT"
[ -f "$ARNIS/Cargo.lock" ] && [ ! -L "$ARNIS/Cargo.lock" ] || die "missing pinned Cargo.lock"
[ -f "$ARNIS/ELYSIUM_PINNED_COMMIT" ] && [ ! -L "$ARNIS/ELYSIUM_PINNED_COMMIT" ] || \
    die "missing pinned commit receipt"
[ "$(tr -d '[:space:]' < "$ARNIS/ELYSIUM_PINNED_COMMIT")" = "$EXPECTED_COMMIT" ] || \
    die "unexpected Arnis source revision"
command -v cargo >/dev/null 2>&1 || die "Rust cargo is required to package Reality Derived maps"

TARGET="$ROOT/.build/arnis-helper"
(cd "$ARNIS" && CARGO_TARGET_DIR="$TARGET" cargo build --locked --release --no-default-features >&2)
SOURCE="$TARGET/release/arnis"
[ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] && [ -x "$SOURCE" ] || die "missing release helper"
mkdir -p "$(dirname "$OUTPUT")"
cp "$SOURCE" "$OUTPUT"
chmod 755 "$OUTPUT"
[ -f "$OUTPUT" ] && [ ! -L "$OUTPUT" ] && [ -x "$OUTPUT" ] || die "invalid staged helper"
