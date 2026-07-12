#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { echo "usage: prepush-release-build.sh LOG" >&2; exit 64; }
LOG="$1"
if ! swift build -c release >"$LOG" 2>&1; then
    cat "$LOG"
    echo "pre-push blocked: release build failed" >&2
    exit 1
fi
cat "$LOG"
if grep -q 'warning:' "$LOG"; then
    echo "pre-push blocked: release warnings" >&2
    exit 1
fi
