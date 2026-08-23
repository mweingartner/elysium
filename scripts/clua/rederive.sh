#!/usr/bin/env bash
# scripts/clua/rederive.sh — hermetic re-derivation of Sources/CLua from the pinned upstream
# Lua 5.4.8 tarball plus scripts/clua/elysium.patch (design.md Decision 1, Condition 31).
#
# Usage:
#   scripts/clua/rederive.sh [--write] [--tarball PATH]
#
#   (no flags)   fetch (or use --tarball), verify, extract, apply the patch, diff the result
#                against the checked-in Sources/CLua (ignoring the five Elysium-authored
#                files), and exit 1 naming every file that drifted. Exit 0 means the checked-in
#                tree is byte-identical to tarball + patch.
#   --write      same derivation, but overwrite Sources/CLua with the result instead of diffing.
#   --tarball P  use the local tarball at P instead of fetching over the network.
#
# In both modes scripts/clua/upstream-manifest.json is (re)written from the verified tarball's
# per-file contents once the derivation succeeds, so CLuaSourceTests can check provenance without
# any network access (it reverse-applies the patch and compares against this manifest).
#
# C31 fetch/extraction hygiene: HTTPS only, `curl --fail --proto '=https' --tlsv1.2
# --max-redirs 0 --max-time <n>`, verify SHA-256 and byte size before extraction, extract into a
# fresh temp directory, and assert the extracted kept set has no symlinks and no path escapes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUA_DIR="$ROOT/Sources/CLua"
PATCH_FILE="$ROOT/scripts/clua/elysium.patch"
MANIFEST_FILE="$ROOT/scripts/clua/upstream-manifest.json"

LUA_URL="https://www.lua.org/ftp/lua-5.4.8.tar.gz"
LUA_SHA256="4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae"
LUA_BYTES=374332

# The 54 upstream files kept: every src/*.c|*.h of Lua 5.4.8 except lua.c luac.c liolib.c
# loslib.c loadlib.c linit.c ldblib.c. lua.hpp is not matched by *.c|*.h and is not vendored.
KEPT_FILES=(
  lapi.c lapi.h lauxlib.c lauxlib.h lbaselib.c lcode.c lcode.h lcorolib.c lctype.c lctype.h
  ldebug.c ldebug.h ldo.c ldo.h ldump.c lfunc.c lfunc.h lgc.c lgc.h ljumptab.h llex.c llex.h
  llimits.h lmathlib.c lmem.c lmem.h lobject.c lobject.h lopcodes.c lopcodes.h lopnames.h
  lparser.c lparser.h lprefix.h lstate.c lstate.h lstring.c lstring.h lstrlib.c ltable.c
  ltable.h ltablib.c ltm.c ltm.h lua.h luaconf.h lualib.h lundump.c lundump.h lutf8lib.c
  lvm.c lvm.h lzio.c lzio.h
)
# Of those, the four public headers move under include/; everything else stays flat beside the
# .c files (private headers resolve through SwiftPM's -I include for "lua.h"-style includes).
PUBLIC_HEADERS=(lua.h luaconf.h lauxlib.h lualib.h)

is_public_header() {
  local f="$1" p
  for p in "${PUBLIC_HEADERS[@]}"; do
    [ "$f" = "$p" ] && return 0
  done
  return 1
}

