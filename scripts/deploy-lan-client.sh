#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_HOST="neo.localdomain"
REMOTE_HOST="${ELYSIUM_LAN_CLIENT_HOST:-$DEFAULT_HOST}"
REMOTE_USER="${ELYSIUM_LAN_CLIENT_USER:-${USER:-}}"
REMOTE_TARGET="${ELYSIUM_LAN_CLIENT_TARGET:-}"
SOURCE_APP="${ELYSIUM_LAN_CLIENT_SOURCE_APP:-/Applications/Elysium.app}"
IDENTITY_FILE="${ELYSIUM_LAN_CLIENT_IDENTITY:-$HOME/.ssh/elysium_neo_ed25519}"
KNOWN_HOSTS_FILE="${ELYSIUM_LAN_KNOWN_HOSTS:-$HOME/.ssh/elysium_lan_known_hosts}"
EXPECTED_BUNDLE_ID="com.briangao.elysium"
REMOTE_APP_REL="Applications/Elysium.app"
BUILD_FIRST=1
LAUNCH_AFTER=1
CHECK_ONLY=0
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOCAL_TEMP=""

cleanup() {
    if [ -n "$LOCAL_TEMP" ] && [ -d "$LOCAL_TEMP" ]; then
        rm -rf "$LOCAL_TEMP"
    fi
}
trap cleanup EXIT INT TERM

usage() {
    cat <<EOF
Usage: scripts/deploy-lan-client.sh [options]

Stages one already-signed Elysium.app, verifies its archive, executable, bundle
identity, and code signature on the remote Mac, then atomically activates it at
~/Applications/Elysium.app with rollback on failure.

Options:
  --host HOST          Remote host name/address (default: ${DEFAULT_HOST})
  --user USER          SSH user (default: current local user)
  --target TARGET      Full SSH target; overrides host/user
  --identity PATH      Dedicated node private key
  --known-hosts PATH   Dedicated, pre-pinned known_hosts file
  --source-app PATH    Local app bundle (default: /Applications/Elysium.app)
  --no-build           Do not run ./elysium install first
  --no-launch          Activate but do not launch the remote app
  --check              Verify the pinned SSH/GUI prerequisites only
  -h, --help           Show this help

Host keys are never accepted on first use. Bootstrap and verify each node with
scripts/setup-lan-test-node.sh before deploying.
EOF
}

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host) [ "$#" -ge 2 ] || die "--host needs a value"; REMOTE_HOST="$2"; shift 2 ;;
        --user) [ "$#" -ge 2 ] || die "--user needs a value"; REMOTE_USER="$2"; shift 2 ;;
        --target) [ "$#" -ge 2 ] || die "--target needs a value"; REMOTE_TARGET="$2"; shift 2 ;;
        --identity) [ "$#" -ge 2 ] || die "--identity needs a value"; IDENTITY_FILE="$2"; shift 2 ;;
        --known-hosts) [ "$#" -ge 2 ] || die "--known-hosts needs a value"; KNOWN_HOSTS_FILE="$2"; shift 2 ;;
        --source-app) [ "$#" -ge 2 ] || die "--source-app needs a value"; SOURCE_APP="$2"; shift 2 ;;
        --no-build) BUILD_FIRST=0; shift ;;
        --no-launch) LAUNCH_AFTER=0; shift ;;
        --check) CHECK_ONLY=1; BUILD_FIRST=0; LAUNCH_AFTER=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

if [ -z "$REMOTE_TARGET" ]; then
    if [ -n "$REMOTE_USER" ]; then
        REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
    else
        REMOTE_TARGET="$REMOTE_HOST"
    fi
fi

[ -f "$IDENTITY_FILE" ] || die "dedicated SSH identity is missing: $IDENTITY_FILE"
[ -f "$KNOWN_HOSTS_FILE" ] || die "pinned known_hosts file is missing: $KNOWN_HOSTS_FILE"
[ "$(stat -f '%Lp' "$IDENTITY_FILE")" = "600" ] || die "SSH private key must have mode 0600: $IDENTITY_FILE"

