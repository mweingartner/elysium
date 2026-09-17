#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { echo "asset verification failed: $*" >&2; exit 1; }

verify_archive() {
    local name="$1" expected="$2"
    shift 2
    local archive="$ROOT/packaging/$name" list
    [ -f "$archive" ] && [ ! -L "$archive" ] || fail "missing regular archive: $name"
    [ "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$expected" ] || \
        fail "hash mismatch: $name"
    unzip -tq "$archive" >/dev/null || fail "zip integrity check failed: $name"
    list="$(mktemp /tmp/elysium-pack-list.XXXXXX)"
    unzip -Z1 "$archive" >"$list"
    while [ "$#" -gt 0 ]; do
        grep -Fxq "$1" "$list" || { rm -f "$list"; fail "$name missing $1"; }
        shift
    done
    [ "$(LC_ALL=C sort -f "$list" | uniq -di | wc -l | tr -d ' ')" -eq 0 ] || {
        rm -f "$list"; fail "$name contains case-folded duplicate paths";
    }
    rm -f "$list"
}

echo "==> assets: verifying Faithful 64x and reviewed add-ons"
verify_archive "Faithful 64x - December 2025 Release.zip" \
    a136d9101a4748558587980dace3cd7447b758fb72c4684d15fb805d0a812dac \
    pack.mcmeta LICENSE.txt \
    assets/minecraft/textures/block/stone.png \
    assets/minecraft/textures/item/diamond.png \
    assets/minecraft/textures/gui/container/inventory.png \
    assets/minecraft/textures/font/ascii.png
verify_archive "Faithful 64x - Ore Borders 64x.zip" \
    232b8a64d745dc08b958c3c4c07167bd3f38eebdc4cd682da9d1016b2ed190f8 \
    pack.mcmeta LICENSE.txt CREDITS.txt \
    assets/minecraft/textures/block/coal_ore.png \
    assets/minecraft/textures/block/diamond_ore.png \
    assets/minecraft/textures/block/deepslate_diamond_ore.png \
    assets/minecraft/textures/block/nether_quartz_ore.png
verify_archive "Faithful 64x - Static Lanterns.zip" \
    d0165130d505da8996354c21090a47fd6def87f4c2a96442f1a4282b1bf2cbc8 \
    pack.mcmeta LICENSE.txt assets/minecraft/textures/block/sea_lantern.png

[ -f "$ROOT/packaging/FAITHFUL-LICENSE.txt" ] || fail "missing Faithful license"
[ -f "$ROOT/packaging/FAITHFUL-ADDONS-CREDITS.txt" ] || fail "missing add-on credits"
grep -Fxq "Vanilla Tweaks Team" "$ROOT/packaging/FAITHFUL-ADDONS-CREDITS.txt" || \
    fail "missing Ore Borders attribution"
grep -Fq "Aerod" "$ROOT/packaging/FAITHFUL-ADDONS-CREDITS.txt" || fail "missing Aerod credit"
grep -Fq "Hedreon" "$ROOT/packaging/FAITHFUL-ADDONS-CREDITS.txt" || fail "missing Hedreon credit"
grep -Fq "Scutoel" "$ROOT/packaging/FAITHFUL-ADDONS-CREDITS.txt" || fail "missing Scutoel credit"

echo "==> assets: Faithful 64x packs verified (3 archives, exact hashes)"
