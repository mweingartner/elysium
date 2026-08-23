#!/bin/bash
# Builds the independent fdlibm reference and regenerates goldens/fmath-explog-goldens.json.
#
# This is a frozen-reference generator: goldens/fmath-explog-goldens.json is committed once
# and never regenerated in the ordinary course of development (design.md Decision 14). Running
# this script is how that commit was produced, and how a reviewer re-derives it byte-for-byte
# to confirm it was not hand-edited.
#
# Fetch/extraction hygiene (design.md Condition 31 / security-plan.md F14): HTTPS only, no
# redirects, bounded timeouts, hashes verified *before* the file is used for anything, a fresh
# temp directory per fetch. Upstream files are never edited — if the ancient fdlibm headers
# need a compatibility shim (they do: __LITTLE_ENDIAN, see below), it lives in this script's
# compiler flags, never in scripts/fdlibm-reference/upstream/.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_DIR="$ROOT_DIR/upstream"
MANIFEST="$ROOT_DIR/MANIFEST.sha256"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
GOLDEN_PATH="$REPO_ROOT/goldens/fmath-explog-goldens.json"

NETLIB_BASE="https://www.netlib.org/fdlibm"
FILES=(fdlibm.h e_exp.c e_log.c e_pow.c s_scalbn.c s_copysign.c s_fabs.c e_sqrt.c)

log() { printf '%s\n' "$*" >&2; }

verify_manifest() {
    local dir="$1"
    ( cd "$dir" && shasum -a 256 -c "$MANIFEST" ) >&2
}

fetch_if_empty() {
    if [ -d "$UPSTREAM_DIR" ] && [ -n "$(ls -A "$UPSTREAM_DIR" 2>/dev/null || true)" ]; then
        log "upstream/ already populated — skipping fetch"
        return
    fi
    mkdir -p "$UPSTREAM_DIR"

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    log "fetching fdlibm sources from $NETLIB_BASE (HTTPS only)"
    for f in "${FILES[@]}"; do
        curl --fail --proto '=https' --tlsv1.2 --max-redirs 0 --max-time 120 \
            -o "$tmp/$f" "$NETLIB_BASE/$f"
    done

    # Verify before this fetch is trusted for anything else.
    verify_manifest "$tmp"

    for f in "${FILES[@]}"; do
        cp "$tmp/$f" "$UPSTREAM_DIR/$f"
    done
    log "verified and installed ${#FILES[@]} files into $UPSTREAM_DIR"
}

fetch_if_empty

log "verifying upstream/ against MANIFEST.sha256"
verify_manifest "$UPSTREAM_DIR"
log "all ${#FILES[@]} upstream files verified"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# -D__LITTLE_ENDIAN: the only compatibility shim these sources need. fdlibm.h's own endian
# probe (`#if defined(i386) || ... || defined(__osf__)`) predates arm64 and picks the
# big-endian __HI/__LO layout by default on this machine, which would silently swap the high
# and low words of every double. arm64 (like every Apple Silicon target) is little-endian, so
# this flag is a correctness fix, not a preference — passed on the command line, never by
# editing upstream/fdlibm.h.
CFLAGS=(-std=c99 -O0 -fno-builtin -ffp-contract=off -D_IEEE_LIBM -D__LITTLE_ENDIAN -I "$UPSTREAM_DIR")

log "compiling reference build (cc ${CFLAGS[*]})"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/e_exp.c" -o "$BUILD_DIR/e_exp.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/e_log.c" -o "$BUILD_DIR/e_log.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/e_pow.c" -o "$BUILD_DIR/e_pow.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/s_scalbn.c" -o "$BUILD_DIR/s_scalbn.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/s_copysign.c" -o "$BUILD_DIR/s_copysign.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/s_fabs.c" -o "$BUILD_DIR/s_fabs.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/e_sqrt.c" -o "$BUILD_DIR/e_sqrt.o"
cc -std=c99 -O0 -fno-builtin -ffp-contract=off -D_IEEE_LIBM \
    -c "$ROOT_DIR/gen-explog-goldens.c" -o "$BUILD_DIR/gen-explog-goldens.o"

cc -o "$BUILD_DIR/gen-explog-goldens" \
    "$BUILD_DIR/gen-explog-goldens.o" "$BUILD_DIR/e_exp.o" "$BUILD_DIR/e_log.o" \
    "$BUILD_DIR/e_pow.o" "$BUILD_DIR/s_scalbn.o" "$BUILD_DIR/s_copysign.o" \
    "$BUILD_DIR/s_fabs.o" "$BUILD_DIR/e_sqrt.o"

log "running the reference generator"
"$BUILD_DIR/gen-explog-goldens" "$GOLDEN_PATH"

log "wrote $GOLDEN_PATH"
log "verified upstream digests:"
( cd "$UPSTREAM_DIR" && shasum -a 256 "${FILES[@]}" ) >&2
