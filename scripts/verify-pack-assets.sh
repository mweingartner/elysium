#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK="$ROOT/packaging/Faithful 32x - 1.20.1.zip"

fail() { echo "asset verification failed: $*" >&2; exit 1; }

echo "==> assets: verifying bundled Faithful pack"

[ -f "$PACK" ] || fail "missing $PACK"
unzip -tq "$PACK" >/dev/null || fail "zip integrity check failed"
LIST="$(mktemp /tmp/elysium-pack-list.XXXXXX)"
trap 'rm -f "$LIST"' EXIT
unzip -Z1 "$PACK" >"$LIST"

require_entry() {
    local entry="$1"
    if ! grep -Fxq "$entry" "$LIST"; then
        fail "missing required entry: $entry"
    fi
}

require_entry "pack.mcmeta"
require_entry "assets/minecraft/textures/block/stone.png"
require_entry "assets/minecraft/textures/item/diamond.png"
require_entry "assets/minecraft/textures/gui/widgets.png"

if ! grep -Eq '^assets/minecraft/textures/(block|item|gui)/' "$LIST"; then
    fail "minecraft texture namespace not found"
fi

echo "==> assets: Faithful pack verified"
