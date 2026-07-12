#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
[ -t 0 ] && [ -t 1 ] || {
    echo "Designer attestation failed: interactive TTY required" >&2
    exit 1
}
scripts/installed-signoff-receipt.sh verify-current
scripts/installed-signoff-receipt.sh designer-attest
scripts/installed-signoff-receipt.sh verify-current