layout_path() {
  local f="$1"
  if is_public_header "$f"; then
    printf 'include/%s' "$f"
  else
    printf '%s' "$f"
  fi
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

WRITE=0
TARBALL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --write) WRITE=1; shift ;;
    --tarball)
      [ $# -ge 2 ] || { echo "error: --tarball requires a path" >&2; exit 2; }
      TARBALL="$2"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TARBALL_COPY="$WORK/lua-5.4.8.tar.gz"
if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || { echo "error: no such tarball: $TARBALL" >&2; exit 1; }
  cp "$TARBALL" "$TARBALL_COPY"
else
  echo "Fetching $LUA_URL ..." >&2
  curl --fail --proto '=https' --tlsv1.2 --max-redirs 0 --max-time 120 \
    -o "$TARBALL_COPY" "$LUA_URL"
fi

ACTUAL_SHA256="$(sha256_of "$TARBALL_COPY")"
ACTUAL_BYTES="$(wc -c < "$TARBALL_COPY" | tr -d ' ')"
if [ "$ACTUAL_SHA256" != "$LUA_SHA256" ]; then
  echo "error: tarball SHA-256 mismatch: got $ACTUAL_SHA256, want $LUA_SHA256" >&2
  exit 1
fi
if [ "$ACTUAL_BYTES" != "$LUA_BYTES" ]; then
  echo "error: tarball size mismatch: got $ACTUAL_BYTES bytes, want $LUA_BYTES" >&2
  exit 1
fi
echo "Verified tarball: sha256=$ACTUAL_SHA256 bytes=$ACTUAL_BYTES" >&2

# Extract into a fresh directory, verify before use.
EXTRACT_DIR="$WORK/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL_COPY" -C "$EXTRACT_DIR"

SRC_DIR="$EXTRACT_DIR/lua-5.4.8/src"
[ -d "$SRC_DIR" ] || { echo "error: extracted tarball has no lua-5.4.8/src directory" >&2; exit 1; }

for f in "${KEPT_FILES[@]}"; do
  path="$SRC_DIR/$f"
  case "$f" in
    */*|*..*) echo "error: rejected path escape in kept-file list: $f" >&2; exit 1 ;;
  esac
  if [ -L "$path" ]; then
    echo "error: $f is a symlink in the extracted tarball" >&2
    exit 1
  fi
  if [ ! -f "$path" ]; then
    echo "error: expected upstream file missing from tarball: $f" >&2
    exit 1
  fi
done

# Build the Sources/CLua layout in a staging tree, then apply the Elysium patch to it. The patch
# hunks are headed a/<layout-path> b/<layout-path>, so -p1 resolves relative to $STAGE.
STAGE="$WORK/stage"
mkdir -p "$STAGE/include"
for f in "${KEPT_FILES[@]}"; do
  cp "$SRC_DIR/$f" "$STAGE/$(layout_path "$f")"
done

if [ -s "$PATCH_FILE" ]; then
  ( cd "$STAGE" && patch -p1 --no-backup-if-mismatch < "$PATCH_FILE" )
fi

if [ $WRITE -eq 1 ]; then
  mkdir -p "$CLUA_DIR/include"
  for f in "${KEPT_FILES[@]}"; do
    rel="$(layout_path "$f")"
    mkdir -p "$(dirname "$CLUA_DIR/$rel")"
    cp "$STAGE/$rel" "$CLUA_DIR/$rel"
  done
  echo "Wrote Sources/CLua from tarball + elysium.patch." >&2
else
  DRIFTED=0
  for f in "${KEPT_FILES[@]}"; do
    rel="$(layout_path "$f")"
    if [ ! -f "$CLUA_DIR/$rel" ]; then
      echo "drift: $rel is missing from Sources/CLua" >&2
      DRIFTED=1
      continue
    fi
    if ! diff -q "$STAGE/$rel" "$CLUA_DIR/$rel" >/dev/null 2>&1; then
      echo "drift: $rel differs from tarball + elysium.patch" >&2
      DRIFTED=1
    fi
  done
  if [ $DRIFTED -ne 0 ]; then
    echo "error: Sources/CLua has drifted from tarball + elysium.patch; re-run with --write" >&2
    exit 1
  fi
  echo "Sources/CLua matches tarball + elysium.patch (no drift)." >&2
fi

# Regenerate the manifest from the verified, pre-patch tarball contents (original src/ names).
{
  printf '{\n'
  printf '  "tarball": {\n'
  printf '    "url": "%s",\n' "$LUA_URL"
  printf '    "sha256": "%s",\n' "$LUA_SHA256"
  printf '    "bytes": %s\n' "$LUA_BYTES"
  printf '  },\n'
  printf '  "files": {\n'
  n=${#KEPT_FILES[@]}
  i=0
  for f in "${KEPT_FILES[@]}"; do
    i=$((i + 1))
    h="$(sha256_of "$SRC_DIR/$f")"
    if [ "$i" -lt "$n" ]; then
      printf '    "%s": "%s",\n' "$f" "$h"
    else
      printf '    "%s": "%s"\n' "$f" "$h"
    fi
  done
  printf '  }\n'
  printf '}\n'
} > "$MANIFEST_FILE"
echo "Wrote $MANIFEST_FILE" >&2

exit 0