SSH_OPTS=(
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
    -o ConnectTimeout=10
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2
    -i "$IDENTITY_FILE"
)

remote() { ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" "$@"; }

check_remote() {
    local output
    if ! output="$(remote 'set -eu
console_user="$(/usr/bin/stat -f %Su /dev/console)"
printf "host=%s\n" "$(/bin/hostname)"
printf "user=%s\n" "$(/usr/bin/whoami)"
printf "console_user=%s\n" "$console_user"
printf "uid=%s\n" "$(/usr/bin/id -u)"
printf "arch=%s\n" "$(/usr/bin/uname -m)"
printf "macos=%s\n" "$(/usr/bin/sw_vers -productVersion)"
[ "$console_user" = "$(/usr/bin/whoami)" ]
/bin/mkdir -p "$HOME/Applications" "$HOME/Library/Caches/ElysiumRemoteClient"
/bin/test -w "$HOME/Applications"
/bin/test -w "$HOME/Library/Caches/ElysiumRemoteClient"' 2>&1)"; then
        printf '%s\n' "$output" >&2
        die "pinned SSH or logged-in GUI-user preflight failed for $REMOTE_TARGET"
    fi
    printf '%s\n' "$output"
}

say "Checking pinned SSH and GUI session on ${REMOTE_TARGET}"
check_remote
[ "$CHECK_ONLY" = "0" ] || { say "Remote client check passed"; exit 0; }

if [ "$BUILD_FIRST" = "1" ]; then
    say "Building and installing the local candidate"
    (cd "$ROOT" && ./elysium install)
fi

[ -d "$SOURCE_APP" ] || die "source app does not exist: $SOURCE_APP"
SOURCE_EXECUTABLE="$SOURCE_APP/Contents/MacOS/Elysium"
SOURCE_INFO="$SOURCE_APP/Contents/Info.plist"
[ -x "$SOURCE_EXECUTABLE" ] || die "source executable is missing: $SOURCE_EXECUTABLE"
[ -f "$SOURCE_INFO" ] || die "source Info.plist is missing: $SOURCE_INFO"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" || die "source app signature is invalid"
"$ROOT/scripts/security-check-binary.sh" "$SOURCE_EXECUTABLE" \
    || die "source executable contains a forbidden production/debug-control surface"
LOCAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_INFO")"
[ "$LOCAL_BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || die "unexpected source bundle id: $LOCAL_BUNDLE_ID"
LOCAL_EXEC_SHA="$(/usr/bin/shasum -a 256 "$SOURCE_EXECUTABLE" | /usr/bin/awk '{print $1}')"

LOCAL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/elysium-deploy.XXXXXX")"
ARCHIVE="$LOCAL_TEMP/Elysium.app.zip"
say "Packaging candidate"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SOURCE_APP" "$ARCHIVE"
ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
REMOTE_STAGE_REL="Library/Caches/ElysiumRemoteClient/$RUN_ID"

say "Uploading verified archive to ${REMOTE_TARGET}"
remote "/bin/mkdir -p '$REMOTE_STAGE_REL'"
scp "${SSH_OPTS[@]}" "$ARCHIVE" "${REMOTE_TARGET}:${REMOTE_STAGE_REL}/Elysium.app.zip" >/dev/null

say "Verifying, activating, and attesting remote candidate"
ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" /bin/bash -s -- \
    "$REMOTE_STAGE_REL" "$REMOTE_APP_REL" "$ARCHIVE_SHA" "$LOCAL_EXEC_SHA" \
    "$EXPECTED_BUNDLE_ID" "$LAUNCH_AFTER" <<'REMOTE_SCRIPT'
set -euo pipefail
STAGE_REL="$1"
APP_REL="$2"
EXPECTED_ARCHIVE_SHA="$3"
EXPECTED_EXEC_SHA="$4"
EXPECTED_BUNDLE_ID="$5"
LAUNCH_AFTER="$6"

STAGE="$HOME/$STAGE_REL"
ARCHIVE="$STAGE/Elysium.app.zip"
UNPACK="$STAGE/unpack"
CANDIDATE="$UNPACK/Elysium.app"
TARGET="$HOME/$APP_REL"
BACKUP="$STAGE/previous.app"
ACTIVATED=0
BACKUP_MOVED=0

rollback() {
    status=$?
    if [ "$status" -ne 0 ] && { [ "$ACTIVATED" = "1" ] || [ "$BACKUP_MOVED" = "1" ]; }; then
        /bin/rm -rf "$TARGET"
        if [ "$BACKUP_MOVED" = "1" ] && [ -d "$BACKUP" ]; then
            /bin/mv "$BACKUP" "$TARGET"
        fi
        printf 'rollback=restored_previous\n' >&2
    fi
    exit "$status"
}
trap rollback EXIT INT TERM

actual_archive_sha="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
[ "$actual_archive_sha" = "$EXPECTED_ARCHIVE_SHA" ]
/bin/rm -rf "$UNPACK"
/bin/mkdir -p "$UNPACK"
/usr/bin/ditto -x -k "$ARCHIVE" "$UNPACK"
[ -x "$CANDIDATE/Contents/MacOS/Elysium" ]

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CANDIDATE/Contents/Info.plist")"
[ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ]
candidate_exec_sha="$(/usr/bin/shasum -a 256 "$CANDIDATE/Contents/MacOS/Elysium" | /usr/bin/awk '{print $1}')"
[ "$candidate_exec_sha" = "$EXPECTED_EXEC_SHA" ]
/usr/bin/codesign --verify --deep --strict "$CANDIDATE"

/bin/mkdir -p "$(/usr/bin/dirname "$TARGET")"
target_executable="$TARGET/Contents/MacOS/Elysium"
old_pids="$(/bin/ps -axo pid=,command= | /usr/bin/awk -v exe="$target_executable" '$2 == exe {print $1}')"
for pid in $old_pids; do /bin/kill -TERM "$pid" 2>/dev/null || true; done
if [ -n "$old_pids" ]; then /bin/sleep 2; fi

/bin/rm -rf "$BACKUP"
if [ -e "$TARGET" ]; then
    /bin/mv "$TARGET" "$BACKUP"
    BACKUP_MOVED=1
fi
/bin/mv "$CANDIDATE" "$TARGET"
ACTIVATED=1

/usr/bin/codesign --verify --deep --strict "$TARGET"
installed_exec_sha="$(/usr/bin/shasum -a 256 "$target_executable" | /usr/bin/awk '{print $1}')"
[ "$installed_exec_sha" = "$EXPECTED_EXEC_SHA" ]
installed_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist")"
[ "$installed_bundle_id" = "$EXPECTED_BUNDLE_ID" ]

if [ "$LAUNCH_AFTER" = "1" ]; then
    /bin/launchctl asuser "$(/usr/bin/id -u)" /usr/bin/open -n "$TARGET"
    /bin/sleep 2
    launched_pid="$(/bin/ps -axo pid=,command= | /usr/bin/awk -v exe="$target_executable" '$2 == exe {print $1; exit}')"
    [ -n "$launched_pid" ]
    printf 'launched_pid=%s\n' "$launched_pid"
fi

/bin/rm -rf "$BACKUP"
BACKUP_MOVED=0
ACTIVATED=0
printf 'installed=%s\n' "$TARGET"
printf 'bundle_id=%s\n' "$installed_bundle_id"
printf 'archive_sha256=%s\n' "$actual_archive_sha"
printf 'executable_sha256=%s\n' "$installed_exec_sha"
REMOTE_SCRIPT

say "Remote LAN client deploy complete"
