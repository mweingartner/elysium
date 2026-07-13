#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
NO_BUILD=false
EXECUTABLE=""
EXPECTED_HASH=""
TIMEOUT_SECONDS=90
die() { echo "AppKit integration failed: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-build) NO_BUILD=true; shift ;;
        --executable) EXECUTABLE="$2"; shift 2 ;;
        --expected-hash) EXPECTED_HASH="$2"; shift 2 ;;
        --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
if [ "$NO_BUILD" = false ]; then (cd "$ROOT" && swift build -c release); fi
[ -n "$EXECUTABLE" ] || EXECUTABLE="$ROOT/.build/release/Elysium"
[ -f "$EXECUTABLE" ] && [ ! -L "$EXECUTABLE" ] || die "release executable missing or unsafe"
ACTUAL_HASH="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
[ -n "$EXPECTED_HASH" ] || EXPECTED_HASH="$ACTUAL_HASH"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "release hash mismatch"

TMP_ROOT="$(mktemp -d /tmp/elysium-appkit-gate.XXXXXX)"
APP="$TMP_ROOT/Elysium.app"
MANIFEST="$TMP_ROOT/package-manifest"
DRIVER="$TMP_ROOT/elysium-appkit-driver"
PID_FILE="$TMP_ROOT/driver-pid"
cleanup() {
    if [ -f "$PID_FILE" ]; then
        PID="$(tr -cd '0-9' < "$PID_FILE")"
        EXPECTED="$(cd "$APP/Contents/MacOS" 2>/dev/null && pwd -P)/Elysium"
        if [ -n "$PID" ]; then
            ACTUAL="$(ps -p "$PID" -o command= 2>/dev/null || true)"
            if [ "$ACTUAL" = "$EXPECTED" ]; then
                kill -TERM "$PID" 2>/dev/null || true
                for _ in 1 2 3 4 5; do
                    kill -0 "$PID" 2>/dev/null || break
                    sleep 1
                done
                ACTUAL="$(ps -p "$PID" -o command= 2>/dev/null || true)"
                if [ "$ACTUAL" = "$EXPECTED" ]; then
                    kill -KILL "$PID" 2>/dev/null || true
                    sleep 1
                fi
            fi
        fi
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

"$ROOT/scripts/package-app.sh" --executable "$EXECUTABLE" --output "$APP" \
    --manifest "$MANIFEST" --expected-hash "$EXPECTED_HASH"
xcrun swiftc -O -framework AppKit -framework ApplicationServices -framework CryptoKit \
    -framework SystemConfiguration "$ROOT/Tests/ElysiumAppKitIntegration/Driver.swift" -o "$DRIVER"

python3 - "$TIMEOUT_SECONDS" "$DRIVER" "$APP" "$MANIFEST" "$EXECUTABLE" "$EXPECTED_HASH" "$PID_FILE" <<'PY'
import subprocess, sys
timeout = int(sys.argv[1])
process = subprocess.Popen(sys.argv[2:])
try:
    result = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    print("AppKit integration failed: outer timeout", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(result)
PY

if [ -f "$PID_FILE" ]; then
    PID="$(tr -cd '0-9' < "$PID_FILE")"
    EXPECTED="$(cd "$APP/Contents/MacOS" && pwd -P)/Elysium"
    ACTUAL="$(ps -p "$PID" -o command= 2>/dev/null || true)"
    [ "$ACTUAL" != "$EXPECTED" ] || die "test process leaked after driver completion"
fi

[ "$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')" = "$EXPECTED_HASH" ] || \
    die "release executable changed during gate"
