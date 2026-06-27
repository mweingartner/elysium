#!/bin/bash
set -euo pipefail

TARGET="${1:-$HOME/Applications/Pebble.app}"

fail() { echo "binary security check failed: $*" >&2; exit 1; }

if [ -d "$TARGET" ]; then
    APP="$TARGET"
    BIN="$APP/Contents/MacOS/Pebble"
    [ -x "$BIN" ] || fail "missing executable at $BIN"
    /usr/bin/codesign --verify --deep --strict "$APP" || fail "codesign verification failed"
    /usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist is invalid"
    BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
    [ "$BID" = "com.briangao.pebble" ] || fail "unexpected bundle id: $BID"
else
    BIN="$TARGET"
    [ -x "$BIN" ] || fail "missing executable at $BIN"
fi

echo "==> binary: linked libraries"
if /usr/bin/otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/Library/|/usr/lib/|@rpath/libswift|@executable_path/|$)'; then
    fail "non-system linked library found"
fi

echo "==> binary: network symbol scan"
if /usr/bin/nm -u "$BIN" 2>/dev/null | grep -E '_NSURLConnection|_NWConnection|_CFSocket|_socket|_connect|_listen|_accept'; then
    fail "unapproved network-related undefined symbol found"
fi

URL_STRINGS="$(/usr/bin/strings "$BIN" | grep -Eo 'https?://[^[:space:]")<]+' | sort -u || true)"
BAD_URL_STRINGS="$(printf '%s\n' "$URL_STRINGS" | grep -v '^http://localhost:11434' || true)"
if [ -n "$BAD_URL_STRINGS" ]; then
    printf '%s\n' "$BAD_URL_STRINGS"
    fail "unapproved URL string found"
fi

if /usr/bin/strings "$BIN" | grep -Ei 'NSURLConnection|NWConnection|CFSocket' >/dev/null; then
    fail "unapproved network-related string found"
fi

if /usr/bin/strings "$BIN" | grep -Ei 'URLSession' >/dev/null; then
    if ! /usr/bin/strings "$BIN" | grep -F 'http://localhost:11434' >/dev/null; then
        fail "URLSession string found without approved local Ollama endpoint"
    fi
fi

echo "==> binary: passed"
