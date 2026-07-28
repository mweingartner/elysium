#!/bin/bash
set -euo pipefail

. scripts/lan-automation-lib.sh

round_trip_remote_player_name() {
    local expected="$1" encoded actual
    encoded="$(printf '%s' "$expected" | /usr/bin/base64 | /usr/bin/tr -d '\r\n')"
    case "$encoded" in ''|*[!A-Za-z0-9+/=]*) return 1 ;; esac
    # This is the same argv shape OpenSSH's remote shell receives: every transported token is
    # whitespace-free, while the decoded third argument recovers the original display name.
    actual="$(/bin/bash -s -- run/path client-door "$encoded" 10.0.10.153 41337 ABCD1234 5400 <<'REMOTE'
set -euo pipefail
[ "$#" = "7" ]
printf '%s' "$3" | /usr/bin/base64 -D
REMOTE
)"
    [ "$actual" = "$expected" ]
}

round_trip_remote_player_name "Neo Probe"
round_trip_remote_player_name "Air Probe"

lan_validate_port 1
lan_validate_port 65535
for invalid_port in 0 65536 '41337;id' '41337 22' ''; do
    ! lan_validate_port "$invalid_port"
done

[ "$(lan_parse_positive_pid_pair '42 43')" = '42 43' ]
for invalid_pids in '0 43' '1 43' '42 0' '42 1' '42' '42 43 44' '42;id 43' ''; do
    ! lan_parse_positive_pid_pair "$invalid_pids" >/dev/null
done

# Deployment must scan the exact production executable before transport, and its remote rollback
# must track a moved backup independently from successful candidate activation.
/usr/bin/grep -F 'security-check-binary.sh" "$SOURCE_EXECUTABLE"' scripts/deploy-lan-client.sh >/dev/null
/usr/bin/grep -F 'security-check-binary.sh" "$LOCAL_EXECUTABLE"' scripts/live-lan-test.sh >/dev/null
/usr/bin/grep -F 'BACKUP_MOVED=1' scripts/deploy-lan-client.sh >/dev/null

printf 'LAN automation script tests: passed\n'
