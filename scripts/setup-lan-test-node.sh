#!/bin/bash
set -euo pipefail

NODE=""
HOST=""
REMOTE_USER="${USER:-}"
EXPECTED_FINGERPRINT=""
ACCEPT_FULL_SHELL=0
KNOWN_HOSTS_FILE="${ELYSIUM_LAN_KNOWN_HOSTS:-$HOME/.ssh/elysium_lan_known_hosts}"

usage() {
    cat <<'EOF'
Usage: scripts/setup-lan-test-node.sh --node neo|air --host HOST [options]

Creates a dedicated controller key and scans the node's Ed25519 SSH host key.
It pins the host key only when --fingerprint exactly matches a fingerprint read
out-of-band on that Mac.

Options:
  --node NAME            neo or air
  --host HOST            DNS name or IP address
  --user USER            Remote GUI test user
  --fingerprint SHA256:X Expected Ed25519 host-key fingerprint
  --known-hosts PATH     Dedicated known_hosts file
  --accept-full-shell    Acknowledge that autonomous deploy/test access grants
                         the controller arbitrary noninteractive commands as
                         this dedicated, non-admin GUI test user
  -h, --help             Show this help

On the remote Mac, obtain the value for --fingerprint with:
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --node) [ "$#" -ge 2 ] || die "--node needs a value"; NODE="$2"; shift 2 ;;
        --host) [ "$#" -ge 2 ] || die "--host needs a value"; HOST="$2"; shift 2 ;;
        --user) [ "$#" -ge 2 ] || die "--user needs a value"; REMOTE_USER="$2"; shift 2 ;;
        --fingerprint) [ "$#" -ge 2 ] || die "--fingerprint needs a value"; EXPECTED_FINGERPRINT="$2"; shift 2 ;;
        --known-hosts) [ "$#" -ge 2 ] || die "--known-hosts needs a value"; KNOWN_HOSTS_FILE="$2"; shift 2 ;;
        --accept-full-shell) ACCEPT_FULL_SHELL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

case "$NODE" in neo|air) ;; *) die "--node must be neo or air" ;; esac
[ -n "$HOST" ] || die "--host is required"
case "$HOST" in *[!A-Za-z0-9._:-]*) die "host contains unsupported characters" ;; esac
case "$REMOTE_USER" in *[!A-Za-z0-9._-]*) die "user contains unsupported characters" ;; esac

IDENTITY_FILE="$HOME/.ssh/elysium_${NODE}_ed25519"
/bin/mkdir -p "$HOME/.ssh"
/bin/chmod 700 "$HOME/.ssh"
if [ ! -f "$IDENTITY_FILE" ]; then
    /usr/bin/ssh-keygen -q -t ed25519 -a 100 -N '' -C "elysium-${NODE}-controller" -f "$IDENTITY_FILE"
fi
/bin/chmod 600 "$IDENTITY_FILE"
/bin/chmod 644 "$IDENTITY_FILE.pub"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/elysium-hostkey.XXXXXX")"
cleanup() { /bin/rm -rf "$TEMP_DIR"; }
trap cleanup EXIT INT TERM
SCAN_FILE="$TEMP_DIR/host.ed25519"

if ! /usr/bin/ssh-keyscan -T 5 -t ed25519 "$HOST" >"$SCAN_FILE" 2>/dev/null; then
    die "could not scan $HOST: enable Remote Login on the node first"
fi
[ -s "$SCAN_FILE" ] || die "no Ed25519 SSH host key returned by $HOST"
SCANNED_FINGERPRINTS="$(/usr/bin/ssh-keygen -lf "$SCAN_FILE" -E sha256 | /usr/bin/awk '{print $2}' | /usr/bin/sort -u)"
SCANNED_FINGERPRINT_COUNT="$(printf '%s\n' "$SCANNED_FINGERPRINTS" | /usr/bin/awk 'NF {count++} END {print count+0}')"
[ "$SCANNED_FINGERPRINT_COUNT" = "1" ] || {
    printf 'refusing to pin %s because ssh-keyscan returned %s distinct Ed25519 keys:\n%s\n' \
        "$HOST" "$SCANNED_FINGERPRINT_COUNT" "$SCANNED_FINGERPRINTS" >&2
    exit 1
}
SCANNED_FINGERPRINT="$SCANNED_FINGERPRINTS"
PUBLIC_KEY="$(/bin/cat "$IDENTITY_FILE.pub")"
CONTROLLER_INTERFACE="$(/sbin/route get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
CONTROLLER_IP="$(/usr/sbin/ipconfig getifaddr "$CONTROLLER_INTERFACE" 2>/dev/null || true)"

printf 'node=%s\n' "$NODE"
printf 'host=%s\n' "$HOST"
printf 'scanned_fingerprint=%s\n' "$SCANNED_FINGERPRINT"
printf 'controller_public_key=%s\n' "$PUBLIC_KEY"
printf '\nSecurity boundary: this key intentionally grants arbitrary noninteractive shell commands as %s.\n' "$REMOTE_USER"
printf 'Use a dedicated non-admin GUI test account. "restrict" disables PTY and forwarding; it is not a command allowlist.\n'

if [ -z "$EXPECTED_FINGERPRINT" ]; then
    printf '\nHost key was not pinned. Re-run with the fingerprint displayed locally on %s:\n' "$NODE"
    printf '  scripts/setup-lan-test-node.sh --node %s --host %s --user %s --fingerprint %s --accept-full-shell\n' \
        "$NODE" "$HOST" "$REMOTE_USER" "$SCANNED_FINGERPRINT"
    exit 2
fi
[ "$SCANNED_FINGERPRINT" = "$EXPECTED_FINGERPRINT" ] || die "host-key fingerprint mismatch"
[ "$ACCEPT_FULL_SHELL" = "1" ] || die "--accept-full-shell is required because deploy/test automation executes arbitrary noninteractive commands as the test user"

printf '\nOn %s, install this acknowledged controller key in ~/.ssh/authorized_keys:\n' "$NODE"
if [ -n "$CONTROLLER_IP" ]; then
    printf 'restrict,from="%s/32" %s\n' "$CONTROLLER_IP" "$PUBLIC_KEY"
else
    printf 'restrict %s\n' "$PUBLIC_KEY"
fi

/bin/mkdir -p "$(/usr/bin/dirname "$KNOWN_HOSTS_FILE")"
/usr/bin/touch "$KNOWN_HOSTS_FILE"
/bin/chmod 600 "$KNOWN_HOSTS_FILE"
/usr/bin/ssh-keygen -q -R "$HOST" -f "$KNOWN_HOSTS_FILE" >/dev/null 2>&1 || true
/bin/cat "$SCAN_FILE" >>"$KNOWN_HOSTS_FILE"
/bin/chmod 600 "$KNOWN_HOSTS_FILE"
printf '\npinned_known_hosts=%s\n' "$KNOWN_HOSTS_FILE"
printf 'next_check=ELYSIUM_LAN_CLIENT_IDENTITY=%s ELYSIUM_LAN_CLIENT_HOST=%s scripts/deploy-lan-client.sh --user %s --check\n' \
    "$IDENTITY_FILE" "$HOST" "$REMOTE_USER"
