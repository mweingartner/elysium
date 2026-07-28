#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lan-automation-lib.sh"
LOCAL_APP="${ELYSIUM_LAN_TEST_LOCAL_APP:-/Applications/Elysium.app}"
REMOTE_APP_REL="Applications/Elysium.app"
KNOWN_HOSTS_FILE="${ELYSIUM_LAN_KNOWN_HOSTS:-$HOME/.ssh/elysium_lan_known_hosts}"
NEO_TARGET="${ELYSIUM_LAN_NEO_TARGET:-${USER:-}@neo.localdomain}"
AIR_TARGET="${ELYSIUM_LAN_AIR_TARGET:-${USER:-}@michaels-air.localdomain}"
NEO_IDENTITY="${ELYSIUM_LAN_NEO_IDENTITY:-$HOME/.ssh/elysium_neo_ed25519}"
AIR_IDENTITY="${ELYSIUM_LAN_AIR_IDENTITY:-$HOME/.ssh/elysium_air_ed25519}"
PORT="${ELYSIUM_LAN_TEST_PORT:-41337}"
SEED="${ELYSIUM_LAN_TEST_SEED:-424242}"
TIMEOUT="${ELYSIUM_LAN_TEST_TIMEOUT:-90}"
DEPLOY=0
KEEP_RUNNING=0
NEO_ONLY=0

HOST_PID=""
HOST_CAFFEINATE_PID=""
NEO_PID=""
NEO_CAFFEINATE_PID=""
AIR_PID=""
AIR_CAFFEINATE_PID=""

usage() {
    cat <<EOF
Usage: scripts/live-lan-test.sh [options]

Runs one installed host plus Neo and, by default, Air. Neo submits the door
intent, Air independently observes the replicated door/container state, then
Neo reconnects. Exact executable hashes must match before launch.

Options:
  --deploy       Deploy the current local app bytes to both clients first
  --neo-only     Run a two-Mac host + Neo convergence/reconnect probe
  --keep-running Leave app processes open after the probe (caffeinate still stops)
  --timeout SEC  Per-phase timeout (default: ${TIMEOUT})
  -h, --help     Show this help

Required one-time setup is documented in docs/LAN_TEST_LAB.md.
EOF
}

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --deploy) DEPLOY=1; shift ;;
        --neo-only) NEO_ONLY=1; shift ;;
        --keep-running) KEEP_RUNNING=1; shift ;;
        --timeout) [ "$#" -ge 2 ] || die "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
case "$TIMEOUT" in ''|*[!0-9]*) die "timeout must be an integer" ;; esac
[ "$TIMEOUT" -ge 10 ] || die "timeout must be at least 10 seconds"
lan_validate_port "$PORT" || die "ELYSIUM_LAN_TEST_PORT must be an integer from 1 through 65535"

SSH_BASE=(
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
    -o ConnectTimeout=10
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2
)

node_target() { if [ "$1" = "neo" ]; then printf '%s\n' "$NEO_TARGET"; else printf '%s\n' "$AIR_TARGET"; fi; }
node_identity() { if [ "$1" = "neo" ]; then printf '%s\n' "$NEO_IDENTITY"; else printf '%s\n' "$AIR_IDENTITY"; fi; }
remote() {
    local node="$1" target identity
    shift
    target="$(node_target "$node")"
    identity="$(node_identity "$node")"
    ssh "${SSH_BASE[@]}" -i "$identity" "$target" "$@"
}
copy_from() {
    local node="$1" source="$2" destination="$3" target identity
    target="$(node_target "$node")"
    identity="$(node_identity "$node")"
    scp "${SSH_BASE[@]}" -i "$identity" "${target}:${source}" "$destination"
}

stop_remote_run() {
    local node="$1" app_pid="$2" caf_pid="$3"
    [ -n "$caf_pid" ] && remote "$node" "/bin/kill -TERM '$caf_pid' 2>/dev/null || true" >/dev/null 2>&1 || true
    [ -n "$app_pid" ] && remote "$node" "/bin/kill -TERM '$app_pid' 2>/dev/null || true" >/dev/null 2>&1 || true
}

