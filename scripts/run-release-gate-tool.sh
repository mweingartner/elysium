#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ "$#" -ge 1 ] || { echo "release-gate tool source required" >&2; exit 64; }
SOURCE="$1"; shift
cd "$ROOT"
case "$SOURCE" in scripts/installed-signoff-receipt.swift) ;; *) echo "unapproved release-gate tool" >&2; exit 64 ;; esac
swift build --target ElysiumReleaseGate >/dev/null
PRODUCTS="$(swift build --show-bin-path)"
OBJECT="$PRODUCTS/ElysiumReleaseGate.o"
[ -f "$OBJECT" ] || { echo "release-gate object missing" >&2; exit 1; }
KEY="$(shasum -a 256 scripts/installed-signoff-receipt.swift scripts/observe-installed-signoff.swift \
    scripts/designer-attest-installed-signoff.swift Sources/ElysiumReleaseGate/*.swift | \
    shasum -a 256 | awk '{print $1}')"
TOOLS="$ROOT/.build/release-gate-tools"
mkdir -p "$TOOLS"
BINARY="$TOOLS/$KEY"
if [ ! -x "$BINARY" ]; then
    xcrun swiftc -parse-as-library scripts/installed-signoff-receipt.swift \
        scripts/observe-installed-signoff.swift scripts/designer-attest-installed-signoff.swift \
        -I "$PRODUCTS" "$OBJECT" -framework Security -framework AppKit \
        -framework ApplicationServices -framework CoreGraphics -o "$BINARY.tmp"
    mv "$BINARY.tmp" "$BINARY"; chmod 700 "$BINARY"
fi
exec "$BINARY" "$@"
