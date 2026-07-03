#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_HOST="neo.localdomain"
REMOTE_HOST="${PEBBLE_LAN_CLIENT_HOST:-$DEFAULT_HOST}"
REMOTE_USER="${PEBBLE_LAN_CLIENT_USER:-${USER:-}}"
REMOTE_TARGET="${PEBBLE_LAN_CLIENT_TARGET:-}"
REMOTE_APP="${PEBBLE_LAN_CLIENT_APP:-/Applications/Pebble.app}"
SOURCE_APP="${PEBBLE_LAN_CLIENT_SOURCE_APP:-/Applications/Pebble.app}"
IDENTITY_FILE="${PEBBLE_LAN_CLIENT_IDENTITY:-$HOME/.ssh/pebble_neo_ed25519}"
BUILD_FIRST=1
LAUNCH_AFTER=1
CHECK_ONLY=0
REMOTE_STAGE_REL="Library/Caches/PebbleRemoteClient"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)
if [ -f "$IDENTITY_FILE" ]; then
    SSH_OPTS+=(-i "$IDENTITY_FILE")
fi
ARCHIVE_TO_CLEAN=""
trap 'if [ -n "${ARCHIVE_TO_CLEAN:-}" ]; then rm -rf "$ARCHIVE_TO_CLEAN"; fi' EXIT

usage() {
    cat <<EOF
Usage: scripts/deploy-lan-client.sh [options]

Builds Pebble locally, copies Pebble.app to a LAN client Mac, installs it in
/Applications, and launches it.

Options:
  --host HOST       Remote host name or address (default: ${DEFAULT_HOST})
  --user USER       SSH user (default: current local user)
  --target TARGET   Full SSH target, e.g. user@neo.local (overrides host/user)
  --app PATH        Remote app path (default: /Applications/Pebble.app)
  --source-app PATH Local app bundle to copy (default: /Applications/Pebble.app)
  --no-build        Copy the existing local app instead of running ./pebble install
  --no-launch       Install on the client but do not open it
  --check           Only verify SSH reachability and remote write prerequisites
  -h, --help        Show this help

Environment overrides:
  PEBBLE_LAN_CLIENT_HOST, PEBBLE_LAN_CLIENT_USER, PEBBLE_LAN_CLIENT_TARGET,
  PEBBLE_LAN_CLIENT_APP, PEBBLE_LAN_CLIENT_SOURCE_APP,
  PEBBLE_LAN_CLIENT_IDENTITY
EOF
}

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            [ "$#" -ge 2 ] || die "--host needs a value"
            REMOTE_HOST="$2"
            shift 2
            ;;
        --user)
            [ "$#" -ge 2 ] || die "--user needs a value"
            REMOTE_USER="$2"
            shift 2
            ;;
        --target)
            [ "$#" -ge 2 ] || die "--target needs a value"
            REMOTE_TARGET="$2"
            shift 2
            ;;
        --app)
            [ "$#" -ge 2 ] || die "--app needs a value"
            REMOTE_APP="$2"
            shift 2
            ;;
        --source-app)
            [ "$#" -ge 2 ] || die "--source-app needs a value"
            SOURCE_APP="$2"
            shift 2
            ;;
        --no-build)
            BUILD_FIRST=0
            shift
            ;;
        --no-launch)
            LAUNCH_AFTER=0
            shift
            ;;
        --check)
            CHECK_ONLY=1
            BUILD_FIRST=0
            LAUNCH_AFTER=0
            shift
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