cleanup() {
    status=$?
    if [ -n "$HOST_CAFFEINATE_PID" ]; then /bin/kill -TERM "$HOST_CAFFEINATE_PID" 2>/dev/null || true; fi
    if [ -n "$NEO_CAFFEINATE_PID" ]; then remote neo "/bin/kill -TERM '$NEO_CAFFEINATE_PID' 2>/dev/null || true" >/dev/null 2>&1 || true; fi
    if [ -n "$AIR_CAFFEINATE_PID" ]; then remote air "/bin/kill -TERM '$AIR_CAFFEINATE_PID' 2>/dev/null || true" >/dev/null 2>&1 || true; fi
    if [ "$KEEP_RUNNING" != "1" ]; then
        if [ -n "$HOST_PID" ]; then /bin/kill -TERM "$HOST_PID" 2>/dev/null || true; fi
        stop_remote_run neo "$NEO_PID" ""
        stop_remote_run air "$AIR_PID" ""
    fi
    wait "$HOST_CAFFEINATE_PID" 2>/dev/null || true
    printf 'cleanup=caffeinate_stopped\n'
    exit "$status"
}
trap cleanup EXIT INT TERM

find_local_ip() {
    local iface
    iface="$(/sbin/route get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
    /usr/sbin/ipconfig getifaddr "$iface" 2>/dev/null
}

REQUIRED_SSH_MATERIAL=("$KNOWN_HOSTS_FILE" "$NEO_IDENTITY")
if [ "$NEO_ONLY" != "1" ]; then REQUIRED_SSH_MATERIAL+=("$AIR_IDENTITY"); fi
for required in "${REQUIRED_SSH_MATERIAL[@]}"; do
    [ -f "$required" ] || die "required pinned SSH material is missing: $required"
done
[ -d "$LOCAL_APP" ] || die "local app not found: $LOCAL_APP"
LOCAL_EXECUTABLE="$LOCAL_APP/Contents/MacOS/Elysium"
[ -x "$LOCAL_EXECUTABLE" ] || die "local executable missing: $LOCAL_EXECUTABLE"
/usr/bin/codesign --verify --deep --strict "$LOCAL_APP" || die "local app signature is invalid"
"$ROOT/scripts/security-check-binary.sh" "$LOCAL_EXECUTABLE" \
    || die "local executable contains a forbidden production/debug-control surface"

LOCAL_IP="$(find_local_ip)" || die "could not determine this Mac's LAN IP"
JOIN_CODE="$(/usr/bin/openssl rand -hex 4 | /usr/bin/tr 'a-f' 'A-F')"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOG_DIR="$ROOT/.artifacts/lan/$RUN_ID"
HOST_LOG="$LOG_DIR/host.probe.log"
HOST_STDOUT="$LOG_DIR/host.stdout.log"
/bin/mkdir -p "$LOG_DIR"

if [ "$DEPLOY" = "1" ]; then
    say "Deploying exact candidate to Neo"
    "$ROOT/scripts/deploy-lan-client.sh" --target "$NEO_TARGET" --identity "$NEO_IDENTITY" \
        --known-hosts "$KNOWN_HOSTS_FILE" --source-app "$LOCAL_APP" --no-build --no-launch
    if [ "$NEO_ONLY" != "1" ]; then
        say "Deploying exact candidate to Air"
        "$ROOT/scripts/deploy-lan-client.sh" --target "$AIR_TARGET" --identity "$AIR_IDENTITY" \
            --known-hosts "$KNOWN_HOSTS_FILE" --source-app "$LOCAL_APP" --no-build --no-launch
    fi
fi

LOCAL_SHA="$(/usr/bin/shasum -a 256 "$LOCAL_EXECUTABLE" | /usr/bin/awk '{print $1}')"
TEST_NODES=(neo)
if [ "$NEO_ONLY" != "1" ]; then TEST_NODES+=(air); fi
for node in "${TEST_NODES[@]}"; do
    say "Preflighting $node"
    remote "$node" 'set -eu
test "$(/usr/bin/stat -f %Su /dev/console)" = "$(/usr/bin/whoami)"
test -x "$HOME/Applications/Elysium.app/Contents/MacOS/Elysium"
/usr/bin/codesign --verify --deep --strict "$HOME/Applications/Elysium.app"' >/dev/null
    remote_sha="$(remote "$node" "/usr/bin/shasum -a 256 \"\$HOME/$REMOTE_APP_REL/Contents/MacOS/Elysium\" | /usr/bin/awk '{print \$1}'")"
    [ "$remote_sha" = "$LOCAL_SHA" ] || die "$node executable hash differs from host"
    printf '%s_executable_sha256=%s\n' "$node" "$remote_sha" >>"$LOG_DIR/receipt.txt"
