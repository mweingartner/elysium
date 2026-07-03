#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_APP="${PEBBLE_LAN_TEST_LOCAL_APP:-/Applications/Pebble.app}"
REMOTE_HOST="${PEBBLE_LAN_CLIENT_HOST:-neo.localdomain}"
REMOTE_USER="${PEBBLE_LAN_CLIENT_USER:-${USER:-}}"
REMOTE_TARGET="${PEBBLE_LAN_CLIENT_TARGET:-}"
REMOTE_APP="${PEBBLE_LAN_CLIENT_APP:-/Applications/Pebble.app}"
IDENTITY_FILE="${PEBBLE_LAN_CLIENT_IDENTITY:-$HOME/.ssh/pebble_neo_ed25519}"
JOIN_CODE="${PEBBLE_LAN_TEST_JOIN_CODE:-TST42A}"
PORT="${PEBBLE_LAN_TEST_PORT:-41337}"
SEED="${PEBBLE_LAN_TEST_SEED:-424242}"
TIMEOUT="${PEBBLE_LAN_TEST_TIMEOUT:-75}"
DEPLOY=0
KEEP_RUNNING=0
REMOTE_UID=""

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)
if [ -f "$IDENTITY_FILE" ]; then
    SSH_OPTS+=(-i "$IDENTITY_FILE")
fi

usage() {
    cat <<EOF
Usage: scripts/live-lan-test.sh [options]

Runs a two-Mac installed-app LAN probe between this Mac as host and Neo as
client. The probe builds a deterministic rig at spawn, auto-joins Neo through
Direct Connect, drives the client right-click path against a door, and checks
that a chest item snapshot replicated to the client.

Options:
  --deploy       Copy the current local /Applications/Pebble.app to Neo first
  --keep-running Leave both Pebble processes open after the probe
  --timeout SEC  Probe timeout in seconds (default: ${TIMEOUT})
  -h, --help     Show this help

Environment overrides:
  PEBBLE_LAN_TEST_LOCAL_APP, PEBBLE_LAN_CLIENT_HOST,
  PEBBLE_LAN_CLIENT_USER, PEBBLE_LAN_CLIENT_TARGET,
  PEBBLE_LAN_CLIENT_APP, PEBBLE_LAN_CLIENT_IDENTITY,
  PEBBLE_LAN_TEST_JOIN_CODE, PEBBLE_LAN_TEST_PORT,
  PEBBLE_LAN_TEST_SEED, PEBBLE_LAN_TEST_TIMEOUT
EOF
}

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --deploy)
            DEPLOY=1
            shift
            ;;
        --keep-running)
            KEEP_RUNNING=1
            shift
            ;;
        --timeout)
            [ "$#" -ge 2 ] || die "--timeout needs a value"
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

if [ -z "$REMOTE_TARGET" ]; then
    if [ -n "$REMOTE_USER" ]; then
        REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
    else
        REMOTE_TARGET="$REMOTE_HOST"
    fi
fi

remote() {
    ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" "$@"
}

remote_gui() {
    if [ -z "$REMOTE_UID" ]; then
        REMOTE_UID="$(remote "id -u" | tr -d '[:space:]')"
    fi
    remote "/bin/launchctl asuser '$REMOTE_UID' $*"
}

set_launch_env() {
    local key="$1"
    local value="$2"
    /bin/launchctl setenv "$key" "$value"
}

unset_launch_env() {
    /bin/launchctl unsetenv "$1" >/dev/null 2>&1 || true
}

remote_set_launch_env() {
    remote_gui "/bin/launchctl setenv '$1' '$(printf "%s" "$2" | sed "s/'/'\\\\''/g")'"
}

remote_unset_launch_env() {
    remote_gui "/bin/launchctl unsetenv '$1' >/dev/null 2>&1 || true"
}

