#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET="${1:-/Applications/Elysium.app}"
DEBUG_CONTROL_MARKER="elysium_debug_control_build_marker_v1"

fail() { echo "binary security check failed: $*" >&2; exit 1; }
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

[ "$#" -le 1 ] || fail "usage: scripts/security-check-binary.sh [EXECUTABLE_OR_APP]"

if [ -d "$TARGET" ]; then
    APP="$TARGET"
    BIN="$APP/Contents/MacOS/Elysium"
    PLIST="$APP/Contents/Info.plist"
    [ -f "$BIN" ] && [ ! -L "$BIN" ] && [ -x "$BIN" ] || fail "missing executable at $BIN"
    /usr/bin/codesign --verify --deep --strict "$APP" || fail "codesign verification failed"
    /usr/bin/plutil -lint "$PLIST" >/dev/null || fail "Info.plist is invalid"
    BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
    [ "$BID" = "com.briangao.elysium" ] || fail "unexpected bundle id: $BID"
else
    BIN="$TARGET"
    PLIST="$ROOT/packaging/Info.plist"
    [ -f "$BIN" ] && [ ! -L "$BIN" ] && [ -x "$BIN" ] || fail "missing executable at $BIN"
fi

if binary_contains_debug_marker "$BIN"; then
    fail "production executable contains forbidden debug-control marker: $DEBUG_CONTROL_MARKER"
fi
if /usr/bin/nm "$BIN" 2>/dev/null | /usr/bin/grep -F 'ElysiumDebugProtocol' >/dev/null \
    || /usr/bin/strings "$BIN" | /usr/bin/grep -F 'ElysiumDebugProtocol' >/dev/null; then
    fail "production executable contains the debug-control protocol module"
fi

LAN_ALLOWED=0
if [ -f "${PLIST:-}" ]; then
    if /usr/bin/plutil -lint "$PLIST" >/dev/null &&
       /usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$PLIST" >/dev/null 2>&1 &&
       /usr/libexec/PlistBuddy -c 'Print :NSBonjourServices:0' "$PLIST" 2>/dev/null | grep -Fx '_elysium-lan._tcp' >/dev/null; then
        LAN_ALLOWED=1
    fi
fi

echo "==> binary: linked libraries"
if /usr/bin/otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/Library/|/usr/lib/|@rpath/libswift|@executable_path/|$)'; then
    fail "non-system linked library found"
fi

echo "==> binary: network symbol scan"
NETWORK_SYMBOLS="$(/usr/bin/nm -u "$BIN" 2>/dev/null | grep -E '_NSURLConnection|_NWConnection|_NWListener|_NWBrowser|_CFSocket|[[:space:]]_(socket|connect|listen|accept)$' || true)"
if [ -n "$NETWORK_SYMBOLS" ]; then
    BAD_NETWORK_SYMBOLS="$(printf '%s\n' "$NETWORK_SYMBOLS" | grep -Ev '_NWConnection|_NWListener|_NWBrowser' || true)"
    if [ -n "$BAD_NETWORK_SYMBOLS" ]; then
        printf '%s\n' "$BAD_NETWORK_SYMBOLS"
        fail "unapproved low-level network-related undefined symbol found"
    fi
    if [ "$LAN_ALLOWED" != "1" ]; then
        printf '%s\n' "$NETWORK_SYMBOLS"
        fail "Network.framework symbols found without Elysium LAN Info.plist declarations"
    fi
fi

URL_STRINGS="$(/usr/bin/strings "$BIN" | grep -Eo 'https?://[^[:space:]")<]+' | sort -u || true)"
BAD_URL_STRINGS="$(printf '%s\n' "$URL_STRINGS" | grep -v '^http://localhost:11434' || true)"
if [ -n "$BAD_URL_STRINGS" ]; then
    printf '%s\n' "$BAD_URL_STRINGS"
    fail "unapproved URL string found"
fi

NETWORK_STRINGS="$(/usr/bin/strings "$BIN" | grep -Ei 'NSURLConnection|NWConnection|NWListener|NWBrowser|CFSocket' || true)"
if [ -n "$NETWORK_STRINGS" ]; then
    BAD_NETWORK_STRINGS="$(printf '%s\n' "$NETWORK_STRINGS" | grep -Eiv 'NWConnection|NWListener|NWBrowser' || true)"
    if [ -n "$BAD_NETWORK_STRINGS" ]; then
        printf '%s\n' "$BAD_NETWORK_STRINGS"
        fail "unapproved network-related string found"
    fi
    if [ "$LAN_ALLOWED" != "1" ]; then
        printf '%s\n' "$NETWORK_STRINGS"
        fail "Network.framework string found without Elysium LAN Info.plist declarations"
    fi
fi

if /usr/bin/strings "$BIN" | grep -Ei 'URLSession' >/dev/null; then
    if ! /usr/bin/strings "$BIN" | grep -F 'http://localhost:11434' >/dev/null; then
        fail "URLSession string found without approved local Ollama endpoint"
    fi
fi

echo "==> binary: passed"