done
printf 'host_executable_sha256=%s\nrun_id=%s\n' "$LOCAL_SHA" "$RUN_ID" >>"$LOG_DIR/receipt.txt"

for node in "${TEST_NODES[@]}"; do
    existing="$(remote "$node" '/bin/ps -axo pid=,command= | /usr/bin/awk -v exe="$HOME/Applications/Elysium.app/Contents/MacOS/Elysium" '\''$2 == exe {print $1}'\''' || true)"
    for pid in $existing; do remote "$node" "/bin/kill -TERM '$pid'" >/dev/null 2>&1 || true; done
done
local_existing="$(/bin/ps -axo pid=,command= | /usr/bin/awk -v exe="$LOCAL_EXECUTABLE" '$2 == exe {print $1}')"
for pid in $local_existing; do /bin/kill -TERM "$pid" 2>/dev/null || true; done
/bin/sleep 2

REMOTE_RUN_REL="Library/Caches/ElysiumRemoteClient/lab/$RUN_ID"
launch_remote() {
    local node="$1" mode="$2" player_name="$3" player_name_base64 output app_pid caf_pid
    case "$player_name" in "Neo Probe"|"Air Probe") ;; *) die "unsupported remote probe identity" ;; esac
    # OpenSSH joins command arguments into a remote shell command; it does not preserve argv
    # boundaries. Encode the only value that can contain spaces/metacharacters before transport.
    player_name_base64="$(printf '%s' "$player_name" | /usr/bin/base64 | /usr/bin/tr -d '\r\n')"
    case "$player_name_base64" in ''|*[!A-Za-z0-9+/=]*) die "could not encode remote player name" ;; esac
    output="$(remote "$node" /bin/bash -s -- "$REMOTE_RUN_REL" "$mode" "$player_name_base64" \
        "$LOCAL_IP" "$PORT" "$JOIN_CODE" "$(( TIMEOUT * 60 ))" <<'REMOTE_LAUNCH'
set -euo pipefail
RUN_REL="$1"
MODE="$2"
PLAYER_NAME="$(printf '%s' "$3" | /usr/bin/base64 -D)"
HOST_IP="$4"
PORT="$5"
JOIN_CODE="$6"
TIMEOUT_FRAMES="$7"
RUN_DIR="$HOME/$RUN_REL"
APP="$HOME/Applications/Elysium.app"
/bin/mkdir -p "$RUN_DIR"
PROBE_LOG="$RUN_DIR/probe.log"
STDOUT_LOG="$RUN_DIR/stdout.log"
JOIN_SPEC="$HOST_IP $PORT $JOIN_CODE $PLAYER_NAME"
nohup /usr/bin/env \
    ELYSIUM_LAN_AUTOJOIN="$JOIN_SPEC" \
    ELYSIUM_LAN_PROBE="$MODE" \
    ELYSIUM_LAN_PROBE_LOG="$PROBE_LOG" \
    ELYSIUM_LAN_PROBE_TIMEOUT_FRAMES="$TIMEOUT_FRAMES" \
    "$APP/Contents/MacOS/Elysium" >"$STDOUT_LOG" 2>&1 &
app_pid=$!
nohup /usr/bin/caffeinate -dimsu -w "$app_pid" >"$RUN_DIR/caffeinate.log" 2>&1 &
caf_pid=$!
printf '%s %s\n' "$app_pid" "$caf_pid"
REMOTE_LAUNCH
)"
    output="$(lan_parse_positive_pid_pair "$output")" \
        || die "$node launch did not return exactly two safe positive PIDs"
    set -- $output
    app_pid="$1"
    caf_pid="$2"
    if [ "$node" = "neo" ]; then
        NEO_PID="$app_pid"; NEO_CAFFEINATE_PID="$caf_pid"
    else
        AIR_PID="$app_pid"; AIR_CAFFEINATE_PID="$caf_pid"
    fi
}

EXPECTED_CLIENTS=2
if [ "$NEO_ONLY" = "1" ]; then EXPECTED_CLIENTS=1; fi

