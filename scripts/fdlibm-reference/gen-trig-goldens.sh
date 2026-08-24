#!/bin/bash
# Builds the independent fdlibm reference and regenerates goldens/fmath-trig-goldens.json.
#
# This is a frozen-reference generator, same contract as gen-explog-goldens.sh: the golden is
# committed once and never regenerated in the ordinary course of development. Running this
# script is how that commit was produced, and how a reviewer re-derives it byte-for-byte to
# confirm it was not hand-edited.
#
# Fetch/extraction hygiene (mirrors gen-explog-goldens.sh exactly): HTTPS only, no redirects,
# bounded timeouts, hashes verified *before* a file is used for anything, a fresh temp
# directory per fetch. Upstream files are never edited — the __LITTLE_ENDIAN shim lives in
# this script's compiler flags, never in scripts/fdlibm-reference/upstream/.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_DIR="$ROOT_DIR/upstream"
MANIFEST="$ROOT_DIR/MANIFEST.sha256"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
GOLDEN_PATH="$REPO_ROOT/goldens/fmath-trig-goldens.json"

NETLIB_BASE="https://www.netlib.org/fdlibm"
# Full file set this generator needs (shared with gen-explog-goldens.sh plus the
# tan/asin/acos/log10 set added for change 3 / deterministic-math). Classic netlib fdlibm has
# no e_log2.c (see gen-trig-goldens.c's header comment) — log2 is derived, not fetched.
FILES=(fdlibm.h e_exp.c e_log.c e_pow.c s_scalbn.c s_copysign.c s_fabs.c e_sqrt.c
       e_acos.c e_asin.c e_log10.c e_rem_pio2.c k_rem_pio2.c k_tan.c s_tan.c)

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
log "all $(ls "$UPSTREAM_DIR" | wc -l | tr -d ' ') upstream files verified"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# -D__LITTLE_ENDIAN: see gen-explog-goldens.sh's comment — arm64 is little-endian and
# fdlibm.h's own endian probe predates it, so this is a correctness fix, passed on the
# command line, never by editing upstream/fdlibm.h.
CFLAGS=(-std=c99 -O0 -fno-builtin -ffp-contract=off -D_IEEE_LIBM -D__LITTLE_ENDIAN -I "$UPSTREAM_DIR")

log "compiling reference build (cc ${CFLAGS[*]})"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/e_log.c" -o "$BUILD_DIR/e_log.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/e_asin.c" -o "$BUILD_DIR/e_asin.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/e_acos.c" -o "$BUILD_DIR/e_acos.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/e_log10.c" -o "$BUILD_DIR/e_log10.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/k_tan.c" -o "$BUILD_DIR/k_tan.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/s_tan.c" -o "$BUILD_DIR/s_tan.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/e_rem_pio2.c" -o "$BUILD_DIR/e_rem_pio2.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/k_rem_pio2.c" -o "$BUILD_DIR/k_rem_pio2.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/s_scalbn.c" -o "$BUILD_DIR/s_scalbn.o"
cc "${CFLAGS[@]}" -c "$UPSTREAM_DIR/s_fabs.c" -o "$BUILD_DIR/s_fabs.o"
cc -std=c99 -O0 -fno-builtin -ffp-contract=off -D_IEEE_LIBM \
    -c "$ROOT_DIR/gen-trig-goldens.c" -o "$BUILD_DIR/gen-trig-goldens.o"

cc -o "$BUILD_DIR/gen-trig-goldens" \
    "$BUILD_DIR/gen-trig-goldens.o" "$BUILD_DIR/e_log.o" "$BUILD_DIR/e_asin.o" \
    "$BUILD_DIR/e_acos.o" "$BUILD_DIR/e_log10.o" "$BUILD_DIR/k_tan.o" "$BUILD_DIR/s_tan.o" \
    "$BUILD_DIR/e_rem_pio2.o" "$BUILD_DIR/k_rem_pio2.o" "$BUILD_DIR/s_scalbn.o" \
    "$BUILD_DIR/s_fabs.o"

log "running the reference generator"
"$BUILD_DIR/gen-trig-goldens" "$GOLDEN_PATH"

log "wrote $GOLDEN_PATH"
log "verified upstream digests (full set, shared with gen-explog-goldens.sh):"
( cd "$UPSTREAM_DIR" && shasum -a 256 "${FILES[@]}" ) >&2
