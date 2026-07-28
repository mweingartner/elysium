#!/bin/bash

lan_validate_port() {
    [ "$#" = "1" ] || return 1
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

lan_parse_positive_pid_pair() {
    [ "$#" = "1" ] || return 1
    local raw="$1"
    case "$raw" in ''|*[!0-9\ ]*) return 1 ;; esac
    set -- $raw
    [ "$#" = "2" ] || return 1
    case "$1:$2" in *[!0-9:]*) return 1 ;; esac
    # PID 1 is launchd and PID 0 has process-group semantics; neither can be an app/caffeinate PID.
    [ "$1" -gt 1 ] 2>/dev/null && [ "$2" -gt 1 ] 2>/dev/null || return 1
    printf '%s %s\n' "$1" "$2"
}