say "Launching installed host"
nohup /usr/bin/env \
    ELYSIUM_AUTOLOAD=1 \
    ELYSIUM_NEWWORLD="$SEED" \
    ELYSIUM_LAN_PROBE=host-rig \
    ELYSIUM_LAN_PROBE_LOG="$HOST_LOG" \
    ELYSIUM_LAN_PROBE_TIMEOUT_FRAMES="$(( TIMEOUT * 60 ))" \
    ELYSIUM_LAN_PROBE_JOIN_CODE="$JOIN_CODE" \
    ELYSIUM_LAN_PROBE_PORT="$PORT" \
    ELYSIUM_LAN_PROBE_EXPECTED_CLIENTS="$EXPECTED_CLIENTS" \
    "$LOCAL_EXECUTABLE" >"$HOST_STDOUT" 2>&1 &
HOST_PID=$!
nohup /usr/bin/caffeinate -dimsu -w "$HOST_PID" >"$LOG_DIR/host.caffeinate.log" 2>&1 &
HOST_CAFFEINATE_PID=$!

say "Launching Neo actor"
launch_remote neo client-door "Neo Probe"
if [ "$NEO_ONLY" != "1" ]; then
    say "Launching Air observer"
    launch_remote air client-observer "Air Probe"
fi

remote_has() { remote "$1" "/usr/bin/grep -Fq '$2' \"\$HOME/$REMOTE_RUN_REL/probe.log\"" >/dev/null 2>&1; }
phase_failed() {
    /usr/bin/grep -Fq 'LANPROBE FAIL' "$HOST_LOG" 2>/dev/null ||
        remote_has neo 'LANPROBE FAIL' ||
        { [ "$NEO_ONLY" != "1" ] && remote_has air 'LANPROBE FAIL'; }
}
poll_initial() {
    local deadline=$(( $(date +%s) + TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        phase_failed && return 1
        if /usr/bin/grep -Fq "LANPROBE PASS host remote-use peers=$EXPECTED_CLIENTS" "$HOST_LOG" 2>/dev/null &&
           remote_has neo 'LANPROBE PASS client shared-state'; then
            if [ "$NEO_ONLY" = "1" ] || remote_has air 'LANPROBE PASS client observed-state'; then
                return 0
            fi
        fi
        /bin/sleep 1
    done
    return 1
}

if ! poll_initial; then
    say "LAN convergence phase failed"
    exit 1
fi

if [ "$NEO_ONLY" = "1" ]; then
    say "Convergence passed; reconnecting Neo"
else
    say "Convergence passed; reconnecting Neo while Air remains live"
fi
stop_remote_run neo "$NEO_PID" "$NEO_CAFFEINATE_PID"
NEO_PID=""; NEO_CAFFEINATE_PID=""
/bin/sleep 2
launch_remote neo client-resume "Neo Probe"

deadline=$(( $(date +%s) + TIMEOUT ))
resume_pass=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    phase_failed && break
    if [ "$NEO_ONLY" != "1" ]; then
        remote air "/bin/kill -0 '$AIR_PID'" >/dev/null 2>&1 || break
    fi
    /bin/kill -0 "$HOST_PID" >/dev/null 2>&1 || break
    if remote_has neo 'LANPROBE PASS client resume-position'; then resume_pass=1; break; fi
    /bin/sleep 1
done
[ "$resume_pass" = "1" ] || die "Neo resume failed or sibling/host exited"

say "Collecting node receipts"
copy_from neo "$REMOTE_RUN_REL/probe.log" "$LOG_DIR/neo.probe.log" >/dev/null
copy_from neo "$REMOTE_RUN_REL/stdout.log" "$LOG_DIR/neo.stdout.log" >/dev/null
if [ "$NEO_ONLY" = "1" ]; then
    printf 'result=pass\nclients=1\nreconnect=neo\nsibling_remained_live=not-applicable\n' >>"$LOG_DIR/receipt.txt"
    say "Two-Mac host + Neo installed LAN probe passed: $LOG_DIR"
else
    copy_from air "$REMOTE_RUN_REL/probe.log" "$LOG_DIR/air.probe.log" >/dev/null
    copy_from air "$REMOTE_RUN_REL/stdout.log" "$LOG_DIR/air.stdout.log" >/dev/null
    printf 'result=pass\nclients=2\nreconnect=neo\nsibling_remained_live=air\n' >>"$LOG_DIR/receipt.txt"
    say "Three-Mac installed LAN probe passed: $LOG_DIR"
fi
