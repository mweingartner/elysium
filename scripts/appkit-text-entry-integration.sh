#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
NO_BUILD=false
EXECUTABLE=""
EXPECTED_HASH=""
PREPACKAGED_APP=""
PREPACKAGED_MANIFEST=""
EXPECTED_PACKAGED_HASH=""
TIMEOUT_SECONDS=90
die() { echo "AppKit integration failed: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-build) NO_BUILD=true; shift ;;
        --executable) EXECUTABLE="$2"; shift 2 ;;
        --expected-hash) EXPECTED_HASH="$2"; shift 2 ;;
        --prepackaged-app) PREPACKAGED_APP="$2"; shift 2 ;;
        --prepackaged-manifest) PREPACKAGED_MANIFEST="$2"; shift 2 ;;
        --expected-packaged-hash) EXPECTED_PACKAGED_HASH="$2"; shift 2 ;;
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
COORDINATOR_APP="$TMP_ROOT/ElysiumIntegrationCoordinator.app"
COORDINATOR="$COORDINATOR_APP/Contents/MacOS/ElysiumIntegrationCoordinator"
PID_FILE="$TMP_ROOT/driver-pid"
COORDINATOR_PID_FILE="$TMP_ROOT/coordinator-pid"
cleanup() {
    local cleanup_status=0
    cleanup_exact_process() {
        local file="$1" expected="$2" pid actual
        if [ -f "$file" ]; then
            pid="$(tr -cd '0-9' < "$file")"
            [ -n "$pid" ] || return 0
            actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
            if [ "$actual" = "$expected" ]; then
                kill -TERM "$pid" 2>/dev/null || true
                for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
                actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
                if [ "$actual" = "$expected" ]; then kill -KILL "$pid" 2>/dev/null || true; sleep 1; fi
            fi
        fi
        # The executable lives in a fresh wrapper-owned root, so exact command-path
        # enumeration covers the LaunchServices-completion-to-PID-file gap.
        while read -r pid; do
            [ -n "$pid" ] || continue
            actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
            [ "${actual%% *}" = "$expected" ] || { cleanup_status=1; continue; }
            kill -TERM "$pid" 2>/dev/null || true
            for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
        done < <(ps -axo pid=,command= | awk -v path="$expected" '$2 == path { print $1 }')
        if ps -axo command= | awk -v path="$expected" '$1 == path { found=1 } END { exit found ? 0 : 1 }'; then
            cleanup_status=1
        fi
    }
    if [ -d "$APP/Contents/MacOS" ]; then
        EXPECTED="$(cd "$APP/Contents/MacOS" 2>/dev/null && pwd -P)/Elysium"
        cleanup_exact_process "$PID_FILE" "$EXPECTED"
    fi
    if [ -d "$COORDINATOR_APP/Contents/MacOS" ]; then
        EXPECTED_COORDINATOR="$(cd "$COORDINATOR_APP/Contents/MacOS" 2>/dev/null && pwd -P)/ElysiumIntegrationCoordinator"
        cleanup_exact_process "$COORDINATOR_PID_FILE" "$EXPECTED_COORDINATOR"
    fi
    if [ "$cleanup_status" -eq 0 ] && [ -d "$TMP_ROOT" ] && [ ! -L "$TMP_ROOT" ] &&
       [ "$(stat -f %u "$TMP_ROOT")" = "$(id -u)" ]; then
        rm -rf "$TMP_ROOT"
    else
        echo "AppKit integration failed: cleanup/residue proof failed; retained $TMP_ROOT" >&2
        return 1
    fi
}
on_exit() {
    local status=$?
    trap - EXIT INT TERM
    cleanup || status=126
    exit "$status"
}
trap on_exit EXIT INT TERM

if [ -n "$PREPACKAGED_APP" ]; then
    [[ "$EXPECTED_PACKAGED_HASH" =~ ^[0-9a-f]{64}$ ]] || die "expected packaged hash invalid"
    [ -f "$PREPACKAGED_MANIFEST" ] && [ ! -L "$PREPACKAGED_MANIFEST" ] || \
        die "prepackaged manifest missing or unsafe"
    [ -d "$PREPACKAGED_APP" ] && [ ! -L "$PREPACKAGED_APP" ] || \
        die "prepackaged application missing or unsafe"
    [ "$(cd "$(dirname "$PREPACKAGED_APP")" && pwd -P)/$(basename "$PREPACKAGED_APP")" = \
      "$PREPACKAGED_APP" ] || die "prepackaged application path is not canonical"
    [ "$(shasum -a 256 "$PREPACKAGED_APP/Contents/MacOS/Elysium" | awk '{print $1}')" = \
      "$EXPECTED_PACKAGED_HASH" ] || die "prepackaged executable hash mismatch"
    /usr/bin/codesign --verify --deep --strict "$PREPACKAGED_APP" || \
        die "prepackaged application signature invalid"
    /usr/bin/ditto "$PREPACKAGED_APP" "$APP"
    [ "$(shasum -a 256 "$APP/Contents/MacOS/Elysium" | awk '{print $1}')" = \
      "$EXPECTED_PACKAGED_HASH" ] || die "copied package executable hash mismatch"
    /usr/bin/codesign --verify --deep --strict "$APP" || die "copied package signature invalid"
    cp "$PREPACKAGED_MANIFEST" "$MANIFEST"
    sed -i '' "s|^bundle_path=.*|bundle_path=$APP|; s|^executable_path=.*|executable_path=$APP/Contents/MacOS/Elysium|" "$MANIFEST"