cleanup_env() {
    for key in PEBBLE_AUTOLOAD PEBBLE_NEWWORLD PEBBLE_CMD PEBBLE_LAN_PROBE PEBBLE_LAN_PROBE_LOG PEBBLE_LAN_PROBE_TIMEOUT_FRAMES PEBBLE_LAN_PROBE_JOIN_CODE PEBBLE_LAN_PROBE_PORT PEBBLE_LAN_AUTOJOIN; do
        unset_launch_env "$key"
        remote_unset_launch_env "$key" >/dev/null 2>&1 || true
    done
}

stop_apps() {
    /usr/bin/osascript -e 'tell application "Pebble" to quit' >/dev/null 2>&1 || true
    /usr/bin/pkill -x Pebble >/dev/null 2>&1 || true
    remote "/usr/bin/osascript -e 'tell application \"Pebble\" to quit' >/dev/null 2>&1 || true; /usr/bin/pkill -x Pebble >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}

find_local_ip() {
    local iface ip
    iface="$(/sbin/route get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    [ -n "$iface" ] || return 1
    ip="$(/usr/sbin/ipconfig getifaddr "$iface" 2>/dev/null || true)"
    [ -n "$ip" ] || return 1
    printf '%s\n' "$ip"
}

require_app() {
    [ -d "$LOCAL_APP" ] || die "local app not found: $LOCAL_APP"
    [ -x "$LOCAL_APP/Contents/MacOS/Pebble" ] || die "local app executable not found: $LOCAL_APP/Contents/MacOS/Pebble"
    remote "test -d '$REMOTE_APP' && test -x '$REMOTE_APP/Contents/MacOS/Pebble'" >/dev/null || die "remote app not installed/executable: $REMOTE_APP"
}

poll_logs() {
    local deadline now host_pass client_pass
    deadline=$(( $(date +%s) + TIMEOUT ))
    host_pass=0
    client_pass=0
    while true; do
        if [ -f "$HOST_LOG" ] && grep -q 'LANPROBE PASS host remote-use' "$HOST_LOG"; then
            host_pass=1
        fi
        if remote "{ test -f '$REMOTE_LOG' && grep -q 'LANPROBE PASS client shared-state' '$REMOTE_LOG'; } || { test -f '$REMOTE_STDOUT' && grep -q 'LANPROBE PASS client shared-state' '$REMOTE_STDOUT'; }" >/dev/null 2>&1; then
            client_pass=1
        fi
        if [ "$host_pass" = "1" ] && [ "$client_pass" = "1" ]; then
            return 0
        fi
        if [ -f "$HOST_LOG" ] && grep -q 'LANPROBE FAIL' "$HOST_LOG"; then
            return 1
        fi
        if remote "{ test -f '$REMOTE_LOG' && grep -q 'LANPROBE FAIL' '$REMOTE_LOG'; } || { test -f '$REMOTE_STDOUT' && grep -q 'LANPROBE FAIL' '$REMOTE_STDOUT'; }" >/dev/null 2>&1; then
            return 1
        fi
        now="$(date +%s)"
        [ "$now" -lt "$deadline" ] || return 1
        sleep 1
    done
}

poll_remote_resume() {
    local deadline now
    deadline=$(( $(date +%s) + TIMEOUT ))
    while true; do
        if remote "{ test -f '$REMOTE_LOG' && grep -q 'LANPROBE PASS client resume-position' '$REMOTE_LOG'; } || { test -f '$REMOTE_STDOUT' && grep -q 'LANPROBE PASS client resume-position' '$REMOTE_STDOUT'; }" >/dev/null 2>&1; then
            return 0
        fi
        if remote "{ test -f '$REMOTE_LOG' && grep -q 'LANPROBE FAIL' '$REMOTE_LOG'; } || { test -f '$REMOTE_STDOUT' && grep -q 'LANPROBE FAIL' '$REMOTE_STDOUT'; }" >/dev/null 2>&1; then
            return 1
        fi
        now="$(date +%s)"
        [ "$now" -lt "$deadline" ] || return 1
        sleep 1
    done
}

print_tails() {
    say "Host probe log: $HOST_LOG"
    if [ -f "$HOST_LOG" ]; then
        tail -n 80 "$HOST_LOG"
    else
        printf 'missing host log\n'
    fi
    say "Neo probe log: $REMOTE_LOG"
    remote "if [ -f '$REMOTE_LOG' ]; then tail -n 80 '$REMOTE_LOG'; else echo missing remote log; fi" || true
    say "Neo stdout log: $REMOTE_STDOUT"
    remote "if [ -f '$REMOTE_STDOUT' ]; then tail -n 120 '$REMOTE_STDOUT'; else echo missing remote stdout; fi" || true
}

LOCAL_IP="$(find_local_ip)" || die "could not determine this Mac's LAN IP"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/tmp/pebble-lan-live-${RUN_ID}"
HOST_LOG="${LOG_DIR}/host.log"
REMOTE_LOG="/tmp/pebble-lan-live-${RUN_ID}-neo.log"
REMOTE_STDOUT="/tmp/pebble-lan-live-${RUN_ID}-neo.stdout"
CLIENT_JOIN="${LOCAL_IP} ${PORT} ${JOIN_CODE} Neo Probe"

mkdir -p "$LOG_DIR"

if [ "$DEPLOY" = "1" ]; then
    say "Deploying current local app to Neo"
    "$ROOT/scripts/deploy-lan-client.sh" --no-build --no-launch
fi

require_app
cleanup_env
stop_apps
rm -f "$HOST_LOG"
remote "rm -f '$REMOTE_LOG' '$REMOTE_STDOUT'"

say "Launching local host from $LOCAL_APP"
set_launch_env PEBBLE_AUTOLOAD 1
set_launch_env PEBBLE_NEWWORLD "$SEED"
set_launch_env PEBBLE_LAN_PROBE host-rig
set_launch_env PEBBLE_LAN_PROBE_LOG "$HOST_LOG"
set_launch_env PEBBLE_LAN_PROBE_TIMEOUT_FRAMES "$(( TIMEOUT * 60 ))"
set_launch_env PEBBLE_LAN_PROBE_JOIN_CODE "$JOIN_CODE"
set_launch_env PEBBLE_LAN_PROBE_PORT "$PORT"
/usr/bin/open -n "$LOCAL_APP"

say "Launching Neo client against ${LOCAL_IP}:${PORT}"
remote "cd /tmp && nohup env PEBBLE_LAN_AUTOJOIN='$(printf "%s" "$CLIENT_JOIN" | sed "s/'/'\\\\''/g")' PEBBLE_LAN_PROBE=client-door PEBBLE_LAN_PROBE_LOG='$REMOTE_LOG' PEBBLE_LAN_PROBE_TIMEOUT_FRAMES='$(( TIMEOUT * 60 ))' '$REMOTE_APP/Contents/MacOS/Pebble' > '$REMOTE_STDOUT' 2>&1 &"

if poll_logs; then
    say "Door/container phase passed; relaunching Neo to verify client resume position"
    remote "/usr/bin/pkill -x Pebble >/dev/null 2>&1 || true; sleep 2"
    remote "cd /tmp && nohup env PEBBLE_LAN_AUTOJOIN='$(printf "%s" "$CLIENT_JOIN" | sed "s/'/'\\\\''/g")' PEBBLE_LAN_PROBE=client-resume PEBBLE_LAN_PROBE_LOG='$REMOTE_LOG' PEBBLE_LAN_PROBE_TIMEOUT_FRAMES='$(( TIMEOUT * 60 ))' '$REMOTE_APP/Contents/MacOS/Pebble' >> '$REMOTE_STDOUT' 2>&1 &"
    if poll_remote_resume; then
        say "Live LAN probe passed"
        print_tails
        cleanup_env
        if [ "$KEEP_RUNNING" != "1" ]; then
            stop_apps
        fi
        exit 0
    fi
fi

say "Live LAN probe failed"
print_tails
cleanup_env
if [ "$KEEP_RUNNING" != "1" ]; then
    stop_apps
fi
exit 1