check_remote() {
    local probe output
    probe='
set -e
printf "host=%s\n" "$(hostname)"
printf "user=%s\n" "$(whoami)"
printf "home=%s\n" "$HOME"
printf "macos=%s\n" "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
if [ -w /Applications ]; then
    echo "applications_writable=yes"
else
    echo "applications_writable=no"
fi
mkdir -p "$HOME/Library/Caches/PebbleRemoteClient"
test -w "$HOME/Library/Caches/PebbleRemoteClient"
'
    if ! output="$(remote "$probe" 2>&1)"; then
        if printf '%s\n' "$output" | grep -qi 'permission denied'; then
            cat >&2 <<EOF
error: ${REMOTE_TARGET} is reachable, but SSH authentication failed.

Add this Mac's Pebble LAN client key to the Neo account's authorized_keys:
  ${IDENTITY_FILE}.pub

If the account name differs, rerun with:
  PEBBLE_LAN_CLIENT_USER=<neo-user> scripts/deploy-lan-client.sh --check
EOF
        else
            cat >&2 <<EOF
error: cannot reach ${REMOTE_TARGET} over SSH.

Neo is visible on the LAN only after macOS Remote Login is enabled for this user.
On Neo, enable:
  System Settings -> General -> Sharing -> Remote Login

Then verify from this Mac:
  ssh ${REMOTE_TARGET} hostname

If the account name differs, rerun with:
  PEBBLE_LAN_CLIENT_USER=<neo-user> scripts/deploy-lan-client.sh --check

If the key has not been authorized yet, add this public key to the Neo account:
  ${IDENTITY_FILE}.pub
EOF
        fi
        printf '\nssh output:\n%s\n' "$output" >&2
        exit 1
    fi
    printf '%s\n' "$output"
    if printf '%s\n' "$output" | grep -q '^applications_writable=no$'; then
        die "${REMOTE_TARGET} can SSH, but /Applications is not writable by that account"
    fi
}

install_remote() {
    local archive temp_dir
    temp_dir="$(mktemp -d /tmp/pebble-lan-client.XXXXXX)"
    ARCHIVE_TO_CLEAN="$temp_dir"
    archive="$temp_dir/Pebble.app.zip"

    say "Packaging ${SOURCE_APP}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SOURCE_APP" "$archive"

    say "Copying Pebble.app archive to ${REMOTE_TARGET}"
    remote "mkdir -p '$REMOTE_STAGE_REL'"
    scp "${SSH_OPTS[@]}" "$archive" "${REMOTE_TARGET}:${REMOTE_STAGE_REL}/Pebble.app.zip" >/dev/null

    say "Installing and launching on ${REMOTE_TARGET}"
    ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" 'bash -s' -- "$REMOTE_APP" "$REMOTE_STAGE_REL" "$LAUNCH_AFTER" <<'REMOTE_SCRIPT'
set -euo pipefail
REMOTE_APP="$1"
REMOTE_STAGE_REL="$2"
LAUNCH_AFTER="$3"
STAGE="$HOME/$REMOTE_STAGE_REL"
ARCHIVE="$STAGE/Pebble.app.zip"
UNPACK="$STAGE/unpack"

/usr/bin/osascript -e 'tell application "Pebble" to quit' >/dev/null 2>&1 || true
/usr/bin/pkill -x Pebble >/dev/null 2>&1 || true
rm -rf "$UNPACK"
mkdir -p "$UNPACK"
/usr/bin/ditto -x -k "$ARCHIVE" "$UNPACK"
test -d "$UNPACK/Pebble.app"
rm -rf "$REMOTE_APP"
/usr/bin/ditto "$UNPACK/Pebble.app" "$REMOTE_APP"
/usr/bin/xattr -dr com.apple.quarantine "$REMOTE_APP" >/dev/null 2>&1 || true
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REMOTE_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "installed=${REMOTE_APP}"
echo "version=${VERSION}"
if [ "$LAUNCH_AFTER" = "1" ]; then
    /usr/bin/open -n "$REMOTE_APP"
    sleep 2
    if /usr/bin/pgrep -x Pebble >/dev/null; then
        echo "launched=yes"
    else
        echo "launched=no"
        exit 1
    fi
fi
REMOTE_SCRIPT
}

say "Checking ${REMOTE_TARGET}"
check_remote

if [ "$CHECK_ONLY" = "1" ]; then
    say "Remote LAN client check passed"
    exit 0
fi

if [ "$BUILD_FIRST" = "1" ]; then
    say "Building and installing local Pebble.app"
    (cd "$ROOT" && ./pebble install)
fi

[ -d "$SOURCE_APP" ] || die "source app does not exist: ${SOURCE_APP}"
install_remote
say "Remote LAN client deploy complete"