else
    "$ROOT/scripts/package-app.sh" --executable "$EXECUTABLE" --output "$APP" \
        --manifest-stdout --expected-hash "$EXPECTED_HASH" > "$MANIFEST"
fi
install -d -m 700 "$TMP_ROOT/driver-source" "$TMP_ROOT/coordinator-source"
ln -s "$ROOT/Tests/ElysiumAppKitIntegration/Driver.swift" "$TMP_ROOT/driver-source/main.swift"
ln -s "$ROOT/Tests/ElysiumAppKitIntegration/Coordinator.swift" "$TMP_ROOT/coordinator-source/main.swift"
xcrun swiftc -O -warnings-as-errors -framework AppKit -framework ApplicationServices -framework CryptoKit \
    -framework Security -framework SystemConfiguration \
    "$ROOT/Tests/ElysiumAppKitIntegration/CoordinatorProtocol.swift" \
    "$TMP_ROOT/driver-source/main.swift" -o "$DRIVER"
DRIVER_HASH="$(shasum -a 256 "$DRIVER" | awk '{print $1}')"

install -d -m 700 "$COORDINATOR_APP/Contents/MacOS"
install -d -m 700 "$COORDINATOR_APP/Contents/Resources"
xcrun swiftc -O -warnings-as-errors -framework AppKit -framework CryptoKit \
    "$ROOT/Tests/ElysiumAppKitIntegration/CoordinatorProtocol.swift" \
    "$TMP_ROOT/coordinator-source/main.swift" -o "$COORDINATOR"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.briangao.elysium.integration-coordinator' \
    -c 'Add :CFBundleExecutable string ElysiumIntegrationCoordinator' \
    -c 'Add :CFBundlePackageType string APPL' \
    -c 'Add :CFBundleVersion string 1' \
    -c 'Add :LSUIElement bool false' "$COORDINATOR_APP/Contents/Info.plist"
chmod 500 "$COORDINATOR"
codesign --force --sign - --timestamp=none "$COORDINATOR_APP" >/dev/null
codesign --verify --strict --deep "$COORDINATOR_APP"
COORDINATOR_HASH="$(shasum -a 256 "$COORDINATOR" | awk '{print $1}')"

python3 - "$TIMEOUT_SECONDS" "$DRIVER" "$APP" "$MANIFEST" "$EXECUTABLE" \
    "$EXPECTED_HASH" "$PID_FILE" "$COORDINATOR_APP" "$COORDINATOR_HASH" "$COORDINATOR_PID_FILE" <<'PY'
import os, signal, subprocess, sys, threading
timeout = int(sys.argv[1])
driver = os.path.realpath(sys.argv[2])
process = subprocess.Popen(sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
command = subprocess.run(["/bin/ps", "-p", str(process.pid), "-o", "command="],
                         capture_output=True, text=True).stdout.strip().split(" ")[0]
if not command or os.path.realpath(command) != driver:
    process.kill(); raise SystemExit("AppKit integration failed: child command mismatch")
limit = 20_480
outputs = [bytearray(), bytearray()]
overflow = threading.Event()
def drain(stream, output):
    while True:
        chunk = stream.read(4096)
        if not chunk: break
        output.extend(chunk)
        if len(outputs[0]) + len(outputs[1]) > limit:
            overflow.set()
threads = [threading.Thread(target=drain, args=(process.stdout, outputs[0])),
           threading.Thread(target=drain, args=(process.stderr, outputs[1]))]
for thread in threads: thread.start()
try:
    status = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    command = subprocess.run(["/bin/ps", "-p", str(process.pid), "-o", "command="],
                             capture_output=True, text=True).stdout.strip().split(" ")[0]
    if os.path.realpath(command) != driver:
        raise SystemExit("AppKit integration failed: timeout child identity")
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    print("AppKit integration failed: outer timeout", file=sys.stderr)
    raise SystemExit(124)
finally:
    for thread in threads: thread.join(timeout=2)
if any(thread.is_alive() for thread in threads) or overflow.is_set():
    print("AppKit integration failed: driver output cap", file=sys.stderr)
    raise SystemExit(125)
sys.stdout.buffer.write(outputs[0]); sys.stderr.buffer.write(outputs[1])
if status < 0:
    raise SystemExit(128 - status)
raise SystemExit(status)
PY

if [ -f "$PID_FILE" ]; then
    PID="$(tr -cd '0-9' < "$PID_FILE")"
    EXPECTED="$(cd "$APP/Contents/MacOS" && pwd -P)/Elysium"
    ACTUAL="$(ps -p "$PID" -o command= 2>/dev/null || true)"
    [ "$ACTUAL" != "$EXPECTED" ] || die "test process leaked after driver completion"
fi

[ "$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')" = "$EXPECTED_HASH" ] || \
    die "release executable changed during gate"
[ "$(shasum -a 256 "$DRIVER" | awk '{print $1}')" = "$DRIVER_HASH" ] || die "Driver executable changed"
[ "$(shasum -a 256 "$COORDINATOR" | awk '{print $1}')" = "$COORDINATOR_HASH" ] || \
    die "Coordinator executable changed"
[ ! -e "$TMP_ROOT/IntegrationDriver.app" ] && [ ! -e "$TMP_ROOT/elysium-appkit-launcher" ] || \
    die "superseded foreground harness artifact residue"
